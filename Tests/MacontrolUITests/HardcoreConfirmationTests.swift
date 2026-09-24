import AppKit
import Cleaner
import Foundation
import MacontrolCore
@testable import MacontrolUI
import os
import Safety
import ScanEngine
import SwiftUI
import Testing
import TestSupport
import Uninstaller

/// Every confirmation in both modes (DESIGN-debloat sections 1.4, 1.6 and 2.6; T-0073 criteria 4-7, 9 and 10).
/// Removals run against a fixture: a home, a Trash folder and a journal inside one temporary folder, and the Trash
/// backend really moves there, so the tests read what happened from the disk.
@Suite struct HardcoreConfirmationTests {
    nonisolated static let modes: [DeletionMode] = [.trash, .permanent]

    // MARK: Criterion 5: a confirmation keeps the mode it opened with

    @Test(arguments: modes)
    func cleanKeepsTheModeItOpenedWith(opened: DeletionMode) async throws {
        let fixture = try RemovalFixture()
        let model = try await fixture.cleanModel()
        model.hardcore.isOn = opened == .permanent
        model.beginReview()
        model.hardcore.isOn = opened != .permanent
        #expect(model.review?.run.mode == opened)
        await model.confirmReview()
        try fixture.expectRemoved(in: opened, report: try #require(model.review?.report), paths: ["home/Library/Caches/com.example.a"])
    }

    @Test(arguments: modes)
    func uninstallKeepsTheModeItOpenedWith(opened: DeletionMode) async throws {
        let fixture = try RemovalFixture()
        let (model, _) = try await fixture.uninstallModel()
        model.hardcore.isOn = opened == .permanent
        model.beginUninstall()
        model.hardcore.isOn = opened != .permanent
        #expect(model.confirmation?.run.mode == opened)
        await model.confirmUninstall()
        let modes = fixture.modes.withLock { $0 }
        #expect(!modes.isEmpty && Set(modes) == [opened], "the uninstaller was asked for \(modes)")
        try fixture.expectRemoved(in: opened, report: try #require(model.confirmation?.report), paths: ["Applications/Probe.app"])
    }

    @Test(arguments: modes)
    func diskMapKeepsTheModeItOpenedWith(opened: DeletionMode) async throws {
        let fixture = try RemovalFixture()
        let model = try await fixture.diskMapModel()
        model.hardcore.isOn = opened == .permanent
        model.beginReview()
        model.hardcore.isOn = opened != .permanent
        #expect(model.review?.run.mode == opened)
        await model.confirmReview()
        guard case .done(let outcomes) = model.review?.phase else { Issue.record("the review did not finish"); return }
        #expect(outcomes.allSatisfy { opened == .trash ? $0.status == .inTrash : $0.status != .inTrash })
        #expect(fixture.inTrash == (opened == .trash ? ["blob.bin"] : []), "fixture Trash: \(fixture.inTrash)")
    }

    // MARK: Criterion 4: Return never confirms, Esc cancels, in every sheet and both modes

    @Test(arguments: modes)
    func returnInTheCleanSheetRemovesNothing(mode: DeletionMode) async throws {
        let fixture = try RemovalFixture()
        let model = try await fixture.cleanModel()
        model.hardcore.isOn = mode == .permanent
        model.beginReview()
        let review = try #require(model.review)
        let window = AppListOrderTests.host(CleanReviewSheet(model: model, review: review), size: Snapshot.sheetSize)
        defer { window.orderOut(nil) }
        try await fixture.pressReturnThenEsc(in: window) { model.review?.report == nil && model.review?.isWorking == false }
        #expect(model.review == nil, "Esc did not close the sheet")
        try fixture.expectUntouched(["home/Library/Caches/com.example.a/blob"])
    }

    @Test(arguments: modes)
    func returnInTheUninstallSheetRemovesNothing(mode: DeletionMode) async throws {
        let fixture = try RemovalFixture()
        let (model, _) = try await fixture.uninstallModel()
        model.hardcore.isOn = mode == .permanent
        model.beginUninstall()
        let window = AppListOrderTests.host(UninstallSheet(model: model), size: Snapshot.sheetSize)
        defer { window.orderOut(nil) }
        try await fixture.pressReturnThenEsc(in: window) { model.confirmation?.report == nil && model.confirmation?.isWorking == false }
        #expect(model.confirmation == nil, "Esc did not close the sheet")
        #expect(fixture.modes.withLock { $0 }.isEmpty, "the uninstaller ran")
        try fixture.expectUntouched(["Applications/Probe.app/Contents/Info.plist", "home/Library/Caches/com.example.macontrol-probe/data"])
    }

    @Test(arguments: modes)
    func returnInTheDiskMapReviewRemovesNothing(mode: DeletionMode) async throws {
        let fixture = try RemovalFixture()
        let model = try await fixture.diskMapModel()
        model.hardcore.isOn = mode == .permanent
        model.beginReview()
        let review = try #require(model.review)
        let window = AppListOrderTests.host(ReviewSheet(model: model, review: review), size: CGSize(width: 560, height: 620))
        defer { window.orderOut(nil) }
        try await fixture.pressReturnThenEsc(in: window) { model.review?.phase == .confirm }
        #expect(model.review == nil, "Esc did not close the sheet")
        try fixture.expectUntouched(["home/Documents/blob.bin"])
    }

    /// After a failed restore point, Cancel is the default: Return cancels and never deletes (section 2.6).
    @Test func returnAfterAFailedRestorePointCancels() throws {
        var run = RemovalRun(mode: .permanent)
        run.restorePointProblem = "No space"
        var closed = false, deleted = false
        let sheet = TrashSheet(
            title: "t", message: "m", rows: [TrashSheetRow(url: URL(fileURLWithPath: "/nonexistent-macontrol-fixture/a"), bytes: 1)],
            confirmTitle: PermanentText.confirm, report: nil, isWorking: false, mode: .permanent, restorePoint: .constant(true), run: run,
            onGoOnWithoutRestorePoint: { deleted = true }, onConfirm: { deleted = true }, onClose: { closed = true }
        )
        let window = AppListOrderTests.host(sheet, size: Snapshot.sheetSize)
        defer { window.orderOut(nil) }
        AppListOrderTests.press("\r", keyCode: 36, [], in: window)
        #expect(closed && !deleted)
    }

    // MARK: Criterion 6: the red strip, and trash-only items apart and out of "Frees up to X"

    @Test func trashOnlyPlacesAndTheirReasons() {
        let home = URL(fileURLWithPath: "/Users/demo")
        let cases: [(String, String?)] = [
            ("Library/Group Containers/group.com.apple.notes", "holds your notes"),
            ("Library/Containers/com.apple.Notes/Data", "holds your notes"),
            ("Library/Application Support/AddressBook", "holds your contacts"),
            ("Library/Calendars/Calendar Cache", "holds your calendars"),
            ("Library/Safari", "holds your Safari data"),
            ("Library/Application Support/MobileSync/Backup/0000-1111", "holds iPhone and iPad backups"),
            ("Library/Mobile Documents/com~apple~CloudDocs/Report.pdf", "stored in iCloud"),
            ("Library/CloudStorage/Dropbox/Photos", "stored in a cloud folder"),
            // A folder that holds one of them goes to the Trash too.
            ("Library/Application Support/MobileSync", "holds iPhone and iPad backups"),
            ("Library/Caches/com.apple.Safari", nil),
            ("Library/SafariSafeBrowsing", nil),
        ]
        for (path, reason) in cases {
            #expect(TrashOnly.reason(for: home.appendingPathComponent(path), home: home) == reason, "\(path)")
        }
    }

    @Test func permanentSheetsShowTheStripAndListTrashOnlyItemsApart() {
        let notes = URL(fileURLWithPath: "/Users/demo/Library/Group Containers/group.com.apple.notes")
        let cache = URL(fileURLWithPath: "/Users/demo/Library/Caches/com.example.Editor")
        let rows = [TrashSheetRow(url: cache, bytes: 3_000), TrashSheetRow(url: notes, bytes: 7_000)]
        let run = RemovalRun(mode: .permanent, urls: rows.map(\.url), support: .demo)
        #expect(run.trashOnly == [notes: "holds your notes"])
        #expect(run.bytes(of: rows) == 3_000, "a trash-only item counted in Frees up to X")

        func sheet(_ mode: DeletionMode, _ run: RemovalRun, report: TrashReport? = nil) -> TrashSheet {
            TrashSheet(
                title: "t", message: mode == .permanent ? PermanentText.message(freesUpTo: run.bytes(of: rows)) : "m", rows: rows,
                confirmTitle: "c", report: report, isWorking: false, mode: mode, run: run, onConfirm: {}, onClose: {}
            )
        }
        let permanent = sheet(.permanent, run)
        #expect(permanent.showsStrip)
        #expect(permanent.sections.map(\.title) == [PermanentText.listHeader, PermanentText.trashOnlyHeader])
        #expect(permanent.sections.map { $0.rows.map(\.url) } == [[cache], [notes]])
        #expect(permanent.explanation == PermanentText.message(freesUpTo: 3_000))

        let trash = sheet(.trash, RemovalRun(mode: .trash, urls: rows.map(\.url), support: .demo))
        #expect(!trash.showsStrip && trash.sections.count == 1 && trash.sections[0].title == nil)
        // The result replaces the strip: the sheet no longer asks anything.
        #expect(!sheet(.permanent, run, report: TrashReport(batch: UUID(), outcomes: [])).showsStrip)
    }

    /// The footer's "frees up to X" leaves out what still goes to the Trash.
    @Test func cleanEstimateLeavesOutTrashOnlyItemsInHardcoreMode() async {
        let rule = CleanModelTests.rule(.safe)
        let items = [
            CleanModelTests.item(rule, "/Users/demo/Library/Caches/com.example.Big"),
            CleanModelTests.item(rule, "/Users/demo/Library/Safari/History.db"),
        ]
        let model = CleanModel(cleaner: nil, trash: nil, engine: nil, items: items)
        model.support = .demo
        model.selection = Set(items.map(\.url))
        await model.refreshEstimate()
        let all = items.reduce(0) { $0 + $1.measurement.allocated }
        #expect(model.estimate == .freesNow(ReclaimEstimate(freesNow: all, sharedElsewhere: 0)))
        model.hardcore.isOn = true
        #expect(model.estimateKey?.mode == .permanent, "the estimate would not be redone for the new mode")
        await model.refreshEstimate()
        #expect(model.estimate == .freesNow(ReclaimEstimate(freesNow: items[0].measurement.allocated, sharedElsewhere: 0)))
    }

    // MARK: Criterion 7: the result is measured

    /// The fake removal frees space as it runs, so a reading taken on the wrong side of it shows.
    @Test func freeSpaceIsReadRightBeforeAndAfterAPermanentBatchOnly() async {
        let free = OSAllocatedUnfairLock(initialState: UInt64(10_000))
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var support = RemovalSupport()
        support.available = { _ in reads.withLock { $0 += 1 }; return free.withLock { $0 } }
        let empty = TrashReport(batch: UUID(), outcomes: [])
        let (_, freed) = await support.measuring(.permanent, []) { free.withLock { $0 += 50_000 }; return empty }
        #expect(freed == 50_000)
        reads.withLock { $0 = 0 }
        let (_, none) = await support.measuring(.trash, []) { free.withLock { $0 += 1 }; return empty }
        #expect(none == nil && reads.withLock { $0 } == 0, "a Trash batch read free space")
        // Space that went down (another app wrote meanwhile) is reported as nothing freed, not a wrapped number.
        #expect(await support.measuring(.permanent, []) { free.withLock { $0 -= 100 }; return empty }.freed == 0)
    }

    /// The uninstall result reports the injected change of free space, with the snapshot line only below half.
    @Test(arguments: [(UInt64(100_000), false), (UInt64(1_000), true)])
    func theResultReportsTheMeasuredChange(freed: UInt64, snapshotLine: Bool) async throws {
        let fixture = try RemovalFixture()
        // Deletes for real inside the fixture, as the engine would, and the volume gains `freed` with the bundle.
        let free = OSAllocatedUnfairLock(initialState: UInt64(5_000_000))
        let (model, _) = try await fixture.uninstallModel(outcome: { item in
            try? FileManager.default.removeItem(at: item.url)
            if item.url.pathExtension == "app" { free.withLock { $0 += freed } }
            return .deleted(original: item.url)
        })
        model.support.available = { _ in free.withLock { $0 } }
        model.hardcore.isOn = true
        model.beginUninstall()
        await model.confirmUninstall()
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.run.freed == freed)
        let sheet = TrashSheet(
            title: "t", message: "m", rows: confirmation.rows, confirmTitle: "c", report: confirmation.report, isWorking: false,
            mode: .permanent, run: confirmation.run, onConfirm: {}, onClose: {}
        )
        #expect(sheet.heading == PermanentText.summary(deleted: confirmation.rows.count, of: confirmation.rows.count))
        #expect(sheet.explanation.hasPrefix("Freed \(freed.formattedBytes). These can't be put back."))
        #expect(sheet.explanation.contains(PermanentText.snapshotNote) == snapshotLine, "\(sheet.explanation)")
    }

    @Test func aPartlyDeletedItemSaysWhereTheRestIs() {
        let url = URL(fileURLWithPath: "/Users/demo/Library/Caches/com.example.Big")
        let outcome = TrashOutcome.failed(url, message: "Partly deleted. 3 items inside could not be removed; the rest is in the Trash as "
            + "\"com.example.Big 2\". Empty the Trash to finish. First: a/b: Operation not permitted")
        #expect(outcome.isPartlyDeleted && !outcome.isRemoved)
        #expect(outcome.words(in: .permanent) == "Partly deleted. The rest is in the Trash as \"com.example.Big 2\"; empty the Trash to finish.")
        // Without Safety's name, the item's own name.
        #expect(TrashOutcome.failed(url, message: "Partly deleted.").words(in: .permanent) == PermanentText.partlyDeleted("com.example.Big"))
        #expect(TrashOutcome.failed(url, message: "Busy").words(in: .trash) == "Could not move it: Busy")
    }

    /// A deleted item leaves the map like a trashed one, but is not "In Trash".
    @Test func diskMapSplicesDeletedItemsOffTheMap() {
        var builder = DiskMapFixtures.Builder()
        let file = builder.file(ScanTree.root, "a.bin", 4_000)
        builder.file(ScanTree.root, "b.bin", 1_000)
        let model = DiskMapFixtures.model(builder.finished())
        model.stage(file)
        let url = model.pile.items[0].url
        let outcomes = model.apply(TrashReport(batch: UUID(), outcomes: [.deleted(original: url)]), mode: .permanent)
        #expect(outcomes.map(\.status) == [.deleted])
        #expect(model.tree?.isRemoved(file) == true && model.tree?.allocatedSize(of: ScanTree.root) == 1_000)
        #expect(model.trashed.isEmpty && model.pile.items.isEmpty)
    }

    // MARK: Criterion 9: the restore point

    @Test func theRestorePointBoxStartsUncheckedAndNeedsAGigabyte() {
        var support = RemovalSupport.demo
        #expect(!RemovalRun(mode: .permanent, urls: [], support: support).wantsRestorePoint)
        #expect(RemovalRun(mode: .permanent, urls: [], support: support).canMakeRestorePoint)
        support.available = { _ in RemovalRun.restorePointMinimum - 1 }
        var low = RemovalRun(mode: .permanent, urls: [], support: support)
        #expect(!low.canMakeRestorePoint)
        low.wantsRestorePoint = true
        #expect(!low.needsRestorePoint, "a restore point would be attempted below 1 GB")
        // Trash mode never offers one.
        #expect(!RemovalRun(mode: .trash, urls: [], support: .demo).canMakeRestorePoint)
    }

    /// The real checkbox, read from the hosted sheet: off at first, and disabled below 1 GB.
    @Test(arguments: [(UInt64(2_000_000_000), true), (UInt64(900_000_000), false)])
    func theRestorePointCheckboxInTheSheet(available: UInt64, enabled: Bool) throws {
        var support = RemovalSupport.demo
        support.available = { _ in available }
        let run = RemovalRun(mode: .permanent, urls: [], support: support)
        let sheet = TrashSheet(
            title: "t", message: "m", rows: [TrashSheetRow(url: URL(fileURLWithPath: "/nonexistent-macontrol-fixture/a"), bytes: 1)],
            confirmTitle: "c", report: nil, isWorking: false, mode: .permanent, restorePoint: .constant(false), run: run,
            onConfirm: {}, onClose: {}
        )
        let window = AppListOrderTests.host(sheet, size: Snapshot.sheetSize)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        let boxes = HardcoreModeTests.checkboxes(in: content)
        #expect(boxes.count == 1)
        #expect(boxes.first?.state == .off && boxes.first?.isEnabled == enabled)
    }

    @Test(arguments: [false, true])
    func aRestorePointIsMadeOnlyWhenTicked(ticked: Bool) async throws {
        let fixture = try RemovalFixture()
        let model = try await fixture.cleanModel()
        let made = OSAllocatedUnfairLock(initialState: 0)
        model.support.createRestorePoint = { made.withLock { $0 += 1 }; return "com.apple.TimeMachine.2026-09-24-120000.local" }
        model.support.available = { _ in 5_000_000_000 }
        model.hardcore.isOn = true
        model.beginReview()
        model.review?.run.wantsRestorePoint = ticked
        await model.confirmReview()
        #expect(made.withLock { $0 } == (ticked ? 1 : 0))
        #expect(model.review?.run.restorePoint == (ticked ? "com.apple.TimeMachine.2026-09-24-120000.local" : nil))
        #expect(model.review?.report != nil)
    }

    /// A failed restore point deletes nothing until the user answers "Delete anyway?"; then it goes on without one.
    @Test func aFailedRestorePointAsksBeforeDeleting() async throws {
        let fixture = try RemovalFixture()
        let (model, _) = try await fixture.uninstallModel()
        model.support.createRestorePoint = { throw CocoaError(.fileWriteOutOfSpace) }
        model.support.available = { _ in 5_000_000_000 }
        model.hardcore.isOn = true
        model.beginUninstall()
        model.confirmation?.run.wantsRestorePoint = true
        await model.confirmUninstall()
        #expect(model.confirmation?.run.restorePointProblem != nil)
        #expect(model.confirmation?.report == nil && fixture.modes.withLock { $0 }.isEmpty, "it deleted without asking")
        try fixture.expectUntouched(["Applications/Probe.app/Contents/Info.plist"])

        // A second confirm while the question is open does nothing either.
        await model.confirmUninstall()
        #expect(fixture.modes.withLock { $0 }.isEmpty)

        await model.confirmWithoutRestorePoint()
        #expect(Set(fixture.modes.withLock { $0 }) == [.permanent])
        #expect(model.confirmation?.report != nil && model.confirmation?.run.restorePoint == nil)
    }

    // MARK: Criterion 10: the administrator helper, only where it belongs

    static let launcher = PrivilegedLauncher(helperURL: URL(fileURLWithPath: "/nonexistent-macontrol-fixture/macontrol-priv")) { _, _, _, _ in
        throw PrivilegedError.cancelled
    }

    @Test(arguments: [false, true])
    func cleanMarksAdminRowsOnlyWithALauncher(withLauncher: Bool) async throws {
        let fixture = try RemovalFixture()
        let model = try await fixture.cleanModel(administrator: withLauncher ? Self.launcher : nil) { $0.lastPathComponent == "com.example.a" }
        #expect(model.adminItems == (withLauncher ? Set(model.items.map(\.url)) : []))
        model.beginReview()
        #expect(model.review?.adminCount == (withLauncher ? 1 : 0))
        let notes = AdminText.notes(count: model.review?.adminCount ?? 0, mode: .trash)
        #expect(notes.count == (withLauncher ? 2 : 0))
    }

    @Test(arguments: [false, true])
    func uninstallOffersAdminLeftoversOnlyWithALauncher(withLauncher: Bool) throws {
        let model = UninstallModel.demo()
        model.canUseAdministrator = withLauncher
        model.needsAdministrator = { _ in false }
        let admin = try #require(model.plan?.leftovers.first { $0.needsAdministrator })
        model.setChosen(true, admin)
        #expect(model.isChosen(admin) == withLauncher)
        model.beginUninstall()
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.rows.contains { $0.url == admin.url } == withLauncher)
        #expect(confirmation.adminCount == (withLauncher ? 1 : 0))
        // The launcher comes from the Uninstaller the model is built with.
        let temp = try TemporaryDirectory()
        let uninstaller = Uninstaller(
            home: temp.url, applicationFolders: [], systemRoot: temp.url,
            trash: TrashService(journalURL: temp.url.appendingPathComponent("journal.jsonl")), actions: RecordedActions().actions,
            administrator: withLauncher ? Self.launcher : nil
        )
        #expect(UninstallModel(uninstaller: uninstaller, engine: nil).canUseAdministrator == withLauncher)
    }

