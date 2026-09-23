@testable import Cleaner
import Foundation
import MacontrolCore
import Testing

@Suite struct InUseGuardTests {
    let home = URL(fileURLWithPath: "/Users/me")
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func check(
        _ path: String, apps: [RunningApp] = [], openFiles: [OpenFile] = [],
        changed ago: TimeInterval? = 30 * 86_400, incomplete: Bool = false, minimumAgeDays: Int? = nil
    ) -> String? {
        let guardrail = InUseGuard(processes: ProcessSnapshot(apps: apps, openFiles: openFiles), home: home, now: now)
        let measurement = ItemMeasurement(
            allocated: 4096, logical: 4096, fileCount: 1,
            newestModification: ago.map { now.addingTimeInterval(-$0) }, isIncomplete: incomplete
        )
        return guardrail.skipReason(for: home.appendingPathComponent(path), measurement: measurement, minimumAgeDays: minimumAgeDays)
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

    @Test func runningAppMatchedAnywhereOnThePathIgnoringPunctuation() {
        let brave = RunningApp(bundleIdentifier: "com.brave.Browser", bundleName: "Brave Browser", executableName: "Brave Browser")
        #expect(check("Library/Caches/BraveSoftware/Brave-Browser", apps: [brave]) == "Brave Browser is running")
        let firefox = RunningApp(bundleIdentifier: "org.mozilla.firefox", bundleName: "Firefox", executableName: "firefox")
        #expect(check("Library/Caches/Firefox/Profiles/abcd.default", apps: [firefox]) == "Firefox is running")
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

    @Test func recentlyWrittenIsSkippedWhateverItsName() {
        #expect(check("Library/Caches/x", changed: 9 * 60) == "Changed in the last 10 minutes")
        #expect(check("Library/Caches/x", changed: -3600) == "Changed in the last 10 minutes")
        #expect(check("Library/Caches/x", changed: 11 * 60) == nil)
    }

    @Test func minimumAgeAppliesPerItem() {
        #expect(check("Library/Logs/x", changed: 3 * 86_400, minimumAgeDays: 7) == "Changed in the last 7 days")
        #expect(check("Library/Logs/x", changed: 8 * 86_400, minimumAgeDays: 7) == nil)
        #expect(check("Library/Logs/x", changed: nil, minimumAgeDays: 7) == nil)
    }

    /// F-0065: MacTools made a cut-short size uncleanable. Here an incomplete size is only a lower bound.
    @Test func incompleteMeasurementIsNotASkipReason() {
        #expect(check("Library/Caches/huge", incomplete: true) == nil)
    }
}
