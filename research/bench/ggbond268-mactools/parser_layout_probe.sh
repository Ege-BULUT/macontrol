#!/bin/bash
# Build and run parser_layout_probe_main.swift with MacTools' unmodified bulk parser.
# The GPL-3.0 file is copied from the gitignored clone into a temp dir at run time only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HERE/../../sources/ggbond268-mactools}"   # ggbond268/MacTools@bf6550a
TMP="$(mktemp -d)"; trap '/bin/rm -rf "$TMP"' EXIT
cp "$SRC/Sources/MacToolsFileSystem/FileSystemBulkAttributeParser.swift" \
   "$SRC/Sources/MacToolsFileSystem/FileSystemEntryType.swift" "$TMP/"
cp "$HERE/parser_layout_probe_main.swift" "$TMP/main.swift"
swiftc -O -parse-as-library "$TMP"/*.swift -o "$TMP/probe"
nice -n 10 "$TMP/probe" "${1:-$PWD}"
