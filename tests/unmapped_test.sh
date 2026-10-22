#!/bin/bash
# A system the iPhone has no WebDAV core for must not look like an unmapped
# slug on every pass; a slug nobody has decided about still must.
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"%s"}' "$4" "$5" > "$1/metadata.json"; }
run() { cd /tmp && WEBDAV_SAVES=/tmp/um/webdav RSM_SAVES=/tmp/um/rsm POLL_INTERVAL_SECS=60 timeout 2 python3 -u "$B" >/tmp/um/log 2>&1; }

echo "=== M1 arcade is skipped without a warning ==="
rm -rf /tmp/um; mkdir -p /tmp/um/webdav
mk "/tmp/um/rsm/Arcade/galaga/save-1-a" EEP eep arcade 2026-01-01T00:00:00Z
run
chk "no [UNMAPPED] for arcade" "$(grep -c 'UNMAPPED' /tmp/um/log)" "0"
chk "nothing written to WebDAV" "$(find /tmp/um/webdav -type f | wc -l | tr -d ' ')" "0"

echo "=== M2 a genuinely unmapped slug still warns ==="
rm -rf /tmp/um; mkdir -p /tmp/um/webdav
mk "/tmp/um/rsm/Sega Dreamcast/Sonic/save-1-a" VMS vms dreamcast 2026-01-01T00:00:00Z
run
chk "warning for dreamcast" "$(grep -c "UNMAPPED.*dreamcast" /tmp/um/log)" "1"

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
