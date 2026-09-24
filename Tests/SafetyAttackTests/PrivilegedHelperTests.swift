import Darwin
import Foundation
import MacontrolCore
import os
@testable import Safety
import TestSupport
import Testing

/// The built debug `macontrol-priv`, run directly as the current user (never as root) on a `RootFixture`, driven by the
/// app's real routing through a launcher that starts it with the test flags instead of the administrator dialog
/// (DESIGN-debloat section 3.9).
@Suite(.serialized) struct PrivilegedHelperTests {
    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `swift build --build-tests` builds it; a binary older than its sources would test old code, so that fails.
    static func helperBinary() throws -> URL {
        let binary = package.appendingPathComponent(".build/debug/macontrol-priv")
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let sources = ["Sources/PrivilegedHelper", "Sources/Safety", "Sources/MacontrolCore"].flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: package.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
        }
        let built = try #require(modified(binary), "no \(binary.path): run swift build --build-tests")
        let newest = try #require(sources.compactMap(modified).max())
        try #require(built >= newest, "macontrol-priv is older than its sources: run swift build --build-tests")
        return binary
    }

    /// Starts the helper as `do shell script` would, minus root: argv, then its exit status. `afterCheck` runs once
    /// the parent has returned (the foreground check passed and the child detached); then the hold is released.
    static func launcher(
        _ fx: RootFixture, holdAt: Int? = nil, beforeCheck: @escaping @Sendable (URL) -> Void = { _ in },
        afterCheck: @escaping @Sendable (URL) -> Void = { _ in }, release: Bool = true,
        prompt: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> PrivilegedLauncher {
        let binary = try helperBinary()
        let root = fx.root.path
        let home = fx.home.path
        let hold = fx.url("hold").path
        return PrivilegedLauncher(helperURL: binary) { helper, request, sha, text in
            prompt(text)
            beforeCheck(request)
            let process = Process()
            process.executableURL = helper
            process.arguments = [request.path, sha, "--test-root", root, "--test-home", home]
                + (holdAt.map { ["--test-hold", hold, String($0)] } ?? [])
            try process.run()
            // Not waitUntilExit: that turns the main run loop inside a main-actor job.
            while process.isRunning { usleep(10_000) }
            guard process.terminationStatus == 0 else { throw PrivilegedError.helperRejected(process.terminationStatus) }
            afterCheck(request)
            if release { FileManager.default.createFile(atPath: hold, contents: nil) }
        }
    }

    static func item(_ fx: RootFixture, _ relative: String, requiresGone: String? = nil) throws -> TrashItem {
        let url = fx.url(relative)
        return TrashItem(url: url, expectedIdentity: FileIdentity(url: url), allocated: 4096,
                         requiresGone: requiresGone.map { fx.url($0) })
    }

    static func run(_ fx: RootFixture, _ items: [TrashItem], mode: DeletionMode = .trash, launcher: PrivilegedLauncher, batch: UUID = UUID()) async -> [TrashOutcome] {
        await PrivilegedRouting.run(
            items, mode: mode, launcher: launcher, batch: batch, journalURL: journal(fx), home: fx.home,
            restorePoint: nil, resultOwner: getuid(), systemRoot: fx.root.path
        )
    }

    static func journal(_ fx: RootFixture) -> URL {
        fx.home.appendingPathComponent("Library/Application Support/Macontrol/trash-journal.jsonl")
    }

    static func requestFolders(_ fx: RootFixture) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: journal(fx).deletingLastPathComponent().appendingPathComponent("priv").path)) ?? []
    }

    /// The parent returns before any item is touched; the child answers every item in order, the journal gets one
    /// administrator line per item moved, and the request folder is gone afterwards. An item outside the allowlist
    /// never reaches the helper.
    @Test func theHelperDetachesThenAnswersEveryItem() async throws {
        let fx = try RootFixture()
        try fx.file("root/Applications/Tool.app/Contents/MacOS/Tool")
        try fx.file("root/Library/Caches/com.vendor.tool/cache.db")
        try fx.file("root/private/etc/sudoers")
        let items = [
            try Self.item(fx, "root/Applications/Tool.app"),
            try Self.item(fx, "root/Library/Caches/com.vendor.tool", requiresGone: "root/Applications/Tool.app"),
            try Self.item(fx, "root/private/etc/sudoers"),
        ]
        let bundle = fx.url("root/Applications/Tool.app").path
        let untouchedAtDetach = OSAllocatedUnfairLock(initialState: false)
        let prompts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let batch = UUID()

        let outcomes = await Self.run(fx, items, launcher: try Self.launcher(fx, holdAt: 0, afterCheck: { _ in
            untouchedAtDetach.withLock { $0 = FileManager.default.fileExists(atPath: bundle) }
        }, prompt: { text in prompts.withLock { $0.append(text) } }), batch: batch)

        #expect(untouchedAtDetach.withLock { $0 })
        // The dialog counts only what the helper may act on: sudoers was refused in the app, before any dialog.
        #expect(prompts.withLock { $0 } == ["macontrol needs your administrator password to move 2 items owned by the system to the Trash."])
        #expect(outcomes == [
            .trashed(original: items[0].url, trashedTo: fx.trash.appendingPathComponent("Tool.app")),
            .trashed(original: items[1].url, trashedTo: fx.trash.appendingPathComponent("com.vendor.tool")),
            .refused(items[2].url, .protectedLocation(items[2].url.path)),
        ])
        let lines = TrashJournal(url: Self.journal(fx)).entries().reversed()
        #expect(lines.map(\.originalPath) == [items[0].url.path, items[1].url.path])
        #expect(lines.allSatisfy { $0.asAdministrator && $0.batch == batch && $0.trashedPath != nil })
        #expect(Self.requestFolders(fx).isEmpty)
        #expect(FileManager.default.fileExists(atPath: items[2].url.path))
    }

    /// sec 1: once the check passed, a rewritten `request.json` changes nothing; the child works from the bytes it
    /// checked. (Rewritten in place, same inode, while the child waits before its first item.)
    @Test func aRequestRewrittenAfterTheCheckChangesNothing() async throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Caches/Vendor/a")
        let canary = try fx.file("root/Library/Caches/Canary/b").deletingLastPathComponent()
        let forged = try PrivilegedRequest(op: .trash, items: [
            .init(path: canary.path, identity: try #require(FileIdentity(url: canary))),
        ]).encoded()
        let item = try Self.item(fx, "root/Library/Caches/Vendor")

        let outcomes = await Self.run(fx, [item], launcher: try Self.launcher(fx, holdAt: 0, afterCheck: { request in
            let handle = try? FileHandle(forWritingTo: request)
            try? handle?.truncate(atOffset: 0)
            try? handle?.write(contentsOf: forged)
            try? handle?.close()
        }))

        #expect(outcomes == [.trashed(original: item.url, trashedTo: fx.trash.appendingPathComponent("Vendor"))])
        #expect(FileManager.default.fileExists(atPath: canary.path))
        #expect(fx.trashNames == ["Vendor"])
    }

    /// A request rewritten between the app's hash and the helper's check is refused (77) and moves nothing.
    @Test func aRequestRewrittenBeforeTheCheckIsRefused() async throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Caches/Vendor/a")
        let canary = try fx.file("root/Library/Caches/Canary/b").deletingLastPathComponent()
        let forged = try PrivilegedRequest(op: .trash, items: [
            .init(path: canary.path, identity: try #require(FileIdentity(url: canary))),
        ]).encoded()
        let item = try Self.item(fx, "root/Library/Caches/Vendor")
        let before = fx.tree()

        let outcomes = await Self.run(fx, [item], launcher: try Self.launcher(fx, beforeCheck: { request in
            let handle = try? FileHandle(forWritingTo: request)
            try? handle?.truncate(atOffset: 0)
            try? handle?.write(contentsOf: forged)
            try? handle?.close()
        }))

        #expect(outcomes == [.failed(item.url, message: "The administrator helper refused the request (exit 77), so nothing was removed.")])
        #expect(Sandbox.difference(fx.tree(), before) == [])
        #expect(fx.trashNames.isEmpty)
        #expect(Self.requestFolders(fx).isEmpty)
    }

    /// `kill -9` mid-batch: what it finished is reported and journaled; the rest is "stopped", untouched.
    @Test func aHelperKilledMidBatchLeavesTheRestAsStopped() async throws {
        let fx = try RootFixture()
        for name in ["A", "B", "C"] { try fx.file("root/Library/Caches/Vendor\(name)/x") }
        let items = try ["A", "B", "C"].map { try Self.item(fx, "root/Library/Caches/Vendor\($0)") }

        let outcomes = await Self.run(fx, items, launcher: try Self.launcher(fx, holdAt: 1, afterCheck: { request in
            // The child finished item 0 and waits before item 1: kill it there.
            let result = request.deletingLastPathComponent().appendingPathComponent("result.jsonl")
            for _ in 0..<500 {
                let lines = (try? String(contentsOf: result, encoding: .utf8))?.split(separator: "\n") ?? []
                if lines.count >= 2, let pid = try? JSONDecoder().decode(PrivilegedResultLine.self, from: Data(lines[0].utf8)).pid {
                    kill(pid, SIGKILL)
                    return
                }
                usleep(20_000)
            }
        }, release: false))

        let stopped = "The administrator helper stopped before it got to this."
        #expect(outcomes == [
            .trashed(original: items[0].url, trashedTo: fx.trash.appendingPathComponent("VendorA")),
            .failed(items[1].url, message: stopped), .failed(items[2].url, message: stopped),
        ])
        #expect(FileManager.default.fileExists(atPath: items[1].url.path) && FileManager.default.fileExists(atPath: items[2].url.path))
        #expect(TrashJournal(url: Self.journal(fx)).entries().map(\.originalPath) == [items[0].url.path])
    }

    /// The detached child uses frameworks after a fork without exec. Memory the parent does not pass on (os_log's
    /// region) crashed it in 3 to 9 of every 100 runs until main.swift marked every region inherited; 40 runs in a row
    /// all finishing would happen about 2 times in 100 with that bug.
    @Test func theDetachedChildSurvivesEveryRun() throws {
        let fx = try RootFixture()
        let binary = try Self.helperBinary()
        var folders: [URL] = []
        for run in 0..<40 {
            try fx.file("root/Library/Caches/Vendor\(run)/x")
            let folder = try fx.tmp.directory("requests/\(run)")
            #expect(chmod(folder.path, 0o700) == 0)
            let data = try PrivilegedRequest(op: .trash, items: [try fx.item("root/Library/Caches/Vendor\(run)")]).encoded()
            let request = folder.appendingPathComponent("request.json")
            try data.write(to: request)
            #expect(chmod(request.path, 0o600) == 0)
            let process = try Process.run(binary, arguments: [
                request.path, PrivilegedRequest.sha256(data), "--test-root", fx.root.path, "--test-home", fx.home.path,
            ])
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            folders.append(folder)
        }
        var unfinished = folders.map { $0.appendingPathComponent("result.jsonl") }
        for _ in 0..<300 where !unfinished.isEmpty {
            unfinished.removeAll { (try? String(contentsOf: $0, encoding: .utf8))?.hasSuffix("{\"done\":true}\n") == true }
            usleep(20_000)
        }
        #expect(unfinished.isEmpty, "\(unfinished.count) of 40 children never finished")
        #expect(fx.trashNames.count == 40)
    }

    /// A cancelled dialog, a helper that never started: every item keeps a clear failure, nothing moves.
    @Test func aCancelledDialogMovesNothing() async throws {
        let fx = try RootFixture()
        try fx.file("root/Library/Caches/Vendor/a")
        let item = try Self.item(fx, "root/Library/Caches/Vendor")
        let before = fx.tree()

        let outcomes = await Self.run(fx, [item], launcher: PrivilegedLauncher(helperURL: try Self.helperBinary()) { _, _, _, _ in
            throw PrivilegedError.cancelled
        })

        #expect(outcomes == [.failed(item.url, message: "Not removed: the administrator password was not given.")])
        #expect(Sandbox.difference(fx.tree(), before) == [])
        #expect(Self.requestFolders(fx).isEmpty)
    }
}
