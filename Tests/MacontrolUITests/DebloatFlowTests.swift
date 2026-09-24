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
    /// `simctl runtime list` ends with this status.
    nonisolated(unsafe) var listStatus: Int32 = 0
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

    /// CoreSimulator's tool: lists the two captured runtimes, records Xcode's quit and each delete.
    var runtimeTool: SimRuntimeTool {
        let log = log
        let failing = failingRuntime
        let listStatus = listStatus
        let json = "{" + Self.runtimes.map { id, bytes in
            #""\#(id)": {"deletable": true, "identifier": "\#(id)", "sizeBytes": \#(bytes), "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5"}"#
        }.joined(separator: ",") + "}"
        return SimRuntimeTool(
            run: { _, arguments, _ in
                guard arguments.first == "runtime", arguments.count == 3, arguments[1] == "delete" else {
                    return (listStatus, listStatus == 0 ? Data(json.utf8) : Data())
                }
                log.record(.runtime(arguments[2]))
                return (arguments[2] == failing ? 1 : 0, Data())
            },
            quit: { app in
                log.record(.quit(app.name))
                return !self.stayRunning.contains(app.name)
            }
        )
    }

    /// A loaded model over the fixture, with Xcode and GarageBand classified as Apple's App Store apps (a fixture
    /// can't carry Apple's signature).
    func model(
        hardcore: Bool = false, administrator: Bool = false, xcodeSelect: String? = nil, appStore: Set<String> = ["Xcode", "GarageBand"]
    ) async throws -> DebloatModel {
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
        for index in apps.indices where appStore.contains(apps[index].name) { apps[index].kind = .appleAppStore }
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

    /// Index of the first remove that touches Xcode or its content, or nil. Its quit comes before the runtimes on
    /// purpose (review 3).
    func firstXcodeEvent() -> Int? {
        log.events.firstIndex { event in
            guard case .remove(let paths) = event else { return false }
            return paths.contains { $0.hasPrefix(xcode.path) || $0.contains("Developer") || $0.contains("receipts") }
        }
    }

    var runtimeDeletes: Int { log.events.filter { if case .runtime = $0 { true } else { false } }.count }
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
        // Review 3: Xcode (and Simulator inside it) quits before the delete shuts down the simulators.
        let quit = try #require(events.firstIndex(of: .quit("Xcode")))
        #expect(runtimeDeletes.allSatisfy { quit < $0 }, "\(events)")
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

    /// Review 1: "couldn't list" is not "there are none". Xcode can't be ticked, and the others still go.
    @Test func aFailedRuntimeListKeepsXcode() async throws {
        let fx = try DebloatFixture()
        fx.listStatus = 1
        let model = try await fx.model()
        let xcode = try #require(model.row(fx.xcode))
        #expect(xcode.plan != nil && xcode.runtimes.isEmpty)
        #expect(xcode.failure?.hasPrefix("Couldn't list its simulator runtimes, so Xcode is kept") == true)
        #expect(!model.canTick(xcode))

        for row in model.rows { model.setTicked(true, row) }
        model.beginRemove()
        #expect(model.confirmation?.jobs.map(\.plan.app.name) == ["GarageBand"])
        await model.confirm()
        #expect(fx.exists(fx.xcode) && fx.exists("root/Library/Developer/PrivateFrameworks"))
        #expect(!fx.exists(fx.garageBand))
    }

    /// Review 3: an Xcode that doesn't quit keeps its runtimes, its simulators and itself.
    @Test func anXcodeThatDoesNotQuitKeepsItsRuntimes() async throws {
        let fx = try DebloatFixture()
        fx.stayRunning = ["Xcode"]
        let model = try await fx.model()

        try await fx.run(model)

        #expect(fx.runtimeDeletes == 0 && fx.firstXcodeEvent() == nil, "\(fx.log.events)")
        #expect(fx.exists(fx.xcode) && !fx.exists(fx.garageBand))
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.message == "Xcode was skipped: Xcode is still running. Quit it, then try again.")
        #expect(confirmation.notMoved[fx.xcode] == "Xcode was skipped.")
    }

    /// Review 8: Xcode replaced after the list (an App Store update). Nothing is deleted for good first.
    @Test func anXcodeReplacedAfterTheListKeepsItsRuntimes() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()
        let row = try #require(model.row(fx.xcode))
        model.setTicked(true, row)
        model.setRuntimesChosen(true, row)
        model.beginRemove()
        try FileManager.default.moveItem(at: fx.xcode, to: fx.tmp.url.appendingPathComponent("old-Xcode.app"))
        try fx.app("Xcode", "com.apple.dt.Xcode")

        await model.confirm()

        #expect(fx.runtimeDeletes == 0 && fx.exists(fx.xcode), "\(fx.log.events)")
        #expect(!fx.log.events.contains(.quit("Xcode")))
        #expect(model.confirmation?.message?.hasPrefix("Xcode was skipped: Xcode.app changed after the list was made.") == true)
    }

    /// Review 3: the sheet lists what happens in the order it happens, simulators shutting down included.
    @Test func notesFollowTheOrderOfTheRun() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()
        let row = try #require(model.row(fx.xcode))
        model.setTicked(true, row)
        model.setRuntimesChosen(true, row)
        model.beginRemove()
        let notes = try #require(model.confirmation?.notes)
        #expect(notes.count >= 2)
        #expect(notes[0].hasPrefix("Asks Xcode to quit first"))
        #expect(notes[1].hasPrefix("Then deletes 2 simulator runtimes") && notes[1].contains("shuts down any simulator still running"))
    }

    /// Review 4 (D12): the Trash-mode message promises History only for what History can put back.
    @Test func trashMessageSaysWhatHistoryCantPutBack() async throws {
        let fx = try DebloatFixture()
        let plain = try await fx.model()
        plain.setTicked(true, try #require(plain.row(fx.garageBand)))
        plain.beginRemove()
        let own = try #require(plain.confirmation?.summary)
        #expect(own.hasSuffix("Put them back from History until then."), "\(own)")

        let admin = try await fx.model(administrator: true)
        let xcode = try #require(admin.row(fx.xcode))
        admin.setTicked(true, xcode)
        admin.setRuntimesChosen(true, xcode)
        admin.beginRemove()
        let confirmation = try #require(admin.confirmation)
        #expect(confirmation.administratorItems > 0)
        #expect(confirmation.summary.contains("Items owned by the system can't be put back from History: drag them out of the Trash in Finder."))
        #expect(!confirmation.summary.contains("Put them back from History until then."))
        #expect(confirmation.summary.hasSuffix("The simulator runtimes are deleted now and can't be put back."))
    }

    /// Review 5: GarageBand and Logic Pro share Apple Loops. Counted once, sent once, one sheet row.
    @Test func sharedContentIsCountedAndSentOnce() async throws {
        let fx = try DebloatFixture()
        try fx.app("Logic Pro", "com.apple.logic10")
        try fx.tmp.file("root/Library/Application Support/Logic/Alchemy/a.caf", size: 4096)
        let model = try await fx.model(administrator: true, appStore: ["Xcode", "GarageBand", "Logic Pro"])
        var unique: [URL: UInt64] = [:]
        for row in model.rows {
            let plan = try #require(row.plan)
            unique[plan.app.url] = plan.appMeasurement.allocated
            for leftover in plan.leftovers { unique[leftover.url] = leftover.measurement.allocated }
        }
        let xcode = try #require(model.row(fx.xcode))
        #expect(model.totalBytes == unique.values.reduce(0, +) + xcode.runtimeBytes)

        var loops: URL?
        for name in ["GarageBand", "Logic Pro"] {
            let row = try #require(model.rows.first { $0.app.name == name })
            model.setTicked(true, row)
            let shared = try #require(row.plan?.leftovers.first { $0.url.path.hasSuffix("Apple Loops/Apple") })
            model.setChosen(true, shared, of: row)
            loops = shared.url
        }
        let chosen = model.tickedRows.flatMap { [$0.id] + model.chosenLeftovers($0).map(\.url) }
        #expect(model.bytesToRemove == Set(chosen).reduce(0) { $0 + unique[$1]! })
        model.beginRemove()
        let confirmation = try #require(model.confirmation)
        let shared = try #require(loops)
        #expect(confirmation.rows.map(\.url).count == Set(confirmation.rows.map(\.url)).count)
        #expect(confirmation.jobs.filter { $0.leftovers.contains(shared) }.count == 1)
    }

    /// Every Xcode lists the same runtimes: ticked in both rows, each is deleted and counted once.
    @Test func runtimesSharedByTwoXcodesAreDeletedOnce() async throws {
        let fx = try DebloatFixture()
        try fx.app("Xcode-beta", "com.apple.dt.Xcode")
        let model = try await fx.model(appStore: ["Xcode", "Xcode-beta"])
        #expect(model.rows.count == 2)
        for row in model.rows {
            model.setTicked(true, row)
            model.setRuntimesChosen(true, row)
        }
        #expect(model.runtimeBytesToDelete == 12_429_315_839)
        model.beginRemove()
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.runtimes.flatMap(\.runtimes).count == 2 && confirmation.runtimeBytes == 12_429_315_839)
    }
}
