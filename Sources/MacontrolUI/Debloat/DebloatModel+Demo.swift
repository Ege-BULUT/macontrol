import Foundation
import MacontrolCore
import ScanEngine
import Uninstaller

extension DebloatModel {
    /// Sample data for snapshots and previews: the Xcode of feasibility-apple-apps (sizes measured on the test Mac),
    /// an unverified GarageBand, an installer and a few locked apps. Paths are fictional and nothing is read or moved.
    public static func demo() -> DebloatModel {
        demo(hardcore: HardcoreMode())
    }

    static func demo(hardcore: HardcoreMode, loaded: Bool = true, empty: Bool = false) -> DebloatModel {
        let model = DebloatModel(
            uninstaller: nil, hardcore: hardcore, engine: nil, runtimeTool: SimRuntimeTool { _, _, _ in (1, Data()) },
            developerDirectory: { "/Applications/Xcode.app/Contents/Developer" }, canUseAdministrator: true
        )
        guard loaded else { return model }
        let rows = empty ? [] : DemoDebloat.rows
        model.allApps = rows.map(\.app) + DemoDebloat.locked
        model.apps = rows.filter { !$0.app.name.hasPrefix("Install macOS") }
        model.installers = rows.filter { $0.app.name.hasPrefix("Install macOS") }
        model.locked = DemoDebloat.locked
        model.lockedSizes = DemoDebloat.lockedSizes
        model.expanded = empty ? [] : [DemoDebloat.xcode.url]
        model.hasLoadedApps = true
        return model
    }
}

enum DemoDebloat {
    static let xcode = app("Xcode", "com.apple.dt.Xcode", "26.6")
    static let garageBand = app("GarageBand", "com.apple.garageband10", "10.4.12")
    static let installer = app("Install macOS Tahoe", "com.apple.InstallAssistant.macOSTahoe", "26.0", kind: .thirdParty)

    static let rows: [DebloatApp] = [
        DebloatApp(app: garageBand, plan: UninstallPlan(app: garageBand, appMeasurement: size(1_120_000_000), leftovers: [
            leftover("/Library/Application Support/GarageBand", .appleProfile, 2_310_000_000, admin: true,
                     note: AppleProfile.unverifiedNote),
            leftover("/Library/Audio/Apple Loops/Apple", .appleProfile, 1_640_000_000, admin: true,
                     note: "Also used by Logic Pro and MainStage (not installed). \(AppleProfile.unverifiedNote)"),
            leftover("~/Library/Containers/com.apple.garageband10", .containerMetadata, 351_000_000),
        ], blocker: nil)),
        DebloatApp(app: installer, plan: UninstallPlan(app: installer, appMeasurement: size(15_020_000_000), leftovers: [], blocker: nil)),
        DebloatApp(app: xcode, plan: UninstallPlan(app: xcode, appMeasurement: size(3_760_000_000), leftovers: [
            leftover("/Library/Developer/CoreSimulator/Caches", .appleProfile, 6_050_000_000, admin: true),
            leftover("~/Library/Developer/Xcode/DerivedData", .appleProfile, 410_000_000),
            leftover("/Library/Developer/PrivateFrameworks", .appleProfile, 121_000_000, admin: true),
            leftover("/Library/Developer/DeviceKit", .appleProfile, 64_000_000, admin: true),
            leftover("/Library/Developer/CoreDevice", .appleProfile, 22_000_000, admin: true),
            leftover("/Library/Developer/DeveloperDiskImages", .appleProfile, 18_000_000, admin: true),
            leftover("/private/var/db/receipts/com.apple.pkg.Xcode.bom", .appleProfile, 39_600_000, admin: true),
            leftover("/private/var/db/receipts/com.apple.pkg.Xcode.plist", .appleProfile, 4_096, admin: true),
            leftover("~/Library/Developer/CoreSimulator/Devices", .appleProfile, 3_320_000_000,
                     note: "Holds the apps and data inside your simulators."),
            leftover("~/Library/Caches/com.apple.dt.Xcode", .bundleIdentifier, 182_000_000),
            leftover("~/Library/Preferences/com.apple.dt.Xcode.plist", .bundleIdentifier, 61_000),
        ], blocker: nil, notes: [
            "Kept by macOS: MobileDeviceDevelopment. It sits where even an administrator can't change it.",
        ]), runtimes: [
            SimRuntime(id: "9AC467AB-22DE-48A1-89DA-CB942B60CE83", name: "iOS 26.5", bytes: 8_494_282_293),
            SimRuntime(id: "F8C76A0E-1793-436F-847B-57A0501E798E", name: "watchOS 26.5", bytes: 3_935_033_546),
        ]),
    ]

    static let locked: [InstalledApp] = [
        app("Chess", "com.apple.Chess", "3.18", kind: .builtIn, folder: "/System/Applications"),
        app("News", "com.apple.news", "11.0", kind: .builtIn, folder: "/System/Applications"),
        app("Stocks", "com.apple.stocks", "7.0", kind: .builtIn, folder: "/System/Applications"),
        app("Tips", "com.apple.tips", "26.0", kind: .builtIn, folder: "/System/Applications"),
    ]

    static let lockedSizes: [URL: UInt64] = Dictionary(uniqueKeysWithValues: zip(locked.map(\.url), [10_800_000, 4_100_000, 2_200_000, 4_500_000]))

    private static func app(_ name: String, _ id: String, _ version: String, kind: AppKind = .appleAppStore, folder: String = "/Applications") -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "\(folder)/\(name).app"), name: name, bundleIdentifier: id, version: version, kind: kind, identity: nil)
    }

    private static func size(_ bytes: UInt64) -> ItemMeasurement {
        ItemMeasurement(allocated: bytes, logical: bytes, fileCount: 10, newestModification: nil, isIncomplete: false)
    }

    private static func leftover(_ path: String, _ evidence: LeftoverEvidence, _ bytes: UInt64, admin: Bool = false, note: String? = nil) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path.replacingOccurrences(of: "~/", with: "/Users/demo/")), identity: nil,
            evidence: evidence, measurement: size(bytes), needsAdministrator: admin, note: note
        )
    }
}
