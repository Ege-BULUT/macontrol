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

        let trashed = [TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)]
            + chosen.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        #expect(fx.recorder.events == [
            .quit("Demo"), .bootout("com.example.Demo.login"), .bootout("com.example.Demo.agent"), .quit("Demo"), .trash(trashed),
        ])
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

        let items = [TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity),
                     TrashItem(url: exactName.url, expectedIdentity: exactName.identity)]
        #expect(fx.recorder.events.last == .trash(items))
        #expect(items.allSatisfy { $0.expectedIdentity != nil })
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
