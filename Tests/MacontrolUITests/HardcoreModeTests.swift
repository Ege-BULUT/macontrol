import AppKit
import Foundation
@testable import MacontrolUI
import Safety
import SwiftUI
import Testing

/// The hardcore switch itself (DESIGN-debloat sections 1.1-1.3, T-0073 criteria 1-4 and 11): where the checkbox is,
/// the banner, the modal and its keys, the exact copy, and that nothing of it is ever stored.
@Suite struct HardcoreModeTests {
    static let sizes = [RootView.minimumSize, CGSize(width: 1600, height: 1000)]

    // MARK: Criterion 1: the checkbox and the banner

    /// The checkbox is the last toolbar item, not in the overflow, inside the window, on every screen at the minimum
    /// and a large size, light and dark. The banner's Turn Off control shows only while the mode is on.
    @Test(arguments: SidebarItem.allCases)
    func theCheckboxIsInsideTheWindowOnEveryScreen(item: SidebarItem) throws {
        for size in Self.sizes {
            for dark in [false, true] {
                let place = "\(item.rawValue) \(Int(size.width))x\(Int(size.height)) \(dark ? "dark" : "light")"
                let model = AppModel.demo(selection: item)
                let window = Self.window(RootView(model: model), size: size, dark: dark)
                defer { window.orderOut(nil) }

                let toolbar = try #require(window.toolbar, "no toolbar: \(place)")
                let toggle = try #require(toolbar.items.last)
                #expect(toggle.label == HardcoreText.label, "last toolbar item is \(toggle.label): \(place)")
                #expect(toolbar.visibleItems?.contains(toggle) == true, "the checkbox is in the overflow menu: \(place)")
                let view = try #require(toggle.view)
                let frame = view.convert(view.bounds, to: nil)
                #expect(frame.minX >= 0 && frame.maxX <= size.width, "the checkbox spans \(frame.minX)...\(frame.maxX): \(place)")
                // Box and label both shown: the label alone is about 100 pt.
                #expect(frame.width >= 110, "the checkbox is \(frame.width) pt wide: \(place)")
                #expect(Self.checkboxes(in: view).map(\.state) == [.off], "\(place)")
                #expect(Self.bannerControls(in: window).isEmpty, "a banner while off: \(place)")

                model.hardcore.isOn = true
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let on = try #require(window.toolbar?.items.last?.view)
                #expect(Self.checkboxes(in: on).map(\.state) == [.on], "\(place)")
                #expect(Self.bannerControls(in: window).count == 1, "no banner while on: \(place)")
            }
        }
    }

    /// Ticking only asks: the modal's flag goes up and the mode stays off. Unticking turns it off at once. The toolbar
    /// Toggle is bound to `checkbox` (SwiftUI's checkbox answers neither `performClick` nor synthetic mouse events in an
    /// inactive window, so the binding is set the way the Toggle sets it). The modal is not presented as a real sheet
    /// here: dismissing a real sheet in the test process ended the whole `swift test` run early, with exit status 0,
    /// in 4 of 8 full runs (M-0001, T-0073).
    @Test func tickingTheCheckboxAsksAndUntickingTurnsItOff() {
        let hardcore = HardcoreMode()
        hardcore.checkbox = true
        #expect(hardcore.isAsking && !hardcore.isOn && hardcore.mode == .trash)
        hardcore.isAsking = false
        #expect(!hardcore.isOn, "closing the modal turned it on")
        hardcore.checkbox = true
        hardcore.confirmTurnOn()
        #expect(hardcore.isOn && !hardcore.isAsking && hardcore.mode == .permanent)
        hardcore.checkbox = true
        #expect(!hardcore.isAsking, "ticking while on asked again")
        hardcore.checkbox = false
        #expect(!hardcore.isOn && !hardcore.isAsking && hardcore.mode == .trash)
    }

    // MARK: Criterion 4: the modal's keys

    /// Return and Esc both cancel the modal; neither turns the mode on. It has no checkbox of its own.
    @Test(arguments: [("\r", UInt16(36)), ("\u{1b}", UInt16(53))])
    func returnAndEscCancelTheModal(key: String, keyCode: UInt16) throws {
        let hardcore = HardcoreMode()
        hardcore.checkbox = true
        let window = AppListOrderTests.host(HardcoreModal(hardcore: hardcore), size: CGSize(width: 480, height: 420))
        defer { window.orderOut(nil) }
        #expect(hardcore.isAsking)
        let content = try #require(window.contentView)
        #expect(Self.checkboxes(in: content).isEmpty, "the modal has a checkbox")
        #expect(Self.press(key, keyCode: keyCode, in: window), "nothing took the key")
        #expect(!hardcore.isAsking, "the key did not cancel")
        #expect(!hardcore.isOn)
    }

