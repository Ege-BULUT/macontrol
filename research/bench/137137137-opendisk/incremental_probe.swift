// Probe for OpenDisk@6e3f1f7 IncrementalUpdater: compiled together with the
// source's own unmodified engine files (see run_incremental_probe.sh).
// 1) hard-link dedup after an incremental splice, 2) garbage node growth,
// 3) which path form FSEvents reports for the changed directory.
import Foundation
import Synchronization

@main struct Probe {
    static func main() async {
        let base = CommandLine.arguments[1]           // fixture root (absolute)
        let fm = FileManager.default
        try? fm.removeItem(atPath: base)
        try! fm.createDirectory(atPath: base + "/A", withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: base + "/B", withIntermediateDirectories: true)
        let payload = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761) })
        fm.createFile(atPath: base + "/A/big.bin", contents: payload)      // 8 MiB
        try! fm.linkItem(atPath: base + "/A/big.bin", toPath: base + "/B/link.bin")
        for i in 0..<200 { fm.createFile(atPath: base + "/B/small\(i).txt", contents: Data("x".utf8)) }

        let dev = VolumeAttributes.deviceID(ofPath: base)!
        let metrics = ScanMetrics()
        let full = TraversalScanner.scan(path: base, rootName: base, metrics: metrics, isCancelled: { false })
        var rolled = full; rolled.rollUpDirectorySizes()
        print("full scan:           root=\(rolled.size(of: FileTree.rootID)) B  nodes=\(full.nodeCount)")

        let startEvent = FSEventsChangeJournal.currentEventID
        fm.createFile(atPath: base + "/B/new.txt", contents: Data("y".utf8))  // touch B
        try? await Task.sleep(for: .seconds(3))                               // let fseventsd flush

        // What does the journal report, and does it resolve in the tree?
        if let ch = await FSEventsChangeJournal.changes(since: startEvent, under: base, timeout: 5) {
            print("journal(\(base)): dirs=\(ch.changedDirectories) subtrees=\(ch.subtreesToRescan)")
        } else { print("journal(\(base)): nil (unreliable/timeout)") }
        if let ch = await FSEventsChangeJournal.changes(since: startEvent, under: "/", timeout: 5) {
            let mine = (ch.changedDirectories + ch.subtreesToRescan).filter { $0.contains("opendisk-fixture") }
            print("journal(/): matching paths=\(mine)")
        } else { print("journal(/): nil (unreliable/timeout)") }

        let live = Mutex(full)
        let ok = IncrementalUpdater.apply(
            .init(changedDirectories: [base + "/B"], subtreesToRescan: []),
            to: live, rootPath: base, allowedDevices: [dev], metrics: metrics, isCancelled: { false })
        var after = live.withLock { $0 }; after.rollUpDirectorySizes()
        print("after 1 splice of B: ok=\(ok) root=\(after.size(of: FileTree.rootID)) B  nodes=\(live.withLock { $0.nodeCount })")

        for _ in 0..<9 {
            _ = IncrementalUpdater.apply(
                .init(changedDirectories: [base + "/B"], subtreesToRescan: []),
                to: live, rootPath: base, allowedDevices: [dev], metrics: metrics, isCancelled: { false })
        }
        let t = live.withLock { $0 }
        let reach = t.reachabilityBitmap().filter { $0 }.count
        print("after 10 splices:    nodes=\(t.nodeCount) reachable=\(reach) serialized=\(t.serializedData().count) B (fresh scan serialized=\(full.serializedData().count) B)")

        // A fresh subtree adopted by the splice (new dir C holding another link).
        try! fm.createDirectory(atPath: base + "/C", withIntermediateDirectories: true)
        try! fm.linkItem(atPath: base + "/A/big.bin", toPath: base + "/C/link2.bin")
        _ = IncrementalUpdater.apply(
            .init(changedDirectories: [base], subtreesToRescan: []),
            to: live, rootPath: base, allowedDevices: [dev], metrics: metrics, isCancelled: { false })
        var withC = live.withLock { $0 }; withC.rollUpDirectorySizes()
        let fresh2 = TraversalScanner.scan(path: base, rootName: base, metrics: ScanMetrics(), isCancelled: { false })
        var fresh2r = fresh2; fresh2r.rollUpDirectorySizes()
        print("after new dir C:     spliced root=\(withC.size(of: FileTree.rootID)) B  vs fresh full scan root=\(fresh2r.size(of: FileTree.rootID)) B")
        try? fm.removeItem(atPath: base)
    }
}
