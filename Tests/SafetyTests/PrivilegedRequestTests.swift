import Darwin
import Foundation
import MacontrolCore
@testable import Safety
import TestSupport
import Testing

/// DESIGN-debloat sections 3.4 and 3.9: the request format and the helper's foreground check, run in-process as the
/// current user (the debug executor takes the current euid, a temporary system root and home).
@Suite struct PrivilegedRequestTests {
    /// feasibility-privileged's quoteprobe.swift names, byte-exact through AppleScript there; here through the request.
    static let hostile = [
        "$(touch PWNED1)", "`touch PWNED2`", "a'b", "a\"b", "a\\b", "line1\nline2", "-rf", "*",
        "tab\there", "; touch PWNED3", "e\u{301}", "\u{e9}", "📁", "cr\rx", "'", "''", "\\'", "$HOME", "!!", "{a,b}", "~",
    ]

    @Test func hostileNamesSurviveTheRoundTrip() throws {
        #expect(Self.hostile.count == 21)
        let items = Self.hostile.enumerated().map { index, name in
            PrivilegedRequest.Item(
                path: "/Library/Caches/" + name, identity: FileIdentity(device: 1, inode: UInt64(index)), allocated: 7,
                bundleIdentifier: name, requiresGone: "/Applications/" + name + ".app"
            )
        }
        let request = PrivilegedRequest(op: .permanent, items: items)
        let data = try request.encoded()
        #expect(PrivilegedRequest.decode(data) == request)
        // One JSON document on one line, whatever the names hold.
        #expect(!data.contains(0x0A))
    }

    /// No Undo through root (D12, sec 2): the only operations are the two deletion modes.
    @Test func theRequestHasNoRestoreOperation() throws {
        #expect(DeletionMode(rawValue: "restore") == nil)
        let restore = #"{"version":1,"op":"restore","items":[{"path":"/Library/Caches/x","device":1,"inode":2,"allocated":0}]}"#
        #expect(PrivilegedRequest.decode(Data(restore.utf8)) == nil)
        let trash = restore.replacingOccurrences(of: "restore", with: "trash")
        #expect(PrivilegedRequest.decode(Data(trash.utf8))?.op == .trash)
    }

    // MARK: Foreground check

    /// A request folder the way the app makes it: `priv/<name>` 0700, `request.json` 0600.
    struct Folder {
        let tmp: TemporaryDirectory
        let folder: URL
        var request: URL { folder.appendingPathComponent("request.json") }
        var result: URL { folder.appendingPathComponent("result.jsonl") }

        init(_ contents: Data? = nil) throws {
            tmp = try TemporaryDirectory()
            try tmp.directory("home/.Trash")
            folder = try tmp.directory("priv/request")
            #expect(chmod(folder.path, 0o700) == 0)
            if let contents { try write(contents) }
        }

        func write(_ contents: Data) throws {
            try contents.write(to: request)
            #expect(chmod(request.path, 0o600) == 0)
        }

        var executor: PrivilegedExecutor {
            PrivilegedExecutor(testRoot: tmp.url.appendingPathComponent("root").path, home: tmp.url.appendingPathComponent("home").path,
                               launchctl: { _ in (1, "") })
        }

        func check(sha: String? = nil) -> Result<PrivilegedExecutor.Checked, PrivilegedExit> {
            let data = (try? Data(contentsOf: request)) ?? Data()
            return executor.check(requestPath: request.path, sha256: sha ?? PrivilegedRequest.sha256(data))
        }
    }

    static func valid() throws -> Data {
        try PrivilegedRequest(op: .trash, items: [.init(path: "/Library/Caches/x", identity: FileIdentity(device: 1, inode: 2))]).encoded()
    }

    static func exit(_ result: Result<PrivilegedExecutor.Checked, PrivilegedExit>) -> PrivilegedExit? {
        if case .failure(let exit) = result { exit } else { nil }
    }

    @Test func aValidRequestPassesAndCreatesTheResultFile() throws {
        let fx = try Folder(try Self.valid())
        guard case .success(let checked) = fx.check() else { Issue.record("refused"); return }
        #expect(checked.request.items.map(\.path) == ["/Library/Caches/x"])
        var info = stat()
        #expect(lstat(fx.result.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1)
        close(checked.result)
    }

