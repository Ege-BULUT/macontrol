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
        // An order-in or order-out animation never ends off screen and holds a dispatch thread for good: 32 windows
        // used up the pool and hung the whole test run.
        #expect(window.animationBehavior == .none)
        for screen in NSScreen.screens {
            #expect(!window.frame.intersects(screen.frame), "window at \(window.frame) overlaps a display at \(screen.frame)")
        }
    }

    /// Ordering a titled window in and out starts a transform animation that never ends off every display, and each
    /// one parked a dispatch thread: about 32 windows used up the pool of 64 and the full run hung (T-0073, T-0077).
    @Test func orderingAWindowInAndOutStartsNoAnimation() throws {
        let method = try #require(class_getInstanceMethod(NSAnimation.self, NSSelectorFromString("startAnimation")))
        let original = method_getImplementation(method)
        typealias Start = @convention(c) (AnyObject, Selector) -> Void
        let started = OSAllocatedUnfairLock(initialState: [String]())
        let counting: @convention(block) (AnyObject) -> Void = { animation in
            let name = String(describing: type(of: animation))
            started.withLock { $0.append(name) }
            unsafeBitCast(original, to: Start.self)(animation, NSSelectorFromString("startAnimation"))
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
        defer { method_setImplementation(method, original) }
        for styleMask in [NSWindow.StyleMask.titled, [.titled, .fullSizeContentView]] {
            // No run-loop turn while the counter is in: other tests' main-actor work would start animations too.
            SnapshotRenderer.offscreenWindow(size: CGSize(width: 240, height: 160), styleMask: styleMask).orderOut(nil)
        }
        #expect(started.withLock { $0 }.isEmpty, "animations started: \(started.withLock { $0 })")
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
