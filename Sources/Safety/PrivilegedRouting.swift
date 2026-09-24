import Foundation

/// Pass 2 of `TrashService.remove` (DESIGN-debloat section 3.6): the items pass 1 refused with `.needsAdministrator`
/// go to the helper in one request, in order.
public enum PrivilegedRouting {
    /// One outcome per item, in the order of `items`; each replaces that item's refusal.
    /// `batch`, `journalURL` and `restorePoint` are the calling batch's, for the journal lines it writes as results
    /// arrive (section 3.3 step 5); `home` is the requesting user's.
    /// Stub (T-0072): returns the refusals unchanged. privileged-helper builds it.
    public static func run(
        _ items: [TrashItem], mode: DeletionMode, launcher: PrivilegedLauncher,
        batch: UUID, journalURL: URL, home: URL, restorePoint: String?
    ) async -> [TrashOutcome] {
        items.map { .refused($0.url, .needsAdministrator) }
    }
}
