import Foundation
@testable import MacontrolUI
import Testing
import Uninstaller

/// DESIGN-debloat section 4.5 on the fixture Xcode and GarageBand: what starts selected, by mode.
@Suite struct DebloatModelTests {
    static func leftover(_ model: DebloatModel, _ app: URL, _ suffix: String) throws -> (DebloatApp, Leftover) {
        let row = try #require(model.row(app))
        let leftover = try #require(row.plan?.leftovers.first { $0.url.path.hasSuffix(suffix) }, "no \(suffix)")
        return (row, leftover)
    }

    /// The sealed panel's total for macOS's own apps waits until every one is measured.
    @Test func systemAppsSizeWaitsForEveryLockedApp() throws {
        let model = DebloatModel.demo()
        #expect(model.systemAppsSize == model.lockedSizes.values.reduce(0, +))
        model.lockedSizes[try #require(model.locked.first).url] = nil
        #expect(model.systemAppsSize == nil)
    }

    @Test func appRowsStartUnticked() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model(hardcore: true, administrator: true)
        #expect(model.rows.map(\.app.name) == ["GarageBand", "Xcode"])
        #expect(model.rows.allSatisfy { $0.plan != nil && model.canTick($0) && !model.isTicked($0) })
        #expect(model.tickedRows.isEmpty && model.bytesToRemove == 0 && model.runtimeBytesToDelete == 0)
        model.beginRemove()
        #expect(model.confirmation == nil)
    }

    @Test func runtimesFollowTheModeAndAreNeverPreselectedWithASecondXcode() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()
        let xcode = try #require(model.row(fx.xcode))
        #expect(xcode.runtimes.map(\.bytes) == [8_494_282_293, 3_935_033_546])
        #expect(!model.runtimesChosen(xcode))
        model.hardcore.isOn = true
        #expect(model.runtimesChosen(xcode) && model.runtimeNote(xcode) == nil)

