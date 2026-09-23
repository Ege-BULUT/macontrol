import Darwin
import Foundation
import MacontrolCore
import Safety
import Testing
import Uninstaller

/// Records every launchctl call instead of running it, and whether the job's plist was still in place then.
final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(arguments: [String], plistPresent: Bool)] = []
    let plist: URL?

    init(plist: URL? = nil) {
        self.plist = plist
    }

    var calls: [(arguments: [String], plistPresent: Bool)] { lock.withLock { recorded } }

    var runner: LaunchctlRunner {
        LaunchctlRunner { [self] arguments in
            let present = plist.map { FileIdentity(url: $0) != nil } ?? false
            lock.withLock { recorded.append((arguments, present)) }
            return 0
        }
    }
}

/// Uninstalls through the real Uninstaller, TrashService and quit logic, with launchctl recorded. Two apps from one
/// vendor share a vendor folder; the worst-case user checks every leftover the plan offers.
@Suite struct UninstallAttackTests {
    let box: Sandbox
    let library = "home/Library"

    init() throws {
        box = try Sandbox()
        try app("AppA", id: "com.vendor.appa")
        try app("AppB", id: "com.vendor.appb")
        try box.file("home/Documents/thesis.docx")
        for app in ["AppA", "AppB"] {
            try box.file("\(library)/Application Support/Vendor/\(app)/state.db")
        }
        try box.file("\(library)/Application Support/Vendor/shared.db")
        for id in ["com.vendor.appa", "com.vendor.appb", "com.vendor"] {
            try box.file("\(library)/Caches/\(id)/blob")
        }
        try box.file("\(library)/Preferences/com.vendor.appa.plist")
        try box.file("\(library)/Preferences/com.vendor.appb.plist")
    }

    func app(_ name: String, id: String) throws {
        try plist(["CFBundleName": name, "CFBundleExecutable": name, "CFBundleIdentifier": id], at: "root/Applications/\(name).app/Contents/Info.plist")
        try box.file("root/Applications/\(name).app/Contents/MacOS/\(name)")
    }

    func plist(_ value: [String: Any], at relative: String) throws {
        let url = try box.file(relative, size: 0)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    func program(of app: String) -> String {
        box.url("root/Applications/\(app).app/Contents/MacOS/\(app)").path
    }

    /// The live actions with launchctl recorded; `whileQuitting` runs inside each quit, as a racing app would.
    func uninstaller(_ launchctl: LaunchctlRecorder, whileQuitting: (@Sendable () -> Void)? = nil) -> Uninstaller {
        let service = box.service()
        var actions = UninstallActions.live(trash: service, launchctl: launchctl.runner)
        let quit = actions.quit
        actions.quit = { app in
            whileQuitting?()
            return await quit(app)
        }
        return Uninstaller(home: box.home, systemRoot: box.url("root"), trash: service, actions: actions)
    }

    func planForAppA(_ uninstaller: Uninstaller) async throws -> UninstallPlan {
        let app = try #require(try await uninstaller.installedApps().first { $0.name == "AppA" })
        return try await uninstaller.plan(for: app)
    }

    /// AppA goes with its own subfolder, cache, preferences, launch agent and a cache link to Documents (as a link).
    /// AppB's data, the vendor folder, the vendor-wide cache and Documents stay. The agent is booted out by its exact
    /// label, `$(...)` and all, as one argument, before its plist moves. Undo restores both batches.
    @Test func uninstallingOneAppOfAVendorTakesOnlyItsOwn() async throws {
        let agent = try box.file("\(library)/LaunchAgents/com.vendor.appa.agent.plist")
        let label = "com.vendor.appa.agent $(touch PWNED-label)"
        try plist(["Label": label, "ProgramArguments": [program(of: "AppA"), "--daemon"]], at: "\(library)/LaunchAgents/com.vendor.appa.agent.plist")
        try plist(["Label": "com.vendor.appb.agent", "ProgramArguments": [program(of: "AppB")]], at: "\(library)/LaunchAgents/com.vendor.appb.agent.plist")
        try FileManager.default.createSymbolicLink(at: box.url("\(library)/Caches/com.vendor.appa.helper"), withDestinationURL: box.url("home/Documents"))
        let launchctl = LaunchctlRecorder(plist: agent)
        let uninstaller = uninstaller(launchctl)
        let plan = try await planForAppA(uninstaller)
        let before = box.tree()

        let report = try await uninstaller.uninstall(plan, leftovers: Set(plan.leftovers.map(\.url)))

        let gone = [
            "root/Applications/AppA.app", "\(library)/Application Support/Vendor/AppA", "\(library)/Caches/com.vendor.appa",
            "\(library)/Caches/com.vendor.appa.helper", "\(library)/Preferences/com.vendor.appa.plist",
            "\(library)/LaunchAgents/com.vendor.appa.agent.plist",
        ]
        #expect(Sandbox.difference(box.tree(), Sandbox.expected(before, without: gone)) == [])
        #expect(report.outcomes.count == gone.count && report.outcomes.allSatisfy { $0.isTrashed })
        #expect(launchctl.calls.map(\.arguments) == [["bootout", "gui/\(getuid())/\(label)"]])
        #expect(launchctl.calls.allSatisfy { $0.plistPresent }, "the plist moved before its job was stopped")
        let service = box.service()
        for batch in Set(await service.history().map(\.batch)) {
            #expect(await service.undo(batch: batch).allSatisfy { $0.isRestored })
        }
        #expect(Sandbox.difference(box.tree(), before) == [])
        for folder in [box.tmp.url, box.home, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            #expect(!((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasPrefix("PWNED") })
        }
    }

    /// A launchd label with a slash could address another domain or service: nothing is booted out, and since the
    /// job might still run, nothing is trashed either, not even the app.
    @Test func aLabelThatClimbsOutStopsTheUninstallBeforeAnyMove() async throws {
        try plist(["Label": "../../../system/com.apple.Dock", "ProgramArguments": [program(of: "AppA")]], at: "\(library)/LaunchAgents/com.vendor.appa.plist")
        let launchctl = LaunchctlRecorder()
        let uninstaller = uninstaller(launchctl)
        let plan = try await planForAppA(uninstaller)
        let before = box.tree()

        await #expect(throws: UninstallError.self) {
            try await uninstaller.uninstall(plan, leftovers: Set(plan.leftovers.map(\.url)))
        }

        #expect(launchctl.calls.isEmpty)
        #expect(box.tree() == before)
    }

