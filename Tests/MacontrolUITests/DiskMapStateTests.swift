import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
@testable import ScanEngine
import TestSupport
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
            let preview = Self.topLevel(sizes)
            model.receive(.preview(preview), generation: generation)
            return try Self.colours(MapLayoutBuilder.build(preview, DiskMapFixtures.key(style, version: model.previewVersion), colours: model.previewColours.slots), preview)
        }
        let first = try colours(["A": 300, "B": 200, "C": 100])
        let second = try colours(["A": 300, "B": 250, "C": 900, "D": 50])
        #expect(first.count == 3 && second.count == 4)
        #expect(second.filter { first[$0.key] != nil } == first, "C overtook A and B, and each kept its colour: \(first) -> \(second)")
        #expect(second["D"].map { !first.values.contains($0) } == true, "a newcomer takes a colour not in use yet")
    }

    /// T-0063 review 2: the finished map keeps the colours the scan's previews gave its folders. Coloured by
    /// rank, it recoloured 5 of 6 named folders at the moment it replaced the preview.
    @Test(arguments: MapStyle.allCases)
    func finishedMapKeepsThePreviewColours(style: MapStyle) async throws {
        let model = DiskMapModel(engine: nil, trash: nil)
        let generation = model.beginScan()
        model.receive(.preview(Self.topLevel(["C": 900, "A": 300, "B": 200])), generation: generation)
        let final = Self.topLevel(["A": 3_000, "B": 2_500, "C": 1_000, "D": 400])
        model.receive(.preview(final), generation: generation)
        let lastPreview = try Self.colours(MapLayoutBuilder.build(final, DiskMapFixtures.key(style), colours: model.previewColours.slots), final)
        model.receive(.completed(final), generation: generation)
        model.finishScan(generation)
        await model.prepareLayout(model.layoutKey(width: 800, height: 600, scale: 2))
        let map = try Self.colours(#require(model.layout), final)
        #expect(map == lastPreview)
        #expect(map == ["C": 0, "A": 1, "B": 2, "D": 3], "first seen C, A, B, then D; by rank it would be A, B, C, D")
    }

    /// T-0063 review 3: a home folder has more top-level items than there are colours, and its first preview
    /// has bytes for a few of them only. The finished map's eight largest still get eight colours, the ones it
    /// had in the last preview; a drawn folder changes colour only in the preview that brings it among the eight
    /// largest; and a second scan of the folder, which finds things in another order, keeps those eight colours
    /// all along (there, a smaller folder may give way to one of them once).
    /// Colours fixed by first sight, zero-byte items included, gave Downloads and .docker one colour here.
    @Test(arguments: MapStyle.allCases)
    func aHomeFolderScanKeepsItsLargestFoldersApart(style: MapStyle) async throws {
        let gb: UInt64 = 1 << 30
        let final: [String: UInt64] = [
            "Library": 60 * gb, "projects": 40 * gb, "Documents": 10 * gb, "Downloads": 8 * gb, "Movies": 5 * gb,
            ".cache": 3 * gb, "Pictures": 3 * gb / 2, ".docker": 2 * gb, "Music": gb, "Desktop": gb / 2, ".npm": gb / 3,
            ".vscode": gb / 5, ".Trash": gb / 8, "Applications": gb / 10, ".local": gb / 20, ".config": gb / 50,
            ".zsh_history": 200_000, ".ssh": 16_384, ".gitconfig": 4096, "Public": 0,
        ]
        func partly(_ share: [String: UInt64]) -> [String: UInt64] { final.mapValues { _ in 0 }.merging(share) { $1 } }
        func third(_ names: [String]) -> [String: UInt64] { partly(Dictionary(uniqueKeysWithValues: names.map { ($0, final[$0]! / 3) })) }
        let model = DiskMapModel(engine: nil, trash: nil)
        model.style = style
        var changes = 0

        /// Runs one scan through these previews and the final sizes, and returns the finished map's colours of the eight largest.
        func scan(_ generation: Int, _ previews: [[String: UInt64]], kept: [String: Int] = [:]) async throws -> [String: Int] {
            var last: [String: Int] = [:], largest: Set<String> = []
            for sizes in previews + [final] {
                let preview = Self.topLevel(sizes)
                model.receive(.preview(preview), generation: generation)
                let drawn = try Self.colours(MapLayoutBuilder.build(preview, DiskMapFixtures.key(style), colours: model.previewColours.slots), preview)
                let top = Set(sizes.filter { $0.value > 0 }.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(8).map(\.key))
                for (name, colour) in drawn where last[name].map({ $0 != colour }) == true {
                    changes += 1
                    #expect(!kept.isEmpty || top.contains(name) && !largest.contains(name), "\(name) changed colour")
                }
                #expect(kept.allSatisfy { name, colour in drawn[name] ?? colour == colour }, "the last map's largest keep their colours")
                last.merge(drawn) { $1 }
                largest = top
            }
            model.receive(.completed(Self.topLevel(final)), generation: generation)
            model.finishScan(generation)
            await model.prepareLayout(model.layoutKey(width: 800, height: 600, scale: 2))
            let tree = try #require(model.tree)
            let map = try #require(model.layout)
            let eight = map.topLevel.prefix(8).compactMap { index -> (String, Int)? in
                guard case .node(let node) = map.elements[index].item, let branch = map.elements[index].branch else { return nil }
                return (tree.name(of: node), branch)
            }
            #expect(eight.count == 8 && Set(eight.map(\.1)).count == 8, "\(eight)")
            #expect(eight.allSatisfy { last[$0.0] == $0.1 }, "the finished map keeps the last preview's colours: \(eight) vs \(last)")
            return Dictionary(uniqueKeysWithValues: eight)
        }

        let small = Dictionary(uniqueKeysWithValues: [".Trash", ".cache", ".config", ".local", ".npm", ".vscode", "Desktop", "Music"].map { ($0, UInt64(30 << 20)) })
        let first = try await scan(model.beginScan(), [
            partly([".zsh_history": 200_000, ".gitconfig": 4096, "Library": gb]),
            // Music and Downloads are drawn past the eighth, then grow among the eight largest.
            partly(small.merging(["Library": gb, "Downloads": 20 << 20, ".zsh_history": 200_000, ".gitconfig": 4096]) { $1 }),
            third(final.keys.filter { $0 != "projects" }),
        ])
        #expect(changes > 0)
        let again = try await scan(model.beginScan(of: URL(fileURLWithPath: "/x")), [
            partly(["Music": gb / 4, ".vscode": gb / 5, ".Trash": gb / 8, ".npm": 1000, ".ssh": 16_384]),
            third(["Music", ".vscode", ".Trash", ".npm", ".ssh", "Applications", ".local", "Movies"]),
            third(Array(final.keys)),
        ], kept: first)
        #expect(again == first, "a second scan of the folder: \(again) vs \(first)")
        print("home scan \(style): \(changes) colour changes")
    }

    /// T-0063 review 4: Move to Trash of one of the eight largest folders. The eight largest after it still have
    /// eight colours, the seven that stay keep theirs, and no two neighbours in the ring share one, the last and
    /// the first included. The splice did not recolour, so the folder that moved up kept a colour one of the
    /// eight had; and the ring's last folder was never checked against its first.
    @Test(arguments: MapStyle.allCases)
    func trashingOneOfTheLargestKeepsTheMapApart(style: MapStyle) async throws {
        let sizes = Dictionary(uniqueKeysWithValues: (0..<10).map { ("f\($0)", UInt64(1_000 - $0 * 60)) })
        for gone in (0..<8).map({ "f\($0)" }) {
            let model = DiskMapModel(engine: nil, trash: nil)
            model.pile = DiscardPile { _ in nil }
            model.style = style
            let generation = model.beginScan()
            model.receive(.preview(Self.topLevel(sizes)), generation: generation)
            model.receive(.completed(Self.topLevel(sizes)), generation: generation)
            model.finishScan(generation)
            let before = try await Self.ring(model)
            let tree = try #require(model.tree)
            let node = try #require(tree.children(of: ScanTree.root).first { tree.name(of: $0) == gone })
            model.stage(node)
            model.apply(TrashReport(batch: UUID(), outcomes: [.trashed(original: tree.url(of: node), trashedTo: URL(fileURLWithPath: "/.Trash/\(gone)"))]))
            let after = try await Self.ring(model)
            #expect(after.count == 9 && after.allSatisfy { $0.colour != nil }, "every folder is drawn, so the ring closes on two of them: \(after)")
            #expect(Set(after.prefix(8).map(\.colour)).count == 8, "\(gone) trashed: \(after)")
            #expect(before.prefix(8).allSatisfy { kept in kept.name == gone || after.contains { $0 == kept } }, "\(gone) trashed: \(before) -> \(after)")
            for index in after.indices {
                #expect(after[index].colour != after[(index + 1) % after.count].colour, "\(gone) trashed, neighbours \(index): \(after)")
            }
        }
    }

    /// T-0063 review 4: the app asks the engine for previews, and a scan that does not ask gets none. Dropping
    /// `previews: true` from DiskMapModel.scan took the live map out of the app with every test green.
    @Test func theAppAsksForPreviewsAndAPlainScanGetsNone() async throws {
        let folder = try TemporaryDirectory()
        for index in 0..<40 { try folder.file("d\(index)/f.bin", size: 4096) }
        var options = ScanOptions(workerCount: 1)
        options.progressInterval = 0.001
        options.firstPreview = .zero
        let model = DiskMapModel(engine: ScanEngine(options: options), trash: nil)
        model.readBytesInUse = { _ in nil }
        // A small tree can be walked before the first progress tick, so each side scans until a tick came.
        for _ in 0..<20 where model.previewVersion == 0 { await model.scan(folder.url) }
        #expect(model.previewVersion > 0)
        var progress = 0, previews = 0
        for _ in 0..<20 where progress == 0 {
            for try await event in ScanEngine(options: options).scan(folder.url) {
                if case .progress = event { progress += 1 }
                if case .preview = event { previews += 1 }
            }
        }
        #expect(progress > 0 && previews == 0, "\(progress) progress events, \(previews) previews")
    }

    /// T-0063: the bar's goal for a new folder is the volume's bytes in use, read off the main actor while the
    /// scan runs. An older scan's goal, or one that arrives after its scan ended, is dropped.
    @Test func volumeGoalIsReadOffTheMainActorForTheRunningScanOnly() async {
        let model = DiskMapModel(engine: nil, trash: nil)
        let root = URL(fileURLWithPath: "/")
        model.readBytesInUse = { _ in Thread.isMainThread ? 1 : 2 }
        let generation = model.beginScan()
        await model.readGoal(of: root, generation: generation).value
        #expect(model.expectedTotal?.bytes == 2, "1 means statfs ran on the main thread")
        #expect(model.expectedTotal?.isLastScan == false)
        let newer = model.beginScan()
        await model.readGoal(of: root, generation: generation).value
        #expect(model.expectedTotal == nil, "an older scan's goal")
        model.finishScan(newer)
        await model.readGoal(of: root, generation: newer).value
        #expect(model.expectedTotal == nil, "a goal that came after its scan ended")
    }

    /// T-0063: scanning the map's folder again aims at its last total at once, without reading the volume.
    @Test func aRescanAimsAtTheLastTotal() {
        let tree = DiskMapFixtures.mixed()
        let model = DiskMapModel(engine: nil, trash: nil, tree: tree)
        model.readBytesInUse = { _ in 1 }
        _ = model.beginScan(of: tree.rootURL)
        #expect(model.expectedTotal?.bytes == tree.allocatedSize(of: ScanTree.root))
        #expect(model.expectedTotal?.isLastScan == true)
        _ = model.beginScan(of: URL(fileURLWithPath: "/elsewhere"))
        #expect(model.expectedTotal == nil, "another folder waits for its volume's bytes in use")
    }

    /// T-0063 review 2: the walk never waits for the volume's bytes in use. On a hung network mount statfs does
    /// not return, and the scan (and Stop) waited for it.
    @Test func theWalkNeverWaitsForTheVolumeGoal() async throws {
        let folder = try TemporaryDirectory()
        try folder.file("a/one.bin", size: 8192)
        let model = DiskMapModel(engine: ScanEngine(), trash: nil)
        let hung = Self.hungVolumeRead()
        defer { hung.release() }
        model.readBytesInUse = hung.read
        await model.scan(folder.url)
        #expect(!hung.hasReturned(), "the scan waited for statfs")
        #expect(model.tree?.allocatedSize(of: ScanTree.root) ?? 0 >= 8192)
        #expect(!model.isScanning)
    }

    /// T-0063 review 2: Stop ends the scan while the volume read hangs, and keeps the map it had.
    /// With the goal awaited in front of the walk, Stop did nothing until statfs returned.
    @Test func stopEndsTheScanWhileTheVolumeReadHangs() async throws {
        let folder = try TemporaryDirectory()
        try folder.file("a/one.bin", size: 8192)
        let old = DiskMapFixtures.mixed()
        let model = DiskMapModel(engine: ScanEngine(), trash: nil, tree: old)
        let hung = Self.hungVolumeRead()
        defer { hung.release() }
        model.readBytesInUse = hung.read
        let scan = Task { await model.scan(folder.url) }
        scan.cancel()
        await scan.value
        #expect(!hung.hasReturned(), "Stop waited for statfs")
        #expect(model.tree?.count == old.count, "Stop keeps the map it had")
        #expect(!model.isScanning && model.preview == nil && model.progress == nil && model.expectedTotal == nil)
    }

    /// A volume read that hangs like statfs on a dead network mount, until `release` or two minutes pass.
    /// Tests ask `hasReturned` instead of timing the scan: in the full suite, main-actor work queues for 50 s.
    static func hungVolumeRead() -> (read: @Sendable (URL) -> UInt64?, release: () -> Void, hasReturned: () -> Bool) {
        let hung = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        let read: @Sendable (URL) -> UInt64? = { _ in
            _ = hung.wait(timeout: .now() + 120)
            returned.signal()
            return 1
        }
        return (read, { hung.signal() }, { returned.wait(timeout: .now()) == .success })
    }

    /// One level of folders with these sizes, like a preview.
    static func topLevel(_ sizes: [String: UInt64]) -> ScanTree {
        var tree = ScanTree(rootURL: URL(fileURLWithPath: "/x"), rootIdentity: FileIdentity(device: 1, inode: 1))
        for (offset, entry) in sizes.sorted(by: { $0.key < $1.key }).enumerated() {
            tree.addChild(
                of: ScanTree.root, name: entry.key, flags: .directory, allocated: entry.value, logical: 0,
                identity: FileIdentity(device: 1, inode: UInt64(offset + 2))
            )
        }
        tree.finalizeTotals()
        return tree
    }

    /// The map's top-level wedges or tiles in drawing order, each with its folder's name and colour slot.
    static func ring(_ model: DiskMapModel) async throws -> [Slice] {
        await model.prepareLayout(model.layoutKey(width: 800, height: 600, scale: 2))
        let layout = try #require(model.layout), tree = try #require(model.tree)
        return layout.topLevel.map { index in
            guard case .node(let node) = layout.elements[index].item else { return Slice(name: "smaller items", colour: nil) }
            return Slice(name: tree.name(of: node), colour: layout.elements[index].branch)
        }
    }

    struct Slice: Equatable, CustomStringConvertible {
        let name: String, colour: Int?
        var description: String { "\(name)=\(colour.map(String.init) ?? "-")" }
    }

    /// Each top-level folder's colour slot in `layout`.
    static func colours(_ layout: MapLayout, _ tree: ScanTree) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: layout.topLevel.compactMap { index in
            guard case .node(let node) = layout.elements[index].item, let branch = layout.elements[index].branch else { return nil }
            return (tree.name(of: node), branch)
        })
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
