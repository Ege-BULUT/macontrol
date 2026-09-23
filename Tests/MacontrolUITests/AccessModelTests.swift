import Foundation
import MacontrolCore
@testable import MacontrolUI
import Testing

@Suite struct AccessModelTests {
    /// Returns the queued answers in order, then repeats the last one.
    final class ScriptedProbe {
        var answers: [FullDiskAccess]
        var calls = 0
        init(_ answers: [FullDiskAccess]) { self.answers = answers }
        func next() -> FullDiskAccess {
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    @Test func pollingContinuesOnItsOwnOnceAccessIsGranted() async {
        let probe = ScriptedProbe([.denied, .denied, .granted])
        let access = AccessModel(status: .denied, probe: probe.next, openURL: { _ in true })
        access.isOnboardingPresented = true

        await access.watch(every: .milliseconds(5))

        #expect(access.status == .granted)
        #expect(!access.isOnboardingPresented)
        #expect(!access.isLimited)
        #expect(probe.calls == 3)
    }

    @Test func relaunchIsOfferedOnlyAfterReturningFromSettingsStillDenied() {
        let probe = ScriptedProbe([.denied])
        let access = AccessModel(status: .denied, probe: probe.next, openURL: { _ in true })

        access.appDidBecomeActive()
        #expect(!access.suggestsRelaunch, "user never went to Settings")

        access.openSettings()
        access.appDidBecomeActive()
        #expect(access.suggestsRelaunch)

        probe.answers = [.granted]
        access.appDidBecomeActive()
        #expect(!access.suggestsRelaunch)
        #expect(access.status == .granted)
    }

    @Test func settingsFallsBackToTheLegacyPaneURL() {
        var opened: [URL] = []
        let access = AccessModel(status: .denied, probe: { .denied }, openURL: { opened.append($0); return false })
        access.openSettings()
        #expect(opened == [FullDiskAccess.settingsURL, FullDiskAccess.legacySettingsURL])

        opened = []
        let modern = AccessModel(status: .denied, probe: { .denied }, openURL: { opened.append($0); return true })
        modern.openSettings()
        #expect(opened == [FullDiskAccess.settingsURL])
    }

    @Test func continuingWithoutAccessLeavesLimitedModeNamingSkippedFolders() {
        let access = AccessModel(status: .denied, probe: { .denied }, openURL: { _ in true })
        access.showOnboarding()
        access.continueWithout()
        #expect(!access.isOnboardingPresented)
        #expect(access.isLimited)
        for folder in ["Mail", "Messages", "Safari", "Trash"] {
            #expect(access.skippedFolders.contains(folder))
        }
    }

    @Test func unknownIsNeverTreatedAsGranted() {
        let access = AccessModel(status: .unknown, probe: { .unknown }, openURL: { _ in true })
        access.refresh()
        #expect(access.isLimited)
    }
}
