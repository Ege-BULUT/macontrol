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

/// Ordering a window in and out animates it on a GCD thread. Outside every display that animation never ended, so
/// each snapshot window kept a thread, and after 64 of them the whole test run stopped with no summary.
@Suite struct OffscreenWindowAnimationTests {
    @MainActor @Test func orderingManyWindowsLeavesGCDItsThreads() {
        for _ in 0..<80 {
            SnapshotRenderer.offscreenWindow(size: CGSize(width: 200, height: 100)).orderOut(nil)
        }
        // The animations start on the next turns of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let ran = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async { ran.signal() }
        #expect(ran.wait(timeout: .now() + 10) == .success, "GCD's threads are all taken by window animations")
    }
}
