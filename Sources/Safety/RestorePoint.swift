import Foundation

/// A local APFS snapshot taken before a permanent batch, only when the user ticks the box (DESIGN-debloat section 2.6).
public enum RestorePoint {
    /// Returns the snapshot's name, `com.apple.TimeMachine.<date>.local`.
    /// Stub (T-0072): always throws. permanent-engine builds it.
    public static func create() async throws -> String {
        throw CocoaError(.featureUnsupported)
    }
}