    /// Disk Map has no launcher at all, so root-owned items there stay "Needs admin" with Reveal in Finder (r2: sec 3a).
    @Test func diskMapNeverGetsTheLauncher() throws {
        let model = DiskMapModel(engine: nil, trash: nil)
        let types = Mirror(reflecting: model).children.map { type(of: $0.value) }
        #expect(!types.contains { $0 == PrivilegedLauncher.self || $0 == PrivilegedLauncher?.self })
        let folder = HardcoreModeTests.sources.appendingPathComponent("DiskMap")
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("PrivilegedLauncher") && !source.contains("administrator:"), "\(file)")
        }
        #expect(DiskMapText.refusal(.needsAdministrator).contains("Reveal in Finder"))
        let appModel = try String(contentsOf: HardcoreModeTests.sources.appendingPathComponent("Shell/AppModel.swift"), encoding: .utf8)
        #expect(appModel.contains("diskMap: DiskMapModel(engine: engine, trash: trash),"))
        #expect(appModel.contains("trash: trash, administrator: administrator)") && appModel.contains("Uninstaller(engine: engine, trash: trash, administrator: administrator)"))
    }

    /// Every screen reads the one switch the app owns.
    @Test func everyScreenSharesTheAppsSwitch() {
        let app = AppModel.demo()
        #expect(app.clean.hardcore === app.hardcore && app.uninstall.hardcore === app.hardcore && app.diskMap.hardcore === app.hardcore)
    }
}

