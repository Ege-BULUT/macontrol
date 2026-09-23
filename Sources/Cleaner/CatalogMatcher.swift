import Darwin
import Foundation

struct CatalogMatch: Sendable, Hashable {
    var rule: CleanupRule
    var url: URL
}

/// Turns validated patterns into concrete items, in-process (F-0025: a glob handed to a shell as a
/// quoted string matched nothing while the preview counted it). Blocking: call it off the cooperative pool.
struct CatalogMatcher: Sendable {
    /// Real path of home, so a symlinked home still works and results name the real objects.
    let home: URL

    init(home: URL) {
        self.home = Self.realPath(home.path).map(URL.init(fileURLWithPath:)) ?? home
    }

    /// Every match of every rule. Where matches overlap, the more specific one wins: `Caches/Google`
    /// from the generic cache rule gives way to `Caches/Google/Chrome` from the browser rule, and of
    /// two equal paths the rule listed first keeps it. So no byte is offered twice.
    func matches(for rules: [CleanupRule]) -> [CatalogMatch] {
        var seen = Set<String>()
        let unique = rules
            .flatMap { rule in rule.paths.flatMap(expand).map { (match: CatalogMatch(rule: rule, url: $0), folder: $0.path + "/") } }
            .filter { seen.insert($0.folder).inserted }
        // Sorted bytewise, everything inside `folder/` directly follows it, so neighbours tell containment.
        let folders = unique.map(\.folder).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let containers = Set(zip(folders, folders.dropFirst()).filter { $1.utf8.starts(with: $0.utf8) }.map(\.0))
        return unique.filter { !containers.contains($0.folder) }.map(\.match)
    }

    /// Matches carry the on-disk spelling, so a rule and the catch-all name the same folder the same way
    /// on a case-insensitive volume.
    func expand(_ pattern: String) -> [URL] {
        let url = pattern.hasPrefix("~/") ? home.appendingPathComponent(String(pattern.dropFirst(2))) : URL(fileURLWithPath: pattern)
        let parent = url.deletingLastPathComponent().path
        // A symlink anywhere above the match could point the rule at user files: refuse the whole pattern.
        // Only the letter case may differ from the rule's spelling.
        guard let real = Self.realPath(parent), real.compare(parent, options: .caseInsensitive) == .orderedSame else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: real)) ?? []
        let leaf = url.lastPathComponent
        return names.sorted().filter { fnmatch(leaf, $0, FNM_CASEFOLD) == 0 }.map { URL(fileURLWithPath: real).appendingPathComponent($0) }
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
