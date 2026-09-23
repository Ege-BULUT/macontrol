// macontrol probe (our code): single-thread throughput of MacTools' DiskCleanFastWalker, which
// sizes one cleanup candidate per thread under a 20 s per-item deadline
// (ggbond268/MacTools@bf6550a DiskCleanScanEngine.swift:54, partial results are not cleanable:
// DiskCleanSizingModels.swift:7-9). Built by pool_timeout_probe.sh with MAIN=walker_throughput_main.swift.
import Foundation

@main
struct Probe {
    static func main() {
        let root = CommandLine.arguments[1]
        let deadline = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 60
        let started = Date()
        let r = DiskCleanFastWalker().size(
            ofItemAt: root, context: DiskCleanSizingContext(deadline: started.addingTimeInterval(deadline)))
        let s = Date().timeIntervalSince(started)
        print(String(format: "files=%d bytes=%lld elapsed=%.2fs files/s=%.0f completeness=%@",
                     r.fileCount, r.estimatedBytes, s, Double(r.fileCount) / s, "\(r.completeness)"))
    }
}