/// A home, a Trash folder and a journal in one temporary folder. The Trash backend renames into the fixture Trash and
/// refuses anything outside the fixture.
final class RemovalFixture {
    let temp: TemporaryDirectory
    let home: URL
    let trash: URL
    /// The modes the uninstaller's remove step was called with.
    let modes = OSAllocatedUnfairLock(initialState: [DeletionMode]())

    init() throws {
        temp = try TemporaryDirectory()
        home = try temp.directory("home")
        trash = try temp.directory("Trash")
    }

    func service() -> TrashService {
        let (root, trash) = (temp.url.path + "/", trash)
        // The journal's folder is protected, so it gets its own, not the fixture root.
        return TrashService(journalURL: temp.url.appendingPathComponent("state/journal.jsonl"), backend: TrashBackend { url in
            guard url.path.hasPrefix(root) else { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }, home: home)
    }

    var inTrash: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted() }

    /// One old cache, scanned by a real Cleaner and removed through the fixture's TrashService.
    func cleanModel(administrator: PrivilegedLauncher? = nil, needsAdministrator: @escaping (URL) -> Bool = { _ in false }) async throws -> CleanModel {
        try CleanModelTests.oldFile(temp, "home/Library/Caches/com.example.a/blob")
        let cleaner = Cleaner(catalog: CleanModelTests.cachesCatalog, home: home, now: CleanModelTests.clock)
        let model = CleanModel(cleaner: cleaner, trash: service(), engine: nil, administrator: administrator)
        model.needsAdministrator = needsAdministrator
        model.support.available = { _ in nil }
        await model.scan()
        #expect(model.selectedItems.count == 1)
        return model
    }

