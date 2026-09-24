import Observation
import Safety

/// The session-wide hardcore switch (DESIGN-debloat section 1.1). Off at every launch and never stored.
/// Confirmations capture `mode` when they open.
@Observable
public final class HardcoreMode {
    public var isOn: Bool
    /// The turn-on modal is showing. Ticking the checkbox only asks; the modal's red button turns it on (section 1.2).
    var isAsking = false
    /// `.permanent` while on, `.trash` otherwise.
    public var mode: DeletionMode { isOn ? .permanent : .trash }

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }

    /// What the toolbar checkbox shows and sets: ticking opens the modal, unticking turns it off at once.
    var checkbox: Bool {
        get { isOn }
        set {
            if newValue { isAsking = !isOn } else { isOn = false }
        }
    }

    func confirmTurnOn() {
        isOn = true
        isAsking = false
    }
}
