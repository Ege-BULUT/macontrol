import Foundation
import Testing
import Uninstaller

/// Recall against what cask curators list for 20 apps (CaskOracle.swift). Each app is installed alone and every
/// zap path without a glob is planted. Library paths should be found; everything else (`~/.vscode`, `/Applications`
/// helpers) must never be, since the search stays in Library folders (F-0011, F-0066).
@Suite struct CaskOracleTests {
    @Test func findsWhatCaskCuratorsListAndNothingOutsideLibrary() async throws {
        var listed = 0, shown = 0, preselected = 0
        var misses: [String] = []
        for cask in caskOracle {
            let fx = try Fixture()
            let name = String(cask.app.dropLast(".app".count))
            try fx.app(name, id: cask.bundleIdentifier)
            let planted = try cask.zap.filter { !$0.contains("*") }.map { path in (path, try plant(path, in: fx)) }

            let plan = try await fx.plan(name)

            for (path, url) in planted {
                let hit = plan.leftovers.first { url.path == $0.url.path || url.path.hasPrefix($0.url.path + "/") }
                guard path.hasPrefix("~/Library/") || path.hasPrefix("/Library/") else {
                    #expect(hit == nil, "\(cask.token): \(path) is outside Library")
                    continue
                }
                listed += 1
                if let hit {
                    shown += 1
                    preselected += hit.isPreselected ? 1 : 0
                } else {
                    misses.append("\(cask.token): \(path)")
                }
            }
        }
        // Measured 2026-09-23: 133 of 169 Library paths shown, 113 preselected. Most misses are right: shared
        // vendor items (Google Keystone, Mozilla's crash reporter), other products (Sublime Text 3's
        // com.sublimetext.3) and helpers with their own identifier (com.figma.agent). The fixture's Info.plist
        // carries only the file name, so names the real bundles declare (CFBundleName "Code", "iTerm2") count as
        // misses here. Raise these floors when the matcher learns more; never lower them.
        #expect(shown >= 133, "shown \(shown) of \(listed); missed: \(misses)")
        #expect(preselected >= 113, "preselected \(preselected) of \(listed)")
    }

    /// Plants a zap path in the fixture: a file for names with a file extension, otherwise a folder with a file in it.
    private func plant(_ path: String, in fx: Fixture) throws -> URL {
        let relative = path.hasPrefix("~/") ? "home/" + path.dropFirst(2) : "root/" + path.dropFirst()
        let url = fx.tmp.url.appendingPathComponent(relative)
        let fileExtensions: Set<String> = ["plist", "binarycookies", "log", "json", "db", "txt"]
        if fileExtensions.contains(url.pathExtension) {
            try fx.file(relative)
        } else {
            try fx.file(relative + "/data")
        }
        return url
    }
}
