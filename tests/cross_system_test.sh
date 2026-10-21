#!/bin/bash
# A save that already exists in the store under one system must not be filed
# again under another system just because RetroArch keeps a copy in a second
# core folder. Content is the discriminator; the folder is a hint.
set -u
B="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; FAIL=0
SNES="Nintendo Super Nintendo Entertainment System"
GB="Nintendo Game Boy"
run() { cd /tmp && WEBDAV_SAVES=/tmp/ct/webdav RSM_SAVES=/tmp/ct/rsm POLL_INTERVAL_SECS=1 timeout 4 python3 -u "$B" >/dev/null 2>&1; }
reset() { rm -rf /tmp/ct; mkdir -p /tmp/ct/webdav; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"%s"}' "$4" "$5" > "$1/metadata.json"; }
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }

echo "=== X1 same bytes in a second core folder land on the existing record ==="
reset
mk "/tmp/ct/rsm/$SNES/F-Zero/save-1-a" SNESBYTES srm snes 2026-01-01T00:00:00Z
mkdir -p /tmp/ct/webdav/Gambatte
printf 'SNESBYTES' > "/tmp/ct/webdav/Gambatte/F-Zero.srm"
run
chk "no Game Boy record created" "$(ls -d "/tmp/ct/rsm/$GB/F-Zero" 2>/dev/null)" ""
chk "SNES record intact" "$(cat "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/payload.srm")" "SNESBYTES"
chk "one record dir for the game" "$(find /tmp/ct/rsm -type d -name 'save-*' | wc -l | tr -d ' ')" "1"

echo "=== X2 a genuinely new game in a core folder still creates its record ==="
reset
mkdir -p "/tmp/ct/rsm/$SNES/F-Zero/save-1-a"
printf 'SNESBYTES' > "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/payload.srm"
printf '{"systemSlug":"snes","uploadedAt":"2026-01-01T00:00:00Z"}' > "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/metadata.json"
mkdir -p /tmp/ct/webdav/Gambatte
printf 'GBBYTES' > "/tmp/ct/webdav/Gambatte/Tetris.srm"
run
chk "Game Boy record created" "$(cat /tmp/ct/rsm/"$GB"/Tetris/save-*/payload.srm 2>/dev/null)" "GBBYTES"
chk "its slug is gameboy" "$(cat /tmp/ct/rsm/"$GB"/Tetris/save-*/metadata.json 2>/dev/null | grep -o '"systemSlug": *"[a-z]*"')" '"systemSlug": "gameboy"'

echo "=== X3 same name, different bytes: two records are still allowed ==="
reset
mkdir -p "/tmp/ct/rsm/$SNES/F-Zero/save-1-a"
printf 'SNESBYTES' > "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/payload.srm"
printf '{"systemSlug":"snes","uploadedAt":"2026-01-01T00:00:00Z"}' > "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/metadata.json"
mkdir -p /tmp/ct/webdav/Gambatte
printf 'DIFFERENTBYTES' > "/tmp/ct/webdav/Gambatte/F-Zero.srm"
run
chk "Game Boy record created for different content" "$(cat /tmp/ct/rsm/"$GB"/F-Zero/save-*/payload.srm 2>/dev/null)" "DIFFERENTBYTES"
chk "SNES record untouched" "$(cat "/tmp/ct/rsm/$SNES/F-Zero/save-1-a/payload.srm")" "SNESBYTES"

echo; [ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILURES PRESENT"
exit "$FAIL"
