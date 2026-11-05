#!/bin/bash
# A shared core's folder (Genesis Plus GX runs Mega Drive, Master System and
# Game Gear) does not name a save's system. Only a record of the game under one
# of the core's systems may; otherwise the save is not uploaded.
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
T="${TMPDIR:-/tmp}/rsb-shared-core.$$"; STUB="$T/stub"; PORT=18779
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT

chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }
posts() { grep -c '^POST /saves' "$STUB/requests.log" 2>/dev/null || true; }
carries() { if grep -aq -- "$2" "$STUB/body.bin" 2>/dev/null; then echo "  PASS  $1"; else echo "  FAIL  $1 (multipart body missing)"; FAIL=1; fi; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"2026-01-01T00:00:00Z"}' "$4" > "$1/metadata.json"; touch -d '2026-01-01' "$1/payload.$3"; }

mkdir -p "$STUB"
cat > "$STUB/server.py" <<PY
import json, http.server, sys
L = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open(L + "/requests.log", "a").write("GET " + self.path + "\n")
        body = json.dumps({"success": True, "count": 0, "rom": None}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        open(L + "/requests.log", "a").write("POST " + self.path + "\n")
        open(L + "/body.bin", "wb").write(body)
        out = json.dumps({"success": True, "save": {"id": "save-x", "sha256": "s", "version": 1}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(("127.0.0.1", $PORT), H).serve_forever()
PY
python3 -u "$STUB/server.py" "$STUB" & SRV=$!
sleep 1

reset() { rm -rf "$T/webdav" "$T/rsm"; mkdir -p "$T/webdav/Genesis Plus GX" "$T/rsm"; : > "$STUB/requests.log"; rm -f "$STUB/body.bin"; }
put() { printf '%s' "$2" > "$T/webdav/Genesis Plus GX/$1.srm"; touch -d '+1 minute' "$T/webdav/Genesis Plus GX/$1.srm"; }
run() { (cd "$T" && WEBDAV_SAVES="$T/webdav" RSM_SAVES="$T/rsm" RSM_URL=http://127.0.0.1:$PORT POLL_INTERVAL_SECS=1 timeout 3 python3 -u "$B" >"$T/bridge.log" 2>&1); }

echo "=== S1 a save another system's record holds is not filed as genesis ==="
reset
mk "$T/rsm/Nintendo Entertainment System/Tecmo Super Bowl/save-1-a" NESBYTES srm nes
put "Tecmo Super Bowl" "NEWERBYTES"
run
chk "no upload of an NES game from Genesis Plus GX" "$(posts)" "0"

echo "=== S2 a game with no record is not guessed ==="
reset
put "Crystal Warriors" "GGBYTES"
run
chk "no upload without a record" "$(posts)" "0"
chk "says why" "$(grep -q "^\[AMBIGUOUS\] Genesis Plus GX/Crystal Warriors.srm" "$T/bridge.log" && echo yes || echo no)" "yes"

echo "=== S3 a game recorded under two of the core's systems is not guessed ==="
reset
mk "$T/rsm/Game Gear/Defenders of Oasis/save-1-a" OLDGG sav game-gear
mk "$T/rsm/Master System/Defenders of Oasis/save-2-b" OLDSMS sav master-system
put "Defenders of Oasis" "NEWBYTES"
run
chk "no upload when the records disagree" "$(posts)" "0"

echo "=== S4 a game recorded under one of the core's systems is filed under it ==="
reset
mk "$T/rsm/Game Gear/Shining Force/save-1-a" OLDGG sav game-gear
put "Shining Force" "EDITEDBYTES"
run
chk "one or more uploads" "$([ "$(posts)" -ge 1 ] && echo yes || echo no)" "yes"
carries "filed as game-gear" 'game-gear'
carries "carries the new bytes" 'EDITEDBYTES'

echo "=== S5 an emptied game folder is not a record ==="
reset
mkdir -p "$T/rsm/Sega Genesis-Mega Drive/Tecmo Super Bowl"
mk "$T/rsm/Nintendo Entertainment System/Tecmo Super Bowl/save-1-a" NESBYTES srm nes
put "Tecmo Super Bowl" "NEWERBYTES"
run
chk "an empty genesis folder does not make it genesis" "$(posts)" "0"

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
