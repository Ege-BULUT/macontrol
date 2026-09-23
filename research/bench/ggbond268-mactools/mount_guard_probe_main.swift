// macontrol probe (our code): does a scan of a folder that contains a mount point stay on the
// folder's volume? Runs MacTools' own, unmodified StorageExplorerScanner and DiskClean
// FastWalker (copied from the gitignored clone at build time by mount_guard_probe.sh).
// Source: ggbond268/MacTools@bf6550a
//   Plugins/StorageExplorer/Sources/StorageExplorerScanner.swift (devid check on directories only)
//   Plugins/DiskClean/Sources/DiskCleanDirectoryTreeWalker.swift (devid check on every entry)
import Darwin
import Foundation

@main
struct Probe {
    static func main() async throws {
        let root = CommandLine.arguments[1]
        let mnt = root + "/mnt"

        let scanner = StorageExplorerScanner(publishesItems: true)
        let snapshot = try await scanner.scanSnapshot(rootURL: URL(fileURLWithPath: root)) { _ in }
        let rootItem = snapshot.items[snapshot.rootPath]!
        let mntItem = snapshot.items[mnt]
        print("StorageExplorer root: size=\(rootItem.size) allocated=\(rootItem.allocatedSize) incomplete=\(rootItem.isIncomplete)")
        print("StorageExplorer mnt : size=\(mntItem?.size ?? -1) allocated=\(mntItem?.allocatedSize ?? -1) incomplete=\(mntItem?.isIncomplete ?? false) skipped=\(mntItem?.skippedCount ?? -1)")
        let counted = snapshot.items.keys.filter { $0.hasPrefix(mnt + "/") }.sorted()
        print("StorageExplorer items under mnt/: \(counted.map { String($0.dropFirst(root.count)) })")

        let walker = DiskCleanFastWalker()
        let result = walker.size(ofItemAt: root, context: DiskCleanSizingContext(deadline: Date().addingTimeInterval(30)))
        print("DiskClean FastWalker root: estimatedBytes=\(result.estimatedBytes) completeness=\(result.completeness)")
    }
}
