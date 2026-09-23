// Probe: resident cost per scanned node in Radix's tree model (colinvkim/Radix@14a76df, MIT).
// Compiled together with an UNMODIFIED copy of Radix/Models/FileNodeRecord.swift.
// Mirrors ScanEngine.makeFileNode (ScanEngine.swift:2958-2984: id = url.path, url = url,
// name = last component) and FileTreeStore's `indexByNodeID: [String: FileTreeNodeIndex]`
// (FileTreeStore.swift:27). Compares with a compact layout (name + parent index + sizes).
// Build: swiftc -O -parse-as-library ../../sources/colinvkim-radix/Radix/Models/FileNodeRecord.swift node_memory_probe_main.swift -o /tmp/probe
// Run:   /tmp/probe radix; /tmp/probe compact; /tmp/probe url   (one mode per process)
import Foundation
import Darwin

// --- stubs for the types FileNodeRecord.swift references (shapes copied from ScanMetadataLoader.swift:770-780, ScanTarget.swift:15-19)
nonisolated struct CloneIdentity: Hashable, Sendable { let device: UInt64; let cloneID: UInt64 }
nonisolated enum FileIdentity: Hashable, Sendable {
    case resourceIdentifier(Data)
    case fileSystem(device: UInt64, inode: UInt64, volumeToken: UInt64? = nil)
}
enum ScanTargetKind { case folder, volume }
struct ScanTarget { let url: URL; let kind: ScanTargetKind }

func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(kr == KERN_SUCCESS)
    return Int64(info.phys_footprint)
}

struct CompactNode { var parent: UInt32; var name: String; var allocated: Int64; var logical: Int64; var inode: UInt64; var flags: UInt16 }

@main struct Probe {
    static func main() {
        let n = 1_000_000
        let mode = CommandLine.arguments.dropFirst().first ?? "radix"   // radix | compact | url, one per process (frees skew footprint deltas)
        // Realistic path shapes: a home-directory tree 6-9 levels deep (avg ~95 bytes).
        let dirs = (0..<2_000).map { "/Users/someone/Library/Application Support/com.vendor.app\($0 % 97)/Cache/Data/v\($0)" }
        var paths: [String] = []; paths.reserveCapacity(n)
        for i in 0..<n { paths.append(dirs[i % dirs.count] + "/entry-\(i).db") }
        let avgLen = paths.reduce(0) { $0 + $1.utf8.count } / n

        if mode == "radix" {
        let base = footprint()
        var nodes: [FileNodeRecord] = []; nodes.reserveCapacity(n)
        var index: [String: UInt32] = [:]; index.reserveCapacity(n)
        for (i, p) in paths.enumerated() {
            let url = URL(fileURLWithPath: p)
            let node = FileNodeRecord(id: url.path, url: url, name: url.lastPathComponent, isDirectory: false,
                isSymbolicLink: false, allocatedSize: 4096, logicalSize: 1000, descendantFileCount: 1,
                lastModified: Date(), fileIdentity: .fileSystem(device: 1, inode: UInt64(i)), linkCount: 1,
                isPackage: false, isAccessible: true, isSelfAccessible: true, isSynthetic: false, isAutoSummarized: false)
            index[node.id] = UInt32(i)
            nodes.append(node)
        }
        let radix = footprint() - base
        print("paths=\(n) avgPathBytes=\(avgLen) MemoryLayout<FileNodeRecord>.stride=\(MemoryLayout<FileNodeRecord>.stride)")
        print(String(format: "Radix model (records + path index): %.0f MiB = %d B/node", Double(radix) / 1_048_576, radix / Int64(n)))
        withExtendedLifetime((nodes, index)) {}
        }
        if mode == "compact" {
        let base2 = footprint()
        var compact: [CompactNode] = []; compact.reserveCapacity(n)
        for (i, p) in paths.enumerated() {
            let name = String(p[p.index(after: p.lastIndex(of: "/")!)...]) + "-segment"  // >15 B so it is heap-allocated like most real names
            compact.append(CompactNode(parent: UInt32(i % 2_000), name: name, allocated: 4096, logical: 1000, inode: UInt64(i), flags: 0))
        }
        let small = footprint() - base2
        print(String(format: "compact model (name + parent index): %.0f MiB = %d B/node", Double(small) / 1_048_576, small / Int64(n)))
        withExtendedLifetime(compact) {}
        }
        if mode == "url" {
        // Attribution: what the URL alone costs per node (Radix keeps it next to the id String).
        let base3 = footprint()
        var urls: [URL] = []; urls.reserveCapacity(n)
        for p in paths { urls.append(URL(fileURLWithPath: p)) }
        let urlOnly = footprint() - base3
        print(String(format: "  of which URL(fileURLWithPath:) alone: %d B/node", urlOnly / Int64(n)))
        withExtendedLifetime(urls) {}
        }
    }
}
