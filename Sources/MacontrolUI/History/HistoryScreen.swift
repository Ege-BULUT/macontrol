import MacontrolCore
import Safety
import SwiftUI

struct HistoryScreen: View {
    let model: HistoryModel

    var body: some View {
        Group {
            if model.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing moved to the Trash yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Everything Macontrol moves to the Trash shows up here, with Undo.")
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
                Image(systemName: batch.canUndo ? "trash.fill" : "arrow.uturn.backward.circle.fill")
                    .font(.title2)
                    .foregroundStyle(batch.canUndo ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
            ForEach(problems, id: \.self) { problem in
                Label("Not put back: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.caution)
            }
        }
        .card()
    }
}

private struct EntryRow: View {
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
            }
            Text(entry.allocated.formattedBytes).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(entry.restored ? .secondary : .primary)
    }
}
