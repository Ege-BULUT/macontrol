import Foundation
import MacontrolCore
import ScanEngine

// Prints the allocated total of each path, one per line, for research/bench/run.sh:
//   mcscan-du|.build/release/mcscan {}|
let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: mcscan <path>...\n".utf8))
    exit(64)
}

let engine = ScanEngine()
for path in paths {
    for try await event in engine.scan(URL(fileURLWithPath: path)) {
        if case .completed(let tree) = event {
            print("\(tree.allocatedSize(of: ScanTree.root))\t\(path)")
        }
    }
}
