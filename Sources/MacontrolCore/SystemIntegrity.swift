import Darwin

/// What macOS lets anyone do to its own apps (DESIGN-debloat section 5.1). Read-only: two calls, no subprocess.
/// Any failure reads as protected.
public struct SystemIntegrity: Sendable, Equatable {
    /// System Integrity Protection guards the file system (`CSR_ALLOW_UNRESTRICTED_FS`, bit 1, is not allowed).
    public var filesystemProtected: Bool
    /// Only a sealed system snapshot may boot (`CSR_ALLOW_UNAUTHENTICATED_ROOT`, bit 11, is not allowed).
    public var authenticatedRoot: Bool
    /// `statfs("/")` reports `MNT_SNAPSHOT`: macOS runs from a snapshot of the system volume.
    public var rootIsSealedSnapshot: Bool
    /// The system volume below the booted snapshot, `/dev/disk3s3` for `/dev/disk3s3s1`. Nil when unreadable.
    public var systemDevice: String?

    /// True only when both protections are off, the state in which the sealed volume can be changed at all.
    public var allowsSealedRemoval: Bool { !filesystemProtected && !authenticatedRoot }

    public init(filesystemProtected: Bool = true, authenticatedRoot: Bool = true, rootIsSealedSnapshot: Bool = true, systemDevice: String? = nil) {
        self.filesystemProtected = filesystemProtected
        self.authenticatedRoot = authenticatedRoot
        self.rootIsSealedSnapshot = rootIsSealedSnapshot
        self.systemDevice = systemDevice
    }

    public static func current() -> SystemIntegrity {
        read(csrCheck: csrCheck(), root: rootMount)
    }

    /// `csr_check`, an SPI in libsystem_kernel with no SDK header (feasibility-apple-apps D1-D2), looked up at run
    /// time: a macOS without it reads as protected instead of stopping the app at launch. 0 means the bit is allowed.
    static func csrCheck(named name: String = "csr_check") -> ((UInt32) -> Int32)? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
        let check = unsafeBitCast(symbol, to: (@convention(c) (UInt32) -> Int32).self)
        return { check($0) }
    }

    /// The flags and source of the root mount.
    struct RootMount {
        var flags: UInt32
        var mountedFrom: String
    }

    /// `csrCheck` stands in for `csr_check`: only 0 counts as "allowed", and no function at all means protected.
    /// A nil root reads as a sealed snapshot of an unknown device.
    static func read(csrCheck: ((UInt32) -> Int32)?, root: () -> RootMount?) -> SystemIntegrity {
        let mount = root()
        let snapshot = mount.map { $0.flags & UInt32(MNT_SNAPSHOT) != 0 } ?? true
        return SystemIntegrity(
            filesystemProtected: csrCheck?(1 << 1) != 0,
            authenticatedRoot: csrCheck?(1 << 11) != 0,
            rootIsSealedSnapshot: snapshot,
            systemDevice: mount.flatMap { systemDevice(mountedFrom: $0.mountedFrom, isSnapshot: snapshot) }
        )
    }

    /// The volume device under the root mount. A snapshot mount names `/dev/diskNsMsK` (or `name@/dev/diskNsM` on
    /// older systems); the volume is `/dev/diskNsM`. Anything else is nil, so no command is ever built from a guess.
    static func systemDevice(mountedFrom: String, isSnapshot: Bool) -> String? {
        let source = mountedFrom.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let named = mountedFrom.contains("@")
        guard source.hasPrefix("/dev/disk") else { return nil }
        let parts = source.dropFirst("/dev/disk".count).split(separator: "s", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        switch (parts.count, isSnapshot && !named) {
        case (3, true): return "/dev/disk\(parts[0])s\(parts[1])"
        case (2, false): return source
        default: return nil
        }
    }

    private static func rootMount() -> RootMount? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        let from = withUnsafeBytes(of: &info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return RootMount(flags: info.f_flags, mountedFrom: from)
    }
}
