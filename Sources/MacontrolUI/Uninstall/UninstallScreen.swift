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

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search apps", text: $model.query)
                .padding(12)
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
                ContentUnavailableView.search(text: model.query)
            } else {
                List(selection: $model.selectedApp) {
                    ForEach(model.sections) { section in
                        Section {
                            // The size goes in as a value, so a new size redraws its own row only.
                            ForEach(section.apps) { AppRow(app: $0, size: model.sizes[$0.url], model: model) }
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
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: UInt64?
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
            Text(size?.formattedBytes ?? "–")
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
            TrashSheet(
                title: "Uninstall \(name)?",
                message: (count == 0 ? "\(name) moves to the Trash." : "\(name) and \(count == 1 ? "1 item" : "\(count) items") it left behind move to the Trash.")
                    + " Put them back from History until you empty the Trash, which is when the space is freed.",
                warning: confirmation.appIsRunning ? "\(name) is open. It will be asked to quit first, so save your work." : nil,
                notes: confirmation.notes,
                rows: confirmation.rows,
                confirmTitle: "Uninstall",
                report: confirmation.report,
                isWorking: confirmation.isWorking,
                errorMessage: confirmation.errorMessage,
                onConfirm: { Task { await model.confirmUninstall() } },
                onClose: { model.confirmation = nil }
            )
        }
    }
}
