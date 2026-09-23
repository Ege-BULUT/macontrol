import Foundation

/// The parts of a launchd plist that tie a job to an app.
struct LaunchdJob {
    var label: String
    /// `Program` and every `ProgramArguments` entry: a job belongs to an app when any of them lies inside its bundle
    /// (agents often run `/usr/bin/open <bundle>`).
    var paths: [String]
    var associatedBundleIdentifiers: [String]

    init?(plistAt url: URL) {
        guard let plist = FileSystem.propertyList(at: url), let label = plist["Label"] as? String else { return nil }
        self.label = label
        paths = [plist["Program"] as? String].compactMap { $0 } + (plist["ProgramArguments"] as? [String] ?? [])
        // A string or an array, depending on who wrote the plist.
        let associated = plist["AssociatedBundleIdentifiers"]
        associatedBundleIdentifiers = associated as? [String] ?? (associated as? String).map { [$0] } ?? []
    }

    func runs(inside bundle: URL) -> Bool {
        let prefix = bundle.path + "/"
        return paths.contains { $0.hasPrefix(prefix) || $0 == bundle.path }
    }

    /// Labels of the launch agents a bundle carries for `SMAppService` (Contents/Library/LaunchAgents).
    static func labels(in folder: URL) -> [String] {
        FileSystem.children(of: folder)
            .filter { $0.hasSuffix(".plist") }
            .compactMap { LaunchdJob(plistAt: folder.appendingPathComponent($0))?.label }
            .sorted()
    }
}
