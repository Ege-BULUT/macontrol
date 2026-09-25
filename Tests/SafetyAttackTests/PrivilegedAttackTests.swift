import Darwin
import Foundation
import MacontrolCore
@testable import Safety
import TestSupport
import Testing

/// v0.2.0 attack (T-0084) on the administrator path: the built helper with hostile names, a result file of one run
/// kept and replayed into another, the shell line the dialog runs under every variable the scrub keeps, and the root
/// allowlist's first-component rule under case, lookalike and boundary spellings. Nothing here runs as root or shows a
/// dialog: the helper is the debug build, run as the current user on a `RootFixture`.
@Suite(.serialized) struct PrivilegedAttackTests {
    /// Waits until the helper's child has written its last line.
    static func waitForDone(_ result: URL) {
        for _ in 0..<500 {
            if (try? String(contentsOf: result, encoding: .utf8))?.hasSuffix("{\"done\":true}\n") == true { return }
            usleep(20_000)
        }
    }

    /// The test launcher, plus `after` once the helper's child has finished: where a same-user process acts on the
    /// request folder before the app opens the result.
    static func launcher(_ fx: RootFixture, after: @escaping @Sendable (_ result: URL) -> Void) throws -> PrivilegedLauncher {
        let inner = try PrivilegedHelperTests.launcher(fx)
        return PrivilegedLauncher(helperURL: inner.helperURL) { helper, request, sha, prompt in
            try inner.start(helper, request, sha, prompt)
            let result = request.deletingLastPathComponent().appendingPathComponent("result.jsonl")
            waitForDone(result)
            after(result)
        }
    }

