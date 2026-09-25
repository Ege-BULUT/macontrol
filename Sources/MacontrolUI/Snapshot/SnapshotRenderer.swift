import AppKit
import SwiftUI

/// Renders every screen with demo data to PNG files, so the UI can be checked without screen recording.
///
/// `ImageRenderer` cannot draw AppKit-backed views (NavigationSplitView, List) and `cacheDisplay`
/// skips SwiftUI scroll content and glass. So the screen is shown in an off-screen window and the
/// window server's copy of that window is read back. Reading your own window needs no Screen
/// Recording permission.
public enum SnapshotRenderer {
    public static let windowSize = CGSize(width: 1180, height: 760)

    /// A named screen state. `size` nil means the view's own fitting size (sheets).
    struct Shot {
        var name: String
        var view: AnyView
        var size: CGSize?
        /// Drawn once this holds: the Disk Map computes its layout off the main actor, and under load it is not
        /// there after the first half second, so the shot showed the spinner.
        var isReady: () -> Bool = { true }
    }

    static func screen(_ item: SidebarItem, suffix: String = "", size: CGSize) -> Shot {
        let model = AppModel.demo(selection: item)
        return Shot(name: item.rawValue + suffix, view: AnyView(RootView(model: model)), size: size,
                    isReady: { item != .diskMap || model.diskMap.layout != nil })
    }

    static var shots: [Shot] {
        SidebarItem.allCases.map { screen($0, size: windowSize) }
        // The minimum window hides what the default size has room for (T-0056).
        + SidebarItem.allCases.map { screen($0, suffix: "-small", size: RootView.minimumSize) }
        + [
            Shot(name: "overview-limited", view: AnyView(RootView(model: .demo(fullDiskAccess: .denied))), size: windowSize),
            Shot(name: "onboarding", view: AnyView(OnboardingSheet(access: .demo())), size: nil),
            Shot(name: "onboarding-relaunch", view: AnyView(OnboardingSheet(access: .demo(returnedFromSettings: true))), size: nil),
        ]
    }

    /// Writes `<shot>-light.png` and `<shot>-dark.png` for every shot. Returns the files written.
    @discardableResult
    public static func renderAll(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for shot in shots {
            for dark in [false, true] {
                let url = directory.appendingPathComponent("\(shot.name)-\(dark ? "dark" : "light").png")
                try png(of: shot.view, dark: dark, size: shot.size, isReady: shot.isReady).write(to: url)
                written.append(url)
            }
        }
        return written
    }

    public static func png(of view: some View, dark: Bool = false, size: CGSize? = windowSize, isReady: () -> Bool = { true }) throws -> Data {
        runHeadless()
        let hosting = NSHostingView(rootView: AnyView(view))
        // Lets `.toolbar` and `.navigationTitle` reach the window, as they do in the real app.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let contentSize = size ?? hosting.fittingSize
        hosting.rootView = AnyView(view.frame(width: contentSize.width, height: contentSize.height).environment(\.controlActiveState, .key))

        let window = offscreenWindow(size: contentSize, styleMask: size == nil ? [.borderless] : [.titled, .fullSizeContentView])
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.orderOut(nil) }
        // Let SwiftUI finish its first passes: lists and split views fill in asynchronously.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let deadline = Date().addingTimeInterval(10)
        while !isReady() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // A last pass, so the view draws what just became ready.
        if isReady() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        let image = try windowImage(window) ?? cachedDisplay(window)
        return try pngData(image)
    }

    /// Keeps a rendering process out of the Dock and from ever taking focus from the user's work.
    public static func runHeadless() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        keepMainLoopRunning
    }

    /// `swift test` drives the main thread with a bare `CFRunLoopRun()` (Swift's async-main drain) and calls `exit(0)`
    /// when it returns. Once AppKit has windows, its event thread stops the main run loop for each window-server event,
    /// to wake NSApplication's event loop. A stop that reached that bare loop ended the run midway with status 0 and no
    /// summary (T-0073, traced to HIToolbox `PushToCGEventQueue`). So the bare loop's first idle moment starts an inner
    /// loop that simply runs again after each stop; the jobs and the tests' own waits run inside it. The app and
    /// `--snapshot` have a synchronous main: their outermost loop starts after this, so it is never depth 0 here.
    private static let keepMainLoopRunning: Void = {
        // Loops entered after this point, such as a test's `RunLoop.main.run(until:)`. Depth 0 is a loop that was
        // already running: the bare one, between jobs.
        var depth = 0
        let activities: CFRunLoopActivity = [.entry, .exit, .beforeTimers, .beforeWaiting, .afterWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, .max) { observer, activity in
            switch activity {
            case .entry: depth += 1
            case .exit: depth -= 1
            default:
                guard depth == 0 else { return }
                CFRunLoopObserverInvalidate(observer)
                // A synchronous stack here, unlike in the async caller: take over only from Swift's async-main drain.
                guard Thread.callStackSymbols.contains(where: { $0.contains("swift_task_asyncMainDrainQueue") }) else { return }
                while CFRunLoopRunInMode(.defaultMode, 1e10, false) != .finished {}
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }()

    /// A window ordered in far off screen, so rendering never shows up over the user's work. Add the content view
    /// after this call; the window is on screen for the window server but outside every display.
    public static func offscreenWindow(size: CGSize, styleMask: NSWindow.StyleMask = [.titled]) -> NSWindow {
        runHeadless()
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: false)
        // Ordering in and out starts a transform animation that never ends off every display, and each one holds a
        // dispatch thread: after 32 windows the pool of 64 is gone and the test run hangs.
        window.animationBehavior = .none
        window.setFrameOrigin(OffscreenWindow.origin)
        window.orderFrontRegardless()
        return window
    }

    /// The app icon as an `.iconset` folder for `iconutil` (scripts/bundle-app.sh).
    public static func renderIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(points * scale)
                // macOS icon grid: the tile is 824 of 1024, centered, so it lines up with other apps in the Dock.
                let icon = AppIconView()
                    .padding(pixels * 100 / 1024)
                    .shadow(color: .black.opacity(0.25), radius: pixels * 10 / 1024, y: pixels * 6 / 1024)
                    .frame(width: pixels, height: pixels)
                guard let image = ImageRenderer(content: icon).cgImage else { throw CocoaError(.fileWriteUnknown) }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try pngData(image).write(to: directory.appendingPathComponent(name))
            }
        }
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// CGWindowListCreateImage is marked obsoleted in the SDK, so Swift cannot call it by name,
    /// but it is still exported and is the only permission-free way to read our own window.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingAtBestResolution: UInt32 = 1 | 1 << 3
        return createImage(.null, includingWindow, UInt32(window.windowNumber), ignoreFramingAtBestResolution)?.takeRetainedValue()
    }

    /// Fallback that misses glass and scroll content, used only if the window server copy is unavailable.
    private static func cachedDisplay(_ window: NSWindow) throws -> CGImage {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}

extension AccessModel {
    /// Onboarding with Full Disk Access off. Opens nothing: the URL opener is a no-op.
    static func demo(returnedFromSettings: Bool = false) -> AccessModel {
        let access = AccessModel(status: .denied, probe: { .denied }, openURL: { _ in false })
        if returnedFromSettings {
            access.openSettings()
            access.appDidBecomeActive()
        }
        return access
    }
}

/// AppKit moves a titled window back onto a display when it is ordered front, which put every snapshot window
/// in front of the user for a moment. Keeping the requested frame keeps it off screen.
final class OffscreenWindow: NSWindow {
    static let origin = CGPoint(x: -20_000, y: -20_000)

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