    // MARK: Criterion 2: the copy, word for word

    @Test func tooltipModalBannerAndSheetCopyMatchTheDesign() throws {
        let design = try Self.design()
        var copy = [
            HardcoreText.helpOff, HardcoreText.helpOn, HardcoreText.valueOn, HardcoreText.valueOff, HardcoreText.banner,
            HardcoreText.modalTitle, HardcoreText.modalLead, HardcoreText.modalBackup, HardcoreText.modalConfirm,
            HardcoreText.menuTurnOff,
            PermanentText.strip, PermanentText.listHeader, PermanentText.trashOnlyHeader, PermanentText.confirm,
            PermanentText.restorePointLabel, PermanentText.restorePointNote, PermanentText.restorePointTooFull,
            PermanentText.restorePointSpace, PermanentText.snapshotNote, AdminText.badge,
            PermanentText.partlyDeleted("<name>"), PermanentText.restorePointFailed("<reason>"),
            AdminText.notes(count: 2, mode: .trash)[1],
            AdminText.notes(count: 2, mode: .trash)[0].replacingOccurrences(of: "2 items", with: "N items"),
            PermanentText.title(count: 2).replacingOccurrences(of: "2", with: "N"),
            PermanentText.summary(deleted: 2, of: 2).replacingOccurrences(of: "2", with: "N"),
            PermanentText.summary(deleted: 1, of: 2).replacingOccurrences(of: "1", with: "M").replacingOccurrences(of: "2", with: "N"),
            "They skip the Trash and can't be put back. Frees up to X.",
            "Freed X. These can't be put back.",
        ]
        copy += HardcoreText.modalBullets
        #expect(PermanentText.message(freesUpTo: 0).hasPrefix("They skip the Trash and can't be put back. Frees up to "))
        #expect(PermanentText.result(deletedAny: true, freed: 0, estimate: 0).hasPrefix("Freed "))
        #expect(HardcoreText.modalBullets.count == 3)
        for line in copy {
            #expect(design.contains(Self.normalized(line)), "not in DESIGN-debloat.md: \(line)")
        }
        // The prompt note never promises a single dialog (r2: ux 9); Trash mode adds Finder's note, permanent does not.
        #expect(AdminText.notes(count: 3, mode: .trash).count == 2 && AdminText.notes(count: 3, mode: .permanent).count == 1)
        #expect(!(AdminText.notes(count: 3, mode: .trash) + [AdminText.badgeHelp]).joined().localizedCaseInsensitiveContains("once"))
        #expect(AdminText.notes(count: 0, mode: .trash).isEmpty)
    }

    // MARK: Criterion 3: off at launch, never stored

