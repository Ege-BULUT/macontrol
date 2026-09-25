import Foundation
@testable import Safety
import TestSupport
import Testing

/// DESIGN-debloat sections 3.3 and 3.9: the fixed AppleScript, the environment allowlist, and where the launcher and the
/// home folder may come from. Nothing here shows a dialog or runs anything as root.
@Suite struct PrivilegedLauncherTests {
    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The source in the code is the one the design reviewed, character for character.
    @Test func theScriptIsTheDesignedOne() throws {
        let design = try String(contentsOf: Self.package.appendingPathComponent("docs/DESIGN-debloat.md"), encoding: .utf8)
        let block = try #require(design.firstRange(of: "```applescript\n").map { design[$0.upperBound...] })
        let end = try #require(block.firstRange(of: "```"))
        let lines = block[..<end.lowerBound].split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
        let indent = lines.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        #expect(lines.map { $0.dropFirst(indent) }.joined(separator: "\n") == PrivilegedLauncher.script)
        #expect(PrivilegedLauncher.script.contains("with administrator privileges"))
    }

    /// The same source without "with administrator privileges" runs as the user: the three shell arguments arrive
    /// byte-exact and nothing in them runs, whatever they hold (feasibility-privileged fact 13).
    @MainActor @Test func theScriptQuotesEveryShellArgument() throws {
        let tmp = try TemporaryDirectory()
        let folder = try tmp.directory("dir with space and 'quote' $(touch PWNED0)")
        let probe = folder.appendingPathComponent("probe")
        let out = tmp.url.appendingPathComponent("argv.txt")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s' \"$a\" | xxd -p | tr -d '\\n'; echo; done > '\(out.path)'\n".write(to: probe, atomically: true, encoding: .utf8)
        #expect(chmod(probe.path, 0o755) == 0)
        let unprivileged = PrivilegedLauncher.script.replacingOccurrences(of: " with administrator privileges", with: "")
        #expect(unprivileged != PrivilegedLauncher.script)

        for pair in stride(from: 0, to: PrivilegedRequestTests.hostile.count, by: 2) {
            let names = Array(PrivilegedRequestTests.hostile[pair..<min(pair + 2, PrivilegedRequestTests.hostile.count)])
            let arguments = names + (names.count == 1 ? ["x"] : [])
            try PrivilegedLauncher.execute(unprivileged, [probe.path] + arguments + ["prompt $(touch PWNED4)"])
            let got = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(got == arguments.map { Data($0.utf8).map { String(format: "%02x", $0) }.joined() }, "\(names)")
        }
        let planted = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath).filter { $0.hasPrefix("PWNED") }
            + FileManager.default.contentsOfDirectory(atPath: tmp.url.path).filter { $0.hasPrefix("PWNED") }
        #expect(planted.isEmpty)
    }

    /// Exactly the allowlist survives, with `PATH` fixed; everything that can inject into `/bin/sh` goes.
    @Test func scrubbingKeepsExactlyTheAllowlist() {
        let environment = [
            "HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "LC_CTYPE": "UTF-8", "__CF_USER_TEXT_ENCODING": "0x1F5:0:0", "PATH": "/opt/evil:/usr/bin", "BASH_ENV": "/tmp/evil",
            "ENV": "/tmp/evil", "SHELLOPTS": "xtrace", "PS4": "$(touch x)", "BASH_FUNC_ls%%": "() { :; }",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "DEVELOPER_DIR": "/tmp/xcode", "SHELL": "/bin/zsh", "IFS": "x",
        ]
        #expect(PrivilegedLauncher.scrubbed(environment) == [
            "HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "LC_CTYPE": "UTF-8", "__CF_USER_TEXT_ENCODING": "0x1F5:0:0", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        #expect(PrivilegedLauncher.isScrubbed(PrivilegedLauncher.scrubbed(environment)))
        #expect(!PrivilegedLauncher.isScrubbed(environment))
        #expect(!PrivilegedLauncher.isScrubbed(["HOME": "/Users/me"]), "PATH must be the fixed one")
    }

    /// The launcher only checks the environment (main.swift scrubs it); a test process never scrubbed its own, so the
    /// real launcher must refuse here before any script runs.
    @MainActor @Test func theLauncherRefusesAnUnscrubbedEnvironment() throws {
        try #require(!PrivilegedLauncher.isScrubbed(ProcessInfo.processInfo.environment))
        #expect(throws: PrivilegedError.launchFailed("environment")) {
            try PrivilegedLauncher.runAsAdministrator(
                helper: URL(fileURLWithPath: "/nonexistent/macontrol-priv"), request: URL(fileURLWithPath: "/nonexistent/request.json"),
                sha256: String(repeating: "0", count: 64), prompt: "never shown"
            )
        }
    }

    @Test func noBundleNoLauncher() throws {
        let tmp = try TemporaryDirectory()
        let app = try tmp.directory("Plain.app/Contents")
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: app.appendingPathComponent("Info.plist"))
        let folder = try #require(Bundle(url: tmp.url))
        let bundle = try #require(Bundle(url: app.deletingLastPathComponent()))
        #expect(PrivilegedLauncher.bundled(folder) == nil)
        #expect(PrivilegedLauncher.bundled(bundle) == nil)
        try tmp.file("Plain.app/Contents/Helpers/macontrol-priv")
        let launcher = try #require(PrivilegedLauncher.bundled(bundle))
        #expect(launcher.helperURL.resolvingSymlinksInPath() == app.appendingPathComponent("Helpers/macontrol-priv").resolvingSymlinksInPath())
    }

    // MARK: Source greps

    static func sources(_ include: (String) -> Bool) throws -> [(path: String, text: String)] {
        try SinkAuditTests.swiftFiles().compactMap { file in
            let path = String(file.path.dropFirst(SinkAuditTests.sources.path.count + 1))
            return include(path) ? (path, try String(contentsOf: file, encoding: .utf8)) : nil
        }
    }

    /// F-0014: the launcher is built in one place, `AppModel.live()`, and handed only to the screens that confirm.
    @Test func theLauncherIsBuiltOnlyInAppModel() throws {
        let files = try Self.sources { _ in true }
        #expect(files.count > 50)
        let builders = files.filter { file in
            file.text.split(separator: "\n").contains { $0.contains("PrivilegedLauncher") && $0.contains(".bundled(") }
        }.map(\.path)
        #expect(builders == ["MacontrolUI/Shell/AppModel.swift"])
    }

    /// sec 6: in the helper's code, a forgotten argument must never mean this process's home (root's, as root).
    @Test func helperCodeNeverDefaultsToThisProcesssHome() throws {
        let files = try Self.sources { $0.hasPrefix("PrivilegedHelper/") || $0.hasPrefix("Safety/Privileged") }
        #expect(files.count >= 7)
        for (path, text) in files {
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for token in ["homeDirectoryForCurrentUser", "NSHomeDirectory", "applicationSupportDirectory", "defaultJournalURL", "ProtectedPaths.refusal(for:"] {
                #expect(!code.contains(token), "\(path): \(token)")
            }
            for match in code.matches(of: /ProtectionPolicy\(\s*([^)]*)/) {
                #expect(match.output.1.contains("home:") && match.output.1.contains("journal:"), "\(path): \(match.output.0)")
            }
        }
    }
}
