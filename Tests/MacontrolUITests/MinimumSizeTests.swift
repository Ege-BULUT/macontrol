import AppKit
import SwiftUI
@testable import MacontrolUI
import Testing

/// Every screen laid out at the window's minimum size (T-0056). A screen that needs more width than the window has
/// makes the split view wider than the window: it then hangs off both edges, clipping the sidebar and the buttons
/// at the far right. The PNGs of the same states are the `-small` shots in SnapshotRenderer.
@Suite struct MinimumSizeTests {
    @Test(arguments: SidebarItem.allCases)
    func screenFitsTheMinimumWindow(item: SidebarItem) throws {
        SnapshotRenderer.runHeadless()
        let size = RootView.minimumSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView(model: .demo(selection: item)).frame(width: size.width, height: size.height))
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        func splitViews(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
        }
        let splits = splitViews(in: try #require(window.contentView))
        let sidebar = try #require(splits.first?.arrangedSubviews.first, "no NavigationSplitView found")
        #expect(sidebar.frame.width >= 180, "the sidebar shrank to \(sidebar.frame.width) pt")
        for pane in splits.flatMap(\.arrangedSubviews) {
            let frame = pane.convert(pane.bounds, to: nil)
            #expect(frame.minX >= 0 && frame.maxX <= size.width, "a pane spans \(frame.minX)...\(frame.maxX) in a \(size.width) pt window")
        }
    }
}
