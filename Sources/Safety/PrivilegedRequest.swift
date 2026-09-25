import CryptoKit
import Foundation
import MacontrolCore

/// What the app asks the administrator helper to do: `request.json`, 0600 in a 0700 folder, bound to the call the user
/// authorized by its SHA-256 (DESIGN-debloat section 3.4). The helper is the authority; nothing here is trusted there.
/// There is no `restore` operation: an Undo that root carries out from user-writable records is a root write primitive.
public struct PrivilegedRequest: Codable, Sendable, Hashable {
    public var version: Int
    public var op: DeletionMode
    public var items: [Item]

    public struct Item: Codable, Sendable, Hashable {
        /// Canonical: the helper refuses a path that differs from its canonical form.
        public var path: String
        public var device: Int32
        public var inode: UInt64
        public var allocated: UInt64
        /// The app the item belongs to, for the first-component rule of `PrivilegedScope`. Absent for Clean items.
        public var bundleIdentifier: String?
        /// Removed only when nothing is at this path (an app's leftovers name its bundle).
        public var requiresGone: String?

        public init(path: String, identity: FileIdentity, allocated: UInt64 = 0, bundleIdentifier: String? = nil, requiresGone: String? = nil) {
            self.path = path
            device = identity.device
            inode = identity.inode
            self.allocated = allocated
            self.bundleIdentifier = bundleIdentifier
            self.requiresGone = requiresGone
        }

        var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
    }

    public init(op: DeletionMode, items: [Item]) {
        version = 1
        self.op = op
        self.items = items
    }

    static let maximumSize = 1 << 20
    static let maximumItems = 10_000

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Nil for anything but a version 1 request of 1 to 10,000 items in at most 1 MiB.
    public static func decode(_ data: Data) -> PrivilegedRequest? {
        guard data.count <= maximumSize, let request = try? JSONDecoder().decode(PrivilegedRequest.self, from: data),
              request.version == 1, (1...maximumItems).contains(request.items.count) else { return nil }
        return request
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One line of `result.jsonl`, written and fsync'd by the helper's detached child: `{"pid":N}` first, then one line per
/// item by index, then `{"done":true}`.
struct PrivilegedResultLine: Codable, Hashable {
    var pid: Int32?
    var index: Int?
    /// `trashed`, `deleted`, `refused` or `failed`.
    var status: String?
    /// Where the item is in the Trash: a trashed item, a failed one that stayed there, or the rest of a partial one.
    var to: String?
    var reason: String?
    /// The path a `protectedLocation` or `holdsLocked` reason names.
    var detail: String?
    var message: String?
    /// A failed permanent delete that removed some of it: History records it as deleted.
    var partial: Bool?
    /// A trashed or deleted LaunchDaemon plist whose job the helper did not boot out: it may run until the next restart.
    var note: String?
    var done: Bool?

    static func outcome(_ index: Int, _ outcome: HelperOutcome) -> PrivilegedResultLine {
        var line = PrivilegedResultLine(index: index)
        switch outcome {
        case .trashed(let to): (line.status, line.to) = ("trashed", to)
        case .deleted: line.status = "deleted"
        case .refused(let reason):
            line.status = "refused"
            (line.reason, line.detail) = switch reason {
            case .protectedLocation(let path): ("protectedLocation", path)
            case .holdsLocked(let path): ("holdsLocked", path)
            case .systemProtected: ("systemProtected", nil)
            case .locked: ("locked", nil)
            case .identityChanged: ("identityChanged", nil)
            case .missing: ("missing", nil)
            case .needsCloudConfirmation: ("needsCloudConfirmation", nil)
            case .needsAdministrator: ("needsAdministrator", nil)
            case .notImplemented: ("notImplemented", nil)
            }
        case .failed(let message, let to, let partial): (line.status, line.message, line.to, line.partial) = ("failed", message, to, partial ? true : nil)
        }
        return line
    }

    /// The outcome for `url`, or nil for a line that is not an item's, or does not read as one.
    func outcome(for url: URL) -> TrashOutcome? {
        switch status {
        case "trashed": to.map { .trashed(original: url, trashedTo: URL(fileURLWithPath: $0)) }
        case "deleted": .deleted(original: url)
        case "failed": .failed(url, message: message ?? "The administrator helper could not remove it.")
        case "refused": refusal.map { .refused(url, $0) }
        default: nil
        }
    }

    private var refusal: RefusalReason? {
        switch reason {
        case "protectedLocation": detail.map { .protectedLocation($0) }
        case "holdsLocked": detail.map { .holdsLocked($0) }
        case "systemProtected": .systemProtected
        case "locked": .locked
        case "identityChanged": .identityChanged
        case "missing": .missing
        case "needsCloudConfirmation": .needsCloudConfirmation
        case "needsAdministrator": .needsAdministrator
        default: nil
        }
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

/// What the helper did with one item.
enum HelperOutcome: Hashable {
    case trashed(to: String)
    case deleted
    case refused(RefusalReason)
    case failed(String, to: String? = nil, partial: Bool = false)
}
