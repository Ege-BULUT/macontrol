# Source deep dive: PureMac (momenbasel/PureMac)

Task T-0013, author `dive-momenbasel-puremac`, 2026-09-23. All paths are relative to the clone at
`research/sources/momenbasel-puremac` (commit `bef6083`, `git clone --depth 1`), unless they start with `http`.
"verified-locally" means I ran it on this Mac (macOS 26.6, 25G72). "unverified" means I only read the code or a claim.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/momenbasel/PureMac (homepage https://www.moamenbasel.com/PureMac/) | `gh api repos/momenbasel/PureMac` |
| License | MIT ("Copyright (c) 2026 PureMac Contributors"), with one exception: see Lineage below | `LICENSE:1-3`, API `license.spdx_id=MIT` |
| Stars / forks | 6,677 / 374 | API, 2026-09-23 |
| Created / last push | 2026-04-08 / 2026-09-23 (last commit `bef6083` "chore: refresh star history") | API, `git log -1` |
| Commits | about 181 | API `commits?per_page=1` Link header, `page=181` |
| Language | Swift 5.9 (about 25.9k lines across the app, CLI and tests), SwiftUI app plus a SwiftPM CLI | `project.yml:16`, `wc -l` |
| Min OS | macOS 13.0 | `project.yml:9,17` |
| Build | xcodegen (`project.yml`), Sparkle 2 SPM package; CI runs `xcodegen generate`, `xcodebuild test`, and `swift test` for the CLI | `project.yml:2-5`, `.github/workflows/build.yml` |
| Sandbox | off (`com.apple.security.app-sandbox = false`) | `PureMac/PureMac.entitlements` |
| Open issues | 0 open issues. The 14 open items are all PRs: localizations, a settings page, new cache targets (Gradle/.NET, Puppeteer/Playwright, AI caches, Git worktrees, XcodeBuildMCP) | `gh api .../issues?state=open` |

### Lineage (matters for reuse)

The uninstaller engine appears to be derived from **Pearcleaner** (alienator88/Pearcleaner, Apache-2.0 **+ Commons Clause**). PureMac ships it as MIT, with no credit and without the Commons Clause notice.

- PureMac commit `f2eeceeb` ("v2.0.0 - Complete architecture overhaul", 2026-04-14) added `PureMac/Logic/Scanning/{AppPathFinder,Conditions,Locations,StringNormalization}.swift` (`gh api repos/momenbasel/PureMac/commits/f2eeceeb`).
- Those files share distinctive identifiers and data with `Pearcleaner/Logic/{Conditions,Locations,AppPathsFetch}.swift`: `skipReverse`, `skipDeepSearch`, `darwinCT()`, `listAppSupportDirectories`, `standardLibrarySubdirectories`, the `MCMMetadataIdentifier` container lookup, `bundleLastTwoComponents`, and rule strings such as `comappleconfigurator`, `cleaner for xcode`, `embeddedbinaryvalidationutility`, `aaprofilepicture`, and the `PasswordManagerBrowserExtensionHelper` path. The grep counts match 1:1 (I fetched the Pearcleaner files with `gh api .../contents`).
- `README.md:266-275` (Acknowledgments) does not mention Pearcleaner. `README.md:90-102` only compares PureMac with it.
- **Consequence:** treat those four files, plus the rule tables `skipReverse` and `skipDeepSearch` that `AppState.findOrphans` and `OrphanListView` use, as Pearcleaner-licensed: **study only**. The rest of the repo shows no such overlap (I searched for the same markers and found no hits) and can be treated as MIT. I posted this to T-0014 (Pearcleaner deep dive) and T-0003 (license matrix).

## Summary

PureMac is a free SwiftUI "CleanMyMac alternative" with these parts:
- **Smart Scan** runs 12 cleanup categories. Two of them (Universal Binaries, Language Files) are withdrawn, and Purgeable is display-only (`Models.swift:6-19,80-120`).
- An **App Uninstaller** with heuristic leftover discovery, an **Orphan Finder**, **Space Explorer** (a list-based folder size browser), and a **Duplicate Finder**.
- A **Similar Photos** finder, **Protection audit** (firewall, FileVault and similar settings), **Performance** view (login and background items), and **App Updates**.
- A **menu bar monitor**, a Finder **Services** entry "Uninstall with PureMac" (`PureMacApp.swift:33-37`), a **scheduled scan with optional auto-clean**, 12 localizations, and a separate **CLI** (`cli/`, `puremac clean|purge|analyze|optimize`).

The project is young (5.5 months old) and moves fast. A large part of the code is defensive: most guards are commented with the issue that caused them.

That history is the most useful thing to learn from. Three incidents shipped to users:
- **#142:** the cache cleaner deleted live iCloud/FileProvider state and corrupted File Provider sync.
- **#144 / #135:** bundle thinning and ad-hoc re-signing broke 21 apps in one run. The feature was withdrawn in 2.9.5.
- **#112:** "APFS Purgeable Space" used `/` as its path and showed the root directory as a deletion target.

Each fix left behind a guard that macontrol should have from day one.

The disk-visualization side is weak. Space Explorer is a sorted list with bars, has no treemap or sunburst, rescans on every navigation, and cannot delete. The scan engine is single-threaded FileManager enumeration.

## Architecture

- **App layers:** `PureMac/Services/*` holds the engines, mostly `actor`s (`ScanEngine` `ScanEngine.swift:3`, `CleaningEngine` `CleaningEngine.swift:3`, `StorageExplorer` `StorageExplorer.swift:72`). `PureMac/Logic/Scanning/*` holds the uninstaller heuristics (`AppPathFinder` is a class that uses GCD), `PureMac/ViewModels/AppState.swift` is a 1,183-line `@MainActor ObservableObject` god object that orchestrates scans, cleans, uninstall, orphans, selection, scheduler and FDA, and `PureMac/Views/*` is SwiftUI.
- **UI to engine boundary:** views call `AppState` methods. `AppState` awaits the actors and republishes `@Published` state. Scan-path progress lives in a separate small `ScanProgressTicker` so a 10 Hz update does not invalidate the whole tree (`AppState.swift:38-47`, fix for #119/#120).
- **CLI:** `cli/Package.swift` is its own SwiftPM package with a **duplicated** engine: `Core/Catalog.swift` (targets), `Core/Safety.swift` (denylist, copied from `ProviderPaths`), `Core/Scanner.swift`, `Core/Cleaner.swift`. Nothing is shared with the app target, so the rules drift. For example, the CLI has Cargo, Go, Gradle, uv, Bun and NuGet targets (`Catalog.swift:15-43`) that the app's `ScanEngine` does not have.
- **Privilege:** there is no helper tool. Root actions use `NSAppleScript` "do shell script ... with administrator privileges" (`CleaningEngine.swift:271-287`).
- **Permissions:** `FullDiskAccessManager` and `PermissionCoordinator` probe TCC by reading protected files (`FullDiskAccessManager.swift:16-35`). F-0001 already covers the false positive in that probe.
- **Updates:** Sparkle is linked but has no feed (covered by F-0003).

## Scanning

**Cleanup scan (`ScanEngine`, actor).**
- Categories run **sequentially**: a `for` loop in `AppState.beginScan` (`AppState.swift:900-925`). Each category walks its targets serially inside one actor. Nothing is parallel: no `TaskGroup`, and the only concurrency is `AppPathFinder.findPathsAsync`.
- **APIs:** `FileManager.contentsOfDirectory(atPath:)` plus `fileExists`, `attributesOfItem` (lstat) and `FileProtection` (lstat + listxattr) per top-level child (`ScanEngine.swift:982-1053`). Directories are sized with `FileManager.enumerator(... .skipsHiddenFiles)` summing `totalFileAllocatedSize ?? fileSize` over regular files (`ScanEngine.swift:1112-1143`).
- **Size semantics are mixed:**
  - Directories are measured by allocated size (`:1137`).
  - Loose files in `scanDirectory` use logical `attrs[.size]` (`:1036`).
  - Large Files uses logical `.fileSizeKey` (`:357,379`).
  - Trash emptying uses `attrs[.size]` of the top entry, which for a directory is only the inode's size (`CleaningEngine.swift:474-476`).
  - There is no hard-link dedupe in `ScanEngine`.
  - Hidden files are skipped when sizing but still deleted. verified-locally, the gap is small: 36,864 B of 312.6 MB on `~/.npm` and 0 B on `~/Library/Caches/Homebrew`. I ran a replica of `directorySize` with and without `.skipsHiddenFiles`.
  - Clones are counted at full size (F-0004).
- **Progress:** throttled path reporting, at most about 10 per second, with an `@autoclosure` so the path string is only built when shown (`ScanEngine.swift:7-21`).
- **Cancellation:** `Task.isCancelled` checks in the loops (`:998,1130`). The "sleeping" helpers `getLocalSnapshots` and `getSnapshotSize` run `tmutil` and `diskutil` synchronously. They call `waitUntilExit()` before draining the pipe (`:1169-1171,1220-1222`), which is the same deadlock pattern the Docker code documents and avoids (`CleaningEngine.swift:357-361`). `getSnapshotSize` spawns one `diskutil apfs listSnapshots` per snapshot.
- **Command-derived paths are validated** before use:
  - `brew --cache` output must fall under known roots, and `HOMEBREW_*` is stripped from the child's environment (`ScanEngine.swift:535-585`).
  - npm, yarn and pnpm output must resolve inside approved roots (`:699-762`).
  - Sandboxed container `Data/Library/Caches` paths must resolve to themselves (`:198-203`).

**Space Explorer (`StorageExplorer`, actor).**
- An explicit DFS stack with `contentsOfDirectory(at:includingPropertiesForKeys:)` plus one `lstat` per entry (`StorageExplorer.swift:203-305,313-327`). Sizes are `st_blocks*512`, and directory inode blocks are included.
- Hard links are deduped by `(st_dev, st_ino)` in a set that holds **every** file, not only files with `st_nlink>1` (`:92,266`). Memory therefore grows with the file count.
- Dataless (`SF_DATALESS`) and non-downloaded ubiquitous items are skipped and counted (`:225-240,307-311`). The result carries `skippedCount` and `inaccessibleCount`, and the UI shows "Partial result" (`SpaceExplorerView.swift:379-383`). That honesty is worth copying.
- Progress is sent every 64 entries (`:280-292`). Each progress callback spawns a `Task { @MainActor }` (`SpaceExplorerView.swift:97-101`).
- **Memory model:** only the top-level children of the chosen folder are kept (`StorageScanResult.entries`). The subtree is thrown away, so every drill-down or Back rescans from disk (`SpaceExplorerView.swift:51-68`).
- Symlinked or package roots are refused (`StorageExplorer.swift:126-131`).

**Uninstaller discovery (`AppPathFinder`, Pearcleaner lineage).**
- A name-matching walk over more than 60 roots (`Locations.swift:42-109`), plus every `~/Library/Application Support/*` subfolder (`:111-115`).
- Depth is 2 for `~/Library` and `/Library` and 1 elsewhere (`AppPathFinder.swift:86-90`).
- The matcher is substring `contains` on normalized names (`AppPathFinder.swift:216-283`). There are three sensitivity levels, and the app always uses `.enhanced` (`AppState.swift:1180`). `minMatchTokenLength = 5` guards against very short names (`:199`).
- Containers are found by reading `.com.apple.containermanagerd.metadata.plist` `MCMMetadataIdentifier` (`:307-340`).
- `findPathsAsync` fans out one GCD block per location (`:100-126`).

## Deletion and rules

**Where the rules live:** Swift arrays, not data.
- Cleanup targets: `ScanEngine.swift` (per-category literals, e.g. `:121-128,165-168,235-272,447-464,811-831`) and, separately, `cli/Sources/puremac/Core/Catalog.swift:15-80`.
- Delete allowlist: `CleaningEngine.isSafeToDelete` (`CleaningEngine.swift:493-568`).
- Provider denylist: `Logic/Utilities/ProviderPaths.swift:21-63`.
- Orphan allowlist and blocklist: `Logic/Utilities/OrphanSafetyPolicy.swift:7-35`.
- Uninstaller rules: `Logic/Scanning/Conditions.swift` (`appConditions` :63, `skipConditions` :323, `highRiskHomeDotPaths` :354, `skipDeepSearch` :398, `skipReverse` :457). `AppCondition` is `Codable` (`:18`), but it is only ever built in code.

**Mechanics:**
- Category cleanup **permanently deletes** with `FileManager.removeItem` (`CleaningEngine.swift:159`). The README says so (`README.md:108`).
- On EACCES or EPERM, items go to an admin pass: `xargs -0 /bin/rm -rf -- < tmpfile` as root through NSAppleScript (`CleaningEngine.swift:208-327`). Paths are re-validated against the allowlist first (`:213-237`).
- The admin pass compares inodes before and after so a log file that its daemon recreates is not reported as a survivor (`:253-259,309-318`). There is no per-path identity check between validation and the root `rm` (unverified as exploitable, noted as a gap).
- Uninstall and orphans use `trashItem` (`AppState.swift:369`, `OrphanListView.swift:236`), except that uninstall's admin fallback goes through the same root `rm -rf`. The UI warns about this (`AppFilesView.swift:133`).
- Duplicates are trashed after the keeper and every selected file are re-hashed (`DuplicateFinder.swift:354-383`).

**Protections worth keeping:**
- Symlink component walk (`CleaningEngine.swift:736-749`), then re-resolve right before the unlink (`:148-157`).
- Large files may only be deleted one file at a time under Downloads, Documents or Desktop (`:755-767`).
- SIP, `SF_RESTRICTED`, immutable and `com.apple.rootless` entries are skipped quietly (`FileProtection.swift:13-41`).
- The iCloud/FileProvider denylist, which also resolves symlinks because a synced `~/Documents` resolves into `Mobile Documents` (`ProviderPaths.swift:42-63`).
- User exclusions that protect in both directions, ancestor and descendant, with a resolved form for paths that do not exist yet (`CleanupExclusions.swift:17-43`).
- Credential dotdirs are never matched or trashed (`Conditions.swift:354-391`, `AppState.swift:285-296`).
- Categories that modify apps are withdrawn behind `scannable` and refused unconditionally in `BinaryThinner.stagedModify` (`Models.swift:80-120`).

**Gaps:**
- No dry-run in the GUI. The CLI has `--dry-run` and an identity-since-scan check (`cli/.../Cleaner.swift:25-47`).
- No persistent record of what was deleted. `Logger` is os_log plus a 1,000-entry in-memory ring (`Logger.swift:28-58`), and successful user-level deletes are not logged per path (`CleaningEngine.swift:159-162`). The maintainer confirmed that "Persistent cleanup history and rollback/quarantine did not ship" in #142: https://github.com/momenbasel/PureMac/issues/142
- Auto-clean can escalate and delete permanently with nobody at the Mac (see Known problems).

## UI

- **Stack:** SwiftUI with `NavigationSplitView`, Swift Charts `BarMark` for the category chart (`DashboardCharts.swift:124-150`), a custom `HealthRing` and `StorageDonut` (`DashboardCharts.swift:4-120`), an AppKit `NSStatusItem` for the menu bar monitor (`PureMacApp.swift:134-140`), and confetti and haptics on clean (`ConfettiView.swift`, `Haptics.swift`). Reduce Motion is respected in removal animations (`AppState.swift:397-403`). `docs/IMPROVEMENT-RESEARCH.md` is the maintainer's own UX research, CleanMyMac-inspired.
- **Space Explorer:** a card list sorted by size with a capsule share bar, click to drill down, a Back button, "Show in Finder" per row and in a context menu, and chips for skipped and inaccessible counts (`SpaceExplorerView.swift:119-555`). There is no treemap or sunburst, no breadcrumbs beyond Back, no delete, no multi-select, and no keyboard navigation. The rows are `LazyVStack` inside a `ScrollView` (`:308-339`).
- **Cleanup review:** filters for search, size, age and sort (`Models/CleanupReview.swift`). A confirmation sheet warns when selected rows are hidden by the filter (README:112).
- **Performance history:** the scan ticker republishing the whole tree about 10 times per second caused UI lag and an apparent freeze (#119, #120), fixed by isolating the ticker (`AppState.swift:38-47`).

## Tests and quality

- 102 XCTest methods in 15 files under `PureMacTests/` and 56 tests in the CLI. CI runs both on macos-15 (`.github/workflows/build.yml`).
- Good safety tests exist, for example `CleaningEngineTests.swift:58-118`: a symlink or symlinked parent is refused, a dangling symlink is not reported as cleaned, excluded files are never deleted, and categories that modify apps never reach file deletion. `StorageExplorerTests`, `CleanupExclusionsTests` and `DuplicateFinderTests` also exist.
- **No tests cover `AppPathFinder`** (uninstaller matching) or the `ScanEngine` category scanners. `grep -l "AppPathFinder\|scanCategory" PureMacTests` finds nothing.
- Dead code:
  - `SchedulerService.installLaunchAgent` and `uninstallLaunchAgent` have no callers, and `--scheduled-clean` is never parsed (`SchedulerService.swift:99-148`).
  - `ScanEngine.getLocalSnapshotSize` (`ScanEngine.swift:1246`) and `CleaningEngine.emptyTrash` (`CleaningEngine.swift:465`) are never called.
  - `CleaningEngine.purgePurgeableSpace` runs `diskutil apfs purgePurgeable /` (`CleaningEngine.swift:443-445`). That verb is not in the `diskutil apfs` verb list on macOS 26.6 (verified-locally; a hidden verb is unverified). The category is no longer scannable, so this path is dead too.
  - `/System/Applications` is walked and then every result is dropped (`AppInfoFetcher.swift:58-83`).
- Comments are thorough and tie each guard to an issue. `AppState` is too large, and the app/CLI engine duplication is the main structural debt.

## Known problems

Findings filed on the analysis board: F-0011, F-0012, F-0013, F-0014. Existing findings that also cover PureMac: F-0001 (FDA probe), F-0003 (Sparkle with no feed), F-0004 (clones sized at full size).


1. **Uninstaller matches user documents by substring and preselects them.** `~/Documents` and `~/Desktop` are search roots (`Locations.swift:49-50`), and matching is `contains` (`AppPathFinder.swift:243-255`) with recursion to depth 1 (`:174-181`). All hits are preselected (`AppState.swift:264`). verified-locally: I compiled the four scanning files with a probe main. For an app "Sketchbook" (`com.example.sketchbook`), it returned `Docs/Sketchbook Drawings.psd`, `Docs/Sketchbook Projects/` and `Docs/Work/sketchbook-notes.txt`, and not `Docs/Unrelated.txt`. The files go to the Trash, which softens the damage. Filed as **F-0011**.
2. **Cleanup is irreversible and unrecorded** (`CleaningEngine.swift:159,271-274`). There is no quarantine, undo or audit log. #142 shows the cost: the user could not tell which category corrupted iCloud state because there was no log. Filed as **F-0012**.
3. **Space Explorer rescans the whole subtree on every drill-down and Back**, single-threaded, and keeps no tree (`SpaceExplorerView.swift:51-68`, `StorageExplorer.swift:112-201`). Filed as **F-0013**. F-0009 covers the serial-walk speed.
4. **Scheduled auto-clean runs unattended and can pop an admin password prompt.** `SchedulerService` fires from a 60-second `Timer` (`SchedulerService.swift:42-46,73-84`), which calls `AppState.runScheduledScan`, which calls `cleanAll()` (`AppState.swift:1144-1146`). `cleanAll` escalates any `requiresAdmin` items through NSAppleScript (`AppState.swift:950-958`), and pre-selected System Junk covers root-owned `/Library/Caches` and `/private/var/log` children (`ScanEngine.swift:121-131`). `autoClean` defaults to false (`Models.swift:225`). Filed as **F-0014**.
5. The broad delete allowlist includes whole `~/Library/Application Support`, `~/Library/Preferences` and `~/Library/Containers` roots, and equality with a root counts as allowed (`CleaningEngine.swift:514-518,562-567`). So any bug upstream in item construction can wipe a whole root. The CLI's `criticalRoots` refusal (`cli/.../Safety.swift:22-30,132`) is the better model and was never ported to the app.
6. The User Cache category pre-selects every `~/Library/Caches/*` child over 1 KB (`ScanEngine.swift:139-162`, default `isSelected: true`). #142 was the result. Provider roots are now denied, but other live-state caches remain a risk (unverified which).
7. The `README.md:144` claim "Trash Bins - empties all bins, including external volumes" does not match the code: `scanTrash` only reads `~/.Trash` (`ScanEngine.swift:304-313`), and there is no `/Volumes` handling in `ScanEngine.swift`.
8. The 10-level matcher's "vendor folder" promotion adds the **parent** of a depth-2 match when the parent is not a standard Library subfolder (`AppPathFinder.swift:156-168`). So one Adobe app can pull in `~/Library/Application Support/Adobe` whole. unverified on a real install; this is inferred from the code.
9. Scope issues seen in closed issues: FDA detection problems (#75, #78, #81, #87, #89, #91, #93) and Launchpad icon glitches (#73, #111, #115).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| iCloud / FileProvider denylist | take | `PureMac/Logic/Utilities/ProviderPaths.swift` | MIT and small. Encodes the #142 incident, including the check on the symlink-resolved path and the `com~apple~` component rule |
| SIP / immutable skip | take | `PureMac/Logic/Utilities/FileProtection.swift` | `SF_RESTRICTED`, immutable flags and the `com.apple.rootless` xattr, so "can't delete" becomes "protected by macOS" |
| User exclusions (ancestor and descendant) | take | `PureMac/Services/CleanupExclusions.swift` | Correct handling in both directions and for paths that do not exist yet. Store in our own settings |
| CLI safety model (`canRemove`, identity since scan, dry-run) | take | `cli/Sources/puremac/Core/Safety.swift`, `cli/Sources/puremac/Core/Cleaner.swift` | Stronger than the app's: critical-root refusal, `(dev,inode)` recheck before unlink, measure-then-delete, dry-run. Model macontrol's delete path on it |
| Delete allowlist + symlink/TOCTOU checks | improve | `PureMac/Services/CleaningEngine.swift:115-190,488-568,736-749` | Keep the idea. Use fd-based `openat`/`unlinkat` with `O_NOFOLLOW` instead of path re-resolution, refuse equality with broad roots, and trash or quarantine by default |
| Command-output path validation (brew, npm, yarn, pnpm) | take | `PureMac/Services/ScanEngine.swift:527-609,699-762` | Env stripping plus approved-root checks. Sound and small |
| Cleanup target lists | improve | `ScanEngine.swift` literals, `cli/Sources/puremac/Core/Catalog.swift` | Good seed data (MIT). Move into one data-driven rule file shared by app and CLI, with selected-by-default flags and rationale |
| "Action" items (Docker prune, `simctl runtime delete`) | improve | `CleaningEngine.swift:329-412`, `ScanEngine.swift:803-875`, `Logic/Utilities/SimulatorRuntimeSupport.swift` | Right idea: some reclaim is a command, not an unlink. Replace the empty-path sentinel (`path: ""`) with a typed action enum |
| Admin escalation (NSAppleScript `rm -rf`) | rewrite | `CleaningEngine.swift:200-327` | Root `rm -rf` with no identity check and no undo, and a password prompt per batch. Use an SMAppService helper with an audited XPC API, or avoid root |
| Space Explorer engine | rewrite | `PureMac/Services/StorageExplorer.swift` | Take the ideas (hard-link dedupe, dataless skip, partial counters). Rewrite for a parallel `getattrlistbulk` scan, a persistent compact tree, and nlink>1-only dedupe |
| Space Explorer UI | study | `PureMac/Views/Tools/SpaceExplorerView.swift` | A plain list with bars. Useful only for the "Partial result" and "N inaccessible" honesty chips |
| Uninstaller matcher + rule tables | study | `PureMac/Logic/Scanning/{AppPathFinder,Conditions,Locations,StringNormalization}.swift` | Likely Pearcleaner-derived (Commons Clause, see Lineage). Also flawed: substring matching over Documents and Desktop, everything preselected, no tests |
| Orphan safety policy | improve | `PureMac/Logic/Utilities/OrphanSafetyPolicy.swift` | Keep the conservative allowlist of volatile dirs. The reverse-search loop in `AppState.findOrphans` (`AppState.swift:535-591`) depends on the Pearcleaner-derived `skipReverse` |
| Duplicate finder | improve | `PureMac/Services/DuplicateFinder.swift` | Size bucket, then full SHA-256, keeper re-validation and trash is solid. Add a partial-hash prefilter and clone awareness (F-0004) |
| Scheduler / auto-clean | rewrite | `PureMac/Services/SchedulerService.swift`, `AppState.swift:1112-1150` | In-app `Timer` plus a dead LaunchAgent writer. Use `NSBackgroundActivityScheduler` or SMAppService. Never escalate or permanently delete unattended |
| Cleanup review filters | take | `PureMac/Models/CleanupReview.swift` | Small and tested. The "selected rows hidden by filter" warning is good UX |
| Scan progress ticker isolation | take (pattern) | `AppState.swift:38-47`, `ScanEngine.swift:7-21` | Throttled `@autoclosure` path reports and a separate tiny observable avoid the #119/#120 lag |
| FDA probe / PermissionCoordinator | study | `PureMac/Services/FullDiskAccessManager.swift`, `PureMac/Services/PermissionCoordinator.swift` | The flow design is useful. The probe itself is flawed (F-0001) |
| Binary thinning / language stripping | ignore | `PureMac/Services/BinaryThinner.swift`, `Logic/Scanning/{UniversalBinaryScanner,LanguageFilesScanner}.swift` | Withdrawn after #135/#144. Lesson: never modify signed third-party bundles |
| Similar photos, protection audit, performance, app updates | ignore | `PureMac/Services/{SimilarPhotoFinder,ProtectionAudit,PerformanceInspector,ApplicationUpdater}.swift` | Outside macontrol's core (cleanup and disk map) for M1 |
| Safety unit tests | take (pattern) | `PureMacTests/CleaningEngineTests.swift`, `cli/Tests/puremacTests/CoreSafetyTests.swift` | Tests for symlinks, symlinked parents, dangling links and exclusions to replicate against macontrol's delete path |

## Open questions

1. Is the Pearcleaner derivation a direct copy or a clean-room re-implementation of the same data? The shared rule strings suggest a copy. A diff or the history of the v2.0.0 PR would settle it (T-0003, T-0014).
2. How much live state other than FileProvider sits under `~/Library/Caches` and gets pre-selected by User Cache (for example CloudKit-like databases of third-party apps)? This needs a survey of real caches, not code reading.
3. Does "vendor folder" parent promotion (`AppPathFinder.swift:156-168`) actually pull in whole shared vendor folders (Adobe, Microsoft, JetBrains) on real installs? It can be tested with the probe harness and a fake tree.
4. How long do `StorageExplorer` scans take compared with a `getattrlistbulk` walk on a large home folder? Hand to T-0004. Not benchmarked here to keep load down.
5. How does PureMac handle GarageBand, iMovie and iWork content under `/Library/Audio/Apple Loops` and `/Library/Application Support/{GarageBand,Logic}`? `skipDeepSearch` contains "Audio" (`Conditions.swift:401`), so Apple Loops are probably not found (unverified).
