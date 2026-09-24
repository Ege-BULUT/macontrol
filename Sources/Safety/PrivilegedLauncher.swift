import CoreServices
import Foundation

/// Starts the bundled helper as root through the administrator dialog (DESIGN-debloat section 3.3): `NSAppleScript`
/// runs `do shell script … with administrator privileges` with three strings macontrol owns on the shell line (the
/// helper, the request file and its SHA-256), passed as a typed Apple-event list, never spliced into the source.
public struct PrivilegedLauncher: Sendable {
    public var helperURL: URL
    /// Shows the dialog and runs the helper with these four strings; throws a `PrivilegedError`.
    public var start: @MainActor @Sendable (_ helper: URL, _ request: URL, _ sha256: String, _ prompt: String) throws -> Void

    public init(helperURL: URL, start: @escaping @MainActor @Sendable (URL, URL, String, String) throws -> Void) {
        self.helperURL = helperURL
        self.start = start
    }

    /// The launcher for `Contents/Helpers/macontrol-priv`, or nil when the app runs without its bundle (`swift run`).
    /// Built in one place only, `AppModel.live()` (a test checks), and used only from a confirmation the user pressed.
    public static func bundled(_ bundle: Bundle = .main) -> PrivilegedLauncher? {
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/macontrol-priv")
        var info = stat()
        guard bundle.bundleURL.pathExtension == "app", lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return PrivilegedLauncher(helperURL: helper, start: runAsAdministrator)
    }

    /// The fixed source; argv = [helper, request, SHA-256, prompt]. The prompt is data, shown in the dialog.
    static let script = """
        on run argv
            do shell script (quoted form of item 1 of argv) & " " & (quoted form of item 2 of argv) & " " & ¬
                (quoted form of item 3 of argv) with prompt (item 4 of argv) with administrator privileges
        end run
        """

    /// AppleScript's "User canceled." error number.
    static let userCancelled = -128

    @MainActor
    static func runAsAdministrator(helper: URL, request: URL, sha256: String, prompt: String) throws {
        // The shell `do shell script` starts inherits this environment: BASH_ENV or SHELLOPTS in it run code as root.
        guard isScrubbed(ProcessInfo.processInfo.environment) else { throw PrivilegedError.launchFailed("environment") }
        try execute(script, [helper.path, request.path, sha256, prompt])
    }

    /// Runs `source` with `arguments` as its `argv`, a typed list in an `aevt/oapp` event: nothing is spliced into the
    /// source, so no name can become AppleScript. Tests run the source without its administrator clause.
    @MainActor
    static func execute(_ text: String, _ arguments: [String]) throws {
        guard let source = NSAppleScript(source: text) else { throw PrivilegedError.launchFailed("script") }
        let argv = NSAppleEventDescriptor.list()
        for (index, text) in arguments.enumerated() {
            argv.insert(NSAppleEventDescriptor(string: text), at: index + 1)
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(argv, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        _ = source.executeAppleEvent(event, error: &error)
        guard let error else { return }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 1
        // Any other number is the helper's exit status: `do shell script` turns a non-zero exit into an error.
        throw number == userCancelled ? PrivilegedError.cancelled : PrivilegedError.helperRejected(Int32(truncatingIfNeeded: number))
    }

    // MARK: Environment (section 3.3 step 2)

    /// Kept as they are; `LC_*` too. Everything else goes, and `PATH` is fixed.
    static let keptVariables: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"]
    static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Keeps only the allowlisted variables, before any thread starts. The first statement of the app's main.swift,
    /// so BASH_ENV, SHELLOPTS, PS4, DYLD_* and DEVELOPER_DIR never reach the admin shell, launchctl, tmutil or simctl.
    public static func scrubEnvironment() {
        let current = ProcessInfo.processInfo.environment
        let kept = scrubbed(current)
        for key in current.keys where kept[key] == nil { unsetenv(key) }
        setenv("PATH", fixedPath, 1)
    }

    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        var kept = environment.filter { keptVariables.contains($0.key) || $0.key.hasPrefix("LC_") }
        kept["PATH"] = fixedPath
        return kept
    }

    static func isScrubbed(_ environment: [String: String]) -> Bool {
        scrubbed(environment) == environment
    }
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
