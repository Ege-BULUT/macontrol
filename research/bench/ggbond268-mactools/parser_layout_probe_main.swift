// macontrol probe (our code): how often does MacTools' getattrlistbulk parser report a layout
// mismatch (and so silently fall back to one fstatat per entry) on this Mac's APFS volume?
// Built by parser_layout_probe.sh with MacTools' unmodified FileSystemBulkAttributeParser.swift.
// Source: ggbond268/MacTools@bf6550a Sources/MacToolsFileSystem/FileSystemBulkAttributeParser.swift
import Darwin
import Foundation

@main
struct Probe {
    static func main() {
        let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        for storage in [false, true] {
            var entries = 0, mismatch = 0, unresolved = 0, dirs = 0
            var stack = [root]
            while let dir = stack.popLast() {
                let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { continue }
                defer { close(fd) }
                dirs += 1
                var list = FileSystemBulkAttributeParser.makeAttributeList(includeStorageDetails: storage)
                let cap = 64 * 1024
                let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 8)
                defer { buf.deallocate() }
                while true {
                    let n = getattrlistbulk(fd, &list, buf, cap, 0)
                    if n <= 0 { break }
                    let parsed = FileSystemBulkAttributeParser.parse(
                        buffer: UnsafeRawBufferPointer(start: buf, count: cap), entryCount: Int(n))
                    for e in parsed.entries {
                        entries += 1
                        if e.hasLayoutMismatch { mismatch += 1 }
                        if !e.isFullyResolved { unresolved += 1 }
                        if e.fileType == .directory, let name = e.displayName {
                            stack.append(dir + "/" + name)
                        }
                    }
                }
            }
            print("includeStorageDetails=\(storage) dirs=\(dirs) entries=\(entries) layoutMismatch=\(mismatch) notFullyResolved=\(unresolved)")
        }
    }
}
