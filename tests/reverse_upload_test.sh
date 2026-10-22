#!/bin/bash
# The iPhone path: a WebDAV write must reach the server through /saves, not by
# writing a record into the store that the server cannot read.
set -u
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }

STUB=/tmp/bt/stub; rm -rf /tmp/bt; mkdir -p /tmp/bt/webdav/mGBA "$STUB"
cat > "$STUB/server.py" <<'PY'
import http.server, json, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open("/tmp/bt/stub/requests.log", "a").write("GET " + self.path + "\n")
        body = json.dumps({"success": True, "count": 0, "rom": None}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        open("/tmp/bt/stub/requests.log", "a").write("POST " + self.path + " len=" + str(len(body)) + "\n")
        open("/tmp/bt/stub/body.bin", "wb").write(body)
        out = json.dumps({"success": True, "save": {"id": "save-x", "sha256": "sha-x", "version": 1}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(("127.0.0.1", 18777), H).serve_forever()
PY
python3 -u "$STUB/server.py" & SRV=$!
sleep 1

printf 'BINARYPAYLOAD-BRIDGE-TEST' > /tmp/bt/webdav/mGBA/ZZ-iPhone-Path-Test.srm
touch -d '+1 minute' /tmp/bt/webdav/mGBA/ZZ-iPhone-Path-Test.srm

cd /tmp && WEBDAV_SAVES=/tmp/bt/webdav RSM_SAVES=/tmp/bt/rsm RSM_URL=http://127.0.0.1:18777 \
  POLL_INTERVAL_SECS=1 timeout 4 python3 -u "$B" >/tmp/bt/bridge.log 2>&1

# The bridge polls, so a pass that cannot see the server's record (the stub
# writes none into /rsm) uploads again on the next tick. The property under
# test is that the upload happens and carries the right fields, not how many
# ticks fit in the window.
at_least_one() { if [ "$2" -ge 1 ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2')"; FAIL=1; fi; }
carries() { if grep -aq -- "$2" /tmp/bt/stub/body.bin 2>/dev/null; then echo "  PASS  $1"; else echo "  FAIL  $1 (multipart body missing)"; FAIL=1; fi; }

echo "=== U1 the save reaches the server as a multipart upload ==="
at_least_one "POST /saves happened" "$(grep -c '^POST /saves' /tmp/bt/stub/requests.log 2>/dev/null)"
at_least_one "rom lookup attempted" "$(grep -c '^GET /rom/lookup?filenameStem=ZZ-iPhone-Path-Test' /tmp/bt/stub/requests.log 2>/dev/null)"
carries "system field is gba" 'name="system"' 
carries "system value" 'gba'
carries "file bytes carried" 'BINARYPAYLOAD-BRIDGE-TEST'
carries "synthetic rom key" 'bridge:gba:zz-iphone-path-test'

echo "=== U3 no RSM_URL: one error line per file, and no request ==="
# The stub from U1 is still listening, so "no request" is observable: had the
# bridge reached anything, this log would show it.
rm -rf /tmp/bt/unset; mkdir -p /tmp/bt/unset/webdav/mGBA
printf 'BINARYPAYLOAD-NOURL' > /tmp/bt/unset/webdav/mGBA/ZZ-No-Url.srm
: > /tmp/bt/stub/requests.log
cd /tmp && WEBDAV_SAVES=/tmp/bt/unset/webdav RSM_SAVES=/tmp/bt/unset/rsm \
  POLL_INTERVAL_SECS=60 timeout 2 python3 -u "$B" >/tmp/bt/unset.bridge.log 2>&1
chk "one [ERR] RSM_URL line" "$(grep -c 'RSM_URL is not set' /tmp/bt/unset.bridge.log)" "1"
chk "no request attempted" "$(grep -cE '^(GET|POST) ' /tmp/bt/stub/requests.log)" "0"
chk "nothing written to the store" "$(find /tmp/bt/unset/rsm -name 'payload.*' 2>/dev/null | wc -l | tr -d ' ')" "0"
kill $SRV 2>/dev/null

echo "=== U2 the bridge writes nothing into the store itself ==="
chk "no store record created" "$(find /tmp/bt/rsm -name 'payload.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
