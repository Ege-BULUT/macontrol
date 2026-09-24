import Foundation
import MacontrolCore

/// The expert guide's text and commands for removing apps from the sealed system volume (DESIGN-debloat section 5.3,
/// feasibility-apple-apps "Guide text"). The user runs every command; macontrol runs none of them.
///
/// Commands carry literal absolute paths only, each single-quoted, never a shell variable (r2: sec 12). A name or
/// home folder that can't be written that way (a `$`, a control character) gets no command at all.
struct SealedGuide {
    struct Step: Identifiable, Hashable {
        var title: String
        var detail: String?
        var commands: [String] = []
        /// Checked on a real Mac. Everything else says "Unverified" next to it.
        var verified: Bool = false
        var id: String { title }
    }

    /// Before any command (r2: ux 10). Markdown: the last bullet starts in bold.
    static let risks = [
        "This lowers your Mac's security. With protection off, iPhone and iPad apps and Apple Pay may stop working (reported by others, unverified).",
        "You must turn off FileVault first. Your files are not encrypted until you turn it back on, which takes hours.",
        "The apps stay removed only while these protections stay off. Turning them back on brings the apps back.",
        "macOS updates bring these apps back, and may then install as a full download.",
        "Almost no space comes back: the previous sealed snapshot keeps the files (expected, not yet tested).",
        "A mistake can leave your Mac unable to start until you reinstall macOS from Recovery.",
        "**Make a Time Machine backup first.** Time Machine does not back up the system volume (expected, not yet tested); the way back is the previous sealed snapshot or reinstalling macOS, which keeps your files.",
    ]
    static let acknowledgement = "I have a backup and I accept these risks"
    static let protectionsOff = "System Integrity Protection and Authenticated Root are off on this Mac."
    static let waitsForVerification = "macontrol doesn't remove system apps itself until this procedure and its undo have been tested on macOS 14, 15 and 26. Until then, these are steps you run yourself."
    static let neededForUndo = "The undo steps need this app."
    /// The undo steps turn FileVault back on in System Settings and run `bless` in Terminal, so these are never removed.
    /// Lowercased: the system volume is case-insensitive.
    static let appsTheUndoNeeds: Set<String> = ["system/applications/system settings.app", "system/applications/utilities/terminal.app"]

    /// The apps' paths below the mount point, `System/Applications/Chess.app`, in the order given.
    let removable: [String]
    /// Apps that get no command, with the reason.
    let skipped: [(name: String, reason: String)]
    let steps: [Step]
    let undo: [Step]
    /// Why the guide shows no removal commands at all, when it doesn't.
    let unavailable: String?

