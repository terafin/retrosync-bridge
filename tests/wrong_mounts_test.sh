#!/bin/bash
# The bridge's two mounts are subpaths of one volume. Started without them, /webdav
# and /rsm were the volume's root: the store's records sat a level below where
# records_for() looked, so none were found and every WebDAV save was uploaded again.
# A pass that cannot see the store must not upload.
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
T="${TMPDIR:-/tmp}/rsb-wrong-mounts.$$"; STUB="$T/stub"; PORT=18781
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT

chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }
posts() { grep -c '^POST /saves' "$STUB/requests.log" 2>/dev/null || true; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"2026-01-01T00:00:00Z"}' "$4" > "$1/metadata.json"; touch -d '2026-01-01' "$1/payload.$3"; }

mkdir -p "$STUB"
cat > "$STUB/server.py" <<PY
import json, http.server, sys
L = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"success": True, "count": 0, "rom": None}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        open(L + "/requests.log", "a").write("POST " + self.path + "\n")
        out = json.dumps({"success": True, "save": {"id": "save-x", "sha256": "s", "version": 1}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(("127.0.0.1", $PORT), H).serve_forever()
PY
python3 -u "$STUB/server.py" "$STUB" & SRV=$!
sleep 1

# The volume as the live share holds it: the two trees one level down.
V="$T/volume"
mkdir -p "$V/save/retroarch-webdav/saves/Snes9x"
printf 'KARTBYTES' > "$V/save/retroarch-webdav/saves/Snes9x/Super Mario Kart.srm"
touch -d '+1 minute' "$V/save/retroarch-webdav/saves/Snes9x/Super Mario Kart.srm"
mk "$V/save/retrogamesaves/Nintendo Super Nintendo Entertainment System/Super Mario Kart/save-1-a" KARTBYTES sav snes
run() { : > "$STUB/requests.log"; (cd "$T" && WEBDAV_SAVES="$1" RSM_SAVES="$2" RSM_URL=http://127.0.0.1:$PORT POLL_INTERVAL_SECS=1 timeout 3 python3 -u "$B" >"$T/bridge.log" 2>&1); }

echo "=== M1 both mounts at the volume root: nothing is uploaded ==="
run "$V" "$V"
chk "no upload when the store is not at /rsm" "$(posts)" "0"
chk "says why" "$(grep -q '^\[ERR\] not syncing' "$T/bridge.log" && echo yes || echo no)" "yes"

echo "=== M2 the right subpaths: the save the store already holds is skipped ==="
run "$V/save/retroarch-webdav/saves" "$V/save/retrogamesaves"
chk "no upload of bytes the store holds" "$(posts)" "0"
chk "the pass runs" "$(grep -q '^\[SYNC\] Running sync pass' "$T/bridge.log" && echo yes || echo no)" "yes"

[ $FAIL = 0 ] && echo "ALL PASS" || echo "FAILURES PRESENT"; exit $FAIL
