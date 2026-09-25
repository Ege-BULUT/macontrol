import Foundation
import os
import Safety

/// What one of Apple's removable apps installs outside its bundle (DESIGN-debloat section 4.3).
public struct AppleProfile: Decodable, Sendable {
    /// The note on every item of a profile that is not `verified`.
    public static let unverifiedNote = "macontrol hasn't checked this location on a real install yet."

    public struct Item: Decodable, Sendable {
        /// `/Library/<folder>/…` or `~/Library/…`.
        public var path: String
        /// A reason to hold the item back. It is shown, and turns off preselection.
        public var note: String?
        /// Other apps that use the item. It is never preselected.
        public var sharedWith: [String]

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            note = try values.decodeIfPresent(String.self, forKey: .note)
            sharedWith = try values.decodeIfPresent([String].self, forKey: .sharedWith) ?? []
        }

        private enum CodingKeys: String, CodingKey { case path, note, sharedWith }
    }

    /// Something the app installed where even root can't change it (SIP), shown as "Kept by macOS" when it exists.
    public struct Kept: Decodable, Sendable {
        /// How the plan's note for it starts.
        public static let notePrefix = "Kept by macOS: "
        public var name: String
        public var path: String
    }

    public var bundleIdentifier: String
    public var name: String
    /// False until the profile's paths have been checked on a real install: then none of its items is preselected.
    public var verified: Bool
    public var evidence: String
    public var items: [Item]
    /// Package ids whose receipt (`/private/var/db/receipts/<id>.plist` and `.bom`) goes with the app.
    public var receipts: [String]
    /// The app's simulator runtimes are deleted with CoreSimulator's own tool (`SimRuntime`), first.
    public var simulatorRuntimes: Bool
    /// The user's own work: nothing at, inside or around these paths is ever listed.
    public var neverTouch: [String]
    public var keptByMacOS: [Kept]

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        name = try values.decode(String.self, forKey: .name)
        verified = try values.decode(Bool.self, forKey: .verified)
        evidence = try values.decode(String.self, forKey: .evidence)
        items = try values.decode([Item].self, forKey: .items)
        receipts = try values.decodeIfPresent([String].self, forKey: .receipts) ?? []
        simulatorRuntimes = try values.decodeIfPresent(Bool.self, forKey: .simulatorRuntimes) ?? false
        neverTouch = try values.decodeIfPresent([String].self, forKey: .neverTouch) ?? []
        keptByMacOS = try values.decodeIfPresent([Kept].self, forKey: .keptByMacOS) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, verified, evidence, items, receipts, simulatorRuntimes, neverTouch, keptByMacOS
    }
}

/// The bundled `apple-apps.json`. It is compiled into the signed app, never read from a place the user can write
/// (F-0021), and validated when loaded: a file that breaks any rule gives no profiles at all, and the generic
/// leftover search still works.
public struct AppleProfiles: Decodable, Sendable {
    public var version: Int
    public var profiles: [AppleProfile]

    public init(version: Int = 1, profiles: [AppleProfile] = []) {
        self.version = version
        self.profiles = profiles
    }

