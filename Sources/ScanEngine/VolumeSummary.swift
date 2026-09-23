import Foundation

/// Capacity numbers for the volume holding a URL.
///
/// On APFS, capacity and free space are container-wide while "used" is per volume, so
/// used + available != capacity (topic-size-accounting fact 24). Purgeable space is a
/// promise from macOS, shown separately and never added to free space.
public struct VolumeSummary: Sendable, Equatable {
    public var name: String
    public var capacity: UInt64
    public var available: UInt64
    /// Available plus what macOS says it can purge on demand.
    public var availableForImportantUsage: UInt64

    public init(name: String, capacity: UInt64, available: UInt64, availableForImportantUsage: UInt64) {
        self.name = name
        self.capacity = capacity
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    public var purgeable: UInt64 { availableForImportantUsage > available ? availableForImportantUsage - available : 0 }

    public static func of(_ url: URL) throws -> VolumeSummary {
        let values = try url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return VolumeSummary(
            name: values.volumeName ?? url.lastPathComponent,
            capacity: UInt64(values.volumeTotalCapacity ?? 0),
            available: UInt64(values.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
}
