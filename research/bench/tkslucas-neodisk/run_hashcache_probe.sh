#!/bin/sh
# F-0046 check for Neodisk's DuplicateHashCache (size+mtime+inode stamp).
# Compiles the source's DuplicateHashCache.swift UNMODIFIED from the gitignored clone
# (GPL-3.0: never copy it into this repo) with hashcache_probe_main.swift, rewrites a 2 MiB
# file in place, restores its mtime, and asks the cache for the digest.
# Expected on tkslucas/Neodisk@b26a08c: "stamp equal ... true", "stale: true".
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${NEODISK_SRC:-$HERE/../../sources/tkslucas-neodisk}
W=$(mktemp -d)
cp "$SRC/Sources/NeodiskKit/Services/DuplicateHashCache.swift" "$HERE/hashcache_probe_main.swift" "$W/"
mv "$W/hashcache_probe_main.swift" "$W/main.swift"
swiftc -O "$W/main.swift" "$W/DuplicateHashCache.swift" -o "$W/probe" 2>/dev/null
mkdir "$W/fx" && "$W/probe" "$W/fx"
/bin/rm -rf "$W"
