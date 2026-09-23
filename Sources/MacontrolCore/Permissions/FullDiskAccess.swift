import Darwin
import Foundation

/// Full Disk Access state, probed by trying to open files that only FDA unlocks.
///
/// There is no API for this (topic-distribution-permissions P1). Never read the system-wide
/// TCC.db: any app can read it, so it reports a false "granted" (F-0001).
public enum FullDiskAccess: Sendable, Equatable {
    case granted
    case denied
    case unknown

    /// One `open()` per path, cheap enough to poll every second. Opening also makes macOS list
    /// the app in the Full Disk Access pane most of the time (P8, not guaranteed).
    public static func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FullDiskAccess {
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari",
        ]
        var sawDenial = false
        for relative in probes {
            let fd = open(home.appendingPathComponent(relative).path, O_RDONLY | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { sawDenial = true }
        }
        return sawDenial ? .denied : .unknown
    }

    /// Opens the Full Disk Access pane of System Settings.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    /// The pre-Ventura pane id; 26.6 still maps it to the same pane (P2). Used if the first URL fails.
    public static let legacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// What a scan without FDA cannot see, in the words the user knows (C1, P3).
    public static let foldersSkippedWithout = ["Mail", "Messages", "Safari", "Cookies", "the Trash"]
}
