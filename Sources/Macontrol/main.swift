import AppKit
import Foundation
import MacontrolUI

// Hidden mode: `Macontrol --snapshot <dir>` renders every screen with demo data and exits.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    do {
        for url in try SnapshotRenderer.renderAll(to: URL(fileURLWithPath: arguments[flag + 1])) {
            print(url.path)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}

MacontrolApp.main()
