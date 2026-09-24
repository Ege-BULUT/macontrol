// swift-tools-version: 6.2
import PackageDescription

// UI code defaults to the main actor. Core modules do not: their scan and file work must
// never land on the main thread by accident (docs/ARCHITECTURE.md, "Concurrency").
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "macontrol",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Macontrol", targets: ["Macontrol"]),
        .executable(name: "mcscan", targets: ["mcscan"]),
        // The privileged helper, bundled as Contents/Helpers/macontrol-priv (docs/DESIGN-debloat.md section 3).
        .executable(name: "macontrol-priv", targets: ["PrivilegedHelper"]),
    ],
    targets: [
        // Shared model: file identity, the scan tree, sizes, permission probe.
        .target(name: "MacontrolCore"),
        // All sizing: tree scans, item measurement, "frees now" estimates, volume stats.
        .target(name: "ScanEngine", dependencies: ["MacontrolCore"]),
        // All file mutation: protected paths, Move to Trash, undo journal.
        .target(name: "Safety", dependencies: ["MacontrolCore"]),
        // Cleanup catalog and junk scan.
        .target(
            name: "Cleaner",
            dependencies: ["MacontrolCore", "ScanEngine", "Safety"],
            resources: [.copy("Resources/catalog.json")]
        ),
        // Installed apps, leftovers, uninstall plans.
        .target(
            name: "Uninstaller",
            dependencies: ["MacontrolCore", "ScanEngine", "Safety"],
            resources: [.copy("Resources/apple-apps.json")]
        ),
        // SwiftUI screens, view models, disk map geometry, snapshot renderer.
        .target(
            name: "MacontrolUI",
            dependencies: ["MacontrolCore", "ScanEngine", "Safety", "Cleaner", "Uninstaller"],
            swiftSettings: mainActorByDefault
        ),
        .executableTarget(name: "Macontrol", dependencies: ["MacontrolUI", "Safety"], swiftSettings: mainActorByDefault),
        // Command-line scanner for research/bench/run.sh.
        .executableTarget(name: "mcscan", dependencies: ["ScanEngine"]),
        // Runs as root for one checked request, started by the app through the admin dialog.
        .executableTarget(name: "PrivilegedHelper", dependencies: ["MacontrolCore", "Safety"]),

        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "MacontrolCoreTests", dependencies: ["MacontrolCore", "TestSupport"]),
        .testTarget(name: "ScanEngineTests", dependencies: ["ScanEngine", "TestSupport"]),
        .testTarget(name: "SafetyTests", dependencies: ["Safety", "TestSupport"]),
        .testTarget(name: "CleanerTests", dependencies: ["Cleaner", "TestSupport"]),
        .testTarget(name: "UninstallerTests", dependencies: ["Uninstaller", "TestSupport"]),
        .testTarget(
            name: "MacontrolUITests",
            dependencies: ["MacontrolUI", "TestSupport"],
            swiftSettings: mainActorByDefault
        ),
        // Hostile fixture trees driven through every destructive path (T-0052).
        .testTarget(
            name: "SafetyAttackTests",
            dependencies: ["MacontrolCore", "ScanEngine", "Safety", "Cleaner", "Uninstaller", "MacontrolUI", "TestSupport"]
        ),
    ]
)
