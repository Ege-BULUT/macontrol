import Foundation
import MacontrolCore
import Observation
import Uninstaller

@Observable
public final class UninstallModel {
    public private(set) var apps: [InstalledApp]
    public var selectedApp: InstalledApp.ID?
    public private(set) var plan: UninstallPlan?

    private let uninstaller: Uninstaller?

    public init(uninstaller: Uninstaller?, apps: [InstalledApp] = [], plan: UninstallPlan? = nil) {
        self.uninstaller = uninstaller
        self.apps = apps
        self.plan = plan
        self.selectedApp = plan?.app.id
    }

    func loadApps() async {
        guard let uninstaller, apps.isEmpty else { return }
        apps = ((try? await uninstaller.installedApps()) ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func loadPlan() async {
        guard let uninstaller, let app = apps.first(where: { $0.id == selectedApp }) else { return }
        plan = try? await uninstaller.plan(for: app)
    }

    static func demo() -> UninstallModel {
        func app(_ name: String, _ id: String, _ kind: AppKind, folder: String = "/Applications") -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "\(folder)/\(name).app"), name: name, bundleIdentifier: id, version: "1.0", kind: kind, identity: nil)
        }
        let editor = app("Editor", "com.example.Editor", .thirdParty)
        let size = { (gigabytes: Double) in
            ItemMeasurement(allocated: UInt64(gigabytes * 1_000_000_000), logical: 0, fileCount: 10, newestModification: nil, isIncomplete: false)
        }
        let plan = UninstallPlan(app: editor, appMeasurement: size(0.62), leftovers: [
            Leftover(url: URL(fileURLWithPath: "/Users/demo/Library/Application Support/com.example.Editor"), identity: nil,
                     evidence: .bundleIdentifier, measurement: size(1.4), needsAdministrator: false, note: nil),
            Leftover(url: URL(fileURLWithPath: "/Users/demo/Library/Application Support/Editor"), identity: nil,
                     evidence: .exactName, measurement: size(0.02), needsAdministrator: false, note: nil),
        ], blocker: nil)
        return UninstallModel(uninstaller: nil, apps: [
            editor,
            app("GarageBand", "com.apple.garageband10", .appleAppStore),
            app("Chess", "com.apple.Chess", .builtIn, folder: "/System/Applications"),
        ], plan: plan)
    }
}
