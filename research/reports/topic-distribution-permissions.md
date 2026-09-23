# Topic: Distribution, permissions and update model

Board task: T-0011 (label `topic-distribution-permissions`). Date: 2026-09-23.
Checked on this Mac: macOS 26.6 (25G72), Xcode 26.6 (17F113), Swift 6.3.3, 8 CPU cores (4P + 4E).

Status key: **verified-locally** = reproduced on this Mac; **sourced** = primary or reputable source cited, not reproduced; **unverified** = could not check.

## Summary

1. **Ship outside the Mac App Store, Developer ID signed and notarized, not sandboxed.** Both reference apps installed on this Mac ship that way: PureMac and Radix. App Store rule 2.4.5 requires the sandbox, bans root escalation and bans any updater other than the App Store. DaisyDisk and CleanMyMac both removed their system-level features from their App Store editions.
2. **Use Sparkle 2 for updates** (2.10.0, MIT, minimum macOS 12). Sign every update with EdDSA, host the appcast on GitHub Releases, and add a Homebrew cask. Homebrew turns off casks that fail Gatekeeper from September 2026, so notarization is also required to be on Homebrew.
3. **Full Disk Access (FDA) cannot be requested through an API.** The good onboarding pattern is: open the right Settings pane, let the user drag the app in, check for the grant every second, then continue. **Two open-source apps check the grant wrongly.** PureMac and Pearcleaner read the system-wide TCC.db to decide. On macOS 26.6 any app can read that file without FDA, so they report "granted" when it is not (F-0001, confirmed here and reproduced by the T-0010 agent).
4. **Minimum macOS 14 is the best choice** (see Decisions). It gives Observation, SectorMark, inspector and ContentUnavailableView. By TelemetryDeck's figures it covers about 96% or more of Macs. Standard controls still get Liquid Glass on macOS 26 when built with the 26 SDK.
5. **Two Swift 6 gotchas affect a file scanner, and I confirmed both here.** (a) With Xcode 26's default settings, a `nonisolated async` scan function runs on the main thread unless it is marked `@concurrent`. (b) The Swift task thread pool has only as many threads as there are CPU cores (8 here). Blocking file-system calls inside tasks therefore wait in line and hold up other async work. Blocking I/O belongs on its own limited set of threads.

## Facts

### Distribution

| # | Fact | Evidence | Status |
|---|---|---|---|
| D1 | App Store apps "must be appropriately sandboxed" (2.4.5(i)), "may not request escalation to root privileges" (v), "must use the Mac App Store to distribute updates; other update mechanisms are not allowed" (vii), and may not auto-launch at login without consent (iii). | https://developer.apple.com/app-store/review/guidelines/ §2.4.5 | sourced |
| D2 | DaisyDisk's App Store edition lacks "Scan as administrator" and "Deleting 'stuck' files". It can only *detect* hidden space and purgeable space, not reveal or purge them. Reason given: "The Mac App Store guidelines limit what an app can and can't do". | https://daisydiskapp.com/guide/4/en/Editions/ | sourced |
| D3 | CleanMyMac's App Store edition lacks System Cache Files, System Log Files, Language Files, Universal Binaries, Free Up Purgeable Space, Thin Time Machine Snapshots and Reindex Spotlight, among others. | https://macpaw.com/support/cleanmymac/knowledgebase/missing-features | sourced |
| D4 | PureMac 2.9.4 on this Mac is signed with "Developer ID Application: Moamen Basel (H3WXHVTP97)", has hardened runtime (flags 0x10000) and `com.apple.security.app-sandbox = false`, and `LSMinimumSystemVersion` 13.0. `spctl` result: "source=Notarized Developer ID". Radix (`~/Downloads/Radix.app`) is Developer ID and notarized, has no entitlements (so no sandbox), requires 14.0, and bundles Sparkle. | `codesign -dvv`, `codesign -d --entitlements -`, `spctl -a -vv` | verified-locally |
| D5 | Notarization needs a Developer ID certificate ("Don't use a Mac Distribution, ad hoc, Apple Developer, or local development certificate"), Hardened Runtime, a secure timestamp and no `get-task-allow`. Since macOS 10.15, all Developer ID software built after 2019-06-01 must be notarized. `altool` has been rejected since 2023-11-01, so `notarytool` is required. | https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution | sourced |
| D6 | macOS 15 removed the Control-click override for Gatekeeper. Un-notarized apps now need System Settings → Privacy & Security → "Open Anyway" plus an admin password. | https://mjtsai.com/blog/2024/07/05/sequoia-removes-gatekeeper-contextual-menu-override/ , https://appleinsider.com/articles/24/08/06/apple-removes-control-click-option-for-skipping-gatekeeper-in-macos-sequoia | sourced (Apple's own news post not fetched) |
| D7 | Homebrew 5.0.0: "We will disable all Homebrew/homebrew-cask casks that fail Gatekeeper checks in September 2026". `--no-quarantine` is deprecated. | https://brew.sh/2025/11/12/homebrew-5.0.0/ | sourced |
| D8 | The Apple Developer Program costs 99 USD per membership year, and notarization is a member-only feature. | https://developer.apple.com/programs/whats-included/ , https://developer.apple.com/support/compare-memberships/ | sourced |
| D9 | This Mac has one code-signing identity, "Apple Development: …", and **no "Developer ID Application" identity**. It cannot produce a notarizable build today. `notarytool` 1.1.2 and `stapler` are installed. | `security find-identity -v -p codesigning`, `xcrun notarytool --version` | verified-locally |
| D10 | The Xcode 26.6 SDK allows deployment targets from 10.13 (recommended 11.0). Sparkle 2.10.0 notes say Xcode 27 drops the older targets. | `SDKSettings.plist` in MacOSX.sdk; https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0 | verified-locally / sourced |

