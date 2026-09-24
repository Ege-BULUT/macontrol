import Darwin
import Foundation
@testable import Safety
import TestSupport

/// A home, a Trash and a journal inside one temporary folder. The service's backend refuses to
/// move anything from outside that folder, so a test can never trash real files.
final class TrashFixture: @unchecked Sendable {
    let tmp: TemporaryDirectory
    let home: URL
    let trash: URL
    let journal: URL
    private let lock = NSLock()
    private var moved: [URL] = []
    private var mounts: [URL] = []

    init() throws {
        tmp = try TemporaryDirectory()
        home = try tmp.directory("home")
        trash = try tmp.directory("Trash")
        journal = tmp.url.appendingPathComponent("Application Support/Macontrol/trash-journal.jsonl")
    }

    deinit {
        for mount in mounts { try? Self.hdiutil("detach", "-force", mount.path) }
    }

    /// Mounts a fresh 20 MB disk image at `relative`, inside the test's folder, until the fixture goes.
    func attachDiskImage(_ fileSystem: String, at relative: String) throws -> URL {
        let mount = try tmp.directory(relative)
        let image = tmp.url.appendingPathComponent("\(UUID().uuidString).dmg").path
        try Self.hdiutil("create", "-quiet", "-size", "20m", "-fs", fileSystem, image)
        try Self.hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image)
        lock.withLock { mounts.append(mount) }
        return mount
    }

    private static func hdiutil(_ arguments: String...) throws {
        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: arguments)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    /// Every URL the backend was asked to move, in order.
    var backendCalls: [URL] { lock.withLock { moved } }

    func service(home: URL? = nil) -> TrashService {
        TrashService(journalURL: journal, backend: backend, home: home ?? self.home)
    }

    /// A service whose remover calls `hook` before each item and entry, and stops the test process before it could
    /// touch anything outside this fixture. `route` stands in for the administrator helper.
    func guardedService(
        hook: (@Sendable (_ item: String, _ relative: String) -> Void)? = nil,
        route: TrashService.Route? = nil
    ) -> TrashService {
        let root = tmp.url.path + "/"
        let engine = RemovalEngine { item, relative in
            precondition(item.hasPrefix(root), "a permanent delete outside the fixture: \(item)")
            hook?(item, relative)
        }
        let unrouted: TrashService.Route = { items, _, _, _, _, _, _ in items.map { .refused($0.url, .needsAdministrator) } }
        return TrashService(journalURL: journal, backend: backend, home: home, engine: engine, route: route ?? unrouted)
    }

    /// Like Finder's Trash: the item keeps its name, with a suffix only when the name is taken, and an item on a disk
    /// image mounted in the fixture goes to a `Trash` folder on that image, as each volume has its own Trash.
    private var backend: TrashBackend {
        TrashBackend { [self] url in
            lock.withLock { moved.append(url) }
            guard url.path.hasPrefix(tmp.url.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
            var trash = trash
            if let volume = Self.mountPoint(of: url.deletingLastPathComponent()), volume.hasPrefix(tmp.url.path + "/") {
                trash = URL(fileURLWithPath: volume).appendingPathComponent("Trash")
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            }
            var destination = trash.appendingPathComponent(url.lastPathComponent)
            var copy = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = trash.appendingPathComponent("\(url.lastPathComponent) \(copy)")
                copy += 1
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private static func mountPoint(of folder: URL) -> String? {
        var volume = statfs()
        guard statfs(folder.path, &volume) == 0 else { return nil }
        return withUnsafeBytes(of: volume.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension TrashOutcome {
    var refusal: RefusalReason? {
        if case .refused(_, let reason) = self { reason } else { nil }
    }

    /// Original and destination paths; URLs of folders differ by a trailing slash.
    var paths: [String] {
        if case .trashed(let original, let destination) = self { [original.path, destination.path] } else { [] }
    }

    var trashedTo: URL? {
        if case .trashed(_, let destination) = self { destination } else { nil }
    }
}

extension RefusalReason {
    var isProtectedLocation: Bool {
        if case .protectedLocation = self { true } else { false }
    }
}
