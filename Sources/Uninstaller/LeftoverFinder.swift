import Foundation

/// One path attributed to the app, before it is measured.
struct LeftoverCandidate {
    var url: URL
    var evidence: LeftoverEvidence
    var note: String?
    var needsAdministrator: Bool
    var launchdLabel: String?
}

/// Finds what an app left behind and records how each item is tied to it (docs/ARCHITECTURE.md section 7).
///
/// Only Library folders are searched, so Documents, Desktop, Downloads, Music, Pictures, Movies, iCloud and
/// /Users/Shared are never candidates (F-0011, F-0066). Identifiers are matched whole or at a dot, names only
/// by case-insensitive equality: never a substring.
struct LeftoverFinder {
    struct Result {
        var candidates: [LeftoverCandidate]
        var bundleLaunchdLabels: [String]
        var notes: [String]
    }

    let app: InstalledApp
    /// Every other installed app. An item one of them also claims gets a note and is not preselected.
    let others: [InstalledApp]
    let home: URL
    let systemRoot: URL

    /// Library folders whose items are named after bundle identifiers, with the suffixes they add (longest first).
    private static let identifierFolders: [(path: String, suffixes: [String])] = [
        ("Caches", [""]), ("Application Support", [""]), ("Preferences", [".plist", ""]),
        ("Saved Application State", [".savedState"]), ("HTTPStorages", [".binarycookies", ""]), ("WebKit", [""]),
        ("Logs", [""]), ("Application Scripts", [""]), ("Cookies", [".binarycookies"]),
    ]
    private static let systemIdentifierFolders: [(path: String, suffixes: [String])] = [
        ("Caches", [""]), ("Application Support", [""]), ("Preferences", [".plist"]), ("Logs", [""]),
        ("PrivilegedHelperTools", [""]),
    ]
    /// Folders where apps keep data under their plain name (the cask oracle: Application Support 54%, Logs 78%).
    private static let nameFolders = ["Application Support", "Caches", "Logs"]
    /// Apple's music apps keep most of their size outside the bundle (topic-platform-constraints A9).
    private static let contentLibraries: [String: [String]] = [
        "com.apple.garageband10": ["Application Support/GarageBand", "Application Support/Logic", "Audio/Apple Loops"],
        "com.apple.logic10": ["Application Support/Logic", "Audio/Apple Loops"],
    ]

    private var homeLibrary: URL { home.appendingPathComponent("Library") }
    private var systemLibrary: URL { systemRoot.appendingPathComponent("Library") }
    private var mainIdentifier: String? { app.bundleIdentifier?.lowercased() }

    func run() -> Result {
        var found: [LeftoverCandidate] = []
        for (folder, suffixes) in Self.identifierFolders {
            found += identifierNamed(in: homeLibrary.appendingPathComponent(folder), suffixes: suffixes)
        }
        for (folder, suffixes) in Self.systemIdentifierFolders {
            found += identifierNamed(in: systemLibrary.appendingPathComponent(folder), suffixes: suffixes)
        }
        found += byHostPreferences()
        found += containers()
        found += groupContainers()
        found += launchdJobs()
        found += contentLibraries()
        found += exactNames()
        return Result(
            candidates: Self.outermostUnique(found),
            bundleLaunchdLabels: LaunchdJob.labels(in: app.url.appendingPathComponent("Contents/Library/LaunchAgents")),
            notes: rootDaemonNotes() + receiptNotes()
        )
    }

    // MARK: Evidence

    private struct Claim {
        var note: String?
    }

    /// Whether an item named `key` belongs to the app: `key` is the bundle identifier or a dotted sub-identifier of
    /// it (`<id>.ShipIt`, `<id>.ShareExtension`). Sub-identifiers need a three-part identifier, so `com.vendor`
    /// never claims a whole vendor. Another installed app with the same or a more specific identifier (a second
    /// copy, `<id>.ce`) turns the item into a noted, unselected one.
    private func claim(_ name: String) -> Claim? {
        guard let main = mainIdentifier else { return nil }
        let key = name.lowercased()
        guard key == main || (main.split(separator: ".").count >= 3 && key.hasPrefix(main + ".")) else { return nil }
        let rival = others.first { other in
            guard let id = other.bundleIdentifier?.lowercased() else { return false }
            return key == id || (key.hasPrefix(id + ".") && id.count >= main.count)
        }
        return Claim(note: rival.map { "Also used by \($0.name)" })
    }

