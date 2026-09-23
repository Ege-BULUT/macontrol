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
    ]

    @Test func destructiveCallsLiveOnlyInSafety() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() where !file.path.contains("/Sources/Safety/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in Self.destructive where text.contains(token) {
                offenders.append("\(file.lastPathComponent): \(token)")
            }
            // Launching tools is allowed only for launchd control, with an argument array.
            if text.contains("Process(") && !file.path.contains("/Sources/Uninstaller/Launchd") {
                offenders.append("\(file.lastPathComponent): Process(")
            }
        }
        #expect(offenders.isEmpty, "move these calls behind Safety: \(offenders)")
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}
