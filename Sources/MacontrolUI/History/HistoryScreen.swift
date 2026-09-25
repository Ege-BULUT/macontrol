import MacontrolCore
import Safety
import SwiftUI

struct HistoryScreen: View {
    let model: HistoryModel

    var body: some View {
        Group {
            if model.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing removed yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Everything macontrol removes shows up here. Items moved to the Trash can be put back.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        TrashSummary(bytes: model.inTrashBytes)
                        ForEach(model.batches) { batch in
                            BatchCard(
                                batch: batch,
                                isUndoing: model.undoing.contains(batch.id),
                                problems: model.undoProblems[batch.id] ?? []
                            ) {
                                Task { await model.undo(batch.id) }
                            }
                        }
                    }
                    .padding(Theme.pagePadding)
                }
            }
        }
        .navigationTitle("History")
        .task { await model.reload() }
    }
}

private struct TrashSummary: View {
    let bytes: UInt64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(bytes.formattedBytes).font(Theme.figure)
            Text("in the Trash from Macontrol. Space comes back when you empty the Trash in Finder.")
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct BatchCard: View {
    let batch: HistoryBatch
    let isUndoing: Bool
    let problems: [String]
    let undo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                icon
                    .font(.title2)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(batch.date.formatted(date: .abbreviated, time: .shortened)) · \(batch.status)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isUndoing {
                    ProgressView().controlSize(.small)
                } else if batch.canUndo {
                    Button("Undo", action: undo)
                        .accessibilityLabel("Undo: put back \(batch.title)")
                }
            }
            DisclosureGroup("^[\(batch.entries.count) item](inflect: true)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(batch.entries, id: \.self) { entry in
                        EntryRow(entry: entry)
                    }
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.secondary)
            ForEach([batch.ownedBySystemNote, batch.restorePointNote].compactMap { $0 }, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(problems, id: \.self) { problem in
                Label("Not put back: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.cautionText)
            }
        }
        .card()
    }

    /// Red for a permanent batch (a partly deleted item too), the tint while anything can be put back, gray once
    /// everything is back.
    @ViewBuilder
    private var icon: some View {
        if !batch.deleted.isEmpty || !batch.partlyDeleted.isEmpty {
            Image(systemName: "xmark.bin.fill").foregroundStyle(Theme.danger)
        } else if !batch.inTrash.isEmpty {
            Image(systemName: "trash.fill").foregroundStyle(.tint)
        } else {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct EntryRow: View {
    let entry: JournalEntry

    var body: some View {
        HStack {
            Text(entry.originalPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if entry.restored {
                Text("Put back").foregroundStyle(.secondary)
            } else if entry.leftInTrash != nil {
                // Its size is the whole item's: the part in the Trash was not measured (the batch status names it).
                Text("Partly deleted").foregroundStyle(Theme.dangerText)
            } else if entry.isPermanent {
                Text("Deleted permanently").foregroundStyle(Theme.dangerText)
            } else if entry.asAdministrator {
                Text("In the Trash, owned by the system").foregroundStyle(.secondary)
            }
            Text(entry.allocated.formattedBytes).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(entry.restored ? .secondary : .primary)
    }
}
