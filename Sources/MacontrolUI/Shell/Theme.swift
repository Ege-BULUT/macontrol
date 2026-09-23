import SwiftUI

/// Shared look for every screen. Standard controls get Liquid Glass from the macOS 26 SDK on their
/// own; only floating custom surfaces opt in explicitly, with a material fallback on 14-15.
enum Theme {
    static let spacing: CGFloat = 16
    static let compactSpacing: CGFloat = 8
    static let pagePadding: CGFloat = 28
    static let cornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 18

    /// Headline numbers. Monospaced digits keep figures from jittering while a scan updates them.
    static let figure = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    /// Card titles.
    static let cardTitle = Font.headline

    /// The one warning hue: limited mode, things that could not be done.
    static let caution = Color.orange
}

extension View {
    /// A floating panel surface: Liquid Glass on macOS 26, regular material before.
    @ViewBuilder
    func floatingSurface() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: Theme.cornerRadius))
        }
    }

    /// A content card on the page background: Overview tiles, History batches.
    func card() -> some View {
        padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(.separator.opacity(0.5)))
    }
}
