import AppKit
import SwiftUI

/// Walks the user through granting Full Disk Access, and continues on its own once it is on.
public struct OnboardingSheet: View {
    let access: AccessModel

    public init(access: AccessModel) {
        self.access = access
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppIconView().frame(width: 72, height: 72)
                Text("Allow Full Disk Access").font(.title2.weight(.semibold))
                Text("macOS keeps some folders private until you allow it. Without access, Macontrol cannot size \(access.skippedFolders).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 18) {
                Step(number: 1, text: "Open Full Disk Access in System Settings.") {
                    Button("Open System Settings") { access.openSettings() }
                        .buttonStyle(.borderedProminent)
                }
                Step(number: 2, text: "Turn on Macontrol. Not in the list? Drag this icon into it.") {
                    HStack(spacing: 12) {
                        DraggableAppIcon()
                        Button("Reveal in Finder") { access.revealApp() }
                    }
                }
                Step(number: 3, text: "Come back here. Macontrol continues by itself.") {
                    WaitingStatus(suggestsRelaunch: access.suggestsRelaunch)
                }
            }
            .card()
            .padding(.horizontal, 24)

            HStack {
                Button("Continue Without Access") { access.continueWithout() }
                Spacer()
                if access.suggestsRelaunch {
                    Button("Relaunch Macontrol") { access.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 580)
        .task { await access.watch() }
    }
}

private struct Step<Accessory: View>: View {
    let number: Int
    let text: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                accessory
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number)")
    }
}

private struct WaitingStatus: View {
    let suggestsRelaunch: Bool

    var body: some View {
        if suggestsRelaunch {
            Label("Still off. If you just turned it on, macOS may apply it only after a relaunch.", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.cautionText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for access…").foregroundStyle(.secondary)
            }
        }
    }
}

/// System Settings accepts an app dropped into the Full Disk Access list.
private struct DraggableAppIcon: View {
    var body: some View {
        AppIconView()
            .frame(width: 40, height: 40)
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag into the Full Disk Access list")
            .accessibilityLabel("Macontrol app icon")
            .accessibilityHint("Drag into the Full Disk Access list, or use Reveal in Finder")
    }
}
