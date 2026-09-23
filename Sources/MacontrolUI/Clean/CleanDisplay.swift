import Cleaner
import Foundation
import SwiftUI

extension CleanupItem {
    /// Can go into a bulk clean. Manual items (backups, archives) and skipped items never do.
    var isCleanable: Bool { rule.safety != .manual && skipReason == nil }

    var name: String { url.lastPathComponent }
}

extension CleanupCategory {
    var title: String {
        switch self {
        case .appCaches: "App caches"
        case .logs: "Logs"
        case .developer: "Developer"
        case .browsers: "Browsers"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .appCaches: "square.stack.3d.up.fill"
        case .logs: "doc.text.fill"
        case .developer: "hammer.fill"
        case .browsers: "globe"
        case .system: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appCaches: .blue
        case .logs: .teal
        case .developer: .indigo
        case .browsers: .orange
        case .system: .pink
        }
    }
}

extension SafetyLevel {
    var title: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .manual: "Manual"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .manual: .secondary
        }
    }

    /// What the level means, under the rule's own note in the badge popover.
    var explanation: String {
        switch self {
        case .safe: "Rebuilt automatically when needed. Selected for you."
        case .review: "Usually fine to remove, but look first. Not selected for you."
        case .manual: "Never part of a bulk clean. Open it in Finder and decide yourself."
        }
    }
}

extension URL {
    /// The path with the home folder shown as `~`.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    /// Shows the item selected in a Finder window. Never opens or runs it.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([self])
    }
}

/// A small coloured square with a symbol, like the category tiles in the sidebar of PureMac-style apps.
struct IconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.28))
    }
}
