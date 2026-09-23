import MacontrolCore
import ScanEngine
import SwiftUI

/// PLACEHOLDER (scaffold): volume numbers and entry points. M3 builds the real overview.
struct OverviewScreen: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if model.fullDiskAccess != .granted {
                    OnboardingBanner()
                }
                if let volume = model.volume {
                    VolumeCard(volume: volume)
                }
            }
            .padding(Theme.spacing * 1.5)
        }
        .navigationTitle("Overview")
    }
}

private struct VolumeCard: View {
    let volume: VolumeSummary

    private var used: UInt64 { volume.capacity - min(volume.available, volume.capacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(volume.name).font(.title2.weight(.semibold))
            ProgressView(value: Double(used), total: Double(max(volume.capacity, 1)))
            HStack {
                Text("\(used.formattedBytes) used")
                Spacer()
                Text("\(volume.available.formattedBytes) available")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if volume.purgeable > 0 {
                Text("macOS can free about \(volume.purgeable.formattedBytes) more on demand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.spacing)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.cornerRadius))
    }
}
