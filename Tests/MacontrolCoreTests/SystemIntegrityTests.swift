import Darwin
@testable import MacontrolCore
import Testing

@Suite struct SystemIntegrityTests {
    static let sealedRoot = SystemIntegrity.RootMount(flags: UInt32(MNT_RDONLY | MNT_ROOTFS | MNT_SNAPSHOT), mountedFrom: "/dev/disk3s3s1")

    @Test(arguments: [Int32(-1), 1, EPERM, Int32.min])
    func aFailedCheckMeansProtected(result: Int32) {
        let integrity = SystemIntegrity.read(csrCheck: { _ in result }, root: { Self.sealedRoot })
        #expect(integrity.filesystemProtected && integrity.authenticatedRoot && !integrity.allowsSealedRemoval)
    }

    /// A macOS without the SPI reads as protected; linking it directly would stop the app at launch (review 2, nit 7).
    @Test func aMissingCsrCheckMeansProtected() throws {
        #expect(SystemIntegrity.csrCheck(named: "csr_check_gone") == nil)
        let integrity = SystemIntegrity.read(csrCheck: SystemIntegrity.csrCheck(named: "csr_check_gone"), root: { Self.sealedRoot })
        #expect(integrity.filesystemProtected && integrity.authenticatedRoot && !integrity.allowsSealedRemoval)
        // On this Mac the lookup finds it, and it answers each bit with 0 or an error, never a crash.
        let check = try #require(SystemIntegrity.csrCheck())
        #expect([check(1 << 1), check(1 << 11)].allSatisfy { $0 == 0 || $0 == -1 })
    }

    @Test func eachProtectionIsItsOwnBit() {
        var asked: [UInt32] = []
        let both = SystemIntegrity.read(csrCheck: { asked.append($0); return 0 }, root: { Self.sealedRoot })
        #expect(asked.sorted() == [1 << 1, 1 << 11])
        #expect(!both.filesystemProtected && !both.authenticatedRoot && both.allowsSealedRemoval)

        let filesystemOnly = SystemIntegrity.read(csrCheck: { $0 == 1 << 1 ? 0 : -1 }, root: { Self.sealedRoot })
        #expect(!filesystemOnly.filesystemProtected && filesystemOnly.authenticatedRoot && !filesystemOnly.allowsSealedRemoval)
        let rootOnly = SystemIntegrity.read(csrCheck: { $0 == 1 << 11 ? 0 : -1 }, root: { Self.sealedRoot })
        #expect(rootOnly.filesystemProtected && !rootOnly.authenticatedRoot && !rootOnly.allowsSealedRemoval)
    }

    @Test func theSnapshotSuffixIsDropped() {
        let integrity = SystemIntegrity.read(csrCheck: { _ in -1 }, root: { Self.sealedRoot })
        #expect(integrity.rootIsSealedSnapshot)
        #expect(integrity.systemDevice == "/dev/disk3s3")
    }

    @Test func anUnreadableRootIsASealedSnapshotOfNoKnownDevice() {
        let integrity = SystemIntegrity.read(csrCheck: { _ in 0 }, root: { nil })
        #expect(integrity.rootIsSealedSnapshot && integrity.systemDevice == nil)
    }

    @Test(arguments: [
        ("/dev/disk3s3s1", true, "/dev/disk3s3"),
        ("/dev/disk12s10s2", true, "/dev/disk12s10"),
        ("/dev/disk3s3", false, "/dev/disk3s3"),
        ("com.apple.os.update-8EC5@/dev/disk1s5", true, "/dev/disk1s5"),
        // Ambiguous or hostile: no device, so the guide builds no command from it.
        ("/dev/disk3s3", true, nil),
        ("/dev/disk3s3s1", false, nil),
        ("/dev/disk3s3s1s2", true, nil),
        ("/dev/disk3", false, nil),
        ("/dev/disk3s3s1; rm -rf ~", true, nil),
        ("/dev/disk3s$1s1", true, nil),
        ("/dev/disk٣s3s1", true, nil),
        ("/dev/disks3s1", true, nil),
        ("map auto_home", false, nil),
        ("", true, nil),
    ] as [(String, Bool, String?)])
    func deviceNames(mountedFrom: String, snapshot: Bool, device: String?) {
        #expect(SystemIntegrity.systemDevice(mountedFrom: mountedFrom, isSnapshot: snapshot) == device)
    }

    /// Reads this Mac without judging its settings: SIP may be off on a build machine.
    @Test func thisMacHasASystemDevice() throws {
        let device = try #require(SystemIntegrity.current().systemDevice)
        #expect(device.wholeMatch(of: /\/dev\/disk\d+s\d+/) != nil, "\(device)")
    }
}
