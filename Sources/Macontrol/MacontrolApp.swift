import MacontrolUI
import SwiftUI

struct MacontrolApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        // One window: every screen shares one AppModel, so a second window would mirror the first.
        Window("Macontrol", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(access: model.access)
        }
    }
}
