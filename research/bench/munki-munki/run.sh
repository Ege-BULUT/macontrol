#!/bin/bash
# Compiles munki's rmpkgs.swift + its own sqlite/file/cli/plist utils UNMODIFIED from the
# gitignored clone, plus stubs.swift (logging/prefs only) and main.swift, then runs the probe.
# Usage: run.sh fixture | rebuild
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HOME/projects/macontrol/research/sources/munki-munki/code/cli/munki/shared}"
OUT="$(mktemp -d)"
FIX="$(cd "$OUT" && pwd -P)/fixture"
export PROBE_DIR="$OUT/db"; mkdir -p "$PROBE_DIR"
git -C "$SRC" rev-parse --short HEAD
swiftc -O -o "$OUT/probe" "$HERE/main.swift" "$HERE/stubs.swift" \
  "$SRC/installer/rmpkgs.swift" "$SRC/sqlite3.swift" "$SRC/errors.swift" \
  "$SRC/utils/fileutils.swift" "$SRC/utils/cliutils.swift" "$SRC/utils/plistutils.swift" "$SRC/utils/stringutils.swift" -lsqlite3
"$OUT/probe" "${1:-fixture}" "$FIX"
echo "exit=$?  (workdir $OUT)"
