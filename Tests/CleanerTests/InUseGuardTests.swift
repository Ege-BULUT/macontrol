@testable import Cleaner
import Foundation
import MacontrolCore
import Testing

@Suite struct InUseGuardTests {
    let home = URL(fileURLWithPath: "/Users/me")
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let catchAll = CleanupRule(id: "caches", title: "", category: .appCaches, safety: .safe, paths: ["~/Library/Caches/*"], minimumAgeDays: nil, note: "")

    func measurement(changed ago: TimeInterval? = 30 * 86_400, incomplete: Bool = false) -> ItemMeasurement {
        ItemMeasurement(allocated: 4096, logical: 4096, fileCount: 1, newestModification: ago.map { now.addingTimeInterval(-$0) }, isIncomplete: incomplete)
    }

    func check(
        _ path: String, rule: CleanupRule? = nil, apps: [RunningApp] = [], openFiles: [OpenFile] = [], uninspected: [String] = [],
        changed ago: TimeInterval? = 30 * 86_400
    ) -> String? {
        let guardrail = InUseGuard(processes: ProcessSnapshot(apps: apps, openFiles: openFiles, uninspected: uninspected), now: now)
        return guardrail.skipReason(for: home.appendingPathComponent(path), rule: rule ?? catchAll, measurement: measurement(changed: ago))
    }

    func rule(owners: [String]?, minimumAgeDays: Int? = nil) -> CleanupRule {
        CleanupRule(id: "r", title: "", category: .developer, safety: .safe, paths: [], minimumAgeDays: minimumAgeDays, note: "", owners: owners)
    }

    @Test func oldIdleCachePasses() {
        #expect(check("Library/Caches/com.example.Editor") == nil)
    }

    @Test func runningAppMatchedByBundleIdentifier() {
        let safari = RunningApp(bundleIdentifier: "com.apple.Safari", bundleName: "Safari", executableName: "Safari")
        #expect(check("Library/Caches/com.apple.Safari", apps: [safari]) == "Safari is running")
    }

    /// F-0015: Mole guarded only reverse-DNS names, so dotless caches were deleted under running apps.
    @Test func runningAppMatchedByDotlessNames() {
        let gemini = RunningApp(bundleIdentifier: "com.google.GeminiMacOS", bundleName: "Gemini", executableName: "GeminiHelper")
        #expect(check("Library/Caches/Gemini", apps: [gemini]) == "Gemini is running")
        #expect(check("Library/Caches/GeminiHelper", apps: [gemini]) == "Gemini is running")
        let pip = RunningApp(bundleIdentifier: nil, bundleName: nil, executableName: "pip")
        #expect(check("Library/Caches/pip", apps: [pip]) == "pip is running")
    }

    @Test func runningAppMatchedIgnoringPunctuation() {
        let brave = RunningApp(bundleIdentifier: "com.brave.Browser", bundleName: "Brave Browser", executableName: "Brave Browser")
        #expect(check("Library/Caches/BraveSoftware/Brave-Browser", apps: [brave]) == "Brave Browser is running")
    }

    @Test func declaredOwnersBlockTheirMatches() {
        let firefox = RunningApp(bundleIdentifier: "org.mozilla.firefox", bundleName: "Firefox", executableName: "firefox")
        #expect(check("Library/Caches/Firefox/Profiles/abcd.default", rule: rule(owners: ["Firefox"]), apps: [firefox]) == "Firefox is running")
    }

    /// A reverse-DNS cache belongs to the app it is named after or is a sub-id of, and to a daemon of that name.
    @Test func reverseDNSNamesMatchRelatedBundlesAndDaemons() {
        let code = RunningApp(bundleIdentifier: "com.microsoft.VSCode", bundleName: "Code", executableName: "Electron")
        #expect(check("Library/Caches/com.microsoft.VSCode.ShipIt", apps: [code]) == "Code is running")
        let daemon = RunningApp(bundleIdentifier: nil, bundleName: nil, executableName: "nsurlsessiond")
        #expect(check("Library/Caches/com.apple.nsurlsessiond", apps: [daemon]) == "nsurlsessiond is running")
        #expect(check("Library/Caches/com.microsoft.VSCodeInsiders", apps: [code]) == nil)
        // Found on this Mac: Safari's link extension runs without Safari and cannot reach its cache.
        let linkExtension = RunningApp(bundleIdentifier: "com.apple.Safari.SafariLinkExtension", bundleName: "SafariLinkExtension", executableName: "SafariLinkExtension")
        #expect(check("Library/Caches/com.apple.Safari", apps: [linkExtension]) == nil)
    }

