import Foundation
import TestSupport
import Testing
@testable import Uninstaller

/// DESIGN-debloat sections 4.3-4.5: the bundled catalog, its validator, and how profiles shape a plan.
@Suite struct AppleProfileTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    // MARK: Catalog and validator

    @Test func shippedCatalogPasses() throws {
        let data = try Data(contentsOf: Self.sources.appendingPathComponent("Uninstaller/Resources/apple-apps.json"))
        let catalog = try JSONDecoder().decode(AppleProfiles.self, from: data)
        #expect(catalog.problems(home: FileManager.default.homeDirectoryForCurrentUser) == [])
        // What the app loads is that file, validated.
        #expect(AppleProfiles.bundled.profiles.map(\.bundleIdentifier) == catalog.profiles.map(\.bundleIdentifier))
        let xcode = try #require(AppleProfiles.bundled.profile(for: "com.apple.dt.Xcode"))
        #expect(xcode.verified && xcode.simulatorRuntimes)
        #expect(AppleProfiles.bundled.profiles.filter(\.verified).map(\.name) == ["Xcode"])
        #expect(Set(AppleProfiles.bundled.profiles.map(\.name)).isSuperset(of: [
            "GarageBand", "Logic Pro", "MainStage", "iMovie", "Pages", "Numbers", "Keynote", "Final Cut Pro", "Motion", "Compressor",
        ]))
    }

    /// One valid profile; each case below breaks exactly one rule of section 4.3.
    static func catalog(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var profile: [String: Any] = [
            "bundleIdentifier": "com.apple.dt.Xcode", "name": "Xcode", "verified": true, "evidence": "test",
            "items": [["path": "/Library/Developer/CoreSimulator/Caches"], ["path": "~/Library/Developer/Xcode/DerivedData", "note": "Build output."]],
            "receipts": ["com.apple.pkg.Xcode"], "neverTouch": ["~/Library/Developer/Xcode/Archives"],
            "keptByMacOS": [["name": "MobileDeviceDevelopment", "path": "/Library/Apple/System/Library/Receipts/x.plist"]],
        ]
        change(&profile)
        return ["version": 1, "profiles": [profile]]
    }

    static func item(_ path: String) -> (inout [String: Any]) -> Void {
        { $0["items"] = [["path": path]] }
    }

    nonisolated(unsafe) static let brokenRules: [(rule: String, catalog: [String: Any])] = [
        ("outside the Library folders", catalog(item("/Applications/Xcode.app/Contents"))),
        ("a /Library folder the helper may not touch", catalog(item("/Library/Keychains/System/x"))),
        ("a .. component", catalog(item("/Library/Developer/../Keychains/x"))),
        ("a * component", catalog(item("/Library/Developer/Core*"))),
        ("an empty component", catalog(item("/Library/Developer//Caches"))),
        ("a . component", catalog(item("/Library/Developer/./Caches"))),
        ("fewer than three components", catalog(item("~/Library/Caches"))),
        ("a protected folder", catalog(item("~/Library/Application Support/Apple"))),
        ("inside neverTouch", catalog(item("~/Library/Developer/Xcode/Archives/2026"))),
        ("containing neverTouch", catalog(item("~/Library/Developer/Xcode"))),
        ("a receipt id that is not [A-Za-z0-9._-]+", catalog { $0["receipts"] = ["com.apple.pkg/Xcode"] }),
        ("a bundle id that is not reverse-DNS", catalog { $0["bundleIdentifier"] = "Xcode" }),
        ("a sharer that is not reverse-DNS", catalog { $0["items"] = [["path": "/Library/Audio/Apple Loops/Apple", "sharedWith": ["Logic"]]] }),
        ("a note over 200 characters", catalog { $0["items"] = [["path": "/Library/Developer/CoreSimulator/Caches", "note": String(repeating: "a", count: 201)]] }),
        ("a neverTouch path that is not absolute", catalog { $0["neverTouch"] = ["Music/GarageBand"] }),
        ("a keptByMacOS path outside /Library/Apple", catalog { $0["keptByMacOS"] = [["name": "X", "path": "/Library/Developer/x"]] }),
        ("version 2", catalog().merging(["version": 2]) { $1 }),
        ("a profile listed twice", catalog().merging(["profiles": (catalog()["profiles"] as! [Any]) + (catalog()["profiles"] as! [Any])]) { $1 }),
        ("a missing field", catalog { $0["evidence"] = nil }),
    ]

    @Test(arguments: brokenRules.indices)
    func validatorRejectsEachRule(index: Int) throws {
        let (rule, catalog) = Self.brokenRules[index]
        let tmp = try TemporaryDirectory()
        let home = try tmp.directory("home")
        // The protected-folder rule reads the folder as Safety does, so its parent must exist.
        try tmp.directory("home/Library/Application Support")
        let data = try JSONSerialization.data(withJSONObject: catalog)
        #expect(AppleProfiles.load(data, home: home).profiles.isEmpty, "\(rule) was accepted")
        if let decoded = try? JSONDecoder().decode(AppleProfiles.self, from: data) {
            #expect(decoded.problems(home: home).count == 1, "\(rule): \(decoded.problems(home: home))")
        }
    }

    /// The positive control for the cases above: the unbroken catalog loads.
    @Test func validCatalogLoads() throws {
        let tmp = try TemporaryDirectory()
        let data = try JSONSerialization.data(withJSONObject: Self.catalog())
        #expect(AppleProfiles.load(data, home: try tmp.directory("home")).profiles.count == 1)
    }

    /// Security review 3(c): root may act below `com.apple.*`/`Apple*` names only at the catalog's own paths, so the
    /// helper keeps them as a constant. Read as text, so this compiles before and after privileged-helper merges.
    @Test func everyLibraryPathIsInPrivilegedScope() throws {
        let paths = AppleProfiles.bundled.systemLibraryPaths
        #expect(paths.count == 12)
        let safety = Self.sources.appendingPathComponent("Safety")
        let texts = try FileManager.default.contentsOfDirectory(atPath: safety.path).filter { $0.hasSuffix(".swift") }
            .map { try String(contentsOf: safety.appendingPathComponent($0), encoding: .utf8) }
        guard let scope = texts.first(where: { $0.contains("appleContent") && $0.contains("PrivilegedScope") }) else {
            withKnownIssue("T-0075: PrivilegedScope.appleContent is not on this branch yet") {
                Issue.record("no PrivilegedScope.appleContent in Sources/Safety")
            }
            return
        }
        for path in paths {
            #expect(scope.contains("\"\(path)\""), "\(path) is missing from PrivilegedScope.appleContent")
        }
    }

    @Test func contentLibrariesAreGone() throws {
        let finder = try String(contentsOf: Self.sources.appendingPathComponent("Uninstaller/LeftoverFinder.swift"), encoding: .utf8)
        #expect(!finder.contains("contentLibraries"))
    }

    // MARK: Profiles in the plan

    static func xcodeTree(_ fx: Fixture) throws {
        try fx.app("Xcode", id: "com.apple.dt.Xcode")
        for item in ["CoreSimulator/Caches/dyld/x", "CoreSimulator/Profiles/x", "CoreDevice/x", "DeviceKit/x",
                     "PrivateFrameworks/CoreSimulator.framework/x", "DeveloperDiskImages/x", "CommandLineTools/usr/bin/git"] {
            try fx.file("root/Library/Developer/\(item)")
        }
        try fx.file("home/Library/Developer/Xcode/DerivedData/Project/x")
        try fx.file("home/Library/Developer/Xcode/Archives/2026/x")
        try fx.file("home/Library/Developer/CoreSimulator/Devices/UUID/x")
        try fx.file("home/Library/Caches/com.apple.dt.Xcode/x")
        try fx.file("root/private/var/db/receipts/com.apple.pkg.Xcode.plist")
        try fx.file("root/private/var/db/receipts/com.apple.pkg.Xcode.bom")
        try fx.file("root/Library/Apple/System/Library/Receipts/com.apple.pkg.MobileDeviceDevelopment.plist")
    }

    /// An App Store app as `AppBundle` classifies Apple-signed bundles; fixtures can't carry Apple's signature.
    static func appleApp(_ fx: Fixture, _ name: String, kind: AppKind = .appleAppStore) async throws -> InstalledApp {
        var app = try await fx.app(named: name)
        app.kind = kind
        return app
    }

    @Test func xcodePlanFollowsItsProfile() async throws {
        let fx = try Fixture()
        try Self.xcodeTree(fx)

        let plan = try await fx.uninstaller().plan(for: Self.appleApp(fx, "Xcode"))

        #expect(plan.paths(relativeTo: fx.tmp.url, where: { $0.evidence == .appleProfile }) == [
            "home/Library/Developer/CoreSimulator/Devices", "home/Library/Developer/Xcode/DerivedData",
            "root/Library/Developer/CoreDevice", "root/Library/Developer/CoreSimulator/Caches",
            "root/Library/Developer/CoreSimulator/Profiles", "root/Library/Developer/DeveloperDiskImages",
            "root/Library/Developer/DeviceKit", "root/Library/Developer/PrivateFrameworks",
            "root/private/var/db/receipts/com.apple.pkg.Xcode.bom", "root/private/var/db/receipts/com.apple.pkg.Xcode.plist",
        ])
        // neverTouch: the Command Line Tools (git, clang, Homebrew) and the user's archives are never listed.
        #expect(!plan.leftovers.contains { $0.url.path.contains("CommandLineTools") || $0.url.path.contains("Archives") })
        #expect(plan.paths(relativeTo: fx.home, where: { $0.evidence == .bundleIdentifier }) == ["Library/Caches/com.apple.dt.Xcode"])
        let devices = plan.leftover("Library/Developer/CoreSimulator/Devices", in: fx.home)
        #expect(devices?.note == "Holds the apps and data inside your simulators.")
        #expect(plan.leftover("Library/Developer/Xcode/DerivedData", in: fx.home)?.isPreselected == true)
        // Root-owned content is the helper's: selected by its evidence, admin-routed.
        let caches = try #require(plan.leftover("Library/Developer/CoreSimulator/Caches", in: fx.root))
        #expect(caches.needsAdministrator && caches.note == nil && caches.evidence.preselected)
        // Restricted content has no checkbox: it is a note, and the receipts are leftovers, not notes.
        #expect(plan.notes.contains { $0.hasPrefix("Kept by macOS: MobileDeviceDevelopment") })
        #expect(!plan.notes.contains { $0.contains("com.apple.pkg.Xcode") })
    }

    @Test func restrictedProfileItemsAreKeptByMacOSWithoutACheckbox() async throws {
        let fx = try Fixture()
        try Self.xcodeTree(fx)
        let finder = LeftoverFinder(
            app: try await Self.appleApp(fx, "Xcode"), others: [], home: fx.home, systemRoot: fx.root,
            isRestricted: { $0.lastPathComponent == "DeveloperDiskImages" || $0.lastPathComponent == "com.apple.pkg.Xcode.bom" }
        )
        let result = finder.run()
        #expect(!result.candidates.contains { $0.url.lastPathComponent == "DeveloperDiskImages" || $0.url.lastPathComponent == "com.apple.pkg.Xcode.bom" })
        #expect(result.notes.contains { $0.hasPrefix("Kept by macOS: DeveloperDiskImages") })
        #expect(result.candidates.contains { $0.url.lastPathComponent == "com.apple.pkg.Xcode.plist" })
    }

    /// A bundle that only claims Xcode's identifier is not Apple's: no profile, no Apple content offered.
    @Test func onlyApplesOwnAppGetsTheProfile() async throws {
        let fx = try Fixture()
        try Self.xcodeTree(fx)
        let plan = try await fx.uninstaller().plan(for: Self.appleApp(fx, "Xcode", kind: .thirdParty))
        #expect(!plan.leftovers.contains { $0.evidence == .appleProfile })
        #expect(!plan.notes.contains { $0.hasPrefix("Kept by macOS") })
    }

    static func garageBandTree(_ fx: Fixture) throws {
        try fx.app("GarageBand", id: "com.apple.garageband10")
        try fx.file("root/Library/Application Support/GarageBand/Instrument Library/a.caf")
        try fx.file("root/Library/Application Support/Logic/Alchemy/a.caf")
        try fx.file("root/Library/Audio/Apple Loops/Apple/loop.caf")
        try fx.file("root/Library/Audio/Apple Loops Index/index.db")
        try fx.file("home/Music/GarageBand/My Song.band")
        try fx.file("home/Library/Audio/Apple Loops/User Loops/mine.caf")
    }

    @Test func sharedContentIsNeverPreselectedAndUnverifiedItemsSaySo() async throws {
        let fx = try Fixture()
        try Self.garageBandTree(fx)

        let alone = try await fx.uninstaller().plan(for: Self.appleApp(fx, "GarageBand"))
        let library = fx.root.appendingPathComponent("Library")
        #expect(alone.paths(relativeTo: library) == [
            "Application Support/GarageBand", "Application Support/Logic", "Audio/Apple Loops Index", "Audio/Apple Loops/Apple",
        ])
        #expect(alone.leftovers.allSatisfy { $0.evidence == .appleProfile && $0.note?.hasSuffix(AppleProfile.unverifiedNote) == true })
        #expect(alone.leftovers.allSatisfy { !$0.isPreselected && $0.note != nil })
        #expect(alone.leftover("Audio/Apple Loops/Apple", in: library)?.note
            == "Also used by Logic Pro and MainStage (not installed). \(AppleProfile.unverifiedNote)")
        #expect(alone.leftover("Application Support/GarageBand", in: library)?.note == AppleProfile.unverifiedNote)

        try fx.app("Logic Pro", id: "com.apple.logic10")
        let withLogic = try await fx.uninstaller().plan(for: Self.appleApp(fx, "GarageBand"))
        #expect(withLogic.leftover("Audio/Apple Loops/Apple", in: library)?.note
            == "Also used by Logic Pro, which is installed. \(AppleProfile.unverifiedNote)")
        // ~/Music is never searched, and the user's own loops are neverTouch.
        #expect(!withLogic.leftovers.contains { $0.url.path.hasPrefix(fx.home.path) && $0.url.path.contains("Loops") })
    }

    // MARK: LaunchServices

    /// feasibility-apple-apps open question 7: listing fixture apps registered them with LaunchServices for good.
    /// Reads the whole LaunchServices database (about 10 s), so it runs only with MACONTROL_LSREGISTER=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_LSREGISTER"] == "1"))
    func fixturesDoNotRegisterWithLaunchServices() async throws {
        let fx = try Fixture()
        try Self.xcodeTree(fx)
        try Self.garageBandTree(fx)
        _ = try await fx.uninstaller().plan(for: Self.appleApp(fx, "Xcode"))
        _ = try await fx.uninstaller().plan(for: Self.appleApp(fx, "GarageBand"))

        let dump = Process()
        dump.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        dump.arguments = ["-dump"]
        let output = Pipe()
        dump.standardOutput = output
        dump.standardError = FileHandle.nullDevice
        try dump.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        dump.waitUntilExit()
        #expect(text.count > 100_000, "the dump looks empty")
        #expect(!text.contains(fx.tmp.url.lastPathComponent), "a fixture bundle is registered with LaunchServices")
    }
}