    init(apps: [URL], integrity: SystemIntegrity, home: URL) {
        var removable: [String] = []
        var skipped: [(String, String)] = []
        for app in apps {
            let name = app.deletingPathExtension().lastPathComponent
            if let relative = Self.pathOnSystemVolume(app) {
                if Self.appsTheUndoNeeds.contains(relative.lowercased()) {
                    skipped.append((name, Self.neededForUndo))
                } else {
                    removable.append(relative)
                }
            } else {
                skipped.append((name, Self.isWritable(app.lastPathComponent)
                    ? "This guide covers only apps in /System/Applications and its Utilities folder."
                    : "Its name can't be written safely as a command."))
            }
        }
        self.removable = removable
        self.skipped = skipped

        let mountPoint = home.appendingPathComponent("sysmount").path
        let device = integrity.systemDevice
        let homeWritable = home.path.hasPrefix("/") && home.path.split(separator: "/").allSatisfy { Self.isWritable(String($0)) }
        unavailable = if removable.isEmpty {
            "None of the chosen apps can be removed this way."
        } else if device == nil {
            "macontrol couldn't read which disk holds this Mac's system volume, so it shows no commands. Stop here."
        } else if !homeWritable {
            "Your home folder's path can't be written safely as a command, so macontrol shows no commands. Stop here."
        } else {
            nil
        }

        // Without commands to run, turning the protections off would only lower security, so no step is shown.
        var steps: [Step] = []
        if unavailable == nil, !integrity.allowsSealedRemoval {
            steps += [
                Step(title: "Turn off FileVault",
                     detail: "System Settings > Privacy & Security > FileVault > Turn Off. Wait until it has finished; this can take hours."),
                Step(title: "Start up in macOS Recovery",
                     detail: "Mac with Apple silicon: shut down, then press and hold the power button until \"Loading startup options\" appears, and choose Options. Intel Mac: restart and hold Command-R."),
                Step(title: "Turn off both protections in Recovery",
                     detail: "In Recovery, choose Utilities > Terminal and run these two commands. Then restart from the Apple menu.",
                     commands: ["csrutil disable", "csrutil authenticated-root disable"]),
                Step(title: "Check that both are off",
                     detail: "Back in macOS, open Terminal. Both commands should say disabled. These only read, and need no password. Then open this guide in macontrol again and copy the next commands from there: they name the disk your Mac started up from, which can change after a restart.",
                     commands: ["csrutil status", "csrutil authenticated-root status"]),
            ]
        } else if unavailable == nil {
            // FileVault must be off (risk 2); with the protections already off, nothing else has checked that.
            steps.append(Step(title: "Check that FileVault is off",
                              detail: "Open Terminal. This command should say \"FileVault is Off.\" It only reads, and needs no password. If FileVault is on, stop here and turn it off first: System Settings > Privacy & Security > FileVault > Turn Off.",
                              commands: ["fdesetup status"],
                              verified: true))
        }
        if unavailable == nil, let device {
            steps += [
                Step(title: "Mount the system volume",
                     detail: "Makes an empty folder in your home folder and mounts this Mac's system volume there, the startup disk without its sealed snapshot. The second command asks for your password.",
                     commands: ["mkdir \(Self.quote(mountPoint))", "sudo mount -o nobrowse -t apfs \(Self.quote(device)) \(Self.quote(mountPoint))"]),
                Step(title: "Delete the apps",
                     detail: "Each command deletes one app from the mounted system volume.",
                     commands: removable.map { "sudo rm -rf \(Self.quote(mountPoint + "/" + $0))" }),
                Step(title: "Make the changed volume the one that starts up",
                     detail: "This creates a new system snapshot and starts up from it. Then restart your Mac.",
                     commands: ["sudo bless --mount \(Self.quote(mountPoint)) --bootefi --create-snapshot"]),
            ]
        }
        self.steps = steps
        // Nothing to undo without removal steps, and a stray `bless --last-sealed-snapshot` would revert other root changes.
        undo = steps.isEmpty ? [] : [
            Step(title: "Go back to the sealed snapshot",
                 detail: "Starts up from the previous sealed snapshot, which still has the apps. Then restart your Mac.",
                 commands: ["sudo bless --mount \(Self.quote("/")) --bootefi --last-sealed-snapshot"]),
            Step(title: "Turn both protections back on in Recovery",
                 detail: "Start up in macOS Recovery again, choose Utilities > Terminal, run these two commands, then restart.",
                 commands: ["csrutil authenticated-root enable", "csrutil enable"]),
            Step(title: "Turn FileVault back on",
                 detail: "System Settings > Privacy & Security > FileVault > Turn On."),
            Step(title: "If your Mac doesn't start up",
                 detail: "Start up in macOS Recovery and choose Reinstall macOS. It keeps your files."),
        ]
    }

    /// Every command of the removal steps and the undo steps, in order.
    var commands: [String] { (steps + undo).flatMap(\.commands) }

    /// `System/Applications/X.app` or `System/Applications/Utilities/X.app` for an app exactly there, nil otherwise.
    /// The raw path is compared, so `..` or a deeper folder never matches.
    static func pathOnSystemVolume(_ app: URL) -> String? {
        let file = app.lastPathComponent
        guard app.pathExtension == "app", file.count > 4, isWritable(file) else { return nil }
        switch app.deletingLastPathComponent().path {
        case "/System/Applications": return "System/Applications/\(file)"
        case "/System/Applications/Utilities": return "System/Applications/Utilities/\(file)"
        default: return nil
        }
    }

    /// A path component that can sit inside single quotes as it is: not empty, not `.` or `..`, and no `/`, `$`,
    /// line break or control character. Everything else, quotes and backticks included, is safe once quoted.
    static func isWritable(_ component: String) -> Bool {
        let unsafe = CharacterSet.controlCharacters.union(.newlines).union(CharacterSet(charactersIn: "/$"))
        return !component.isEmpty && component != "." && component != ".." && !component.unicodeScalars.contains(where: unsafe.contains)
    }

    /// One shell word: `'` becomes `'\''`.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
