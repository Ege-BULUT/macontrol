import Observation
import Safety

/// The session-wide hardcore switch (DESIGN-debloat section 1.1). Off at every launch and never stored.
/// Confirmations capture `mode` when they open.
@Observable
public final class HardcoreMode {
    public var isOn: Bool
    /// `.permanent` while on, `.trash` otherwise.
    public var mode: DeletionMode { isOn ? .permanent : .trash }

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }
}
