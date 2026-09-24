import Foundation

/// Starts the bundled helper as root through the administrator dialog (DESIGN-debloat section 3.3).
/// Stub (T-0072): `bundled()` is nil and `scrubEnvironment()` does nothing. privileged-helper builds both.
public struct PrivilegedLauncher: Sendable {
    public var helperURL: URL
    /// Shows the dialog and runs the helper with these four strings; throws a `PrivilegedError`.
    public var start: @MainActor @Sendable (_ helper: URL, _ request: URL, _ sha256: String, _ prompt: String) throws -> Void

    public init(helperURL: URL, start: @escaping @MainActor @Sendable (URL, URL, String, String) throws -> Void) {
        self.helperURL = helperURL
        self.start = start
    }

    /// The launcher for `Contents/Helpers/macontrol-priv`, or nil when the app runs without its bundle.
    public static func bundled(_ bundle: Bundle = .main) -> PrivilegedLauncher? {
        nil
    }

    /// Keeps only the allowlisted variables, before any thread starts. The first statement of the app's main.swift.
    public static func scrubEnvironment() {}
}

public enum PrivilegedError: Error, Sendable, Hashable {
    /// The user cancelled the administrator dialog.
    case cancelled
    /// The helper's foreground check refused the request, with its exit status.
    case helperRejected(Int32)
    /// The helper stopped before it answered every item.
    case helperStopped
    case launchFailed(String)
}
