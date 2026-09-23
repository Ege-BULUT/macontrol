import Foundation
import MacontrolCore

/// Decides whether a matched item must be left alone right now (F-0015). It runs at scan time and
/// again from `Cleaner.recheck` just before the trash, with a fresh process snapshot each time.
///
/// Mole's guard only looked for owners of reverse-DNS names and deleted `GIPPseudonymousID` under a
/// running Gemini, which then wrote ~200 GB/h retrying. Here every item has an owner that is
/// declared, read from a reverse-DNS name, or unknown, and an unknown owner is never preselected.
struct InUseGuard: Sendable {
    /// Anything written this recently is treated as live, whatever its name.
    static let quietPeriod: TimeInterval = 10 * 60

    /// Normalized bundle id, bundle name and executable name of every running process, to its display name.
    private let appNames: [String: String]
    private let bundleIDs: [(id: String, displayName: String)]
    private let openFiles: [OpenFile]
    private let uninspected: [String]
    private let now: Date

    init(processes: ProcessSnapshot, now: Date) {
        var appNames: [String: String] = [:]
        for app in processes.apps {
            for name in [app.bundleIdentifier, app.bundleName, app.executableName].compactMap({ $0 }) {
                let key = Self.normalized(name)
                if !key.isEmpty { appNames[key] = app.displayName }
            }
        }
        self.appNames = appNames
        self.bundleIDs = processes.apps.compactMap { app in app.bundleIdentifier.map { ($0.lowercased(), app.displayName) } }
        self.openFiles = processes.openFiles
        self.uninspected = processes.uninspected
        self.now = now
    }

    func skipReason(for url: URL, rule: CleanupRule, measurement: ItemMeasurement) -> String? {
        // Only the declared owners and the matched name count: the fixed folders of a rule
        // (Library, Caches, Developer, Xcode) would make unrelated apps block every match.
        for name in (rule.owners ?? []) + [url.lastPathComponent] {
            if let app = runningApp(named: name) { return "\(app) is running" }
        }
        let path = url.path
        if let file = openFiles.first(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
            return "In use by \(file.processName)"
        }
        if let process = uninspected.first { return "Could not check which files \(process) has open" }
        guard let newest = measurement.newestModification else { return nil }
        let age = now.timeIntervalSince(newest)
        if age < Self.quietPeriod { return "Changed in the last 10 minutes" }
        if let days = rule.minimumAgeDays, age < TimeInterval(days) * 86_400 {
            return days == 1 ? "Changed in the last day" : "Changed in the last \(days) days"
        }
        return nil
    }

    /// Why an item that may be cleaned still starts unselected, or `nil` when it can be preselected.
    static func caution(for url: URL, rule: CleanupRule, measurement: ItemMeasurement) -> String? {
        if rule.owners == nil && !isReverseDNS(url.lastPathComponent) { return "Cache of an unidentified app" }
        // A write inside the unreadable part would be invisible to the 10-minute check.
        if measurement.isIncomplete { return "Some contents could not be read" }
        return nil
    }

    /// `name` is a running app's bundle id, app name or executable name. A reverse-DNS name also
    /// matches the app it is a sub-id of (`com.microsoft.VSCode.ShipIt` while VS Code runs) and, by
    /// its last part, daemons with no bundle (`com.apple.nsurlsessiond`). Not the reverse: a running
    /// `com.apple.Safari.SafariLinkExtension` is sandboxed away from Safari's cache, and would
    /// otherwise block it all day.
    private func runningApp(named name: String) -> String? {
        if let app = appNames[Self.normalized(name)] { return app }
        guard Self.isReverseDNS(name) else { return nil }
        let id = name.lowercased()
        if let app = bundleIDs.first(where: { id.hasPrefix($0.id + ".") }) { return app.displayName }
        return name.split(separator: ".").last.flatMap { appNames[Self.normalized(String($0))] }
    }

    /// `com.vendor.Product`: three or more parts, the first a lowercase domain.
    static func isReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
            && parts[0].allSatisfy { $0.isASCII && $0.isLowercase }
    }

    /// Case, punctuation and a leading dot are ignored: "Brave-Browser" is "Brave Browser", ".cargo" is "cargo".
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
