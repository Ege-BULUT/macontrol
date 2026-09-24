import Darwin
import Foundation
import MacontrolCore
import Safety
import Testing
@testable import Uninstaller

/// DESIGN-debloat section 3.6 with the administrator helper: several apps in one Safety batch, root-owned bundles and
/// leftovers, receipts, and LaunchDaemons left to the helper. The launcher is never started here (the actions are
/// injected); what matters is what the Uninstaller sends.
@Suite struct AdminUninstallTests {
    /// Recorded if anything ever starts it: the Uninstaller only hands it to Safety through the live actions.
    static let launcher = PrivilegedLauncher(helperURL: URL(fileURLWithPath: "/nonexistent/macontrol-priv")) { _, _, _, _ in
        Issue.record("the launcher was started")
    }

    static func uninstaller(_ fx: Fixture, administrator: PrivilegedLauncher? = launcher) -> Uninstaller {
        Uninstaller(
            home: fx.home, systemRoot: fx.root,
            trash: TrashService(journalURL: fx.tmp.url.appendingPathComponent("journal.jsonl")),
            actions: fx.recorder.actions, administrator: administrator
        )
    }

    static func plan(_ fx: Fixture, _ name: String, administrator: PrivilegedLauncher? = launcher) async throws -> UninstallPlan {
        let uninstaller = uninstaller(fx, administrator: administrator)
        let app = try #require(try await uninstaller.installedApps().first { $0.name == name })
        return try await uninstaller.plan(for: app)
    }

    /// Three apps, each with a user leftover and one in /Library.
    static func threeApps() throws -> Fixture {
        let fx = try Fixture()
        for name in ["Alpha", "Beta", "Gamma"] {
            try fx.app(name, id: "com.example.\(name)")
            try fx.file("home/Library/Caches/com.example.\(name)/cache.db")
            try fx.file("root/Library/Application Support/com.example.\(name)/state")
        }
        return fx
    }

    static func items(_ event: Recorder.Event?) -> [TrashItem] {
        if case .trash(let items)? = event { items } else { [] }
    }

    /// One user action, one `remove` call, so at most one administrator dialog: each bundle, then its leftovers,
    /// every leftover with its own bundle as `requiresGone`.
    @Test func severalAppsGoInOneRemoveCall() async throws {
        let fx = try Self.threeApps()
        var jobs: [UninstallJob] = []
        for name in ["Alpha", "Beta", "Gamma"] {
            let plan = try await Self.plan(fx, name)
            jobs.append(UninstallJob(plan: plan, leftovers: Set(plan.leftovers.filter(\.isPreselected).map(\.url))))
        }

        let result = await Self.uninstaller(fx).uninstall(jobs, mode: .trash)

        #expect(result.skipped.isEmpty)
        let batches = fx.recorder.events.filter { if case .trash = $0 { true } else { false } }
        #expect(batches.count == 1)
        let sent = Self.items(batches.first)
        let expected = jobs.flatMap { job in
            [job.plan.app.url] + job.plan.leftovers.filter { job.leftovers.contains($0.url) }.map(\.url)
        }
        #expect(sent.map(\.url) == expected)
        for job in jobs {
            let leftovers = sent.filter { job.leftovers.contains($0.url) }
            #expect(leftovers.count == 2 && leftovers.allSatisfy { $0.requiresGone == job.plan.app.url })
            #expect(sent.first { $0.url == job.plan.app.url }?.requiresGone == nil)
        }
        #expect(result.report.outcomes.count == expected.count)
    }

