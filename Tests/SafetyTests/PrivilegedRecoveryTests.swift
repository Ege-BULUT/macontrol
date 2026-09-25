import Darwin
import Foundation
import MacontrolCore
@testable import Safety
import TestSupport
import Testing

/// DESIGN-debloat section 3.8: what a helper finished while the app was gone reaches History once, and only from a
/// result file root created. Tests stand in for root with their own uid, except where the owner is the point.
@Suite struct PrivilegedRecoveryTests {
    struct Fixture {
        let tmp: TemporaryDirectory
        var journal: URL { tmp.url.appendingPathComponent("Macontrol/trash-journal.jsonl") }
        var priv: URL { tmp.url.appendingPathComponent("Macontrol/priv") }
        let batch = UUID()
        let items = [
            PrivilegedRequest.Item(path: "/Applications/Tool.app", identity: FileIdentity(device: 1, inode: 2), allocated: 10),
            PrivilegedRequest.Item(path: "/Library/Caches/com.vendor.tool", identity: FileIdentity(device: 1, inode: 3), allocated: 20),
        ]

        init() throws {
            tmp = try TemporaryDirectory()
            try tmp.directory("Macontrol/priv")
        }

        /// A request folder left behind: its request, and a result naming `pid` that trashed item 0 and refused item 1.
        @discardableResult
        func leftBehind(suffix: String = "abc123", pid: pid_t, done: Bool = false) throws -> URL {
            let folder = priv.appendingPathComponent("\(batch.uuidString).\(suffix)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let request = try PrivilegedRequest(op: .trash, items: items).encoded()
            try request.write(to: folder.appendingPathComponent("request.json"))
            var lines = [
                PrivilegedResultLine(pid: pid, sha256: PrivilegedRequest.sha256(request)), .outcome(0, .trashed(to: "/Users/me/.Trash/Tool.app")),
                .outcome(1, .refused(.identityChanged)),
            ]
            if done { lines.append(PrivilegedResultLine(done: true)) }
            try Data(lines.flatMap { $0.encoded() }).write(to: folder.appendingPathComponent("result.jsonl"))
            return folder
        }

        var entries: [JournalEntry] { TrashJournal(url: journal).entries() }
        var folders: [String] { (try? FileManager.default.contentsOfDirectory(atPath: priv.path)) ?? [] }
    }

    /// A process that has ended, so its pid is gone.
    static func deadPid() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func anOrphanedResultIsJournaledExactlyOnce() throws {
        let fx = try Fixture()
        let pid = try Self.deadPid()
        try fx.leftBehind(pid: pid)
        // The same batch left twice (a folder that could not be removed last time): still one line.
        try fx.leftBehind(suffix: "def456", pid: pid, done: true)

        PrivilegedRouting.recover(journalURL: fx.journal, resultOwner: getuid())
        PrivilegedRouting.recover(journalURL: fx.journal, resultOwner: getuid())

        #expect(fx.entries == [JournalEntry(
            batch: fx.batch, date: try #require(fx.entries.first?.date), originalPath: "/Applications/Tool.app",
            trashedPath: "/Users/me/.Trash/Tool.app", identity: FileIdentity(device: 1, inode: 2), allocated: 10,
            restored: false, asAdministrator: true
        )])
        #expect(fx.folders.isEmpty)
    }

    /// A same-user process can plant a result file, or hard-link one; neither is read, and both folders go.
    @Test func aResultRootDidNotCreateIsIgnored() async throws {
        let fx = try Fixture()
        try fx.leftBehind(pid: try Self.deadPid(), done: true)
        // Through the app's own entry point, which expects root: this file is the user's.
        await TrashService(journalURL: fx.journal, backend: TrashBackend { $0 }, home: fx.tmp.url).recoverPrivilegedResults()
        #expect(fx.entries.isEmpty)
        #expect(fx.folders.isEmpty)

        let linked = try fx.leftBehind(suffix: "link01", pid: try Self.deadPid(), done: true)
        let target = fx.tmp.url.appendingPathComponent("elsewhere.jsonl")
        try FileManager.default.linkItem(at: linked.appendingPathComponent("result.jsonl"), to: target)
        PrivilegedRouting.recover(journalURL: fx.journal, resultOwner: getuid())
        #expect(fx.entries.isEmpty)
        #expect(fx.folders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// A helper still at work (its pid alive, no `done`) is left alone until a later launch.
    @Test func aHelperStillRunningIsLeftAlone() throws {
        let fx = try Fixture()
        let folder = try fx.leftBehind(pid: getpid())
        PrivilegedRouting.recover(journalURL: fx.journal, resultOwner: getuid())
        #expect(fx.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.jsonl").path))
    }

    /// A request with no result (the dialog was cancelled, or the app crashed before it) is removed.
    @Test func aRequestWithoutAResultIsRemoved() throws {
        let fx = try Fixture()
        let folder = fx.priv.appendingPathComponent("\(fx.batch.uuidString).zzz999")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("request.json"))
        PrivilegedRouting.recover(journalURL: fx.journal, resultOwner: getuid())
        #expect(fx.folders.isEmpty)
    }
}
