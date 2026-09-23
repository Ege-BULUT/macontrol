import MacontrolCore
import SwiftUI
import Uninstaller

/// PLACEHOLDER (scaffold): M6 builds search, sizes, evidence groups, Apple-app section and the uninstall flow.
struct UninstallScreen: View {
    @Bindable var model: UninstallModel

    var body: some View {
        HSplitView {
            List(model.apps, selection: $model.selectedApp) { app in
                Label(app.name, systemImage: app.kind == .builtIn ? "lock.fill" : "app.dashed")
            }
            .frame(minWidth: 220, maxWidth: 300)
            PlanView(plan: model.plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Uninstall")
        .task { await model.loadApps() }
        .onChange(of: model.selectedApp) { Task { await model.loadPlan() } }
    }
}

private struct PlanView: View {
    let plan: UninstallPlan?

    var body: some View {
        if let plan {
            List {
                Section(plan.app.name) {
                    row(plan.app.url, plan.appMeasurement.allocated, detail: plan.blocker ?? "Application")
                }
                Section("Leftovers") {
                    ForEach(plan.leftovers) { leftover in
                        row(leftover.url, leftover.measurement.allocated, detail: leftover.evidence.rawValue)
                    }
                }
            }
        } else {
            ContentUnavailableView("Select an app", systemImage: "app.dashed")
        }
    }

    private func row(_ url: URL, _ bytes: UInt64, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(url.lastPathComponent)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(bytes.formattedBytes).monospacedDigit()
        }
    }
}
