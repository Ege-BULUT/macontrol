import Foundation
import MacontrolCore
import Safety

public enum AppKind: String, Sendable, Hashable {
    case thirdParty
    /// Apple's own App Store apps (GarageBand, iMovie, Pages...): removable and free to download again.
    case appleAppStore
    /// Part of macOS on the sealed system volume. Shown, never removable (topic-platform-constraints A1-A7).
    case builtIn
}

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    public var kind: AppKind
    public var identity: FileIdentity?
    /// When the app landed in its folder (Finder's Date Added), else when the bundle was created. Nil if unreadable.
    public var dateAdded: Date?

    public init(
        url: URL, name: String, bundleIdentifier: String?, version: String?, kind: AppKind, identity: FileIdentity?, dateAdded: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.kind = kind
        self.identity = identity
        self.dateAdded = dateAdded
    }
}

/// Why a path is attributed to an app. Only identifiers are preselected, never names (F-0011, F-0022).
public enum LeftoverEvidence: String, Sendable, Hashable {
    /// The item's name is the app's bundle identifier (or one of its embedded bundles'), in a known Library folder.
    case bundleIdentifier
    /// A container whose metadata (MCMMetadataIdentifier) names the app.
    case containerMetadata
    /// A group container listed in the app's own entitlements.
    case appGroup
    /// A launchd job whose program lives inside the app bundle, or whose label is the app's identifier.
    case launchdJob
    /// A folder named exactly like the app. Shown, not preselected.
    case exactName
    /// A content library of Apple's music apps (Apple Loops, GarageBand and Logic sounds). Admin-only in v1.
    case contentLibrary
    /// An item of the app's profile in the bundled `apple-apps.json` (DESIGN-debloat section 4.3).
    case appleProfile

    public var preselected: Bool { self != .exactName && self != .contentLibrary }
}

public struct Leftover: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var identity: FileIdentity?
    public var evidence: LeftoverEvidence
    public var measurement: ItemMeasurement
    /// Root-owned or in /Library: removed through the administrator helper; without it, Reveal in Finder.
    public var needsAdministrator: Bool
    /// A reason to hold back, such as "Also used by BlockBlock". A note turns off preselection.
    public var note: String?
    /// For a launchd plist: the job label that is booted out before the plist is trashed (F-0023).
    public var launchdLabel: String?

    public init(
        url: URL, identity: FileIdentity?, evidence: LeftoverEvidence, measurement: ItemMeasurement,
        needsAdministrator: Bool, note: String?, launchdLabel: String? = nil
    ) {
        self.url = url
        self.identity = identity
        self.evidence = evidence
        self.measurement = measurement
        self.needsAdministrator = needsAdministrator
        self.note = note
        self.launchdLabel = launchdLabel
    }

    /// Items that need an administrator are preselected too (the UI disables them when there is no helper), but only
    /// for an Apple App Store app: `Uninstaller.plan` gives the others a note, since any app can claim a name.
    public var isPreselected: Bool { evidence.preselected && note == nil }
}

public struct UninstallPlan: Sendable {
    public var app: InstalledApp
    public var appMeasurement: ItemMeasurement
    public var leftovers: [Leftover]
    /// Why the app bundle cannot be removed from inside macontrol ("Part of macOS", needs an administrator).
    public var blocker: String?
    /// Labels of launch agents inside the bundle (SMAppService). They are booted out before the bundle is trashed.
    public var bundleLaunchdLabels: [String]
    /// Facts the user should know that macontrol does not act on: package receipts, root daemons.
    public var notes: [String]

    public init(
        app: InstalledApp, appMeasurement: ItemMeasurement, leftovers: [Leftover], blocker: String?,
        bundleLaunchdLabels: [String] = [], notes: [String] = []
    ) {
        self.app = app
        self.appMeasurement = appMeasurement
        self.leftovers = leftovers
        self.blocker = blocker
        self.bundleLaunchdLabels = bundleLaunchdLabels
        self.notes = notes
    }
}

/// One app of a batch uninstall: its plan and the leftovers the user chose.
public struct UninstallJob: Sendable {
    public var plan: UninstallPlan
    public var leftovers: Set<URL>

    public init(plan: UninstallPlan, leftovers: Set<URL>) {
        self.plan = plan
        self.leftovers = leftovers
    }
}

/// What a batch uninstall did: one report for every app that went ahead, and why each skipped app was skipped,
/// keyed by the app's URL.
public struct UninstallBatchReport: Sendable {
    public var report: TrashReport
    public var skipped: [URL: UninstallError]

    public init(report: TrashReport, skipped: [URL: UninstallError]) {
        self.report = report
        self.skipped = skipped
    }
}

/// Why an uninstall stopped. Every case is raised before anything is trashed.
public enum UninstallError: Error, Hashable {
    /// The plan's blocker: part of macOS, macontrol itself, or a root-owned bundle.
    case blocked(String)
    /// A chosen leftover needs an administrator, and there is no helper (`swift run`).
    case needsAdministrator(URL)
    /// Safety refuses the path.
    case refused(URL, RefusalReason)
    /// The path names another object (or nothing) since the plan was made.
    case changedSincePlan(URL)
    /// The app did not quit within the timeout, before or after its jobs were booted out. Nothing was trashed.
    case stillRunning(String)
    /// `launchctl bootout` failed; the job may still be running, so nothing was trashed.
    case bootoutFailed(label: String, status: Int32)
}

extension UninstallError: LocalizedError {
    /// Shown after "The uninstall stopped before moving anything:", so each one says what to do next.
    public var errorDescription: String? {
        switch self {
        case .blocked(let reason):
            reason
        case .needsAdministrator(let url):
            "\(url.lastPathComponent) needs an administrator to remove. Deselect it, or reveal it in Finder and remove it there."
        case .refused(let url, .protectedLocation(let place)):
            "\(url.lastPathComponent) is in a place macontrol never deletes (\(place)). Deselect it and try again."
        case .refused(let url, _):
            "\(url.lastPathComponent) can't be moved to the Trash safely. Deselect it and try again."
        case .changedSincePlan(let url):
            "\(url.lastPathComponent) changed after the list was made. Refresh the list and try again."
        case .stillRunning(let name):
            "\(name) is still running. Quit it, then try again."
        case .bootoutFailed(let label, let status):
            "Its background service \(label) could not be stopped (launchctl exit \(status)). Restart your Mac, then try again."
        }
    }
}
