import Foundation
import MacontrolCore
import Safety
import ScanEngine

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

    public init(url: URL, name: String, bundleIdentifier: String?, version: String?, kind: AppKind, identity: FileIdentity?) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.kind = kind
        self.identity = identity
    }
}

/// Why a path is attributed to an app. Only exact identifiers are preselected (F-0011, F-0022).
public enum LeftoverEvidence: String, Sendable, Hashable {
    /// The item's name is the bundle identifier, in a known Library folder.
    case bundleIdentifier
    /// A container whose metadata (MCMMetadataIdentifier) names the app.
    case containerMetadata
    /// A group container listed in the app's own entitlements.
    case appGroup
    /// A launchd plist whose program lives inside the app bundle.
    case launchdJob
    /// A folder named exactly like the app. Shown, not preselected.
    case exactName

    public var preselected: Bool { self != .exactName }
}

public struct Leftover: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var identity: FileIdentity?
    public var evidence: LeftoverEvidence
    public var measurement: ItemMeasurement
    /// Root-owned; v1 offers Reveal in Finder instead of deleting it.
    public var needsAdministrator: Bool
    /// A reason to hold back, such as "also used by BlockBlock". A note turns off preselection.
    public var note: String?

    public init(url: URL, identity: FileIdentity?, evidence: LeftoverEvidence, measurement: ItemMeasurement, needsAdministrator: Bool, note: String?) {
        self.url = url
        self.identity = identity
        self.evidence = evidence
        self.measurement = measurement
        self.needsAdministrator = needsAdministrator
        self.note = note
    }

    public var isPreselected: Bool { evidence.preselected && note == nil && !needsAdministrator }
}

public struct UninstallPlan: Sendable {
    public var app: InstalledApp
    public var appMeasurement: ItemMeasurement
    public var leftovers: [Leftover]
    /// Why the app bundle itself cannot be removed from inside macontrol ("Part of macOS").
    public var blocker: String?

    public init(app: InstalledApp, appMeasurement: ItemMeasurement, leftovers: [Leftover], blocker: String?) {
        self.app = app
        self.appMeasurement = appMeasurement
        self.leftovers = leftovers
        self.blocker = blocker
    }
}

/// Lists apps, finds their leftovers, and removes both in a safe order.
///
/// PLACEHOLDER (scaffold): lists bundles and checks bundle-id names in a few Library folders.
/// M6 implements docs/ARCHITECTURE.md "Uninstaller".
public final class Uninstaller: Sendable {
    public let home: URL
    public let applicationFolders: [URL]
    private let engine: ScanEngine
    private let trash: TrashService

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationFolders: [URL]? = nil,
        engine: ScanEngine = ScanEngine(),
        trash: TrashService
    ) {
        self.home = home
        self.applicationFolders = applicationFolders ?? [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        self.engine = engine
        self.trash = trash
    }

    public func installedApps() async throws -> [InstalledApp] {
        applicationFolders.flatMap { folder -> [InstalledApp] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".app") }.map { app(at: folder.appendingPathComponent($0)) }
        }
    }

    public func plan(for app: InstalledApp) async throws -> UninstallPlan {
        var leftovers: [Leftover] = []
        if let id = app.bundleIdentifier {
            let candidates = [
                "Library/Caches/\(id)", "Library/Application Support/\(id)", "Library/Preferences/\(id).plist",
                "Library/Containers/\(id)", "Library/Saved Application State/\(id).savedState",
                "Library/HTTPStorages/\(id)", "Library/WebKit/\(id)", "Library/Logs/\(id)",
            ].map { home.appendingPathComponent($0) }
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                leftovers.append(Leftover(
                    url: url, identity: FileIdentity(url: url), evidence: .bundleIdentifier,
                    measurement: try await engine.measure(url), needsAdministrator: false, note: nil
                ))
            }
        }
        return UninstallPlan(
            app: app,
            appMeasurement: try await engine.measure(app.url),
            leftovers: leftovers,
            blocker: app.kind == .builtIn ? "Part of macOS. It lives on the sealed system volume and can't be removed." : nil
        )
    }

    /// Quits the app, stops its launchd jobs, then trashes the bundle and the chosen leftovers.
    public func uninstall(_ plan: UninstallPlan, leftovers selected: Set<URL>) async throws -> TrashReport {
        let items = [TrashItem(url: plan.app.url, expectedIdentity: plan.app.identity)]
            + plan.leftovers.filter { selected.contains($0.url) }.map { TrashItem(url: $0.url, expectedIdentity: $0.identity) }
        return await trash.moveToTrash(items)
    }

    private func app(at url: URL) -> InstalledApp {
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        let kind: AppKind
        if url.path.hasPrefix("/System/") {
            kind = .builtIn
        } else if bundleID?.hasPrefix("com.apple.") == true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path) {
            kind = .appleAppStore
        } else {
            kind = .thirdParty
        }
        return InstalledApp(
            url: url,
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            kind: kind,
            identity: FileIdentity(url: url)
        )
    }
}
