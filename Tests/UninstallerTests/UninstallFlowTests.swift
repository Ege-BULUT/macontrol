import Foundation
import MacontrolCore
import Safety
import Testing
@testable import Uninstaller

@Suite struct UninstallFlowTests {
    /// A Demo app with an in-bundle agent, a user agent pointing into the bundle, and a few leftovers.
    private func demo() throws -> Fixture {
        let fx = try Fixture()
        let app = try fx.app("Demo", id: "com.example.Demo")
        try fx.write(["Label": "com.example.Demo.login", "BundleProgram": "Contents/MacOS/login"],
                     to: "root/Applications/Demo.app/Contents/Library/LaunchAgents/com.example.Demo.login.plist")
        try fx.launchdJob("home/Library/LaunchAgents/com.example.Demo.agent.plist", label: "com.example.Demo.agent",
                          program: app.appendingPathComponent("Contents/MacOS/agent").path)
        try fx.file("home/Library/Caches/com.example.Demo/cache.db")
        try fx.file("home/Library/Preferences/com.example.Demo.plist")
        try fx.file("home/Library/Application Support/Demo/notes.txt")
        try fx.file("root/Library/Application Support/com.example.Demo/state")
        return fx
    }

    /// F-0023: jobs are stopped by exact label before anything is trashed, and the app is checked again after the
    /// last bootout, because a KeepAlive job can relaunch it between the first quit and its own bootout.
    @Test func stopsJobsByExactLabelAfterQuittingAndBeforeTrashing() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let chosen = plan.leftovers.filter(\.isPreselected)

        _ = try await fx.uninstaller().uninstall(plan, leftovers: Set(chosen.map(\.url)))

