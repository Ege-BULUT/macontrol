import AppKit
import MacontrolCore
import SwiftUI
import Uninstaller

/// Installed apps on the left, the selected app and its leftovers on the right.
struct UninstallScreen: View {
    @Bindable var model: UninstallModel

    var body: some View {
        // An HStack, not HSplitView: the split view asked for more width than its panes' minimums, and at the
        // minimum window it pushed the Uninstall button off screen (T-0056).
        HStack(spacing: 0) {
            AppListPane(model: model)
                .frame(width: 280)
            Divider()
            AppDetailView(model: model)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Uninstall")
        .task { await model.loadApps() }
        .task(id: model.selectedApp) { await model.loadPlan() }
        .sheet(item: $model.confirmation) { _ in UninstallSheet(model: model) }
    }
}

private struct AppListPane: View {
    @Bindable var model: UninstallModel
    // The view keeps the choice across launches; the model mirrors it for its own list logic.
    @AppStorage("uninstallFilter") private var filter = AppFilter.all
    @AppStorage("uninstallSort") private var sort = AppSort.nameAscending

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search apps", text: $model.query)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 8)
            AppListControls(model: model, filter: $filter, sort: $sort)
                .padding([.horizontal, .bottom], 12)
            Divider()
            if !model.hasLoadedApps {
                ProgressView("Finding apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.appsError, model.apps.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't list your apps", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.loadApps() } }
                }
            } else if model.sections.isEmpty {
                Group {
                    if model.filter == .all {
                        ContentUnavailableView.search(text: model.query)
                    } else {
                        let query = model.query.trimmingCharacters(in: .whitespaces)
                        ContentUnavailableView {
                            Label(query.isEmpty ? model.filter.emptyTitle : "\(model.filter.emptyTitle) match", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            if !query.isEmpty { Text("Nothing here matches “\(query)”.") }
                        } actions: {
                            Button("Show All Apps") { filter = .all }
                        }
                    }
                }
                // Fills the pane, so the search field stays at the top.
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selectedApp) {
                    ForEach(model.sections) { section in
                        Section {
                            // The size goes in as a value, so a new size redraws its own row only.
                            ForEach(section.apps) { AppRow(app: $0, size: model.sizes[$0.url], showsDate: sort.usesDate, model: model) }
                        } header: {
                            HStack {
                                Text(section.kind.sectionTitle)
                                Spacer()
                                Text("\(section.apps.count)").monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: filter, initial: true) { model.filter = filter }
        .onChange(of: sort, initial: true) { model.sort = sort }
        // Keyed by the apps, identities included: a reinstalled app lost its size and is measured again.
        .task(id: sort.usesSize ? model.apps : []) {
            if sort.usesSize { await model.measureAll() }
        }
    }
}

/// All, User or System with their counts, and the sort menu. ⌥⌘1-3 pick the filter, ⌃⌥⌘1-6 the order.
private struct AppListControls: View {
    let model: UninstallModel
    @Binding var filter: AppFilter
    @Binding var sort: AppSort

    var body: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $filter) {
                ForEach(AppFilter.allCases) { Text("\($0.title) \(model.count($0))").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Show all apps, apps from other developers, or Apple's apps (⌥⌘1, ⌥⌘2, ⌥⌘3)")
            Menu {
                ForEach(Array(AppSort.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0, index.isMultiple(of: 2) { Divider() }
                    // The shortcut here only labels the item; the hidden buttons below make it work while the menu is closed.
                    Toggle(option.title, isOn: Binding(get: { sort == option }, set: { if $0 { sort = option } }))
                        .keyboardShortcut(Self.key(index), modifiers: [.control, .option, .command])
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Sort order: \(sort.title)")
            .accessibilityLabel("Sort: \(sort.title)")
        }
        .background {
            Group {
                ForEach(Array(AppFilter.allCases.enumerated()), id: \.element) { index, option in
                    Button(option.title) { filter = option }.keyboardShortcut(Self.key(index), modifiers: [.option, .command])
                }
                ForEach(Array(AppSort.allCases.enumerated()), id: \.element) { index, option in
                    Button(option.title) { sort = option }.keyboardShortcut(Self.key(index), modifiers: [.control, .option, .command])
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private static func key(_ index: Int) -> KeyEquivalent { KeyEquivalent(Character(String(index + 1))) }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: UInt64?
    /// Sorted by date added: the row shows the date the order comes from, not the size.
    let showsDate: Bool
    let model: UninstallModel

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(url: app.url, size: 24)
            Text(app.name).lineLimit(1)
            if app.kind == .builtIn {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Part of macOS")
            }
            Spacer(minLength: 8)
            Text(showsDate ? app.dateAdded?.formatted(date: .abbreviated, time: .omitted) ?? "–" : size?.formattedBytes ?? "–")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .task { await model.measureIfNeeded(app) }
        .contextMenu {
            Button("Reveal in Finder") { app.url.revealInFinder() }
        }
    }
}

struct UninstallSheet: View {
    let model: UninstallModel

    var body: some View {
        if let confirmation = model.confirmation {
            let name = confirmation.plan.app.name
            let count = confirmation.leftovers.count
            let run = confirmation.run
            TrashSheet(
                title: run.isPermanent ? "Uninstall \(name) permanently?" : "Uninstall \(name)?",
                message: run.isPermanent
                    ? PermanentText.message(freesUpTo: run.bytes(of: confirmation.rows))
                    : (count == 0 ? "\(name) moves to the Trash." : "\(name) and \(count == 1 ? "1 item" : "\(count) items") it left behind move to the Trash.")
                        + " Put them back from History until you empty the Trash, which is when the space is freed.",
                warning: confirmation.appIsRunning ? "\(name) is open. It will be asked to quit first, so save your work." : nil,
                notes: AdminText.notes(count: confirmation.adminCount, mode: run.mode) + confirmation.notes,
                rows: confirmation.rows,
                confirmTitle: run.isPermanent ? PermanentText.confirm : "Uninstall",
                report: confirmation.report,
                isWorking: confirmation.isWorking,
                errorMessage: confirmation.errorMessage,
                mode: run.mode,
                restorePoint: run.isPermanent
                    ? Binding { model.confirmation?.run.wantsRestorePoint ?? false } set: { model.confirmation?.run.wantsRestorePoint = $0 }
                    : nil,
                run: run,
                onGoOnWithoutRestorePoint: { Task { await model.confirmWithoutRestorePoint() } },
                onConfirm: { Task { await model.confirmUninstall() } },
                onClose: { model.confirmation = nil }
            )
        }
    }
}
