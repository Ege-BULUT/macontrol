import Foundation
import MacontrolCore
import Uninstaller

extension UninstallModel {
    /// Sample apps covering every state: a running third-party app with every kind of leftover
    /// (shared, exact-name, admin-only), an Apple app with an admin-only library, and apps that are
    /// part of macOS. `showing` picks which one is open. Paths are fictional and nothing is read or moved.
    static func demo(showing kind: AppKind = .thirdParty) -> UninstallModel {
        let plan = DemoApps.plans.first { $0.app.kind == kind }
        let model = UninstallModel(uninstaller: nil, apps: DemoApps.apps, plan: plan, engine: nil)
        for plan in DemoApps.plans { model.plans[plan.app.url] = plan }
        model.sizes = DemoApps.sizes
        model.runningBundleIDs = ["com.example.Editor"]
        model.support = .demo
        return model
    }
}

enum DemoApps {
    static let editor = app("Editor", "com.example.Editor", "4.2.1", .thirdParty, daysAgo: 12)
    static let garageBand = app("GarageBand", "com.apple.garageband10", "10.4.12", .appleAppStore, daysAgo: 400)
    /// Root-owned, as App Store installs are: blocked, with leftovers still listed.
    static let pages = app("Pages", "com.apple.iWork.Pages", "14.4", .appleAppStore, daysAgo: 95)
    static let chess = app("Chess", "com.apple.Chess", "3.18", .builtIn, daysAgo: 60, folder: "/System/Applications")

    static let apps: [InstalledApp] = [
        editor,
        app("Pixel Studio", "com.example.PixelStudio", "2.0", .thirdParty, daysAgo: 230),
        app("Podcast Maker", "com.example.PodcastMaker", "1.8.3", .thirdParty, daysAgo: 3),
        app("Terminal Plus", "com.example.TerminalPlus", "0.9", .thirdParty, daysAgo: 41),
        garageBand,
        pages,
        app("Safari", "com.apple.Safari", "26.0", .builtIn, daysAgo: 60),
        chess,
        app("Photo Booth", "com.apple.PhotoBooth", "13.1", .builtIn, daysAgo: 60, folder: "/System/Applications"),
    ]

    static let sizes: [URL: UInt64] = Dictionary(uniqueKeysWithValues: zip(apps.map(\.url), [
        620_400_000, 1_870_000_000, 245_000_000, 38_600_000, 1_120_000_000, 612_000_000, 14_300_000, 8_100_000, 4_700_000,
    ]))

    static let plans: [UninstallPlan] = [
        UninstallPlan(app: editor, appMeasurement: size(620_400_000), leftovers: [
            leftover("~/Library/Application Support/com.example.Editor", .bundleIdentifier, 1_400_000_000),
            leftover("~/Library/Caches/com.example.Editor", .bundleIdentifier, 1_310_000_000),
            leftover("~/Library/Preferences/com.example.Editor.plist", .bundleIdentifier, 4_096),
            leftover("~/Library/Saved Application State/com.example.Editor.savedState", .bundleIdentifier, 212_000),
            leftover("/Library/Application Support/com.example.Editor", .bundleIdentifier, 45_000_000, admin: true, note: Uninstaller.unvouchedNote("Editor")),
            leftover("~/Library/Containers/com.example.Editor.QuickLook", .containerMetadata, 12_300_000),
            leftover("~/Library/Group Containers/A1B2C3D4E5.com.example.shared", .appGroup, 85_000_000,
                     note: "Also used by Editor Pro, which stays installed."),
            leftover("~/Library/LaunchAgents/com.example.Editor.updater.plist", .launchdJob, 2_048, label: "com.example.Editor.updater"),
            leftover("~/Library/Application Support/Editor", .exactName, 20_100_000),
        ], blocker: nil, bundleLaunchdLabels: ["com.example.Editor.helper"],
        notes: ["Its installer's receipt (com.example.Editor.pkg) stays in the system's install history."]),
        UninstallPlan(app: garageBand, appMeasurement: size(1_120_000_000), leftovers: [
            leftover("~/Library/Containers/com.apple.garageband10", .containerMetadata, 351_000_000),
            leftover("/Library/Application Support/GarageBand", .contentLibrary, 2_310_000_000, admin: true,
                     note: "Instruments and sounds, shared with Logic Pro if you install it."),
        ], blocker: nil),
        UninstallPlan(app: pages, appMeasurement: size(612_000_000), leftovers: [
            leftover("~/Library/Containers/com.apple.iWork.Pages", .containerMetadata, 96_000_000),
        ], blocker: "Owned by the system, so removing it needs an administrator. Reveal it in Finder and drag it to the Trash."),
        UninstallPlan(app: chess, appMeasurement: size(8_100_000), leftovers: [], blocker:
            "Chess is part of macOS. It lives on the sealed, read-only system volume, which macOS restores on every update, so no app can remove it."),
    ]

    /// Days before 1 September 2026, so snapshots stay the same from day to day.
    private static func app(
        _ name: String, _ id: String, _ version: String, _ kind: AppKind, daysAgo: Double, folder: String = "/Applications"
    ) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: "\(folder)/\(name).app"), name: name, bundleIdentifier: id, version: version, kind: kind,
            identity: nil, dateAdded: Date(timeIntervalSince1970: 1_788_220_800 - daysAgo * 86_400)
        )
    }

    private static func size(_ bytes: UInt64) -> ItemMeasurement {
        ItemMeasurement(allocated: bytes, logical: bytes, fileCount: 10, newestModification: nil, isIncomplete: false)
    }

    private static func leftover(
        _ path: String, _ evidence: LeftoverEvidence, _ bytes: UInt64, admin: Bool = false, note: String? = nil, label: String? = nil
    ) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path.replacingOccurrences(of: "~/", with: "/Users/demo/")), identity: nil,
            evidence: evidence, measurement: size(bytes), needsAdministrator: admin, note: note, launchdLabel: label
        )
    }
}
