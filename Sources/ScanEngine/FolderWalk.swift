import Darwin
import Foundation
import MacontrolCore

/// Consumes listings. Every call happens while the walk holds its lock, so a sink needs no locking.
protocol WalkSink: AnyObject, SendableMetatype {
    /// Adds the entries of the folder whose node is `folder`, and appends one node token for each
    /// entry with `isWalkable`, in listing order. The walk lists those folders next.
    func add(_ listing: Listing, to folder: Int32, walkableNodes: inout [Int32])
    /// The folder could not be listed completely.
    func flag(_ folder: Int32, _ flags: NodeFlags)
    /// Attributes the sink reads beyond the disk map's.
    static var extras: BulkReader.Extras { get }
}

/// Never download evicted iCloud files or folders while reading metadata, on every engine thread that
/// touches paths (F-0019). Per thread, so the rest of the app can still open such a file on purpose.
func stopDatalessMaterialization() {
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}

/// A walk root: an absolute path, the identity it must still have, and the sink's node for it.
struct WalkRoot {
    var path: String
    var identity: FileIdentity
    var node: Int32
}

/// The parallel, fd-relative folder walk (docs/ARCHITECTURE.md section 3).
///
/// A fixed pool of blocking threads (never the cooperative pool) takes folders from one LIFO stack.
/// A folder is opened with `openat` relative to its parent's descriptor, so path length never matters
/// (F-0008), and read with `getattrlistbulk`. A parent descriptor stays open while it still has child
/// folders to open. When the descriptor budget is used up, the shallowest idle descriptor is closed and
/// reopened later by walking names down from an open ancestor, verified by identity; a walk therefore
/// finishes exactly under any budget (F-0060). The walk ends when `pending` reaches 0; totals come from
/// the sink afterwards, never from a counter read at a barrier (F-0007).
final class FolderWalk<Sink: WalkSink>: @unchecked Sendable {
    // @unchecked: every mutable property is read and written only while `lock` is held.
    private let lock = NSCondition()
    private let sink: Sink
    private let workerCount: Int
    private let budget: Int

    private var folders: [Folder] = []
    private var freeFolders: [Int32] = []
    private var jobs: [Int32] = []
    private var pending = 0
    private var liveWorkers = 0
    private var idleWorkers = 0
    private var slotWaiters = 0
    private let finished = DispatchSemaphore(value: 0)
    private var openFolders: [Int32] = []
    private var openCount = 0
    private var cancelled = false
    /// Descriptors closed under budget pressure and opened again. Tests read it.
    private(set) var reopenCount = 0

    /// Seconds a folder keeps retrying `openat` while the process is out of descriptors.
    private let descriptorWait: TimeInterval = 5

    init(roots: [WalkRoot], sink: Sink, workers: Int, descriptorBudget: Int) {
        self.sink = sink
        budget = max(4, descriptorBudget)
        // Each worker holds at most one pinned parent and three reserved slots, so a budget of four per
        // worker guarantees that a waiting worker always finds an idle descriptor to close.
        workerCount = max(1, min(workers, budget / 4))
        for root in roots {
            let index = allocate(Folder(parent: -1, name: Array(root.path.utf8) + [0], identity: root.identity, node: root.node, depth: 0))
            jobs.append(index)
        }
        pending = roots.count
    }

