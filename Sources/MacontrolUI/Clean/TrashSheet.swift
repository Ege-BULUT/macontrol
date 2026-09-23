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
    /// Steps and facts besides the moves (a background item stopped, a receipt left in place), listed verbatim.
    var notes: [String] = []
    let rows: [TrashSheetRow]
    let confirmTitle: String
    let report: TrashReport?
    /// Rows held back when the move ran, with the reason; they were never sent to the Trash.
    var notMoved: [URL: String] = [:]
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
            // Notes scroll with the items: in the fixed header, a long list of them squeezed the items to a sliver.
            List {
                if report == nil && !notes.isEmpty {
                    Section("Also happens") {
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                    }
                    Section("Moves to the Trash") { rowViews }
                } else {
                    rowViews
                }
            }
            .listStyle(.inset)
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 540)
    }

    private var rowViews: some View {
        ForEach(rows) { row in
            TrashSheetRowView(row: row, outcome: outcomes[row.url], notMoved: notMoved[row.url], isDone: report != nil)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            headerIcon.font(.system(size: 36))
            VStack(alignment: .leading, spacing: 6) {
                Text(report?.summary(of: rows.count) ?? title)
                    .font(.title3.weight(.semibold))
                Text(report == nil ? message : "Items stay in the Trash and still use their space. Put them back from History until you empty the Trash.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning, report == nil {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.cautionText)
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
    let notMoved: String?
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
                if let notMoved {
                    Label("Not moved: \(notMoved)", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.cautionText)
                } else if let outcome {
                    Label(outcome.words, systemImage: outcome.isTrashed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(outcome.isTrashed ? Theme.successText : Theme.cautionText)
                } else if isDone {
                    Label("No result was reported for this item", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            // What stayed behind is reachable from here even after its app or row is gone.
            if isDone && outcome?.isTrashed != true {
                Button("Reveal in Finder") { row.url.revealInFinder() }
                    .controlSize(.small)
            }
            Text(row.bytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(row.url.path)
    }
}

/// The item's Finder icon; a generic icon for its type when it is not on this Mac (demo data).
struct FileIcon: View {
    let url: URL
    let size: CGFloat

    /// Read once per path: `icon(forFile:)` touches the disk, and list rows redraw often.
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    private static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.icon(forFile: url.path)
        } else {
            NSWorkspace.shared.icon(for: placeholderType(of: url))
        }
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }

    /// A declared extension (`.plist`) is a file; anything else (`com.example.Editor`) is taken as a folder.
    private static func placeholderType(of url: URL) -> UTType {
        if url.pathExtension == "app" { return .applicationBundle }
        guard let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic else { return .folder }
        return type
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