    /// Every launch starts off, and nothing in the switch reads or writes stored state. `AppModel.live()` is read as
    /// source: calling it would run the launch-time privileged recovery against this Mac's real Application Support.
    @Test func itStartsOffAndIsNeverStored() throws {
        #expect(!HardcoreMode().isOn && HardcoreMode().mode == .trash)
        #expect(!AppModel.demo().hardcore.isOn)
        let shell = Self.sources.appendingPathComponent("Shell")
        let appModel = try String(contentsOf: shell.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        let live = try #require(appModel.components(separatedBy: "public static func live()").last?.components(separatedBy: "public static func demo").first)
        #expect(live.contains("let hardcore = HardcoreMode()\n"), "live() must build the switch with its default, off")
        #expect(live.contains("hardcore: hardcore") && live.contains("DebloatModel(uninstaller: uninstaller, hardcore: hardcore)"))
        for file in ["HardcoreMode.swift", "HardcoreViews.swift", "AppModel.swift"] {
            let source = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
            for storage in ["UserDefaults", "AppStorage", "SceneStorage", "NSUbiquitousKeyValueStore"] {
                #expect(!source.contains(storage), "\(file) mentions \(storage)")
            }
        }
    }

    /// Turning it on and off through the checkbox's binding, the modal and the banner's real Turn Off link writes
    /// nothing to UserDefaults.
    @Test func togglingWritesNothingToUserDefaults() throws {
        let model = AppModel.demo(selection: .history)
        let window = Self.window(RootView(model: model), size: RootView.minimumSize)
        defer { window.orderOut(nil) }
        // Read once the window is up: AppKit registers its own defaults (fonts, menus) when the first window draws.
        let before = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        model.hardcore.checkbox = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        model.hardcore.confirmTurnOn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try #require(Self.bannerControls(in: window).first).performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(!model.hardcore.isOn, "the banner's Turn Off did not turn it off")
        let after = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        #expect(after.isEqual(before), "UserDefaults changed: \(Set(after.allKeys.map { "\($0)" }).symmetricDifference(before.allKeys.map { "\($0)" }))")
    }

    // MARK: Criterion 11: the danger colour, measured from pixels

    /// `Theme.dangerText` on the banner reaches 4.5:1, measured from the rendered window: the banner's background and
    /// its darkest (light mode) or brightest (dark mode) text pixel, through the WCAG formula.
    @Test(arguments: [false, true])
    func dangerTextOnTheBannerReachesAA(dark: Bool) throws {
        let size = RootView.minimumSize
        let model = AppModel.demo(selection: .history)
        model.hardcore.isOn = true
        let window = Self.window(RootView(model: model), size: size, dark: dark)
        let control = try #require(Self.bannerControls(in: window).first)
        let band = control.convert(control.bounds, to: nil)
        let frameHeight = window.frame.height
        window.orderOut(nil)

        let png = try SnapshotRenderer.png(of: RootView(model: model), dark: dark, size: size)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        // The label sits at the banner's leading edge, on the row of the Turn Off control.
        var pixels: [NSColor] = []
        for y in stride(from: band.minY, through: band.maxY, by: 1) {
            for x in stride(from: 205, to: band.minX - 8, by: 0.5) {
                let color = bitmap.colorAt(x: Int(x * scale), y: Int((frameHeight - y) * scale))?.usingColorSpace(.sRGB)
                if let color { pixels.append(color) }
            }
        }
        let background = try #require(Self.mostCommon(pixels))
        let ratios = pixels.map { Self.contrast($0, background) }
        let best = try #require(ratios.max())
        #expect(best >= 4.5, "dangerText on the banner: \(best):1 (\(dark ? "dark" : "light"))")
        // The banner is red-tinted, not the plain window background.
        #expect(background.redComponent > background.blueComponent + 0.02, "banner background \(background)")
    }

    // MARK: Helpers

    static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacontrolUI")
    }

    /// DESIGN-debloat.md with line breaks, quote marks and list indents folded into single spaces.
    static func design() throws -> String {
        let url = sources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/DESIGN-debloat.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        return normalized(text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = Substring(line)
            while line.first == ">" || line.first == " " { line = line.dropFirst() }
            return String(line)
        }.joined(separator: " "))
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Hosts `view` like the real window: toolbar bridged into an NSToolbar, off screen, never activated.
    static func window(_ view: some View, size: CGSize, dark: Bool = false) -> NSWindow {
        SnapshotRenderer.runHeadless()
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return window
    }

    /// A key press offered the way AppKit offers it to buttons with a keyboard shortcut. Returns whether anything
    /// took it. Unlike `sendEvent`, a key nobody takes does not travel on to NSBeep, which the user would hear.
    @discardableResult
    static func press(_ key: String, keyCode: UInt16, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
        )!
        let handled = window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return handled
    }

    static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    /// SwiftUI's checkboxes are small square AppKit buttons; its link buttons are wide, and push buttons are not AppKit views.
    static func checkboxes(in view: NSView) -> [NSButton] {
        buttons(in: view).filter { abs($0.frame.width - $0.frame.height) < 1 && $0.frame.width <= 22 }
    }

    /// The banner's Turn Off link: the only AppKit-backed control in the band just under the toolbar, right of the sidebar.
    static func bannerControls(in window: NSWindow) -> [NSButton] {
        guard let content = window.contentView else { return [] }
        let top = content.bounds.height - (window.toolbar.map { _ in 52 } ?? 0)
        return buttons(in: content).filter {
            let frame = $0.convert($0.bounds, to: nil)
            return frame.minY >= top - 32 && frame.maxY <= top && frame.minX > 200
        }
    }

    static func mostCommon(_ colors: [NSColor]) -> NSColor? {
        let keyed = Dictionary(grouping: colors) { color in
            [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        return keyed.max { $0.value.count < $1.value.count }?.value.first
    }

    /// WCAG 2 contrast ratio of two sRGB colours.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            func channel(_ c: CGFloat) -> Double {
                let c = Double(c)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
