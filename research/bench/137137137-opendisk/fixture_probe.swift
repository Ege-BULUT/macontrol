// Correctness probe: OpenDisk@6e3f1f7 TraversalScanner (unmodified) over the
// shared fixture, 3 runs, totals compared byte-exact with ground_truth.json.
// Build: see run_incremental_probe.sh for the file list (same engine files).
import Foundation

@main struct Probe {
    static func main() {
        let root = CommandLine.arguments[1]
        let workers = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : TraversalScanner.subtreeWorkerCount
        for run in 1...3 {
            let metrics = ScanMetrics()
            let t0 = Date()
            var tree = TraversalScanner.scan(path: root, rootName: root, workerCount: workers,
                                             metrics: metrics, isCancelled: { false })
            let dt = Date().timeIntervalSince(t0)
            tree.rollUpDirectorySizes()
            print("run \(run): workers=\(workers) root=\(tree.size(of: FileTree.rootID)) B nodes=\(tree.nodeCount - 1) unreadable=\(metrics.unreadableDirectories) wall=\(String(format: "%.2f", dt)) s")
        }
    }
}
