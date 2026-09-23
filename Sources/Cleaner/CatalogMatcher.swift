import Darwin
import Foundation

struct CatalogMatch: Sendable, Hashable {
    var rule: CleanupRule
    var url: URL
}

/// Turns validated patterns into concrete items, in-process (F-0025: a glob handed to a shell as a
/// quoted string matched nothing while the preview counted it).
struct CatalogMatcher {
    /// Real path of home, so a symlinked home still works and results name the real objects.
    let home: URL

    init(home: URL) {
        self.home = Self.realPath(home.path).map(URL.init(fileURLWithPath:)) ?? home
    }

    /// Every match of every rule. Where matches overlap, the more specific one wins: `Caches/Google`
    /// from the generic cache rule gives way to `Caches/Google/Chrome` from the browser rule, and of
    /// two equal paths the rule listed first keeps it. So no byte is offered twice.
    func matches(for rules: [CleanupRule]) -> [CatalogMatch] {
        let all = rules.flatMap { rule in rule.paths.flatMap(expand).map { CatalogMatch(rule: rule, url: $0) } }
        var seen = Set<String>()
        // ponytail: O(n²) containment check; fine for the few hundred matches a catalog yields.
        return all.filter { match in
            guard seen.insert(match.url.path).inserted else { return false }
            let folder = match.url.path + "/"
            return !all.contains { $0.url.path.hasPrefix(folder) }
        }
    }

    func expand(_ pattern: String) -> [URL] {
        let url = pattern.hasPrefix("~/") ? home.appendingPathComponent(String(pattern.dropFirst(2))) : URL(fileURLWithPath: pattern)
        let parent = url.deletingLastPathComponent()
        // A symlink anywhere above the match could point the rule at user files: refuse the whole pattern.
        guard Self.realPath(parent.path) == parent.path else { return [] }
        let leaf = url.lastPathComponent
        guard PatternValidator.hasGlob(leaf) else {
            var info = stat()
            return lstat(url.path, &info) == 0 ? [url] : []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.sorted().filter { fnmatch(leaf, $0, 0) == 0 }.map { parent.appendingPathComponent($0) }
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
