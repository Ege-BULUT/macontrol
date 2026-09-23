// Probe for OpenDisk@6e3f1f7 ProtectedPaths.reason(for:): compiled with the
// source's own unmodified ProtectedPaths.swift + UserHome.swift. Pure string
// checks, nothing is deleted. Also prints (st_dev, st_ino) so aliases of the
// same directory are visible.
import Foundation

@main struct Probe {
    static func main() {
        let home = UserHome.path
        let data = "/System/Volumes/Data"
        let paths = [
            home, home + "/Library", "/Users", "/Applications",
            data + home, data + home + "/Library", data + "/Users", data + "/Applications",
            data + "/Library", data + "/private/var",
            home + "/Documents", home + "/.ssh", home + "/Library/Keychains",
            home + "/Library/Mobile Documents",
        ]
        for p in paths {
            var st = stat()
            let id = stat(p, &st) == 0 ? "dev=\(st.st_dev) ino=\(st.st_ino)" : "missing"
            let verdict = ProtectedPaths.reason(for: p).map { "BLOCKED (\($0))" } ?? "ALLOWED"
            print("\(verdict.hasPrefix("BLOCKED") ? "BLOCKED" : "ALLOWED")  \(p)  [\(id)]")
        }
    }
}
