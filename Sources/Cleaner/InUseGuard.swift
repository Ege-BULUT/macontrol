import Foundation
import MacontrolCore

/// Decides whether a matched item must be left alone right now (F-0015).
///
/// Every name is checked, not only reverse-DNS ones: Mole's guard skipped dotless cache names and
/// deleted `GIPPseudonymousID` under a running Gemini, which then wrote ~200 GB/h retrying.
struct InUseGuard {
    /// Anything written this recently is treated as live, whatever its name.
    static let quietPeriod: TimeInterval = 10 * 60

    private let appNames: [String: String]
    private let openFiles: [OpenFile]
    private let home: URL
    private let now: Date

    init(processes: ProcessSnapshot, home: URL, now: Date) {
        var appNames: [String: String] = [:]
        for app in processes.apps {
            for name in [app.bundleIdentifier, app.bundleName, app.executableName].compactMap({ $0 }) {
                let key = Self.normalized(name)
                if !key.isEmpty { appNames[key] = app.displayName }
            }
        }
        self.appNames = appNames
        self.openFiles = processes.openFiles
        self.home = home
        self.now = now
    }

    func skipReason(for url: URL, measurement: ItemMeasurement, minimumAgeDays: Int?) -> String? {
        if let app = runningApp(namedIn: url) { return "\(app) is running" }
        let path = url.path
        if let file = openFiles.first(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
            return "In use by \(file.processName)"
        }
        guard let newest = measurement.newestModification else { return nil }
        let age = now.timeIntervalSince(newest)
        if age < Self.quietPeriod { return "Changed in the last 10 minutes" }
        if let days = minimumAgeDays, age < TimeInterval(days) * 86_400 {
            return days == 1 ? "Changed in the last day" : "Changed in the last \(days) days"
        }
        return nil
    }

    /// Any folder on the way to the item may carry the app's name: `Caches/Google/Chrome`, `Firefox/Profiles/x`.
    private func runningApp(namedIn url: URL) -> String? {
        let homePath = home.path.hasSuffix("/") ? home.path : home.path + "/"
        let below = url.path.hasPrefix(homePath) ? String(url.path.dropFirst(homePath.count)) : url.lastPathComponent
        return below.split(separator: "/").lazy.compactMap { appNames[Self.normalized(String($0))] }.first
    }

    /// Case, punctuation and a leading dot are ignored: "Brave-Browser" is "Brave Browser", ".cargo" is "cargo".
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
