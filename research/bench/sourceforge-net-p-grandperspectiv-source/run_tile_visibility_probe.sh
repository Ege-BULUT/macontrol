#!/bin/bash
# Usage: run_tile_visibility_probe.sh <folder> [width height]   (defaults: GP's default window 1168x688)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GP="$HERE/../../sources/sourceforge-net-p-grandperspectiv-source"
OUT="${TMPDIR:-/tmp}/gp_tile_probe"
INC=""; for d in tree util control view task filter mapping io test test/strings; do INC="$INC -I$GP/$d"; done
( cd "$GP" && clang -Os -fno-objc-arc -fobjc-weak -fmodules -include "$GP/GrandPerspective_Prefix.pch" $INC \
    tree/Item.m tree/FileItem.m tree/DirectoryItem.m tree/PlainFileItem.m tree/CompoundItem.m \
    tree/TreeBalancer.m tree/TreeLayoutBuilder.m util/PeekingEnumerator.m \
    util/UniformTypeInventory.m util/UniformType.m util/LogManager.m \
    "$HERE/tile_visibility_probe.m" -framework Cocoa -framework UniformTypeIdentifiers -o "$OUT" 2>/dev/null ) || exit 1
/usr/bin/time -l "$OUT" "$1" "${2:-1168}" "${3:-688}"
