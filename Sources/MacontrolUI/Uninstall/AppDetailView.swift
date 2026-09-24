import MacontrolCore
import SwiftUI
import Uninstaller

/// The selected app: header, notices, leftovers grouped by evidence, and the Uninstall button.
struct AppDetailView: View {
    @Bindable var model: UninstallModel
    /// Highlighted leftover rows; Space turns highlight into choice.
    @State private var highlighted: Set<URL> = []

    var body: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                header(app)
                notices(app)
                Divider()
                content(app)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom) {
                if model.canUninstall, let plan = model.plan { footer(plan) }
            }
        } else {
            ContentUnavailableView(
                "Select an app",
                systemImage: "app.dashed",
                description: Text("See its size and everything it left behind before you remove it.")
            )
        }
    }

    private func header(_ app: InstalledApp) -> some View {
        HStack(spacing: 16) {
            FileIcon(url: app.url, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title2.weight(.semibold))
                Text([app.version.map { "Version \($0)" }, app.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.sizes[app.url]?.formattedBytes ?? "–")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("app size").font(.caption).foregroundStyle(.secondary)
            }
            if app.kind != .builtIn {
                Button { Task { await model.rescan() } } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Look for \(app.name) and what it left behind again")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func notices(_ app: InstalledApp) -> some View {
        // The uninstaller also blocks apps that are not built in (a root-owned bundle, macontrol itself).
        let blocker = model.plan?.app.id == app.id ? model.plan?.blocker : nil
        let fallback = app.kind == .builtIn ? "Part of macOS. It lives on the sealed system volume and can't be removed." : nil
        VStack(alignment: .leading, spacing: 8) {
            if let text = blocker ?? fallback {
                // A root-owned bundle (most App Store apps) is removed in Finder; built-in apps not at all.
                Notice(text: text, systemImage: "lock.fill", tint: .secondary, reveal: app.kind == .builtIn ? nil : app.url)
            }
            if app.kind == .appleAppStore && blocker == nil {
                Notice(text: "Made by Apple. You can remove it and download it again for free from the App Store.",
                       systemImage: "apple.logo", tint: .blue)
            }
            ForEach(model.plan?.app.id == app.id ? model.plan?.notes ?? [] : [], id: \.self) { note in
                Notice(text: note, systemImage: "info.circle.fill", tint: .secondary)
            }
            if app.kind != .builtIn && model.isRunning(app) {
                Notice(text: "\(app.name) is open. Uninstalling asks it to quit first, so save your work.",
                       systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func content(_ app: InstalledApp) -> some View {
        if app.kind == .builtIn {
            ContentUnavailableView(
                "Nothing to remove",
                systemImage: "lock.shield",
                description: Text("macOS keeps its own apps on a protected volume. You can hide \(app.name) from the Dock instead.")
            )
        } else if let plan = model.plan, plan.app.id == app.id {
            leftovers(plan)
        } else if let error = model.planError {
            ContentUnavailableView {
                Label("Couldn't look for leftovers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Scan Again") { Task { await model.rescan() } }
            }
        } else {
            ProgressView("Looking for what \(app.name) left behind…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func leftovers(_ plan: UninstallPlan) -> some View {
        List(selection: $highlighted) {
            if plan.leftovers.isEmpty {
                Label("No leftovers found. Only the app itself will move.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(LeftoverEvidence.sections(of: plan.leftovers), id: \.self) { evidence in
                let members = plan.leftovers.filter { $0.evidence == evidence }
                Section {
                    ForEach(members) { leftover in
                        LeftoverRow(leftover: leftover, canChoose: model.canUninstall, usesAdministrator: model.canUseAdministrator, isChosen: Binding(
                            get: { model.isChosen(leftover) },
                            set: { model.setChosen($0, leftover) }
                        ))
                    }
                } header: {
                    EvidenceHeader(evidence: evidence, members: members)
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            model.toggle(highlighted)
            return .handled
        }
    }

    private func footer(_ plan: UninstallPlan) -> some View {
        let chosen = model.chosenLeftovers
        let total = chosen.reduce(plan.appMeasurement.allocated) { $0 + $1.measurement.allocated }
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chosen.isEmpty ? "\(plan.app.name) only" : "\(plan.app.name) and \(chosen.count == 1 ? "1 item" : "\(chosen.count) items")")
                    .font(.headline)
                Text("\(total.formattedBytes) on disk, \(model.hardcore.isOn ? "deleted permanently" : "moved to the Trash")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Uninstall…") { model.beginUninstall() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct Notice: View {
    let text: String
    let systemImage: String
    let tint: Color
    var reveal: URL?

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
            if let reveal {
                Button("Reveal in Finder") { reveal.revealInFinder() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

private struct EvidenceHeader: View {
    let evidence: LeftoverEvidence
    let members: [Leftover]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: evidence.systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(evidence.title).font(.headline).foregroundStyle(.primary)
                Text(evidence.explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(members.reduce(0) { $0 + $1.measurement.allocated }.formattedBytes)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 6)
    }
}

private struct LeftoverRow: View {
    let leftover: Leftover
    /// False for an app that can't be uninstalled: nothing would act on the checkbox.
    let canChoose: Bool
    /// The administrator helper is there: a root-owned leftover gets a checkbox and the "Admin" badge (DESIGN-debloat
    /// section 1.4). Without it, v1: a lock, "Needs admin" and Reveal in Finder.
    let usesAdministrator: Bool
    @Binding var isChosen: Bool

    private var isLocked: Bool { leftover.needsAdministrator && !usesAdministrator }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isLocked {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                } else {
                    Toggle("Remove \(leftover.url.lastPathComponent)", isOn: $isChosen)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!canChoose)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(leftover.url.lastPathComponent).lineLimit(1)
                Text(leftover.url.deletingLastPathComponent().displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = leftover.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.cautionText)
                }
            }
            Spacer(minLength: 12)
            if leftover.needsAdministrator && usesAdministrator {
                AdminBadge()
            } else if isLocked {
                Text("Needs admin")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .help("Owned by the system. macontrol can't remove it yet; reveal it in Finder to remove it yourself.")
                Button("Reveal in Finder") { leftover.url.revealInFinder() }
                    .controlSize(.small)
            }
            Text(leftover.measurement.allocated.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(isChosen ? .primary : .secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") { leftover.url.revealInFinder() }
        }
    }
}
