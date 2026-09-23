import Darwin
import Foundation
import MacontrolCore

/// One line of the undo journal (JSON Lines, mode 0600).
public struct JournalEntry: Codable, Sendable, Hashable {
    public var batch: UUID
    public var date: Date
    public var originalPath: String
    public var trashedPath: String
    public var identity: FileIdentity
    public var allocated: UInt64
    public var restored: Bool

    public init(batch: UUID, date: Date, originalPath: String, trashedPath: String, identity: FileIdentity, allocated: UInt64, restored: Bool) {
        self.batch = batch
        self.date = date
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.identity = identity
        self.allocated = allocated
        self.restored = restored
    }
}

/// The undo journal: one JSON line per trashed item and one per restore, in a 0700 folder, mode 0600.
/// Lines are only ever appended and synced one by one, so a crash mid-batch loses at most the line
/// being written, and the item it describes still sits in the Trash under its own name (F-0036).
struct TrashJournal {
    let url: URL

    func openForAppending() throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Close a line torn by a crash, so the next entry starts on a line of its own.
        var last: UInt8 = 0x0A
        let size = lseek(fd, 0, SEEK_END)
        if size > 0 && pread(fd, &last, 1, size - 1) == 1 && last != 0x0A {
            try handle.write(contentsOf: Data([0x0A]))
        }
        return handle
    }

    static func append(_ entry: JournalEntry, to handle: FileHandle) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Trash entries newest first, each marked restored when a later restore line names it.
    /// A line that does not decode (the torn tail of a crash) is skipped.
    func entries() -> [JournalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var entries: [JournalEntry] = []
        var indexByMove: [String: Int] = [:]
        for line in data.split(separator: 0x0A) {
            guard let entry = try? Self.decoder.decode(JournalEntry.self, from: Data(line)) else { continue }
            let move = "\(entry.batch.uuidString)\n\(entry.trashedPath)"
            if !entry.restored {
                indexByMove[move] = entries.count
                entries.append(entry)
            } else if let index = indexByMove[move] {
                entries[index].restored = true
            }
        }
        return entries.reversed()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
