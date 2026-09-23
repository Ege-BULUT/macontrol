import Foundation
import MacontrolCore
@testable import MacontrolUI
import Safety
import ScanEngine
import Testing

/// The disk map as the user drives it: a real scan of a hostile tree, items staged on the Discard Pile, the review
/// sheet confirmed, then Undo from History.
@MainActor @Suite struct DiskMapAttackTests {
    let box: Sandbox

    init() throws {
        box = try Sandbox()
    }

    /// A model whose add-time check protects the sandbox's home, as the app's protects the real one.
    func scannedModel(_ relative: String) async throws -> DiskMapModel {
        let model = DiskMapModel(engine: ScanEngine(), trash: box.service())
        let home = box.home
        model.pile = DiscardPile { ProtectedPaths.refusal(for: $0, home: home) }
        await model.scan(box.url(relative))
        #expect(model.scanError == nil)
        return model
    }

    func node(_ relative: String, in model: DiskMapModel) throws -> Int {
        let tree = try #require(model.tree)
        var node = ScanTree.root
        for name in relative.split(separator: "/").map(String.init) {
            node = try #require(tree.children(of: node).first { tree.name(of: $0) == name }, "\(name) is not on the map")
        }
        return node
    }

    func confirm(_ model: DiskMapModel) async throws -> [ReviewOutcome] {
        model.beginReview()
        await model.confirmReview()
        guard case .done(let outcomes)? = model.review?.phase else { throw CancellationError() }
        return outcomes
    }

    /// A link to Documents, a hard link of a Documents file, a Cyrillic lookalike next to its Latin twin and every
    /// shell-hostile name: each staged item moves as itself, nothing else does, and one Undo brings all back.
    @Test func stagedLinksAndHostileNamesMoveAsThemselves() async throws {
        try box.file("home/Documents/big.bin", size: 1 << 20)
        try box.file("scan/blobs/blob", size: 1 << 16)
        try box.tmp.hardLink("scan/hl.bin", to: "home/Documents/big.bin")
        try FileManager.default.createSymbolicLink(at: box.url("scan/to-docs"), withDestinationURL: box.url("home/Documents"))
        for name in HostileNames.shell + [HostileNames.lookalike, "Cache", "keep.txt"] {
            try box.file("scan/\(name)")
        }
        let model = try await scannedModel("scan")
        let staged = ["blobs", "hl.bin", "to-docs", HostileNames.lookalike] + HostileNames.shell
        for name in staged {
            model.stage(try node(name, in: model))
        }
        #expect(model.pile.items.count == staged.count, "\(model.stagingMessage ?? "")")
        let before = box.tree()

        let outcomes = try await confirm(model)

        #expect(outcomes.count == staged.count && outcomes.allSatisfy { $0.status == .inTrash })
        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: staged.map { "scan/\($0)" })) == [])
        let service = try #require(model.trashService)
        let batch = try #require(await service.history().first?.batch)
        #expect(await service.undo(batch: batch).allSatisfy { $0.isRestored })
        #expect(Sandbox.difference(box.tree(), before) == [])
    }

    /// After staging, a folder becomes a link to Documents and a file's folder a link to a project holding a file
    /// of the same name. Neither moves; both stay on the pile with the reason.
    @Test func stagedItemsSwappedForLinksAreNotMoved() async throws {
        try box.file("home/Documents/thesis.docx")
        try box.file("home/Documents/proj/data.bin")
        try box.file("scan/victim/blob")
        try box.file("scan/other/data.bin")
        let model = try await scannedModel("scan")
        model.stage(try node("victim", in: model))
        model.stage(try node("other/data.bin", in: model))
        try box.swapForSymlink("scan/victim", to: box.url("home/Documents"))
        try box.swapForSymlink("scan/other", to: box.url("home/Documents/proj"))
        let before = box.tree()

        let outcomes = try await confirm(model)

        #expect(outcomes.count == 2 && outcomes.allSatisfy { $0.status != .inTrash })
        #expect(box.tree() == before)
        #expect(model.pile.items.allSatisfy { $0.note != nil })
    }

    /// Scanning the home itself: Library, Documents, `.ssh` and a key inside it never reach the pile.
    @Test func protectedFoldersOfTheScannedHomeCannotBeStaged() async throws {
        try box.file("home/.ssh/id_ed25519")
        try box.file("home/Library/Keychains/login.keychain-db")
        try box.file("home/Library/Caches/com.example.cache/blob")
        let model = try await scannedModel("home")

        for protected in ["Library", "Documents", ".ssh", ".ssh/id_ed25519", "Library/Keychains", "Library/Caches"] {
            model.stage(try node(protected, in: model))
            #expect(model.pile.items.isEmpty, "\(protected) was staged")
        }
        model.stage(try node("Library/Caches/com.example.cache", in: model))
        #expect(model.pile.items.count == 1)
    }
}
