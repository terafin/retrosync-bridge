#!/bin/bash
# A system the iPhone has no WebDAV core for must not look like an unmapped
# slug on every pass; a slug nobody has decided about still must.
set -u
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

echo "=== M3 master-system, game-gear and psp are mapped ==="
for spec in "Sega Master System/Phantasy Star:srm:master-system:Genesis Plus GX" \
            "Sega Game Gear/Shining Force:srm:game-gear:Genesis Plus GX" \
            "Sony PlayStation Portable/Dissidia:bin:psp:PPSSPP"; do
  IFS=: read -r dir ext slug core <<<"$spec"
  rm -rf /tmp/um; mkdir -p /tmp/um/webdav
  mk "/tmp/um/rsm/$dir/save-1-a" DATA "$ext" "$slug" 2026-01-01T00:00:00Z
  run
  chk "no [UNMAPPED] for $slug" "$(grep -c 'UNMAPPED' /tmp/um/log)" "0"
  chk "$slug lands under $core" "$(find "/tmp/um/webdav/$core" -type f 2>/dev/null | wc -l | tr -d ' ')" "1"
done

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
