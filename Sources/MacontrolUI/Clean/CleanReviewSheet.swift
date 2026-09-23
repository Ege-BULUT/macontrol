import MacontrolCore
import SwiftUI

/// The Clean review: every item that will move, what that frees, then per-item outcomes.
struct CleanReviewSheet: View {
    let model: CleanModel
    let review: CleanReview

    var body: some View {
        let current = model.review ?? review
        TrashSheet(
            title: current.items.count == 1 ? "Move 1 item to the Trash?" : "Move \(current.items.count) items to the Trash?",
            message: message,
            warning: warning(current),
            rows: current.items.map { TrashSheetRow(url: $0.url, bytes: $0.measurement.allocated) },
            confirmTitle: "Move to Trash",
            report: current.report,
            notMoved: current.notMoved,
            isWorking: current.isWorking,
            onConfirm: { Task { await model.confirmReview() } },
            onClose: { model.review = nil }
        )
    }

    private var message: String {
        let frees: String = switch model.estimate {
        case .freesNow(let estimate): "Frees about \(estimate.freesNow.formattedBytes) once you empty the Trash."
        case .atMost(let bytes): "Frees at most \(bytes.formattedBytes) once you empty the Trash."
        case .working: "Space is freed once you empty the Trash."
        }
        return "\(frees) You can put everything back from History."
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
