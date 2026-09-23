import SwiftUI
import Uninstaller

/// Placeholder (T-0072) for an app on the sealed system volume. sealed-expert builds DESIGN-debloat section 5.
struct SealedAppPanel: View {
    let app: InstalledApp
    let size: UInt64?

    init(app: InstalledApp, size: UInt64?) {
        self.app = app
        self.size = size
    }

    var body: some View {
        ContentUnavailableView(
            "\(app.name) is locked by macOS",
            systemImage: "lock.fill",
            description: Text("It is part of macOS, on the sealed system volume.")
        )
    }
}
