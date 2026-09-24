import Foundation
@testable import MacontrolUI
import Safety
import ScanEngine
import TestSupport
import Testing
import Uninstaller

/// Everything a Debloat run asked the system for, in order.
nonisolated final class DebloatLog: @unchecked Sendable {
    enum Event: Equatable {
        case runtime(String)
        case quit(String)
        case remove([String])
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    var events: [Event] { lock.withLock { recorded } }

    func record(_ event: Event) {
        lock.withLock { recorded.append(event) }
    }
}

/// A home and system root with an Xcode-shaped tree and GarageBand, the real `Uninstaller` over them, and doubles for
/// quit, remove and CoreSimulator's tool. `remove` really moves items into the fixture's Trash folder, so tests assert
/// on disk. Nothing outside the temporary folder is touched, and no app is registered with LaunchServices.
final class DebloatFixture {
    static let runtimes = [("9AC467AB-22DE-48A1-89DA-CB942B60CE83", 8_494_282_293), ("F8C76A0E-1793-436F-847B-57A0501E798E", 3_935_033_546)]

    let tmp: TemporaryDirectory
    let log = DebloatLog()
    var home: URL { tmp.url.appendingPathComponent("home") }
    var root: URL { tmp.url.appendingPathComponent("root") }
    var xcode: URL { root.appendingPathComponent("Applications/Xcode.app") }
    var garageBand: URL { root.appendingPathComponent("Applications/GarageBand.app") }
    /// This runtime's delete fails.
    nonisolated(unsafe) var failingRuntime: String?
    /// These apps don't quit.
    nonisolated(unsafe) var stayRunning: Set<String> = []
    /// The administrator dialog was cancelled: every remove fails and nothing moves.
    nonisolated(unsafe) var cancelAdministrator = false
    private(set) var uninstallCalls = 0

    init() throws {
        tmp = try TemporaryDirectory()
        try app("Xcode", "com.apple.dt.Xcode")
        try app("GarageBand", "com.apple.garageband10")
        for path in [
            "root/Library/Developer/CoreSimulator/Caches/dyld/x", "root/Library/Developer/PrivateFrameworks/CoreSimulator.framework/x",
            "home/Library/Developer/Xcode/DerivedData/Project/x", "home/Library/Developer/CoreSimulator/Devices/UUID/x",
            "root/private/var/db/receipts/com.apple.pkg.Xcode.plist",
            "root/Library/Application Support/GarageBand/Instrument Library/a.caf", "root/Library/Audio/Apple Loops/Apple/loop.caf",
            "home/Library/Containers/com.apple.garageband10/Data/x", "home/Library/Caches/com.apple.garageband10/x",
        ] {
            try tmp.file(path, size: 4096)
        }
        try tmp.directory("Trash")
        // Receipts are root-owned on a real Mac, so they need the helper; TemporaryDirectory makes it writable again.
        chmod(root.appendingPathComponent("private/var/db/receipts").path, 0o555)
    }

    func app(_ name: String, _ id: String) throws {
        let plist = tmp.url.appendingPathComponent("root/Applications/\(name).app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func exists(_ path: String) -> Bool { exists(tmp.url.appendingPathComponent(path)) }

    var actions: UninstallActions {
        let log = log
        let trash = tmp.url.appendingPathComponent("Trash")
        let fixture = tmp.url.path
        return UninstallActions(
            quit: { app in
                log.record(.quit(app.name))
                return !self.stayRunning.contains(app.name)
            },
            bootout: { _ in },
            remove: { items, mode in
                log.record(.remove(items.map(\.url.path)))
                let cancelled = self.cancelAdministrator
                return TrashReport(batch: UUID(), outcomes: items.map { item -> TrashOutcome in
                    guard !cancelled else { return .failed(item.url, message: "The administrator dialog was cancelled.") }
                    guard item.url.path.hasPrefix(fixture + "/") else { return .refused(item.url, .protectedLocation("outside the fixture")) }
                    do {
                        let destination = trash.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.moveItem(at: item.url, to: destination)
                        return mode == .permanent ? .deleted(original: item.url) : .trashed(original: item.url, trashedTo: destination)
                    } catch {
                        return .failed(item.url, message: error.localizedDescription)
                    }
                })
            }
        )
    }

    /// CoreSimulator's tool: lists the two captured runtimes, records each delete.
    var runtimeTool: SimRuntimeTool {
        let log = log
        let failing = failingRuntime
        let json = "{" + Self.runtimes.map { id, bytes in
            #""\#(id)": {"deletable": true, "identifier": "\#(id)", "sizeBytes": \#(bytes), "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5"}"#
        }.joined(separator: ",") + "}"
        return SimRuntimeTool { _, arguments, _ in
            guard arguments.first == "runtime", arguments.count == 3, arguments[1] == "delete" else { return (0, Data(json.utf8)) }
            log.record(.runtime(arguments[2]))
            return (arguments[2] == failing ? 1 : 0, Data())
        }
    }

    /// A loaded model over the fixture, with Xcode and GarageBand classified as Apple's App Store apps (a fixture
    /// can't carry Apple's signature).
    func model(hardcore: Bool = false, administrator: Bool = false, xcodeSelect: String? = nil) async throws -> DebloatModel {
        let uninstaller = Uninstaller(
            home: home, systemRoot: root, trash: TrashService(journalURL: tmp.url.appendingPathComponent("journal.jsonl")), actions: actions
        )
        let model = DebloatModel(
            uninstaller: uninstaller, hardcore: HardcoreMode(isOn: hardcore), engine: ScanEngine(), runtimeTool: runtimeTool,
            developerDirectory: { xcodeSelect },
            uninstallJobs: { jobs, mode in
                self.uninstallCalls += 1
                return await uninstaller.uninstall(jobs, mode: mode)
            },
            canUseAdministrator: administrator
        )
        var apps = try await uninstaller.installedApps()
        for index in apps.indices where ["Xcode", "GarageBand"].contains(apps[index].name) { apps[index].kind = .appleAppStore }
        model.present(apps)
        await model.load()
        return model
    }

    /// Ticks every app (and Xcode's runtimes), then runs the confirmation.
    func run(_ model: DebloatModel, runtimes: Bool = true) async throws {
        for row in model.rows { model.setTicked(true, row) }
        let xcodeRow = try #require(model.row(xcode))
        if runtimes { model.setRuntimesChosen(true, xcodeRow) }
        model.beginRemove()
        #expect(model.confirmation != nil)
        await model.confirm()
    }

    /// Index of the first event that touches Xcode (its quit or any of its paths), or nil.
    func firstXcodeEvent() -> Int? {
        log.events.firstIndex { event in
            switch event {
            case .quit(let name): name == "Xcode"
            case .remove(let paths): paths.contains { $0.hasPrefix(xcode.path) || $0.contains("Developer") || $0.contains("receipts") }
            case .runtime: false
            }
        }
    }
}

/// DESIGN-debloat section 4.6: runtimes first, one uninstall for every app, and what a failure leaves.
@Suite struct DebloatFlowTests {
    @Test func runtimesGoFirstThenOneUninstallForEveryApp() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()

        try await fx.run(model)

        let events = fx.log.events
        let runtimeDeletes = events.indices.filter { if case .runtime = events[$0] { true } else { false } }
        #expect(runtimeDeletes.count == 2)
        let firstXcode = try #require(fx.firstXcodeEvent())
        #expect(runtimeDeletes.allSatisfy { $0 < firstXcode }, "\(events)")
        #expect(fx.uninstallCalls == 1)
        #expect(!fx.exists(fx.xcode) && !fx.exists(fx.garageBand))
        #expect(!fx.exists("home/Library/Developer/Xcode/DerivedData"))
        // Not preselected (a note), and root-owned content without the helper: both stay.
        #expect(fx.exists("home/Library/Developer/CoreSimulator/Devices"))
        #expect(fx.exists("root/Library/Developer/CoreSimulator/Caches"))
        #expect(model.confirmation?.message == nil)
    }

    @Test func aRuntimeFailureKeepsXcodeAndTheOthersGoOn() async throws {
        let fx = try DebloatFixture()
        fx.failingRuntime = DebloatFixture.runtimes[1].0
        let model = try await fx.model()

        try await fx.run(model)

        #expect(fx.exists(fx.xcode) && fx.exists("home/Library/Developer/Xcode/DerivedData"))
        #expect(fx.firstXcodeEvent() == nil, "\(fx.log.events)")
        #expect(!fx.exists(fx.garageBand))
        #expect(fx.uninstallCalls == 1)
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.message?.contains("Simulator runtimes couldn't be deleted, so Xcode was kept") == true)
        #expect(confirmation.notMoved[fx.xcode] != nil)
    }

    /// Security review 4: a cancelled administrator dialog touches no leftover, in both modes.
    @Test(arguments: [false, true])
    func cancelledDialogSaysXcodeIsStillInstalled(hardcore: Bool) async throws {
        let fx = try DebloatFixture()
        fx.cancelAdministrator = true
        let model = try await fx.model(hardcore: hardcore)

        try await fx.run(model)

        #expect(fx.exists(fx.xcode) && fx.exists(fx.garageBand))
        #expect(fx.exists("home/Library/Developer/Xcode/DerivedData") && fx.exists("home/Library/Containers/com.apple.garageband10"))
        let removed = fx.log.events.compactMap { if case .remove(let paths) = $0 { paths } else { nil } }.flatMap { $0 }
        #expect(Set(removed) == [fx.xcode.path, fx.garageBand.path], "a leftover was sent while its bundle stayed")
        #expect(model.confirmation?.message == "Simulator runtimes were deleted; Xcode is still installed.")
    }

    @Test func oneAppsFailureDoesNotStopTheNext() async throws {
        let fx = try DebloatFixture()
        fx.stayRunning = ["GarageBand"]
        let model = try await fx.model()

        try await fx.run(model, runtimes: false)

        #expect(fx.exists(fx.garageBand) && fx.exists("home/Library/Caches/com.apple.garageband10"))
        #expect(!fx.exists(fx.xcode))
        #expect(fx.uninstallCalls == 1)
        #expect(model.confirmation?.message?.hasPrefix("GarageBand was skipped: GarageBand is still running") == true)
        #expect(!fx.log.events.contains { if case .runtime = $0 { true } else { false } })
    }

    /// ux 8: the git and clang note only when xcode-select points inside the bundle being removed.
    @Test(arguments: [
        ("root/Applications/Xcode.app/Contents/Developer", true),
        ("root/Applications/Xcode.app", true),
        ("root/Applications/Xcode.app-beta/Contents/Developer", false),
        ("/Library/Developer/CommandLineTools", false),
        (nil, false),
    ] as [(String?, Bool)])
    func developerToolsNoteOnlyWhenXcodeSelectPointsInside(link: String?, expected: Bool) async throws {
        let fx = try DebloatFixture()
        let resolved = link.map { $0.hasPrefix("/") ? $0 : fx.tmp.url.appendingPathComponent($0).path }
        let model = try await fx.model(xcodeSelect: resolved)
        model.setTicked(true, try #require(model.row(fx.xcode)))
        model.beginRemove()
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.breaksDeveloperTools == expected)
        #expect(confirmation.notes.contains(DebloatModel.developerToolsNote) == expected)
    }
}
