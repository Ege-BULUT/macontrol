import SwiftUI

/// Placeholder (T-0072). debloat-catalog builds the screen of DESIGN-debloat section 4.2.
struct DebloatScreen: View {
    let model: DebloatModel

    init(model: DebloatModel) {
        self.model = model
    }

    var body: some View {
        ContentUnavailableView(
            "Debloat is not built yet",
            systemImage: "scissors",
            description: Text("Removes Apple's App Store apps, like GarageBand, iMovie and Xcode, and what they install.")
        )
        .navigationTitle("Debloat")
    }
}
