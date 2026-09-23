# Source deep dive: Mac Sai, formerly MacClean (iliyami/MacSai)

Task T-0016, author `dive-iliyami-macsai`, 2026-09-23. Unless a path starts with `http`, it is relative to the clone at
`research/sources/iliyami-macsai` (commit `2c9ec77`, `git clone --depth 1`).
- **verified-locally:** I compiled and ran the source's own code, unmodified, in a scratch harness on this Mac (macOS 26.6). The harness sources are in `scratchpad/dive-iliyami-macsai/harness*`.
- **unverified:** I only read the code, or the claim comes from the source's docs.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/iliyami/MacSai. `iliyami/MacClean` redirects here, and awesome-mac still lists the old name | `gh api repos/iliyami/MacSai`, M-0001 |
| License | BSD-3-Clause ("Copyright (c) 2026, Mac Sai Contributors") | `LICENSE:1-3`, API `license.spdx_id` |
| Stars / forks | 1,585 / 90 | API, 2026-09-23 |
| Created / last push | 2026-05-27 / 2026-09-22 (last commit `2c9ec77`, "Fix Russian button truncation…", #177) | API, `git log -1` |
| Commits / releases | 208 commits. 21 minor releases in 4 months (v1.21.0, 2026-09-22) | API Link header, `releases` |
| Contributors | 1 main author (iliyami, 159 commits), 1 regular contributor (Borisserz, 26), and 5 others with 1-3 commits each | API `contributors` |
| Language | Swift 6 (`swift-tools-version: 6.0`), SwiftUI plus AppKit. 21.2k lines in `Sources`, 13.2k lines in `Tests` | `Package.swift:1`, `wc -l` |
| Min OS | macOS 14 | `Package.swift:7-9` |
| Build | Pure SwiftPM (no .xcodeproj). The only dependency is GRDB 7. CI runs `swift build`, `swift test --enable-code-coverage` and a version-sync check. There is a separate signing/notarization workflow | `Package.swift:15-17`, `.github/workflows/ci.yml:20-29` |
| Distribution | Developer ID, notarized, available as an official Homebrew cask `mac-sai` (unverified: I did not install it) | `README.md:33-41`, `SECURITY.md` |
| Open issues | 4, all feature or chore items: #55 feature vote, #12 translations, #8 "parallelize TargetedScanner" (already done, see Scanning), #5 DuplicatesModule TODOs. 35 were closed recently, and many are safety bugs: #154 AppMatching over-match, #156 hard links as duplicates, #157 secure-erase on directories, #162 Privacy offered Safari Bookmarks.plist, #164 thinning reports success with nothing thinned | `gh api .../issues?state=open`, `state=closed` |
| Dev process | `docs/superpowers/{plans,specs}` holds 25 dated plan/spec files, so the project is built largely with an AI agent workflow. Every guard is commented with its issue number | `ls docs/superpowers` |

**Lineage and license:** the README credits Pearcleaner (uninstaller patterns), Mole (categories) and Lemon (architecture) (`README.md` Acknowledgments). I searched for Pearcleaner code markers (`skipReverse`, `skipDeepSearch`, `darwinCT`, `bundleLastTwoComponents`) and got 0 hits. The only mention is a comment at `OrphanedAppFiles.swift:8`. The code looks original. **BSD-3 permits us to copy code**, provided we keep the copyright notice and license text in source and binary distributions and do not use the "Mac Sai" name to endorse our product.

## Summary

Mac Sai is a free, telemetry-free CleanMyMac clone with 17 modules:
- **Cleanup:** Smart Scan, System Junk (20 categories), Mail Attachments, Trash Bins.
- **Protection:** Malware (signature list), Privacy (browser data), Saved Wi-Fi, TCC permissions overview.
- **Performance:** Optimization (login items), Maintenance (admin shell tasks).
- **Applications:** Uninstaller with Reset, Extensions, Updater (Sparkle appcasts).
- **Files:** Space Lens (treemap), Large & Old Files, Duplicates with APFS-clone consolidation, Shredder.
- A separate menu-bar monitor process.

The project is young and moves fast. Its strength is **disciplined, test-backed safety plumbing around a narrow core**:
- the pure-logic `MacCleanKit` library,
- one audited deletion path (`CleanActions` → `CleaningEngine`, trash-first),
- a scan-time "cleanability" filter,
- conservative bundle-id orphan detection,
- a verified clone-and-swap for duplicates,
- thinning with a `codesign --verify` rollback.

The weaknesses are these (details under Known problems):
- The advertised `SafetyGuard` is a **6-prefix blocklist**. It passes `/`, `~`, `~/Documents`, `/Applications` and Keychains. Its "TOCTOU" guard is a path-string re-check that an ancestor symlink bypasses (verified-locally).
- The uninstaller's substring matching still over-matches for common short names. For VS Code, which is named "Code", it pre-selects Xcode's preferences (verified-locally).
- Deselecting a file inside a selected directory does not protect that file.
- **Space Lens is a demo:** it scans one level at a time, re-walks on every click, sizes `.app` bundles as 0 B, and has no delete or reveal.
- The README describes an **XPC root helper, GRDB cache and FSEvents incremental updates** that no longer exist or are never used.

## Architecture

- **Targets** (`Package.swift:18-52`):
  - `MacClean`: the SwiftUI app, which holds the modules, views, the scanners and `CleaningEngine`.
  - `MacCleanKit`: a pure library with no FileManager-heavy code, so it can be tested. It holds models, `SafetyGuard`, `PathExclusion`, `CleanFilter`, category rule structs, `AppMatching`, `OrphanedAppFiles`, `SquarifiedTreemap`, `DuplicateDetection` and `FileConsolidator`.
  - `MacCleanMenu`: the menu-bar process.
  - `MacCleanTestSupport`, plus two test targets.
- **Module seam:** `protocol ScanModule { id, name, category, includedInSmartScan, scan() async -> [ScanResult] }` (`Core/Scanner/ScanCoordinator.swift:4-10`). `ScanCoordinator` is an `@Observable` class that runs the selected modules **sequentially** on a `@MainActor` task and applies `CleanFilter.isActionable` to every result (`ScanCoordinator.swift:79-125`).
- **Engine to UI:** views own `@State` selection sets (`Set<URL>`) and call `CleanActions.executeUserClean`. That function is the single entry point for deletion (`CleanActions.swift:4-23`), and a static test guards it (`Tests/MacCleanTests/CleanIsNotDryRunRegressionTests.swift`). Large result lists render in an `NSTableView` wrapper, because SwiftUI `List` beachballed at tens of thousands of rows (`Views/Shared/FileTableView.swift:5-13`).
- **Privilege:** there is **no helper**. Root work (purge, periodic, `tmutil thinlocalsnapshots`, `mdutil -E`, and so on) runs in-process through `NSAppleScript` `do shell script … with administrator privileges`, with arguments single-quoted (`Modules/Maintenance/PrivilegedShellRunner.swift:33-59`, `MaintenanceShell.swift:10-32`, `MaintenanceTask.swift:167-188`). The commands are a fixed list with no user input.
- **Dead or stale:**
  - `README.md` "Architecture" lists `MacCleanHelper XPC privileged helper` and a "Kernel-enforced XPC gate". That helper was removed in #71 (`61fe8f9`, 2026-06-10, "remove unused IPC scaffolding"). Only `MCConstants.codeSigningRequirement`/`teamIdentifier` remain (`Constants.swift:9-24`).
  - `AppDatabase` (GRDB, WAL, `Core/Cache/Database.swift`) is referenced only by `DatabaseTests`. GRDB is actually used only to read TCC.db in `AppPermissionsClient.swift:3`.
  - `FSEventMonitor` is used only by `RealTimeMalwareMonitor`, which nothing instantiates (`grep` finds 0 call sites).
  - `SafetyError.outsideUserScope` is declared (`SafetyGuard.swift:15`) and never thrown.

## Scanning

- **APIs:** `FileManager.enumerator(at:includingPropertiesForKeys:options:)` with a URLResourceKey prefetch list, plus `contentsOfDirectory` for non-recursive targets (`Core/Scanner/TargetedScanner.swift:83-146`). `lstat` supplies `st_ino`/`st_dev` so hard links can be de-duplicated in Duplicates only (`TargetedScanner.swift:195-215`). There is no `getattrlistbulk`, `fts` or `searchfs`.
- **Permission handling (good):**
  - Before enumerating, `open(path, O_RDONLY|O_DIRECTORY)` probes each target and returns EPERM/EACCES (`TargetedScanner.swift:61-65`). This tells "blocked by TCC" apart from "empty", which the enumerator does not (it swallows errors). The result is `ScanOutcome.permissionDeniedPaths` (`MacCleanKit/ScanOutcome.swift`).
  - There is no global FDA probe. `PermissionManager` only opens System Settings (`Services/PermissionManager.swift:9-12`). So F-0001's false "granted" does not apply here.
- **Concurrency:**
  - System Junk uses a `TaskGroup` per category (`Modules/SystemJunk/SystemJunkModule.swift:43-112`), and TargetedScanner uses a `TaskGroup` per `ScanTarget` (`TargetedScanner.swift:33-52`). Issue #8, "parallelize", is therefore already done and stale.
  - Each target is walked by one synchronous enumerator inside a cooperative-pool task, so a big target (the whole of `~/Library/Caches`) is serial.
  - Modules run one after another (`ScanCoordinator.swift:85-97`).
  - Space Lens is one actor with one enumerator that yields every 200 entries (`FileTreeScanner.swift:78-84`). F-0009 (serial walkers) applies to it.
- **Sizes:**
  - Files use `totalFileAllocatedSize ?? fileAllocatedSize ?? fileSize` (`FileTreeScanner.swift:88`, `TargetedScanner.swift:206-207`).
  - Directories get `0`, because the key is nil for directories.
  - Every place that needs a directory's size re-walks it: `CleaningEngine.recursiveAllocatedSize` (`CleaningEngine.swift:249-267`), `AppDiscovery.directorySize` and `AppPathFinder.directorySize` (`UninstallerModule.swift:109-122,199-211`), and `AppLeftoversScanner.directorySize` (`AppLeftoversScanner.swift:105-124`).
  - **Hard links are counted once per link, and clones at full size.** The only exception is Duplicates. This is verified-locally: an 8 MiB file plus a hard link to it is reported as 16 MiB by the Space Lens logic. Same class as F-0010 and F-0004.
- **Packages:** `.skipsPackageDescendants` together with `size: isDir ? 0 : size` gives **every `.app`/`.bundle`/`.photoslibrary` a size of 0 B in Space Lens** (`FileTreeScanner.swift:50,88-96`). Verified-locally: `Foo.app` holding an 8 MiB binary counted 0. The same option means `LanguageFilesCategory` (target `/Applications`, recursive, extension `lproj`) never descends into an app bundle (`Categories/SimpleCategories.swift:64-77`, `TargetedScanner.swift:87`). That category is close to dead, which is fortunate, because deleting `.lproj` inside signed bundles breaks their signatures.
- **Progress and cancellation:** `Task.isCancelled` is checked per entry in every enumerator loop. The UI progress for a module is `index/totalModules` (`ScanCoordinator.swift:88`). Space Lens shows a **hard-coded `progress: 0.5`** ring (`Views/Files/SpaceLensView.swift:103`).
- **Memory model:**
  - Cleanup results are flat `[FileItem]` structs, one per file **and** one per directory, each holding a `URL`, `String` name, dates and `UTType` (`MacCleanKit/Models/FileItem.swift`). A 200k-entry cache holds 200k of them. The code comments mention "~200k observed in the wild" (`Constants.swift:39-44`).
  - Space Lens builds a `FileNode` class per entry, with a `[FileNode]` of children, plus a `[String: FileNode]` map of every directory path (`FileTreeScanner.swift:75,132-162`). It shows only the top 50 children of the current level and then throws the tree away.

## Deletion & rules

- **Rule definitions** are Swift structs, not a data file. Each `JunkCategory` returns `[ScanTarget]` (`MacCleanKit/Categories/SimpleCategories.swift`, `DeveloperCacheCategories.swift`). `ScanTarget` is pure data: `path, recursive, maxDepth, fileExtensions, minAge, maxAge, minSize, excludePatterns, skipHiddenDirectories` (`MacCleanKit/ScanTarget.swift:5-42`). This is easy to port to JSON. Paths live in `MacCleanKit/Constants.swift:96-187`, and the developer and AI-tool cache paths are deliberately cache-only (`Constants.swift:160-187`).
- **Default pre-selection** (`Models/ScanCategory.swift:147-170`): everything is auto-selected **except** unusedDiskImages, large/old files, duplicates, universalBinaries, appLeftovers, deletedUsers and the package-manager, IDE and AI caches. So the following are **pre-checked** in Smart Scan (`Views/SmartScan/SmartScanCleanup.swift:20-26`):
  - `iosDeviceBackups` (every entry in `MobileSync/Backup` older than 30 days) (`SimpleCategories.swift:107-119`).
  - `xcodeJunk`, which lists the top level of `Xcode/Archives` and `CoreSimulator` (so `Devices` is offered whole) (`SimpleCategories.swift:152-163`).
  - `userCaches`, which is the whole of `~/Library/Caches` with only Spotify and Gradle excluded (`SimpleCategories.swift:9-21`). There is no `com.apple.*`, CloudKit or FileProvider exclusion: 45 Apple-owned cache dirs on this Mac pass their `access(W_OK)` filter. That was probed from Terminal, and the app context is unverified. PureMac's incident #142 came from this class of problem.
- **Pipeline:**
  1. `CleanFilter.isActionable` runs at scan time. It requires `access(parent, W_OK)`, `access(dir, W_OK)` and a path outside the user's excluded folders (`MacCleanKit/CleanFilter.swift:27-63`).
  2. `CleanActions.executeUserClean` routes items: universal binaries are thinned, Trash Bins items are removed `.permanent`, and everything else goes to `.trash`. It then prunes descendants of selected ancestors (`CleanActions.swift:37-104,180-204`).
  3. `CleaningEngine.clean` refuses more than 500k items and processes chunks of 5k. For each chunk it runs `validateDeletion`; if the chunk fails, it re-validates each item. For each item it runs `validatePath`, re-walks the size if the item is a directory, then calls `trashItem` or `removeItem` and appends a log line (`CleaningEngine.swift:63-244`).
  4. A `.dryRun` mode exists, but only tests use it (`CleanIsNotDryRunRegressionTests`).
- **SafetyGuard** (`MacCleanKit/SafetyGuard.swift:68-117`) checks for an empty path or NUL, then `/System` (SIP), then `protectedPaths` = `/System, /usr, /bin, /sbin, /Library/Apple, /private/var/db` (`Constants.swift:56-63`), then the user's excluded folders. The last check rejects a path only if symlink resolution changed its **first 3 path components**. Verified-locally, with the unmodified file: `/`, `/Users`, `~`, `~/Documents`, `~/Library`, `~/Library/Keychains`, `/Applications`, `/Library`, `/Library/Keychains`, `/private/var/folders`, `/etc/hosts`, `/opt/homebrew` and `/Volumes` all **pass**. So does `~/Library/Caches/com.foo/x` when `com.foo` is a symlink to `~/Documents`, which resolves to `~/Documents/x`. This is not filed separately: the policy fix is F-0024 (Pearcleaner's 12-path guard) and the fd-based `O_NOFOLLOW` plus symlink-swap test is F-0012 (PureMac). I posted the Mac Sai evidence on T-0014 and T-0013.
- **Uninstaller:**
  - Discovery walks `/Applications` and `~/Applications` to depth 4 with `.skipsPackageDescendants` (`UninstallerModule.swift:59-76`).
  - Leftovers are the top-level entries of 17 `~/Library` subdirectories whose name `contains()` any pattern from `AppMatching.generatePatterns`: bundle id, display name, directory name, normalized name, last two id components, base id and version-stripped name. Patterns must be at least 3 characters, and only "app" is filtered out (`MacCleanKit/AppMatching.swift:22-137`). `/Library/LaunchDaemons|LaunchAgents` plists are matched the same way (`UninstallerModule.swift:159-172`).
  - **All matches are pre-selected** (`Views/Applications/UninstallerView.swift:362-364`).
  - Protected Apple apps are refused by bundle id (`Views/Applications/AppUninstaller.swift:19-38`, `Constants.swift:65-94`). That list omits GarageBand, iMovie, Keynote, Pages and Numbers on purpose (`Tests/MacCleanKitTests/SafetyGuardProtectedAppTests.swift:13-14`).
  - There is no running-app check before an uninstall. Cache rows only flag `appRunning` (`FileListRows.swift:58-62`).
