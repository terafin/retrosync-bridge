#!/bin/bash
# A save arriving from a RetroArch core folder is filed through the server, and
# a save whose bytes the store already holds is not filed again. Content is the
# discriminator; the core folder is only a hint at the system.
set -u
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
SNES="Nintendo Super Nintendo Entertainment System"
STUB=/tmp/ct/stub

chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }
posts() { grep -c '^POST /saves' "$STUB/requests.log" 2>/dev/null || true; }
# The stub stores nothing in /rsm, so a pass that cannot see the server's record
# uploads again on the next tick; the property under test is whether an upload
# happens with the right content, not how many ticks fit in the window.
at_least_one() { if [ "$2" -ge 1 ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2')"; FAIL=1; fi; }
carries() { if grep -aq -- "$2" "$STUB/body.bin" 2>/dev/null; then echo "  PASS  $1"; else echo "  FAIL  $1 (multipart body missing)"; FAIL=1; fi; }

reset() {
  rm -rf /tmp/ct; mkdir -p /tmp/ct/webdav "$STUB"
  : > "$STUB/requests.log"; rm -f "$STUB/body.bin"
  cat > "$STUB/server.py" <<'PY'
import json, http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open("/tmp/ct/stub/requests.log", "a").write("GET " + self.path + "\n")
        body = json.dumps({"success": True, "count": 0, "rom": None}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        open("/tmp/ct/stub/requests.log", "a").write("POST " + self.path + "\n")
        open("/tmp/ct/stub/body.bin", "wb").write(body)
        out = json.dumps({"success": True, "save": {"id": "save-x", "sha256": "s", "version": 1}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(("127.0.0.1", 18778), H).serve_forever()
PY
  python3 -u "$STUB/server.py" & SRV=$!
  sleep 1
}
run() { cd /tmp && WEBDAV_SAVES=/tmp/ct/webdav RSM_SAVES=/tmp/ct/rsm RSM_URL=http://127.0.0.1:18778 POLL_INTERVAL_SECS=1 timeout 3 python3 -u "$B" >/dev/null 2>&1; }
finish_stub() { kill $SRV 2>/dev/null; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"%s"}' "$4" "$5" > "$1/metadata.json"; }

echo "=== X1 bytes the store already holds are not filed again ==="
reset
mk "/tmp/ct/rsm/$SNES/F-Zero/save-1-a" SNESBYTES srm snes 2026-01-01T00:00:00Z
mkdir -p /tmp/ct/webdav/Gambatte
printf 'SNESBYTES' > "/tmp/ct/webdav/Gambatte/F-Zero.srm"
touch -d '+1 minute' "/tmp/ct/webdav/Gambatte/F-Zero.srm"
run; finish_stub
chk "no upload for byte-identical save" "$(posts)" "0"
chk "SNES record intact" "$(cat "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/payload.srm")" "SNESBYTES"

echo "=== X2 a genuinely new game is filed with its system and bytes ==="
reset
mk "/tmp/ct/rsm/$SNES/F-Zero/save-1-a" SNESBYTES srm snes 2026-01-01T00:00:00Z
mkdir -p /tmp/ct/webdav/Gambatte
printf 'GBBYTES' > "/tmp/ct/webdav/Gambatte/Tetris.srm"
touch -d '+1 minute' "/tmp/ct/webdav/Gambatte/Tetris.srm"
run; finish_stub
at_least_one "an upload happened" "$(posts)"
carries "declares gameboy" 'name="system"'
carries "system value" 'gameboy'
carries "carries the bytes" 'GBBYTES'

echo "=== X3 same name, different bytes: the new content is what is filed ==="
reset
mk "/tmp/ct/rsm/$SNES/F-Zero/save-1-a" SNESBYTES srm snes 2026-01-01T00:00:00Z
mkdir -p /tmp/ct/webdav/Gambatte
printf 'DIFFERENTBYTES' > "/tmp/ct/webdav/Gambatte/F-Zero.srm"
touch -d '+1 minute' "/tmp/ct/webdav/Gambatte/F-Zero.srm"
run; finish_stub
at_least_one "an upload happened" "$(posts)"
carries "carries the different bytes" 'DIFFERENTBYTES'
chk "SNES record untouched" "$(cat "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/payload.srm")" "SNESBYTES"

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