### Updates (Sparkle)

| # | Fact | Evidence | Status |
|---|---|---|---|
| U1 | Sparkle: 9,742 stars. The LICENSE is MIT plus an external bsdiff BSD-style notice; GitHub reports `NOASSERTION`. Latest release 2.10.0 (2026-09-13) raised the minimum to macOS 12.0 and dropped CocoaPods. | `gh api repos/sparkle-project/Sparkle`, `.../contents/LICENSE`, `.../releases/latest` | sourced |
| U2 | Setup: SPM `https://github.com/sparkle-project/Sparkle`; Info.plist `SUFeedURL` and `SUPublicEDKey`; tools `generate_keys`, `sign_update`, `generate_appcast`; class `SPUStandardUpdaterController`. | https://sparkle-project.org/documentation/ | sourced |
| U3 | Defaults: Sparkle asks for permission to check automatically "on second launch". `SUScheduledCheckInterval` defaults to 86400 and `SUAutomaticallyUpdate` to NO. | https://sparkle-project.org/documentation/customization/ | sourced |
| U4 | Only a sandboxed app needs the Installer XPC service, `SUEnableInstallerLauncherService` and the `-spks`/`-spki` mach-lookup exceptions. A non-sandboxed Developer ID app needs none of these. | https://sparkle-project.org/documentation/sandboxing/ | sourced |
| U5 | Updates must be EdDSA-signed (`sparkle:edSignature`). Sparkle also supports `sparkle:minimumSystemVersion`, `sparkle:phasedRolloutInterval`, `sparkle:criticalUpdate` and channels. | https://sparkle-project.org/documentation/publishing/ | sourced |
| U6 | 8 apps on this Mac embed Sparkle (1.x–2.9.4). PureMac embeds Sparkle 2.9.4 but has **no `SUFeedURL` and no `SUPublicEDKey`**, so "Check for Updates" opens GitHub Releases in the browser (F-0003). | PlistBuddy on the installed Info.plists; PureMac@bef6083 `PureMac/Services/UpdateService.swift:18-35` | verified-locally + sourced |
| U7 | TCC stores each grant with the app's *designated requirement*. Radix's FDA row requires `identifier "com.colinkim.Radix"` and `certificate leaf[subject.OU] = "42MBX5D86L"`. So an update from the same team with the same bundle ID keeps the FDA grant. Changing the bundle ID or team loses it. | `sqlite3 -readonly` system TCC.db `access.csreq` piped to `csreq -r - -t` | verified-locally |

### Permissions (Full Disk Access and App Management)

