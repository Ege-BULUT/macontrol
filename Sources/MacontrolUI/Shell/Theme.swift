import AppKit
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

    /// The one warning hue: limited mode, things that could not be done. For icons and fills; text takes `cautionText`.
    static let caution = Color.orange

    /// Status text. System green and orange measure 2.2:1 on white, so light mode takes darker shades that
    /// reach 4.5:1 (WCAG AA) down to a #E5E5E5 background; dark mode keeps the system hues (T-0060).
    static let successText = statusText(light: 0x1A7431, dark: .systemGreen)
    static let cautionText = statusText(light: 0xA04500, dark: .systemOrange)

    private static func statusText(light: UInt32, dark: NSColor) -> Color {
        let shade = NSColor(
            srgbRed: CGFloat(light >> 16 & 0xFF) / 255, green: CGFloat(light >> 8 & 0xFF) / 255, blue: CGFloat(light & 0xFF) / 255, alpha: 1
        )
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : shade })
    }
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
