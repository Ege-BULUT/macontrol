import AppKit
@testable import MacontrolUI
import os
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

    /// Ordering a titled window in and out starts a transform animation that never ends off every display, and each
    /// one parked a dispatch thread: about 32 windows used up the pool of 64 and the full run hung (T-0073, T-0077).
    @Test func orderingManyWindowsLeavesDispatchThreadsFree() {
        for _ in 0..<48 {
            SnapshotRenderer.offscreenWindow(size: CGSize(width: 240, height: 160)).orderOut(nil)
        }
        let ran = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().async { ran.withLock { $0 = true } }
        // Wait on the main run loop, not with Task.sleep: a used-up pool would leave a sleep hanging instead of failing.
        let deadline = Date().addingTimeInterval(3)
        while !ran.withLock({ $0 }), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(ran.withLock { $0 }, "a global-queue block did not start: the dispatch threads are used up")
    }

    /// AppKit's event thread stops the main run loop for window-server events. Under `swift test` a stop that reached
    /// Swift's bare main loop ended the whole run with status 0 and no summary (T-0073). This stop arrives the way
    /// AppKit's does, as a block queued on the main run loop from another thread, while the test is suspended. Run
    /// alone (`--filter`), it ends the process without `SnapshotRenderer.runHeadless()`'s inner loop.
    @Test func aStopOfTheMainRunLoopDoesNotEndTheRun() async throws {
        SnapshotRenderer.runHeadless()
        // The main loop goes idle once, which starts the inner loop.
        try await Task.sleep(for: .milliseconds(50))
        let ran = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                ran.withLock { $0 = true }
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        for _ in 0..<200 where !ran.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ran.withLock { $0 }, "the stop never ran")
    }
}
