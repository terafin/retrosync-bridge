#!/bin/bash
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$1"; FAIL=0
SYS="Nintendo Super Nintendo Entertainment System"
run() { cd /tmp && WEBDAV_SAVES=/tmp/bt/webdav RSM_SAVES=/tmp/bt/rsm POLL_INTERVAL_SECS=1 timeout 4 python3 -u "$B" >/dev/null 2>&1; }
reset() { rm -rf /tmp/bt; mkdir -p /tmp/bt/webdav; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"%s"}' "$4" "$5" > "$1/metadata.json"; }
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }

echo "=== F1 same dir .srm+.sav -> two files ==="
reset; mk "/tmp/bt/rsm/$SYS/Alpha/save-1-a" SRM srm snes 2026-01-01T00:00:00Z
mk "/tmp/bt/rsm/$SYS/Alpha/save-1-a" SAV sav snes 2026-01-01T00:00:00Z
run; chk "Alpha.srm" "$(cat /tmp/bt/webdav/Snes9x/Alpha.srm 2>/dev/null)" "SRM"
chk "Alpha.sav" "$(cat /tmp/bt/webdav/Snes9x/Alpha.sav 2>/dev/null)" "SAV"

echo "=== F2 sibling .srm + .rtc (both orderings) ==="
for order in "SRM srm RTC rtc" "RTC rtc SRM srm"; do
  set -- $order
  reset; mk "/tmp/bt/rsm/$SYS/Beta/save-1-a" "$1" "$2" snes 2026-01-01T00:00:00Z
  mk "/tmp/bt/rsm/$SYS/Beta/save-2-b" "$3" "$4" snes 2026-01-02T00:00:00Z
  run
  chk "order($1/$3).srm" "$(cat /tmp/bt/webdav/Snes9x/Beta.srm 2>/dev/null)" "SRM"
  chk "order($1/$3).rtc" "$(cat /tmp/bt/webdav/Snes9x/Beta.rtc 2>/dev/null)" "RTC"
done

echo "=== F3 sibling .srm/.srm -> newer record wins ==="
reset; mk "/tmp/bt/rsm/$SYS/Gamma/save-1-a" OLD srm snes 2026-01-04T00:00:00Z
mk "/tmp/bt/rsm/$SYS/Gamma/save-2-b" NEW srm snes 2026-01-05T00:00:00Z
run; chk "Gamma.srm newer" "$(cat /tmp/bt/webdav/Snes9x/Gamma.srm 2>/dev/null)" "NEW"

echo "=== R1 reverse must not destroy a different component ==="
reset; mkdir -p /tmp/bt/webdav/Snes9x
D="/tmp/bt/rsm/$SYS/Game/save-1-a"; mkdir -p "$D"
printf 'SAVDATA' > "$D/payload.sav"; printf 'SRMDATA' > "$D/payload.srm"
printf '{"systemSlug":"snes","uploadedAt":"2026-01-01T00:00:00Z"}' > "$D/metadata.json"
printf 'SAVDATA' > "/tmp/bt/webdav/Snes9x/Game.srm"
run; run
chk "sav intact" "$(cat "$D/payload.sav" 2>/dev/null)" "SAVDATA"
chk "srm intact" "$(cat "$D/payload.srm" 2>/dev/null)" "SRMDATA"

echo "=== F4 idempotency ==="
reset; mk "/tmp/bt/rsm/$SYS/Delta/save-1-a" D1 srm snes 2026-01-01T00:00:00Z
run; cp -r /tmp/bt/webdav /tmp/bt/snap; run
if diff -r /tmp/bt/snap /tmp/bt/webdav >/dev/null 2>&1; then echo "  PASS  second pass identical"; else echo "  FAIL  second pass changed"; FAIL=1; fi

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
