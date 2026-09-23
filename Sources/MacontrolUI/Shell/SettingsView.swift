import SwiftUI

/// The Settings window. v1 has one real setting to show: the permission state.
public struct SettingsView: View {
    let access: AccessModel

    public init(access: AccessModel) {
        self.access = access
    }

    public var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(access.isLimited ? "Off" : "On")
                            .foregroundStyle(access.isLimited ? Theme.caution : .secondary)
                        Button("Open System Settings") { access.openSettings() }
                    }
                }
                if access.isLimited {
                    Text("Not scanned without it: \(access.skippedFolders).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.appDidBecomeActive()
        }
    }
}
