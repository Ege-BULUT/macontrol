import MacontrolCore
import SwiftUI

/// PLACEHOLDER (scaffold): M3 builds the full Full Disk Access flow (poll, drag the app icon, relaunch).
struct OnboardingBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").font(.headline)
                Text("Mail, Safari, the Trash and other protected folders are not scanned until you turn it on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { openURL(FullDiskAccess.settingsURL) }
        }
        .padding(Theme.spacing)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: Theme.cornerRadius))
    }
}
