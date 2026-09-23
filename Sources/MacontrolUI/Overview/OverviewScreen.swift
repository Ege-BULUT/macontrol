import MacontrolCore
import SwiftUI

/// Disk capacity, the biggest items from the last scan and what is safe to clean, on one page.
struct OverviewScreen: View {
    let model: AppModel

    var body: some View {
        let summary = model.overview
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if model.access.isLimited {
                    LimitedAccessBanner(access: model.access)
                }
                if let capacity = summary.capacity, let volume = model.volume {
                    CapacityCard(name: volume.name, capacity: capacity, readAt: model.volumeReadAt)
                }
                HStack(alignment: .top, spacing: Theme.spacing) {
                    LargestItemsCard(model: model, summary: summary)
                    SafeToCleanCard(model: model, safeToClean: summary.safeToClean)
                        .frame(width: 280)
                }
            }
            .padding(Theme.pagePadding)
        }
        .navigationTitle("Overview")
    }
}

private struct CapacityCard: View {
    let name: String
    let capacity: OverviewSummary.Capacity
    let readAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(name, systemImage: "internaldrive.fill")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(capacity.available.formattedBytes).font(Theme.figure)
                Text("available of \(capacity.total.formattedBytes)")
                    .foregroundStyle(.secondary)
            }
            CapacityBar(fraction: capacity.usedFraction)
                .accessibilityElement()
                .accessibilityLabel("Disk usage")
                .accessibilityValue("\(capacity.usedFraction.formatted(.percent.precision(.fractionLength(0)))) used, \(capacity.available.formattedBytes) available")
            HStack(spacing: 18) {
                LegendDot(color: .accentColor, text: "\(capacity.used.formattedBytes) used")
                LegendDot(color: .secondary.opacity(0.35), text: "\(capacity.available.formattedBytes) available")
            }
            .font(.callout)
            if capacity.purgeable > 0, let readAt {
                Label {
                    Text("macOS said at \(readAt.formatted(date: .abbreviated, time: .shortened)) that it can free about \(capacity.purgeable.formattedBytes) of purgeable space when it needs room. That is not counted as available.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

private struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.75), .accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.height, proxy.size.width * fraction))
            }
        }
        .frame(height: 14)
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).monospacedDigit()
        }
    }
}