    /// Between the plan and the uninstall, AppA's cache folder becomes a link to Documents: the uninstall stops
    /// before quitting or moving anything.
    @Test func aLeftoverSwappedAfterThePlanStopsEverything() async throws {
        let launchctl = LaunchctlRecorder()
        let uninstaller = uninstaller(launchctl)
        let plan = try await planForAppA(uninstaller)
        try box.swapForSymlink("\(library)/Caches/com.vendor.appa", to: box.url("home/Documents"))
        let before = box.tree()

        let error = await #expect(throws: UninstallError.self) {
            try await uninstaller.uninstall(plan, leftovers: Set(plan.leftovers.map(\.url)))
        }

        guard case .changedSincePlan(let url)? = error else { Issue.record("\(String(describing: error))"); return }
        #expect(url.path == box.url("\(library)/Caches/com.vendor.appa").path)
        #expect(box.tree() == before)
    }

    /// The swap lands while the app quits, after the last check of the plan: the app goes, the swapped leftover
    /// is refused by the Trash, and Documents is untouched.
    @Test func aLeftoverSwappedWhileTheAppQuitsIsRefused() async throws {
        let box = self.box
        let uninstaller = uninstaller(LaunchctlRecorder()) {
            try? box.swapForSymlink("home/Library/Application Support/Vendor/AppA", to: box.url("home/Documents"))
        }
        let plan = try await planForAppA(uninstaller)
        let documents = box.tree().filter { $0.key.hasPrefix("home/Documents") }

        let report = try await uninstaller.uninstall(plan, leftovers: Set(plan.leftovers.map(\.url)))

        let refused = report.outcomes.compactMap { outcome in
            if case .refused(let url, let reason) = outcome { (url.path, reason) } else { nil }
        }
        #expect(refused.map(\.0) == [box.url("\(library)/Application Support/Vendor/AppA").path])
        #expect(refused.map(\.1) == [.identityChanged])
        #expect(report.outcomes.filter(\.isTrashed).count == report.outcomes.count - 1)
        #expect(box.tree().filter { $0.key.hasPrefix("home/Documents") } == documents)
    }
}