    public func profile(for bundleIdentifier: String?) -> AppleProfile? {
        profiles.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Every `/Library/…` item path. Each one must also be in the helper's `PrivilegedScope.appleContent`.
    public var systemLibraryPaths: [String] {
        Array(Set(profiles.flatMap { $0.items.map(\.path) }.filter { $0.hasPrefix("/Library/") })).sorted()
    }

    public static let bundled = load(bundledData(), home: FileManager.default.homeDirectoryForCurrentUser)

    /// The decoded catalog if it keeps every rule, otherwise no profiles.
    public static func load(_ data: Data?, home: URL) -> AppleProfiles {
        let log = Logger(subsystem: "Macontrol", category: "Uninstaller")
        guard let data, let catalog = try? JSONDecoder().decode(AppleProfiles.self, from: data) else {
            log.error("apple-apps.json is missing or unreadable; no Apple app profiles")
            return AppleProfiles()
        }
        let problems = catalog.problems(home: home)
        guard problems.isEmpty else {
            log.error("apple-apps.json refused: \(problems.joined(separator: "; "), privacy: .public)")
            return AppleProfiles()
        }
        return catalog
    }

    private static func bundledData() -> Data? {
        // As CleanupCatalog: in the .app the resource bundle sits in Contents/Resources (scripts/bundle-app.sh).
        let resources = Bundle.main.url(forResource: "macontrol_Uninstaller", withExtension: "bundle").flatMap(Bundle.init(url:))
            ?? Bundle.module
        return resources.url(forResource: "apple-apps", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    // MARK: Validation (section 4.3)

    /// The `/Library` folders the privileged helper may act in (section 3.5).
    /// Not LaunchAgents or LaunchDaemons: a job plist is found and booted out by the launchd search, never trashed as
    /// profile content while its job runs (review 2, 11).
    static let systemFolders = ["Application Support", "Audio", "Caches", "Developer", "Logs", "Preferences", "PrivilegedHelperTools"]

    /// Never listed, whatever the file says: iCloud and cloud folders (section 4.5), the personal databases that
    /// always go to the Trash (D4), the live network configuration root must not touch (D7), and the user's launchd
    /// jobs (as above).
    static let refusedRoots = [
        "~/Library/Mobile Documents", "~/Library/CloudStorage", "~/Library/Application Support/MobileSync",
        "~/Library/Application Support/AddressBook", "~/Library/Calendars", "~/Library/Safari",
        "~/Library/Containers/com.apple.Safari", "~/Library/Containers/com.apple.Notes",
        "~/Library/Group Containers/group.com.apple.notes", "~/Library/LaunchAgents", "/Library/Preferences/SystemConfiguration",
    ]

    /// Every rule this catalog breaks, one line each. Empty means it may be used.
    public func problems(home: URL) -> [String] {
        var found: [String] = version == 1 ? [] : ["version \(version) is not 1"]
        var seen = Set<String>()
        for profile in profiles {
            let app = profile.bundleIdentifier
            if !Self.isReverseDNS(app) { found.append("\(app): the bundle identifier is not reverse-DNS") }
            if !seen.insert(app).inserted { found.append("\(app): listed twice") }
            for path in profile.neverTouch where !path.hasPrefix("~/") && !path.hasPrefix("/") || Self.hasBadComponent(path) {
                found.append("\(app): neverTouch \(path) is not a plain absolute or ~/ path")
            }
            for item in profile.items {
                if let problem = Self.itemProblem(item.path, home: home) { found.append("\(app): \(item.path) \(problem)") }
                if let kept = profile.neverTouch.first(where: { Self.overlaps(item.path, $0) }) {
                    found.append("\(app): \(item.path) overlaps neverTouch \(kept)")
                }
                if let note = item.note, note.isEmpty || note.count > 200 { found.append("\(app): \(item.path) has a note of \(note.count) characters") }
                for other in item.sharedWith where !Self.isReverseDNS(other) {
                    found.append("\(app): \(item.path) is shared with \(other), which is not reverse-DNS")
                }
            }
            for receipt in profile.receipts where !Self.isReceiptID(receipt) {
                found.append("\(app): receipt \(receipt) is not [A-Za-z0-9._-]+")
            }
            for kept in profile.keptByMacOS where !kept.path.hasPrefix("/Library/Apple/") || Self.hasBadComponent(kept.path)
                || kept.name.isEmpty || kept.name.count > 80 {
                found.append("\(app): keptByMacOS \(kept.path) is not a plain path in /Library/Apple with a short name")
            }
        }
        return found
    }

    static func itemProblem(_ path: String, home: URL) -> String? {
        let relative: Substring
        if path.hasPrefix("~/Library/") {
            relative = path.dropFirst(2)
        } else if systemFolders.contains(where: { path.hasPrefix("/Library/\($0)/") }) {
            relative = path.dropFirst()
        } else {
            return "is not in ~/Library or one of /Library/{\(systemFolders.joined(separator: ", "))}"
        }
        if hasBadComponent(path) { return "has an empty, \".\", \"..\" or \"*\" component" }
        if relative.split(separator: "/").count < 3 { return "has fewer than three components" }
        if let root = refusedRoots.first(where: { overlaps(path, $0) }) { return "overlaps \(root), which is never listed" }
        // What exists is checked as Safety sees it. A path whose folder does not exist can't be listed either.
        let url = path.hasPrefix("~/") ? home.appendingPathComponent(String(relative)) : URL(fileURLWithPath: path)
        if case .protectedLocation? = ProtectedPaths.refusal(for: url, home: home) { return "is or contains a protected folder" }
        return nil
    }

    static func hasBadComponent(_ path: String) -> Bool {
        let components = (path.hasPrefix("~/") ? path.dropFirst(2) : path.dropFirst()).split(separator: "/", omittingEmptySubsequences: false)
        return components.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("*") || $0.contains("\0") }
    }

    /// Equal, inside or containing, ignoring case as APFS does.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    static func isReverseDNS(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    }

    static func isReceiptID(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