- **App leftovers (good pattern):** `OrphanedAppFiles.isOrphan` flags only reverse-DNS names with at least 3 components, skips `com.apple.`, Chromium, Keystone, Qt and Electron, and requires no *dotted-lineage* relation to any installed bundle id after stripping helper suffixes (`MacCleanKit/OrphanedAppFiles.swift:28-95`). It scans only Caches, Logs, HTTPStorages, Saved Application State and WebKit (`AppLeftoversScanner.swift:26-34`), refuses to flag anything if 0 apps were found (`:43`), and is never auto-selected.
- **Trash vs rm:** the default is `FileManager.trashItem`. `removeItem` is used for Trash Bins and for the Shredder's permanent and secure modes (`Modules/Shredder/ShredderModule.swift:84-95`). The Shredder's "secure" mode overwrites with zeros in place, which is meaningless on APFS copy-on-write. The code says "best effort" (`:107-111`).
- **Other good safety patterns:**
  - **Duplicates consolidation** re-hashes both files, `clonefile`s the master into a hidden temp file in the copy's directory, verifies the clone's hash, restores the copy's permissions and mtime, then `rename`s it atomically over the copy (`MacCleanKit/FileConsolidator.swift:95-143`). Caveats: it does not preserve the copy's own xattrs, tags, ACLs or creation date, and its "reclaimed" figure is the copy's allocated size even if the copy was already a clone (F-0004 class).
  - **Universal-binary thinning** backs up each binary, runs `codesign --verify --deep` before and after, and rolls back if a signed bundle stops verifying. It never re-signs (`MacCleanKit/Cleaner/ThinAppBundleOperation.swift:8,82-132`).
  - **Deleted users** are never pre-selected, and the reason is documented (`ScanCategory.swift:160-166`).