    /// The sample app with its cache. Quit and bootout are stand-ins; the remove step records its mode and then either
    /// runs the fixture's TrashService for real or answers `outcome` for every item.
    func uninstallModel(outcome: (@Sendable (TrashItem) -> TrashOutcome)? = nil) async throws -> (UninstallModel, UninstallPlan) {
        let service = service()
        let modes = modes
        let actions = UninstallActions(quit: { _ in true }, bootout: { _ in }, remove: { items, mode in
            modes.withLock { $0.append(mode) }
            if let outcome { return TrashReport(batch: UUID(), outcomes: items.map(outcome)) }
            return await service.remove(items, mode: mode)
        })
        let uninstaller = Uninstaller(
            home: home, applicationFolders: [temp.url.appendingPathComponent("Applications")],
            systemRoot: try temp.directory("root"), trash: service, actions: actions
        )
        try UninstallModelTests.bundle(temp, "Probe", "com.example.macontrol-probe")
        try temp.file("home/Library/Caches/com.example.macontrol-probe/data", size: 2_000)
        let model = UninstallModel(uninstaller: uninstaller, engine: nil)
        model.support.available = { _ in nil }
        let plan = try await UninstallModelTests.selectSample(model)
        return (model, plan)
    }

    /// A scanned folder with one file staged in the Discard Pile.
    func diskMapModel() async throws -> DiskMapModel {
        try temp.file("home/Documents/blob.bin", size: 50_000)
        let model = DiskMapModel(engine: ScanEngine(), trash: service())
        // Staging checks the real home's protected paths; the fixture's TrashService checks its own.
        model.pile = DiscardPile { _ in nil }
        model.support.available = { _ in nil }
        await model.scan(home.appendingPathComponent("Documents"))
        let tree = try #require(model.tree)
        let node = try #require((0..<tree.count).first { tree.name(of: $0) == "blob.bin" })
        model.stage(node)
        #expect(model.pile.items.count == 1)
        return model
    }

