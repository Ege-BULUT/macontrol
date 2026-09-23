import Foundation

/// A rule the catalog refused, and why. Rules are dropped whole: one bad pattern is enough.
public struct RuleRejection: Sendable, Hashable {
    public var ruleID: String
    public var pattern: String
    public var reason: String
}

/// Decides whether a catalog pattern may ever be expanded (F-0032). Fails closed: anything it does
/// not positively recognise as a narrow, home-relative or allowlisted location is refused.
public enum PatternValidator {
    /// Absolute locations outside home that a rule may name. Everything else absolute is refused.
    static let allowedAbsoluteRoots = ["/System/Volumes/Data/macOS Install Data"]

    /// First components under home that hold the user's own files (F-0066, PureMac #142).
    static let userContentRoots: Set = ["documents", "desktop", "downloads", "music", "pictures", "movies", "public"]

    /// `~/Library/<folder>/*` is allowed only for these; `~/Library/Application Support/*` would be every app's data.
    static let libraryFoldersOpenToGlobs: Set = ["caches", "logs"]

    static let globCharacters = CharacterSet(charactersIn: "*?[]")

    /// Why `pattern` is refused, or `nil` when it may be used.
    public static func problem(with pattern: String) -> String? {
        if pattern.hasPrefix("~/") {
            return problem(withHomeComponents: pattern.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        if pattern.hasPrefix("/") {
            let insideAllowedRoot = allowedAbsoluteRoots.contains { pattern == $0 || pattern.hasPrefix($0 + "/") }
            guard insideAllowedRoot else { return "absolute path outside the allowed roots" }
            return problem(withComponents: pattern.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        return "must start with ~/ or an allowed absolute root"
    }

    private static func problem(withHomeComponents components: [String]) -> String? {
        if let problem = problem(withComponents: components) { return problem }
        guard components.count >= 3 else { return "less than three levels below home" }
        let lowercased = components.map { $0.lowercased() }
        if userContentRoots.contains(lowercased[0]) { return "inside the user's \(components[0]) folder" }
        if lowercased[0] == "library" {
            if ["mobile documents", "cloudstorage"].contains(lowercased[1]) { return "inside iCloud or a cloud provider folder" }
            if components.count == 3 && hasGlob(components[2]) && !libraryFoldersOpenToGlobs.contains(lowercased[1]) {
                return "a glob directly inside ~/Library/\(components[1])"
            }
        }
        return nil
    }

    private static func problem(withComponents components: [String]) -> String? {
        for (index, component) in components.enumerated() {
            if component.isEmpty { return "empty path component" }
            if component == "." || component == ".." { return "relative component \(component)" }
            let lowercased = component.lowercased()
            if lowercased.contains("com~apple~") || lowercased.contains("fileprovider") { return "inside a file provider folder" }
            if component.contains("$") || component.contains("~") || component.contains("\\") {
                return "variables, ~ and escapes are not expanded"
            }
            if hasGlob(component) && index != components.count - 1 { return "glob outside the last component" }
        }
        return nil
    }

    static func hasGlob(_ component: String) -> Bool {
        component.rangeOfCharacter(from: globCharacters) != nil
    }
}

extension CleanupCatalog {
    /// This catalog without any rule that has an invalid pattern, and the reasons they were dropped.
    public func validated() -> (catalog: CleanupCatalog, rejections: [RuleRejection]) {
        var rejections: [RuleRejection] = []
        let valid = rules.filter { rule in
            let problems = rule.paths.compactMap { pattern in
                PatternValidator.problem(with: pattern).map { RuleRejection(ruleID: rule.id, pattern: pattern, reason: $0) }
            }
            rejections += problems
            return problems.isEmpty && !rule.paths.isEmpty
        }
        return (CleanupCatalog(version: version, rules: valid), rejections)
    }
}
