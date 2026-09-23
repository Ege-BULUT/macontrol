import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
import ScanEngine
import Testing
import TestSupport

@Suite struct DiskMapModelTests {
    /// F-0013: drill-down, back, forward and up read the tree in memory. The fixture's root does not
    /// exist, so any disk access would fail.
    @Test func navigationNeverReadsTheDisk() async {
        #expect(!FileManager.default.fileExists(atPath: DiskMapFixtures.missingRoot.path))
        let model = DiskMapModel(engine: nil, trash: nil, tree: DiskMapFixtures.mixed())
        let tree = model.tree!
        let folders = tree.sortedChildren(of: ScanTree.root).filter { tree.isExpandable($0) }
        model.drill(into: folders[0])
        let inner = tree.sortedChildren(of: folders[0]).first { tree.flags(of: $0).contains(.directory) }
        if let inner { model.drill(into: inner) }
        model.goBack()
        #expect(model.focus == folders[0])
        model.goForward()
        #expect(model.focus == inner ?? folders[0])
        model.goUp()
        #expect(model.focus == folders[0])
        for style in MapStyle.allCases {
            model.style = style
            await model.prepareLayout(model.layoutKey(width: 600, height: 400, scale: 2))
            #expect(model.layout?.key.focus == folders[0])
            #expect(model.layout?.elements.isEmpty == false)
        }
    }

    /// F-0016: the side list names every child or folds the map's small ones into one row, and the
    /// rows always add up to the folder.
    @Test func listRowsAddUpToTheFolder() async {
        var builder = DiskMapFixtures.Builder()
        let folder = builder.folder(ScanTree.root, "mixed", ownBytes: 4_096)
        for index in 0..<300 { builder.file(folder, "small-\(index)", UInt64(1_000 + index)) }
        builder.file(folder, "big.bin", 5_000_000_000)
        let model = DiskMapModel(engine: nil, trash: nil, tree: builder.finished())
        let tree = model.tree!
        model.focus = folder
        await model.prepareLayout(model.layoutKey(width: 600, height: 400, scale: 2))
        let countedBytes = { model.listRows.filter { if case .inTrash = $0.kind { false } else { true } }.reduce(0) { $0 + $1.bytes } }

        #expect(model.focusSmallerItems.count == 300)
        #expect(model.listRows.contains { $0.kind == .smallerItems(model.focusSmallerItems) })
        #expect(model.listRows.contains { $0.kind == .folderEntries && $0.bytes == 4_096 })
        #expect(countedBytes() == tree.allocatedSize(of: folder))

        model.select(.node(model.focusSmallerItems[5]))
        #expect(model.showsAllSmallerItems)
        #expect(model.listRows.filter { if case .node = $0.kind { true } else { false } }.count == 301)
        #expect(countedBytes() == tree.allocatedSize(of: folder))
    }

    @Test func navigatesAFourThousandLevelChain() {
        let depth = 4_000
        let model = DiskMapFixtures.model(DiskMapFixtures.chain(depth: depth))
        model.focus = depth
        for _ in 0..<depth { model.goUp() }
        #expect(model.focus == ScanTree.root)
        #expect(model.backStack.count == depth)
        model.stage(depth + 1)
        #expect(model.pile.items.first?.url.pathComponents.count == DiskMapFixtures.missingRoot.pathComponents.count + depth + 1)
    }

