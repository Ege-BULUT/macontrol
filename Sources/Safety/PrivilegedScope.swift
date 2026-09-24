import Darwin
import Foundation

/// The only places the administrator helper may act (DESIGN-debloat section 3.5 step 1), checked on the canonical path
/// before the v1 policy. Everything else is refused as `.protectedLocation`. The app applies it too, so an item outside
/// it never reaches the password dialog.
public enum PrivilegedScope {
    /// Folders of `/Library` and `<home>/Library` whose items root may remove, never the folder itself.
    static let libraryFolders: Set<String> = [
        "Application Support", "Audio", "Caches", "Developer", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences",
        "PrivilegedHelperTools",
    ]

    /// The `/Library/…` content of Apple's apps in `apple-apps.json` (section 4.3), allowed although its names start
    /// with `Apple`. Kept here, in the code root runs, not read from the catalog; a debloat-catalog test fails when the
    /// catalog lists a `/Library` path this lacks.
    public static let appleContent = [
        "/Library/Application Support/GarageBand",
        "/Library/Application Support/Logic",
        "/Library/Application Support/ProApps",
        "/Library/Audio/Apple Loops/Apple",
        "/Library/Audio/Apple Loops Index",
        "/Library/Audio/Impulse Responses/Apple",
        "/Library/Developer/CoreDevice",
        "/Library/Developer/CoreSimulator/Caches",
        "/Library/Developer/CoreSimulator/Profiles",
        "/Library/Developer/DeveloperDiskImages",
        "/Library/Developer/DeviceKit",
        "/Library/Developer/PrivateFrameworks",
    ]

    /// Why root must not act on `path`, or nil when it lies in the allowlist. `path` is canonical; `home` is the
    /// requesting user's canonical home; `bundleIdentifier` is the app the item belongs to, if any. `systemRoot` is `/`
    /// except in tests.
    public static func refusal(
        canonical path: String, home: String, bundleIdentifier: String?, systemRoot: String = "/"
    ) -> RefusalReason? {
        let root = systemRoot == "/" ? "" : systemRoot
        if let parts = components(of: path, below: root + "/Applications") {
            let bundle = parts.count == 1 || (parts.count == 2 && !parts[0].hasSuffix(".app"))
            return bundle && parts.last!.count > 4 && parts.last!.hasSuffix(".app") ? nil : .protectedLocation(path)
        }
        if let parts = components(of: path, below: root + "/private/var/db/receipts") {
            return parts.count == 1 && isReceipt(parts[0]) && isRegularFile(path) ? nil : .protectedLocation(path)
        }
        for library in [root + "/Library", home + "/Library"] {
            guard let parts = components(of: path, below: library) else { continue }
            guard parts.count >= 2, libraryFolders.contains(parts[0]) else { return .protectedLocation(path) }
            let isAppleContent = appleContent.contains { path == root + $0 || path.hasPrefix(root + $0 + "/") }
            if !isAppleContent && looksLikeApple(parts[1]) && !belongs(parts[1], to: bundleIdentifier) {
                return .protectedLocation(path)
            }
            return nil
        }
        return .protectedLocation(path)
    }

    /// The components of `path` below `base`; nil when it is not below it. Empty, `.` and `..` components never pass.
    private static func components(of path: String, below base: String) -> [String]? {
        guard path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.contains { $0.isEmpty || $0 == "." || $0 == ".." } ? [] : parts
    }

    /// macOS's own configuration: `com.apple.loginwindow.plist`, `Apple/ParentalControls`, `.GlobalPreferences.plist`.
    private static func looksLikeApple(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("com.apple.") || lowered.hasPrefix("apple") || lowered.hasPrefix(".")
    }

    /// `name` is the app's reverse-DNS identifier, or starts with it and a dot (`com.apple.dt.Xcode.plist`). Three
    /// components at least, so `com.apple` never claims all of Apple.
    private static func belongs(_ name: String, to bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier?.lowercased(), id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+){2,}/) != nil else {
            return false
        }
        let lowered = name.lowercased()
        return lowered == id || lowered.hasPrefix(id + ".")
    }

    /// `<id>.plist` or `<id>.bom`, as `pkgutil --forget` removes them.
    private static func isReceipt(_ name: String) -> Bool {
        let id = name.hasSuffix(".plist") ? name.dropLast(6) : name.hasSuffix(".bom") ? name.dropLast(4) : ""
        return id.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
