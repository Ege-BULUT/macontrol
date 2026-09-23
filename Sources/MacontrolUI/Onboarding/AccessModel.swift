import AppKit
import MacontrolCore
import Observation

/// Full Disk Access state and the onboarding flow around it (docs/ARCHITECTURE.md section 9).
@Observable
public final class AccessModel {
    public private(set) var status: FullDiskAccess
    public var isOnboardingPresented = false
    /// The user went to System Settings, came back, and the probe still says no. Whether a grant
    /// reaches a running app is unverified (P5), so a relaunch is offered instead of guessing.
    public private(set) var suggestsRelaunch = false

    private var openedSettings = false
    private let probe: () -> FullDiskAccess
    private let openURL: (URL) -> Bool

    public init(
        status: FullDiskAccess,
        probe: @escaping () -> FullDiskAccess = { FullDiskAccess.probe() },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.status = status
        self.probe = probe
        self.openURL = openURL
    }

    /// Scans skip protected folders; the UI says which ones instead of showing smaller totals.
    public var isLimited: Bool { status != .granted }

    public var skippedFolders: String {
        ListFormatter.localizedString(byJoining: FullDiskAccess.foldersSkippedWithout)
    }

    func refresh() {
        status = probe()
        if status == .granted {
            isOnboardingPresented = false
            suggestsRelaunch = false
        }
    }

    /// Polls while the onboarding sheet is visible; the sheet's `.task` cancels it on dismissal.
    func watch(every interval: Duration = .seconds(1)) async {
        while !Task.isCancelled && status != .granted {
            try? await Task.sleep(for: interval)
            refresh()
        }
    }

    func appDidBecomeActive() {
        refresh()
        if openedSettings && status != .granted { suggestsRelaunch = true }
    }

    func openSettings() {
        openedSettings = true
        if !openURL(FullDiskAccess.settingsURL) {
            _ = openURL(FullDiskAccess.legacySettingsURL)
        }
    }

    func continueWithout() {
        isOnboardingPresented = false
    }

    func showOnboarding() {
        isOnboardingPresented = true
    }

    /// Automatic registration in the FDA list is not guaranteed (P8), so the user may need to add the app by hand.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, _ in
            guard app != nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
