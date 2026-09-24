import Foundation
import Uninstaller

extension InstalledApp {
    /// Apple's: part of macOS, one of Apple's App Store apps, or any other `com.apple.*` bundle (Xcode, Safari).
    var isApple: Bool {
        kind != .thirdParty || bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true
    }
}

/// Which apps the Uninstall list shows. Stored with `@AppStorage`, so the raw values must not change.
enum AppFilter: String, CaseIterable, Identifiable {
    case all, user, system

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .user: "User"
        case .system: "System"
        }
    }

    /// "No user apps", "No system apps match".
    var emptyTitle: String {
        switch self {
        case .all: "No apps"
        case .user: "No user apps"
        case .system: "No system apps"
        }
    }

    func includes(_ app: InstalledApp) -> Bool {
        switch self {
        case .all: true
        case .user: !app.isApple
        case .system: app.isApple
        }
    }
}

/// The order of the Uninstall list. Stored with `@AppStorage`, so the raw values must not change.
enum AppSort: String, CaseIterable, Identifiable {
    case nameAscending, nameDescending, newestFirst, oldestFirst, largestFirst, smallestFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .nameAscending: "Name, A to Z"
        case .nameDescending: "Name, Z to A"
        case .newestFirst: "Date Added, Newest First"
        case .oldestFirst: "Date Added, Oldest First"
        case .largestFirst: "Size, Largest First"
        case .smallestFirst: "Size, Smallest First"
        }
    }

    var usesSize: Bool { self == .largestFirst || self == .smallestFirst }
    var usesDate: Bool { self == .newestFirst || self == .oldestFirst }

    /// A total, repeatable order. Equal values go by name, then path. An app with no date or no size yet
    /// goes last in both directions, so unmeasured apps never lead a "Smallest First" list.
    func sorted(_ apps: [InstalledApp], size: (InstalledApp) -> UInt64?) -> [InstalledApp] {
        switch self {
        case .nameAscending: apps.sorted(by: Self.byName)
        case .nameDescending: apps.sorted { Self.byName($1, $0) }
        case .newestFirst: apps.sorted { Self.order($0.dateAdded, $1.dateAdded, descending: true) ?? Self.byName($0, $1) }
        case .oldestFirst: apps.sorted { Self.order($0.dateAdded, $1.dateAdded, descending: false) ?? Self.byName($0, $1) }
        case .largestFirst, .smallestFirst:
            apps.map { ($0, size($0)) }
                .sorted { Self.order($0.1, $1.1, descending: self == .largestFirst) ?? Self.byName($0.0, $1.0) }
                .map(\.0)
        }
    }

    /// Nil when the values tie; a missing value sorts after any present one.
    private static func order<Value: Comparable>(_ a: Value?, _ b: Value?, descending: Bool) -> Bool? {
        switch (a, b) {
        case let (a?, b?): a == b ? nil : (descending ? a > b : a < b)
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }

    private static func byName(_ a: InstalledApp, _ b: InstalledApp) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.url.path < b.url.path
        }
    }
}
