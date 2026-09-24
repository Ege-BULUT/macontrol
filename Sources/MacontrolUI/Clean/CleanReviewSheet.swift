import MacontrolCore
import SwiftUI

/// The Clean review: every item that will move, what that frees, then per-item outcomes.
struct CleanReviewSheet: View {
    let model: CleanModel
    let review: CleanReview

    var body: some View {
        let current = model.review ?? review
        let count = current.items.count
        let permanent = current.run.isPermanent
        let rows = current.items.map { TrashSheetRow(url: $0.url, bytes: $0.measurement.allocated) }
        TrashSheet(
            title: permanent
                ? PermanentText.title(count: count)
                : (count == 1 ? "Move 1 item to the Trash?" : "Move \(count) items to the Trash?"),
            message: permanent ? PermanentText.message(freesUpTo: freesUpTo ?? current.run.bytes(of: rows)) : message,
            warning: warning(current),
            notes: AdminText.notes(count: current.adminCount, mode: current.run.mode),
            rows: rows,
            confirmTitle: permanent ? PermanentText.confirm : "Move to Trash",
            report: current.report,
            notMoved: current.notMoved,
            isWorking: current.isWorking,
            mode: current.run.mode,
            restorePoint: permanent ? Binding { model.review?.run.wantsRestorePoint ?? false } set: { model.review?.run.wantsRestorePoint = $0 } : nil,
            run: current.run,
            freesUpTo: freesUpTo,
            onGoOnWithoutRestorePoint: { Task { await model.confirmWithoutRestorePoint() } },
            onConfirm: { Task { await model.confirmReview() } },
            onClose: { model.review = nil }
        )
    }

    /// The engine's clone-aware figure; in hardcore mode the estimate already leaves out what still goes to the Trash.
    private var freesUpTo: UInt64? {
        switch model.estimate {
        case .freesNow(let estimate): estimate.freesNow
        case .atMost(let bytes): bytes
        case .working: nil
        }
    }

    private var message: String {
        let frees: String = switch model.estimate {
        case .freesNow(let estimate): "Frees about \(estimate.freesNow.formattedBytes) once you empty the Trash."
        case .atMost(let bytes): "Frees at most \(bytes.formattedBytes) once you empty the Trash."
        case .working: "Space is freed once you empty the Trash."
        }
        return "\(frees) Put them back from History until you empty the Trash."
    }

    private func warning(_ review: CleanReview) -> String? {
        var parts: [String] = []
        if review.hiddenBySearch > 0 {
            parts.append("\(review.hiddenBySearch) of these \(review.hiddenBySearch == 1 ? "is" : "are") hidden by your search.")
        }
        if review.nestedCount > 0 {
            parts.append("\(review.nestedCount) selected \(review.nestedCount == 1 ? "item is" : "items are") inside a folder listed here and move with it.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