    /// Runs the walk on its own threads and returns when it is finished or cancelled.
    /// `progress` runs with the lock held, every `interval` seconds while the walk lasts.
    func run(progressInterval interval: TimeInterval = 0.1, progress: ((Sink) -> Void)? = nil) {
        lock.lock()
        liveWorkers = workerCount
        lock.unlock()
        for _ in 0..<workerCount {
            let thread = Thread { [self] in work() }
            thread.name = "macontrol.scan"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        while finished.wait(timeout: .now() + interval) == .timedOut {
            guard let progress else { continue }
            lock.lock()
            progress(sink)
            lock.unlock()
        }
        lock.lock()
        for index in openFolders { close(folders[Int(index)].fd) }
        openFolders.removeAll()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }

    // MARK: Worker

    private func work() {
        stopDatalessMaterialization()
        let reader = BulkReader(Sink.extras)
        var listing = Listing()
        var walkable: [Int32] = []
        lock.lock()
        while let job = nextJob() {
            let fd = openFolder(job)
            guard fd >= 0 else {
                finish(job)
                continue
            }
            lock.unlock()
            listing.removeAll()
            let error = reader.read(fd, into: &listing)
            lock.lock()
            let node = folders[Int(job)].node
            walkable.removeAll(keepingCapacity: true)
            sink.add(listing, to: node, walkableNodes: &walkable)
            if error != 0 { sink.flag(node, Self.flags(for: error)) }
            push(children: listing, nodes: walkable, of: job)
            folders[Int(job)].pinned -= 1
            closeIfIdle(job)
            finish(job)
        }
        liveWorkers -= 1
        if liveWorkers == 0 { finished.signal() }
        lock.broadcast()
        lock.unlock()
    }

    private func nextJob() -> Int32? {
        while !cancelled {
            if let job = jobs.popLast() { return job }
            if pending == 0 { return nil }
            idleWorkers += 1
            lock.wait()
            idleWorkers -= 1
        }
        return nil
    }

    private func push(children listing: Listing, nodes: [Int32], of parent: Int32) {
        var next = nodes.makeIterator()
        let depth = folders[Int(parent)].depth + 1
        for entry in listing.entries where entry.isWalkable {
            guard let node = next.next() else { break }
            let child = allocate(Folder(
                parent: parent, name: Array(listing.name(of: entry)) + [0], identity: FileIdentity(device: entry.device, inode: entry.inode), node: node, depth: depth
            ))
            folders[Int(parent)].refs += 1
            folders[Int(parent)].unopened += 1
            jobs.append(child)
            pending += 1
        }
        if !nodes.isEmpty && idleWorkers > 0 { lock.broadcast() }
    }

    /// Opens `job`'s folder and pins it. Called and returns with the lock held; -1 means the sink was told why.
    private func openFolder(_ job: Int32) -> Int32 {
        guard reserve(1) else { return -1 }
        let parent = folders[Int(job)].parent
        var parentFD = AT_FDCWD
        if parent >= 0 {
            parentFD = pinDescriptor(of: parent)
            if parentFD < 0 {
                release(1)
                folders[Int(parent)].unopened -= 1
                closeIfIdle(parent)
                if !cancelled { sink.flag(folders[Int(job)].node, .incomplete) }
                return -1
            }
        }
        // A first open follows the listing that just named it; only roots and reopens can be stale.
        let (fd, failure) = openWaiting(at: parentFD, folders[Int(job)].name, verifying: parent < 0 ? folders[Int(job)].identity : nil)
        if parent >= 0 {
            folders[Int(parent)].pinned -= 1
            folders[Int(parent)].unopened -= 1
            closeIfIdle(parent)
        }
        guard fd >= 0 else {
            release(1)
            sink.flag(folders[Int(job)].node, Self.flags(for: failure))
            return -1
        }
        folders[Int(job)].fd = fd
        folders[Int(job)].pinned += 1
        register(job)
        return fd
    }

    /// The parent's descriptor, pinned so no one closes it; reopened by name from the nearest open
    /// ancestor if it was closed under budget pressure. Lock held throughout except while waiting for slots.
    private func pinDescriptor(of folder: Int32) -> Int32 {
        while folders[Int(folder)].fd < 0 {
            guard reserve(2) else { return -1 }  // the reopened descriptor plus one temporary
            if folders[Int(folder)].fd >= 0 {  // another worker reopened it while this one waited
                release(2)
                break
            }
            let fd = reopen(folder)
            if folders[Int(folder)].fd >= 0 {  // another worker reopened it while this one had the lock released
                if fd >= 0 { close(fd) }
                release(2)
                break
            }
            release(fd >= 0 ? 1 : 2)
            guard fd >= 0 else { return -1 }
            folders[Int(folder)].fd = fd
            register(folder)
            reopenCount += 1
        }
        folders[Int(folder)].pinned += 1
        return folders[Int(folder)].fd
    }

    /// Walks names down from the nearest open ancestor (or a root's path) to `folder`, holding at most
    /// two descriptors at a time. The ancestor stays pinned while the lock is released for each open.
    private func reopen(_ folder: Int32) -> Int32 {
        var chain: [Int32] = []
        var ancestor = folder
        while folders[Int(ancestor)].fd < 0 {
            chain.append(ancestor)
            guard folders[Int(ancestor)].parent >= 0 else { break }
            ancestor = folders[Int(ancestor)].parent
        }
        let anchor = folders[Int(ancestor)].fd >= 0 ? ancestor : -1
        var current = AT_FDCWD
        if anchor >= 0 {
            folders[Int(anchor)].pinned += 1
            current = folders[Int(anchor)].fd
        }
        defer {
            if anchor >= 0 {
                folders[Int(anchor)].pinned -= 1
                closeIfIdle(anchor)
            }
        }
        var owned = false
        for link in chain.reversed() {
            let (next, _) = openWaiting(at: current, folders[Int(link)].name, verifying: folders[Int(link)].identity)
            if owned { close(current) }
            guard next >= 0 else { return -1 }
            current = next
            owned = true
        }
        return current
    }

    /// `openat` with the lock released. While the process is out of descriptors (other walks, other code),
    /// frees this walk's idle ones or waits, for up to `descriptorWait` (F-0060). Called and returns with the lock held.
    private func openWaiting(at parent: Int32, _ name: [UInt8], verifying identity: FileIdentity?) -> (fd: Int32, error: Int32) {
        let deadline = Date().addingTimeInterval(descriptorWait)
        while true {
            lock.unlock()
            let fd = Self.openDirectory(at: parent, name, verifying: identity)
            let failure = fd < 0 ? errno : 0
            lock.lock()
            guard fd < 0, failure == EMFILE || failure == ENFILE, !cancelled, Date() < deadline else { return (fd, failure) }
            if !spillIdleFolder() { _ = lock.wait(until: Date().addingTimeInterval(0.01)) }
        }
    }

    private static func openDirectory(at parent: Int32, _ name: [UInt8], verifying identity: FileIdentity?) -> Int32 {
        let fd = name.withUnsafeBytes { name in
            openat(parent, name.assumingMemoryBound(to: CChar.self).baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0, let identity else { return fd }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode else {
            close(fd)
            errno = ENOENT  // replaced since it was listed: report it as gone, not as its successor
            return -1
        }
        return fd
    }

    private static func flags(for error: Int32) -> NodeFlags {
        error == EACCES || error == EPERM ? .unreadable : .incomplete
    }

    // MARK: Descriptor budget

    private func reserve(_ count: Int) -> Bool {
        while openCount + count > budget {
            if cancelled { return false }
            if !spillIdleFolder() {
                slotWaiters += 1
                lock.wait()
                slotWaiters -= 1
            }
        }
        openCount += count
        return true
    }

    private func release(_ count: Int) {
        openCount -= count
        if slotWaiters > 0 { lock.broadcast() }
    }

    /// Closes the shallowest open folder no worker is using. Deep folders are the ones LIFO needs next.
    private func spillIdleFolder() -> Bool {
        var best: Int32 = -1
        for index in openFolders where folders[Int(index)].pinned == 0 {
            if best < 0 || folders[Int(index)].depth < folders[Int(best)].depth { best = index }
        }
        guard best >= 0 else { return false }
        closeDescriptor(of: best)
        return true
    }

    private func closeIfIdle(_ folder: Int32) {
        let state = folders[Int(folder)]
        if state.fd >= 0 && state.pinned == 0 && state.unopened == 0 { closeDescriptor(of: folder) }
    }

    private func register(_ folder: Int32) {
        folders[Int(folder)].openSlot = Int32(openFolders.count)
        openFolders.append(folder)
    }

    private func closeDescriptor(of folder: Int32) {
        close(folders[Int(folder)].fd)
        folders[Int(folder)].fd = -1
        let slot = Int(folders[Int(folder)].openSlot)
        let moved = openFolders.removeLast()
        if moved != folder {
            openFolders[slot] = moved
            folders[Int(moved)].openSlot = Int32(slot)
        }
        folders[Int(folder)].openSlot = -1
        release(1)
    }

    // MARK: Folder records

    /// Drops the finished job's reference; a record is freed once its own job and all child records are done.
    private func finish(_ job: Int32) {
        pending -= 1
        var folder = job
        while true {
            folders[Int(folder)].refs -= 1
            guard folders[Int(folder)].refs == 0 else { break }
            if folders[Int(folder)].fd >= 0 { closeDescriptor(of: folder) }
            let parent = folders[Int(folder)].parent
            folders[Int(folder)].name = []
            freeFolders.append(folder)
            guard parent >= 0 else { break }
            folder = parent
        }
        if pending == 0 { lock.broadcast() }
    }

    private func allocate(_ folder: Folder) -> Int32 {
        if let index = freeFolders.popLast() {
            folders[Int(index)] = folder
            return index
        }
        folders.append(folder)
        return Int32(folders.count - 1)
    }
}

/// One folder the walk still needs, as a record in `FolderWalk.folders`.
private struct Folder {
    var parent: Int32
    /// NUL-terminated name relative to the parent; a root holds its absolute path.
    var name: [UInt8]
    var identity: FileIdentity
    var node: Int32
    var depth: Int32
    var fd: Int32 = -1
    var openSlot: Int32 = -1
    /// This folder's own job, plus one per child record still alive.
    var refs: Int32 = 1
    /// Child folders not opened yet; the descriptor is needed until this is 0.
    var unopened: Int32 = 0
    /// Workers using the descriptor right now; a pinned descriptor is never closed.
    var pinned: Int32 = 0

    init(parent: Int32, name: [UInt8], identity: FileIdentity, node: Int32, depth: Int32) {
        self.parent = parent
        self.name = name
        self.identity = identity
        self.node = node
        self.depth = depth
    }
}
