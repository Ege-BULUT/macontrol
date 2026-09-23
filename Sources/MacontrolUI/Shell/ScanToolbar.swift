import SwiftUI

/// Scan scope and rescan, shared by every screen.
struct ScanToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.scan(.home) } label: { Label(ScanScope.home.title, systemImage: ScanScope.home.systemImage) }
                Button { model.scan(.startupDisk) } label: {
                    Label(ScanScope.startupDisk.title, systemImage: ScanScope.startupDisk.systemImage)
                }
                Divider()
                Button("Choose Folder…") { model.isChoosingFolder = true }
            } label: {
                let scope = model.scope ?? .home
                Label("Scan \(scope.title)", systemImage: scope.systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .help("Choose what to scan")
            .accessibilityLabel("Scan scope: \((model.scope ?? .home).title)")
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isScanning {
                Button { model.stopScan() } label: { Label("Stop Scan", systemImage: "stop.fill") }
                    .help("Stop scanning")
            } else {
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Scan \((model.scope ?? .home).title) again (⌘R)")
            }
        }
    }
}
