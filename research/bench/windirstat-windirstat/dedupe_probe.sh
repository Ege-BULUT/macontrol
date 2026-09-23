#!/bin/bash
# Probe: what does "replace a duplicate with a hard link" do to the replaced file on APFS,
# compared with replacing it by an APFS clone? Mirrors the shape of WinDirStat's
# CreateHardlinkFromFile (windirstat@da13ad6 HelpersTasks.cpp:688-704: link source to a temp
# name next to the target, then rename over the target). Runs only inside a scratch dir.
set -euo pipefail
D="${1:?usage: dedupe_probe.sh <scratch dir>}"
/bin/rm -rf "$D"; mkdir -p "$D"; cd "$D"

show() { stat -f '%N inode=%i links=%l mode=%Sp mtime=%Sm size=%z' "$@"; }

for mode in hardlink clone clone-noedit; do
  mkdir "$mode"; cd "$mode"
  head -c 1048576 /dev/zero > keep.bin            # the "source" the tool keeps
  head -c 1048576 /dev/zero > dup.bin             # identical bytes, different owner-visible metadata
  chmod 600 dup.bin; touch -t 202001010000 dup.bin
  echo "== $mode: before"; show keep.bin dup.bin
  echo "   (scan-time hash taken here; now another process edits dup.bin, same size)"
  [ "$mode" = clone-noedit ] || printf 'X' | dd of=dup.bin bs=1 seek=0 conv=notrunc 2>/dev/null
  cmp -s keep.bin dup.bin && echo "   dup.bin still identical" || echo "   dup.bin now DIFFERS from keep.bin"
  if [ "$mode" = hardlink ]; then
    ln keep.bin .dup.tmp && mv -f .dup.tmp dup.bin          # WinDirStat shape: no re-check
  else
    # macontrol shape: byte-compare right before the swap, clone, keep the target's metadata
    if cmp -s keep.bin dup.bin; then
      cp -c keep.bin .dup.tmp && chmod "$(stat -f %Lp dup.bin)" .dup.tmp && touch -r dup.bin .dup.tmp && mv -f .dup.tmp dup.bin
    else echo "   re-check failed: dup.bin left untouched"; fi
  fi
  echo "== $mode: after replace"; show keep.bin dup.bin
  [ "$mode" = clone-noedit ] || { grep -q X dup.bin && echo "   dup.bin edit survived" || echo "   dup.bin edit LOST"; }
  printf 'Y' >> keep.bin
  echo "== $mode: after appending 1 byte to keep.bin"; show dup.bin
  cd ..
done