- **Logging:** `~/Library/Logs/MacClean/operations.log` gets one line per item, `[REMOVED]/[DRY-RUN]/[ERROR]/[SKIP]`. It is pruned after 30 days (`LogPruner.swift`). Each line allocates an `ISO8601DateFormatter`, stats the file twice and opens and closes a `FileHandle` (`CleaningEngine.swift:301-323`). That is O(items) syscalls on 100k-item cleans.

## UI

- The layout is a SwiftUI sidebar plus a per-module container (`Views/Sidebar`, `Views/Shared/ModuleContainerView.swift`). There are gradient themes per module group (`GradientBackground.swift`, `SuperEllipse.swift`), and keyboard shortcuts ⌘R scan, ⌘K clean and ⌘1-9 modules (`App/ModuleKeyboardShortcuts.swift`).
- The **results list** is an `NSTableView` with a row model `FileListRow` (header or item), a tri-state checkbox per category and a "Reveal in Finder" context menu (`FileTableView.swift:41-50,118,180`, `MacCleanKit/FileListRows.swift`). Selections above 50k items trigger a confirmation modal (`Constants.swift:46-51`, `ModuleContainerView.swift:316`). Clean shows per-chunk progress (`CleaningEngine.Progress`).
- **Selection model defect:** directory rows and their descendant rows are independent checkboxes (`Views/Shared/FileListView.swift:146-152`), and `prunedToParents` then keeps the selected ancestor (`CleanActions.swift:180-204`). **Unchecking a file inside a checked directory still trashes it.** Verified-locally with a verbatim copy of `prunedToParents`. Filed as **F-0026**.
- **Space Lens** (`Views/Files/SpaceLensView.swift`):
  - It shows one level, as a squarified treemap of the **top 50 children** (`:224-238`), drawn as SwiftUI `RoundedRectangle`s positioned in a `ZStack` (`:141-195`). Colors come from an 11-way file-type category (`SquarifiedTreemap.swift:4-56`). A folder, including an `.app`, is always the "folders" color (`:35`).
  - Every drill-down, up, home or breadcrumb click calls `startScan()`, which **re-walks the subtree from scratch** (`:67,71,78-79,188-191,216-241`).
  - The root is always `~`. `selectedVolume` is dead state (`:9-10`), and there is no folder picker.
  - There is no delete, reveal, hover detail or keyboard navigation, and the progress indicator is fake (`:103`).
  - `SquarifiedTreemap` itself is a clean pure implementation with tests (`MacCleanKit/SquarifiedTreemap.swift`, `Tests/MacCleanKitTests/SquarifiedTreemapTests.swift`).
  - Filed: package sizing as **F-0028**. The rescan on every click is the F-0013 class (PureMac), and top-N only is the F-0016 class (Mole).