| # | Fact | Evidence | Status |
|---|---|---|---|
| P1 | No API exists to request FDA or to query its status. Apple DTS: "the location and permissions of the TCC database is not considered API. A better option is to do what you're really trying to do and then handle errors". A command-line tool outside an app bundle is "not expected to work" with FDA. | https://developer.apple.com/forums/thread/114452 , https://developer.apple.com/forums/thread/107546 | sourced |
| P2 | On 26.6 the Settings extension `com.apple.settings.PrivacySecurity.extension` declares `legacyBundleIdentifier = com.apple.preference.security` and `allowsXAppleSystemPreferencesURLScheme = true`. `TCCServiceList.plist` maps anchor `Privacy_AllFiles` to `kTCCServiceSystemPolicyAllFiles` (`requiresAdmin` true, `supportsAddDeleteAction` true) and `Privacy_AppBundles` to `kTCCServiceSystemPolicyAppBundles` (App Management). So `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` and the legacy `…com.apple.preference.security?Privacy_AllFiles` both point at the same pane. | `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/{Info.plist,Resources/TCCServiceList.plist}` | verified-locally (plists). I did not actually open the URL, because that would pop up UI. |
| P3 | An app without FDA, launched through `open` so that it is its own TCC client, gets `EPERM` from `access(R_OK)`, `opendir` and `open` on `~/Library/{Safari,Mail,Messages,Cookies}`, `~/Library/Safari/Bookmarks.plist` and the **per-user** `~/Library/Application Support/com.apple.TCC/TCC.db`. `~/Library/Caches` stays readable. So `access()` is a valid one-syscall probe. | `scratchpad/topic-distribution-permissions/fdaprobe2.c` → `probe_app.out` | verified-locally |
| P4 | The **system** `/Library/Application Support/com.apple.TCC/TCC.db` (root:wheel 644, `restricted`) can be opened and read (header "SQLite format 3") by the same app without FDA. Any FDA check based on that file gives false positives. PureMac `FullDiskAccessManager.swift:17-28` and Pearcleaner `Utilities.swift:790` both rely on it. On this Mac the TCC row for `com.puremac.app` is `auth_value=0` (not granted). | `rd.c` → `rd.out`; independently reproduced in `scratchpad/topic-platform-constraints/fda.out`; filed as **F-0001** | verified-locally |
| P5 | Does an FDA grant reach an app that is already running, or only after a relaunch? **Sources conflict.** Pearcleaner has a "Retry" button (`PermissionsSheetView.swift:158-162`) and PureMac polls every 1 s and moves on automatically (`OnboardingView.swift:19,61-62`), so both authors expect the grant to take effect live. A third-party spec (https://github.com/fpcMotif/floodlight/issues/63) and consumer how-to pages say a relaunch is needed. Apple's support page says nothing either way. | `research/bench/fda-probe/run.sh`: a 2-minute manual check that needs a person to flip the switch | **unverified** |
| P6 | App Management (macOS 13): Gatekeeper blocks an app from modifying notarized apps from other teams, and the user gets a notification that leads to Settings. Apps from the same team are exempt, and `NSUpdateSecurityPolicy` can allow other updaters. According to lapcat, **FDA implies App Management**. | https://developer.apple.com/videos/play/wwdc2022/10096/ ; https://lapcatsoftware.com/articles/AppManagement.html | sourced (whether FDA covers App Management was not reproduced here) |
| P7 | PureMac's onboarding: it attempts protected reads so that it appears in the FDA list (`FullDiskAccessManager.swift:70-88`), polls every 1 s (`OnboardingView.swift:19,61-62`), reveals the app in Finder so the user can drag it into the list (`:99-102`), and runs `tccutil reset SystemPolicyAllFiles <id>` to clear stale rows after a Homebrew reinstall (`:109-121`). | momenbasel/PureMac@bef6083 | sourced |
| P8 | Failed attempts *usually* register the app: the system TCC.db has `auth_value=0` rows for apps that only tried, such as `com.puremac.app` and the T-0010 Swift probe. My C probe (`local.macontrol.research.fdaprobe`) did **not** get a row. So automatic registration is not guaranteed, and the "+ / drag the app" path must stay. | `sqlite3 -readonly` system TCC.db | verified-locally (partial) |

### Minimum macOS

| # | Fact | Evidence | Status |
|---|---|---|---|
| M1 | macOS availability: Table 12.0 · Charts, NavigationSplitView, MenuBarExtra, SMAppService 13.0 · Observation/`@Observable`, SectorMark, `inspector`, ContentUnavailableView, `onChange(of:initial:)`, `containerRelativeFrame`, SwiftData 14.0 · `TaskExecutor`/`withTaskExecutorPreference`, `Synchronization.Mutex`/`Atomic` 15.0 · `glassEffect`, `Chart3D`, `Observations` 26.0. | Apple docs JSON `developer.apple.com/tutorials/data/documentation/<symbol>.json` → `metadata.platforms` | sourced |
| M2 | TelemetryDeck (updated 2026-09-01), end of August 2026: 26.6 54.34%, 26.5 25.24%, 26.3 3.02%, 27.0 1.26%. Week of 2026-07-27: Tahoe 86.0%, 15.7 9.23%, 14.8 0.80%. | https://telemetrydeck.com/survey/apple/macOS/versions/ (the July figures come from the search summary) | sourced |
| M3 | macOS 26 is the last release for Intel Macs; macOS 27 runs only on Apple silicon. | https://www.theregister.com/2025/06/10/apple_macos_26_last_intel_support/ | sourced |
| M4 | Apps that use standard SwiftUI/AppKit components "pick up the latest look and feel" (Liquid Glass) when built with the latest SDK. That does not depend on the deployment target. | https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass | sourced |

### Swift 6 concurrency for a scanner

| # | Fact | Evidence | Status |
|---|---|---|---|
| S1 | Xcode 26 new projects default to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`. SE-0466 (default isolation) and SE-0461 (`nonisolated(nonsending)`, `@concurrent`) are both "Implemented (Swift 6.2)". | https://www.donnywals.com/setting-default-actor-isolation-in-xcode-26/ ; swift-evolution proposals 0466 and 0461 (status lines read with `gh api`) | sourced |
| S2 | With those settings, `nonisolated func scan() async` called from a `@MainActor` model **runs on the main thread** (`pthread_main_np()` returned true). With `@concurrent` it runs off the main thread. | `scratchpad/topic-distribution-permissions/iso.swift` | verified-locally |
| S3 | Default MainActor isolation also isolates plain helper functions to the main actor, so calling one from `@concurrent` code is a compile error. Scanner helpers must be marked `nonisolated`, or live in a module without default isolation. | same file, first compile | verified-locally |
| S4 | The Swift task thread pool had 8 threads, equal to `hw.ncpu`. 8, 32 and 64 blocking 200 ms tasks took 0.21 s, 0.82 s and 1.62 s: an effective width of 8. Apple: "The new thread pool will only spawn as many threads as there are CPU cores", and code in tasks must uphold "forward progress". | `iso.swift`; https://developer.apple.com/videos/play/wwdc2021/10254/ | verified-locally + sourced |
| S5 | A non-Sendable `final class Node` tree built in a `@concurrent` function can be returned to `@MainActor`, either as a plain return or as `sending`. Keeping a concurrent reference to it fails with `error: sending value of non-Sendable type … risks causing data races [#SendingRisksDataRace]`. **Gotcha:** `swiftc -typecheck` does not report this; the check runs at the SIL stage and needs a real compile (`-c`). | `tree.swift`, `treeAB.swift` | verified-locally |
| S6 | Task executors (SE-0417, macOS 15) let a task group run on a custom executor, for example dedicated I/O threads. | swift-evolution 0417 "Implemented (Swift 6.0)"; M1 availability | sourced |

## What this means for macontrol

1. **Channel.** Developer ID with notarization and stapling, distributed as a direct download (zip or dmg) plus a Homebrew cask, with no sandbox. The app's purpose needs things the App Store bans: system caches and logs, root-owned apps (see T-0010 for SIP and the sealed system volume), deletes through an admin helper, and an updater of its own. A reduced App Store edition is possible later, but only if the user wants one (Decision 2).
2. **Bundle identity is permanent.** TCC grants (U7), the Sparkle feed and the Homebrew cask are all tied to the bundle ID and team ID. Pick them once. Sign debug builds with the stable Apple Development identity, not ad-hoc. An ad-hoc signature's designated requirement is its cdhash, so every rebuild would lose the FDA grant. That last point is inferred from how designated requirements work and was not reproduced here.
3. **Updates.** Sparkle 2.10 with `SUFeedURL`, `SUPublicEDKey` and `SPUStandardUpdaterController(startingUpdater: true…)`. Accept Sparkle's second-launch consent prompt. The release script: `xcodebuild archive` → export → `notarytool submit --wait` → `stapler staple` → `ditto -c -k --keepParent` → `generate_appcast` → upload to GitHub Releases. Fail Release builds when either Info.plist key is missing (see F-0003 for what goes wrong otherwise).
4. **FDA onboarding** (improves on PureMac, fixes F-0001):
   - The probe is `open()` on the per-user `~/Library/Application Support/com.apple.TCC/TCC.db`, falling back to `~/Library/Safari`. It is three-state: granted, denied (EPERM) or unknown. The system TCC.db is never used.
   - At launch, probe once so macontrol usually appears in the FDA list (P8).
   - The "Open Settings" button opens `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` and falls back to the legacy `com.apple.preference.security?Privacy_AllFiles`.
   - Next to it, show a draggable app icon, with "Reveal in Finder" as a fallback, because automatic registration is not guaranteed.
   - Poll once a second while onboarding is visible, and again on `NSApplication.didBecomeActiveNotification`. Continue automatically when the probe returns granted.
   - If the user comes back and the probe still says denied after the toggle, offer **"Relaunch macontrol"**. This works whichever answer P5 turns out to have.
   - Without FDA the app still runs, with a banner that names the folders it skipped. It never shows a total that silently leaves out protected areas.
   - One FDA grant probably also covers App Management for uninstalling apps from other teams (P6). T-0010 owns confirming that.
5. **Minimum macOS 14.** Same as Radix, and it unlocks Observation, SectorMark (sunburst), `inspector` and ContentUnavailableView. Sparkle's floor (12) is lower, so it does not constrain the choice. On macOS 26, Liquid Glass comes free from the SDK (M4). Use `if #available(macOS 26, *)` only for explicit `glassEffect`.
6. **Scanner concurrency.**
   - Keep the UI module on MainActor default isolation, but put the scan engine in its own module or package **without** default isolation. Alternatively, mark every entry point `@concurrent` (S2, S3).
   - Run blocking enumeration (`getattrlistbulk`/`fts`) on a small, separately limited set of threads (a `DispatchQueue`, or a `TaskExecutor` if the minimum is 15), not on the task pool (S4).
   - Stream batched results to the main actor with an `AsyncStream` at about 10 Hz.
   - Build the tree off the main actor and hand it over with `sending` (S5).
   - Check for cancellation between directories.
   - Compile with `-c` in CI, not `-typecheck`, so the data-race checks run.

## Decisions for the user

1. **Apple Developer Program:** enroll (99 USD a year) and choose the name that appears in the Developer ID. Without it there is no notarization, no Homebrew cask and no clean first launch (D5–D9).
2. **Channel:** direct download plus Homebrew only (recommended), or also plan a reduced App Store edition later.
3. **Minimum macOS:** 14 (recommended: about 96% or more of Macs, Observation, SectorMark), 15 (adds TaskExecutor and Mutex, drops about 0.8% more), or 26 only (explicit `glassEffect` and `Chart3D`; macOS 26 was 86% in July).
4. **Bundle ID and team:** fix them now, for example `com.<you>.macontrol`, because the FDA grant, the Sparkle feed and the cask all depend on them.
5. **Update behaviour:** automatic download and install on or off by default, and whether to host the appcast on GitHub Releases or on your own domain.
6. **No-FDA mode:** allow a limited scan with a clear banner (recommended), or block the app until FDA is granted.
7. **Optional 2-minute check** (P5): run `research/bench/fda-probe/run.sh`, add the printed app under Full Disk Access, and see whether the log changes from `denied` to `granted` without a relaunch. The onboarding design above works either way.

## Local artefacts

- `research/bench/fda-probe/run.sh`: the manual live-grant check (smoke-tested for 3 s here: `user-TCC.db=denied system-TCC.db=granted`).
- Scratchpad (not committed): `scratchpad/topic-distribution-permissions/{fdaprobe2.c,probe_app.out,rd.c,rd.out,iso.swift,tree.swift}`.
- Analysis board: F-0001 (FDA false positive), F-0003 (PureMac Sparkle has no feed).
