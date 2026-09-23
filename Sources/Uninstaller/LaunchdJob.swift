import Foundation

/// The parts of a launchd plist that tie a job to an app.
struct LaunchdJob {
    var label: String
    /// `Program` and every `ProgramArguments` entry: a job belongs to an app when any of them lies inside its bundle
    /// (agents often run `/usr/bin/open <bundle>`).
    var paths: [String]
    var associatedBundleIdentifiers: [String]
    /// SMAppService's program path, relative to the app bundle.
    var bundleProgram: String?

    init?(plistAt url: URL) {
        guard let plist = FileSystem.propertyList(at: url), let label = plist["Label"] as? String else { return nil }
        self.label = label
        paths = [plist["Program"] as? String].compactMap { $0 } + (plist["ProgramArguments"] as? [String] ?? [])
        bundleProgram = plist["BundleProgram"] as? String
        // A string or an array, depending on who wrote the plist.
        let associated = plist["AssociatedBundleIdentifiers"]
        associatedBundleIdentifiers = associated as? [String] ?? (associated as? String).map { [$0] } ?? []
    }

    func runs(inside bundle: URL) -> Bool {
        paths.contains { $0 == bundle.path || Self.isPath($0, inside: bundle) }
    }

    /// Whether the program launchd starts is in `bundle`: `BundleProgram`, else `Program`, else the first argument.
    func startsProgram(in bundle: URL) -> Bool {
        if let relative = bundleProgram { return !relative.hasPrefix("/") && !relative.split(separator: "/").contains("..") }
        return paths.first.map { Self.isPath($0, inside: bundle) } ?? false
    }

    /// Labels of the jobs a bundle carries for `SMAppService` (Contents/Library/LaunchAgents or LaunchDaemons).
    /// A label is text the bundle ships, so it counts only when the job runs the bundle's own program: a plist naming
    /// another vendor's label must not stop that vendor's job.
    static func labels(in folder: URL, of bundle: URL) -> [String] {
        FileSystem.children(of: folder)
            .filter { $0.hasSuffix(".plist") }
            .compactMap { LaunchdJob(plistAt: folder.appendingPathComponent($0)) }
            .filter { $0.startsProgram(in: bundle) }
            .map(\.label)
            .sorted()
    }

    /// Compared as text, so a `..` component could climb out; such a path never counts.
    private static func isPath(_ path: String, inside bundle: URL) -> Bool {
        path.hasPrefix(bundle.path + "/") && !path.split(separator: "/").contains("..")
    }
}
