import Darwin
import Foundation
import MacontrolCore

public struct ScanOptions: Sendable {
    /// Walker threads. `nil` lets the engine pick; see `resolvedWorkerCount`.
    public var workerCount: Int?
    /// Directory descriptors one walk may hold open. `nil` takes a quarter of the process's open-file limit,
    /// so the cleaner's parallel measures and a scan fit together. Any value gives the same result; a
    /// small one only costs reopening folders by name.
    public var descriptorBudget: Int?

    public init(workerCount: Int? = nil, descriptorBudget: Int? = nil) {
        self.workerCount = workerCount
        self.descriptorBudget = descriptorBudget
    }

    /// 1.5 threads per active core, at most 12, halved in Low Power Mode or at serious thermal state.
    /// The walk waits on metadata I/O far more than it computes once a tree outgrows the vnode cache
    /// (kern.maxvnodes is 120k on an 8 GB Mac): on the 311k-node bench fixture 8 threads took 0.99 s,
    /// 12 took 0.69 s (dua: 0.68 s) and 16 took 0.72 s; on a cached 28k-node tree 8 and 12 were equal.
    var resolvedWorkerCount: Int {
        if let workerCount { return max(1, workerCount) }
        let info = ProcessInfo.processInfo
        let count = min(info.activeProcessorCount * 3 / 2, 12)
        let throttled = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        return max(1, throttled ? count / 2 : count)
    }

    var resolvedDescriptorBudget: Int {
        if let descriptorBudget { return descriptorBudget }
        _ = Self.raisedFileLimit
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 64 }
        return Int(min(limit.rlim_cur / 4, 1024))
    }

    /// A GUI app starts with a soft limit of 256 descriptors; raise it once to what the kernel allows
    /// (F-0060). Walks share the process, and running out only costs waiting, never bytes.
    private static let raisedFileLimit: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < rlim_t(OPEN_MAX) else { return }
        limit.rlim_cur = min(limit.rlim_max, rlim_t(OPEN_MAX))
        setrlimit(RLIMIT_NOFILE, &limit)
    }()
}

public struct ScanProgress: Sendable, Equatable {
    public var filesVisited: Int
    public var bytesVisited: UInt64
    public var currentPath: String?

    public init(filesVisited: Int, bytesVisited: UInt64, currentPath: String?) {
        self.filesVisited = filesVisited
        self.bytesVisited = bytesVisited
        self.currentPath = currentPath
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case completed(ScanTree)
}

public enum ScanError: Error, Equatable {
    /// `scan` needs a folder; use `measure` for a file.
    case notADirectory(URL)
}

/// Every size macontrol shows comes from here. All file-system work runs on the engine's own threads.
public final class ScanEngine: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Streams progress (at most about 10 events a second), then exactly one `.completed` tree.
    /// Ending the stream or cancelling the consumer stops the walk.
    ///
    /// Scanning "/" or /System/Volumes/Data scans the startup disk as the user sees it: the Data volume is
    /// walked once and its entries are shown at their firmlinked paths under a "/" root, plus the Data-only
    /// folders under /System/Volumes/Data (F-0031, F-0005).
    public func scan(_ root: URL) -> AsyncThrowingStream<ScanEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ScanEvent, any Error>.makeStream()
        let cancellation = Cancellation()
        continuation.onTermination = { _ in cancellation.cancel() }
        let options = options
        Thread {
            stopDatalessMaterialization()
            do {
                let tree = try Self.buildTree(root, options: options, cancellation: cancellation) { continuation.yield(.progress($0)) }
                continuation.yield(.completed(tree))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }.start()
        return stream
    }

    /// Sizes of one item without keeping a tree. Used by the cleaner and the uninstaller.
    public func measure(_ url: URL) async throws -> ItemMeasurement {
        let options = options
        return try await Self.onOwnThread { cancellation in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                let dataless = info.st_flags & UInt32(SF_DATALESS) != 0
                return ItemMeasurement(
                    allocated: dataless ? 0 : UInt64(info.st_blocks) * 512, logical: UInt64(info.st_size), fileCount: 1,
                    newestModification: Date(timeIntervalSince1970: TimeInterval(info.newestChange)), isIncomplete: false
                )
            }
            let sink = MeasureSink(root: info)
            let root = WalkRoot(path: url.path, identity: FileIdentity(device: info.st_dev, inode: info.st_ino), node: 0)
            try Self.walk([root], sink: sink, options: options, cancellation: cancellation)
            return sink.measurement
        }
    }

    /// What trashing `urls` together and emptying the Trash would free right now (F-0004): private bytes,
    /// hard links and clone groups only when every member is selected. Reads the APFS extended attributes,
    /// which the map scan skips because they cost ~65% more kernel time.
    public func reclaimable(_ urls: [URL]) async throws -> ReclaimEstimate {
        let options = options
        return try await Self.onOwnThread { cancellation in
            let selection = Selection(urls)
            let sink = ReclaimSink()
            selection.readFiles(into: sink)
            try Self.walk(selection.folders, sink: sink, options: options, cancellation: cancellation)
            return sink.estimate
        }
    }

    // MARK: Plumbing

    static func buildTree(
        _ root: URL, options: ScanOptions, cancellation: Cancellation, progress: @escaping (ScanProgress) -> Void
    ) throws -> ScanTree {
        guard let resolved = realpath(root.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let path = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(root) }
        let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        let layout = DataVolumeLayout.forStartupDisk(path)
        let walkRoot = layout.map { WalkRoot(path: DataVolumeLayout.dataRoot, identity: $0.dataIdentity, node: 0) }
            ?? WalkRoot(path: path, identity: identity, node: 0)
        let tree = layout.map { ScanTree(rootURL: URL(fileURLWithPath: "/"), rootIdentity: $0.rootIdentity) }
            ?? ScanTree(rootURL: root, rootIdentity: identity)
        let sink = TreeSink(tree: tree, dataVolume: layout)
        try walk([walkRoot], sink: sink, options: options, cancellation: cancellation) { progress($0.progress) }
        sink.tree.finalizeTotals()
        return sink.tree
    }

    static func walk<Sink: WalkSink>(
        _ roots: [WalkRoot], sink: Sink, options: ScanOptions, cancellation: Cancellation,
        progress: ((Sink) -> Void)? = nil
    ) throws {
        guard !roots.isEmpty else { return }
        let walk = FolderWalk(
            roots: roots, sink: sink,
            workers: options.resolvedWorkerCount, descriptorBudget: options.resolvedDescriptorBudget
        )
        cancellation.onCancel { walk.cancel() }
        walk.run(progress: progress)
        if cancellation.isCancelled { throw CancellationError() }
    }

    /// Runs blocking file-system work on a thread of its own, never on the cooperative pool.
    private static func onOwnThread<T: Sendable>(_ work: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread {
                    stopDatalessMaterialization()
                    continuation.resume(with: Result { try work(cancellation) })
                }.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Carries a consumer's cancellation to a walk that may not exist yet.
final class Cancellation: @unchecked Sendable {
    // @unchecked: both properties are guarded by `lock`.
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let handler = lock.withLock {
            cancelled = true
            return self.handler
        }
        handler?()
    }

    /// Runs `handler` on cancellation, or right away if that already happened.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock {
            self.handler = handler
            return cancelled
        }
        if runNow { handler() }
    }
}
