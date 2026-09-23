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

    /// Writes `<screen>-light.png` and `<screen>-dark.png` for every sidebar item. Returns the files written.
    @discardableResult
    public static func renderAll(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for item in SidebarItem.allCases {
            for dark in [false, true] {
                let url = directory.appendingPathComponent("\(item.rawValue)-\(dark ? "dark" : "light").png")
                try png(of: RootView(model: .demo(selection: item)), dark: dark).write(to: url)
                written.append(url)
            }
        }
        return written
    }

    public static func png(of view: some View, dark: Bool = false, size: CGSize = windowSize) throws -> Data {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Let SwiftUI finish its first passes: lists and split views fill in asynchronously.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let image = try windowImage(window) ?? cachedDisplay(window)
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
