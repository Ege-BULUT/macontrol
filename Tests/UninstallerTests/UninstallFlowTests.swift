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

    @Test func stopsJobsByExactLabelAfterQuittingAndBeforeTrashing() async throws {
        let fx = try demo()
        let plan = try await fx.plan("Demo")
        let chosen = plan.leftovers.filter(\.isPreselected)

        _ = try await fx.uninstaller().uninstall(plan, leftovers: Set(chosen.map(\.url)))

        let trashed = [TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)]
            + chosen.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        #expect(fx.recorder.events == [
            .quit("Demo"), .bootout("com.example.Demo.login"), .bootout("com.example.Demo.agent"), .trash(trashed),
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
        fx.recorder.quitSucceeds = false
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