    /// Trash mode moved every path into the fixture Trash; permanent mode moved nothing there and reported no move.
    func expectRemoved(in mode: DeletionMode, report: TrashReport, paths: [String]) throws {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        switch mode {
        case .trash:
            let allTrashed = report.outcomes.allSatisfy { $0.isTrashed }
            #expect(allTrashed, "\(report.outcomes)")
            #expect(Set(names).isSubset(of: inTrash), "fixture Trash: \(inTrash)")
        case .permanent:
            let anyTrashed = report.outcomes.contains { $0.isTrashed }
            #expect(!anyTrashed, "a permanent batch moved to the Trash: \(report.outcomes)")
            #expect(inTrash.isEmpty, "fixture Trash: \(inTrash)")
        }
    }

    func expectUntouched(_ paths: [String]) throws {
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent(path).path), "\(path) is gone")
        }
        #expect(inTrash.isEmpty, "fixture Trash: \(inTrash)")
    }

    /// Return, then a wait long enough for a confirm to start, then Esc.
    func pressReturnThenEsc(in window: NSWindow, stillAsking: () -> Bool) async throws {
        AppListOrderTests.press("\r", keyCode: 36, [], in: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stillAsking(), "Return confirmed the sheet")
        AppListOrderTests.press("\u{1b}", keyCode: 53, [], in: window)
    }
}
