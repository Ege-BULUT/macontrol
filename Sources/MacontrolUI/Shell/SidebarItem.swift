import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case overview
    case diskMap
    case clean
    case uninstall
    case history

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .diskMap: "Disk Map"
        case .clean: "Clean"
        case .uninstall: "Uninstall"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "internaldrive"
        case .diskMap: "chart.pie"
        case .clean: "sparkles"
        case .uninstall: "trash.square"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// ⌘1-⌘5, in sidebar order.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1)))
    }
}
