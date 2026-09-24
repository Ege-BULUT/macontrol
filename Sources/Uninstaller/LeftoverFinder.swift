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
    /// Apple's removable apps and what they install (DESIGN-debloat section 4.3).
    var profiles: AppleProfiles = .bundled
    /// SIP's `restricted` flag. Only the kernel sets it, so tests pass their own.
    var isRestricted: @Sendable (URL) -> Bool = { FileSystem.status(of: $0).map { $0.st_flags & LeftoverFinder.restrictedFlag != 0 } ?? false }

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

    static let containerMetadata = ".com.apple.containermanagerd.metadata.plist"
    /// SF_RESTRICTED, which Swift does not import.
    static let restrictedFlag: UInt32 = 0x0008_0000

    private var homeLibrary: URL { home.appendingPathComponent("Library") }
    private var systemLibrary: URL { systemRoot.appendingPathComponent("Library") }
    /// Reverse-DNS identifiers only. A one-word "identifier" is a name (PyInstaller's default is the app's name),
    /// and names are never evidence (F-0011, F-0022).
    private var mainIdentifier: String? {
        guard let id = app.bundleIdentifier?.lowercased(), id.split(separator: ".").count >= 2 else { return nil }
        return id
    }

    func run() -> Result {
        // Only an app signed as Apple's App Store app gets its profile: a copy that merely claims Xcode's identifier
        // must not be offered Apple's shared content.
        let profile = app.kind == .appleAppStore ? profiles.profile(for: app.bundleIdentifier) : nil
        // The profile first: where it and the generic search find the same path, its notes win.
        var found = profile.map(profileItems) ?? []
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
        found += exactNames()
        let neverTouch = (profile?.neverTouch ?? []).map(url(of:))
        found.removeAll { candidate in neverTouch.contains { AppleProfiles.overlaps(candidate.url.path, $0.path) } }
        return Result(
            candidates: Self.outermostUnique(found),
            bundleLaunchdLabels: LaunchdJob.labels(in: app.url.appendingPathComponent("Contents/Library/LaunchAgents"), of: app.url),
            notes: rootDaemonNotes() + receiptNotes(skipping: profile?.receipts ?? []) + (profile.map(keptByMacOS) ?? [])
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
            if let owner = Self.containerOwner(url) {
                return claim(owner).map { candidate(url, .containerMetadata, note: $0.note) }
            }
            return nameClaim.map { candidate(url, .bundleIdentifier, note: $0.note) }
        }
    }

    /// Group containers (and their Application Scripts) named in the app's `application-groups` entitlement.
    /// The names are text from the bundle, so only a single name shaped like a group (`group.` or the app's own team
    /// ID, then a dot) counts: not an empty entry (an undefined `$(APP_GROUP)`), `../../Documents`, or `com.apple.mail`,
    /// whose Application Scripts folder holds Mail's rule scripts and has no metadata to check. A group container
    /// counts only when containermanagerd records it as that group's. Built-in apps count as other users, so listing
    /// `group.com.apple.notes` never takes Notes' store.
    private func groupContainers() -> [LeftoverCandidate] {
        let bundle = AppBundle(url: app.url)
        let team = bundle.teamIdentifier
        let groups = bundle.appGroups.filter { Self.isAppGroup($0, team: team) }
        guard !groups.isEmpty else { return [] }
        var users: [String: String] = [:]
        // ponytail: one signature read per installed app, ~0.3 s for 94 apps here; read them concurrently if plans feel slow.
        for other in others {
            for group in AppBundle(url: other.url).appGroups where users[group] == nil {
                users[group] = other.name
            }
        }
        return groups.flatMap { group -> [LeftoverCandidate] in
            let container = homeLibrary.appendingPathComponent("Group Containers").appendingPathComponent(group)
            let scripts = homeLibrary.appendingPathComponent("Application Scripts").appendingPathComponent(group)
            let found = (Self.containerOwner(container) == group ? [container] : []) + (FileSystem.exists(scripts) ? [scripts] : [])
            return found.map { candidate($0, .appGroup, note: users[group].map { "Also used by \($0)" }) }
        }
    }

    static func isAppGroup(_ name: String, team: String?) -> Bool {
        let shaped = name.hasPrefix("group.") || team.map { !$0.isEmpty && name.hasPrefix($0 + ".") } == true
        return shaped && !name.contains("/") && !name.contains("\0")
    }

    /// containermanagerd's record of whose container this is.
    private static func containerOwner(_ container: URL) -> String? {
        FileSystem.propertyList(at: container.appendingPathComponent(containerMetadata))?["MCMMetadataIdentifier"] as? String
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
                var note: String?
                if !job.runs(inside: app.url) && !associated {
                    guard let claim = claim(job.label) ?? claim(fileKey) else { return nil }
                    note = claim.note
                }
                return candidate(url, .launchdJob, note: note ?? otherUser(of: job), label: job.label)
            }
        }
    }

    /// Another installed app the job also serves (a shared updater lists several apps), or whose program it runs.
    private func otherUser(of job: LaunchdJob) -> String? {
        let associated = Set(job.associatedBundleIdentifiers.map { $0.lowercased() })
        if let user = others.first(where: { $0.bundleIdentifier.map { associated.contains($0.lowercased()) } ?? false }) {
            return "Also used by \(user.name)"
        }
        return others.first { job.runs(inside: $0.url) }.map { "Starts \($0.name)" }
    }

    // MARK: Apple's profile

    /// Each profile item and receipt file that exists. A SIP-restricted item is not a candidate: it becomes a
    /// "Kept by macOS" note, since even root can't remove it.
    private func profileItems(_ profile: AppleProfile) -> [LeftoverCandidate] {
        let unverified = profile.verified ? nil : AppleProfile.unverifiedNote
        // Another copy of the app (Xcode-beta) uses all of it too: CoreSimulator, its caches, DerivedData (review 6).
        let copies = others.filter { $0.bundleIdentifier == profile.bundleIdentifier }.map(\.name)
        let copiesNote = copies.isEmpty ? nil : "Also used by \(Self.list(copies)), which \(copies.count == 1 ? "is" : "are") installed."
        let items = profile.items.compactMap { item -> LeftoverCandidate? in
            let url = url(of: item.path)
            guard FileSystem.exists(url), !isRestricted(url) else { return nil }
            let note = [sharedNote(item.sharedWith), copiesNote, item.note, unverified].compactMap { $0 }.joined(separator: " ")
            return candidate(url, .appleProfile, note: note.isEmpty ? nil : note)
        }
        let receipts = systemRoot.appendingPathComponent("private/var/db/receipts")
        let receiptFiles = profile.receipts.flatMap { id in ["plist", "bom"].map { receipts.appendingPathComponent("\(id).\($0)") } }
            .filter { FileSystem.exists($0) && !isRestricted($0) }
            .map { candidate($0, .appleProfile, note: unverified) }
        return items + receiptFiles
    }

    private func keptByMacOS(_ profile: AppleProfile) -> [String] {
        let restrictedItems = profile.items.map { url(of: $0.path) }.filter { FileSystem.exists($0) && isRestricted($0) }.map(\.lastPathComponent)
        let kept = profile.keptByMacOS.filter { FileSystem.exists(url(of: $0.path)) }.map(\.name)
        return (restrictedItems + kept).map { "Kept by macOS: \($0). It sits where even an administrator can't change it." }
    }

    /// "Also used by Logic Pro, which is installed." or "Also used by Logic Pro and MainStage (not installed)."
    private func sharedNote(_ identifiers: [String]) -> String? {
        guard !identifiers.isEmpty else { return nil }
        var installed: [String] = []
        for id in identifiers {
            for other in others where other.bundleIdentifier == id && !installed.contains(other.name) { installed.append(other.name) }
        }
        if !installed.isEmpty {
            return "Also used by \(Self.list(installed)), which \(installed.count == 1 ? "is" : "are") installed."
        }
        return "Also used by \(Self.list(identifiers.map { profiles.profile(for: $0)?.name ?? $0 })) (not installed)."
    }

    private static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// `~/…` is in the home folder, `/…` below the system root.
    private func url(of path: String) -> URL {
        path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : systemRoot.appendingPathComponent(String(path.dropFirst()))
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
        LaunchdJob.labels(in: app.url.appendingPathComponent("Contents/Library/LaunchDaemons"), of: app.url).map {
            "\(app.name) has a background service that runs as root (\($0)). macontrol can't stop it; it stops when you restart your Mac."
        }
    }

    /// Package receipts are reported, never removed: the receipt is how macOS knows what the package installed.
    /// The receipts of an Apple profile are leftovers instead, since the profile lists what the package installed.
    private func receiptNotes(skipping profileReceipts: [String]) -> [String] {
        let folder = systemRoot.appendingPathComponent("private/var/db/receipts")
        return FileSystem.children(of: folder)
            .filter { $0.hasSuffix(".plist") && !profileReceipts.contains(String($0.dropLast(".plist".count))) }
            .filter { claim(String($0.dropLast(".plist".count))) != nil }
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
