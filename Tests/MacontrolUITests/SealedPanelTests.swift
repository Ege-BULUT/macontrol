import AppKit
import MacontrolCore
@testable import MacontrolUI
import SwiftUI
import Testing
import Uninstaller

/// The locked panel and the expert guide sheet, read through the accessibility tree of a headless window
/// (DESIGN-debloat sections 5.2 and 5.3). Set MACONTROL_SNAPSHOT_DIR to keep the PNGs.
@Suite(.serialized) struct SealedPanelTests {
    static let chess = InstalledApp(
        url: URL(fileURLWithPath: "/System/Applications/Chess.app"), name: "Chess", bundleIdentifier: "com.apple.Chess",
        version: "3.18", kind: .builtIn, identity: nil
    )
    static let sipOn = SystemIntegrity(filesystemProtected: true, authenticatedRoot: true, rootIsSealedSnapshot: true, systemDevice: "/dev/disk3s3")
    static let sipOff = SystemIntegrity(filesystemProtected: false, authenticatedRoot: false, rootIsSealedSnapshot: true, systemDevice: "/dev/disk3s3")
    static let home = URL(fileURLWithPath: "/Users/you")
    static let chessSize: UInt64 = 10_800_000
    static let systemAppsSize: UInt64 = 726_777_856

    static func panel(_ integrity: SystemIntegrity = sipOn) -> SealedAppPanel {
        SealedAppPanel(app: chess, size: chessSize, systemAppsSize: systemAppsSize, integrity: integrity, home: home)
    }

    @Test(arguments: [false, true])
    func sipOnPanelCopyIsExactAndItsOnlyButtonIsTheGuide(hardcore: Bool) throws {
        let host = Host(Self.panel().environment(HardcoreMode(isOn: hardcore)), size: RootView.minimumSize)
        defer { host.close() }
        let texts = host.texts(role: .staticText)
        for line in [
            "Chess is part of macOS",
            "Locked by macOS",
            Self.chessSize.formattedBytes,
            "macOS keeps this app on a sealed, read-only system volume. No app can remove it while System Integrity Protection is on. All of macOS's own apps together use \(Self.systemAppsSize.formattedBytes), and macOS updates put them back.",
            "What you can do instead",
            "Remove it from the Dock: Control-click its Dock icon, then Options > Remove from Dock.",
        ] {
            #expect(texts.contains(line), "missing \(line) in \(texts)")
        }
        // No destructive button: the guide is the only control, in both modes (r2: ux 14).
        #expect(host.texts(role: .button) == ["Expert: remove system apps yourself…"])
        #expect(host.texts(role: .checkBox).isEmpty)
    }

