import AppKit
import Foundation
import MacontrolUI
import Safety

// First statement, before NSApplication or Dispatch starts a thread: tools macontrol runs, and the administrator
// helper, never inherit BASH_ENV, DYLD_* and the like (DESIGN-debloat section 3.3 step 2).
PrivilegedLauncher.scrubEnvironment()

// Hidden modes, both exit when done:
//   Macontrol --snapshot <dir>       renders every screen with demo data, light and dark
//   Macontrol --render-icon <dir>    writes the app icon as an .iconset for iconutil
let arguments = CommandLine.arguments
for (flag, render) in [
    ("--snapshot", { (url: URL) in try SnapshotRenderer.renderAll(to: url).forEach { print($0.path) } }),
    ("--render-icon", { (url: URL) in try SnapshotRenderer.renderIconSet(to: url) }),
] {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { continue }
    NSApplication.shared.setActivationPolicy(.prohibited)
    do {
        try render(URL(fileURLWithPath: arguments[index + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(flag) failed: \(error)\n".utf8))
        exit(1)
    }
}

MacontrolApp.main()
