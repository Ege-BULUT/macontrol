// Stubs for compiling munki's rmpkgs.swift unmodified outside the munki target.
// Only UI/logging/prefs/status are stubbed. SQLite wrapper, file utils, CLI runner and
// plist utils are munki's own files (see run.sh). Nothing here touches the real
// /Library/Managed Installs or Apple's receipt DB.
import Foundation

final class DisplayAndLog {
    static let main = DisplayAndLog()
    var munkistatusoutput: Bool { false }
    func error(_ m: String) { print("  [error] \(m)") }
    func warning(_ m: String) { print("  [warn] \(m)") }
    func info(_ m: String) { print("  [info] \(m)") }
    func detail(_ m: String) { print("  [detail] \(m)") }
    func debug(_ m: String) { print("  [debug] \(m)") }
    func majorStatus(_ m: String) { print("  [major] \(m)") }
    func minorStatus(_ m: String) { print("  [minor] \(m)") }
}

func displayPercentDone(current: Int, maximum: Int) {}
func munkiStatusPercent(_ percentage: Int) {}
func munkiStatusDisableStopButton() {}
func munkiStatusEnableStopButton() {}
func stopRequested() -> Bool { false }

/// The receipt DB goes to $PROBE_DIR, never /Library/Managed Installs.
func managedInstallsDir(subpath: String? = nil) -> String {
    let base = ProcessInfo.processInfo.environment["PROBE_DIR"]!
    return subpath.map { (base as NSString).appendingPathComponent($0) } ?? base
}
typealias PlistDict = [String: Any] // same as munki shared/constants.swift:75
func printStderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)); FileHandle.standardError.write(Data([10])) }
