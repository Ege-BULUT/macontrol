import Darwin
import Foundation
import MacontrolCore
import Testing
import TestSupport

/// The probe runs against a fake home, so the result never depends on this Mac's real grant (F-0001).
@Suite struct FullDiskAccessProbeTests {
    static let perUserTCC = "Library/Application Support/com.apple.TCC/TCC.db"

    @Test func emptyHomeIsUnknownEvenThoughTheSystemTCCDatabaseIsReadable() throws {
        let home = try TemporaryDirectory()
        // Any app can read the system TCC.db without FDA. A probe that looked at it would say "granted" here.
        let systemTCC = "/Library/Application Support/com.apple.TCC/TCC.db"
        let systemReadable = access(systemTCC, R_OK) == 0
        #expect(FullDiskAccess.probe(home: home.url) == .unknown, "system TCC.db readable: \(systemReadable)")
    }

    @Test func readablePerUserDatabaseMeansGranted() throws {
        let home = try TemporaryDirectory()
        try home.file(Self.perUserTCC, size: 16)
        #expect(FullDiskAccess.probe(home: home.url) == .granted)
    }

    @Test func refusedOpenMeansDenied() throws {
        let home = try TemporaryDirectory()
        let database = try home.file(Self.perUserTCC, size: 16)
        let safari = try home.directory("Library/Safari")
        chmod(database.path, 0)
        chmod(safari.path, 0)
        #expect(FullDiskAccess.probe(home: home.url) == .denied)
    }

    @Test func fallsBackToSafariWhenTheDatabaseIsMissing() throws {
        let home = try TemporaryDirectory()
        try home.directory("Library/Safari")
        #expect(FullDiskAccess.probe(home: home.url) == .granted)
    }
}
