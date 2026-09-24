import AppKit
import MacontrolCore
import Safety
import SwiftUI
import Uninstaller

/// Apple's removable apps as a checklist with what each installed, then one Remove for all (DESIGN-debloat 4.2).
struct DebloatScreen: View {
    @Bindable var model: DebloatModel

    init(model: DebloatModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle("Debloat")
        .task { await model.load() }
        .sheet(item: $model.confirmation) { _ in DebloatSheet(model: model) }
        .sheet(item: $model.lockedPanel) { app in
            VStack(spacing: 0) {
                SealedAppPanel(app: app, size: model.lockedSizes[app.url])
                    .frame(minWidth: 560, minHeight: 360)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { model.lockedPanel = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                // No fixedSize here: in the split view's detail it blanked the whole window (a layout loop).
                Text("Removes Apple's App Store apps (GarageBand, iMovie, Pages, Numbers, Keynote, Xcode…) and what they install. macOS's built-in apps are locked by macOS.")
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.headline)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            // Text, not an icon: the window toolbar already has a ↻ for the Disk Map scan.
            Button("Scan Again") { Task { await model.rescan() } }
                .help("Look for Apple's apps and what they installed again")
            .disabled(model.isMeasuring)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// What exists, never what "you can remove" (ux 3).
    private var headline: String {
        if model.isMeasuring { return "Measuring Apple's apps on this Mac…" }
        if model.rows.isEmpty { return "No removable Apple apps on this Mac." }
        return "Apple's removable apps and what they install use \(model.totalBytes.formattedBytes) on this Mac."
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoadedApps {
            ProgressView("Finding Apple's apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn't list your apps", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.rescan() } }
            }
        } else {
            List {
                // The headline says when there are none.
                if !model.apps.isEmpty {
                    Section("Apple apps you can remove") {
                        ForEach(model.apps) { AppBlock(model: model, row: $0) }
                    }
                }
                if !model.installers.isEmpty {
                    Section("Installers") {
                        ForEach(model.installers) { AppBlock(model: model, row: $0) }
                    }
                }
                if !model.locked.isEmpty {
                    Section {
                        ForEach(model.locked) { LockedRow(model: model, app: $0) }
                    } header: {
                        HStack {
                            Text("Part of macOS (locked)")
                            Spacer()
                            Text(model.locked.reduce(0) { $0 + (model.lockedSizes[$1.url] ?? 0) }.formattedBytes).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(model.footerText)
                .font(.headline)
                .monospacedDigit()
            Spacer()
            Button("Remove…") { model.beginRemove() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(model.tickedRows.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// An app row that expands to everything it installed, each with its own checkbox.
private struct AppBlock: View {
    @Bindable var model: DebloatModel
    let row: DebloatApp

    private var isTicked: Bool { model.isTicked(row) }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.expanded.contains(row.id) },
            set: { if $0 { model.expanded.insert(row.id) } else { model.expanded.remove(row.id) } }
        )) {
            if let plan = row.plan { items(plan) }
        } label: {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Toggle("Remove \(row.app.name)", isOn: Binding(get: { isTicked }, set: { model.setTicked($0, row) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!model.canTick(row))
            FileIcon(url: row.app.url, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).font(.body.weight(.medium))
                if let failure = row.failure {
                    Label("Couldn't look at it: \(failure)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let blocker = row.plan?.blocker {
                    Label(blocker, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if isUnverified {
                    Text("Its content isn't checked on a real install yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(sizeText)
                .monospacedDigit()
                .foregroundStyle(isTicked ? .primary : .secondary)
        }
        .padding(.vertical, 2)
    }

    private var isUnverified: Bool {
        row.plan?.leftovers.contains { $0.note?.hasSuffix(AppleProfile.unverifiedNote) == true } ?? false
    }

    private var sizeText: String {
        guard row.plan != nil else { return row.failure == nil ? "Measuring…" : "–" }
        return isTicked ? "\(model.selectedBytes(row).formattedBytes) selected of \(row.total.formattedBytes)" : "\(row.total.formattedBytes) on disk"
    }

    @ViewBuilder
    private func items(_ plan: UninstallPlan) -> some View {
        ItemRow(
            name: plan.app.url.lastPathComponent, place: plan.app.url.deletingLastPathComponent().displayPath, note: nil,
            bytes: plan.appMeasurement.allocated, badge: DebloatModel.isOwnedBySystem(plan.app.url) ? .admin : nil,
            isChosen: Binding(get: { isTicked }, set: { model.setTicked($0, row) }), canChoose: model.canTick(row)
        )
        ForEach(plan.leftovers) { leftover in
            ItemRow(
                name: leftover.url.lastPathComponent, place: leftover.url.deletingLastPathComponent().displayPath,
                note: model.note(for: leftover, of: row), bytes: leftover.measurement.allocated,
                badge: leftover.needsAdministrator ? (model.canUseAdministrator ? .admin : .needsAdmin) : nil,
                isChosen: Binding(get: { isTicked && model.isChosen(leftover, of: row) }, set: { model.setChosen($0, leftover, of: row) }),
                canChoose: isTicked && model.canChoose(leftover)
            )
        }
        if !row.runtimes.isEmpty {
            Text("Deleted by Xcode's tool, not moved to the Trash")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            ItemRow(
                name: "Simulator runtimes (\(row.runtimes.map(\.name).joined(separator: ", ")))",
                place: nil, note: [DebloatModel.runtimeNote, model.runtimeNote(row).map { $0 + "." }].compactMap { $0 }.joined(separator: " "),
                bytes: row.runtimeBytes, badge: nil,
                isChosen: Binding(get: { isTicked && model.runtimesChosen(row) }, set: { model.setRuntimesChosen($0, row) }),
                canChoose: isTicked
            )
        }
        ForEach(plan.notes, id: \.self) { note in
            let kept = note.hasPrefix("Kept by macOS")
            Label(note, systemImage: kept ? "lock.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
    }
}

private struct ItemRow: View {
    enum Badge { case admin, needsAdmin }

    let name: String
    let place: String?
    let note: String?
    let bytes: UInt64
    let badge: Badge?
    @Binding var isChosen: Bool
    let canChoose: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Remove \(name)", isOn: $isChosen)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canChoose)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if let place {
                    Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let note, !note.isEmpty {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.cautionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch badge {
            case .admin?:
                BadgeText(text: "Admin", help: "Owned by the system. macOS asks for your administrator password to remove it.")
            case .needsAdmin?:
                BadgeText(text: "Needs admin", help: "Owned by the system. macontrol can't remove it in this build.")
            case nil:
                EmptyView()
            }
            Text(bytes.formattedBytes)
                .monospacedDigit()
                .foregroundStyle(isChosen ? .primary : .secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

private struct BadgeText: View {
    let text: String
    let help: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .help(help)
    }
}

/// A Part of macOS row: no checkbox. Selecting it opens the locked panel (section 5).
private struct LockedRow: View {
    let model: DebloatModel
    let app: InstalledApp

    var body: some View {
        Button { model.lockedPanel = app } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16)
                FileIcon(url: app.url, size: 20)
                Text(app.name)
                Spacer(minLength: 8)
                Text(model.lockedSizes[app.url]?.formattedBytes ?? "–").monospacedDigit().foregroundStyle(.secondary)
                Text("Locked by macOS").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows why macOS keeps \(app.name)")
    }
}

/// The confirmation: the shared, mode-aware `TrashSheet`, plus the Copy line for `xcode-select --reset`.
struct DebloatSheet: View {
    let model: DebloatModel

    var body: some View {
        if let confirmation = model.confirmation {
            let count = confirmation.rows.count
            let items = count == 1 ? "1 item" : "\(count) items"
            let permanent = confirmation.mode == .permanent
            let names = DebloatModel.list(confirmation.jobs.map(\.plan.app.name))
            VStack(spacing: 0) {
                TrashSheet(
                    title: permanent ? "Delete \(items) permanently?" : "Move \(items) to the Trash?",
                    message: permanent
                        ? "They skip the Trash and can't be put back. Frees up to \((confirmation.rowBytes + confirmation.runtimeBytes).formattedBytes)."
                        : "\(names) and what \(confirmation.jobs.count == 1 ? "it" : "they") installed move to the Trash. Put them back from History until you empty the Trash, which is when the space is freed.",
                    notes: confirmation.notes,
                    rows: confirmation.rows,
                    confirmTitle: permanent ? "Delete Permanently" : "Move to Trash",
                    report: confirmation.report,
                    notMoved: confirmation.notMoved,
                    isWorking: confirmation.isWorking,
                    errorMessage: confirmation.message,
                    mode: confirmation.mode,
                    onConfirm: { Task { await model.confirm() } },
                    onClose: { model.confirmation = nil }
                )
                if confirmation.breaksDeveloperTools && confirmation.report == nil {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        Text("To fix git and clang afterwards:").foregroundStyle(.secondary)
                        Text(DebloatModel.resetCommand).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DebloatModel.resetCommand, forType: .string)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(width: 640)
                }
            }
        }
    }
}
