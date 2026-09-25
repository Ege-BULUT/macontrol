import Darwin
import Foundation
import MacontrolCore
import Safety
import Testing

/// Acceptance 8 (bench, not a test): an Xcode-shaped tree of 7,000 folders x 21 files (154,070 entries, one file in
/// ten holding 8 KiB), cloned with `clonefile` and deleted permanently: Trash move, then the erase.
/// `MACONTROL_BENCH_PERMANENT=1 swift test --filter PermanentBenchTests`; about 120 MB in the temporary folder.
@Suite struct PermanentBenchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACONTROL_BENCH_PERMANENT"] == "1"))
    func a150kEntryCloneIsDeleted() async throws {
        let fixture = try TrashFixture()
        let template = try fixture.tmp.directory("template")
        let block = [UInt8](repeating: 7, count: 8192)
        var files = 0
        for folder in 0..<7000 {
            let path = template.path + "/d\(folder / 100)/d\(folder)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            for index in 0..<21 {
                let file = openat(fd, "f\(index)", O_WRONLY | O_CREAT, 0o644)
                if files % 10 == 0 { _ = write(file, block, block.count) }
                close(file)
                files += 1
            }
            close(fd)
        }
        let target = fixture.home.appendingPathComponent("Library/Caches/bench")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(template.path, target.path, 0) == 0)

        let clock = ContinuousClock()
        let start = clock.now
        let report = await fixture.service().remove([TrashItem(url: target, expectedIdentity: FileIdentity(url: target))], mode: .permanent)
        let elapsed = clock.now - start

        #expect(report.outcomes == [.deleted(original: target)])
        print("BENCH permanent delete of \(files) files in 7,070 folders (clone): \(elapsed)")
    }
}
