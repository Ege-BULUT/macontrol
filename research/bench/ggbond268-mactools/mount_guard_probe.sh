#!/bin/bash
# Mount-guard probe for MacTools StorageExplorer vs DiskClean (see mount_guard_probe_main.swift).
# Fixture (temp dir, removed on exit):
#   root/plain.bin          1 MiB on the boot Data volume
#   root/mnt/               mount point of a 100 MB APFS disk image (hdiutil, no root needed)
#   root/mnt/big.bin        64 MiB, at the root of the mounted volume
#   root/mnt/sub/inner.bin   8 MiB, one level down on the mounted volume
# A scan that stays on root's volume should report ~1 MiB for root.
# GPL-3.0 sources are copied from the gitignored clone into the temp dir at build time only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HERE/../../sources/ggbond268-mactools}"   # ggbond268/MacTools@bf6550a
TMP="$(cd "$(mktemp -d)" && pwd -P)"   # physical path: /var -> /private/var would trip O_NOFOLLOW_ANY
ROOT="$TMP/root"
cleanup() {
  hdiutil detach -quiet "$ROOT/mnt" 2>/dev/null || true
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$ROOT/mnt" "$TMP/build"
dd if=/dev/urandom of="$ROOT/plain.bin" bs=1048576 count=1 2>/dev/null
hdiutil create -quiet -size 100m -fs APFS -volname mgprobe "$TMP/img.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$ROOT/mnt" "$TMP/img.dmg"
dd if=/dev/urandom of="$ROOT/mnt/big.bin" bs=1048576 count=64 2>/dev/null
mkdir "$ROOT/mnt/sub"
dd if=/dev/urandom of="$ROOT/mnt/sub/inner.bin" bs=1048576 count=8 2>/dev/null
echo "st_dev: root=$(stat -f %d "$ROOT") mnt=$(stat -f %d "$ROOT/mnt")"

FS="$SRC/Sources/MacToolsFileSystem"
SE="$SRC/Plugins/StorageExplorer/Sources"
DC="$SRC/Plugins/DiskClean/Sources"
cp "$FS"/*.swift "$TMP/build/"
cp "$SE/StorageExplorerModels.swift" "$SE/StorageExplorerSnapshot.swift" "$TMP/build/"
sed '/^import MacToolsFileSystem$/d' "$SE/StorageExplorerScanner.swift" > "$TMP/build/StorageExplorerScanner.swift"
for f in DiskCleanBulkAttributeParser DiskCleanFastWalker DiskCleanDirectoryTreeWalker \
         DiskCleanSizingModels DiskCleanRootOpener; do
  sed '/^import MacToolsFileSystem$/d' "$DC/$f.swift" > "$TMP/build/$f.swift"
done
cp "$HERE/mount_guard_probe_main.swift" "$TMP/build/main.swift"
swiftc -O -parse-as-library -swift-version 5 "$TMP/build"/*.swift -o "$TMP/probe"
"$TMP/probe" "$ROOT"
