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
    }

    static var shots: [Shot] {
        SidebarItem.allCases.map { Shot(name: $0.rawValue, view: AnyView(RootView(model: .demo(selection: $0))), size: windowSize) }
        // The minimum window hides what the default size has room for (T-0056).
        + SidebarItem.allCases.map { Shot(name: "\($0.rawValue)-small", view: AnyView(RootView(model: .demo(selection: $0))), size: RootView.minimumSize) }
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
                try png(of: shot.view, dark: dark, size: shot.size).write(to: url)
                written.append(url)
            }
        }
        return written
    }

    public static func png(of view: some View, dark: Bool = false, size: CGSize? = windowSize) throws -> Data {
        runHeadless()
        let hosting = NSHostingView(rootView: AnyView(view))
        // Lets `.toolbar` and `.navigationTitle` reach the window, as they do in the real app.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let contentSize = size ?? hosting.fittingSize
        hosting.rootView = AnyView(view.frame(width: contentSize.width, height: contentSize.height).environment(\.controlActiveState, .key))

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: size == nil ? [.borderless] : [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Let SwiftUI finish its first passes: lists and split views fill in asynchronously.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let image = try windowImage(window) ?? cachedDisplay(window)
        return try pngData(image)
    }

    /// Keeps a rendering process out of the Dock and from ever taking focus from the user's work.
    public static func runHeadless() {
        NSApplication.shared.setActivationPolicy(.prohibited)
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
