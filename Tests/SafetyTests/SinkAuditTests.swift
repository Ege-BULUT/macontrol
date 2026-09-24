import Foundation
import Testing

/// Every delete, move, flag change, launch or script in Sources/ sits in the few files allowed to do it
/// (docs/DESIGN-debloat.md section 3.10, the pattern Mole enforces with its sink audit). One forbidden list covers
/// every file; a rule that names files allows its token there and nowhere else. Whole-line `//` comments are skipped.
@Suite struct SinkAuditTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    struct Rule: Sendable {
        /// A regular expression.
        let pattern: String
        /// Paths below Sources/, matched as prefixes. Empty: allowed nowhere.
        let allowedIn: [String]

        init(_ pattern: String, _ allowedIn: [String] = []) {
            self.pattern = pattern
            self.allowedIn = allowedIn
        }

        init(literal: String) {
            self.init(NSRegularExpression.escapedPattern(for: literal))
        }
    }

    /// Tools run with an argument array at a fixed path: launchctl (v1 and the helper), CoreSimulator's simctl, tmutil.
    static let launchers = [
        "Uninstaller/Launchd", "Uninstaller/SimRuntime.swift", "Safety/RestorePoint.swift", "PrivilegedHelper/LaunchdSystem.swift",
    ]

    static let rules: [Rule] = [
        // Any use of the type, not only `Process(`: `Process.run(`, `.launchedProcess(`, `let p: Process = .init()`.
        Rule(#"(?:^|\W)Process(?:\W|$)"#, launchers),
        Rule("/bin/", launchers),
        // The helper's detach: one fork, never an exec (section 3.3 step 4).
        Rule(#"fork\(|"fork""#, ["PrivilegedHelper/main.swift"]),
        Rule(#"posix_spawn|vfork|exec[lv]"#),
        Rule("AppleScript", ["Safety/PrivilegedLauncher.swift"]),
        // RemovalEngine's walk, and the helper's request folder: two fixed names and the folder, by descriptor.
        Rule("unlinkat", ["Safety/RemovalEngine.swift", "Safety/PrivilegedRouting.swift"]),
        Rule(#"unlink(?!at)"#),
        Rule("renameatx_np|renamex_np", ["Safety/TrashService.swift", "Safety/TrashBatch.swift", "Safety/PrivilegedExecutor.swift"]),
        Rule(#"rename\(|renameat(?!x_np)"#),
        Rule(#"trashItem\("#, ["Safety/TrashService.swift"]),
        // No flag, mode or owner change to force a delete (F-0024, F-0070): chmod, fchmodat, lchown, chflags...
        Rule(#"(^|[^\w])[fl]?ch(mod|own|flags)(at)?\("#),
        // Whole words, so `.font(.system(size:))` passes.
        Rule(#"(?:^|[^\w.])system\("#),
    ] + [
        "setAttributes(", "setResourceValue", "removefile", "copyfile", "popen(", "\"/bin/rm\"", "\"/bin/sh\"",
        "\"/bin/bash\"", "\"/bin/zsh\"", "osascript", "OSAScript", "NSUserAppleScriptTask", "SBApplication",
        "removeItem(", "moveItem(", "replaceItem", "recycle(", "rmdir(", "setattrlist", "exchangedata",
    ].map { Rule(literal: $0) }

    /// Every rule broken in `files` (path below Sources/, text), plus the "only once" limits.
    static func audit(_ files: [(path: String, text: String)]) throws -> [String] {
        var offenses: [String] = []
        var scripts = 0
        var finderTrash = 0
        for (path, text) in files {
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for rule in rules where !rule.allowedIn.contains(where: path.hasPrefix) {
                if code.contains(try Regex(rule.pattern)) { offenses.append("\(path): \(rule.pattern)") }
            }
            if path == "PrivilegedHelper/main.swift", code.components(separatedBy: "\"fork\"").count > 2 {
                offenses.append("\(path): more than one fork")
            }
            scripts += code.components(separatedBy: "NSAppleScript(").count - 1
            finderTrash += code.components(separatedBy: "FileManager.default.trashItem(at:").count - 1
        }
        if scripts > 1 { offenses.append("NSAppleScript( \(scripts) times, one allowed") }
        if finderTrash > 1 { offenses.append("FileManager.default.trashItem(at: \(finderTrash) times, one allowed") }
        return offenses
    }

    static func audit(_ sample: String, in path: String) throws -> [String] {
        try audit([(path, sample)])
    }

    @Test func destructiveCallsLiveOnlyInTheirFiles() throws {
        let files = try Self.swiftFiles().map { file in
            (path: String(file.path.dropFirst(Self.sources.path.count + 1)), text: try String(contentsOf: file, encoding: .utf8))
        }
        #expect(files.count > 50 && files.contains { $0.path == "Safety/TrashService.swift" })
        let offenses = try Self.audit(files)
        #expect(offenses.isEmpty, "not allowed in these files: \(offenses)")
        // F-0053: the only way into the Trash is Finder's own, via FileManager.
        #expect(files.map { $0.text.components(separatedBy: "FileManager.default.trashItem(at:").count - 1 }.reduce(0, +) == 1)
        // Exactly one script: the launcher's fixed source (section 3.10).
        #expect(files.map { $0.text.components(separatedBy: "NSAppleScript(source:").count - 1 }.reduce(0, +) == 1)
    }

    /// One sample per rule: it fails outside its files, and passes in the first file it is allowed in.
    static let samples: [(sample: String, allowedIn: String?, outside: String)] = [
        ("let p = Process()", "PrivilegedHelper/LaunchdSystem.swift", "Safety/PrivilegedExecutor.swift"),
        ("process.executableURL = URL(fileURLWithPath: \"/usr/bin/tmutil\")", "Safety/RestorePoint.swift", "Safety/PrivilegedLauncher.swift"),
        ("@_silgen_name(\"fork\") private func detach() -> pid_t", "PrivilegedHelper/main.swift", "Safety/PrivilegedExecutor.swift"),
        ("let pid = fork()", "PrivilegedHelper/main.swift", "PrivilegedHelper/LaunchdSystem.swift"),
        ("posix_spawn(&pid, path, nil, nil, argv, nil)", nil, "PrivilegedHelper/main.swift"),
        ("var attributes = posix_spawnattr_t(nil)", nil, "Uninstaller/SimRuntime.swift"),
        ("let pid = vfork()", nil, "PrivilegedHelper/main.swift"),
        ("execv(path, argv)", nil, "PrivilegedHelper/main.swift"),
        ("@_silgen_name(\"execve\") func run() -> Int32", nil, "PrivilegedHelper/main.swift"),
        ("let script = NSAppleScript(source: source)", "Safety/PrivilegedLauncher.swift", "Safety/PrivilegedRouting.swift"),
        ("unlinkat(fd, name, AT_REMOVEDIR)", "Safety/RemovalEngine.swift", "Safety/PrivilegedExecutor.swift"),
        ("unlinkat(folder, \"request.json\", 0)", "Safety/PrivilegedRouting.swift", "Safety/PrivilegedLauncher.swift"),
        ("unlink(path)", nil, "Safety/RemovalEngine.swift"),
        ("renameatx_np(from, name, trash, name, UInt32(RENAME_EXCL))", "Safety/PrivilegedExecutor.swift", "Safety/RemovalEngine.swift"),
        ("renamex_np(a, b, UInt32(RENAME_EXCL))", "Safety/TrashBatch.swift", "Uninstaller/Uninstaller.swift"),
        ("rename(a, b)", nil, "Safety/TrashService.swift"),
        ("renameat(fd, a, fd, b)", nil, "Safety/TrashService.swift"),
        ("try FileManager.default.trashItem(at: url, resultingItemURL: nil)", "Safety/TrashService.swift", "Safety/PrivilegedExecutor.swift"),
        ("fchmodat(fd, name, 0o777, 0)", nil, "Safety/RemovalEngine.swift"),
        ("lchown(path, 0, 0)", nil, "Safety/PrivilegedExecutor.swift"),
        ("_ = chflags(path, 0)", nil, "Safety/TrashBatch.swift"),
        ("try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: p)", nil, "Safety/PrivilegedExecutor.swift"),
        ("try url.setResourceValue(false, forKey: .isUserImmutableKey)", nil, "Safety/RemovalEngine.swift"),
        ("removefile(path, nil, 0)", nil, "Safety/RemovalEngine.swift"),
        ("copyfile(a, b, nil, flags)", nil, "Safety/TrashService.swift"),
        ("let rm = URL(fileURLWithPath: \"/bin/rm\")", nil, "Uninstaller/LaunchdControl.swift"),
        ("process.executableURL = URL(fileURLWithPath: \"/bin/sh\")", nil, "PrivilegedHelper/LaunchdSystem.swift"),
        ("let tool = \"/usr/bin/osascript\"", nil, "Safety/PrivilegedLauncher.swift"),
        ("let status = system(command)", nil, "PrivilegedHelper/main.swift"),
        ("let pipe = popen(command, \"r\")", nil, "PrivilegedHelper/main.swift"),
        ("try FileManager.default.removeItem(at: url)", nil, "Safety/RemovalEngine.swift"),
        ("try FileManager.default.moveItem(at: a, to: b)", nil, "Safety/TrashBatch.swift"),
        ("rmdir(path)", nil, "Safety/RemovalEngine.swift"),
        ("try OSAScript(source: s).executeAndReturnError(nil)", nil, "Safety/PrivilegedLauncher.swift"),
        ("NSUserAppleScriptTask(url: u)", nil, "Safety/PrivilegedLauncher.swift"),
        ("SBApplication(bundleIdentifier: \"com.apple.finder\")", nil, "MacontrolUI/Clean/CleanModel.swift"),
        // Other ways to launch.
        ("_ = try Process.run(URL(fileURLWithPath: \"/usr/bin/true\"), arguments: [])", nil, "MacontrolUI/Clean/CleanModel.swift"),
        ("let p: Process = .init()", nil, "Cleaner/Cleaner.swift"),
        ("Process.launchedProcess(launchPath: a, arguments: [])", nil, "Safety/TrashService.swift"),
        ("Process\n.init()", nil, "ScanEngine/ScanEngine.swift"),
    ]

    @Test(arguments: samples.indices)
    func eachRuleFailsOutsideItsFiles(index: Int) throws {
        let (sample, allowedIn, outside) = Self.samples[index]
        #expect(try Self.audit(sample, in: outside) != [], "\(sample) in \(outside)")
        if let allowedIn {
            #expect(try Self.audit(sample, in: allowedIn) == [], "\(sample) in \(allowedIn)")
        }
    }

    @Test func nearMissesPass() throws {
        let passing: [(String, String)] = [
            ("request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)", "ScanEngine/BulkReader.swift"),
            (".font(.system(size: 12)) Font.system(size: 1) fileSystem(x)", "MacontrolUI/Clean/CleanRow.swift"),
            ("ProcessInfo.processInfo.environment", "Safety/PrivilegedLauncher.swift"),
            ("let processed = scanProcess(x)\nstruct ScanProcess {}", "Cleaner/Cleaner.swift"),
            ("/// Never removefile: as root it clears uchg.\n    // unlink(path) would follow a swapped parent", "Safety/RemovalEngine.swift"),
            ("Text(\"Deleted permanently\")", "MacontrolUI/Clean/TrashSheet.swift"),
        ]
        for (sample, path) in passing {
            #expect(try Self.audit(sample, in: path) == [], "\(sample)")
        }
    }

    @Test func onlyOnceMeansOnce() throws {
        let fork = "@_silgen_name(\"fork\") func a() -> pid_t\n@_silgen_name(\"fork\") func b() -> pid_t"
        #expect(try Self.audit(fork, in: "PrivilegedHelper/main.swift") != [])
        let scripts = [("Safety/PrivilegedLauncher.swift", "NSAppleScript(source: a)\nNSAppleScript(source: b)")]
        #expect(try Self.audit(scripts) != [])
        let trash = [
            ("Safety/TrashService.swift", "FileManager.default.trashItem(at: a, resultingItemURL: &r)"),
            ("Safety/TrashService.swift", "FileManager.default.trashItem(at: b, resultingItemURL: &r)"),
        ]
        #expect(try Self.audit(trash) != [])
    }

    /// DESIGN-debloat section 3.3 step 2: the app scrubs its environment before any other statement runs.
    @Test func appScrubsItsEnvironmentFirst() throws {
        let text = try String(contentsOf: Self.sources.appendingPathComponent("Macontrol/main.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("import ") }
        #expect(code.first == "PrivilegedLauncher.scrubEnvironment()")
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}
