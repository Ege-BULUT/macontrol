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
    /// Why the item must not be cleaned right now ("Safari is running", "Changed in the last 10 minutes").
    public var skipReason: String?

    public init(rule: CleanupRule, url: URL, identity: FileIdentity?, measurement: ItemMeasurement, skipReason: String?) {
        self.rule = rule
        self.url = url
        self.identity = identity
        self.measurement = measurement
        self.skipReason = skipReason
    }

    public var isPreselected: Bool { rule.safety == .safe && skipReason == nil }

    /// Whether the item may be part of a clean at all: `manual` items are sized and revealed only (F-0027).
    public var canClean: Bool { rule.safety != .manual && skipReason == nil }

    public var trashItem: TrashItem { TrashItem(url: url, expectedIdentity: identity) }
}

/// Finds and measures what the catalog allows cleaning. Read-only: cleaning goes through `TrashService`.
public final class Cleaner: Sendable {
    /// The catalog as given, minus every rule the validator refuses. Nothing else is ever expanded.
    public let catalog: CleanupCatalog
    public let home: URL
    private let engine: ScanEngine
    private let processes: @Sendable (URL) -> ProcessSnapshot

    /// Items measured at once. Each measure is its own walk; a few in parallel keep the disk busy
    /// without starving the disk map scan.
    static let concurrentMeasurements = 4

    public init(
        catalog: CleanupCatalog,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        engine: ScanEngine = ScanEngine(),
        processes: @escaping @Sendable (URL) -> ProcessSnapshot = { ProcessSnapshot.current(under: $0) }
    ) {
        self.catalog = catalog.validated().catalog
        self.home = home
        self.engine = engine
        self.processes = processes
    }

    /// Streams items as they are measured, in no particular order. There is no time limit per item:
    /// a big cache takes longer, it never becomes uncleanable (F-0065).
    public func scan() -> AsyncThrowingStream<CleanupItem, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let matcher = CatalogMatcher(home: home)
                    let matches = matcher.matches(for: catalog.rules)
                    let guardrail = InUseGuard(processes: processes(matcher.home), home: matcher.home, now: Date())
                    try await withThrowingTaskGroup(of: CleanupItem?.self) { group in
                        var pending = matches.makeIterator()
                        for _ in 0..<Self.concurrentMeasurements {
                            guard let match = pending.next() else { break }
                            group.addTask { try await self.item(for: match, guardrail: guardrail) }
                        }
                        while let finished = try await group.next() {
                            if let finished { continuation.yield(finished) }
                            if let match = pending.next() {
                                group.addTask { try await self.item(for: match, guardrail: guardrail) }
                            }
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

    private func item(for match: CatalogMatch, guardrail: InUseGuard) async throws -> CleanupItem? {
        try Task.checkCancellation()
        // Gone since expansion: nothing to offer.
        guard let identity = FileIdentity(url: match.url) else { return nil }
        let measurement: ItemMeasurement
        do {
            measurement = try await engine.measure(match.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CleanupItem(rule: match.rule, url: match.url, identity: identity, measurement: .zero, skipReason: "Could not be read")
        }
        let reason = guardrail.skipReason(for: match.url, measurement: measurement, minimumAgeDays: match.rule.minimumAgeDays)
        return CleanupItem(rule: match.rule, url: match.url, identity: identity, measurement: measurement, skipReason: reason)
    }
}
