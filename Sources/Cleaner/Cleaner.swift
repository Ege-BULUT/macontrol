import Foundation
import MacontrolCore
import Safety
import ScanEngine

/// One match of one rule, measured and ready for review.
public struct CleanupItem: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var rule: CleanupRule
    public var url: URL
    public var identity: FileIdentity?
    public var measurement: ItemMeasurement
    /// Why the item must not be cleaned right now ("Safari is running", "written 2 minutes ago").
    public var skipReason: String?

    public init(rule: CleanupRule, url: URL, identity: FileIdentity?, measurement: ItemMeasurement, skipReason: String?) {
        self.rule = rule
        self.url = url
        self.identity = identity
        self.measurement = measurement
        self.skipReason = skipReason
    }

    public var isPreselected: Bool { rule.safety == .safe && skipReason == nil }

    public var trashItem: TrashItem { TrashItem(url: url, expectedIdentity: identity) }
}

/// Finds and measures what the catalog allows cleaning. Read-only: cleaning goes through `TrashService`.
///
/// PLACEHOLDER (scaffold): expands patterns and measures matches. M5 adds rule validation (F-0032),
/// the in-use guard (F-0015) and the developer-artifact scan.
public final class Cleaner: Sendable {
    public let catalog: CleanupCatalog
    public let home: URL
    private let engine: ScanEngine

    public init(catalog: CleanupCatalog, home: URL = FileManager.default.homeDirectoryForCurrentUser, engine: ScanEngine = ScanEngine()) {
        self.catalog = catalog
        self.home = home
        self.engine = engine
    }

    /// Streams items as they are measured.
    public func scan() -> AsyncThrowingStream<CleanupItem, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for rule in catalog.rules {
                        for url in rule.paths.flatMap(expand) {
                            try Task.checkCancellation()
                            let measurement = try await engine.measure(url)
                            continuation.yield(CleanupItem(
                                rule: rule, url: url, identity: FileIdentity(url: url), measurement: measurement, skipReason: nil
                            ))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func expand(_ pattern: String) -> [URL] {
        let path = pattern.hasPrefix("~/") ? home.appendingPathComponent(String(pattern.dropFirst(2))).path : pattern
        let url = URL(fileURLWithPath: path)
        let leaf = url.lastPathComponent
        guard leaf.contains("*") else {
            return FileManager.default.fileExists(atPath: path) ? [url] : []
        }
        let parent = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { fnmatch(leaf, $0, 0) == 0 }.map { parent.appendingPathComponent($0) }
    }
}