    @Test func arrowsMoveAcrossSiblingsAndSmallerItemsOpenInTheList() {
        let model = DiskMapModel(engine: nil, trash: nil, tree: DiskMapFixtures.mixed())
        let siblings = model.tree!.sortedChildren(of: ScanTree.root)
        model.moveSelection(by: 1)
        #expect(model.selection == .node(siblings[0]))
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: -1)
        #expect(model.selection == .node(siblings[1]))
        let folder = siblings.first { model.tree!.isExpandable($0) }!
        let members = model.tree!.children(of: folder)
        model.open(.smallerItems(parent: folder, members: members))
        #expect(model.focus == folder)
        #expect(model.showsAllSmallerItems)
    }

    @Test func stagingRefusesProtectedItemsWithTheReason() {
        var builder = DiskMapFixtures.Builder(root: URL(fileURLWithPath: "/"))
        let applications = builder.folder(ScanTree.root, "Applications")
        let sealed = builder.file(ScanTree.root, "sealed", 10, flags: .systemProtected)
        let volume = builder.folder(ScanTree.root, "Volume", flags: .mountPoint)
        let tree = builder.finished()
        var pile = DiscardPile()
        #expect(pile.add(applications, in: tree) == .protected(.protectedLocation("/Applications")))
        #expect(pile.add(sealed, in: tree) == .protected(.systemProtected))
        #expect(pile.add(volume, in: tree) == .otherVolume)
        #expect(pile.add(ScanTree.root, in: tree) == .scanRoot)
        #expect(pile.items.isEmpty)
        #expect(DiskMapText.staging(.protected(.protectedLocation("/Applications"))).contains("/Applications"))
    }

    @Test func stagingAFolderAbsorbsWhatIsInsideIt() {
        var builder = DiskMapFixtures.Builder()
        let outer = builder.folder(ScanTree.root, "outer")
        let inner = builder.file(outer, "inner", 100)
        let tree = builder.finished()
        var pile = DiscardPile { _ in nil }
        #expect(pile.add(inner, in: tree) == nil)
        #expect(pile.add(inner, in: tree) == .alreadyStaged)
        #expect(pile.add(outer, in: tree) == nil)
        #expect(pile.items.map(\.node) == [outer])
        #expect(pile.add(inner, in: tree) == .insideStaged("outer"))
    }

    /// F-0052, F-0042: trashed items leave the tree in place (no rescan), their bytes read "In Trash",
    /// the map moves off them, and the next delete is available at once.
    @Test func trashedItemsAreSplicedOutWithoutARescan() {
        var builder = DiskMapFixtures.Builder()
        let caches = builder.folder(ScanTree.root, "Caches")
        let blob = builder.file(caches, "blob", 7_000)
        let keep = builder.file(caches, "keep", 3_000)
        let old = builder.folder(ScanTree.root, "old")
        builder.file(old, "a", 1_000)
        let model = DiskMapFixtures.model(builder.finished())
        let before = model.tree!.allocatedSize(of: ScanTree.root)
        model.stage(blob)
        model.stage(old)
        model.focus = old
        let version = model.treeVersion
        let urls = model.pile.items.map(\.url)

        let outcomes = model.apply(TrashReport(batch: UUID(), outcomes: urls.map { .trashed(original: $0, trashedTo: URL(fileURLWithPath: "/.Trash").appendingPathComponent($0.lastPathComponent)) }))

        let tree = model.tree!
        #expect(outcomes.allSatisfy { $0.status == .inTrash })
        #expect(tree.allocatedSize(of: ScanTree.root) == before - 8_000)
        #expect(tree.allocatedSize(of: caches) == 3_000)
        #expect(tree.children(of: caches) == [keep])
        #expect(model.treeVersion == version + 1)
        #expect(model.focus == ScanTree.root)
        #expect(model.pile.items.isEmpty)
        #expect(model.inTrashBytes == 8_000)
        model.focus = caches
        #expect(model.listRows.contains { if case .inTrash(let item) = $0.kind { item.node == blob } else { false } })
        #expect(model.pile.add(keep, in: tree) == nil)
    }

    /// F-0063: trashing a hard link that was counted at 0 B takes 0 B off the totals.
    @Test func trashingAZeroByteHardLinkLeavesTotalsAlone() {
        var builder = DiskMapFixtures.Builder()
        let shared = FileIdentity(device: 1, inode: 999)
        let first = builder.folder(ScanTree.root, "first")
        let second = builder.folder(ScanTree.root, "second")
        _ = builder.add(first, "data.bin", bytes: 4 << 20, flags: .hardLinked, identity: shared)
        let link = builder.add(second, "data-link.bin", bytes: 0, flags: [.hardLinked, .sharedHardLink], identity: shared)
        let model = DiskMapFixtures.model(builder.finished())
        let rootBefore = model.tree!.allocatedSize(of: ScanTree.root)
        model.stage(link)
        model.apply(TrashReport(batch: UUID(), outcomes: [.trashed(original: model.tree!.url(of: link), trashedTo: URL(fileURLWithPath: "/.Trash/data-link.bin"))]))
        #expect(model.tree!.allocatedSize(of: ScanTree.root) == rootBefore)
        #expect(model.tree!.allocatedSize(of: first) == 4 << 20)
        #expect(model.tree!.allocatedSize(of: second) == 0)
    }

    /// Items that are not moved stay on the map and in the pile, each with the reason.
    @Test func refusalsLeaveTheMapAndThePileAsTheyWere() async {
        let model = DiskMapFixtures.model(DiskMapFixtures.mixed())
        let target = model.tree!.sortedChildren(of: ScanTree.root)[0]
        model.stage(target)
        let version = model.treeVersion
        model.beginReview()
        await model.confirmReview()
        guard case .done(let outcomes) = model.review?.phase else { Issue.record("review did not finish"); return }
        let reason = DiskMapText.refusal(.notImplemented)
        #expect(outcomes.map(\.status) == [.notMoved(reason)])
        #expect(model.treeVersion == version)
        #expect(model.pile.items.map(\.node) == [target])
        #expect(model.pile.items.first?.note == reason)
        #expect(model.trashed.isEmpty)
    }

    /// End to end on real files in a temporary folder: scan, then every entry is on the map.
    @Test func aScannedFolderIsMapped() async throws {
        let folder = try TemporaryDirectory()
        try folder.file("videos/clip.mov", size: 300_000)
        try folder.file("videos/trailer.mov", size: 120_000)
        try folder.file("notes.txt", size: 40_000)
        try folder.directory("empty")
        let model = DiskMapModel(engine: ScanEngine(), trash: nil)
        await model.scan(folder.url)
        let tree = try #require(model.tree)
        #expect(!model.isScanning)
        await model.prepareLayout(model.layoutKey(width: 600, height: 400, scale: 2))
        let layout = try #require(model.layout)
        var mapped: [String] = []
        for index in layout.topLevel {
            switch layout.elements[index].item {
            case .node(let node): mapped.append(tree.name(of: node))
            case .smallerItems(_, let members): mapped += members.map(tree.name(of:))
            }
        }
        #expect(mapped.sorted() == ["empty", "notes.txt", "videos"])
        #expect(layout.elements.contains { $0.node.map(tree.name(of:)) == "clip.mov" })
    }
}
