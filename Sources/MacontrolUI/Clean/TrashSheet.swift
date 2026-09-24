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

/// Lists every item that will move to the Trash, or be deleted in hardcore mode, runs it, then shows each item's
/// outcome. Nothing is truncated or summarised away: the list is the batch (F-0050).
struct TrashSheet: View {
    let title: String
    /// What happens, in the sheet's mode: `PermanentText.message(freesUpTo:)` for a permanent sheet.
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
    /// The mode the confirmation opened with.
    var mode: DeletionMode = .trash
    /// The restore-point box of a permanent sheet; nil hides it.
    var restorePoint: Binding<Bool>? = nil
    /// The rest of the hardcore state: trash-only items, free space, the restore point's progress, the measured result.
    var run = RemovalRun()
    /// The sheet's "Frees up to X", which the measured result is compared with. Nil: the rows' sizes.
    var freesUpTo: UInt64?
    /// "Delete Permanently" after the restore point failed.
    var onGoOnWithoutRestorePoint: () -> Void = {}
    let onConfirm: () -> Void
    let onClose: () -> Void

    private var isPermanent: Bool { mode == .permanent }

    private var outcomes: [URL: TrashOutcome] {
        Dictionary((report?.outcomes ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var total: UInt64 { rows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            if isPermanent && report == nil { PermanentStrip() }
            Divider()
            // Notes scroll with the items: in the fixed header, a long list of them squeezed the items to a sliver.
            List {
                if report == nil && !notes.isEmpty {
                    Section("Also happens") {
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                    }
                }
                if report == nil && (isPermanent || !notes.isEmpty) {
                    let deleted = rows.filter { !isTrashOnly($0) }
                    let trashed = rows.filter(isTrashOnly)
                    if !deleted.isEmpty || trashed.isEmpty {
                        Section(isPermanent ? PermanentText.listHeader : "Moves to the Trash") { rowViews(deleted) }
                    }
                    if !trashed.isEmpty {
                        Section(PermanentText.trashOnlyHeader) { rowViews(trashed) }
                    }
                } else {
                    rowViews(rows)
                }
            }
            .listStyle(.inset)
            if isPermanent, let restorePoint, report == nil {
                RestorePointBox(isOn: restorePoint, run: run, isWorking: isWorking)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 540)
    }

    private func isTrashOnly(_ row: TrashSheetRow) -> Bool { isPermanent && run.trashOnly[row.url] != nil }

    private func rowViews(_ rows: [TrashSheetRow]) -> some View {
        ForEach(rows) { row in
            TrashSheetRowView(
                row: row, outcome: outcomes[row.url], notMoved: notMoved[row.url], isDone: report != nil, mode: mode,
                trashOnly: isPermanent ? run.trashOnly[row.url] : nil
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            headerIcon.font(.system(size: 36))
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                Text(explanation)
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

    private var heading: String {
        guard let report else { return title }
        return isPermanent ? PermanentText.summary(deleted: report.deletedURLs.count, of: rows.count) : report.summary(of: rows.count)
    }

    private var explanation: String {
        guard let report else {
            let ticked = isPermanent && restorePoint?.wrappedValue == true
            return ticked ? message + " " + PermanentText.restorePointSpace : message
        }
        guard isPermanent else {
            return "Items stay in the Trash and still use their space. Put them back from History until you empty the Trash."
        }
        // Compared with what the deleted rows could free, not the whole sheet: refused items free nothing.
        let deletedBytes = rows.filter { report.deletedURLs.contains($0.url) }.reduce(0) { $0 + $1.bytes }
        return PermanentText.result(deletedAny: !report.deletedURLs.isEmpty, freed: run.freed, estimate: min(freesUpTo ?? deletedBytes, deletedBytes))
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let report {
            // Done means every row went where the sheet said: deleted, or to the Trash for trash-only rows.
            let done = rows.allSatisfy { row in
                isPermanent && !isTrashOnly(row) ? report.deletedURLs.contains(row.url) : report.removedURLs.contains(row.url)
            }
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(done ? .green : .orange)
        } else if isPermanent {
            Image(systemName: "flame.circle.fill").foregroundStyle(Theme.danger)
        } else {
            Image(systemName: "trash.circle.fill").foregroundStyle(Color.accentColor)
        }
    }

    private var footer: some View {
        HStack {
            if let problem = run.restorePointProblem, report == nil {
                RestorePointProblem(problem: problem, onCancel: onClose, onDelete: onGoOnWithoutRestorePoint)
            } else {
                Text("\(rows.count == 1 ? "1 item" : "\(rows.count) items") · \(total.formattedBytes) on disk")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if report == nil && errorMessage == nil {
                    if run.isCreatingRestorePoint {
                        Text(PermanentText.creatingRestorePoint).foregroundStyle(.secondary)
                    }
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
        }
        .controlSize(.large)
    }
}

/// The red strip inside every permanent sheet: the window's banner sits under the sheet (DESIGN-debloat section 1.4).
struct PermanentStrip: View {
    var body: some View {
        Label(PermanentText.strip, systemImage: "flame.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.dangerText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Theme.dangerWash)
    }
}

/// The unchecked restore-point box of a permanent confirmation (DESIGN-debloat section 2.6).
struct RestorePointBox: View {
    @Binding var isOn: Bool
    let run: RemovalRun
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(PermanentText.restorePointLabel, isOn: $isOn)
                .toggleStyle(.checkbox)
                .disabled(!run.canMakeRestorePoint || isWorking)
            Text(run.canMakeRestorePoint ? PermanentText.restorePointNote : PermanentText.restorePointTooFull)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

/// "Couldn't create a restore point: <reason>. Delete anyway?" with Cancel as the default (DESIGN-debloat section 2.6).
struct RestorePointProblem: View {
    let problem: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Label(PermanentText.restorePointFailed(problem), systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.cautionText)
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
        // Cancel is the default here: Return must never be the one that deletes (section 1.6).
        Button("Cancel", role: .cancel, action: onCancel)
            .keyboardShortcut(.defaultAction)
        Button("Delete Permanently", role: .destructive, action: onDelete)
            .buttonStyle(.borderedProminent)
            .tint(.red)
    }
}

/// Permanent-mode copy shared by every confirmation sheet, word for word from DESIGN-debloat sections 1.4 and 2.6.
enum PermanentText {
    static let strip = "Permanent: skips the Trash"
    static let listHeader = "Deletes permanently"
    static let trashOnlyHeader = "Moved to the Trash"
    static let confirm = "Delete Permanently"
    static let restorePointLabel = "Create a restore point first (Time Machine local snapshot, about a minute)"
    static let restorePointNote = "Rolling back returns every file on this Mac to this moment; anything newer is lost. While it "
        + "exists, the deleted items still use their space. macOS may remove it on its own. It is not a backup."
    static let restorePointTooFull = "Not enough free space for a restore point."
    static let restorePointSpace = "Space comes back when the restore point is removed."
    static let creatingRestorePoint = "Creating a restore point…"
    static let snapshotNote = "The rest is held by local snapshots or shared with other files, and comes back when macOS "
        + "removes those snapshots."

    static func restorePointFailed(_ reason: String) -> String {
        "Couldn't create a restore point: \(reason). Delete anyway?"
    }

    /// The sheet message: "They skip the Trash and can't be put back. Frees up to X."
    static func message(freesUpTo bytes: UInt64) -> String {
        "They skip the Trash and can't be put back. Frees up to \(bytes.formattedBytes)."
    }

    /// "Delete N items permanently?"
    static func title(count: Int) -> String {
        count == 1 ? "Delete 1 item permanently?" : "Delete \(count) items permanently?"
    }

    /// A partly deleted item: the rest is in the Trash under its own name (DESIGN-debloat sections 1.4 and 2.4).
    static func partlyDeleted(_ name: String) -> String {
        "Partly deleted. The rest is in the Trash as \"\(name)\"; empty the Trash to finish."
    }

    /// "Deleted N items permanently" / "Deleted M of N items" (DESIGN-debloat section 1.4). Items that went to the
    /// Trash on purpose (D4) are not counted as deleted; their rows say where they went.
    static func summary(deleted: Int, of count: Int) -> String {
        if deleted == count { return count == 1 ? "Deleted permanently" : "Deleted \(count) items permanently" }
        if deleted == 0 { return count == 1 ? "Nothing was deleted" : "None of the \(count) items were deleted" }
        return "Deleted \(deleted) of \(count) items"
    }

    /// "Freed X. These can't be put back.", X measured from `VolumeSummary.available` before and after the batch, and
    /// the snapshot line when X is below half of `estimate`, what the deleted items were expected to free.
    static func result(deletedAny: Bool, freed: UInt64?, estimate: UInt64) -> String {
        guard deletedAny else { return "Nothing was deleted." }
        guard let freed else { return "These can't be put back." }
        let line = "Freed \(freed.formattedBytes). These can't be put back."
        return freed < estimate / 2 ? line + " " + snapshotNote : line
    }
}

private struct TrashSheetRowView: View {
    let row: TrashSheetRow
    let outcome: TrashOutcome?
    let notMoved: String?
    let isDone: Bool
    let mode: DeletionMode
    /// Why this row goes to the Trash in a permanent batch (D4).
    let trashOnly: String?

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
                    Label(outcome.words(in: mode), systemImage: outcome.isRemoved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(outcome.isRemoved ? Theme.successText : Theme.cautionText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isDone {
                    Label("No result was reported for this item", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let trashOnly {
                    Label(trashOnly.prefix(1).uppercased() + trashOnly.dropFirst(), systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            // What stayed behind is reachable from here even after its app or row is gone.
            if isDone && outcome?.isRemoved != true {
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
