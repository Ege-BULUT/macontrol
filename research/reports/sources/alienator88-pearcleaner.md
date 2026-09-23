# Source deep dive: Pearcleaner (alienator88/Pearcleaner)

Task T-0014, author `dive-alienator88-pearcleaner`, 2026-09-23. Paths are relative to the clone at
`research/sources/alienator88-pearcleaner` (commit `7724df7`, `git clone --depth 1`) unless they start with `http`.
"verified-locally" means I ran it on this Mac (macOS 26.6). "unverified" means I only read the code or a claim.
Reproduction code that transcribes Pearcleaner logic is kept out of git, in `research/sources/alienator88-pearcleaner-repro/`
(gitignored) because of the Commons Clause. macontrol-owned oracles are in `research/bench/uninstall-oracle/`.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/alienator88/Pearcleaner (homepage https://itsalin.com/appInfo/?id=pearcleaner) | `gh api repos/alienator88/Pearcleaner` |
| License | Apache-2.0 **+ Commons Clause** ("does not grant ... the right to Sell"). The API reports `NOASSERTION` | `LICENSE.md:1-15`, `README.md:120-122` |
| What it permits us | Read, study, run, modify for non-commercial use. It does **not** permit shipping its code in a product sold "for a fee or other consideration", and any notice must carry the Commons Clause text. **Decision: study only; no code or rule tables copied.** | `LICENSE.md:5-7` |
| Stars / forks | 14,715 / 380 | API, 2026-09-23 |
| Created / last push | 2023-11-13 / 2026-06-22 (README only). Last code commit `3222dc8`, 2026-01-30 | API, `commits?per_page=5` |
| Commits / contributors | about 1,007 / about 22 (incl. anonymous) | API Link headers `page=1007`, `page=22` |
| Latest release | 5.4.3, 2025-11-26, about 1.02 M asset downloads | `releases?per_page=5` |
| Status | "Project Status: On Hold ... issue responses, feature work, PR reviews, and new releases are effectively on hold indefinitely" | `README.md:7-18` |
| Language | Swift (1.91 MB by bytes; 47,270 lines in 109 files), a little ObjC (`Logic/PKG/PKBOM.h`) | API `/languages`, `wc -l` |
| Build | Xcode project, `SWIFT_VERSION = 5.0`, macOS 13.0+, sandbox off, hardened runtime on. SPM deps: Sparkle >= 2.8.0, AlinFoundation (author's own lib, MIT, **pinned to branch `main`**, `f61241c`), swift-argument-parser >= 1.5.0 | `project.pbxproj:1004,1032-1033,1050,1198-1217` |
| Open issues | 85 open issues + PRs; the first page of 50 has 40 issues and 10 PRs. Themes: **over-matching deletes user data** (#587 ~/Documents/OpenSCAD, #571 "chrome (film simulation)", #557 iPad "Wrapper" folders for Audacity, #553 ~/Public for Steam, #544 Docker, #546 printer prefs as orphan); Lipo breaks signed apps (#564, #561, #551, #575); updater loops (#570, #599, #558); a fake pearcleaner.com malware site (#603, #595, #592, #588, #585); macOS 27 (#600, #577) | `gh api .../issues?state=open&per_page=50` |

Lineage note (from T-0013): PureMac's uninstaller files `PureMac/Logic/Scanning/{AppPathFinder,Conditions,Locations,StringNormalization}.swift` are derived from Pearcleaner. The defects below that live in `AppPathsFetch.swift`/`Locations.swift` are therefore also present in PureMac@bef6083 (checked: `PureMac/Logic/Scanning/Locations.swift:49-50` scans `~/Documents` and `~/Desktop`; `AppPathFinder.swift:158-166` has the same vendor-folder escalation). PureMac dropped the bare `$HOME` root with the comment that it matched `~/.claude`, `~/.ssh` and invited data loss (`Locations.swift:44-47`); Pearcleaner still scans `$HOME` (`Logic/Locations.swift:59`).

## Summary

Pearcleaner is a free, source-available AppCleaner-style uninstaller that grew into a 10-page Mac utility: App Uninstall, Orphaned Files, Development environment cleaner, File Search, Homebrew manager, App Lipo (strip architectures), PKG manager, Plugins, Services (launchd) manager and an Apps Updater (`Logic/AppState.swift:680-689`, `README.md:51-69`). Extras: drag-and-drop, a `pear` CLI (`Logic/CLI.swift`), `pear://` deep links (`Logic/DeepLink.swift:30-58`), a Finder Sync extension (`FinderOpen/FinderOpen.swift`), a Trash-watching agent ("Sentinel", `PearcleanerSentinel/`) and a root helper (`PearcleanerHelper/`).

For macontrol it matters as the most-starred open reference for **leftover matching**: which roots to search, which identifiers to match (bundle id, name, app groups, iCloud containers, Team ID, binary names), special cases (web apps, wrapped iPad apps, Steam, container UUID folders) and a curated per-app include/exclude table. It is also a catalogue of what goes wrong with name-based matching: its open issues are mostly false positives, and I reproduced four of them (see Known problems). The deletion layer (shell strings through a root helper) is the part not to learn from.

## Architecture

- **One SwiftUI app target plus three small targets**: the `PearcleanerHelper` root daemon (208 lines, `SMAppService.daemon`, `Logic/HelperToolManager.swift:58`), the `PearcleanerSentinel` login agent (264 lines, `SMAppService.agent`, `Logic/Logic.swift:1368-1386`), and the `FinderOpen` Finder Sync extension (63 lines). `project.pbxproj:448,472,516,533`.
- **Layering is by folder only**: `Pearcleaner/Logic` 19,401 lines, `Pearcleaner/Views` 24,940 lines, `Style` 2,245. Views hold real logic: the dev-environment path table lives in `Views/DevelopmentView.swift:1603-1754`, launchctl commands are built in `Views/DaemonView.swift:974-987`, and the uninstall orchestration (kill, trash, brew cleanup, queue) is in `Views/FilesView/FilesView.swift:213-360`.
- **Global state**: 18 `static let shared` singletons (`grep -rn "static let shared"`), with `AppState.shared` (`Logic/AppState.swift`, 829 lines) as the hub. Settings are `@AppStorage` keys read from many files (for example `settings.general.searchSensitivity` in 5 files).
- **Concurrency is mixed**: GCD `DispatchGroup.wait()` + `concurrentPerform`-style chunking (`Logic/Logic.swift:45-53`, `AppPathsFetch.swift:262-276,771-795`), `Task {}` + `DispatchSemaphore.wait()` bridges (`Logic/UndoManager.swift:230-267`), `updateOnMain`, and `Task { @MainActor }`. Cancellation is a plain `var shouldStop = false` flag read from other threads (`Logic/ReversePathsFetch.swift:23,57-59`, `Logic/FileSearch/FileSearchLogic.swift:20,40`).
- **Engine shared by GUI and CLI**: `AppPathFinder` has `findPaths()` (GUI, async) and `findPathsCLI()` (sync) over the same predicate (`AppPathsFetch.swift:822-853`).

## Scanning

Pearcleaner has no whole-disk scanner or treemap. It has four narrow scans:

1. **App inventory** (`Logic/Logic.swift:133-350`): recursive `contentsOfDirectory` over the app folders on a concurrent queue, skipping symlinks and "restricted" apps (`Logic/Utilities.swift:149-155`: path contains `/Applications/Safari`, `/Applications/Utilities` or the app's own name). Metadata comes from Spotlight in one `MDItemCreate` per bundle, chunked in parallel (`Logic/AppInfoFetch.swift:392-470`): dates, bundle id, `kMDItemLogicalSize`, `kMDItemPhysicalSize` (fetched, never used), App Store Adam ID. It streams in two phases: a cheap `AppInfoMini` first, then entitlements, arch, cask and Team ID in the background (`Logic.swift:228-298`). **Take the two-phase idea.**
2. **Leftovers for one app** (`Logic/AppPathsFetch.swift`):
   - Roots: 63 fixed paths plus every `~/Library/Application Support/<dir>` (`Logic/Locations.swift:58-128`). They include `$HOME` (:59), `~/Documents` (:61), `~/Desktop` (:62), `/Applications`, `/private/var/db/receipts` (:112), `/private/tmp`, `/usr/local/*` and the `DARWIN_USER_CACHE_DIR`/`TEMP_DIR` found by running `/bin/bash -c "echo $(getconf ...)"` (`Logic/Logic.swift:353-381`).
   - Walk: `contentsOfDirectory` to depth 1, depth 2 for `~/Library` and `/Library` (`AppPathsFetch.swift:186-292`), one GCD task per root, `DispatchGroup.wait()` at the end. A 130-entry `skipDeepSearch` set prunes Apple folders at depth 1 (`Logic/Conditions.swift:218-256`).
   - Match keys (`AppPathsFetch.swift:55-131,323-433`): everything goes through `pearFormat()` (keep alphanumerics, lowercase; `Logic/Utilities.swift:703-720`), so "chrome (film simulation)" becomes `chromefilmsimulation`. Keys are the full bundle id (substring), app name, `.app` file name, letters-only name, "entitlements", last two bundle-id components (Enhanced+), company component of a 3-part id (Deep), Team ID (Deep), base bundle id with `helper|agent|daemon|...` stripped, and the version-stripped name (Enhanced+). Strict (the default, `AppPathsFetch.swift:32`) uses `==` for names and `contains` for bundle id. "Entitlements" are really app-group ids, iCloud container ids, **every binary name in `Contents/MacOS` of 5+ chars** and nested helper `.app` names (`Logic/AppInfoFetch.swift:691-760`). Minimum-length guard: a single-component bundle id must be at least 5 chars (`AppPathsFetch.swift:481-487`).
   - Containers: sandbox containers are found by reading `.com.apple.containermanagerd.metadata.plist` → `MCMMetadataIdentifier` in each UUID-named folder (`AppPathsFetch.swift:160-181`), and the group container through `containerURL(forSecurityApplicationGroupIdentifier:)` with the **bundle id** as group id (:151), which only hits apps whose group id equals the bundle id. **Take the MCM metadata lookup** (it is the only reliable way to attribute UUID containers).
   - Spotlight supplement over `NSMetadataQueryUserHomeScope`, with a 5 s timeout and a 500-result cap (`AppPathsFetch.swift:490-623`). Strict uses `kMDItemDisplayName ==[cd]`; Deep ORs name/path/comment/creator/copyright/encoding-application/`kMDItemTextContent` predicates.
   - Special cases: Steam game folders and `appmanifest_<id>.acf` via the id in the launcher's `run.sh` (:334-355, :447-469); web apps (container-only, :826-831); wrapped iPad apps (`Wrapper/` two levels up, :135-140).
   - Result handling: parent-wins dedupe (O(n²), :669-679), a per-app user exclusion list applied as a **substring** of the normalised full path (:662-667), and "zombie" file associations the user made earlier (:471-478).
3. **Orphans** (`Logic/ReversePathsFetch.swift`): depth-1 listing of 22 roots (`Locations.swift:133-156`). An item is an orphan unless its normalised path contains the bundle id, name or an "entitlement" (5+ chars) of any installed app (:227-255), or a condition include keyword (:257-278), or a `skipReverse` substring (146 words, `Conditions.swift:260`). Results stream to the UI in batches of 10 (:76-173). Anything owned by a non-app component (for example `org.cups.PrintingPrefs.plist`, issue #546) is flagged.
4. **File Search** (`Logic/FileSearch/FileSearchLogic.swift:199-265`): a sequential `FileManager.enumerator` with `totalFileSizeKey`, cancellable by flag.

**Sizes**: `totalSizeOnDisk` sums `.fileSizeKey` (logical) over a `FileManager.enumerator` (`Logic/Lipo.swift:437-475`), and files and bundles use `kMDItemLogicalSize` (`AppPathsFetch.swift:889-909`). No allocated size, no hard-link dedupe, no clone awareness. A sparse 1 GiB file (Docker.raw-style) reads 1,073,741,824 logical vs 0 allocated bytes (verified-locally, `stat -f '%z %b'`), so VM images are overstated. Already covered by F-0004 (clones) and the T-0009 table (`topic-size-accounting.md:98`); no new finding.

**Memory**: results are `[URL]`/`Set<URL>` plus a `[URL: NSImage?]` icon per result (`AppPathsFetch.swift:769-791`). Fine for hundreds of leftovers, and not a model for a disk map.

## Deletion & rules

- **Rules are Swift code, not data.** 26 per-app `Condition` entries (bundle-id substring → include/exclude keywords, `includeForce`/`excludeForce` paths) in `Logic/Conditions.swift:45-202`, the skip lists in the same file, the 26 dev environments in `Views/DevelopmentView.swift:1603-1754`. Adding a rule needs a release. For macontrol: load rules from a versioned JSON file and seed leftover paths from the Homebrew `zap` dataset (T-0005).
- **Selection**: every found item is pre-selected (`AppPathsFetch.swift:808`). The confirm dialog setting defaults to off (`Views/FilesView/FilesView.swift:25`); with it off, `showCustomAlert` runs `onOk` directly (AlinFoundation@f61241c `Sources/AlinFoundation/Utilities.swift:356-381`). A one-time sheet says "Always confirm the files marked for removal" (`FilesView.swift:95-126`).
- **Kill before delete**: `NSRunningApplication.terminate()` for the exact bundle id, without waiting for the exit (`Logic/Utilities.swift:363-370`, called at `FilesView.swift:228`). Helpers, login items and launchd jobs are not stopped. On the regular (non-Homebrew) path nothing calls `launchctl` (`grep launchctl` hits only `Brew/`, `DaemonView.swift` and the Sentinel toggle).
- **Trash, not rm**: `FileManagerUndo.deleteFiles` builds `/bin/mkdir -p "~/.Trash/<App>_<timestamp>"` plus one `/bin/mv "<src>" "<dst>"` per item, joins them with ` ; `, and runs the string through `runSUCommand` (`Logic/UndoManager.swift:62-174`). With the helper installed **every** delete runs as root, user files included (`Logic/Utilities.swift:855-857`). Otherwise it falls back to `AuthorizationExecuteWithPrivileges` found by `dlsym` (AlinFoundation `Sources/AlinFoundation/Authorization.swift:15-56`), and finally `/bin/sh -c` as the user (`UndoManager.swift:250-252,270-290`). Consequences:
  - shell injection by filename (F-0002, critical, already filed);
  - no Finder "Put Back" record; cross-volume items are copied into `~/.Trash` rather than the volume's `.Trashes` (inferred from `mv` semantics, unverified);
  - `filterValidFiles` silently clears the user's **Locked** (`uchg`) flag before moving (`Logic/Logic.swift:504-527,543-546`).
- **Undo**: in-session `UndoManager` plus a persistent `UndoHistory.json` of (original, trash) pairs that the Delete History page can restore (`Logic/UndoManager.swift:139-154`, `Logic/UndoHistoryManager.swift:64-88`). **Good idea to take (re-implemented)**: an uninstall grouped under one timestamped record with one-click restore.
- **Protection** is one function: an exact-match blocklist of 12 paths (`/`, `/Applications`, `/Library`, `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/private`, `/opt`, `$HOME`) plus the app folders (`UndoManager.swift:24-60`). `~/Documents`, `~/Library`, `~/Desktop`, `~/Public`, `/Library/Application Support` all pass (verified-locally with the extracted guard).
- **Privilege**: root helper via `SMAppService.daemon`, a generic `runCommand(String)` XPC API, PID-based caller check (`PearcleanerHelper/main.swift:13,48-51,86-88`), see F-0002.
- **Dry run**: the CLI has `pear list <path>` and `list-orphaned` (`Logic/CLI.swift:48-112`); `uninstall-all` has no prompt (`CLI.swift:147-202`, no `readLine`/confirm).
- **Homebrew path**: when the "brew cleanup" setting is on and the app has a cask, it runs `brew uninstall --zap` after trashing (`FilesView.swift:311-330`, `Logic/Brew/HomebrewUninstaller.swift:17,29-31`). A manual cask-directive interpreter with `pkill -9 -f '<AppName>'` as root and `launchctl bootout gui/$UID/...` run through the root helper (`HomebrewUninstaller.swift:145-200,412-437`) is **dead code** because `useBrewUninstallZap` is the constant `true` (:17). Do not copy it: against this Mac's process list, 41 of 4,002 cask app names regex-match unrelated running processes (e.g. cask `support` → `tccd`, `cloudd`; `look` → `quicklookd`), and `$UID` is 0 under the helper (verified-locally with `pgrep -f`-equivalent matching; output in `research/sources/alienator88-pearcleaner-repro/pkill_hits.txt`).
- **Sentinel**: FSEvents on `~/.Trash` with file-level events and latency 0 (`PearcleanerSentinel/FileWatcher.swift:84-92`). When a `.app` lands in the Trash it opens `pear://openApp?path=<path>` (`PearcleanerSentinel/main.swift:49-65`) and the main app shows the leftover list. `URL(string:)!` on an unescaped path (also in `FinderOpen/FinderOpen.swift:59`) truncates at `#` and can crash on macOS 13 for paths with spaces (unverified).
- **Sudo password cache**: for Homebrew `SUDO_ASKPASS`, the user's password is stored in the login keychain under `com.alienator88.Pearcleaner.SudoPassword` with a timeout (`Logic/KeychainPasswordManager.swift:4-30`, `Logic/CLI.swift:368-379`). macontrol should never handle the user's password.

## UI

SwiftUI with an AppKit `NSVisualEffectView` wrapper (`Style/Styles.swift:443-460`) and a custom theme system (`Style/Theme.swift`, 637 lines). Lists use `ScrollView { LazyVStack }`, with a `LazyVGrid` grid mode for apps (`Views/AppsView/AppsListView.swift:20-22,151`, `Views/FilesView/FileListView.swift:153-180`). Interaction: drag an app onto the window or Dock icon, Finder right-click "Pearcleaner Uninstall" (Finder Sync on `/`, `FinderOpen.swift:17-29`), deep links, a debug console (Cmd+D), badges for web and iOS apps, per-file size and icon, and a sidebar with app details. There is no disk visualisation, no drill-down and no "reveal in Finder" beyond the per-file context menu (not checked in depth). Visual quality is high by user reports and screenshots (`README.md:73-77`), but screen density comes from 10 feature pages, which is the opposite of macontrol's "fast and sleek" goal.

## Tests & quality

- **No tests.** No test target in `project.pbxproj` (product types are 1 app, 2 tools, 1 extension), no `*Test*` files, and the only workflow is `.github/workflows/issues.yml`. With a matcher this heuristic, the lack of a fixture suite explains the steady flow of false-positive issues.
- Large files (`SearchInstallSection.swift` 3,073 lines, `HomebrewController.swift` 2,337), commented-out code (`Logic/Logic.swift:1282-1338`), `try!` on the privileged path (`UndoManager.swift:236`), a dependency pinned to a moving branch (AlinFoundation `main`).
- Bus factor of one, and the author says he has no Mac to build on (`README.md:12`).

## Known problems

Verified-locally items used `research/sources/alienator88-pearcleaner-repro/repro.swift`, a faithful transcription of the Strict-mode walk, predicate, dedupe, `Conditions` entries and delete guard, run on a scratch fixture. `research/bench/uninstall-oracle/fixture.sh` rebuilds the same fixture as a macontrol oracle.

1. **User data matched by name, pre-selected and deleted** (issues #587, #571, #553). Reproduced in Strict mode: OpenSCAD → `~/Documents/OpenSCAD` (with a `.scad` project inside); Google Chrome → `~/Documents/chrome (film simulation)` (via the `chrome` include keyword, `Conditions.swift:88-93`); an app named Claude → `~/.claude`. All pass the delete guard. → the same defect as **F-0011** (filed for PureMac's copy of this code). The Pearcleaner-specific evidence (Strict mode also hits, `$HOME` root, binary-name keys, confirm dialog off by default) is in a comment on T-0014. The guard itself is **F-0024**.
2. **Vendor-folder escalation**. A depth-2 match under `~/Library` or `/Library` adds the *parent* when the parent is not a standard Library folder (`AppPathsFetch.swift:213-224`). Reproduced: LuLu → the whole `~/Library/Application Support/Objective-See` including BlockBlock's rules; PyCharm → the whole `~/Library/Application Support/JetBrains` (also forced by `includeForce`, `Conditions.swift:160-165`) including IntelliJ settings. → **F-0022**.
3. **Launchd jobs survive uninstall**. Plists and helper binaries are moved but never booted out. Verified-locally with `research/bench/uninstall-oracle/launchd_probe.sh`: after `/bin/mv` of the plist the job stays `running`, and after the process exits launchd goes to `spawn scheduled`. → **F-0023**.
4. Binary names as match keys: `Contents/MacOS/*` names of 5+ chars become exact-match keys in Strict and substring keys in Enhanced (`AppInfoFetch.swift:728-740`, `AppPathsFetch.swift:357-367`). This likely explains #557 (Audacity vs every iPad app's `Wrapper/` folder); I did not confirm that Audacity ships a `Wrapper` binary (unverified). Locally, Android Studio's binary is `studio`, which in Enhanced mode matches any item containing "studio". Evidence for F-0011.
5. `pathComponentName` is not normalised (`AppPathsFetch.swift:84`) but is compared with normalised names (:388), so it never matches unless the `.app` name is already lowercase alphanumeric. A dead check.
6. Wrapped-app detection is `url.path.contains("Wrapper")` (`AppPathsFetch.swift:137`), so any app under a folder whose path contains "Wrapper" gets its grandparent collected. `validatePath` blocks it only if the grandparent is exactly `/Applications` or an app folder.
7. The delete guard is an exact-match list of 12 paths and silently clears the user's Locked flag (`UndoManager.swift:24-60`, `Logic.swift:504-546`): **F-0024**.
8. The FDA check reads the system TCC.db (`Utilities.swift:790`): F-0001. Root helper shell injection: F-0002.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Leftover root list | study | `Logic/Locations.swift:58-156` | Good coverage (receipts, `DARWIN_USER_*_DIR`, crash reporters, SDK caches such as Sparkle/Sentry/Crashlytics). Rebuild our own list without `$HOME`, `~/Documents` or `~/Desktop`, and cross-check it against the Homebrew zap dataset. Commons Clause: no copying |
| Match predicate (bundle id, name, groups, Team ID, base id) | rewrite | `Logic/AppPathsFetch.swift:55-131,323-433` | Right identifiers, wrong model. Replace the OR of substrings with evidence-scored candidates: exact bundle-id/group/MCM hits are pre-selected; name-only hits are shown unselected with the reason |
| Container attribution via `MCMMetadataIdentifier` | take (re-implement) | `AppPathsFetch.swift:160-181` | The correct way to map UUID containers to bundle ids; a few lines, no code needed from them |
| Per-app Conditions table | improve | `Logic/Conditions.swift:45-202` | Useful knowledge (Xcode vs Xcodes, Firefox vs Thunderbird, VS Code vs Insiders). Move it to versioned JSON with tests, and use exact tokens instead of substrings like `chrome` or `google` |
| `skipReverse` / `skipDeepSearch` lists | study | `Conditions.swift:218-260` | Hand-grown denylists that show where orphan scans go wrong. We need an allowlist of attributable owners instead |
| Orphan finder | rewrite | `Logic/ReversePathsFetch.swift` | "Not matched to an installed app" is not "orphan" (#546). Also check LaunchServices for any registered bundle id and executable paths in launchd plists |
| Two-phase app inventory via Spotlight | take (idea) | `Logic/Logic.swift:228-298`, `AppInfoFetch.swift:392-470` | Fast first paint with MD attributes, then expensive fields. Fall back to a filesystem walk when the index is off |
| Deletion via `mv` shell strings through a root helper | ignore | `Logic/UndoManager.swift`, `PearcleanerHelper/main.swift` | Unsafe (F-0002), no Put Back, clears the user's lock flag. macontrol uses `FileManager.trashItem` in-process and a typed helper API for root-owned items |
| Persistent undo history | take (idea) | `Logic/UndoHistoryManager.swift`, `Views/DeleteHistoryView.swift` | One record per uninstall with restore. Pair it with `trashItem` result URLs |
| Trash watcher (Sentinel) | improve | `PearcleanerSentinel/` | Nice UX (drag to Trash → offer cleanup). Use FSEvents with directory-level latency > 0, and escape the path in the URL |
| Finder Sync extension on `/` | study | `FinderOpen/FinderOpen.swift` | A Services menu item or `NSExtension` action is lighter than Finder Sync on the whole disk. Decide in UX |
| Homebrew `brew uninstall --zap` hand-off | take (idea) | `Views/FilesView/FilesView.swift:311-330` | For cask-installed apps, let brew run its curated zap. The manual interpreter (`HomebrewUninstaller.swift:145-437`) is dead code with unsafe `pkill -f`: ignore |
| Dev-environment path table | study | `Views/DevelopmentView.swift:1603-1754` | Mixes caches with installs (`~/anaconda3/`, `~/.cargo/`). Our cleaner must mark "regenerable cache" vs "installed toolchain" |
| Lipo / language pruning | ignore | `Logic/Lipo.swift`, `Logic/Logic.swift:640-795` | Breaks code signatures (#564, #561, #551). Out of scope for macontrol |
| Sudo password keychain cache | ignore | `Logic/KeychainPasswordManager.swift` | Handling the user's password is a liability |

## Open questions

- Does `FileManager.trashItem` from a root helper put items into the *user's* Trash with Put Back for root-owned `/Library` files? That decides whether the helper API is `trash` or `remove` for system leftovers (T-0010 has the in-process case verified).
- Does macOS clean up Background Task Management (`SMAppService`) registrations when the owning app is trashed, or do stale Login Items remain until `sfltool resetbtm`? Pearcleaner has a last-resort `sfltool resetbtm` for its own helper (`Logic/HelperToolManager.swift:320-332`). Unverified.
- #557 root cause: does Audacity 3.x ship `Contents/MacOS/Wrapper`? It would confirm the binary-name key theory (unverified; the Audacity master tree has no such target).
- #553 (`~/Public` for Steam in Strict mode): I could not derive it from the code I read. Possibly a Spotlight hit or a binary name. Open.
- Does Spotlight `kMDItemLogicalSize` for `.app` bundles match a filesystem sum on APFS with compressed bundles? Pearcleaner trusts it for app size sorting (`AppInfoFetch.swift:62,166-173`).
