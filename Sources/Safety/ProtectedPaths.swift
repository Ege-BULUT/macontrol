import Foundation

/// Where macontrol refuses to delete, checked before any button is enabled and again at delete time.
///
/// PLACEHOLDER (scaffold): exact roots only, which is the F-0024 defect. M7 replaces it with the
/// containment policy in docs/ARCHITECTURE.md (canonical path via F_GETPATH, SF_RESTRICTED, curated roots).
public enum ProtectedPaths {
    public static func refusal(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RefusalReason? {
        let path = url.standardizedFileURL.path
        let roots = ["/", "/System", "/Users", "/Applications", "/Library", home.path]
        return roots.contains(path) ? .protectedLocation(path) : nil
    }
}
