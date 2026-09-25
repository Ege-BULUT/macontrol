import AppKit
import MacontrolCore
import SwiftUI
import Uninstaller

/// The expert guide (DESIGN-debloat section 5.3): the risks, an acknowledgement box, and only then the commands with
/// Copy buttons and the way back. macontrol runs none of them; the sheet has no button that acts on the Mac.
struct SealedGuideSheet: View {
    let apps: [InstalledApp]
    let integrity: SystemIntegrity
    let guide: SealedGuide
    @State private var acknowledged: Bool
    @Environment(\.dismiss) private var dismiss

    init(apps: [InstalledApp], integrity: SystemIntegrity, home: URL, acknowledged: Bool = false) {
        self.apps = apps
        self.integrity = integrity
        guide = SealedGuide(apps: apps.map(\.url), integrity: integrity, home: home)
        _acknowledged = State(initialValue: acknowledged)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if integrity.allowsSealedRemoval {
                            Callout(text: "\(SealedGuide.protectionsOff) \(SealedGuide.waitsForVerification)", systemImage: "info.circle.fill", tint: .blue)
                        }
                        risks
                        Toggle(SealedGuide.acknowledgement, isOn: $acknowledged)
                            .toggleStyle(.checkbox)
                            .font(.headline)
                        if acknowledged {
                            steps
                        } else {
                            Text("The steps appear once you tick the box.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Ticking the box brings the steps up, which start below the risks.
                .onChange(of: acknowledged) { _, ticked in
                    if ticked { withAnimation { scroller.scrollTo(Self.stepsAnchor, anchor: .top) } }
                }
            }
            Divider()
            HStack {
                Text("macontrol runs none of these commands.").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 640, maxWidth: .infinity, minHeight: 540, idealHeight: 540, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text("Strongly not recommended")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.dangerText)
                Text("Removing \(ListFormatter.localizedString(byJoining: apps.map(\.name))) from macOS yourself, in Terminal.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var risks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before you start").font(.headline)
            ForEach(SealedGuide.risks, id: \.self) { risk in
                Label {
                    Text(LocalizedStringKey(risk)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                }
            }
        }
    }

    private static let stepsAnchor = "steps"

    @ViewBuilder
    private var steps: some View {
        ForEach(guide.skipped, id: \.name) { app in
            Callout(text: "\(app.name): \(app.reason)", systemImage: "minus.circle.fill", tint: .secondary)
        }
        if let unavailable = guide.unavailable {
            Callout(text: unavailable, systemImage: "xmark.octagon.fill", tint: .orange)
        }
        if !guide.steps.isEmpty {
            Text("Steps").font(.title3.weight(.semibold)).id(Self.stepsAnchor)
            ForEach(Array(guide.steps.enumerated()), id: \.element.id) { index, step in
                StepView(number: index + 1, step: step)
            }
        }
        if !guide.undo.isEmpty {
            Text("To undo").font(.title3.weight(.semibold))
        }
        ForEach(Array(guide.undo.enumerated()), id: \.element.id) { index, step in
            StepView(number: index + 1, step: step)
        }
    }
}

private struct StepView: View {
    let number: Int
    let step: SealedGuide.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number). \(step.title)").font(.headline)
                Text(step.verified ? "Verified" : "Unverified")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(step.verified ? Theme.successText : Theme.cautionText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.separator))
                    .help(step.verified
                        ? "Checked on a Mac with macOS 26.6."
                        : "Not tested by macontrol yet. It follows Apple's documentation and others' reports.")
            }
            if let detail = step.detail {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(step.commands, id: \.self) { CommandRow(command: $0) }
        }
    }
}

private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .controlSize(.small)
            .help("Copy this command")
            .accessibilityLabel("Copy \(command)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

private struct Callout: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}
