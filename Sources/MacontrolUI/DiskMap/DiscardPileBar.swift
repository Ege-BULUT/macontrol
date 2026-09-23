import MacontrolCore
import SwiftUI

/// The staging tray floating over the map: what is waiting to be reviewed, and what already went to the Trash.
struct DiscardPileBar: View {
    @Bindable var model: DiskMapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pile.items.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "trash.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Discard Pile").font(.headline)
                        Text("\(DiskMapText.itemCount(model.pile.items.count)) · \(DiskMapText.size(model.pile.totalBytes, isLowerBound: model.pile.isIncomplete)) on disk")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.pile.items) { item in
                                chip(item)
                            }
                        }
                    }
                    Button("Review…") { model.beginReview() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            if !model.trashed.isEmpty {
                Label(
                    "In Trash: \(DiskMapText.itemCount(model.trashed.count)), \(model.inTrashBytes.formattedBytes). Space returns when the Trash is emptied.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620, alignment: .leading)
        .floatingSurface()
    }

    private func chipHelp(_ item: StagedItem) -> String {
        var lines = [item.url.path]
        if item.isIncomplete { lines.append("\(DiskMapText.size(item.bytes, isLowerBound: true)). \(DiskMapText.notFullyScanned)") }
        if item.isInCloud { lines.append(DiskMapText.inCloud) }
        if let note = item.note { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    private func chip(_ item: StagedItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: item.isFolder ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
            Text(item.name).lineLimit(1)
            if item.isIncomplete { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if item.isInCloud { Image(systemName: "icloud").foregroundStyle(.orange) }
            Button("Remove \(item.name)", systemImage: "xmark.circle.fill") { model.unstage(item.node) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
        .help(chipHelp(item))
    }
}
