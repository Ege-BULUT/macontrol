import Darwin
import Foundation
import MacontrolCore
@testable import ScanEngine
import Testing
import TestSupport

/// `ItemMeasurement.newestModification` feeds the cleaner's in-use and minimum-age guards (F-0015),
/// so it must not read as old when only mtime says so.
@Suite struct MeasureRecencyTests {
    private static let year2020 = 1_577_836_800

    /// Sets atime and mtime to 2020-01-01, as curl --remote-time, tar and unzip do. ctime becomes now.
    private func backdate(_ url: URL) {
        var times = [timeval(tv_sec: Self.year2020, tv_usec: 0), timeval(tv_sec: Self.year2020, tv_usec: 0)]
        _ = utimes(url.path, &times)
    }

    private func isRecent(_ date: Date?) -> Bool {
        date.map { abs($0.timeIntervalSinceNow) < 600 } ?? false
    }

    @Test func backdatedDownloadIsRecent() async throws {
        let tmp = try TemporaryDirectory()
        let file = try tmp.file("cache/download.bottle", size: 10_000)
        backdate(file)
        backdate(tmp.url.appendingPathComponent("cache"))

        #expect(isRecent(try await ScanEngine().measure(tmp.url.appendingPathComponent("cache")).newestModification))
        #expect(isRecent(try await ScanEngine().measure(file).newestModification))
    }

    @Test func deletionInsideASubfolderIsRecent() async throws {
        let tmp = try TemporaryDirectory()
        backdate(try tmp.file("cache/sub/old.bin", size: 10_000))
        try FileManager.default.removeItem(at: try tmp.file("cache/sub/download.part", size: 10))

        #expect(isRecent(try await ScanEngine().measure(tmp.url.appendingPathComponent("cache")).newestModification))
    }

    @Test func folderWithoutFilesHasItsOwnDate() async throws {
        let tmp = try TemporaryDirectory()
        let fresh = try tmp.directory("cache/fresh")

        #expect(isRecent(try await ScanEngine().measure(tmp.url.appendingPathComponent("cache")).newestModification))
        #expect(isRecent(try await ScanEngine().measure(fresh).newestModification))
    }

    /// In a fresh temporary folder every ctime is recent, so the tests above cannot tell which entry
    /// supplied the date. These two pin each source down.
    @Test func changeTimeIsReadForEveryEntry() throws {
        let tmp = try TemporaryDirectory()
        backdate(try tmp.file("cache/a.bin", size: 5000))
        backdate(try tmp.directory("cache/sub"))
        let fd = open(tmp.url.appendingPathComponent("cache").path, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        var listing = Listing()

        #expect(BulkReader(.changeTime).read(fd, into: &listing) == 0)

        #expect(listing.entries.count == 2)
        for entry in listing.entries {
            var info = stat()
            let path = tmp.url.appendingPathComponent("cache/" + String(decoding: listing.name(of: entry), as: UTF8.self)).path
            try #require(lstat(path, &info) == 0)
            #expect(entry.modified == Self.year2020)
            #expect(entry.changed == info.st_ctimespec.tv_sec)
        }
    }

    @Test func newestCoversFolderEntriesAndTheRoot() {
        var old = stat()
        old.st_mtimespec.tv_sec = Self.year2020
        old.st_ctimespec.tv_sec = Self.year2020
        var newer = old
        newer.st_ctimespec.tv_sec = Self.year2020 + 7

        var listing = Listing()
        for (name, type, changed) in [("a.bin", VREG, Self.year2020), ("sub", VDIR, Self.year2020 + 60)] {
            let entry = BulkEntry(
                nameStart: listing.names.count, nameLength: name.utf8.count, device: 1, type: UInt32(type.rawValue),
                modified: Self.year2020, changed: changed, inode: 9
            )
            listing.names.append(contentsOf: name.utf8)
            listing.entries.append(entry)
        }
        let sink = MeasureSink(root: old)
        var walkable: [Int32] = []
        sink.add(listing, to: 0, walkableNodes: &walkable)

        #expect(sink.measurement.newestModification == Date(timeIntervalSince1970: TimeInterval(Self.year2020 + 60)))
        #expect(MeasureSink(root: newer).measurement.newestModification == Date(timeIntervalSince1970: TimeInterval(Self.year2020 + 7)))
        #expect(MeasureSink.extras.contains(.changeTime), "the walk must ask for the ctime the sink reads")
    }
}
