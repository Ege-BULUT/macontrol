import Foundation
import Testing

/// Every delete, move or shell-out goes through Sources/Safety. This test fails when any other
/// source file calls a destructive API directly (the pattern Mole enforces with its sink audit).
@Suite struct SinkAuditTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static let destructive = [
        "removeItem(", "trashItem(", "moveItem(", "replaceItem", "recycle(", "unlink(", "unlinkat(",
        "rmdir(", "rename(", "renameat", "renamex_np", "NSAppleScript", "osascript", "\"/bin/sh\"",
        "\"/bin/bash\"", "\"/bin/zsh\"", "\"/bin/rm\"",
        // Finder scripting by other doors (F-0018).
        "OSAScript", "NSUserAppleScriptTask", "SBApplication",
    ]

    @Test func destructiveCallsLiveOnlyInSafety() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() where !file.path.contains("/Sources/Safety/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Launching tools is allowed only for launchd control, with an argument array.
            let launchd = file.path.contains("/Sources/Uninstaller/Launchd")
            offenders += Self.offenses(in: text).filter { !(launchd && $0 == "Process") }.map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(offenders.isEmpty, "move these calls behind Safety: \(offenders)")
    }

    static func offenses(in text: String) -> [String] {
        destructive.filter(text.contains) + cCalls(in: text).map { $0 + "(" } + (usesProcess(text) ? ["Process"] : [])
    }

    /// Any use of the type, not only `Process(`: `Process.run(`, `.launchedProcess(`, `let p: Process = .init()`.
    static func usesProcess(_ text: String) -> Bool {
        text.contains(#/(?:^|\W)Process(?:\W|$)/#)
    }

    @Test func everyWayToLaunchOrScriptIsFound() {
        let launches = [
            "_ = try Process.run(URL(fileURLWithPath: \"/usr/bin/true\"), arguments: [])", "let p = Process()",
            "let p: Process = .init()", "Process.launchedProcess(launchPath: a, arguments: [])", "Process\n.init()",
            "try OSAScript(source: s).executeAndReturnError(nil)", "NSUserAppleScriptTask(url: u)",
            "SBApplication(bundleIdentifier: \"com.apple.finder\")",
        ]
        for sample in launches {
            #expect(!Self.offenses(in: sample).isEmpty, "\(sample)")
        }
        for sample in ["ProcessInfo.processInfo.environment", "let processed = scanProcess(x)", "struct ScanProcess {}", "// processes"] {
            #expect(Self.offenses(in: sample).isEmpty, "\(sample)")
        }
    }

    /// C calls that delete, move or launch, matched as whole words so `.font(.system(size:))` passes.
    static func cCalls(in text: String) -> [String] {
        text.matches(of: #/(?:^|[^\w.])(removefile|copyfile|posix_spawnp?|popen|exec[lv]p?e?|system)\(/#).map { String($0.1) }
    }

    @Test func cCallsAreFoundAsWholeWords() {
        #expect(Self.cCalls(in: "let r = system(cmd); posix_spawn(&pid, p, nil, nil, argv, nil)") == ["system", "posix_spawn"])
        #expect(Self.cCalls(in: "removefile(p, nil, 0)\ncopyfile(a, b, nil, f)\npopen(c, \"r\")\nexecv(p, a)") == ["removefile", "copyfile", "popen", "execv"])
        #expect(Self.cCalls(in: ".font(.system(size: 12)) Font.system(size: 1) fileSystem(x)").isEmpty)
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}

/// The one door itself: Safety moves items to the Trash in-process and back again, and nothing else.
/// No permanent delete, no shell or AppleScript (F-0002, F-0012, F-0018), and no changing flags or
/// ownership to force a move (F-0024, F-0070).
@Suite struct SafetySinkTests {
    static let forbidden = [
        "removeItem(", "unlink", "rmdir(", "recycle(", "AppleScript", "osascript", "OSAScript", "SBApplication", "/bin/",
        "posix_spawn", "system(", "popen(", "execv", "execl", "removefile", "copyfile", "chmod(", "chown(", "chflags(",
        "setattrlist", "exchangedata", "moveItem(",
    ]

    @Test func safetyOnlyTrashesAndRestores() throws {
        var offenders: [String] = []
        var trashCalls = 0
        for file in try SinkAuditTests.swiftFiles() where file.path.contains("/Sources/Safety/") {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for token in Self.forbidden where code.contains(token) {
                offenders.append("\(file.lastPathComponent): \(token)")
            }
            if SinkAuditTests.usesProcess(code) { offenders.append("\(file.lastPathComponent): Process") }
            trashCalls += code.components(separatedBy: "FileManager.default.trashItem(at:").count - 1
        }
        #expect(offenders.isEmpty, "Safety must not do this: \(offenders)")
        // F-0053: the only way into the Trash is Finder's own, via FileManager.
        #expect(trashCalls == 1)
    }
}
