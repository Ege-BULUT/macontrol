import Foundation
@testable import MacontrolUI
import Testing

/// Renders Debloat at the minimum window and a large one, light and dark: the first look (nothing ticked), Xcode
/// ticked in each mode, loading, empty, and the confirmation. Set MACONTROL_SNAPSHOT_DIR to keep the PNGs.
@Suite struct DebloatSnapshotTests {
    /// The minimum window (`RootView.minimumSize`) and a large one.
    nonisolated static let sizes = [CGSize(width: 900, height: 600), CGSize(width: 1600, height: 1000)]

    static func root(_ debloat: DebloatModel) -> RootView {
        RootView(model: AppModel(
            selection: .debloat, fullDiskAccess: .granted, volume: nil, diskMap: .demo(), clean: .demo(),
            uninstall: .demo(), history: .demo(), hardcore: debloat.hardcore, debloat: debloat
        ))
    }

    /// Xcode ticked with its runtimes, as a user would set it up in Trash mode.
    static func tickedXcode(hardcore: Bool) -> DebloatModel {
        let model = DebloatModel.demo(hardcore: HardcoreMode(isOn: hardcore))
        let xcode = model.row(DemoDebloat.xcode.url)!
        model.setTicked(true, xcode)
        if !hardcore { model.setRuntimesChosen(true, xcode) }
        return model
    }

    @Test(arguments: sizes)
    func firstLookRenders(size: CGSize) throws {
        try Snapshot.write(Self.root(.demo()), "debloat-first-\(Int(size.width))", size: size)
    }

    @Test(arguments: sizes)
    func tickedXcodeRendersInBothModes(size: CGSize) throws {
        try Snapshot.write(Self.root(Self.tickedXcode(hardcore: false)), "debloat-trash-\(Int(size.width))", size: size)
        try Snapshot.write(Self.root(Self.tickedXcode(hardcore: true)), "debloat-hardcore-\(Int(size.width))", size: size)
    }

    @Test(arguments: sizes)
    func loadingAndEmptyRender(size: CGSize) throws {
        try Snapshot.write(Self.root(.demo(hardcore: HardcoreMode(), loaded: false)), "debloat-loading-\(Int(size.width))", size: size)
        try Snapshot.write(Self.root(.demo(hardcore: HardcoreMode(), empty: true)), "debloat-empty-\(Int(size.width))", size: size)
    }

    @Test func confirmationRendersInBothModes() throws {
        for hardcore in [false, true] {
            let model = Self.tickedXcode(hardcore: hardcore)
            model.beginRemove()
            #expect(model.confirmation?.breaksDeveloperTools == true)
            try Self.writeSheet(DebloatSheet(model: model), "debloat-confirm-\(hardcore ? "hardcore" : "trash")")
        }
        // The Trash-mode default: runtimes unticked, and the sheet says they stay (review 2, 4).
        let model = DebloatModel.demo()
        model.setTicked(true, model.row(DemoDebloat.xcode.url)!)
        model.beginRemove()
        #expect(model.confirmation?.notes.contains { $0.hasPrefix("The simulator runtimes left unticked") } == true)
        try Self.writeSheet(DebloatSheet(model: model), "debloat-confirm-trash-default")
    }

    @Test func resultRenders() async throws {
        let model = Self.tickedXcode(hardcore: false)
        model.beginRemove()
        await model.confirm()
        #expect(model.confirmation?.report != nil)
        try Self.writeSheet(DebloatSheet(model: model), "debloat-result")
    }

    /// Sheets at their own size: the Copy line makes this one taller than `Snapshot.sheetSize`.
    static func writeSheet(_ sheet: DebloatSheet, _ name: String) throws {
        SnapshotRenderer.runHeadless()
        let folder = ProcessInfo.processInfo.environment["MACONTROL_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
        for dark in [false, true] {
            let data = try SnapshotRenderer.png(of: sheet, dark: dark, size: nil)
            #expect(data.count > 20_000, "\(name) rendered almost nothing")
            try folder.map { try data.write(to: $0.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) }
        }
    }
}
