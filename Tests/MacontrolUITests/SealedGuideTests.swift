import Foundation
import MacontrolCore
@testable import MacontrolUI
import Testing

/// The expert guide's commands (DESIGN-debloat section 5.3, r2: sec 12). Nothing here runs a guide command:
/// the only process is `/bin/sh -c 'printf %s …'`, which prints a quoted word back.
@Suite struct SealedGuideTests {
    static let sipOn = SystemIntegrity(filesystemProtected: true, authenticatedRoot: true, rootIsSealedSnapshot: true, systemDevice: "/dev/disk3s3")
    static let sipOff = SystemIntegrity(filesystemProtected: false, authenticatedRoot: false, rootIsSealedSnapshot: true, systemDevice: "/dev/disk3s3")
    static let home = URL(fileURLWithPath: "/Users/o'brien x")
    static let mountPoint = "/Users/o'brien x/sysmount"

    static let hostileNames = [
        "Chess", "It's", "''", "'", "a b", ";rm -rf ~", "`id`", "\"q\"", #"back\slash"#, "*", "!x", "Ümlaut",
        "-rf", "~", "..x", "--", "a\u{00A0}b", "中文", "a#b", "(x)|&<>",
    ]

    static func apps(_ names: [String], in folder: String = "/System/Applications") -> [URL] {
        names.map { URL(fileURLWithPath: folder).appendingPathComponent("\($0).app") }
    }

