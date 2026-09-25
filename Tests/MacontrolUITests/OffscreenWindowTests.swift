import AppKit
@testable import MacontrolUI
import Testing

/// Snapshot windows used to flash over the user's work: AppKit pulled each titled window back onto a display
/// when it was ordered front. They must stay outside every display.
@Suite struct OffscreenWindowTests {
    @Test(arguments: [NSWindow.StyleMask.titled, [.titled, .fullSizeContentView], .borderless])
    func windowStaysOutsideEveryDisplay(styleMask: NSWindow.StyleMask) {
        let window = SnapshotRenderer.offscreenWindow(size: SnapshotRenderer.windowSize, styleMask: styleMask)
        defer { window.orderOut(nil) }
        #expect(window.isVisible)
        for screen in NSScreen.screens {
            #expect(!window.frame.intersects(screen.frame), "window at \(window.frame) overlaps a display at \(screen.frame)")
        }
    }
}
