// F-0046 probe: Neodisk DuplicateHashCache (tkslucas/Neodisk@b26a08c, verbatim) keyed by size+mtime+inode.
// Rewrites a file in place (same inode, same size), restores its mtime like `touch -r` / `cp -p`,
// then asks the cache for the digest. Stamp logic copied from DuplicateFinder.hashableStamp (:471-481).
import Foundation
import CryptoKit
import Darwin

func stamp(_ p: String) -> (DuplicateHashCache.FileStamp, ctime: Int64) {
    var st = stat(); precondition(stat(p, &st) == 0)
    let s = DuplicateHashCache.FileStamp(size: Int64(st.st_size),
        modifiedAtNanoseconds: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
        inode: UInt64(st.st_ino))
    return (s, Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec))
}
func sha(_ p: String) -> String { SHA256.hash(data: FileManager.default.contents(atPath: p)!).map { String(format: "%02x", $0) }.joined() }

let dir = CommandLine.arguments[1]
let a = dir + "/a.bin"
let size = 2 << 20
FileManager.default.createFile(atPath: a, contents: Data(repeating: 0x41, count: size))
let cache = DuplicateHashCache()
let (s1, c1) = stamp(a)
cache.storeDigest(sha(a), for: a, tier: .full, stamp: s1)
var st = stat(); stat(a, &st); let oldTimes = [st.st_atimespec, st.st_mtimespec]
Thread.sleep(forTimeInterval: 1.1)
// in-place rewrite: same inode, same size, different bytes
let fh = FileHandle(forWritingAtPath: a)!; fh.write(Data(repeating: 0x42, count: size)); fh.closeFile()
// restore the old mtime (what touch -r, cp -p, rsync --inplace -t, exiftool -P do)
var times = oldTimes; precondition(utimensat(AT_FDCWD, a, &times, 0) == 0)
let (s2, c2) = stamp(a)
let cached = cache.cachedDigest(for: a, tier: .full, stamp: s2)
print("stamp equal after rewrite+restore:", s1 == s2, " inode", s1.inode, "->", s2.inode)
print("ctime changed:", c1 != c2)
print("cache returned digest:", cached != nil, " stale:", cached != nil && cached != sha(a))
print("cached:", cached?.prefix(16) ?? "nil", " actual:", sha(a).prefix(16))
