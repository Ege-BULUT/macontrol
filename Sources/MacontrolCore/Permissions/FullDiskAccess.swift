import Darwin
import Foundation

/// Full Disk Access state, probed by trying to open files that only FDA unlocks.
///
/// Never read the system-wide TCC.db: any app can read it, so it reports a false "granted" (F-0001).
public enum FullDiskAccess: Sendable, Equatable {
    case granted
    case denied
    case unknown

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
}
