#!/bin/bash
set -u
B="$1"; FAIL=0
run() { cd /tmp && WEBDAV_SAVES=/tmp/bt/webdav RSM_SAVES=/tmp/bt/rsm POLL_INTERVAL_SECS=1 timeout 4 python3 -u "$B" >/tmp/bt/run.log 2>&1; }
mk() { mkdir -p "$1"; printf '%s' "$2" > "$1/payload.$3"; printf '{"systemSlug":"%s","uploadedAt":"%s"}' "$4" "$5" > "$1/metadata.json"; }
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2' want '$3')"; FAIL=1; fi; }

rm -rf /tmp/bt; mkdir -p /tmp/bt/webdav
# Two DIFFERENTLY-NAMED system folders for the same game, different bytes,
# both mapping to core Snes9x. The live-store collision.
mk "/tmp/bt/rsm/SNES/Game/save-1-a"   OLD srm snes 2026-01-01T00:00:00Z
mk "/tmp/bt/rsm/Nintendo Super Nintendo Entertainment System/Game/save-2-b" NEW srm snes 2026-01-09T00:00:00Z

run
echo "--- pass 1 ---"
chk "one destination file" "$(find /tmp/bt/webdav -name 'Game.srm' | wc -l)" "1"
chk "newer record won"     "$(cat /tmp/bt/webdav/Snes9x/Game.srm 2>/dev/null)" "NEW"
N1=$(grep -c "RSM->WEBDAV" /tmp/bt/run.log 2>/dev/null); echo "  (copies this pass: $N1)"

cp -r /tmp/bt/webdav /tmp/bt/snap
run
echo "--- pass 2 (must write nothing) ---"
if diff -r /tmp/bt/snap /tmp/bt/webdav >/dev/null 2>&1; then echo "  PASS  destination unchanged"; else echo "  FAIL  destination rewritten"; FAIL=1; fi
N2=$(grep -c "RSM->WEBDAV" /tmp/bt/run.log 2>/dev/null); chk "no copies on pass 2" "$N2" "0"

echo "--- real change still copies (negative test: a stopped bridge must not pass) ---"
mk "/tmp/bt/rsm/Nintendo Super Nintendo Entertainment System/Game/save-2-b" CHANGED srm snes 2026-01-20T00:00:00Z
run
chk "real change propagated" "$(cat /tmp/bt/webdav/Snes9x/Game.srm 2>/dev/null)" "CHANGED"

echo; [ "$FAIL" = "0" ] && echo "COLLIDE PASS" || { echo "COLLIDE FAIL"; exit 1; }