        let bundle = TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)
        let leftovers = chosen.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        #expect(fx.recorder.events == [
            .quit("Demo"), .bootout("com.example.Demo.login"), .bootout("com.example.Demo.agent"), .quit("Demo"),
            .trash([bundle]), .trash(leftovers),
        ])
    }

    /// F-0030: Safety carries on past a refused item, so the bundle goes alone and first, and its path must be empty
    /// after. When the app stays (Sparkle swapped in a new copy while it quit, App Management said no, or an updater
    /// finished after the Trash step), its data stays too.
    @Test(arguments: [false, true]) func appThatStaysInstalledKeepsItsData(reinstalledAfterTrash: Bool) async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let chosen = plan.leftovers.filter(\.isPreselected)
        if reinstalledAfterTrash {
            let contents = plan.app.url.appendingPathComponent("Contents")
            fx.recorder.afterTrashing = { try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true) }
        } else {
            fx.recorder.refusedPath = plan.app.url.path
        }

        let report = try await fx.uninstaller().uninstall(plan, leftovers: Set(chosen.map(\.url)))

        #expect(fx.recorder.events.last == .trash([TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)]))
        #expect(chosen.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        let kept = report.outcomes.dropFirst().compactMap { if case .failed(let url, _) = $0 { url } else { nil } }
        #expect(kept == chosen.map(\.url), "\(report.outcomes)")
    }

    /// cfprefsd replaces a preferences plist on every write, and apps save settings as they quit. A regular file is
    /// taken as it is at each look; a folder keeps the identity the plan saw.
    @Test func preferencesRewrittenBeforeAndWhileQuittingAreStillTrashed() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let prefs = fx.home.appendingPathComponent("Library/Preferences/com.example.Demo.plist")
        let cache = try #require(plan.leftover("Caches/com.example.Demo", in: fx.home.appendingPathComponent("Library")))
        try Data("window frame".utf8).write(to: prefs, options: .atomic)
        fx.recorder.whileQuitting = { try? Data("window frame, saved on quit".utf8).write(to: prefs, options: .atomic) }

        let report = try await fx.uninstaller().uninstall(plan, leftovers: [prefs, cache.url])

        // A rename keeps the inode, so the Trash copy shows the identity the plist had when it was trashed.
        guard case .trashed(_, let trashedPrefs)? = report.outcomes.last else { Issue.record("\(report.outcomes)"); return }
        let saved = try #require(FileIdentity(url: trashedPrefs))
        #expect(fx.recorder.events.last == .trash([TrashItem(url: cache.url, expectedIdentity: cache.identity),
                                                   TrashItem(url: prefs, expectedIdentity: saved)]))
        #expect(saved != plan.leftover("Preferences/com.example.Demo.plist", in: fx.home.appendingPathComponent("Library"))?.identity)
    }

    @Test func preferencesReplacedByALinkCountAsChanged() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let prefs = fx.home.appendingPathComponent("Library/Preferences/com.example.Demo.plist")
        try FileManager.default.removeItem(at: prefs)
        try FileManager.default.createSymbolicLink(at: prefs, withDestinationURL: try fx.file("home/Documents/thesis.docx"))

        await #expect(throws: UninstallError.changedSincePlan(prefs)) {
            try await fx.uninstaller().uninstall(plan, leftovers: [prefs])
        }
        #expect(fx.recorder.events.isEmpty)
    }

    /// The UI shows `localizedDescription` after "The uninstall stopped before moving anything:".
    @Test func uninstallErrorsReadAsSentences() {
        let errors: [UninstallError] = [
            .blocked("Part of macOS."), .needsAdministrator(URL(fileURLWithPath: "/Library/Logs/Demo")),
            .refused(URL(fileURLWithPath: "/Users/me/Documents"), .protectedLocation("Documents")),
            .refused(URL(fileURLWithPath: "/Users/me/Library/Caches/x"), .identityChanged),
            .changedSincePlan(URL(fileURLWithPath: "/Applications/Demo.app")), .stillRunning("Demo"),
            .bootoutFailed(label: "com.example.Demo.agent", status: 5),
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.contains("UninstallError") && text.hasSuffix("."), "\(error): \(text)")
        }
        #expect(UninstallError.stillRunning("Demo").localizedDescription == "Demo is still running. Quit it, then try again.")
    }

    /// The UI cancels the plan of an app the user has moved past; it must not walk that app's leftovers anyway.
    @Test func cancelledPlanStops() async throws {
        let fx = try demo()
        let app = try await fx.app(named: "Demo")
        let uninstaller = fx.uninstaller()
        let task = Task { try await uninstaller.plan(for: app) }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// uchg makes the bundle unwritable too, which must not read as "owned by the system".
    @Test func lockedBundleSaysItIsLocked() async throws {
        let fx = try Fixture()
        let url = try fx.app("Demo", id: "com.example.Demo")
        let app = try await fx.app(named: "Demo")
        let blocker = withExtendedLifetime(fx) {
            #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
            defer { #expect(chflags(url.path, 0) == 0) }
            return Uninstaller.blocker(for: app)
        }
        #expect(blocker == "Locked in Finder. Clear Locked in its Get Info window, then try again.")
    }

    @Test func appRelaunchedBeforeItsJobsStoppedStopsBeforeTrashing() async throws {
        let fx = try demo()
        fx.recorder.quitResults = [true, false]
        let plan = try await fx.plan("Demo")

        await #expect(throws: UninstallError.stillRunning("Demo")) {
            try await fx.uninstaller().uninstall(plan, leftovers: Set(plan.leftovers.filter(\.isPreselected).map(\.url)))
        }
        #expect(fx.recorder.events == [
            .quit("Demo"), .bootout("com.example.Demo.login"), .bootout("com.example.Demo.agent"), .quit("Demo"),
        ])
    }

    /// F-0069: what the preview lists is exactly what is trashed; a URL the plan never showed is ignored.
    @Test func trashesExactlyTheBundleAndTheChosenPlanItems() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let exactName = try #require(plan.leftovers.first { $0.evidence == .exactName })
        let stranger = try fx.file("home/Documents/Demo/essay.txt")

        _ = try await fx.uninstaller().uninstall(plan, leftovers: [exactName.url, stranger])

        let bundle = TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)
        let leftover = TrashItem(url: exactName.url, expectedIdentity: exactName.identity)
        #expect(fx.recorder.events.suffix(2) == [.trash([bundle]), .trash([leftover])])
        #expect(bundle.expectedIdentity != nil && leftover.expectedIdentity != nil)
    }

    /// T-0072: the mode reaches both batches, and the leftovers follow a bundle that came back `.deleted`.
    @Test func permanentModeReachesBothBatchesAndLeftoversFollowADeletedBundle() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let exactName = try #require(plan.leftovers.first { $0.evidence == .exactName })

        let report = try await fx.uninstaller().uninstall(plan, leftovers: [exactName.url], mode: .permanent)

        #expect(report.outcomes == [.deleted(original: plan.app.url), .deleted(original: exactName.url)])
        #expect(fx.recorder.modes == [.permanent, .permanent])
        #expect(!FileManager.default.fileExists(atPath: exactName.url.path))
    }

    /// F-0030: a failed step ends the uninstall; nothing after it runs.
    @Test func appThatDoesNotQuitStopsEverything() async throws {
        let fx = try demo()
        fx.recorder.quitResults = [false]
        let plan = try await fx.plan("Demo")

        await #expect(throws: UninstallError.stillRunning("Demo")) {
            try await fx.uninstaller().uninstall(plan, leftovers: Set(plan.leftovers.filter(\.isPreselected).map(\.url)))
        }
        #expect(fx.recorder.events == [.quit("Demo")])
    }

    @Test func failedBootoutStopsBeforeTrashing() async throws {
        let fx = try demo()
        fx.recorder.failingLabel = "com.example.Demo.login"
        let plan = try await fx.plan("Demo")

        await #expect(throws: UninstallError.bootoutFailed(label: "com.example.Demo.login", status: 5)) {
            try await fx.uninstaller().uninstall(plan, leftovers: Set(plan.leftovers.filter(\.isPreselected).map(\.url)))
        }
        #expect(fx.recorder.events == [.quit("Demo"), .bootout("com.example.Demo.login")])
    }

    @Test func builtInAppIsBlockedAndNeverTouched() async throws {
        let fx = try Fixture()
        try fx.app("Chess", id: "com.apple.Chess", in: "root/System/Applications")
        try fx.file("home/Library/Containers/com.apple.Chess/Data/Library/Preferences/com.apple.Chess.plist")
        let plan = try await fx.plan("Chess")

        #expect(plan.app.kind == .builtIn)
        #expect(plan.blocker?.contains("Part of macOS") == true)
        #expect(plan.leftovers.isEmpty)
        await #expect(throws: UninstallError.self) { try await fx.uninstaller().uninstall(plan, leftovers: []) }
        #expect(fx.recorder.events.isEmpty)
    }

    @Test func administratorLeftoverIsRefusedBeforeAnyStep() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let administrative = try #require(plan.leftovers.first { $0.needsAdministrator })

        await #expect(throws: UninstallError.needsAdministrator(administrative.url)) {
            try await fx.uninstaller().uninstall(plan, leftovers: [administrative.url])
        }
        #expect(fx.recorder.events.isEmpty)
    }

    @Test func itemReplacedAfterThePlanStopsBeforeAnyStep() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let cache = try #require(plan.leftovers.first { $0.url.lastPathComponent == "com.example.Demo" && !$0.needsAdministrator })
        // Swap the folder for a new object at the same path (inside the test's own temporary folder).
        try FileManager.default.removeItem(at: cache.url)
        try fx.file("home/Library/Caches/com.example.Demo/other.db")

        await #expect(throws: UninstallError.changedSincePlan(cache.url)) {
            try await fx.uninstaller().uninstall(plan, leftovers: [cache.url])
        }
        #expect(fx.recorder.events.isEmpty)
    }

    /// A last line behind the finder: a leftover must lie inside a folder of a Library, whatever its path spells.
    @Test func leftoverOutsideALibraryFolderIsRefusedBeforeAnyStep() async throws {
        let fx = try demo()
        var plan = try await fx.plan("Demo")
        try fx.file("home/Documents/thesis.docx")
        let library = fx.home.appendingPathComponent("Library")
        for stray in [library.appendingPathComponent("Group Containers/../../Documents"), library.appendingPathComponent("Group Containers"), library] {
            plan.leftovers = [Leftover(url: stray, identity: FileIdentity(url: stray), evidence: .appGroup,
                                       measurement: plan.appMeasurement, needsAdministrator: false, note: nil)]
            await #expect(throws: UninstallError.refused(stray, .protectedLocation("Outside the Library folders"))) {
                try await fx.uninstaller().uninstall(plan, leftovers: [stray])
            }
        }
        #expect(fx.recorder.events.isEmpty)
    }

    /// Without a recorded identity there is nothing to prove the path still names what the plan showed.
    @Test func itemWithoutARecordedIdentityCountsAsChanged() async throws {
        let fx = try demo()
        var plan = try await fx.plan("Demo")
        let index = try #require(plan.leftovers.firstIndex { $0.isPreselected })
        plan.leftovers[index].identity = nil
        let url = plan.leftovers[index].url

        await #expect(throws: UninstallError.changedSincePlan(url)) {
            try await fx.uninstaller().uninstall(plan, leftovers: [url])
        }
        #expect(fx.recorder.events.isEmpty)
    }

    /// Removing an old copy must not quit the copy the user works in. A translocated process (Gatekeeper runs a
    /// quarantined app from a random path) may be this copy, so it is matched by identifier.
    @Test func onlyThisBundleAndItsHelpersCountAsRunning() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Users/me/Applications/Demo.app"), name: "Demo",
                               bundleIdentifier: "com.example.Demo", version: nil, kind: .thirdParty, identity: nil)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/0B1C2D3E/d/Demo.app")
        #expect(RunningApps.isInstance(of: app, bundleURL: app.url, bundleIdentifier: "com.example.Demo"))
        #expect(RunningApps.isInstance(of: app, bundleURL: app.url.appendingPathComponent("Contents/Library/LoginItems/Helper.app"),
                                       bundleIdentifier: "com.example.Demo.Helper"))
        #expect(!RunningApps.isInstance(of: app, bundleURL: URL(fileURLWithPath: "/Applications/Demo.app"), bundleIdentifier: "com.example.Demo"))
        #expect(RunningApps.isInstance(of: app, bundleURL: translocated, bundleIdentifier: "com.example.Demo"))
        #expect(!RunningApps.isInstance(of: app, bundleURL: translocated, bundleIdentifier: "com.example.Other"))
    }

    @Test func bootoutPassesTheExactLabelAsOneArgument() async throws {
        let calls = Calls()
        let runner = LaunchctlRunner { arguments in
            calls.append(arguments)
            return arguments.last == "gui/501/com.example.loaded" ? 0 : Launchd.notLoaded
        }

        try await Launchd.bootout(label: "com.example.loaded", runner: runner, uid: 501)
        try await Launchd.bootout(label: "com.example.not-loaded", runner: runner, uid: 501)
        await #expect(throws: UninstallError.bootoutFailed(label: "a/b", status: -1)) {
            try await Launchd.bootout(label: "a/b", runner: runner, uid: 501)
        }
        let failing = LaunchctlRunner { _ in 5 }
        await #expect(throws: UninstallError.bootoutFailed(label: "com.example.x", status: 5)) {
            try await Launchd.bootout(label: "com.example.x", runner: failing, uid: 501)
        }

        #expect(calls.all == [["bootout", "gui/501/com.example.loaded"], ["bootout", "gui/501/com.example.not-loaded"]])
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var all: [[String]] { lock.withLock { calls } }
    func append(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
}