    /// Review probe7: Simulator's dyld caches are mapped, not open, and their folder is not named after Simulator.
    @Test func simulatorCachesAreBlockedByTheCatalogsDeclaredOwners() throws {
        let simulator = try #require(CleanupCatalog.unvalidatedBundled().rules.first { $0.id == "simulator-caches" })
        let path = "Library/Developer/CoreSimulator/Caches/dyld"
        let app = RunningApp(bundleIdentifier: "com.apple.iphonesimulator", bundleName: "Simulator", executableName: "Simulator")
        let service = RunningApp(
            bundleIdentifier: "com.apple.CoreSimulator.CoreSimulatorService", bundleName: nil,
            executableName: "com.apple.CoreSimulator.CoreSimulatorService"
        )
        #expect(check(path, rule: simulator, apps: [app]) == "Simulator is running")
        #expect(check(path, rule: simulator, apps: [service]) != nil)
        #expect(check(path, rule: simulator) == nil)
    }

    /// Review issue 8: the rule's fixed folders (Library, Developer, Xcode) never name an owner.
    @Test func fixedRuleFoldersDoNotBlock() {
        let apps = ["Developer", "Caches", "swift", "sourcekit-lsp"].map { RunningApp(bundleIdentifier: nil, bundleName: nil, executableName: $0) }
        let derivedData = rule(owners: ["com.apple.dt.Xcode", "Xcode", "xcodebuild"])
        #expect(check("Library/Developer/Xcode/DerivedData/Macontrol-abcdef", rule: derivedData, apps: apps) == nil)
        #expect(check("Library/Caches/com.example.Other", apps: apps) == nil)
    }

    @Test func unrelatedAppDoesNotBlock() {
        let editor = RunningApp(bundleIdentifier: "com.example.Editor", bundleName: "Editor", executableName: "Editor")
        #expect(check("Library/Caches/com.example.Other", apps: [editor]) == nil)
    }

    /// F-0015: a cache named after nothing (GIPPseudonymousID) is still protected while a file in it is open.
    @Test func openFileInsideBlocks() {
        let open = OpenFile(path: "/Users/me/Library/Caches/GIPPseudonymousID/store.db", processName: "Gemini")
        #expect(check("Library/Caches/GIPPseudonymousID", openFiles: [open]) == "In use by Gemini")
        #expect(check("Library/Caches/GIPPseudonymousIDOther", openFiles: [open]) == nil)
    }

    /// F-0015 "how": a process whose open files cannot be listed counts as using every item.
    @Test func uninspectedProcessFailsClosed() {
        #expect(check("Library/Caches/com.example.Idle", uninspected: ["Locked Helper"]) == "Could not check which files Locked Helper has open")
    }

    @Test func recentlyWrittenIsSkippedWhateverItsName() {
        #expect(check("Library/Caches/x", changed: 9 * 60) == "Changed in the last 10 minutes")
        #expect(check("Library/Caches/x", changed: -3600) == "Changed in the last 10 minutes")
        #expect(check("Library/Caches/x", changed: 11 * 60) == nil)
    }

    @Test func minimumAgeAppliesPerItem() {
        let logs = rule(owners: [], minimumAgeDays: 7)
        #expect(check("Library/Logs/x", rule: logs, changed: 3 * 86_400) == "Changed in the last 7 days")
        #expect(check("Library/Logs/x", rule: logs, changed: 8 * 86_400) == nil)
        #expect(check("Library/Logs/x", rule: logs, changed: nil) == nil)
    }

    /// F-0015: an owner that is neither declared nor read from a reverse-DNS name is unknown, and unknown is never preselected.
    @Test func ownerStateDecidesTheCaution() {
        let url = { (name: String) in self.home.appendingPathComponent("Library/Caches/\(name)") }
        #expect(InUseGuard.caution(for: url("GIPPseudonymousID"), rule: catchAll, measurement: measurement()) == "Cache of an unidentified app")
        #expect(InUseGuard.caution(for: url("CloudKit"), rule: catchAll, measurement: measurement()) == "Cache of an unidentified app")
        #expect(InUseGuard.caution(for: url("com.google.GeminiMacOS"), rule: catchAll, measurement: measurement()) == nil)
        #expect(InUseGuard.caution(for: url("Homebrew"), rule: rule(owners: ["brew"]), measurement: measurement()) == nil)
        #expect(InUseGuard.caution(for: url("x"), rule: rule(owners: []), measurement: measurement()) == nil)
    }

    /// F-0065: MacTools made a cut-short size uncleanable. Here an incomplete item stays cleanable,
    /// but starts unselected: a fresh write in the unreadable part would be invisible (review probe2).
    @Test func incompleteMeasurementIsACautionNotASkip() {
        let url = home.appendingPathComponent("Library/Caches/com.example.Huge")
        let guardrail = InUseGuard(processes: ProcessSnapshot(apps: [], openFiles: []), now: now)
        #expect(guardrail.skipReason(for: url, rule: catchAll, measurement: measurement(incomplete: true)) == nil)
        #expect(InUseGuard.caution(for: url, rule: catchAll, measurement: measurement(incomplete: true)) == "Some contents could not be read")
    }

    @Test func reverseDNSNames() {
        #expect(["com.apple.Safari", "company.thebrowser.Browser", "org.swift.swiftpm"].allSatisfy(InUseGuard.isReverseDNS))
        #expect(!["GIPPseudonymousID", "Google", "node.js", "Com.Example.App", "com..x", ".npm"].contains(where: InUseGuard.isReverseDNS))
    }
}
