import Foundation
import MacontrolCore
import ScanEngine

// Prints the allocated total of each path, one per line, for research/bench/run.sh:
//   mcscan|.build/release/mcscan {}|.build/release/mcscan -A {}
// -A prints the logical (apparent) total instead. --stats adds node and memory counts on stderr.
// -j N sets the worker count (default: the engine's policy).
var arguments = Array(CommandLine.arguments.dropFirst())
let apparent = arguments.contains("-A")
let stats = arguments.contains("--stats")
arguments.removeAll { $0 == "-A" || $0 == "--stats" }
var workers: Int?
if let flag = arguments.firstIndex(of: "-j"), flag + 1 < arguments.count {
    workers = Int(arguments[flag + 1])
    arguments.removeSubrange(flag...flag + 1)
}
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: mcscan [-A] [--stats] [-j workers] <path>...\n".utf8))
    exit(64)
}

var exitCode: Int32 = 0
let engine = ScanEngine(options: ScanOptions(workerCount: workers))
for path in arguments {
    let started = Date()
    for try await event in engine.scan(URL(fileURLWithPath: path)) {
        guard case .completed(let tree) = event else { continue }
        let total = apparent ? tree.logicalSize(of: ScanTree.root) : tree.allocatedSize(of: ScanTree.root)
        print("\(total)\t\(path)")
        var notScanned = 0
        for node in 0..<tree.count where !tree.flags(of: node).isDisjoint(with: [.unreadable, .incomplete]) { notScanned += 1 }
        if notScanned > 0 {
            exitCode = 1
            FileHandle.standardError.write(Data("mcscan: \(notScanned) folders not fully scanned in \(path)\n".utf8))
        }
        if stats {
            let seconds = Date().timeIntervalSince(started)
            let line = "nodes \(tree.count), tree \(tree.storageBytes) B (\(tree.storageBytes / max(tree.count, 1)) B/node incl. names and slack, "
                + "\(ScanTree.bytesPerNode) B/node fixed), \(String(format: "%.3f", seconds)) s\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
exit(exitCode)
