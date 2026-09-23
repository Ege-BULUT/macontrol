import SwiftUI

/// Menu bar commands: ⌘1-⌘6 switch sections, ⌘R rescans, ⌘O scans a chosen folder.
public struct AppCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { model.isChoosingFolder = true }
                .keyboardShortcut("o")
        }
        CommandGroup(before: .sidebar) {
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) { model.selection = item }
                    .keyboardShortcut(item.shortcut)
            }
            Divider()
            Button("Rescan") { model.rescan() }
                .keyboardShortcut("r")
            Divider()
        }
    }
}
