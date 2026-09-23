import Observation
import Uninstaller

/// The Debloat checklist of Apple's removable apps (DESIGN-debloat section 4).
/// Placeholder (T-0072): holds its services only. debloat-catalog builds it.
@Observable
public final class DebloatModel {
    let uninstaller: Uninstaller?
    let hardcore: HardcoreMode

    public init(uninstaller: Uninstaller?, hardcore: HardcoreMode = HardcoreMode()) {
        self.uninstaller = uninstaller
        self.hardcore = hardcore
    }

    /// Sample data for snapshots and previews. Touches no real files.
    public static func demo() -> DebloatModel {
        DebloatModel(uninstaller: nil)
    }
}
