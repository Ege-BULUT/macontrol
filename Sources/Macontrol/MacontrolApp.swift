import MacontrolUI
import SwiftUI

struct MacontrolApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup("Macontrol") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
