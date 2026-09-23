import MacontrolCore
import ScanEngine
import SwiftUI

struct LargestItemsCard: View {
    let model: AppModel
    let summary: OverviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(summary.scannedRoot.map { "Largest in \($0)" } ?? "Largest items").font(Theme.cardTitle)
                Spacer()
                if !summary.largest.isEmpty {
                    Button("Open Disk Map") { model.selection = .diskMap }
                        .buttonStyle(.link)
                }
            }
            if model.isScanning {
                ScanningRow(progress: model.diskMap.progress)
            } else if summary.largest.isEmpty {
                NotScannedYet(model: model)
            } else {
                ForEach(summary.largest) { item in
                    Button { model.openInDiskMap(item) } label: { ItemRow(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name), \(item.bytes.formattedBytes)")
                        .accessibilityHint("Opens in Disk Map")
                }
            }
        }
        .card()
    }
}

private struct ItemRow: View {
    let item: OverviewSummary.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.bytes.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule().fill(.tint.opacity(0.55))
                    .frame(width: max(4, proxy.size.width * item.share))
            }
            .frame(height: 4)
            .padding(.leading, 26)
        }
        .contentShape(.rect)
    }
}

private struct ScanningRow: View {
    let progress: ScanProgress?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            if let progress {
                Text("\(progress.filesVisited.formatted()) items, \(progress.bytesVisited.formattedBytes)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Scanning…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct NotScannedYet: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Text("Scan to see what takes up space.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Scan Home") { model.scan(.home) }
                    .buttonStyle(.borderedProminent)
                Button("Scan \(ScanScope.startupDisk.title)") { model.scan(.startupDisk) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

struct SafeToCleanCard: View {
    let model: AppModel
    let safeToClean: (bytes: UInt64, count: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clean", systemImage: "sparkles").font(Theme.cardTitle)
            if model.clean.isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for junk…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else if let safeToClean {
                VStack(alignment: .leading, spacing: 2) {
                    Text(safeToClean.bytes.formattedBytes).font(Theme.figure)
                    Text("safe to clean in ^[\(safeToClean.count) item](inflect: true)")
                        .foregroundStyle(.secondary)
                }
                Button("Review in Clean") { model.selection = .clean }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Caches, logs and build files that apps recreate on their own.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Find Junk") { model.findJunk() }
            }
        }
        .card()
    }
}
