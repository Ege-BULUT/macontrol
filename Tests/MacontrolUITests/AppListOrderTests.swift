import AppKit
import Foundation
@testable import MacontrolUI
import SwiftUI
import Testing
import TestSupport
import Uninstaller

@Suite struct AppListOrderTests {
    static let day: TimeInterval = 86_400

    static func app(_ name: String, _ id: String = "com.example.x", kind: AppKind = .thirdParty, folder: String = "/Applications",
                    added: TimeInterval? = nil) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: "\(folder)/\(name).app"), name: name, bundleIdentifier: id, version: nil, kind: kind,
            identity: nil, dateAdded: added.map { Date(timeIntervalSince1970: 1_700_000_000 + $0 * day) }
        )
    }

    static func names(_ sort: AppSort, _ apps: [InstalledApp], sizes: [String: UInt64] = [:]) -> [String] {
        sort.sorted(apps) { sizes[$0.name] }.map { "\($0.name)\($0.url.path.hasPrefix("/Users") ? "~" : "")" }
    }

    // MARK: Sort

    /// Finder's name order (numbers by value, case ignored); two copies of one app go by path, both directions.
    @Test func nameSortIsFindersOrderWithTwinsByPath() {
        let apps = [Self.app("Zed"), Self.app("app 10"), Self.app("Editor"), Self.app("Editor", folder: "/Users/me/Applications"), Self.app("App 9")]
        #expect(Self.names(.nameAscending, apps) == ["App 9", "app 10", "Editor", "Editor~", "Zed"])
        #expect(Self.names(.nameDescending, apps) == ["Zed", "Editor~", "Editor", "app 10", "App 9"])
    }

    /// Equal dates go by name; apps without a date go last in both directions, by name.
    @Test func dateSortBreaksTiesByNameAndPutsMissingDatesLast() {
        let apps = [Self.app("Undated B"), Self.app("Bravo", added: 5), Self.app("Undated A"), Self.app("Alpha", added: 5), Self.app("Old", added: 1),
                    Self.app("New", added: 9)]
        #expect(Self.names(.newestFirst, apps) == ["New", "Alpha", "Bravo", "Old", "Undated A", "Undated B"])
        #expect(Self.names(.oldestFirst, apps) == ["Old", "Alpha", "Bravo", "New", "Undated A", "Undated B"])
    }

    /// Unmeasured apps (no size yet) never lead "Smallest First": they go last, by name.
    @Test func sizeSortBreaksTiesByNameAndPutsUnmeasuredAppsLast() {
        let apps = ["Tiny", "Big", "Unmeasured", "Twin B", "Twin A", "Also Unmeasured"].map { Self.app($0) }
        let sizes: [String: UInt64] = ["Tiny": 10, "Big": 9_000, "Twin B": 500, "Twin A": 500]
        #expect(Self.names(.largestFirst, apps, sizes: sizes) == ["Big", "Twin A", "Twin B", "Tiny", "Also Unmeasured", "Unmeasured"])
        #expect(Self.names(.smallestFirst, apps, sizes: sizes) == ["Tiny", "Twin A", "Twin B", "Big", "Also Unmeasured", "Unmeasured"])
    }

    /// The order depends on the apps, never on the order they were listed in. Every rotation, forwards and
    /// backwards, so each pair of apps comes in both ways round, and a failure repeats.
    @Test(arguments: AppSort.allCases)
    func everySortGivesOneOrderForAnyInputOrder(sort: AppSort) {
        let apps = (0..<12).map { Self.app("App \($0 % 5)", folder: "/Volumes/V\($0)", added: $0 % 3 == 0 ? nil : Double($0 % 4)) }
        let sizes = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($0.element.url, UInt64($0.offset % 3) * 100) }.filter { $0.1 > 0 })
        let expected = sort.sorted(apps) { sizes[$0.url] }
        for shift in apps.indices {
            let rotated = Array(apps[shift...] + apps[..<shift])
            for input in [rotated, rotated.reversed()] {
                #expect(sort.sorted(input) { sizes[$0.url] }.map(\.url) == expected.map(\.url), "shift \(shift)")
            }
        }
    }

    // MARK: Filter

    /// System is Apple's: part of macOS, Apple's App Store apps, and any other com.apple.* app such as Xcode.
    @Test func systemIsApplesAppsAndUserIsEveryOtherApp() {
        let apps = [
            Self.app("Editor", "com.example.Editor"), Self.app("No ID", ""), Self.app("Xcode", "com.apple.dt.Xcode"),
            Self.app("Pages", "com.apple.iWork.Pages", kind: .appleAppStore), Self.app("Chess", "com.apple.Chess", kind: .builtIn),
            Self.app("Odd", "COM.APPLE.Odd"), Self.app("Lookalike", "com.applesauce.Lookalike"),
        ]
        #expect(apps.filter(AppFilter.system.includes).map(\.name) == ["Xcode", "Pages", "Chess", "Odd"])
        #expect(apps.filter(AppFilter.user.includes).map(\.name) == ["Editor", "No ID", "Lookalike"])
        #expect(apps.filter(AppFilter.all.includes).count == apps.count)
    }

    @Test func countsFollowTheSearch() {
        let model = UninstallModel.demo()
        #expect(AppFilter.allCases.map(model.count) == [9, 4, 5])
        model.query = "Editor"
        #expect(AppFilter.allCases.map(model.count) == [1, 1, 0])
        model.filter = .system
        #expect(model.sections.isEmpty)
    }

    @Test func sectionsKeepTheirKindAndSortWithin() {
        let model = UninstallModel.demo()
        model.sort = .largestFirst
        #expect(model.sections.map(\.kind) == [.thirdParty, .appleAppStore, .builtIn])
        #expect(model.sections[0].apps.map(\.name) == ["Pixel Studio", "Editor", "Podcast Maker", "Terminal Plus"])
        model.sort = .newestFirst
        model.filter = .system
        #expect(model.sections.flatMap(\.apps).map(\.name) == ["Pages", "GarageBand", "Chess", "Photo Booth", "Safari"])
        model.filter = .user
        #expect(model.sections.map(\.kind) == [.thirdParty])
    }

    /// Return must not uninstall an app the filter hides, as with the search.
    @Test func filteringAwayTheSelectedAppDeselectsIt() {
        let model = UninstallModel.demo()
        model.filter = .user
        #expect(model.selectedApp == DemoApps.editor.id && model.canUninstall)
        model.filter = .system
        #expect(model.selectedApp == nil && !model.canUninstall)
        model.beginUninstall()
        #expect(model.confirmation == nil)
    }

    /// Size order needs every app's size, not only the rows on screen.
    @Test func measureAllSizesEveryApp() async throws {
        let temp = try TemporaryDirectory()
        for name in ["One", "Two", "Three", "Four"] { try UninstallModelTests.bundle(temp, name, "com.example.macontrol-\(name)") }
        let model = UninstallModel(uninstaller: try UninstallModelTests.uninstaller(temp))
        await model.loadApps()
        await model.measureAll()
        #expect(model.apps.count == 4 && model.apps.allSatisfy { (model.sizes[$0.url] ?? 0) > 0 })
    }

    /// Row X and measureAll both want X's size while three big rows hold the three measure slots. The caller that
    /// claimed X first is cancelled: the row scrolled away, or the user left Size sort. The other must still measure X.
    @Test(.serialized, arguments: [(first: "row", cancel: true), (first: "all", cancel: true), (first: "row", cancel: false)])
    func aCancelledCallerDoesNotLeaveTheAppUnmeasured(first: String, cancel: Bool) async throws {
        let temp = try TemporaryDirectory()
        for name in ["A", "B", "C"] {
            try UninstallModelTests.bundle(temp, name, "com.example.macontrol-\(name)")
            for i in 0..<4000 { try temp.file("Applications/\(name).app/Contents/Resources/f\(i)", size: 10) }
        }
        for name in ["X", "Y"] { try UninstallModelTests.bundle(temp, name, "com.example.macontrol-\(name)") }
        let model = UninstallModel(uninstaller: try UninstallModelTests.uninstaller(temp))
        await model.loadApps()
        let byName = Dictionary(uniqueKeysWithValues: model.apps.map { ($0.name, $0) })
        let busy = ["A", "B", "C"].map { name in Task { await model.measureIfNeeded(byName[name]!) } }
        let start = { (caller: String) in caller == "row" ? Task { await model.measureIfNeeded(byName["X"]!) } : Task { await model.measureAll() } }
        let claimer = start(first)
        try await Task.sleep(for: .milliseconds(5))
        let waiter = start(first == "row" ? "all" : "row")
        try await Task.sleep(for: .milliseconds(5))
        if cancel { claimer.cancel() }
        for task in busy + [claimer, waiter] { await task.value }
        #expect(model.sizes[byName["X"]!.url] != nil)
    }

    // MARK: Screen

    /// The screen reads the stored choice, ⌥⌘1-3 and ⌃⌥⌘1-6 change it, and the change is stored for the next launch.
    /// Runs in a scratch defaults suite, headless.
    @Test func shortcutsChangeAndStoreTheChoice() throws {
        try Self.withScratchDefaults(["uninstallFilter": "system", "uninstallSort": "oldestFirst"]) { defaults in
            let model = UninstallModel.demo()
            let window = Self.host(UninstallScreen(model: model).defaultAppStorage(defaults))
            defer { window.orderOut(nil) }
            #expect(model.filter == .system && model.sort == .oldestFirst)

            Self.press("2", keyCode: 19, [.option, .command], in: window)
            #expect(model.filter == .user)
            #expect(defaults.string(forKey: "uninstallFilter") == "user")

            Self.press("5", keyCode: 23, [.control, .option, .command], in: window)
            #expect(model.sort == .largestFirst)
            #expect(defaults.string(forKey: "uninstallSort") == "largestFirst")

            Self.press("1", keyCode: 18, [.option, .command], in: window)
            #expect(model.filter == .all)
        }
    }

    /// A suite named by an absolute path keeps its plist in the temp folder, not in ~/Library/Preferences.
    static func withScratchDefaults(_ values: [String: String], _ body: (UserDefaults) throws -> Void) throws {
        let temp = try TemporaryDirectory()
        let defaults = try #require(UserDefaults(suiteName: temp.url.appendingPathComponent("defaults").path))
        for (key, value) in values { defaults.set(value, forKey: key) }
        try body(defaults)
    }

    static func host(_ view: some View, size: CGSize = SnapshotRenderer.windowSize) -> NSWindow {
        SnapshotRenderer.runHeadless()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return window
    }

    static func press(_ key: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
        )!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
