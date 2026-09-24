import SwiftUI

/// The hardcore strings, word for word from DESIGN-debloat sections 1.2 and 1.3 (HardcoreTextTests reads them back
/// out of the document).
enum HardcoreText {
    static let label = "Hardcore mode"
    static let helpOff = "Hardcore mode is off. Files macontrol removes go to the Trash, and you can put them back until you "
        + "empty it. Turn it on to delete permanently instead."
    static let helpOn = "Hardcore mode is on. Removals skip the Trash and can't be undone. macontrol still never deletes "
        + "macOS itself, your top-level folders or Photos libraries, locked files, or anything that changed since the scan. "
        + "Files you select inside your folders are deleted for good."
    static let valueOn = "On, deletions are permanent"
    static let valueOff = "Off, deletions go to the Trash"
    static let banner = "Hardcore mode is on: removals are permanent."
    static let turnOff = "Turn Off"
    static let menuTurnOff = "Turn Off Hardcore Mode"

    static let modalTitle = "Turn on hardcore mode?"
    static let modalLead = "macontrol will delete permanently instead of moving to the Trash."
    static let modalBullets = [
        "Nothing goes to the Trash, and History can't put anything back.",
        "It stays on for Clean, Uninstall, Debloat and Disk Map until you turn it off or quit macontrol.",
        "macontrol still never deletes macOS itself, your top-level folders (Documents, Desktop…), Photos libraries, "
            + "locked files, or anything that changed since the scan. Files you select inside your folders are deleted for "
            + "good. Items in iCloud Drive, and your notes, contacts, calendars and Safari data, still go to the Trash.",
    ]
    static let modalBackup = "Back up your Mac with Time Machine first. A mistake here can't be fixed from inside macontrol."
    static let modalConfirm = "Turn On Hardcore Mode"
}

/// The always-visible checkbox, the last trailing toolbar item on every screen (section 1.2). No keyboard shortcut.
struct HardcoreToolbar: ToolbarContent {
    @Bindable var hardcore: HardcoreMode

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $hardcore.checkbox) {
                Label {
                    Text(HardcoreText.label)
                } icon: {
                    Image(systemName: hardcore.isOn ? "flame.fill" : "flame")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(hardcore.isOn ? AnyShapeStyle(Theme.dangerText) : AnyShapeStyle(.secondary))
            }
            .toggleStyle(.checkbox)
            .help(hardcore.isOn ? HardcoreText.helpOn : HardcoreText.helpOff)
            .accessibilityLabel(HardcoreText.label)
            .accessibilityValue(hardcore.isOn ? HardcoreText.valueOn : HardcoreText.valueOff)
        }
    }
}

/// Shows the state even with the toolbar hidden (View > Hide Toolbar).
struct HardcoreBanner: View {
    let hardcore: HardcoreMode

    var body: some View {
        HStack(spacing: 10) {
            Label(HardcoreText.banner, systemImage: "flame.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.dangerText)
            Spacer(minLength: 8)
            Button(HardcoreText.turnOff) { hardcore.isOn = false }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.dangerWash)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The turn-on modal (section 1.3). Return and Esc both cancel; the red button, with no shortcut, is the confirmation.
struct HardcoreModal: View {
    let hardcore: HardcoreMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "flame.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 6) {
                    Text(HardcoreText.modalTitle).font(.title3.weight(.semibold))
                    Text(HardcoreText.modalLead)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(HardcoreText.modalBullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(bullet).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(.secondary)
            Text(HardcoreText.modalBackup)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { hardcore.isAsking = false }
                    .keyboardShortcut(.defaultAction)
                Button(HardcoreText.modalConfirm, role: .destructive) { hardcore.confirmTurnOn() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.danger)
            }
            .controlSize(.large)
            // Esc: a second, invisible cancel, since a button carries one shortcut. `.hidden()` would drop the shortcut.
            .background {
                Button("Cancel") { hardcore.isAsking = false }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
