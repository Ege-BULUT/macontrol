import Foundation
import MacontrolCore
import SwiftUI
import Uninstaller

/// An app on the sealed system volume (DESIGN-debloat section 5.2): its size, why it is locked, what to do instead,
/// and the expert guide. It has no destructive button, and the guide button shows in both modes (r2: ux 14).
struct SealedAppPanel: View {
    let app: InstalledApp
    let size: UInt64?
    /// All of macOS's own apps together; the sentence falls back to one without the total when nil.
    var systemAppsSize: UInt64?
    var integrity: SystemIntegrity
    var home: URL
    @State private var showsGuide = false

    init(
        app: InstalledApp, size: UInt64?, systemAppsSize: UInt64? = nil, integrity: SystemIntegrity = .current(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.app = app
        self.size = size
        self.systemAppsSize = systemAppsSize
        self.integrity = integrity
        self.home = home
    }

    static let dockAdvice = "Remove it from the Dock: Control-click its Dock icon, then Options > Remove from Dock."
    static let expertButton = "Expert: remove system apps yourself…"

    /// `onSystemVolume` is false for a protected app outside `/System/Applications`, such as Safari (feasibility S3).
    static func explanation(_ integrity: SystemIntegrity, systemAppsSize: UInt64?, onSystemVolume: Bool = true) -> String {
        let lock = if !onSystemVolume {
            "macOS protects this app, so macontrol can't remove it. It isn't in /System/Applications, so the expert guide doesn't cover it either."
        } else if integrity.allowsSealedRemoval {
            "macOS keeps this app on a sealed system volume. System Integrity Protection and Authenticated Root are off on this Mac, but macontrol doesn't remove system apps until that has been tested on macOS 14, 15 and 26."
        } else if integrity.filesystemProtected {
            "macOS keeps this app on a sealed, read-only system volume. No app can remove it while System Integrity Protection is on."
        } else {
            "macOS keeps this app on a sealed, read-only system volume. No app can remove it while Authenticated Root is on."
        }
        guard let systemAppsSize else { return lock + " macOS updates put its own apps back." }
        return lock + " All of macOS's own apps together use \(systemAppsSize.formattedBytes), and macOS updates put them back."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                FileIcon(url: app.url, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(app.name) is part of macOS").font(.title2.weight(.semibold))
                    Label("Locked by macOS", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let size {
                    Text(size.formattedBytes).font(.title2.weight(.semibold)).monospacedDigit()
                }
            }
            Text(Self.explanation(integrity, systemAppsSize: systemAppsSize, onSystemVolume: SealedGuide.pathOnSystemVolume(app.url) != nil))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("What you can do instead").font(.headline)
                Label(Self.dockAdvice, systemImage: "dock.rectangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button(Self.expertButton) { showsGuide = true }
                .help("Steps to remove macOS's own apps from Terminal, with their risks. macontrol runs none of them.")
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showsGuide) {
            SealedGuideSheet(apps: [app], integrity: integrity, home: home)
        }
    }
}
