// macontrol probe (our code, not MacTools'): does DiskCleanWorkerPool treat a healthy,
// deadline-honoring walk as a stuck syscall?
//
// Built by pool_timeout_probe.sh together with MacTools' own, unmodified DiskClean sizing files
// (copied at run time from the gitignored clone; GPL-3.0 text is never committed here).
// Source: ggbond268/MacTools@bf6550a Plugins/DiskClean/Sources/DiskCleanWorkerPool.swift
//
// The job is cooperative: it walks ROOT with the real DiskCleanFastWalker over and over,
// using the context the pool hands it, until context.shouldStop is true. It never blocks
// in a syscall for longer than one getattrlistbulk batch.
//
// Per run we record who won the gate:
//   walker  = result carries a rootIdentity (the walker saw its own deadline and returned first)
//   pool    = result has rootIdentity == nil (handleTimeout claimed the gate first)
// and whether the pool then abandoned the thread and blacklisted ROOT's device.
import Darwin
import Foundation

@main
struct Probe {
    static func main() async {
        let args = CommandLine.arguments
        let root = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
        let timeout = args.count > 2 ? Double(args[2])! : 0.25
        let runs = args.count > 3 ? Int(args[3])! : 10

        var st = stat()
        guard lstat(root, &st) == 0 else { print("cannot stat \(root)"); exit(2) }
        let rootDevice = UInt64(UInt32(bitPattern: st.st_dev))

        var poolWon = 0, walkerWon = 0, abandonedTotal = 0, blacklisted = 0
        for run in 1...runs {
            // Fresh pool per run so abandon counts are per run (production uses one shared pool).
            let pool = DiskCleanWorkerPool(maxThreadCount: 3, abandonBudget: 1000)
            let walker = DiskCleanFastWalker()
            let started = Date()
            let result = await pool.perform(deadline: started.addingTimeInterval(timeout)) { context in
                var last = walker.size(ofItemAt: root, context: context)
                while !context.shouldStop {
                    last = walker.size(ofItemAt: root, context: context)
                }
                return last
            }
            let elapsed = Date().timeIntervalSince(started)
            let winner = result.rootIdentity == nil ? "pool" : "walker"
            if winner == "pool" { poolWon += 1 } else { walkerWon += 1 }

            // Is ROOT's device now refused for every later candidate?
            let admitted = await pool.perform(deadline: Date().addingTimeInterval(5)) { context in
                let ok = context.admitDevice(rootDevice)
                return DiskCleanSizeResult(
                    estimatedBytes: ok ? 1 : 0, fileCount: 0, completeness: .complete,
                    rootIdentity: nil, observedAt: Date())
            }
            let deviceBlocked = admitted.estimatedBytes == 0
            if deviceBlocked { blacklisted += 1 }
            abandonedTotal += pool.abandonedThreads
            print(String(format: "run %2d timeout=%.2fs elapsed=%.3fs winner=%@ abandoned=%d deviceBlocked=%@ reasons=%@",
                         run, timeout, elapsed, winner, pool.abandonedThreads,
                         deviceBlocked ? "yes" : "no", "\(result.completeness.partialReasons)"))
            pool.shutDown()
        }
        print("SUMMARY timeout=\(timeout)s runs=\(runs) poolWon=\(poolWon) walkerWon=\(walkerWon) abandonedThreads=\(abandonedTotal) runsWithDeviceBlacklisted=\(blacklisted)")
    }
}
