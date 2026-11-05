#!/bin/bash
# DRY_RUN=1 makes one pass over the real trees and acts on nothing: no request
# reaches RSM, the WebDAV tree is byte-identical afterwards, and every action it
# would have taken is named. A dry run that read nothing must say so and fail,
# or a wrong mount would look like a clean result.
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
T="${TMPDIR:-/tmp}/rsb-dry-run.$$"; STUB="$T/stub"; PORT=18782
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT

chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }
reqs() { wc -l < "$STUB/requests.log" 2>/dev/null | tr -d ' '; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"2026-01-01T00:00:00Z"}' "$4" > "$1/metadata.json"; touch -d '2026-01-01' "$1/payload.$3"; }
tree_sum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum; find . -type d | sort) | sha256sum | cut -d' ' -f1; }

mkdir -p "$STUB"
cat > "$STUB/server.py" <<PY
import json, http.server, sys
L = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _log(self): open(L + "/requests.log", "a").write(self.command + " " + self.path + "\n")
    def do_GET(self):
        self._log(); body = json.dumps({"success": True, "count": 0, "rom": None}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self._log(); n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        out = json.dumps({"success": True, "save": {"id": "save-x", "sha256": "s", "version": 1}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(("127.0.0.1", $PORT), H).serve_forever()
PY
python3 -u "$STUB/server.py" "$STUB" & SRV=$!
sleep 1

# A fixture with one action each way: an iPhone save the store lacks (upload),
# and a store save the iPhone lacks (write).
fixture() {
  rm -rf "$T/web" "$T/rsm"; mkdir -p "$T/web/Snes9x"
  printf 'NEWKART' > "$T/web/Snes9x/Super Mario Kart.srm"
  mk "$T/rsm/Nintendo Super Nintendo Entertainment System/F-Zero/save-1-a" FZEROBYTES srm snes
}
run() { : > "$STUB/requests.log"; (cd "$T" && WEBDAV_SAVES="$T/web" RSM_SAVES="$T/rsm" RSM_URL=http://127.0.0.1:$PORT POLL_INTERVAL_SECS=1 "$@" timeout 5 python3 -u "$B" >"$T/bridge.log" 2>&1; echo $? > "$T/rc"); }

echo "=== D1 DRY_RUN=1: nothing reaches RSM, nothing is written, every action named ==="
# tree_sum hashes every file and directory under the WebDAV tree, before and after.
fixture; before="$(tree_sum "$T/web")"
run env DRY_RUN=1
chk "no request reached RSM" "$(reqs)" "0"
chk "WebDAV tree byte-identical" "$(tree_sum "$T/web")" "$before"
chk "names the upload" "$(grep -c '^\[DRY-RUN\]   would upload Snes9x/Super Mario Kart.srm -> snes/Super Mario Kart$' "$T/bridge.log")" "1"
chk "names the write" "$(grep -c '^\[DRY-RUN\]   would write Snes9x/F-Zero.srm <- Nintendo Super Nintendo Entertainment System/F-Zero$' "$T/bridge.log")" "1"
chk "exits 0 after one pass" "$(cat "$T/rc")" "0"

echo "=== D2 the same fixture without DRY_RUN acts ==="
fixture
run env
chk "the upload is posted" "$([ "$(grep -c "^POST /saves" "$STUB/requests.log")" -ge 1 ] && echo yes || echo no)" "yes"
chk "the write lands" "$([ -f "$T/web/Snes9x/F-Zero.srm" ] && echo yes || echo no)" "yes"

echo "=== D3 a dry run that reads nothing says so and fails ==="
rm -rf "$T/web" "$T/rsm"; mkdir -p "$T/web" "$T/rsm"
run env DRY_RUN=1
chk "says it found nothing" "$(grep -c '^\[DRY-RUN\] found nothing to read' "$T/bridge.log")" "1"
chk "does not exit 0" "$([ "$(cat "$T/rc")" != 0 ] && echo nonzero || echo zero)" "nonzero"

echo "=== D5 an empty store with WebDAV saves warns ==="
fixture; rm -rf "$T/rsm"; mkdir -p "$T/rsm"
run env DRY_RUN=1
chk "warns about the /rsm mount" "$(grep -c '^\[DRY-RUN\] WARNING: the store read no payloads while WebDAV read 1 save(s)' "$T/bridge.log")" "1"
chk "still names the upload" "$(grep -c '^\[DRY-RUN\]   would upload Snes9x/Super Mario Kart.srm' "$T/bridge.log")" "1"
chk "no request reached RSM" "$(reqs)" "0"

echo "=== D4 a dry run still refuses a bad layout ==="
fixture
(cd "$T" && WEBDAV_SAVES="$T" RSM_SAVES="$T" RSM_URL=http://127.0.0.1:$PORT DRY_RUN=1 timeout 5 python3 -u "$B" >"$T/bridge.log" 2>&1; echo $? > "$T/rc")
chk "refuses before reading" "$(grep -c '^\[ERR\] not syncing' "$T/bridge.log")" "1"
chk "does not exit 0" "$([ "$(cat "$T/rc")" != 0 ] && echo nonzero || echo zero)" "nonzero"

[ $FAIL = 0 ] && echo "ALL PASS" || echo "FAILURES PRESENT"; exit $FAIL