    /// 65: malformed, oversized, unknown version, no items or too many.
    @Test func malformedRequestsExit65() throws {
        let item = #"{"path":"/Library/Caches/x","device":1,"inode":2,"allocated":0}"#
        let bodies = [
            "not json", "{}", #"{"version":2,"op":"trash","items":[\#(item)]}"#, #"{"version":1,"op":"trash","items":[]}"#,
            #"{"version":1,"op":"trash","items":[\#(Array(repeating: item, count: 10_001).joined(separator: ","))]}"#,
            #"{"version":1,"op":"trash","items":[{"path":"/x"}]}"#,
        ]
        for body in bodies {
            let fx = try Folder(Data(body.utf8))
            #expect(Self.exit(fx.check()) == .malformed, "\(body.prefix(60))")
        }
        let oversized = try Folder(Data(repeating: 0x20, count: (1 << 20) + 1))
        #expect(Self.exit(oversized.check()) == .malformed)
        let fx = try Folder(try Self.valid())
        #expect(Self.exit(fx.executor.check(requestPath: fx.request.path, sha256: "abc")) == .malformed)
        #expect(Self.exit(fx.executor.check(requestPath: fx.folder.appendingPathComponent("other.json").path, sha256: String(repeating: "0", count: 64))) == .malformed)
    }

    /// 77: the bytes are not the ones the user authorized, or someone else could have written them.
    @Test func untrustedRequestsExit77() throws {
        let valid = try Self.valid()
        let rewritten = try Folder(valid)
        let authorized = PrivilegedRequest.sha256(valid)
        try rewritten.write(try PrivilegedRequest(op: .trash, items: [.init(path: "/Library/Caches/y", identity: FileIdentity(device: 1, inode: 3))]).encoded())
        #expect(Self.exit(rewritten.check(sha: authorized)) == .notPermitted, "hash of a rewritten request")

        let readable = try Folder(valid)
        #expect(chmod(readable.request.path, 0o644) == 0)
        #expect(Self.exit(readable.check()) == .notPermitted, "request not 0600")

        let shared = try Folder(valid)
        #expect(chmod(shared.folder.path, 0o755) == 0)
        #expect(Self.exit(shared.check()) == .notPermitted, "folder not 0700")

        let linked = try Folder()
        let elsewhere = try linked.tmp.file("elsewhere.json")
        try valid.write(to: elsewhere)
        #expect(chmod(elsewhere.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: linked.request, withDestinationURL: elsewhere)
        #expect(Self.exit(linked.executor.check(requestPath: linked.request.path, sha256: PrivilegedRequest.sha256(valid))) == .notPermitted, "request is a link")

        let throughLink = try Folder(valid)
        let alias = try throughLink.tmp.symlink("alias", to: throughLink.folder.path)
        #expect(Self.exit(throughLink.executor.check(requestPath: alias.appendingPathComponent("request.json").path, sha256: PrivilegedRequest.sha256(valid))) == .notPermitted, "a link on the way")

        // A folder root owns (here /usr/share) is not a user's request.
        let fx = try Folder(valid)
        #expect(Self.exit(fx.executor.check(requestPath: "/usr/share/request.json", sha256: PrivilegedRequest.sha256(valid))) == .notPermitted, "root-owned folder")
    }

    /// 71: a name already at `result.jsonl` fails `O_EXCL`. A hard link there would otherwise let root append its
    /// lines to any file the link names.
    @Test(arguments: ["hardLink", "symlink", "file"]) func aPrePlacedResultFileExits71(kind: String) throws {
        let fx = try Folder(try Self.valid())
        let canary = try fx.tmp.file("canary.txt")
        try Data("canary".utf8).write(to: canary)
        switch kind {
        case "hardLink": try FileManager.default.linkItem(at: canary, to: fx.result)
        case "symlink": try FileManager.default.createSymbolicLink(at: fx.result, withDestinationURL: canary)
        default: try Data().write(to: fx.result)
        }
        #expect(Self.exit(fx.check()) == .systemError)
        #expect(try Data(contentsOf: canary) == Data("canary".utf8))
    }
}
