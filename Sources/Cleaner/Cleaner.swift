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
    /// Why a cleanable item starts unselected ("Cache of an unidentified app"). The user may still tick it.
    public var caution: String?

    public init(
        rule: CleanupRule, url: URL, identity: FileIdentity?, measurement: ItemMeasurement, skipReason: String?, caution: String? = nil
    ) {
        self.rule = rule
        self.url = url
        self.identity = identity
        self.measurement = measurement
        self.skipReason = skipReason
        self.caution = caution
    }

    public var isPreselected: Bool { rule.safety == .safe && skipReason == nil && caution == nil }

    /// Whether the item may be part of a clean at all: `manual` items are sized and revealed only (F-0027).
    public var canClean: Bool { rule.safety != .manual && skipReason == nil }

    public var trashItem: TrashItem { TrashItem(url: url, expectedIdentity: identity) }
}

/// Finds and measures what the catalog allows cleaning. Read-only: cleaning goes through `TrashService`.
public final class Cleaner: Sendable {
    /// The catalog as given, minus every rule the validator refuses. Nothing else is ever expanded.
    public let catalog: CleanupCatalog
    public let home: URL
    private let matcher: CatalogMatcher
    private let engine: ScanEngine
    private let processes: @Sendable (URL) -> ProcessSnapshot
    private let now: @Sendable () -> Date

    /// Items measured at once. Each measure is its own walk; a few in parallel keep the disk busy
    /// without starving the disk map scan.
    static let concurrentMeasurements = 4

    public init(
        catalog: CleanupCatalog,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        engine: ScanEngine = ScanEngine(),
        processes: @escaping @Sendable (URL) -> ProcessSnapshot = { ProcessSnapshot.current(under: $0) },
        // Tests move the clock instead of the files: an item's age includes its ctime, which no API can backdate.
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog.validated().catalog
        self.home = home
        self.matcher = CatalogMatcher(home: home)
        self.engine = engine
        self.processes = processes
        self.now = now
    }

    /// Streams items as they are measured, in no particular order. There is no time limit per item:
    /// a big cache takes longer, it never becomes uncleanable (F-0065).
    public func scan() -> AsyncThrowingStream<CleanupItem, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (matches, guardrail) = await offCooperativePool { [self] in
                        (matcher.matches(for: catalog.rules), currentGuard())
                    }
                    let jobs = matches.map { Job(rule: $0.rule, url: $0.url, identity: nil) }
                    try await evaluate(jobs, guardrail: guardrail) { _, item in
                        if let item { continuation.yield(item) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The guard again, with what runs and what changed right now. Call it immediately before the
    /// trash: a scan can be hours old, and an app launched since must keep its cache (F-0015).
    /// Items keep the scan's identity, so the trash still refuses a path that now names another object.
    /// Fails closed: an item that could not be checked again comes back with a skip reason.
    public func recheck(_ items: [CleanupItem]) async -> [CleanupItem] {
        let guardrail = await offCooperativePool { [self] in currentGuard() }
        var rechecked = items.map { item in
            var unchecked = item
            unchecked.skipReason = "Could not be checked again"
            return unchecked
        }
        let jobs = items.map { Job(rule: $0.rule, url: $0.url, identity: $0.identity) }
        try? await evaluate(jobs, guardrail: guardrail) { index, item in
            if let item { rechecked[index] = item } else { rechecked[index].skipReason = "No longer there" }
        }
        return rechecked
    }

    private struct Job: Sendable {
        var rule: CleanupRule
        var url: URL
        /// The scan's identity when rechecking; a new scan reads it.
        var identity: FileIdentity?
    }

    private func currentGuard() -> InUseGuard {
        InUseGuard(processes: processes(matcher.home), now: now())
    }

    /// Measures and judges every job, a few at a time, reporting each by its index as it finishes.
    private func evaluate(_ jobs: [Job], guardrail: InUseGuard, onResult: (Int, CleanupItem?) -> Void) async throws {
        try await withThrowingTaskGroup(of: (Int, CleanupItem?).self) { group in
            var pending = jobs.enumerated().makeIterator()
            for _ in 0..<Self.concurrentMeasurements {
                guard let (index, job) = pending.next() else { break }
                group.addTask { (index, try await self.item(for: job, guardrail: guardrail)) }
            }
            while let (index, item) = try await group.next() {
                onResult(index, item)
                if let (index, job) = pending.next() {
                    group.addTask { (index, try await self.item(for: job, guardrail: guardrail)) }
                }
            }
        }
    }

    /// `nil` when the item is gone.
    private func item(for job: Job, guardrail: InUseGuard) async throws -> CleanupItem? {
        try Task.checkCancellation()
        guard let current = FileIdentity(url: job.url) else { return nil }
        let identity = job.identity ?? current
        let measurement: ItemMeasurement
        do {
            measurement = try await engine.measure(job.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CleanupItem(rule: job.rule, url: job.url, identity: identity, measurement: .zero, skipReason: "Could not be read")
        }
        return CleanupItem(
            rule: job.rule, url: job.url, identity: identity, measurement: measurement,
            skipReason: guardrail.skipReason(for: job.url, rule: job.rule, measurement: measurement),
            caution: InUseGuard.caution(for: job.url, rule: job.rule, measurement: measurement)
        )
    }
}

/// Runs blocking file and libproc work on a GCD thread, never on the cooperative pool (docs/ARCHITECTURE.md, "Concurrency").
private func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
