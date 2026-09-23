import MacontrolCore
import SwiftUI

/// Everything that will move, what that frees, then what actually happened to each item.
struct ReviewSheet: View {
    @Bindable var model: DiskMapModel
    let review: ReviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch review.phase {
            case .confirm, .moving: confirmation
            case .done(let outcomes): results(outcomes)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(review.phase == .moving)
    }

    private var confirmation: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \(DiskMapText.itemCount(review.items.count)) to the Trash?").font(.title2.weight(.semibold))
                Text("Put them back from History until you empty the Trash.")
                    .foregroundStyle(.secondary)
            }
            List(review.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.isFolder ? "folder.fill" : "doc.fill").foregroundStyle(.tint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if item.isInCloud { Label(DiskMapText.inCloud, systemImage: "icloud").font(.caption).foregroundStyle(Theme.cautionText) }
                        if item.isIncomplete { Label(DiskMapText.notFullyScanned, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.cautionText) }
                        if let note = item.note { Text(note).font(.caption).foregroundStyle(Theme.cautionText) }
                    }
                    Spacer()
                    Text(DiskMapText.size(item.bytes, isLowerBound: item.isIncomplete)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .frame(height: min(CGFloat(review.items.count) * 44 + 12, 240))
            estimate
            if review.cloudItemCount > 0 {
                Toggle(isOn: Binding { model.review?.cloudConfirmed ?? false } set: { model.review?.cloudConfirmed = $0 }) {
                    Text("Remove \(DiskMapText.itemCount(review.cloudItemCount)) from iCloud Drive on every device")
                }
                .disabled(review.phase != .confirm)
            }
            HStack {
                Spacer()
                // Closing the sheet mid-move would hide the outcome; the model applies it either way.
                Button("Cancel") { model.review = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(review.phase == .moving)
                Button("Move to Trash") { Task { await model.confirmReview() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!review.canConfirm)
            }
            .controlSize(.large)
        }
    }

    private var estimate: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                switch review.estimate {
                case .measuring:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Measuring what this frees…")
                    }
                    Text("\(DiskMapText.size(review.totalBytes, isLowerBound: review.isIncomplete)) on disk").font(.callout).foregroundStyle(.secondary)
                case .measured(let estimate):
                    Text("Frees \(review.isIncomplete ? "at least" : "about") \(estimate.freesNow.formattedBytes) once you empty the Trash")
                        .font(.headline.monospacedDigit())
                    if estimate.sharedElsewhere > 0 {
                        Text("\(estimate.sharedElsewhere.formattedBytes) stays in use: shared with clones, snapshots or other hard links.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .unavailable:
                    Text("\(DiskMapText.size(review.totalBytes, isLowerBound: review.isIncomplete)) on disk").font(.headline.monospacedDigit())
                    Text("How much of it is shared with clones or hard links could not be measured, so the space freed may be less.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    private func results(_ outcomes: [ReviewOutcome]) -> some View {
        let moved = outcomes.filter { $0.status == .inTrash }
        let movedBytes = moved.reduce(0) { $0 + $1.bytes }
        return Group {
            VStack(alignment: .leading, spacing: 4) {
                Text(moved.isEmpty ? "Nothing was moved" : "Moved \(DiskMapText.itemCount(moved.count)) to the Trash")
                    .font(.title2.weight(.semibold))
                Text(moved.isEmpty
                     ? "The items stay on the map and in the Discard Pile."
                     : "\(movedBytes.formattedBytes) is in the Trash and frees once you empty it. Put them back from History until you empty the Trash.")
                    .foregroundStyle(.secondary)
            }
            List(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                HStack(alignment: .top, spacing: 10) {
                    switch outcome.status {
                    case .inTrash:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notMoved:
                        Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outcome.name).lineLimit(1)
                        switch outcome.status {
                        case .inTrash: Text("In Trash").font(.caption).foregroundStyle(.secondary)
                        case .notMoved(let reason): Text(reason).font(.caption).foregroundStyle(Theme.cautionText)
                        }
                    }
                    Spacer()
                    Text(outcome.bytes.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .frame(height: min(CGFloat(outcomes.count) * 44 + 12, 240))
            HStack {
                Spacer()
                Button("Done") { model.review = nil }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }
}
