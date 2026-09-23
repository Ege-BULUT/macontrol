import AppKit
import Foundation
@testable import MacontrolUI
import Testing

@Suite struct SnapshotTests {
    @Test func everyShotRendersToAPNG() throws {
        _ = NSApplication.shared
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let names = SnapshotRenderer.shots.map(\.name)
        #expect(Set(names).isSuperset(of: SidebarItem.allCases.map(\.rawValue) + ["onboarding", "overview-limited"]))
        for shot in SnapshotRenderer.shots {
            let data = try SnapshotRenderer.png(of: shot.view, size: shot.size)
            #expect(Array(data.prefix(4)) == pngSignature, "\(shot.name)")
            #expect(data.count > 20_000, "\(shot.name) rendered almost nothing")
        }
    }
}