        try fx.app("Xcode-beta", "com.apple.dt.Xcode")
        let withBeta = try await fx.model(hardcore: true)
        let shared = try #require(withBeta.row(fx.xcode))
        #expect(withBeta.runtimeNote(shared) == "Also used by Xcode-beta")
        #expect(!withBeta.runtimesChosen(shared))
    }

    @Test func containersAreNotPreselectedInHardcoreMode() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()
        let (row, container) = try Self.leftover(model, fx.garageBand, "Containers/com.apple.garageband10")
        #expect(model.isChosen(container, of: row) && model.note(for: container, of: row) == nil)
        model.hardcore.isOn = true
        #expect(!model.isChosen(container, of: row))
        #expect(model.note(for: container, of: row) == "May hold documents you made in GarageBand.")
    }

    /// With the helper, root-owned content of a verified profile is selected; shared and unverified content never is.
    @Test func sharedAndUnverifiedContentIsNeverPreselected() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model(hardcore: true, administrator: true)
        let (xcode, caches) = try Self.leftover(model, fx.xcode, "CoreSimulator/Caches")
        #expect(model.isChosen(caches, of: xcode))
        let (xcodeRow, devices) = try Self.leftover(model, fx.xcode, "CoreSimulator/Devices")
        #expect(!model.isChosen(devices, of: xcodeRow))
        for suffix in ["Application Support/GarageBand", "Apple Loops/Apple"] {
            let (row, item) = try Self.leftover(model, fx.garageBand, suffix)
            #expect(item.note?.hasSuffix(AppleProfile.unverifiedNote) == true)
            #expect(!model.isChosen(item, of: row), "\(suffix)")
        }
        let (row, loops) = try Self.leftover(model, fx.garageBand, "Apple Loops/Apple")
        #expect(loops.note?.hasPrefix("Also used by Logic Pro and MainStage (not installed).") == true)
        _ = row
    }

    @Test func rootOwnedContentNeedsTheHelper() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()
        let (row, caches) = try Self.leftover(model, fx.xcode, "CoreSimulator/Caches")
        #expect(caches.needsAdministrator && !model.canChoose(caches))
        model.setChosen(true, caches, of: row)
        #expect(!model.isChosen(caches, of: row))
    }

    /// Section 4.2: "X to the Trash · Y deleted now" in Trash mode, "frees up to" in hardcore mode.
    @Test func footerSplitsWhatGoesToTheTrashFromWhatIsDeleted() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model()
        let xcode = try #require(model.row(fx.xcode))
        model.setTicked(true, xcode)
        let plan = try #require(xcode.plan)
        let chosen = model.chosenLeftovers(xcode).reduce(plan.appMeasurement.allocated) { $0 + $1.measurement.allocated }
        #expect(model.bytesToRemove == chosen && model.runtimeBytesToDelete == 0)
        #expect(!model.footerText.contains("deleted now"))

        model.setRuntimesChosen(true, xcode)
        #expect(model.runtimeBytesToDelete == 12_429_315_839)
        #expect(model.selectedBytes(xcode) == chosen + 12_429_315_839)
        #expect(model.footerText.hasPrefix("1 app, ") && model.footerText.contains(" to the Trash · ") && model.footerText.hasSuffix(" deleted now"))

        model.hardcore.isOn = true
        #expect(model.footerText.hasPrefix("1 app, frees up to "))
    }

    /// Review 2: CoreSimulator holds the only tool that deletes runtimes, so it waits for them in either mode.
    @Test func coreSimulatorWaitsForTheRuntimes() async throws {
        let fx = try DebloatFixture()
        let model = try await fx.model(administrator: true)
        let (row, frameworks) = try Self.leftover(model, fx.xcode, "Developer/PrivateFrameworks")
        model.setTicked(true, row)
        #expect(!model.runtimesChosen(row) && !model.isChosen(frameworks, of: row))
        #expect(model.note(for: frameworks, of: row)?.hasPrefix("Holds the only tool that deletes simulator runtimes.") == true)
        model.setRuntimesChosen(true, row)
        #expect(model.isChosen(frameworks, of: row) && model.note(for: frameworks, of: row) == nil)
        // Unticked again: back to held, not the tick it had while the runtimes went too.
        model.setChosen(true, frameworks, of: row)
        model.setRuntimesChosen(false, row)
        #expect(!model.isChosen(frameworks, of: row))

        let hardcore = try await fx.model(hardcore: true, administrator: true)
        let (xcode, framework) = try Self.leftover(hardcore, fx.xcode, "Developer/PrivateFrameworks")
        #expect(hardcore.runtimesChosen(xcode) && hardcore.isChosen(framework, of: xcode))

        // Review 2, 1: the plan holds it back for every screen; Debloat lifts that when there are no runtimes.
        #expect(frameworks.note == SimRuntimeTool.heldNote && !frameworks.isPreselected)
        fx.listed = []
        let none = try await fx.model(administrator: true)
        let (bare, framework2) = try Self.leftover(none, fx.xcode, "Developer/PrivateFrameworks")
        none.setTicked(true, bare)
        #expect(bare.runtimes.isEmpty && none.note(for: framework2, of: bare) == nil && none.isChosen(framework2, of: bare))
    }

    /// Review 6: with Xcode-beta installed, what every Xcode shares is held back like the runtimes.
    @Test func aSecondXcodeKeepsItsSharedDeveloperContent() async throws {
        let fx = try DebloatFixture()
        try fx.app("Xcode-beta", "com.apple.dt.Xcode")
        let model = try await fx.model(hardcore: true, administrator: true)
        let xcode = try #require(model.row(fx.xcode))
        model.setTicked(true, xcode)
        let chosen = model.chosenLeftovers(xcode).map(\.url.lastPathComponent)
        #expect(!chosen.contains("PrivateFrameworks") && !chosen.contains("Caches") && !chosen.contains("DerivedData"), "\(chosen)")
        let (row, caches) = try Self.leftover(model, fx.xcode, "CoreSimulator/Caches")
        #expect(model.note(for: caches, of: row) == "Also used by Xcode-beta, which is installed.")
    }
}
