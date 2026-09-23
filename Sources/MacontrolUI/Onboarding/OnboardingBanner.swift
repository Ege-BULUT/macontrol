import SwiftUI

/// Limited mode: names what the scans skip, so smaller totals are never a silent surprise.
struct LimitedAccessBanner: View {
    let access: AccessModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.title2)
                .foregroundStyle(Theme.caution)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Limited mode: Full Disk Access is off").font(.headline)
                Text("Not scanned: \(access.skippedFolders). Sizes there are missing, not zero.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn On…") { access.showOnboarding() }
        }
        .padding(Theme.spacing)
        .background(Theme.caution.opacity(0.1), in: .rect(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.caution.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }
}
