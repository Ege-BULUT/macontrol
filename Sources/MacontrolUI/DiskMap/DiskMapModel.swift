import Foundation
import MacontrolCore
import Observation
import Safety
import ScanEngine

@Observable
public final class DiskMapModel {
    public private(set) var tree: ScanTree?
    public private(set) var progress: ScanProgress?
    /// The folder the map is drilled into.
    public var focus: Int = ScanTree.root

    private let engine: ScanEngine?
    private let trash: TrashService?

    public init(engine: ScanEngine?, trash: TrashService?, tree: ScanTree? = nil) {
        self.engine = engine
        self.trash = trash
        self.tree = tree
    }

    func scan(_ root: URL) async {
        guard let engine else { return }
        tree = nil
        focus = ScanTree.root
        do {
            for try await event in engine.scan(root) {
                switch event {
                case .progress(let update): progress = update
                case .completed(let result): tree = result
                }
            }
        } catch {
            progress = nil
        }
    }

    static func demo() -> DiskMapModel {
        DiskMapModel(engine: nil, trash: nil, tree: .demo())
    }
}

extension ScanTree {
    /// A small fixed tree for snapshots.
    static func demo() -> ScanTree {
        var tree = ScanTree(rootURL: URL(fileURLWithPath: "/Users/demo"), rootIdentity: FileIdentity(device: 1, inode: 1))
        var inode: UInt64 = 1
        func add(_ parent: Int, _ name: String, _ gigabytes: Double, folder: Bool = false) -> Int {
            inode += 1
            return tree.addChild(
                of: parent, name: name, flags: folder ? .directory : [],
                allocated: UInt64(gigabytes * 1_000_000_000), logical: UInt64(gigabytes * 1_000_000_000),
                identity: FileIdentity(device: 1, inode: inode)
            )
        }
        let library = add(ScanTree.root, "Library", 0, folder: true)
        _ = add(add(library, "Caches", 0, folder: true), "com.example.Editor", 6.2)
        _ = add(add(library, "Developer", 0, folder: true), "DerivedData", 18.4)
        _ = add(library, "Mail", 3.1, folder: false)
        let projects = add(ScanTree.root, "projects", 0, folder: true)
        _ = add(projects, "node_modules", 2.7)
        _ = add(projects, "videos.mov", 11.9)
        _ = add(ScanTree.root, "Downloads", 9.5)
        _ = add(ScanTree.root, "Movies", 22.0)
        _ = add(ScanTree.root, "Documents", 4.4)
        tree.finalizeTotals()
        return tree
    }
}
