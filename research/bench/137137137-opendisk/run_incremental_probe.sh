#!/bin/sh
# Builds the probe against OpenDisk's own, unmodified engine files and runs it
# on a throwaway fixture. Usage: run_incremental_probe.sh <fixture-dir>
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../sources/137137137-opendisk/OpenDisk"
OUT="${TMPDIR:-/tmp}/opendisk_incremental_probe"
swiftc -O -swift-version 6 -target arm64-apple-macosx15.0 -parse-as-library -o "$OUT" \
  "$HERE/incremental_probe.swift" \
  "$SRC/Services/Scanning/FileTree.swift" "$SRC/Services/Scanning/TraversalScanner.swift" \
  "$SRC/Services/Scanning/SystemInterop/BulkDirectoryReader.swift" \
  "$SRC/Services/Scanning/SystemInterop/VolumeAttributes.swift" \
  "$SRC/Services/Scanning/SystemInterop/FSEventsChangeJournal.swift" \
  "$SRC/Services/Scanning/IncrementalUpdater.swift" "$SRC/Services/Scanning/ScanMetrics.swift" \
  "$SRC/Services/Scanning/DiskScanning.swift" "$SRC/Models/ScanProgress.swift" \
  "$SRC/Utilities/PathHelpers.swift"
"$OUT" "$1"
