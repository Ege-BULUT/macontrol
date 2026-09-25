import Darwin
import Foundation
import MacontrolCore
@testable import MacontrolUI
@testable import Safety
import ScanEngine
import Testing

/// v0.2.0 attack (T-0084): the permanent remover while the tree changes under it, past the swaps the builders'
/// suites already make (a folder turned into a link mid-walk, a volume mounted mid-erase, entry 500 of 1,000). Each
/// test changes the trashed copy from the remover's own hook, between its look at an entry and its action on it.
@Suite struct EraseAttackTests {
    let box: Sandbox
    let caches = "home/Library/Caches"

    init() throws {
        box = try Sandbox()
    }

    /// The sandbox's Trash backend and journal, and a remover that stops the test process before it could act outside
    /// the sandbox. No administrator route: nothing here needs one.
    func service(hook: @escaping @Sendable (_ item: String, _ relative: String) -> Void) async -> TrashService {
        let root = box.tmp.url.path + "/"
        let engine = RemovalEngine { item, relative in
            precondition(item.hasPrefix(root), "a permanent delete outside the sandbox: \(item)")
            hook(item, relative)
        }
        return TrashService(
            journalURL: box.journal, backend: await box.service().backend, home: box.home, engine: engine,
            route: { items, _, _, _, _, _, _ in (items.map { .refused($0.url, .needsAdministrator) }, [:]) }
        )
    }

    func item(_ relative: String) -> TrashItem {
        TrashItem(url: box.url(relative), expectedIdentity: FileIdentity(url: box.url(relative)))
    }

    /// The path below the sandbox's Trash of the one entry ending in `suffix`, or nil.
    func inTrash(_ suffix: String) -> URL? {
        Sandbox.snapshot(of: box.trashFolder).keys.first { $0.hasSuffix(suffix) }.map { box.trashFolder.appendingPathComponent($0) }
    }

    func partlyMessage(_ report: TrashReport, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        guard case .failed(_, let message)? = report.outcomes.first, report.outcomes.count == 1 else {
            Issue.record("expected one failed outcome, got \(report.outcomes)", sourceLocation: sourceLocation)
            return nil
        }
        return message
    }

    /// Between the erase's look at `sub` and its open, `sub` is replaced by a real folder of Documents, renamed in (no
    /// link anywhere). The open's identity check refuses to enter it: every byte of it stays, in the Trash where the
    /// rename put it, and the item says it was partly deleted.
    @Test func aFolderSwappedForAnotherRealFolderMidEraseIsNotEntered() async throws {
        try box.file("\(caches)/com.example.mid/sub/a.bin")
        try box.file("\(caches)/com.example.mid/top.bin")
        try Data(repeating: 0x5A, count: 777).write(to: try box.file("home/Documents/proj/thesis.docx"))
        let box = box
        let service = await service { item, relative in
            guard relative == "sub" else { return }
            let sub = URL(fileURLWithPath: item).appendingPathComponent("sub")
            try? FileManager.default.moveItem(at: sub, to: box.url("moved-away-sub"))
            try? FileManager.default.moveItem(at: box.url("home/Documents/proj"), to: sub)
        }

        let report = await service.remove([item("\(caches)/com.example.mid")], mode: .permanent)

        let message = try #require(partlyMessage(report))
        #expect(message.hasPrefix("Partly deleted. 1 item inside could not be removed"), "\(message)")
        #expect(message.hasSuffix("First: sub: It changed while it was being deleted"), "\(message)")
        let thesis = try #require(inTrash("com.example.mid/sub/thesis.docx"), "Documents' folder was erased")
        #expect(try Data(contentsOf: thesis) == Data(repeating: 0x5A, count: 777))
        #expect(inTrash("com.example.mid/top.bin") == nil, "the rest of the folder still goes")
    }

    /// After the erase has read the folder's names, a hard link to a Documents file appears in it. It was never
    /// listed, so it is not removed; the folder stays in the Trash holding it, and the Documents file keeps its bytes.
    @Test func aHardLinkAddedMidEraseKeepsItsData() async throws {
        let big = try box.file("home/Documents/big.bin")
        try Data(repeating: 0xA5, count: 1 << 16).write(to: big)
        try box.file("\(caches)/com.example.late/a.bin")
        try box.file("\(caches)/com.example.late/b.bin")
        let once = Counter()
        let service = await service { item, relative in
            guard !relative.isEmpty, once.next() == 1 else { return }
            link(big.path, item + "/late.bin")
        }

        let report = await service.remove([item("\(caches)/com.example.late")], mode: .permanent)

        let message = try #require(partlyMessage(report))
        #expect(message.hasSuffix("First: com.example.late: Directory not empty"), "\(message)")
        #expect(try Data(contentsOf: big) == Data(repeating: 0xA5, count: 1 << 16))
        #expect(inTrash("com.example.late/late.bin") != nil)
        #expect(await box.service().history().map { $0.leftInTrash != nil } == [true], "History says where the rest is")
    }