    private func identifierNamed(in folder: URL, suffixes: [String]) -> [LeftoverCandidate] {
        FileSystem.children(of: folder).compactMap { name in
            for suffix in suffixes where name.hasSuffix(suffix) && name.count > suffix.count {
                if let claim = claim(String(name.dropLast(suffix.count))) {
                    return candidate(folder.appendingPathComponent(name), .bundleIdentifier, note: claim.note)
                }
            }
            return nil
        }
    }

    /// `Preferences/ByHost/<identifier>.<host id>.plist`.
    private func byHostPreferences() -> [LeftoverCandidate] {
        let folder = homeLibrary.appendingPathComponent("Preferences/ByHost")
        return FileSystem.children(of: folder).compactMap { name in
            guard name.hasSuffix(".plist") else { return nil }
            let stem = name.dropLast(".plist".count)
            guard let dot = stem.lastIndex(of: "."), let claim = claim(String(stem[..<dot])) else { return nil }
            return candidate(folder.appendingPathComponent(name), .bundleIdentifier, note: claim.note)
        }
    }

    /// Sandbox containers, attributed by containermanagerd's own record (`MCMMetadataIdentifier`) when there is one:
    /// a UUID-named container can be the app's, and a folder named like the app can belong to someone else.
    private func containers() -> [LeftoverCandidate] {
        let folder = homeLibrary.appendingPathComponent("Containers")
        return FileSystem.children(of: folder).compactMap { name in
            let nameClaim = claim(name)
            // Metadata is read only where it can change the answer, not for every app's container.
            guard nameClaim != nil || UUID(uuidString: name) != nil else { return nil }
            let url = folder.appendingPathComponent(name)
            let metadata = FileSystem.propertyList(at: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
            if let owner = metadata?["MCMMetadataIdentifier"] as? String {
                return claim(owner).map { candidate(url, .containerMetadata, note: $0.note) }
            }
            return nameClaim.map { candidate(url, .bundleIdentifier, note: $0.note) }
        }
    }

    /// Group containers (and their Application Scripts) named in the app's `application-groups` entitlement.
    private func groupContainers() -> [LeftoverCandidate] {
        let groups = AppBundle(url: app.url).appGroups
        guard !groups.isEmpty else { return [] }
        var users: [String: String] = [:]
        for other in others where other.kind != .builtIn {
            for group in AppBundle(url: other.url).appGroups where users[group] == nil {
                users[group] = other.name
            }
        }
        return ["Group Containers", "Application Scripts"].flatMap { folderName in
            let folder = homeLibrary.appendingPathComponent(folderName)
            return groups.map { folder.appendingPathComponent($0) }.filter(FileSystem.exists).map { url in
                candidate(url, .appGroup, note: users[url.lastPathComponent].map { "Also used by \($0)" })
            }
        }
    }

    /// launchd plists whose program lies in the bundle, that name the app in `AssociatedBundleIdentifiers`, or whose
    /// label is the app's identifier. A job whose program is missing is still listed: that orphan is the leftover (F-0072).
    private func launchdJobs() -> [LeftoverCandidate] {
        let folders = [
            homeLibrary.appendingPathComponent("LaunchAgents"),
            systemLibrary.appendingPathComponent("LaunchAgents"),
            systemLibrary.appendingPathComponent("LaunchDaemons"),
        ]
        return folders.flatMap { folder in
            FileSystem.children(of: folder).filter { $0.hasSuffix(".plist") }.compactMap { name -> LeftoverCandidate? in
                let url = folder.appendingPathComponent(name)
                let fileKey = String(name.dropLast(".plist".count))
                guard let job = LaunchdJob(plistAt: url) else {
                    // launchd cannot load it either, so there is nothing to stop: a plain leftover if named after the app.
                    return claim(fileKey).map { candidate(url, .bundleIdentifier, note: $0.note) }
                }
                let associated = job.associatedBundleIdentifiers.contains { $0.lowercased() == mainIdentifier }
                if job.runs(inside: app.url) || associated {
                    return candidate(url, .launchdJob, note: nil, label: job.label)
                }
                guard let claim = claim(job.label) ?? claim(fileKey) else { return nil }
                let starter = others.first { job.runs(inside: $0.url) }.map { "Starts \($0.name)" }
                return candidate(url, .launchdJob, note: claim.note ?? starter, label: job.label)
            }
        }
    }

    private func contentLibraries() -> [LeftoverCandidate] {
        guard let id = app.bundleIdentifier, let paths = Self.contentLibraries[id] else { return [] }
        return paths.filter { FileSystem.exists(systemLibrary.appendingPathComponent($0)) }.map { path in
            let sharer = others.first { Self.contentLibraries[$0.bundleIdentifier ?? ""]?.contains(path) == true }
            return candidate(systemLibrary.appendingPathComponent(path), .contentLibrary, note: sharer.map { "Also used by \($0.name)" })
        }
    }

    /// Folders named exactly like the app, and the app's own subfolder in a vendor folder
    /// (`Objective-See/LuLu`). The vendor folder itself is never a candidate (F-0022).
    private func exactNames() -> [LeftoverCandidate] {
        let names = AppBundle(url: app.url).names.union([app.name.lowercased()])
        let folders = Self.nameFolders.map { homeLibrary.appendingPathComponent($0) } + [systemLibrary.appendingPathComponent("Application Support")]
        return folders.flatMap { folder in
            FileSystem.children(of: folder).flatMap { name -> [LeftoverCandidate] in
                let url = folder.appendingPathComponent(name)
                if names.contains(name.lowercased()) {
                    return [candidate(url, .exactName, note: nameRival(name))]
                }
                guard FileSystem.isDirectory(url) else { return [] }
                return FileSystem.children(of: url).filter { names.contains($0.lowercased()) }.map {
                    candidate(url.appendingPathComponent($0), .exactName, note: nameRival($0))
                }
            }
        }
    }

    private func nameRival(_ name: String) -> String? {
        let key = name.lowercased()
        return others.first { $0.name.lowercased() == key || $0.url.deletingPathExtension().lastPathComponent.lowercased() == key }
            .map { "Also the name of \($0.name)" }
    }

    // MARK: Notes

    private func rootDaemonNotes() -> [String] {
        LaunchdJob.labels(in: app.url.appendingPathComponent("Contents/Library/LaunchDaemons")).map {
            "\(app.name) has a background service that runs as root (\($0)). macontrol can't stop it; it stops when you restart your Mac."
        }
    }

    /// Package receipts are reported, never removed: the receipt is how macOS knows what the package installed.
    private func receiptNotes() -> [String] {
        let folder = systemRoot.appendingPathComponent("private/var/db/receipts")
        return FileSystem.children(of: folder)
            .filter { $0.hasSuffix(".plist") && claim(String($0.dropLast(".plist".count))) != nil }
            .map { "Installed by the package \($0.dropLast(".plist".count)). Files it put outside the app may remain." }
    }

    // MARK: Building candidates

    private func candidate(_ url: URL, _ evidence: LeftoverEvidence, note: String?, label: String? = nil) -> LeftoverCandidate {
        let inSystemLibrary = url.path.hasPrefix(systemLibrary.path + "/")
        return LeftoverCandidate(
            url: url, evidence: evidence, note: note,
            needsAdministrator: inSystemLibrary || !FileSystem.isRemovableByUser(url),
            launchdLabel: label
        )
    }

    /// One candidate per path, the first (strongest) evidence wins; items inside another candidate are dropped,
    /// because trashing the outer one takes them along.
    private static func outermostUnique(_ candidates: [LeftoverCandidate]) -> [LeftoverCandidate] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.url.path).inserted }
        return unique
            .filter { inner in !unique.contains { inner.url.path.hasPrefix($0.url.path + "/") } }
            .sorted { $0.url.path < $1.url.path }
    }
}
