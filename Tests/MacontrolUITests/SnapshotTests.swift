import AppKit
import Foundation
import MacontrolUI
import Testing

@Suite struct SnapshotTests {
    @Test func everyScreenRendersToAPNG() throws {
        _ = NSApplication.shared
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        for item in SidebarItem.allCases {
            let data = try SnapshotRenderer.png(of: RootView(model: .demo(selection: item)))
            #expect(Array(data.prefix(4)) == pngSignature, "\(item)")
            #expect(data.count > 20_000, "\(item) rendered almost nothing")
        }
    }
}
