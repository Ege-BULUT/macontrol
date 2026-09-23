import AppKit
import MacontrolCore
import Safety
import SwiftUI
import UniformTypeIdentifiers

/// One item a confirmation sheet will move, exactly as it is sent to `TrashService`.
struct TrashSheetRow: Identifiable, Hashable {
    let url: URL
    let bytes: UInt64
    var id: URL { url }
}

/// Lists every item that will move to the Trash, runs the move, then shows each item's outcome.
/// Nothing is truncated or summarised away: the list is the batch (F-0050).
struct TrashSheet: View {
    let title: String
    let message: String
    var warning: String?
    let rows: [TrashSheetRow]
    let confirmTitle: String
    let report: TrashReport?
    let isWorking: Bool
    var errorMessage: String?
    let onConfirm: () -> Void
    let onClose: () -> Void

    private var outcomes: [URL: TrashOutcome] {
        Dictionary((report?.outcomes ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var total: UInt64 { rows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            List(rows) { row in
                TrashSheetRowView(row: row, outcome: outcomes[row.url], isDone: report != nil)
            }
            .listStyle(.inset)
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 540)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            headerIcon.font(.system(size: 36))
            VStack(alignment: .leading, spacing: 6) {
                Text(report?.summary(of: rows.count) ?? title)
                    .font(.title3.weight(.semibold))
                Text(report == nil ? message : "Items stay in the Trash, still using their space, until you empty it. You can put them back from History.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning, report == nil {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let report {
            let allMoved = report.trashedURLs.count == rows.count
            Image(systemName: allMoved ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(allMoved ? .green : .orange)
        } else {
            Image(systemName: "trash.circle.fill").foregroundStyle(Color.accentColor)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(rows.count == 1 ? "1 item" : "\(rows.count) items") · \(total.formattedBytes) on disk")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            if report == nil && errorMessage == nil {
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isWorking || rows.isEmpty)
            } else {
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

private struct TrashSheetRowView: View {
    let row: TrashSheetRow
    let outcome: TrashOutcome?
    let isDone: Bool

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(url: row.url, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent).lineLimit(1)
                Text(row.url.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let outcome {
                    Label(outcome.words, systemImage: outcome.isTrashed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(outcome.isTrashed ? .green : .orange)
                } else if isDone {
                    Label("No result was reported for this item", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(row.bytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(row.url.path)
    }
}

/// The item's Finder icon; a generic app or folder icon when it is not on this Mac (demo data).
struct FileIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        let icon = if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.icon(forFile: url.path)
        } else {
            NSWorkspace.shared.icon(for: url.pathExtension == "app" ? .applicationBundle : .folder)
        }
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Array where Element == URL {
    /// Drops every URL that lies inside another URL of the array: moving the folder moves them too,
    /// and a confirmation must name what is really removed (F-0050).
    func removingNested() -> [URL] {
        let paths = Set(map { $0.standardizedFileURL.path })
        return filter { url in
            var parent = url.standardizedFileURL.deletingLastPathComponent()
            while parent.path != "/" {
                if paths.contains(parent.path) { return false }
                parent = parent.deletingLastPathComponent()
            }
            return true
        }
    }
}
