import Foundation
import MacontrolCore
import Observation
import Safety
import SwiftUI

/// Everything macontrol moved to the Trash, with Undo per batch.
@Observable
public final class HistoryModel {
    public var entries: [JournalEntry]
    private let trash: TrashService?

    public init(trash: TrashService?, entries: [JournalEntry] = []) {
        self.trash = trash
        self.entries = entries
    }

    func reload() async {
        guard let trash else { return }
        entries = await trash.history()
    }

    static func demo() -> HistoryModel {
        let batch = UUID()
        let entry = JournalEntry(
            batch: batch, date: Date(timeIntervalSince1970: 1_790_000_000),
            originalPath: "/Users/demo/Library/Caches/com.example.Editor",
            trashedPath: "/Users/demo/.Trash/com.example.Editor",
            identity: FileIdentity(device: 1, inode: 42), allocated: 1_250_000_000, restored: false
        )
        return HistoryModel(trash: nil, entries: [entry])
    }
}

/// PLACEHOLDER (scaffold): M7 adds Undo per batch and "in Trash, frees X when emptied" (F-0042).
struct HistoryScreen: View {
    let model: HistoryModel

    var body: some View {
        Group {
            if model.entries.isEmpty {
                ContentUnavailableView("Nothing moved to the Trash yet", systemImage: "clock.arrow.circlepath")
            } else {
                List(model.entries, id: \.self) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text((entry.originalPath as NSString).lastPathComponent)
                            Text(entry.originalPath).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.allocated.formattedBytes).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("History")
        .task { await model.reload() }
    }
}
