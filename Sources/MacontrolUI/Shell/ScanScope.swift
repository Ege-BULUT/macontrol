import Foundation

/// What the Disk Map scans, picked in the toolbar.
public enum ScanScope: Hashable, Sendable {
    case home
    case startupDisk
    case folder(URL)

    var url: URL {
        switch self {
        case .home: FileManager.default.homeDirectoryForCurrentUser
        // The Data volume holds everything writable; walking "/" would count it twice through firmlinks (F-0031).
        case .startupDisk: URL(fileURLWithPath: "/System/Volumes/Data")
        case .folder(let url): url
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .startupDisk: FileManager.default.displayName(atPath: "/")
        case .folder(let url): FileManager.default.displayName(atPath: url.path)
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .startupDisk: "internaldrive"
        case .folder: "folder"
        }
    }
}