    /// After the pre-flight walk found nothing locked, a file two levels down is locked (Finder's Locked) and, in the
    /// second case, the folder holding it. The erase never clears a flag: the locked entry stays in the Trash, still
    /// locked, with its bytes, and the rest of the item goes.
    @Test(arguments: ["a/b/keep.txt", "a/b"])
    func aLockAddedAfterThePreflightIsNeverCleared(locked: String) async throws {
        try Data(repeating: 0x33, count: 100).write(to: try box.file("\(caches)/com.example.lock/a/b/keep.txt"))
        try box.file("\(caches)/com.example.lock/a/junk.bin")
        try box.file("\(caches)/com.example.lock/top.bin")
        let service = await service { item, relative in
            if relative.isEmpty { chflags(item + "/" + locked, UInt32(UF_IMMUTABLE)) }
        }

        let report = await service.remove([item("\(caches)/com.example.lock")], mode: .permanent)

        let message = try #require(partlyMessage(report))
        #expect(message.hasSuffix(": Operation not permitted"), "\(message)")
        let kept = try #require(inTrash("com.example.lock/a/b/keep.txt"), "a locked entry was deleted")
        #expect(try Data(contentsOf: kept) == Data(repeating: 0x33, count: 100))
        let base = kept.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var info = stat()
        #expect(lstat(base.appendingPathComponent(locked).path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0, "the lock was cleared")
        #expect(inTrash("com.example.lock/a/junk.bin") == nil && inTrash("com.example.lock/top.bin") == nil)
    }
}

/// Disk Map in hardcore mode never reaches the administrator helper (DESIGN-debloat D8, r2: sec 3a), whatever its
/// Safety service could route: the stand-in route here records any call. The item is a user's folder holding a folder
/// this user can't write (a root-owned one on a real Mac): staging accepts it, and a permanent delete needs root to
/// empty it, which is exactly what Clean and Uninstall send to the helper.
@MainActor @Suite struct DiskMapNoLauncherAttackTests {
    @Test func aFolderOnlyRootCanEmptyNeverReachesTheHelperFromDiskMap() async throws {
        let box = try Sandbox()
        try box.file("scan/mixed/inner/blob")
        try box.file("scan/plain/blob")
        #expect(chmod(box.url("scan/mixed/inner").path, 0o555) == 0)
        defer { chmod(box.url("scan/mixed/inner").path, 0o755) }
        let routed = Calls()
        let service = TrashService(
            journalURL: box.journal, backend: await box.service().backend, home: box.home, engine: RemovalEngine { item, _ in
                precondition(item.hasPrefix(box.tmp.url.path + "/"), "a permanent delete outside the sandbox: \(item)")
            },
            route: { items, _, _, _, _, _, _ in
                routed.record(items.map(\.url.path))
                return (items.map { .deleted(original: $0.url) }, [:])
            }
        )
        let model = DiskMapModel(engine: ScanEngine(), trash: service)
        model.support = .demo
        model.hardcore.isOn = true
        await model.scan(box.url("scan"))
        let tree = try #require(model.tree)
        func node(_ path: String) throws -> Int {
            var node = ScanTree.root
            for name in path.split(separator: "/").map(String.init) {
                node = try #require(tree.children(of: node).first { tree.name(of: $0) == name })
            }
            return node
        }
        model.stage(try node("mixed"))
        model.stage(try node("plain"))
        #expect(model.pile.items.count == 2, "\(model.stagingMessage ?? "")")
        let before = box.tree()

        model.beginReview()
        #expect(model.review?.run.mode == .permanent)
        await model.confirmReview()

        #expect(routed.all.isEmpty, "Disk Map reached the administrator route: \(routed.all)")
        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: ["scan/plain"])) == [], "only the ordinary item goes")
        guard case .done(let outcomes)? = model.review?.phase else { Issue.record("the review did not finish"); return }
        #expect(outcomes.contains { $0.path.hasSuffix("scan/mixed") && $0.status == .notMoved(DiskMapText.refusal(.needsAdministrator)) }, "\(outcomes)")
    }
}
