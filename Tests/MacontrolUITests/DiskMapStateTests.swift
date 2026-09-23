import Foundation
import MacontrolCore
@testable import MacontrolUI
import ScanEngine
import Testing

/// Model state that outlives one layout or one scan: hover, focus, scans replacing each other, and the
/// side list's cost on a huge flat folder.
@Suite struct DiskMapStateTests {
    /// A hover recorded in one layout never indexes another: the context menu reads it on every body
    /// evaluation, and a stale index trapped after a drill-in with the pointer at rest.
    @Test func aHoverOnlyIndexesTheLayoutItCameFrom() throws {
        let tree = DiskMapFixtures.mixed()
        let folder = tree.sortedChildren(of: ScanTree.root).first { tree.isExpandable($0) }!
        let map = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(.treemap))
        let drilled = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(.treemap, focus: folder))
        let deep = MapHover(key: map.key, index: map.elements.count - 1)
        #expect(map.elements.count > drilled.elements.count)
        #expect(deep.element(in: map) == map.elements.count - 1)
        #expect(deep.element(in: drilled) == nil)
        #expect(MapHover(key: map.key, index: map.elements.count).element(in: map) == nil)
        let spliced = try MapLayoutBuilder.build(tree, DiskMapFixtures.key(.treemap, version: 1))
        #expect(deep.element(in: spliced) == nil)
    }

    /// An older scan's buffered events can arrive after a newer scan started; they must not replace
    /// the tree or end the newer scan's progress screen.
    @Test func anOlderScanNeverWritesOverANewerOne() {
        let model = DiskMapModel(engine: nil, trash: nil)
        let stale = DiskMapFixtures.chain(depth: 3)
        let fresh = DiskMapFixtures.mixed()
        let older = model.beginScan()
        let newer = model.beginScan()
        model.receive(.completed(stale), generation: older)
        model.finishScan(older)
        #expect(model.tree == nil)
        #expect(model.isScanning)
        model.receive(.completed(fresh), generation: newer)
        model.finishScan(newer)
        #expect(model.tree?.count == fresh.count)
        #expect(!model.isScanning)
    }

    /// T-0063: previews of the newest scan show while it runs; the completed tree replaces them.
    @Test func previewsShowUntilTheScanCompletes() {
        let model = DiskMapModel(engine: nil, trash: nil)
        let older = model.beginScan()
        let newer = model.beginScan()
        model.receive(.preview(DiskMapFixtures.chain(depth: 3)), generation: older)
        #expect(model.preview == nil)
        let preview = DiskMapFixtures.mixed()
        model.receive(.preview(preview), generation: newer)
        #expect(model.preview?.count == preview.count)
        let version = model.previewVersion
        model.receive(.preview(preview), generation: newer)
        #expect(model.previewVersion == version + 1)
        model.receive(.completed(DiskMapFixtures.mixed()), generation: newer)
        model.finishScan(newer)
        #expect(model.preview == nil)
        #expect(model.tree != nil)
    }

    /// T-0063: a folder keeps its colour for the whole scan while sizes change rank. Colour by rank changed
    /// up to 10 of the 12 legend colours from one preview to the next on a real walk.
    @Test(arguments: MapStyle.allCases)
    func previewColoursStayWithTheirFolderWhileRanksChange(style: MapStyle) throws {
        let model = DiskMapModel(engine: nil, trash: nil)
        let generation = model.beginScan()
        func colours(_ sizes: [String: UInt64]) throws -> [String: Int] {
            var preview = ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 1))
            for (offset, entry) in sizes.enumerated() {
                preview.addChild(
                    of: ScanTree.root, name: entry.key, flags: .directory, allocated: entry.value, logical: 0,
                    identity: FileIdentity(device: 1, inode: UInt64(offset + 2))
                )
            }
            preview.finalizeTotals()
            model.receive(.preview(preview), generation: generation)
            let layout = try MapLayoutBuilder.build(preview, DiskMapFixtures.key(style, version: model.previewVersion), slots: model.previewSlots)
            return Dictionary(uniqueKeysWithValues: layout.topLevel.compactMap { index in
                guard case .node(let node) = layout.elements[index].item, let branch = layout.elements[index].branch else { return nil }
                return (preview.name(of: node), branch)
            })
        }
        let first = try colours(["A": 300, "B": 200, "C": 100])
        let second = try colours(["A": 300, "B": 250, "C": 900, "D": 50])
        #expect(first.count == 3 && second.count == 4)
        #expect(second.filter { first[$0.key] != nil } == first, "C overtook A and B, and each kept its colour: \(first) -> \(second)")
        #expect(second["D"].map { !first.values.contains($0) } == true, "a newcomer takes a colour not in use yet")
    }

    /// T-0063: the progress bar's goal is read off the main actor; on a hung network mount statfs froze the UI.
    @Test func volumeGoalIsReadOffTheMainActor() async {
        let readOnMain = await DiskMapModel.bytesInUse(URL(fileURLWithPath: "/")) { _ in Thread.isMainThread ? 1 : 0 }
        #expect(readOnMain == 0)
    }

    /// Stop keeps the map and the pile. A rescan keeps staged items it finds again at the same path
    /// as the same file, and drops the ones that changed.
    @Test func stopKeepsTheMapAndARescanKeepsThePile() {
        func makeTree(extra: Bool) -> (ScanTree, same: Int, changed: Int) {
            var builder = DiskMapFixtures.Builder()
            let folder = builder.folder(ScanTree.root, "Caches")
            let same = builder.file(folder, "same.bin", 5_000)
            if extra { builder.file(folder, "new.bin", 1) }
            let changed = builder.file(folder, "changed.bin", 3_000)
            return (builder.finished(), same, changed)
        }
        let (first, same, changed) = makeTree(extra: false)
        let model = DiskMapFixtures.model(first)
        model.stage(same)
        model.stage(changed)

        model.finishScan(model.beginScan())
        #expect(model.tree?.count == first.count)
        #expect(model.pile.items.count == 2)

        // The extra file shifts the fixture's inode numbers, so "changed.bin" is another file now.
        let (second, sameAgain, _) = makeTree(extra: true)
        let generation = model.beginScan()
        model.receive(.completed(second), generation: generation)
        model.finishScan(generation)
        #expect(model.pile.items.map(\.node) == [sameAgain])
        #expect(model.pile.items.first?.url == second.url(of: sameAgain))
    }

    /// `focus` is public: the Overview sets it. Files, packages, removed folders and bad indexes are ignored.
    @Test func focusOnlyAcceptsFoldersTheMapCanOpen() {
        var builder = DiskMapFixtures.Builder()
        let folder = builder.folder(ScanTree.root, "folder")
        let file = builder.file(folder, "file", 10)
        let package = builder.folder(ScanTree.root, "Tool.app", flags: .package)
        let gone = builder.folder(ScanTree.root, "gone")
        let inside = builder.folder(gone, "inside")
        var tree = builder.finished()
        tree.removeSubtree(at: gone)
        let model = DiskMapFixtures.model(tree)
        for node in [file, package, inside, -1, tree.count] {
            model.focus = node
            #expect(model.focus == ScanTree.root, "accepted \(node)")
        }
        model.focus = folder
        #expect(model.focus == folder)
    }

    /// Both clicks of a double-click in the sunburst's centre used to go up, two levels in all.
    @Test func aCentreDoubleClickGoesUpOnce() {
        let model = DiskMapFixtures.model(DiskMapFixtures.chain(depth: 5))
        model.focus = 4
        model.centerClicked(clickCount: 1)
        model.centerClicked(clickCount: 2)
        #expect(model.focus == 3)
    }

    /// One flat folder of 200,001 equal-size files, the worst case for a "size, then name" sort:
    /// the side list and the arrow keys cost 244 ms and 91 ms of main-actor time per selection change.
    @Test func aFlatFolderKeepsTheListAndArrowsCheap() async throws {
        var builder = DiskMapFixtures.Builder()
        let folder = builder.folder(ScanTree.root, "flat")
        for index in 0..<200_000 { builder.file(folder, "item-\(index)", 4_096) }
        builder.file(folder, "big.bin", 10_000_000_000)
        let model = DiskMapFixtures.model(builder.finished())
        let tree = model.tree!
        model.focus = folder
        model.style = .treemap
        await model.prepareLayout(model.layoutKey(width: 1000, height: 700, scale: 2))
        let counted = { model.listRows.reduce(0) { $0 + $1.bytes } }
        #expect(counted() == tree.allocatedSize(of: folder))

        let clock = ContinuousClock()
        let arrow = clock.measure { model.moveSelection(by: 1) }
        let rows = clock.measure { _ = model.listRows }
        print("flat folder: moveSelection \(arrow), listRows after it \(rows)")
        #expect(arrow < .milliseconds(50))
        #expect(rows < .milliseconds(5))

        model.showsAllSmallerItems = true
        #expect(model.listRows.count <= DiskMapModel.listPage + 3)
        #expect(counted() == tree.allocatedSize(of: folder))
        model.showMoreRows()
        #expect(model.listRows.count > DiskMapModel.listPage + 3)
        #expect(counted() == tree.allocatedSize(of: folder))
    }
}
