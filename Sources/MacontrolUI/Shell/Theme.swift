import SwiftUI

/// Shared look. Standard controls get Liquid Glass from the macOS 26 SDK on their own;
/// only floating custom surfaces opt in explicitly, with a material fallback on 14-15.
enum Theme {
    static let spacing: CGFloat = 16
    static let cornerRadius: CGFloat = 12
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
}