- Visual quality: unverified (I did not build or run the app). The screenshots are `assets/demo.png` and `assets/menu_bar.png`.

## Tests & quality

- The suite has 879 `func test` methods in 115 files (13.2k lines). The README says 862. There are adversarial `SafetyGuard` tests: symlink to `/System`, traversal, NUL, firmlinks, the 10k cap and excluded folders (`Tests/MacCleanKitTests/SafetyGuardTests.swift`). `CleaningEngine` has dry-run, trash and permanent tests plus a "one unsafe path does not skip the chunk" test (`CleaningEngineTests.swift:46-84`). There are also E2E fixture tests (`withTempHome`, `withFakeApp`).
- **Test gaps:**
  - No test asserts that `~`, `/`, `/Applications` or `~/Documents` are **rejected**. `testAllowsArbitraryUserFile` asserts the opposite (`SafetyGuardTests.swift:71-73`).
  - There is no ancestor-symlink test, no `prunedToParents` test (0 references in `Tests/`), and no `.app`-sizing test for `FileTreeScanner`.
  - LanguageFiles, XcodeJunk and DocumentVersions have no E2E test (`RemainingSystemJunkE2ETests.swift:12-20`).
- **Code quality:**
  - The code is heavily commented, and each guard names the issue that caused it. The pure and system split is consistent. Swift 6 strict concurrency, with some `@unchecked Sendable` (`FileNode`, `ScanCoordinator`).
  - Localization is inline `L10n.tr(zh, en, ru)` in every string (`MacCleanKit/Localization.swift`), which is noisy.
  - Rules are compiled Swift, not data. The docs claim several things the code no longer does (see Architecture).
  - `prunedToParents` says it is O(n log n), but `keptPaths.contains` is a linear scan inside the loop (`CleanActions.swift:177-197`), so it is O(n·k).

