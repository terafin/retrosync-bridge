#!/bin/bash
# The iPhone path: a WebDAV write must reach the server through /saves, not by
# writing a record into the store that the server cannot read.
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }

# A scratch tree per run: suites that share one fixed path delete each other's
# files when two run at once.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STUB=$T/stub; SERVER=$T/server.py; mkdir -p $T/webdav/mGBA "$STUB"
cat > "$SERVER" <<'PY'
import http.server, json, os, sys
LOG = sys.argv[1]
# Only the bridge's own routes are logged. Other local processes probe open
# ports with "GET /" (seen: a host daemon's health probe), and such a request
# is not the bridge reaching the server.
def ours(path): return path.startswith(("/saves", "/rom/"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if ours(self.path): open(LOG + "/requests.log", "a").write("GET " + self.path + "\n")
        body = json.dumps({"success": True, "count": 0, "rom": None}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        if ours(self.path):
            open(LOG + "/requests.log", "a").write("POST " + self.path + " len=" + str(len(body)) + "\n")
            open(LOG + "/body.bin", "wb").write(body)
        out = json.dumps({"success": True, "save": {"id": "save-x", "sha256": "sha-x", "version": 1}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
# Port 0: the OS picks a free port, written out for the case to read. A fixed
# port also receives whatever else on the host probes it, and a stray request
# there reads as the bridge contacting a server it was told nothing about.
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(LOG + "/port", "w").write(str(srv.server_port))
srv.serve_forever()
PY
# Each case gets its own stub process, port and log, so nothing a previous case
# or another process sent can land in the case being checked.
start_stub() {
  rm -rf "$1"; mkdir -p "$1"; python3 -u "$SERVER" "$1" & SRV=$!
  for _ in $(seq 50); do [ -s "$1/port" ] && { PORT=$(cat "$1/port"); return; }; sleep 0.1; done
  echo "stub did not start"; exit 2
}
stop_stub() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
start_stub "$STUB"

# mGBA runs Game Boy and GBA, so only a size no Game Boy cartridge has (64 KiB
# flash) lets the bridge file a save it has no record of as gba.
{ printf 'BINARYPAYLOAD-BRIDGE-TEST'; head -c $((65536 - 25)) /dev/zero; } > $T/webdav/mGBA/ZZ-iPhone-Path-Test.srm
touch -d '+1 minute' $T/webdav/mGBA/ZZ-iPhone-Path-Test.srm

cd "$T" && WEBDAV_SAVES=$T/webdav RSM_SAVES=$T/rsm RSM_URL=http://127.0.0.1:$PORT \
  POLL_INTERVAL_SECS=1 timeout 4 python3 -u "$B" >$T/bridge.log 2>&1

# The bridge polls, so a pass that cannot see the server's record (the stub
# writes none into /rsm) uploads again on the next tick. The property under
# test is that the upload happens and carries the right fields, not how many
# ticks fit in the window.
at_least_one() { if [ "${2:-0}" -ge 1 ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2')"; FAIL=1; fi; }
carries() { if grep -aq -- "$2" $T/stub/body.bin 2>/dev/null; then echo "  PASS  $1"; else echo "  FAIL  $1 (multipart body missing)"; FAIL=1; fi; }

echo "=== U1 the save reaches the server as a multipart upload ==="
at_least_one "POST /saves happened" "$(grep -c '^POST /saves' $T/stub/requests.log 2>/dev/null)"
at_least_one "rom lookup attempted" "$(grep -c '^GET /rom/lookup?filenameStem=ZZ-iPhone-Path-Test' $T/stub/requests.log 2>/dev/null)"
carries "system field is gba" 'name="system"' 
carries "system value" 'gba'
carries "file bytes carried" 'BINARYPAYLOAD-BRIDGE-TEST'
carries "synthetic rom key" 'bridge:gba:zz-iphone-path-test'

stop_stub

echo "=== U3 no RSM_URL: one error line per file, and no request ==="
# A fresh stub on its own port, so this log holds only what this case sends:
# had the bridge reached a server without RSM_URL, it would show here.
rm -rf $T/unset; mkdir -p $T/unset/webdav/mGBA
{ printf 'BINARYPAYLOAD-NOURL'; head -c $((65536 - 19)) /dev/zero; } > $T/unset/webdav/mGBA/ZZ-No-Url.srm
start_stub $T/unset/stub; : > $T/unset/stub/requests.log
cd "$T" && WEBDAV_SAVES=$T/unset/webdav RSM_SAVES=$T/unset/rsm \
  POLL_INTERVAL_SECS=60 timeout 2 python3 -u "$B" >$T/unset.bridge.log 2>&1
chk "one [ERR] RSM_URL line" "$(grep -c 'RSM_URL is not set' $T/unset.bridge.log)" "1"
chk "no request attempted" "$(grep -cE '^(GET|POST) ' $T/unset/stub/requests.log)" "0"
chk "nothing written to the store" "$(find $T/unset/rsm -name 'payload.*' 2>/dev/null | wc -l | tr -d ' ')" "0"
stop_stub

echo "=== U2 the bridge writes nothing into the store itself ==="
chk "no store record created" "$(find $T/rsm -name 'payload.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