    /// What `/bin/sh` makes of one quoted word.
    static func shellWord(_ quoted: String) throws -> String {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf %s \(quoted)"]
        shell.environment = [:]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0, "\(quoted)")
        return String(decoding: data, as: UTF8.self)
    }

    @Test func hostileNamesRoundTripThroughTheShell() throws {
        let guide = SealedGuide(apps: Self.apps(Self.hostileNames) + Self.apps(["Terminal's"], in: "/System/Applications/Utilities"),
                                integrity: Self.sipOn, home: Self.home)
        #expect(guide.skipped.isEmpty && guide.unavailable == nil)
        let deletions = guide.commands.filter { $0.hasPrefix("sudo rm -rf ") }
        #expect(deletions.count == Self.hostileNames.count + 1)
        let expected = Self.hostileNames.map { "\(Self.mountPoint)/System/Applications/\($0).app" }
            + ["\(Self.mountPoint)/System/Applications/Utilities/Terminal's.app"]
        for (line, path) in zip(deletions, expected) {
            #expect(try Self.shellWord(String(line.dropFirst("sudo rm -rf ".count))) == path)
        }
        #expect(try Self.shellWord(SealedGuide.quote(Self.mountPoint)) == Self.mountPoint)
    }

    @Test func everyDeletionEndsInOneAppBelowTheMountPoint() throws {
        let guide = SealedGuide(apps: Self.apps(Self.hostileNames) + Self.apps(["Terminal"], in: "/System/Applications/Utilities"),
                                integrity: Self.sipOn, home: Self.home)
        let prefix = "sudo rm -rf '/Users/o'\\''brien x/sysmount/System/Applications/"
        let destructive = guide.commands.filter { $0.contains("rm ") }
        #expect(destructive.count == Self.hostileNames.count + 1)
        for line in destructive {
            #expect(line.hasPrefix(prefix), "\(line)")
            let tail = line.dropFirst(prefix.count)
            let app = tail.hasPrefix("Utilities/") ? tail.dropFirst("Utilities/".count) : tail
            #expect(app.hasSuffix(".app'") && !app.dropLast(5).contains("/"), "\(line)")
        }
    }

    @Test func noLineHasAShellVariable() {
        for integrity in [Self.sipOn, Self.sipOff] {
            let guide = SealedGuide(apps: Self.apps(Self.hostileNames + ["$HOME", "${x}"]), integrity: integrity, home: Self.home)
            #expect(!guide.commands.isEmpty)
            for line in guide.commands {
                #expect(!line.contains("$") && !line.contains("\n") && !line.contains("~/"), "\(line)")
            }
        }
    }

    @Test(arguments: [
        "/System/Applications/$HOME.app", "/System/Applications/a\nb.app", "/System/Applications/a\u{2028}b.app",
        "/System/Applications/a\tb.app", "/System/Applications/Chess", "/System/Applications/.app",
        "/System/Applications/Utilities/Extras/Chess.app", "/System/Applications/../../Chess.app",
        "/System/Applications/Utilities/../Chess.app", "/Applications/Safari.app", "/System/Library/CoreServices/Finder.app",
        "/Users/x/System/Applications/Chess.app",
    ])
    func appsTheGuideCannotWriteGetNoCommand(path: String) {
        let guide = SealedGuide(apps: [URL(fileURLWithPath: path)], integrity: Self.sipOn, home: Self.home)
        #expect(guide.removable.isEmpty && guide.skipped.count == 1)
        #expect(guide.steps.isEmpty && guide.unavailable != nil, "no reason to turn protection off")
        #expect(!guide.commands.contains { $0.contains("rm ") || $0.contains("mount") && !$0.contains("--mount '/'") })
    }

    @Test func aSkippedAppLeavesTheOthers() {
        let guide = SealedGuide(apps: Self.apps(["Chess", "$x"]), integrity: Self.sipOn, home: Self.home)
        #expect(guide.removable == ["System/Applications/Chess.app"])
        #expect(guide.skipped.map(\.name) == ["$x"])
        #expect(guide.commands.filter { $0.hasPrefix("sudo rm") }.count == 1)
    }

    @Test(arguments: [
        SystemIntegrity(filesystemProtected: true, authenticatedRoot: true, rootIsSealedSnapshot: true, systemDevice: nil),
        SystemIntegrity(filesystemProtected: false, authenticatedRoot: false, rootIsSealedSnapshot: true, systemDevice: nil),
    ])
    func anUnknownDeviceShowsNoSteps(integrity: SystemIntegrity) {
        let guide = SealedGuide(apps: Self.apps(["Chess"]), integrity: integrity, home: Self.home)
        #expect(guide.steps.isEmpty && guide.unavailable != nil)
    }

    @Test(arguments: ["/Users/a$b", "/Users/a\nb"])
    func aHomeThatCannotBeWrittenShowsNoSteps(home: String) {
        let guide = SealedGuide(apps: Self.apps(["Chess"]), integrity: Self.sipOn, home: URL(fileURLWithPath: home))
        #expect(guide.steps.isEmpty && guide.unavailable != nil)
    }

    @Test func protectionsOnTurnThemOffInRecoveryFirst() {
        let guide = SealedGuide(apps: Self.apps(["Chess"]), integrity: Self.sipOn, home: Self.home)
        #expect(guide.steps.map(\.title) == [
            "Turn off FileVault", "Start up in macOS Recovery", "Turn off both protections in Recovery", "Check that both are off",
            "Mount the system volume", "Delete the apps", "Make the changed volume the one that starts up",
        ])
        #expect(guide.commands.prefix(7) == [
            "csrutil disable", "csrutil authenticated-root disable", "csrutil status", "csrutil authenticated-root status",
            "mkdir '/Users/o'\\''brien x/sysmount'",
            "sudo mount -o nobrowse -t apfs '/dev/disk3s3' '/Users/o'\\''brien x/sysmount'",
            "sudo rm -rf '/Users/o'\\''brien x/sysmount/System/Applications/Chess.app'",
        ])
        #expect(guide.undo.flatMap(\.commands) == [
            "sudo bless --mount '/' --bootefi --last-sealed-snapshot", "csrutil authenticated-root enable", "csrutil enable",
        ])
    }

    @Test func protectionsOffSkipTheRecoverySteps() {
        let guide = SealedGuide(apps: Self.apps(["Chess"]), integrity: Self.sipOff, home: Self.home)
        #expect(guide.steps.map(\.title) == ["Mount the system volume", "Delete the apps", "Make the changed volume the one that starts up"])
        #expect(!guide.steps.flatMap(\.commands).contains { $0.hasPrefix("csrutil") })
        #expect(SealedGuide.waitsForVerification.contains("macontrol doesn't remove system apps itself until"))
    }

    @Test func theRiskListNamesFileVaultTheWayBackAndWhatIsUntested() {
        let risks = SealedGuide.risks
        #expect(risks.count == 7)
        #expect(risks.contains("You must turn off FileVault first. Your files are not encrypted until you turn it back on, which takes hours."))
        #expect(risks.contains("The apps stay removed only while these protections stay off. Turning them back on brings the apps back."))
        #expect(risks.filter { $0.contains("(expected, not yet tested)") }.count == 2)
        #expect(risks.contains { $0.hasPrefix("Almost no space comes back") && $0.contains("(expected, not yet tested)") })
        #expect(risks.contains { $0.contains("Time Machine does not back up the system volume (expected, not yet tested)") })
    }

    /// docs/guides/remove-system-apps.md carries the same risks and steps, each step tagged like the sheet.
    @Test func theDocMirrorsTheSheet() throws {
        let doc = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/guides/remove-system-apps.md"),
            encoding: .utf8
        )
        let lines = doc.split(separator: "\n").map(String.init)
        for risk in SealedGuide.risks {
            #expect(lines.contains("- \(risk)"), "missing risk: \(risk)")
        }
        #expect(doc.contains(SealedGuide.acknowledgement))
        #expect(doc.contains(SealedGuide.protectionsOff) && doc.contains(SealedGuide.waitsForVerification))
        let on = SealedGuide(apps: Self.apps(["Chess"]), integrity: Self.sipOn, home: Self.home)
        for step in on.steps + on.undo {
            let tag = step.verified ? "*(verified)*" : "*(unverified)*"
            #expect(lines.contains { $0.hasPrefix("### ") && $0.contains(step.title) && $0.hasSuffix(tag) }, "\(step.title) \(tag)")
            if let detail = step.detail { #expect(doc.contains(detail), "\(step.title): detail differs") }
        }
        let headings = lines.filter { $0.hasPrefix("### ") }
        #expect(headings.count == on.steps.count + on.undo.count)
        #expect(headings.allSatisfy { $0.hasSuffix("*(verified)*") || $0.hasSuffix("*(unverified)*") })
    }
}