## Known problems

1. **SafetyGuard is a blocklist, not a scope check** (verified-locally; covered by F-0024's `DeletionPolicy`, and the evidence is on T-0014). The home root, `/`, `/Applications`, `~/Documents` and both Keychains folders pass. `outsideUserScope` is never thrown. The only real protection is that each scanner produces sensible lists. Shredder accepts arbitrary user-picked paths through the same gate.
2. **The "TOCTOU prevention" is a path re-check** (covered by F-0012's fd-based `renameat` plus the symlink-swap test; the evidence is on T-0013). It compares only the first 3 components after `resolvingSymlinksInPath`, so an ancestor symlink inside home is accepted. Between the check and `trashItem` it runs a full recursive size walk of the item (`CleaningEngine.swift:177,193-195,206`), which widens the window.
3. **Deselection is not honored under a selected parent directory** (**F-0026**, verified-locally).
4. **Uninstaller substring matching over-matches** (verified-locally; the F-0011 class, where F-0011's confidence tiers fix it; the evidence is on T-0013). VS Code's `CFBundleName` is "Code", which produces the pattern `code`. On this Mac that pre-selects 20 foreign `~/Library` entries, including `Preferences/com.apple.dt.Xcode.plist`, `Application Support/com.apple.dt.Xcode`, `Application Support/Codex`, `HTTPStorages/com.openai.codex` and `ai.opencode.desktop`. #154 fixed only 1- and 2-letter tokens and "app".
5. **Space Lens:**
   - Packages are sized 0 B.
   - Hard links are double-counted (F-0010 class).
   - It re-walks on every navigation, shows only the top 50 at one level, and has fake progress.
   - It has no delete or reveal, and its root is fixed to `~`.
6. **Risky data is pre-selected** (**F-0027**): iOS backups older than 30 days, Xcode Archives, and `CoreSimulator/Devices` as a whole (`SimpleCategories.swift:107-119,152-163`, `ScanCategory.swift:147-170`). This is recoverable only because the default is Trash, and Trash does not free space until it is emptied.
7. **Docs drift:** the README describes the XPC helper, the GRDB WAL cache and FSEvents "historical replay" as the architecture (`README.md` Architecture, Tech stack), but none of it is live (see Architecture).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| `ScanTarget` + `JunkCategory` rule shape | improve | `MacCleanKit/ScanTarget.swift`, `Categories/*.swift` | Clean, pure data shape (path, depth, extensions, age, size, excludes). Port it to a JSON rule file, and add a `risk`/`autoSelect` field per target, not per category, so `Xcode/DerivedData` can be pre-checked but `Archives` cannot. |
| Dev and AI cache path list | take (BSD-3 notice) | `MacCleanKit/Constants.swift:153-187`, `DeveloperCacheCategories.swift` | Cache-only paths for npm `_cacache`, cargo, gradle, Claude, Codex, Cursor and Antigravity, with user data excluded on purpose. Cross-check against Mole's lists. |
| `CleanFilter` (scan-time actionability) | improve | `MacCleanKit/CleanFilter.swift` | Dropping rows the process cannot delete (root-owned, data vault) before the UI sees them is a good UX rule. Verify the claim that `access(W_OK)` catches `UF_DATAVAULT` (unverified: Python `os.access` returned writable for `com.apple.Safari.SafeBrowsing` here), or use `lstat` `st_flags`. |
| `OrphanedAppFiles` (bundle-id lineage orphan test) | take | `MacCleanKit/OrphanedAppFiles.swift` | This is the most careful orphan heuristic seen so far. It uses reverse-DNS only, dotted lineage, helper-suffix stripping and shared-framework prefixes, and refuses to flag anything when 0 apps are found. Extend the installed set with LaunchServices and Homebrew. |
| `AppMatching` substring engine | rewrite | `MacCleanKit/AppMatching.swift`, `UninstallerModule.swift:138-175` | `contains()` on short names over-matches (F-0011 class). Use exact or token-boundary matching on bundle id or team id, container metadata, and name only as a low-confidence, unchecked tier. |
| `PathExclusion` (user-excluded folders, `/` boundary, firmlink canonicalization) | take | `MacCleanKit/PathExclusion.swift`, `FolderExclusionPreferences.swift` | Small, correct and tested. It refuses to exclude all of home or `/Volumes`. |
| `SafetyGuard` | rewrite | `MacCleanKit/SafetyGuard.swift`, `Constants.swift:56-63` | It is a blocklist with a string-based symlink check (F-0024, F-0012). Keep the idea of one gate that throws typed errors. Replace the policy with allowlisted roots per operation, a critical-path denylist, and `O_NOFOLLOW`/`openat`-based deletion. |
| `CleanActions` single deletion entry + regression test | improve | `CleanActions.swift`, `Tests/MacCleanTests/CleanIsNotDryRunRegressionTests.swift` | A single audited entry point is right. Fix ancestor pruning so it honors deselection (F-0026), and make pruning O(n log n) for real (sorted-prefix sweep). |
| `CleaningEngine` chunking and progress | improve | `Core/Cleaner/CleaningEngine.swift` | Chunks of 5k with a progress snapshot per chunk, cancellation between chunks, and benign-ENOENT handling are good. Drop the second recursive size walk (reuse the scan's size), batch the log writes, and report "moved to Trash" separately from "freed". |
| `FileConsolidator` clone-and-swap | improve | `MacCleanKit/FileConsolidator.swift:95-143` | A verified `clonefile` plus atomic `rename` is the right technique for the "free duplicates without deleting" feature. Also preserve xattrs, tags, ACLs and btime, and use the private size (ATTR_CMNEXT_PRIVATESIZE) for "reclaimed" (F-0004). |
| `ThinAppBundleOperation` | study | `MacCleanKit/Cleaner/ThinAppBundleOperation.swift` | Backup plus a `codesign --verify --deep` check before and after, with rollback. Worth copying as a pattern if macontrol ever rewrites bundles. PureMac's report shows thinning broke 21 apps, so the feature itself is questionable. |
| TCC-denial probe per target (`open O_DIRECTORY` errno) | take | `Core/Scanner/TargetedScanner.swift:55-79`, `MacCleanKit/ScanOutcome.swift` | Cheap and honest "blocked vs empty" reporting for each root. |
| `NSTableView` results list | take (pattern) | `Views/Shared/FileTableView.swift`, `MacCleanKit/FileListRows.swift` | Real evidence that SwiftUI `List` beachballs at tens of thousands of rows. A flat value-typed row array plus `reloadData` is simple and fast. |
| `SquarifiedTreemap` | study | `MacCleanKit/SquarifiedTreemap.swift` | A correct Bruls et al. implementation with tests, but only for one level with no nesting. macontrol needs nested, incremental layout (see the Radix report). |
| `FileTreeScanner` / Space Lens | ignore | `Core/Scanner/FileTreeScanner.swift`, `Views/Files/SpaceLensView.swift` | Serial, wrong for packages and hard links, and it rescans on every click (F-0028, F-0013, F-0016). |
| Maintenance tasks via `NSAppleScript` admin | study | `PrivilegedShellRunner.swift`, `MaintenanceShell.swift`, `MaintenanceTask.swift:160-225` | A fixed argv list, quoted, with one prompt per 5 minutes. It avoids a root helper entirely, which is a valid option for rare root tasks. It skips tasks whose binary is missing on macOS 26 (`periodic`, #129). |
| Menu-bar monitor, Wi-Fi, malware signatures, Updater | ignore | `Sources/MacCleanMenu`, `Modules/{WiFi,Malware,Updater}` | Out of scope for macontrol's cleanup and visualization goal. |

## Open questions

- Does `access(W_OK)` really return EPERM for `UF_DATAVAULT` directories, as `CleanFilter.swift:16-25` claims? A probe from an ad-hoc-signed `.app` (M-0001 lesson, T-0010) would settle it. Hand this to T-0010.
- Does `lipo -thin` keep nested-code `CodeResources` valid in every case? The source relies on its `codesign --verify` rollback, and I did not test it.
- Are `~/Library/Caches/CloudKit` and `com.apple.*` caches that pass `CleanFilter` safe to delete while their daemons run? This is the PureMac #142 class. It needs a policy decision for macontrol's rule set.
- Real-world scan speed was not benchmarked: I did not build the app because the machine is under load. Hand the Space Lens and TargetedScanner walk to T-0004 as "FileManager.enumerator serial" baselines.
