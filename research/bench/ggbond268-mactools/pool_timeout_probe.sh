#!/bin/bash
# Build and run pool_timeout_probe_main.swift against MacTools' own DiskClean sizing files.
# GPL-3.0 sources are copied from the gitignored clone into a temp dir at run time only.
# Usage: pool_timeout_probe.sh <root-to-walk> <timeout-seconds> <runs>
#        MAIN=walker_throughput_main.swift pool_timeout_probe.sh <root> [deadline-seconds]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HERE/../../sources/ggbond268-mactools}"   # ggbond268/MacTools@bf6550a
TMP="$(mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
FS="$SRC/Sources/MacToolsFileSystem"
DC="$SRC/Plugins/DiskClean/Sources"
cp "$FS/FileSystemBulkAttributeParser.swift" "$FS/FileSystemEntryType.swift" "$TMP/"
for f in DiskCleanBulkAttributeParser DiskCleanFastWalker DiskCleanDirectoryTreeWalker \
         DiskCleanSizingModels DiskCleanRootOpener DiskCleanWorkerPool; do
  # Single-module build: drop the cross-module import, nothing else changes.
  sed '/^import MacToolsFileSystem$/d' "$DC/$f.swift" > "$TMP/$f.swift"
done
cp "$HERE/${MAIN:-pool_timeout_probe_main.swift}" "$TMP/main.swift"   # MAIN=walker_throughput_main.swift reuses this build
swiftc -O -parse-as-library -swift-version 5 "$TMP"/*.swift -o "$TMP/probe"
nice -n 10 "$TMP/probe" "$@"