    /// The panel's own sheet, hosted on its own: presenting it from the panel would put a sheet window on the user's
    /// screen. Hosting `guideSheet` keeps the panel's call site under test (review 2, item 5).
    @Test(arguments: [false, true])
    func theCommandsWaitForTheBox(off: Bool) throws {
        let integrity = off ? Self.sipOff : Self.sipOn
        let host = Host(Self.panel(integrity).guideSheet, size: Snapshot.sheetSize)
        defer { host.close() }
        let guide = SealedGuide(apps: [Self.chess.url], integrity: integrity, home: Self.home)
        #expect(guide.commands.count == (integrity.allowsSealedRemoval ? 9 : 7))

        #expect(host.texts(role: .staticText).contains("Strongly not recommended"))
        #expect(host.texts(role: .button) == ["Close"], "no command and no Copy button before the box is ticked")
        #expect(!host.allTexts.contains { text in guide.commands.contains { text.contains($0) } })

        #expect(host.press(role: .checkBox, SealedGuide.acknowledgement))
        // Each Copy button names its command for VoiceOver (review 2, nit 8).
        #expect(host.texts(role: .button) == guide.commands.map { "Copy \($0)" } + ["Close"])
        let shown = host.texts(role: .staticText)
        for command in guide.commands { #expect(shown.contains(command), "\(command) is not shown") }
        let verified = guide.steps.filter(\.verified).count
        #expect(shown.filter { $0 == "Unverified" }.count == guide.steps.count + guide.undo.count - verified)
        #expect(shown.filter { $0 == "Verified" }.count == verified)
    }

    /// DebloatScreen builds the panel with `SealedAppPanel(app:size:)`, so no total is passed (review R2).
    @Test func withoutTheTotalThePanelStillSaysUpdatesPutTheAppsBack() {
        let host = Host(SealedAppPanel(app: Self.chess, size: Self.chessSize, integrity: Self.sipOn, home: Self.home), size: RootView.minimumSize)
        defer { host.close() }
        #expect(host.texts(role: .staticText).contains(
            "macOS keeps this app on a sealed, read-only system volume. No app can remove it while System Integrity Protection is on. macOS updates put its own apps back."
        ))
        for integrity in [Self.sipOn, Self.sipOff, SystemIntegrity(filesystemProtected: false, authenticatedRoot: true)] {
            #expect(SealedAppPanel.explanation(integrity, systemAppsSize: nil).hasSuffix(" macOS updates put its own apps back."))
        }
    }

    /// Safari is Part of macOS (restricted) but lives in the App cryptex, not on the system volume (feasibility S3).
    /// Its guide has no steps, so it shows no undo either (review R3).
    @Test func safariIsNotCalledSealedAndItsGuideHasNothingToUndo() {
        let safari = InstalledApp(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari", bundleIdentifier: "com.apple.Safari",
                                  version: "26.0", kind: .builtIn, identity: nil)
        let panel = Host(SealedAppPanel(app: safari, size: 36_000_000, integrity: Self.sipOn, home: Self.home), size: RootView.minimumSize)
        defer { panel.close() }
        let texts = panel.texts(role: .staticText)
        #expect(texts.contains(
            "macOS protects this app, so macontrol can't remove it. It isn't in /System/Applications, so the expert guide doesn't cover it either. macOS updates put its own apps back."
        ), "\(texts)")
        #expect(!texts.contains { $0.contains("system volume.") })
        #expect(panel.texts(role: .button) == ["Expert: remove system apps yourself…"])

        let sheet = Host(SealedGuideSheet(apps: [safari], integrity: Self.sipOn, home: Self.home, acknowledged: true), size: Snapshot.sheetSize)
        defer { sheet.close() }
        let shown = sheet.texts(role: .staticText)
        #expect(shown.contains("None of the chosen apps can be removed this way."))
        #expect(!shown.contains("To undo") && !shown.contains("Steps"), "\(shown)")
        #expect(sheet.texts(role: .button) == ["Close"])
    }

    @Test func sipOffShowsTheStateAndSkipsRecovery() throws {
        let panel = Host(Self.panel(Self.sipOff), size: RootView.minimumSize)
        defer { panel.close() }
        #expect(panel.texts(role: .staticText).contains(
            "macOS keeps this app on a sealed system volume. System Integrity Protection and Authenticated Root are off on this Mac, but macontrol doesn't remove system apps until that has been tested on macOS 14, 15 and 26. All of macOS's own apps together use \(Self.systemAppsSize.formattedBytes), and macOS updates put them back."
        ))
        #expect(panel.texts(role: .button) == ["Expert: remove system apps yourself…"])

        let sheet = Host(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOff, home: Self.home, acknowledged: true), size: Snapshot.sheetSize)
        defer { sheet.close() }
        let texts = sheet.texts(role: .staticText)
        #expect(texts.contains("\(SealedGuide.protectionsOff) \(SealedGuide.waitsForVerification)"))
        #expect(!texts.contains("csrutil disable") && !texts.contains { $0.contains("Recovery") && $0.hasPrefix("1.") })
        #expect(texts.contains("1. Check that FileVault is off") && texts.contains("fdesetup status"))
        #expect(texts.contains("2. Mount the system volume"))
        #expect(texts.filter { $0 == "Verified" }.count == 1)
    }

    @Test func theRisksShowBeforeTheBox() {
        let host = Host(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOn, home: Self.home), size: Snapshot.sheetSize)
        defer { host.close() }
        let texts = host.texts(role: .staticText)
        for risk in SealedGuide.risks {
            #expect(texts.contains(risk.replacingOccurrences(of: "**", with: "")), "\(risk)")
        }
    }

    @Test func snapshots() throws {
        for (name, size) in [("900x600", RootView.minimumSize), ("large", SnapshotRenderer.windowSize)] {
            try Self.write(Self.panel(), "sealed-panel-\(name)", size: size)
            try Self.write(Self.panel(Self.sipOff), "sealed-panel-sip-off-\(name)", size: size)
            try Self.write(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOn, home: Self.home), "sealed-guide-\(name)", size: size)
            try Self.write(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOn, home: Self.home, acknowledged: true), "sealed-guide-steps-\(name)", size: size)
            try Self.write(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOff, home: Self.home, acknowledged: true), "sealed-guide-sip-off-\(name)", size: size)
        }
        // What the sheet really is in the app, and the panel in a narrow detail column.
        try Self.write(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOn, home: Self.home), "sealed-guide-sheet", size: Snapshot.sheetSize)
        try Self.write(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOn, home: Self.home, acknowledged: true), "sealed-guide-steps-sheet", size: Snapshot.sheetSize)
        try Self.write(Self.panel(), "sealed-panel-narrow", size: CGSize(width: 440, height: 600))
        // Every step at once, for review: the sheet scrolls in the app.
        try Self.write(SealedGuideSheet(apps: [Self.chess], integrity: Self.sipOn, home: Self.home, acknowledged: true), "sealed-guide-steps-all", size: CGSize(width: 640, height: 2000))
    }

    /// Like `Snapshot.write`, but in a borderless window: AppKit moves a titled window from -20000 back onto the
    /// screen when it is ordered in, a borderless one stays off screen. Keeps the PNGs when MACONTROL_SNAPSHOT_DIR is set.
    static func write(_ view: some View, _ name: String, size: CGSize) throws {
        let folder = ProcessInfo.processInfo.environment["MACONTROL_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
        for dark in [false, true] {
            let data = try SnapshotRenderer.png(of: view.frame(width: size.width, height: size.height), dark: dark, size: nil)
            let image = try #require(NSBitmapImageRep(data: data))
            #expect(image.pixelsWide >= Int(size.width) && image.pixelsHigh >= Int(size.height), "\(name) is \(image.pixelsWide)x\(image.pixelsHigh)")
            #expect(data.count > 20_000, "\(name) rendered almost nothing")
            if let folder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

/// AppKit moves a titled window that is ordered in off screen back onto the screen; this one stays where it is put.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A view in an off-screen window, read and driven through its accessibility tree.
@MainActor
private final class Host {
    let window: NSWindow

    init(_ view: some View, size: CGSize) {
        SnapshotRenderer.runHeadless()
        Self.accessibilityClient(true)
        window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        #expect(window.frame.minX < -10_000, "the test window is on the screen")
        Self.settle()
    }

    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    func close() {
        window.orderOut(nil)
        Self.accessibilityClient(false)
    }

    /// SwiftUI builds its accessibility elements only while an assistive client has asked for them, which it does by
    /// setting this attribute on the app. Only this test process changes; nothing outside it is touched.
    static func accessibilityClient(_ on: Bool) {
        _ = NSApplication.shared.perform(Selector(("accessibilitySetEnhancedUserInterfaceAttribute:")), with: NSNumber(value: on))
    }

    private struct Node {
        let role: String?
        let texts: [String]
        let element: NSObject
    }

    /// Read by selector: the AppKit protocol's optional members don't resolve from Swift on SwiftUI's element class.
    private static func attribute(_ name: String, of element: NSObject) -> Any? {
        element.responds(to: Selector(name)) ? element.value(forKey: name) : nil
    }

    private var nodes: [Node] {
        func walk(_ element: NSObject, depth: Int) -> [Node] {
            guard depth < 80 else { return [] }
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                .compactMap { Self.attribute($0, of: element) as? String }.filter { !$0.isEmpty }
            let role = Self.attribute("accessibilityRole", of: element) as? String
            let children = (Self.attribute("accessibilityChildren", of: element) as? [Any])?.compactMap { $0 as? NSObject } ?? []
            return [Node(role: role, texts: texts, element: element)] + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(window.contentView!, depth: 0)
    }

    /// The first text of every element with `role`, in tree order.
    func texts(role: NSAccessibility.Role) -> [String] {
        nodes.filter { $0.role == role.rawValue }.compactMap(\.texts.first)
    }

    var allTexts: [String] { nodes.flatMap(\.texts) }

    /// Presses the first element with `role` and `text`, then lets SwiftUI update.
    func press(role: NSAccessibility.Role, _ text: String) -> Bool {
        guard let node = nodes.first(where: { $0.role == role.rawValue && $0.texts.contains(text) }) else { return false }
        let pressed = node.element.responds(to: Selector("accessibilityPerformPress"))
            && node.element.perform(Selector("accessibilityPerformPress")) != nil
        Self.settle()
        return pressed
    }
}