    /// An app that does not quit, or whose job cannot be stopped, is skipped with its reason; the others still go.
    @Test func anAppThatFailsIsSkippedAndTheOthersGoOn() async throws {
        let fx = try Self.threeApps()
        try fx.launchdJob("home/Library/LaunchAgents/com.example.Gamma.agent.plist", label: "com.example.Gamma.agent",
                          program: fx.root.appendingPathComponent("Applications/Gamma.app/Contents/MacOS/agent").path)
        let plans = [try await Self.plan(fx, "Alpha"), try await Self.plan(fx, "Beta"), try await Self.plan(fx, "Gamma")]
        fx.recorder.quitResults = [true, false]
        fx.recorder.failingLabel = "com.example.Gamma.agent"
        let jobs = plans.map { UninstallJob(plan: $0, leftovers: Set($0.leftovers.filter(\.isPreselected).map(\.url))) }

        let result = await Self.uninstaller(fx).uninstall(jobs)

        #expect(result.skipped == [
            plans[1].app.url: .stillRunning("Beta"),
            plans[2].app.url: .bootoutFailed(label: "com.example.Gamma.agent", status: 5),
        ])
        let sent = Self.items(fx.recorder.events.last)
        #expect(sent.map(\.url) == [plans[0].app.url] + plans[0].leftovers.filter(\.isPreselected).map(\.url))
        #expect(FileManager.default.fileExists(atPath: plans[1].app.url.path) && FileManager.default.fileExists(atPath: plans[2].app.url.path))
    }

    /// A bundle this user cannot move (root-owned, like Apple's App Store apps; a 0555 bundle stands in) is a blocker
    /// without the helper and goes to Safety with it, together with its /Library leftovers.
    @Test func aRootOwnedBundleGoesThroughTheHelper() async throws {
        let fx = try Fixture()
        let bundle = try fx.app("Suite", id: "com.example.Suite")
        let leftover = try fx.file("root/Library/Application Support/com.example.Suite/content")
        #expect(chmod(bundle.path, 0o555) == 0)

        let v1 = try await Self.plan(fx, "Suite", administrator: nil)
        #expect(v1.blocker == "Owned by the system, so removing it needs an administrator. Reveal it in Finder and drag it to the Trash.")
        await #expect(throws: UninstallError.blocked(try #require(v1.blocker))) {
            try await Self.uninstaller(fx, administrator: nil).uninstall(v1, leftovers: [])
        }

        let plan = try await Self.plan(fx, "Suite")
        #expect(plan.blocker == nil)
        let chosen = try #require(plan.leftovers.first { $0.url == leftover.deletingLastPathComponent() })
        #expect(chosen.needsAdministrator && chosen.isPreselected)
        _ = try await Self.uninstaller(fx).uninstall(plan, leftovers: [chosen.url])

        let sent = Self.items(fx.recorder.events.last)
        #expect(sent.map(\.url) == [plan.app.url, chosen.url])
        #expect(sent.last?.requiresGone == plan.app.url)
    }

    /// Package receipts (`pkgutil --forget`'s two files) are a removable area with the helper; anything deeper is not.
    @Test func receiptsAreAcceptedAndNothingDeeper() async throws {
        let fx = try Fixture()
        try fx.app("Tool", id: "com.example.Tool")
        let receipt = try fx.file("root/private/var/db/receipts/com.example.Tool.plist")
        let deeper = try fx.file("root/private/var/db/receipts/sub/com.example.Tool.plist")
        var plan = try await Self.plan(fx, "Tool")
        plan.leftovers = [receipt, deeper].map {
            Leftover(url: $0, identity: FileIdentity(url: $0), evidence: .appleProfile, measurement: plan.appMeasurement,
                     needsAdministrator: true, note: nil)
        }

        await #expect(throws: UninstallError.refused(deeper, .protectedLocation("Outside the Library folders"))) {
            try await Self.uninstaller(fx).uninstall(plan, leftovers: [receipt, deeper])
        }
        _ = try await Self.uninstaller(fx).uninstall(plan, leftovers: [receipt])
        #expect(Self.items(fx.recorder.events.last).map(\.url) == [plan.app.url, receipt])
    }

    /// A LaunchDaemon runs in the system domain: the helper boots it out after launchd confirms the plist, so the
    /// Uninstaller never runs `bootout gui/<uid>/<label>` for it. A /Library/LaunchAgents job is still booted out as
    /// the user first (v1), then its root-owned file goes to the helper.
    @Test func launchDaemonsAreLeftToTheHelper() async throws {
        let fx = try Fixture()
        let app = try fx.app("Demo", id: "com.example.Demo")
        try fx.launchdJob("root/Library/LaunchDaemons/com.example.Demo.helper.plist", label: "com.example.Demo.helper",
                          program: app.appendingPathComponent("Contents/MacOS/helper").path)
        try fx.launchdJob("root/Library/LaunchAgents/com.example.Demo.agent.plist", label: "com.example.Demo.agent",
                          program: app.appendingPathComponent("Contents/MacOS/agent").path)
        let plan = try await Self.plan(fx, "Demo")
        #expect(plan.leftovers.count == 2)

        _ = try await Self.uninstaller(fx).uninstall(plan, leftovers: Set(plan.leftovers.map(\.url)))

        #expect(fx.recorder.events.dropLast() == [.quit("Demo"), .bootout("com.example.Demo.agent"), .quit("Demo")])
        #expect(Self.items(fx.recorder.events.last).map(\.url) == [plan.app.url] + plan.leftovers.map(\.url))
    }

    /// The restore point made before the uninstall reaches the one Safety batch, for its journal lines (section 2.6).
    @Test func theRestorePointReachesTheBatch() async throws {
        let fx = try Fixture()
        try fx.app("Demo", id: "com.example.Demo")
        let plan = try await Self.plan(fx, "Demo")
        let points = Points()
        let actions = UninstallActions(quit: { _ in true }, bootout: { _ in }, remove: { items, _, point in
            points.append(point)
            return TrashReport(batch: UUID(), outcomes: items.map { .refused($0.url, .notImplemented) })
        })
        let uninstaller = Uninstaller(home: fx.home, systemRoot: fx.root, trash: TrashService(journalURL: fx.tmp.url.appendingPathComponent("j.jsonl")),
                                      actions: actions, administrator: Self.launcher)

        _ = try await uninstaller.uninstall(plan, leftovers: [], mode: .permanent, restorePoint: "com.apple.TimeMachine.2026-09-24-101500.local")
        _ = await uninstaller.uninstall([UninstallJob(plan: plan, leftovers: [])])

        #expect(points.all == ["com.apple.TimeMachine.2026-09-24-101500.local", nil])
    }

    /// Without the helper, v1 unchanged: a chosen admin leftover stops everything before any step.
    @Test func withoutTheHelperAdminLeftoversStillStop() async throws {
        let fx = try Fixture()
        try fx.app("Demo", id: "com.example.Demo")
        let state = try fx.file("root/Library/Application Support/com.example.Demo/state").deletingLastPathComponent()
        let plan = try await Self.plan(fx, "Demo", administrator: nil)

        await #expect(throws: UninstallError.needsAdministrator(state)) {
            try await Self.uninstaller(fx, administrator: nil).uninstall(plan, leftovers: [state])
        }
        #expect(fx.recorder.events.isEmpty)
        #expect(!Self.uninstaller(fx, administrator: nil).canUseAdministrator && Self.uninstaller(fx).canUseAdministrator)
    }
}

private final class Points: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [String?] = []
    var all: [String?] { lock.withLock { points } }
    func append(_ point: String?) { lock.withLock { points.append(point) } }
}
