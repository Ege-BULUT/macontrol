import Foundation
import Safety
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

    init() throws {
        tmp = try TemporaryDirectory()
        home = try tmp.directory("home")
        trash = try tmp.directory("Trash")
        journal = tmp.url.appendingPathComponent("Application Support/Macontrol/trash-journal.jsonl")
    }

    /// Every URL the backend was asked to move, in order.
    var backendCalls: [URL] { lock.withLock { moved } }

    func service(home: URL? = nil) -> TrashService {
        TrashService(journalURL: journal, backend: backend, home: home ?? self.home)
    }

    /// Like Finder's Trash: the item keeps its name, with a suffix only when the name is taken.
    private var backend: TrashBackend {
        TrashBackend { [self] url in
            lock.withLock { moved.append(url) }
            guard url.path.hasPrefix(tmp.url.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
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
