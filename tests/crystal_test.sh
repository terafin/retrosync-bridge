#!/bin/bash
set -u
[ $# -ge 1 ] || { echo "usage: $0 <path to bridge.py>"; exit 2; }
B="$1"; SYS="Nintendo Super Nintendo Entertainment System"
run() { cd /tmp && WEBDAV_SAVES=/tmp/bt/webdav RSM_SAVES=/tmp/bt/rsm POLL_INTERVAL_SECS=1 timeout 4 python3 -u "$B" >/dev/null 2>&1; }
rm -rf /tmp/bt; mkdir -p /tmp/bt/webdav/Snes9x
# Crystal shape: .srm in save-b1, .rtc alone in save-b2
mkdir -p "/tmp/bt/rsm/$SYS/Crystal/save-b1" "/tmp/bt/rsm/$SYS/Crystal/save-b2"
printf 'CRYSTAL' > "/tmp/bt/rsm/$SYS/Crystal/save-b1/payload.srm"
printf '{"systemSlug":"snes","uploadedAt":"2026-01-01T00:00:00Z"}' > "/tmp/bt/rsm/$SYS/Crystal/save-b1/metadata.json"
printf 'CLOCK' > "/tmp/bt/rsm/$SYS/Crystal/save-b2/payload.rtc"
printf '{"systemSlug":"snes","uploadedAt":"2026-01-02T00:00:00Z"}' > "/tmp/bt/rsm/$SYS/Crystal/save-b2/metadata.json"
snap() { find /tmp/bt -type f | sort | while read f; do echo "$f:$(md5sum "$f"|cut -c1-8)"; done; }
run; A=$(snap); run; Bs=$(snap); run; C=$(snap)
echo "--- .srm copies under the game (should be exactly 1) ---"
echo "  $(find "/tmp/bt/rsm/$SYS/Crystal" -name 'payload.srm' | wc -l)"
echo "--- rtc dir untouched? ---"
echo "  save-b2 contents: $(ls "/tmp/bt/rsm/$SYS/Crystal/save-b2")"
FAIL=0
echo "--- stability ---"
[ "$A" = "$Bs" ] && echo "  pass1==pass2" || { echo "  pass1!=pass2"; FAIL=1; }
[ "$Bs" = "$C" ] && echo "  pass2==pass3" || { echo "  pass2!=pass3"; FAIL=1; }
[ "$FAIL" = "0" ] && echo "CRYSTAL PASS" || { echo "CRYSTAL FAIL"; exit 1; }
