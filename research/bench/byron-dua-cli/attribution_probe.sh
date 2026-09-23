#!/bin/bash
# Probe for Byron/dua-cli 2.45.0 (Homebrew `dua`), source @cf59618.
# Q1: is a shared hard link / full APFS clone charged to the same folder on identical re-runs?
# Q2 (optional, needs pyte): does TUI "refresh selected" (r) count a hard link a second time?
# Builds its own fixture in a temp dir (APFS needed for cp -c). Never touches user folders.
# Usage: attribution_probe.sh [runs]     (default 30)
set -u
RUNS=${1:-30}
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d "${TMPDIR:-/tmp}/dua-attr.XXXXXX")
mkdir -p "$D/hl/A" "$D/hl/B" "$D/cl/A" "$D/cl/B" "$D/src"
head -c 8388608 /dev/urandom > "$D/src/blob.bin"
for d in hl/A hl/B cl/A cl/B; do
  for i in $(seq 1 40); do printf '%200s' x > "$D/$d/f$i.txt"; done
done
cp "$D/src/blob.bin" "$D/hl/A/big.bin"; ln "$D/hl/A/big.bin" "$D/hl/B/big.bin"
cp -c "$D/src/blob.bin" "$D/cl/A/big.bin"; cp -c "$D/src/blob.bin" "$D/cl/B/big.bin"
cd "$D" || exit 1
owner() { awk '$3=="A"{a=$1} $3=="B"{b=$1} END{print (a>b?"A":"B"), "A="a, "B="b}'; }
echo "dua: $(dua --version)   runs: $RUNS   du -sk: $(du -sk hl | cut -f1) KiB (hl)"
echo "== Q1a hard link: dua -f bytes aggregate --depth 2 hl -> folder charged 8 MiB"
for i in $(seq 1 "$RUNS"); do dua -f bytes aggregate --depth 2 hl 2>/dev/null | owner; done | sort | uniq -c
echo "== Q1b full clones: dua -f bytes --deduplicate-apfs-clones aggregate --depth 2 cl"
for i in $(seq 1 "$RUNS"); do dua -f bytes --deduplicate-apfs-clones aggregate --depth 2 cl 2>/dev/null | owner; done | sort | uniq -c
if [ -x "$HERE/venv/bin/python" ]; then
  echo "== Q2 TUI: initial vs after 'jr' (select 2nd row, refresh selected)"
  for k in "" "jr"; do echo "keys='$k'"; "$HERE/venv/bin/python" "$HERE/pty_once.py" "$k" hl | grep -E '\| /[AB]|Total disk'; done
else
  echo "== Q2 skipped: python3 -m venv $HERE/venv && $HERE/venv/bin/pip install pyte"
fi
/bin/rm -rf "$D"