    func expectNoCommandRan(_ folders: [URL], sourceLocation: SourceLocation = #_sourceLocation) {
        for folder in folders + [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            #expect(!names.contains { $0.hasPrefix("PWNED") }, "a command ran in \(folder.path)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Hostile names through the built helper

    /// Every shell-hostile name, as a folder and as a file in /Library/Application Support, through the app's routing,
    /// the request file and the built helper: each reaches the Trash under its own name (or is deleted), nothing runs,
    /// and History records each exact path.
    @Test(arguments: [DeletionMode.trash, .permanent])
    func hostileNamesGoThroughTheHelperAsThemselves(mode: DeletionMode) async throws {
        let fx = try RootFixture()
        let names = HostileNames.shell + [HostileNames.lookalike, HostileNames.decomposed]
        var items: [TrashItem] = []
        for name in names {
            try fx.file("root/Library/Application Support/\(name)/data")
            try fx.file("root/Library/Application Support/\(name)-file")
            items += [
                try PrivilegedHelperTests.item(fx, "root/Library/Application Support/\(name)"),
                try PrivilegedHelperTests.item(fx, "root/Library/Application Support/\(name)-file"),
            ]
        }

        let outcomes = await PrivilegedHelperTests.run(fx, items, mode: mode, launcher: try PrivilegedHelperTests.launcher(fx))

        #expect(outcomes.count == items.count && outcomes.allSatisfy(\.isDone), "\(outcomes)")
        for item in items { #expect(!FileManager.default.fileExists(atPath: item.url.path), "\(item.url.lastPathComponent) stayed") }
        let expectedTrash = mode == .trash ? items.map(\.url.lastPathComponent).sorted() : []
        #expect(fx.trashNames == expectedTrash)
        let journaled = TrashJournal(url: PrivilegedHelperTests.journal(fx)).entries().map(\.originalPath)
        #expect(Set(journaled) == Set(items.map(\.url.path)) && journaled.count == items.count)
        expectNoCommandRan([fx.tmp.url, fx.root, fx.home, fx.url("root/Library/Application Support")])
    }

    // MARK: A result file kept from one run and replayed into another

    /// Run A: the helper refuses its only item (its folder was replaced after the list was made). A same-user process
    /// adds a hard link to root's `result.jsonl` while it is still in the user's request folder, which it may do to any
    /// file it can see. The app sees two links and does not read run A's result (a link made after its open would not
    /// even cost that), but root's child wrote every line. The app then unlinks its own name, so the kept file is once
    /// more a regular root file with one link: the only things `ResultReader` checks.
    func keepRunA(_ fx: RootFixture, kept: URL) async throws -> TrashItem {
        try fx.file("root/Library/Caches/VendorA/x")
        let a = try PrivilegedHelperTests.item(fx, "root/Library/Caches/VendorA")
        try FileManager.default.removeItem(at: a.url)
        try fx.file("root/Library/Caches/VendorA/x")
        try fx.tmp.directory("kept")

        let outcomes = await PrivilegedHelperTests.run(fx, [a], launcher: try Self.launcher(fx) { result in _ = link(result.path, kept.path) })

        #expect(outcomes == [.failed(a.url, message: "The administrator helper's results could not be read.")])
        var info = stat()
        #expect(lstat(kept.path, &info) == 0 && info.st_nlink == 1, "the kept result should be back to one link")
        return a
    }

    /// Run B deletes its item permanently. Before the app opens B's result, the kept file of run A is renamed over it
    /// (the user owns the folder). Nothing in a result file names the request it answers, so the app takes run A's
    /// "refused: changed since the list" for B's item, which root really deleted, and journals nothing for it.
    @Test func aResultKeptFromAnotherRunIsNotTakenForThisOne() async throws {
        let fx = try RootFixture()
        let kept = fx.url("kept/result.jsonl")
        _ = try await keepRunA(fx, kept: kept)
        try fx.file("root/Library/Caches/VendorB/y")
        let b = try PrivilegedHelperTests.item(fx, "root/Library/Caches/VendorB")

        let answer = await PrivilegedHelperTests.answer(fx, [b], mode: .permanent, launcher: try Self.launcher(fx) { result in
            _ = rename(kept.path, result.path)
        })

        #expect(!FileManager.default.fileExists(atPath: b.url.path), "the helper did delete it")
        withKnownIssue("T-0089: result.jsonl is not bound to its request, so a kept root result of another run is believed") {
            #expect(answer.outcomes.first?.refusal == nil, "reported \(answer.outcomes) for an item root deleted")
        }
    }

    /// The same kept file in a request folder the user made, next to a `request.json` the user wrote: crash recovery
    /// at the next launch journals root's line for whatever path that request names, as moved by the administrator.
    @Test func recoveryDoesNotJournalAKeptResultAgainstARequestTheUserWrote() async throws {
        let fx = try RootFixture()
        let kept = fx.url("kept/result.jsonl")
        // Run C trashes its item, so its result carries a line recovery journals.
        try fx.file("root/Library/Caches/VendorC/x")
        let c = try PrivilegedHelperTests.item(fx, "root/Library/Caches/VendorC")
        try fx.tmp.directory("kept")
        let outcomes = await PrivilegedHelperTests.run(fx, [c], launcher: try Self.launcher(fx) { result in _ = link(result.path, kept.path) })
        #expect(outcomes == [.failed(c.url, message: "The administrator helper's results could not be read.")])
        #expect(fx.trashNames == ["VendorC"], "root's child did trash it")
        let thesis = try fx.file("home/Documents/thesis.docx")
        let priv = PrivilegedHelperTests.journal(fx).deletingLastPathComponent().appendingPathComponent("priv")
        let folder = priv.appendingPathComponent("\(UUID().uuidString).forged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try PrivilegedRequest(op: .permanent, items: [.init(path: thesis.path, identity: try #require(FileIdentity(url: thesis)))])
            .encoded().write(to: folder.appendingPathComponent("request.json"))
        #expect(rename(kept.path, folder.appendingPathComponent("result.jsonl").path) == 0)

        PrivilegedRouting.recover(journalURL: PrivilegedHelperTests.journal(fx), resultOwner: getuid())

        let claimed = TrashJournal(url: PrivilegedHelperTests.journal(fx)).entries().filter { $0.originalPath == thesis.path }
        #expect(FileManager.default.fileExists(atPath: thesis.path))
        withKnownIssue("T-0089: recovery maps a kept root result onto a request.json the user wrote") {
            #expect(claimed.isEmpty, "History says the administrator moved \(thesis.lastPathComponent): \(claimed)")
        }
    }

    // MARK: The shell line the dialog runs

    /// AppleScript's `quoted form of`.
    static func quotedForm(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs the dialog's shell line (`/bin/sh -c`, bash on macOS) with exactly `environment`, in `folder`; the
    /// arguments the probe saw after its own path, hex-encoded.
    static func shellLine(_ arguments: [String], environment: [String: String], in folder: URL) throws -> [String] {
        let out = folder.appendingPathComponent("argv.txt")
        try? FileManager.default.removeItem(at: out)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", arguments.map(quotedForm).joined(separator: " ")]
        process.environment = environment
        process.currentDirectoryURL = folder
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// sec 8: every variable the scrub keeps, holding text a shell would run if it evaluated it, runs nothing on the line
    /// the dialog runs, and the three arguments arrive byte for byte. The control proves the probe sees an injection:
    /// SHELLOPTS and PS4, which the scrub drops, do run code on the same line, and nothing once scrubbed.
    @Test func everyVariableTheScrubKeepsIsInertOnTheDialogsShellLine() throws {
        let tmp = try TemporaryDirectory()
        let folder = try tmp.directory("work dir 'q'")
        let probe = folder.appendingPathComponent("macontrol-priv")
        let out = folder.appendingPathComponent("argv.txt")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s' \"$a\" | xxd -p | tr -d '\\n'; echo; done > \(Self.quotedForm(out.path))\n".write(to: probe, atomically: true, encoding: .utf8)
        #expect(chmod(probe.path, 0o755) == 0)
        let arguments = [probe.path, folder.appendingPathComponent("req $(touch PWNED-arg).json").path, String(repeating: "a", count: 64)]
        let hex = arguments.dropFirst().map { Data($0.utf8).map { String(format: "%02x", $0) }.joined() }
        let values = ["$(touch PWNED-dollar)", "`touch PWNED-tick`", "() { :; }; touch PWNED-fn", "x; touch PWNED-semi", "x\ntouch PWNED-nl"]
        let names = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "__CF_USER_TEXT_ENCODING"]
        for shift in values.indices {
            var hostile = ["PATH": "/opt/evil:/usr/bin"]
            for (index, name) in names.enumerated() { hostile[name] = values[(index + shift) % values.count] }
            let kept = PrivilegedLauncher.scrubbed(hostile)
            #expect(PrivilegedLauncher.isScrubbed(kept) && kept.count == names.count + 1)

            #expect(try Self.shellLine(arguments, environment: kept, in: folder) == hex)
            expectNoCommandRan([folder, tmp.url])
        }

        // BASH_ENV rides along: bash run as sh ignores it (probed on macOS 26.6), so only PS4 is required to fire.
        let bashEnv = try tmp.file("bash-env")
        try "touch PWNED-bashenv\n".write(to: bashEnv, atomically: true, encoding: .utf8)
        let control = ["PATH": PrivilegedLauncher.fixedPath, "SHELLOPTS": "xtrace", "PS4": "$(touch PWNED-control)", "BASH_ENV": bashEnv.path]
        _ = try Self.shellLine(arguments, environment: control, in: folder)
        let ran = (try FileManager.default.contentsOfDirectory(atPath: folder.path)).filter { $0.hasPrefix("PWNED") }
        #expect(ran.contains("PWNED-control"), "the probe must see the control's injection")
        for name in ran { try FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        #expect(try Self.shellLine(arguments, environment: PrivilegedLauncher.scrubbed(control), in: folder) == hex)
        expectNoCommandRan([folder, tmp.url])
    }

    /// The launcher's check reads the live environment, so a variable something sets after the scrub (a framework's
    /// setenv) is caught before any dialog. It changes this process's environment for a moment, so it runs only with
    /// MACONTROL_ENV_TESTS=1, alone (--filter).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_ENV_TESTS"] == "1"))
    func aVariableSetAfterTheScrubIsSeenByTheCheck() {
        let name = "MACONTROL_ATTACK_PROBE_\(UUID().uuidString.prefix(8))"
        let clean = PrivilegedLauncher.scrubbed(ProcessInfo.processInfo.environment)
        setenv(name, "1", 1)
        let seen = ProcessInfo.processInfo.environment
        unsetenv(name)
        #expect(seen[name] == "1", "ProcessInfo's environment is a copy from launch: the launcher's check would miss BASH_ENV set later")
        #expect(!PrivilegedLauncher.isScrubbed(clean.merging([name: "1"]) { a, _ in a }))
        #expect(ProcessInfo.processInfo.environment[name] == nil)
    }

    // MARK: The root allowlist

    /// sec 3c under other spellings: case, a hidden or Apple-named first component in the user's Library, the parent and
    /// the neighbours of Apple content, and malformed identifiers. Each is refused; the controls pass.
    @Test func theFirstComponentRuleHoldsUnderOtherSpellings() {
        let home = "/Users/tester"
        let refused: [(String, String?)] = [
            ("/Library/Preferences/COM.APPLE.loginwindow.plist", nil),
            ("/Library/Preferences/Com.Apple.loginwindow.plist", "com.vendor.app"),
            ("/Library/Application Support/APPLE/x", nil),
            ("/Library/Application Support/apple/ParentalControls", nil),
            ("/Library/Caches/com.apple.xpc.launchd", nil),
            ("/Library/LaunchDaemons/com.apple.remoted.plist", nil),
            ("/Library/PrivilegedHelperTools/.hidden", nil),
            ("/Users/tester/Library/Preferences/com.apple.loginwindow.plist", nil),
            ("/Users/tester/Library/Application Support/.hidden/x", nil),
            ("/Library/Preferences/ORG.CUPS.PRINTERS.PLIST", nil),
            ("/Library/Application Support/SCRIPT EDITOR/x", nil),
            // Apple content's parent holds third-party loops too; its neighbours are not Apple content.
            ("/Library/Audio/Apple Loops", nil),
            ("/Library/Audio/Apple Loops/AppleX", nil),
            ("/Library/Audio/Apple Loops/Apple/../../Plug-Ins", nil),
            ("/Library/Developer/CoreSimulator/../CommandLineTools", nil),
            // Identifiers that are not three clean parts claim nothing.
            ("/Library/Preferences/com.apple.dt.Xcode.plist", "com.apple."),
            ("/Library/Preferences/com.apple.dt.Xcode.plist", "com.apple.dt.xcode."),
            ("/Library/Preferences/com.apple.dt.Xcode.plist", "com..apple.dt.Xcode"),
            ("/Library/Preferences/com.apple.dt.Xcode.plist", ""),
            // Another user's Library, from any requester.
            ("/Users/other/Library/Caches/com.vendor.x", nil),
            ("/Users/tester/../other/Library/Caches/com.vendor.x", nil),
        ]
        for (path, id) in refused {
            #expect(PrivilegedScope.refusal(canonical: path, home: home, bundleIdentifier: id) != nil, "\(path) \(id ?? "-") passed")
        }
        let allowed: [(String, String?)] = [
            ("/Library/Audio/Apple Loops/Apple", nil), ("/Library/Audio/Apple Loops Index", nil),
            ("/Library/Application Support/ProApps/x", nil), ("/Library/Preferences/COM.APPLE.DT.XCODE.plist", "com.apple.dt.Xcode"),
            ("/Users/tester/Library/Caches/com.vendor.x", nil),
        ]
        for (path, id) in allowed {
            #expect(PrivilegedScope.refusal(canonical: path, home: home, bundleIdentifier: id) == nil, "\(path) \(id ?? "-") refused")
        }
    }

    /// The executor acts for the user whose folder holds the request: another user's Library under the same root is
    /// outside the allowlist, while the requester's own item goes. Nothing of the other user's moves.
    @Test func anotherUsersLibraryIsOutsideTheRequestersScope() throws {
        let fx = try RootFixture()
        try fx.file("Users/other/Library/Caches/com.vendor.x/blob")
        try fx.file("home/Library/Caches/com.vendor.x/blob")
        let before = fx.tree()

        let lines = try fx.execute([try fx.item("Users/other/Library/Caches/com.vendor.x"), try fx.item("home/Library/Caches/com.vendor.x")])

        #expect(lines.map(\.status) == ["refused", "trashed"])
        #expect(lines.first?.refusalReason == .protectedLocation(fx.url("Users/other/Library/Caches/com.vendor.x").path))
        #expect(Sandbox.difference(fx.tree(), Sandbox.expected(before, without: ["home/Library/Caches/com.vendor.x"])) == [])
    }
}
