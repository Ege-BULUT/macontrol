#!/bin/bash
# Compiles GP's tree model + layout (from the gitignored clone) with the probe and finds the
# nesting depth at which laying out crashes on a default-size NSThread stack.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GP="$HERE/../../sources/sourceforge-net-p-grandperspectiv-source"
OUT="${TMPDIR:-/tmp}/gp_layout_probe"
OPT="${OPT:--Os}"
SRCS="tree/Item.m tree/FileItem.m tree/DirectoryItem.m tree/PlainFileItem.m tree/CompoundItem.m
      tree/TreeBalancer.m tree/TreeLayoutBuilder.m util/PeekingEnumerator.m
      util/UniformTypeInventory.m util/UniformType.m util/LogManager.m"
INC=""; for d in tree util control view task filter mapping io test test/strings; do INC="$INC -I$GP/$d"; done
( cd "$GP" && clang $OPT -fno-objc-arc -fobjc-weak -fmodules -include "$GP/GrandPerspective_Prefix.pch" $INC \
    $SRCS "$HERE/layout_depth_probe.m" -framework Cocoa -framework UniformTypeIdentifiers -o "$OUT" ) || exit 1
MODE="${MODE:-}"
for n in ${DEPTHS:-500 1000 2000 4000 8000}; do
  printf 'depth %5s  main: ' "$n"; "$OUT" "$n" main $MODE >/dev/null 2>&1 && printf 'ok   ' || printf 'CRASH(%s) ' $?
  printf 'thread: '; "$OUT" "$n" thread $MODE >/dev/null 2>&1 && echo ok || echo "CRASH($?)"
done
