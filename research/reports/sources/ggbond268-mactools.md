# Source deep dive: MacTools, DiskClean and StorageExplorer plugins (ggbond268/MacTools)

Task T-0033. Author: dive-ggbond268-mactools, 2026-09-23. All code citations are `ggbond268/MacTools@bf6550a` (clone at `research/sources/ggbond268-mactools`, gitignored) unless stated otherwise. Paths are relative to the repo root. `DC/` means `Plugins/DiskClean/Sources/` and `SE/` means `Plugins/StorageExplorer/Sources/`. Probes live in `research/bench/ggbond268-mactools/`. They copy the GPL sources from the clone into a temp dir when they run, so no GPL text is committed.

## Facts

| | |
|---|---|
| URL | https://github.com/ggbond268/MacTools (homepage https://mactools.ggbond.app) |
| License | **GPL-3.0-only at HEAD** (`LICENSE`, `LICENSING.md`, and the `"license": "GPL-3.0-only"` field in every plugin.json). **Apache-2.0 before 2026-08-27.** The Apache license was added in `a8627a0` on 2026-05-16, and `bcd9f9f` "licensing: migrate MacTools to GPL-3.0-only" landed on 2026-08-27. `LICENSING.md` §"Historical Releases" says pre-transition revisions "remain available under … Apache License 2.0", and those grants "are not revoked". At the last Apache revision, `9197035` (the parent of `bcd9f9f`), `LICENSE` is Apache-2.0. See the reuse notes below. |
| Stars / forks | 1,218 / 67 (`gh api repos/ggbond268/MacTools`, 2026-09-23). fork=false. |
| Created / last commit | 2026-04-13 / 2026-09-22 (`bf6550a` "ci: publish MacTools Nightly 41.1"). 1,702 commits. |
| Releases | v2.0.0 and plugins-2.0.0 (2026-09-22). Nightly builds. Homebrew cask `mactools`. |
| Contributors | xcv58 561, ggbond2077 387, ggbond268 249, github-actions 125, ayangweb 82, … DiskClean 2.0 was written by rkrkrkk (`df1dcdd`, 2026-07-30) with follow-up fixes by `cursoragent`. |
| Language | Swift, about 15.1 MB of source (`gh api …/languages`). About 381k lines of Swift across the app and 60+ plugins. SwiftUI with AppKit. XcodeGen (`project.yml`). |
| Min macOS | 14.0 (the `requirements` block in each plugin.json) |
| Open issues | 35 (API count, PRs included). Disk-related issues are design RFCs, not bugs: #347 "improve rule explainability, scan coverage, run-level history" (DiskClean), #348 "Xcode Clean: Trash-first, verifiable execution", #350 "confidence-based App Uninstaller" (proposal, no code). No open DiskClean or StorageExplorer bug reports. |

## Summary

MacTools is a menu-bar "tool collection" app with about 60 in-process plugins (clipboard, window switcher, system status and more). Two plugins matter to macontrol:

- **DiskClean** (`Plugins/DiskClean`, v3.0.0, about 15.8k lines plus 8.5k lines of tests with 305 XCTests). A rule-based cache and junk cleaner. It has 54 targets in a Swift catalog, 4 dynamic providers, developer-artifact purge in user-chosen roots, and leftover installers in `~/Downloads`. The engine is the most defensive in this survey:
  - a typed walk-completeness model;
  - a `getattrlistbulk` walker with a per-entry `fstatat` fallback;
  - an abandonable thread pool;
  - a mint-once validated plan;
  - an fd-anchored, journaled "verify, freeze by rename, trash or delete" primitive with rollback and a launch-time reconciler;
  - an append-only audit log.
- **StorageExplorer** (`Plugins/StorageExplorer`, v1.0.0, added 2026-09-06, about 4.4k lines, 60 tests). A disk-usage explorer: a parallel `getattrlistbulk` scanner, a nested treemap with an "Other" tile per level, a review basket, and Trash through a private staging folder. It is newer and less hardened. It is GPL-only.

What is worth taking: the engine patterns (completeness typing, the exactly-once resume gate, root and identity revalidation, ancestor decomposition of overlapping rule hits, the staging journal and reconciler, deterministic hard-link charging). These can be **copied with attribution from the Apache-2.0 revision `9197035`**. The DiskClean engine files are byte-identical there. What falls short: a hidden Trash name with no restore (F-0064), a single-threaded 20 s sizing wall that makes big items uncleanable (F-0065), a mount guard that bulk devid defeats (evidence for F-0031), a root-mtime size cache (F-0017 class), and no running-app guard for `~/Library/Caches/*` (F-0015 class).

## Architecture

- **Host and plugins.** `Sources/App` is the menu-bar app and its settings. `Sources/Core/Plugins` holds `PluginHost.swift` (6,030 lines) and `Dynamic/DynamicPluginManager.swift`. `Sources/MacToolsPluginKit` is the plugin ABI (PluginKit v7). Each plugin is a `.bundle` with a `plugin.json` manifest that declares its factory class, permissions (`full-disk-access` for DiskClean), a privacy block and actions. Official plugins load in-process from a signed catalog (`LICENSING.md` §Plugins).
- **Shared filesystem module.** `Sources/MacToolsFileSystem/` has 3 files, about 390 lines, GPL-era (`b3a45b7`, 2026-09-07). It holds a bounds-checked `getattrlistbulk` parser (`FileSystemBulkAttributeParser.swift`) and a one-directory reader with a `readdir`+`fstatat` fallback (`FileSystemDirectoryReader.swift:16-102`). DiskClean re-exports the parser as typealiases (`DC/DiskCleanBulkAttributeParser.swift`). In the Apache-era revision `9197035`, the same parser lives in full inside `DiskCleanBulkAttributeParser.swift`, with the same layout-check logic.
- **UI vs engine separation (DiskClean).** Protocol seams everywhere: `DiskCleanDirectorySizing`, `DiskCleanSizingExecuting`, `DiskCleanTrashing`, `DiskCleanFileSystemProviding`, `DiskCleanRunningAppSnapshotting`, `DiskCleanFullDiskAccessProbing`. `DiskCleanScanEngine` emits an `AsyncThrowingStream<DiskCleanScanEvent>` (`DC/DiskCleanScanEngine.swift:131-141`). `DiskCleanController` is a state machine with the expiry and confirmation clocks (`DC/DiskCleanController.swift:175-191`). The views (`DiskCleanDetailView`, `DiskCleanCategoryListView`, `DiskCleanCleanupHistoryView`) are SwiftUI and only read snapshots.
- **UI vs engine separation (StorageExplorer).** `StorageExplorerScanner` is a public class behind `StorageExplorerScanning` (`SE/StorageExplorerSnapshot.swift:47`). `StorageExplorerController` drives the UI. `StorageExplorerHierarchyLayout` and `…RectLayout` are pure layout code. `StorageExplorerSafetyPolicy` handles validation and Trash.
- **Design docs.** The code cites "design §3.3, §4.2, §7.4 …" everywhere. The v1 spec is `docs/superpowers/specs/2026-04-27-disk-clean-design.md` (303 lines). The 2.0 design document behind the § numbers was not found in the repo (unverified whether it was published). `docs/plugins/storage-explorer.md` documents StorageExplorer.

## Scanning

### DiskClean sizing

- **Two phases** (`DC/DiskCleanScanEngine.swift:69-75, 142-240`). First *expand*, serially: globs and dynamic providers produce candidates, which appear in the UI within 1-2 s. Then *size*: at most 3 at a time (`maximumConcurrentSizing = 3`, :58), each on a resident pool thread.
- **Walker** (`DC/DiskCleanDirectoryTreeWalker.swift:48-237`). An explicit-stack DFS shared by both entry sources.
  - `DiskCleanFastWalker` calls `getattrlistbulk` with a 64 KiB buffer (`DC/DiskCleanFastWalker.swift:9-18, 65-95`).
  - `DiskCleanSlowWalker` uses `readdir` plus `fstatat`, in batches of 128 (`DC/DiskCleanSlowWalker.swift:11-97`).
  - Children are opened with `openat(parentFD, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK)` (:199-207). Names stay as raw bytes, so invalid UTF-8 never breaks descent (`Sources/MacToolsFileSystem/FileSystemBulkAttributeParser.swift:7-12`).
  - Open fds are bounded by tree depth: child directories are drained before the next batch is read (:128-138).
- **Attributes and sizes.**
  - DiskClean requests `NAME|DEVID|OBJTYPE|FILEID` plus `LINKCOUNT|DATALENGTH` (`FileSystemBulkAttributeParser.swift:66-74`). It sums the **logical** size: `totalBytes += dataLength` (`DC/DiskCleanDirectoryTreeWalker.swift:184`, `DC/DiskCleanSizingModels.swift:84-88`). The code documents that this is "not reclaimable space" because of clones, sparse files and hard links (F-0004 class).
  - Hard links are deduplicated per walk by `(devid, fileID)` when `linkCount > 1` (:179-183).
  - Directories themselves count 0.
- **Parser robustness.** The parser checks that the end of the fixed section equals `ATTR_CMN_NAME`'s `attr_dataoffset`. A mismatch sets `hasLayoutMismatch` and falls back to one `fstatat` for that entry. `ATTR_CMN_ERROR` is deliberately not requested, because it keeps 4 bytes even when its returned bit is 0 (`FileSystemBulkAttributeParser.swift:53-64, 220-229`).
  - Verified: `parser_layout_probe.sh` found **0 mismatches** in 3,290 entries with both attribute sets on APFS (macOS 26.6).
  - Worth taking as a pattern: silent misalignment becomes a detected fallback.
- **Completeness is typed** (`DC/DiskCleanSizingModels.swift:10-35`). The result is `.complete` or `.partial{timedOut, permissionDenied, unsupportedVolume, crossedMountPoint, walkError}`. Only complete results are cleanable (`DC/DiskCleanModels.swift:324-327`).
  - The mount guard applies to every entry: `resolved.devid == identity.devid` is checked before the type check (`DC/DiskCleanDirectoryTreeWalker.swift:168-172`). Bulk devid misses the mount point itself (see below), but the files and folders inside it carry the new devid, so DiskClean correctly reports `crossedMountPoint`. Verified: `mount_guard_probe.sh` gave `estimatedBytes=1048576 completeness=partial(crossedMountPoint)`.
  - The root must be on a local volume (`fstatfs` and `MNT_LOCAL`, `DC/DiskCleanRootOpener.swift:105-109`).
  - An intermediate symlink is rejected with `O_NOFOLLOW_ANY`. A symlink leaf is sized as the link itself (:31-103).
- **Deadlines and cancellation.** `shouldStop` = cancelled, or now ≥ deadline. It is checked between batches and before each descent (`DC/DiskCleanDirectoryTreeWalker.swift:121-126`). Each item gets 20 s and the whole scan gets 300 s (`DC/DiskCleanScanEngine.swift:53-56`). Cancel goes through `withTaskCancellationHandler` into a lock-backed flag that the worker reads for each batch (`DC/DiskCleanWorkerPool.swift:117-135, 383-394`).
- **WorkerPool and the exactly-once gate** (`DC/DiskCleanWorkerPool.swift`).
  - The pool owns a fixed set of `Thread`s (3, with 1 MiB stacks), not GCD or the cooperative pool. A thread stuck in a blocking syscall can therefore be *abandoned* and replaced (:54-66, 185-193).
  - `DiskCleanResumeGate` (:5-49) is an `OSAllocatedUnfairLock<Bool>` with a `claim()` / `deliver()` split. The timeout side claims first, records its bookkeeping (abandon count, device blacklist), and only then resumes, so the waiter never sees a result before the circuit-break state (:265-321).
  - Process-wide: 3 abandons break the circuit for the life of the process, and there is no automatic recovery (:61-65, 296-301).
  - Measured (`pool_timeout_probe.sh`, 10 runs at a 0.25 s deadline on a 3.3k-entry warm tree): the cooperative walker won the race **10 of 10** times, with 0 abandons and 0 blacklisted devices. The pool timer fires at the same deadline as the walker's own check (:174-183, 244-253), and GCD `asyncAfter` leeway normally lets the walker notice first. A single slow batch can still lose the race, and the device would then be refused until relaunch. The report counts this as a risk, not a defect (see F-0065, last paragraph).
- **Throughput and the 20 s wall.** Measured with `walker_throughput_main.swift` on the unmodified walker:
  - 34k and 40k files/s on a 728k-file tree larger than the vnode cache (`kern.maxvnodes` 120,350; load average 3-12);
  - 160k and 190k files/s on a 23k-file warm tree.

  One candidate is walked by one thread, so a cache folder of roughly 0.7M-3.8M files times out. A timed-out folder can never be cleaned. Filed as **F-0065**.
- **Size cache** (`DC/DiskCleanSizeCache.swift`). The key is the path. A hit needs root `(devid, fileID, mtime, type)` to match and is valid for 240 s, capped at 500 entries. Only complete results are stored (:36-143). The root mtime does not change when content deeper down changes, so a nested change shows a stale size for up to 240 s. The code says so for deletion at `DC/DiskCleanRemovalPrimitive.swift:83-85`. This is the F-0017 class, bounded by the TTL. The `forceRefresh` rescan bypasses the cache (:175-179). The caching sizer retries `SlowWalker` only when the only problem is `walkError` (:191-196).
- **Memory.** DiskClean keeps no tree, only per-candidate totals and a per-walk hard-link `Set`.

### StorageExplorer scanning

- **Scanner** (`SE/StorageExplorerScanner.swift`).
  - It runs `DispatchQueue.concurrentPerform(iterations: workerCount)` on a global queue (:44-89). The worker count is `max(4, cores/2)`, capped at 6 (:17-19). The doc says "defaults to two workers, capped at four" (`docs/plugins/storage-explorer.md` §Scanning), so the doc is stale.
  - A shared LIFO job stack uses an `NSCondition` with 0.1 s timed waits (:239-247).
  - Directory reads go through `FileSystemDirectoryReader.read` with `includeStorageDetails` (`MODTIME|FLAGS|ALLOCSIZE`).
- **Sizes.** Both logical (`dataLength`) and allocated (`ATTR_FILE_ALLOCSIZE`) sizes are kept. The UI metric defaults to size on disk (docs).
  - `SF_DATALESS` directories are not descended and are marked cloud placeholders (:67-70, 200-237).
  - Packages (a fixed list of 31 extensions, :105-111) are atomic: their payload is charged to the package.
- **Hard links: deterministic charging.** Every link with `linkCount > 1` is deferred. The charged link is the lexicographically smallest path among all links seen (:295-311, 421-462). Totals therefore do not change between runs, which is the fix F-0054 (dua) asks for. Worth taking.
- **Mount guard defeated by bulk devid (verified).** The scanner compares `entry.devid` with the root device for **directories only**, and the devid comes from `getattrlistbulk` (:282, 312-316).
  - `research/bench/ggbond268-mactools/bulk_devid_mountpoint_probe.c` (`clang -O2 … && ./a.out /System/Volumes`) shows that `ATTR_CMN_DEVID` for a mount-point entry reports the *covered* device. In `/System/Volumes`, `Hardware`, `Update`, `Preboot`, `xarts`, `VM` and `iSCPreboot` all show the parent devid 16777229, while `lstat` gives each its own dev.
  - So the scanner descends into the mount point and counts the files at the mounted volume's root. `mount_guard_probe.sh` (100 MB APFS image mounted at `root/mnt`, holding a 64 MiB file at its root) reported root size **68,157,440 B instead of 1,048,576 B**, and listed `mnt/big.bin` as an item. Subfolders of the mounted volume are skipped.
  - When `/` is scanned, the same mechanism counts `/System/Volumes/VM/swapfile*`, and nothing excludes the firmlinked Data volume. This is the F-0031 class, and the evidence is posted on T-0018 and T-0033 instead of in a new finding.
- **Directory-listing cache.** It lasts 30 s, holds at most 10,000 entries in total, and is keyed by path. FSEvents invalidates it, and more than 32 changed paths clear it completely (:126-172).
- **Retention for huge trees.** With `publishesItems: false` (as the plugin is wired, `SE/StorageExplorerPlugin.swift:17-21`), the snapshot keeps every directory, the largest file in each directory, and the top `maximumRetainedFiles` files through a min-heap (`StorageExplorerLargestFileHeap`, :516-556). The code default is **10,000** (:16), but `docs/plugins/storage-explorer.md` says 50,000. Everything else is folded into totals, so smaller files cannot be listed or selected individually (F-0016 class). The doc's benchmark enforces a 200 MiB peak on 100k files (`scripts/benchmark-storage-explorer.py`, not run here).
- **Progress.** Updates are throttled to 150 ms (:356-363). Hard-link accounting and the folding of directories into parents happen at the end, with a cancellation check every 512 items (:366-420).

## Deletion & rules

- **Rules are Swift data, not a file.** `DC/DiskCleanRuleCatalogV2.swift` has 54 target literals: 40 low risk and 16 medium, with no high-risk targets. Each target has a glob list, `reservedRootPaths`, `requiresFullDiskAccess`, lock declarations (`lockedByBundleIDs`, `skipWhenProcessIsRunning`) and an optional structured `explanation` (`DC/DiskCleanRuleModels.swift:193-312`).
  - Only `.low` targets are pre-selected (:214).
  - 4 dynamic providers cover Xcode/simulator version directories, unavailable simulators through `xcrun simctl list devices -j` (`DC/DiskCleanDynamicRules.swift:489-611`), and others.
  - Tests check the FDA flags per target against a prefix table (`DC/DiskCleanRuleCatalogV2.swift:23-50`).
- **Overlapping hits: ancestor decomposition.** When one glob hits `A` and another hits `A/B`, `A` is replaced by its direct children, recursively, so `B` keeps its own risk, lock and default. If `A` cannot be listed, `A` is dropped (`DC/DiskCleanScanEngine.swift:864-960`). Ownership of the same physical path goes to the most specific glob prefix, and the logical aliases are merged so whitelist rules still match (:907-937). Worth taking.
- **Planner: a mint-once plan** (`DC/DiskCleanPlan.swift:70-271`). `DiskCleanValidatedPlan.init` is fileprivate, so only `DiskCleanPlanner.makePlan` can create a plan. The plan freezes the mode, the per-item identity and lock declarations, the exclusion paths and the reserved prefixes. The planner and the executor independently refuse any planned path that is an ancestor of an exclusion or reserved root (`ancestorViolation`, :263).
- **Freshness gates.** Results expire 300 s after the earliest observation (`DC/DiskCleanModels.swift:358-365`). The confirmation window is `min(60 s, remaining)` (`DC/DiskCleanController.swift:190-191, 540`).
- **Executor** (`DC/DiskCleanExecutor.swift`). It takes a fresh running-app snapshot as preflight and refreshes the bundle IDs before each item (:214-219, 310-314, `DC/DiskCleanRunningAppLock.swift:79-100`).
- **Removal primitive** (`DC/DiskCleanRemovalPrimitive.swift:66-420`).
  - Open the parent with `O_NOFOLLOW_ANY`, check it is local, and check the leaf identity `(devid, ino, type, mtime)` plus the size for regular files (:195-216).
  - Write the journal entry and `fsync` it (`DC/DiskCleanStagingJournal.swift:6, 89, 247`).
  - `renameatx_np(RENAME_EXCL)` to `.mactools-staged-<UUID>` (:240-293), then re-verify.
  - Then, in trash mode, `FileManager.trashItem` on the staged path (:328-350). In permanent mode, a read-only prewalk for mount points and anomalies, `markIrreversible`, then an fd-anchored recursive delete with a depth cap of 128 (:354-420).
  - Every failure before the point of no return renames back with `RENAME_EXCL`. It never overwrites a rebuilt original (`rollbackBlocked`, :298-326).
  - `DiskCleanStagingReconciler` reconciles incomplete journal entries at launch (`DC/DiskCleanStagingReconciler.swift:54-144`). This solves F-0036 (MangoDisk).
  - Terminal states are recorded honestly (`DiskCleanRemovalDisposition`, :5-26). The audit log is JSONL, rotated at 5 MB, with 2 generations (`DC/DiskCleanAuditLog.swift:5, 91`). "Attention" rows are pinned at the top of history (`DC/DiskCleanCleanupHistoryView.swift:49-58, 124-137`).
- **The weak spot in the primitive: the Trash name.** The staged name reaches the Trash. Verified with `trash_name_probe.swift`: the entry is `.mactools-staged-…`, which is hidden in Finder. Put Back lands on the hidden name (the author's comment, `DC/DiskCleanRemovalPrimitive.swift:13-14`). The path is then protected forever as "staging in progress" (`DC/DiskCleanSafetyPolicy.swift:144-145`). Filed as **F-0064**.
- **Trash is the default; privileges are never raised.** The mode defaults to Trash (`DC/DiskCleanPlan.swift:32`). Permanent mode needs a two-step confirmation. Nothing runs as root.
- **No dry-run mode**, but the scan itself is read-only and the plan is reviewed before anything runs.
- **Safety policy** (`DC/DiskCleanSafetyPolicy.swift`). Lexical checks on the physical path and every logical alias:
  - traversal, control characters, protected system roots (:313-345);
  - credentials, TCC, iCloud, browser profile files, password managers, VPN tools and system-state tokens, matched by `contains` (:131-305);
  - a whitelist (`DC/DiskCleanWhitelistStore.swift`).

  Over-matching (for example any path containing `keyboard`) only skips items.
- **Running-app locks are opt-in per target.** Only Xcode, Simulator, Chrome and Arc targets declare locks (`DC/DiskCleanRuleCatalogV2.swift:719-1440`). The biggest target, `~/Library/Caches/*` (low risk, pre-selected, :88-114), has **no** lock at all. A running app's dotless cache folder is trashed. This is the F-0015 class, and the evidence is in a comment.
- **Consequence copy.** `cache.macos-app-state` (medium risk) includes `~/Library/Autosave Information/*` (:145-172) but declares no explanation. It inherits the category consequence "Apps may not restore previous windows; preview thumbnails must be rebuilt" (`Localizable.xcstrings` `category.systemCaches.consequence`). That folder is where unsaved or untitled documents are autosaved. This is common macOS knowledge, but no Apple document for it was found here (the `NSDocument.autosavedContentsFileURL` abstract does not name the folder), so treat the semantics as **unverified**. It belongs to the F-0027 user-data class.
- **Developer-artifact purge** (`DC/DiskCleanPurgeScanner.swift`). User-configured roots only, with overly broad roots rejected (`c41ca2c`, `c1dabf6`). The name must match a marker in the same folder: `node_modules`+`package.json`, `target`+`Cargo.toml`, and `build`/`dist`+`package.json|setup.py|pyproject.toml`. `__pycache__` needs no marker. Depth cap 6. Git state comes from `git status --porcelain` and `git log --branches --not --remotes` with a 2 s timeout, and it fails dirty (:1-120, 428-500). A git-tracked `build/` is still offered (the F-0035 class).
- **Installers.** The top level of `~/Downloads` only, with `.dmg/.pkg/.iso`. Anything newer than 7 days is not pre-selected (`DC/DiskCleanInstallerScanner.swift:1-120`).
- **XcodeClean plugin (separate).** It pre-selects **every** category, Archives included (`Plugins/XcodeClean/Sources/XcodeCleanController.swift:57-60`). It deletes permanently through `FileManager.removeItem`, after only a string-prefix allow check and an existence check (`XcodeCleanExecutor.swift:36-75`, `XcodeCleanScanner.swift:83-85`). These are the F-0027 and F-0012 classes. Issue #348 plans Trash-first cleanup.
- **StorageExplorer Trash** (`SE/StorageExplorerSafetyPolicy.swift:182-316`).
  - Validation, then `openVerified` (identity by fd).
  - Rename into `<parent>/.mactools-trash-<UUID>/<name>`, re-verify, `NSWorkspace.recycle`.
  - Restore on failure, then `rmdir` the staging folder.
  - The Trash entry keeps the visible original name (probe). What Finder's Put Back does once the staging folder is gone is **unverified**.
  - Guards: any path that is an ancestor or descendant of the keychain, TCC, Mobile Documents, `.ssh` or `.gnupg` locations is blocked (:374-403), and so is anything under `/System`, `/usr`, `/Volumes` and similar roots (:415-449). As a result, the firmlink spelling `/System/Volumes/Data/Users/<me>` is blocked, so the F-0039 class does not apply here.

## UI

- **DiskClean.** A menu-bar panel row plus a "workspace" settings page: a category list with per-item rows, badges (in use, protected, whitelisted, partial reasons), a removal-mode picker, results and history (`DC/DiskCleanDetailView.swift`, `DiskCleanCategoryListView.swift`, `DiskCleanCleanupHistoryView.swift`). There is **no Reveal in Finder** in DiskClean (grep finds none). #347 asks for it. The UI strings are Chinese by default, with 11 localizations (`Resources/Localizable.xcstrings`).
- **StorageExplorer.**
  - A SwiftUI treemap: a background `Canvas`, plus one view per tile for tap and context menus (`SE/StorageExplorerHierarchyTreemapView.swift:189-213, 476-483, 598-617`).
  - Layout: a nested "binary split at half weight", not squarified, so thin slivers are possible. Nesting goes 3 levels deep and shows at most 48, 18 and 10 children per level, plus an "Other" remainder tile. The whole map is capped at 500 rectangles, and nested levels need at least 44×34 pt (`SE/StorageExplorerHierarchyLayout.swift:75-110, 128-186, 187+`).
  - Colours are stable by the size rank of the top-level item, and descendants inherit their group's colour.
  - Drill-down (`drillDown`, `navigateUp`), Reveal in Finder (`StorageExplorerController.swift:404`), Quick Look (`QLPreviewView`), and drag or plus-button into an always-visible review basket that removes ancestor/descendant overlap (:347-379).
  - During a refresh the previous visualization stays in place.
- Not run here: building the app needs Xcode plus XcodeGen, and the machine was loaded. Visual quality was judged from code and README screenshots only.

## Tests & quality

- DiskClean: 33 test files with 305 `func test`, about 8.5k lines. They cover the parser, both walkers, the pool (including the exactly-once race, abandonment, circuit breaking and queued-timeout budget), the removal primitive, the journal, the reconciler, the planner and the engine. StorageExplorer: 5 files with 60 tests.
- CI: `.github/workflows/build.yml` runs `xcodebuild … test` with 120 s test timeouts and serial tests, plus Python script tests.
- Gaps found:
  - no test where a cooperative job reaches its own deadline at the same instant as the pool timer (the case F-0065 describes);
  - no test with a real mount point in a scanned folder for StorageExplorer (grep finds no `mount` in `StorageExplorerScannerTests.swift`);
  - no test for what a trashed item is called in the Trash.
- Code quality is high: long "why" comments, typed errors, fd ownership rules written down per protocol, and honest copy ("about X", "Trash does not free space until emptied", `DC/DiskCleanDetailView.swift:308-311`). The repo carries `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`, and `cursoragent` commits show agent-written code, so check comments against behaviour. The docs drift twice (worker count, retained-file cap).

## Known problems

| # | Problem | Evidence | Board |
|---|---|---|---|
| 1 | Trash mode leaves items hidden as `.mactools-staged-<UUID>`. Put Back restores the hidden name, and later scans protect it forever. | `DC/DiskCleanRemovalPrimitive.swift:240-350`, `DC/DiskCleanSafetyPolicy.swift:144-145`, `trash_name_probe.swift` (verified) | **F-0064** |
| 2 | One thread per item with a 20 s wall clock. A partial size is uncleanable, so folders above about 0.7-3.8M files can never be cleaned. | `DC/DiskCleanScanEngine.swift:53-58`, `DC/DiskCleanModels.swift:324-327`, `walker_throughput_main.swift` (measured) | **F-0065** |
| 3 | StorageExplorer's mount guard reads devid from `getattrlistbulk`, which gives a mount point the covered device. The mounted volume's root files are counted (+64 MiB in the probe). A `/` scan double-walks Data. | `SE/StorageExplorerScanner.swift:282, 312-316`, `mount_guard_probe.sh`, `bulk_devid_mountpoint_probe.c` (verified) | F-0031 class, comment on T-0018 |
| 4 | The size cache is validated by the root's `(dev, ino, mtime)` only, so a nested change is stale for up to 240 s. | `DC/DiskCleanSizeCache.swift:36-143` | F-0017 class |
| 5 | `~/Library/Caches/*` is pre-selected with no running-app lock. | `DC/DiskCleanRuleCatalogV2.swift:88-114`, lock declarations only at :719-1440 | F-0015 class |
| 6 | Logical sizes (`DATALENGTH`), with clones counted in full | `DC/DiskCleanDirectoryTreeWalker.swift:184` | F-0004 class |
| 7 | XcodeClean pre-selects Archives and deletes permanently. | `XcodeCleanController.swift:57-60`, `XcodeCleanExecutor.swift:61-63` | F-0027 / F-0012 class |
| 8 | StorageExplorer keeps only the top 10k files (the doc says 50k). Smaller files cannot be selected. | `SE/StorageExplorerScanner.swift:16`, docs | F-0016 class |
| 9 | Pool timeout and walker deadline are the same instant. The walker won 10 of 10 races, but a lost race blacklists the volume for the process lifetime. | `DC/DiskCleanWorkerPool.swift:174-183, 265-321`, `pool_timeout_probe.sh` | noted in F-0065 |

## Reuse table

"Apache@9197035" means: fetch the file at `ggbond268/MacTools@9197035650b67f1c313960e8b1dded7a710264dd`, the last revision before the GPL switch. There, `LICENSE` is Apache-2.0, and the file is byte-identical to HEAD (checked by diffing all 39 DiskClean source files: 25 identical, including every engine file named below). Keep the Apache notice, add a NOTICE entry, and mark our changes. Anything GPL-era (StorageExplorer, `Sources/MacToolsFileSystem`) is ideas only.

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Exactly-once resume gate + abandonable resident thread pool | take (Apache@9197035), then improve | `DC/DiskCleanWorkerPool.swift` | This is the one clean way to join "blocking syscall" with "continuation resumed once". Improve it with a progress-heartbeat watchdog instead of a wall-clock deadline (F-0065). |
| Walk-completeness typing (`complete` / `partial{…}`) + accumulator | take (Apache@9197035) | `DC/DiskCleanSizingModels.swift` | A partial result never looks complete. The reasons drive the UI badges. Decouple "partial" from "not cleanable" (F-0065). |
| fd-anchored DFS walker, depth-bounded fds, raw-byte names, per-entry devid guard | take the idea, rewrite parallel | `DC/DiskCleanDirectoryTreeWalker.swift`, `DC/DiskCleanFastWalker.swift`, `DC/DiskCleanSlowWalker.swift` | Correct semantics, but single-threaded. macontrol needs the work-stealing pool (F-0009). Add an `ATTR_DIR_MOUNTSTATUS` stop (F-0031). |
| getattrlistbulk parser with layout-offset check and no `ATTR_CMN_ERROR` | take (Apache@9197035: full parser in `DC/DiskCleanBulkAttributeParser.swift`) | Apache-era `DC/DiskCleanBulkAttributeParser.swift`; HEAD `Sources/MacToolsFileSystem/FileSystemBulkAttributeParser.swift` (GPL, study) | Defensive and verified: 0 mismatches on APFS. Add `ALLOCSIZE`, `MOUNTSTATUS`, `FLAGS` (dataless) and clone attributes. |
| Root opener: `O_NOFOLLOW_ANY` + `O_NONBLOCK` + `MNT_LOCAL`, symlink-leaf handling via parent fd | take (Apache@9197035) | `DC/DiskCleanRootOpener.swift` | Closes the intermediate-symlink and FIFO-hang holes in about 130 lines. |
| Removal primitive: verify, journal+fsync, `renameatx_np(RENAME_EXCL)`, re-verify, dispose, rollback | take (Apache@9197035), then improve | `DC/DiskCleanRemovalPrimitive.swift`, `DC/DiskCleanStagingJournal.swift`, `DC/DiskCleanStagingReconciler.swift` | The strongest delete path in the survey (answers F-0012 and F-0036). Change the staging so the original name reaches the Trash, and add an in-app restore (F-0064, T-0026). |
| Mint-once validated plan + ancestor/reserved-root assertion + expiry gate | take (Apache@9197035) | `DC/DiskCleanPlan.swift`, `DC/DiskCleanModels.swift:358-470` | Makes "delete only what was reviewed" a type-level guarantee. |
| Ancestor decomposition of overlapping rule hits | take (Apache@9197035) | `DC/DiskCleanScanEngine.swift:864-960` | Keeps the per-target risk and lock intact when globs nest. |
| Rule catalog (54 targets, explanations, FDA flags, locks) | study; rewrite as a data file | `DC/DiskCleanRuleCatalogV2.swift`, `DC/DiskCleanRuleModels.swift`, `DC/DiskCleanDynamicRules.swift` | Good schema (risk per target, reserved roots, explanation fields). Rules compiled into Swift are not updatable. Fix `Autosave Information` (F-0027 class) and add a generic running-app guard for `~/Library/Caches/*` (F-0015). |
| Running-app snapshot (one NSWorkspace read + one batched `pgrep -x`, refreshed per item) | take the idea | `DC/DiskCleanRunningAppLock.swift` | Cheap and fails open by design, with an execution-time recheck. Needs a generic cache-to-app mapping. |
| FDA probe (user TCC.db, then Safari bookmarks, open read-only) | take the idea | `DC/DiskCleanFullDiskAccess.swift` | Uses the *user* TCC.db, which is FDA-protected, so it avoids F-0001. The process-lifetime cache follows the relaunch assumption (T-0011: unverified). |
| Size cache keyed by path + root identity | rewrite | `DC/DiskCleanSizeCache.swift` | The root mtime misses nested changes (F-0017). Use FSEvents or a journal-driven cache. |
| Audit log (JSONL, rotation, pinned attention rows) | take the idea | `DC/DiskCleanAuditLog.swift`, `DC/DiskCleanCleanupHistoryView.swift` | Honest, per-item terminal states. |
| Developer-artifact purge with marker + git state (fails dirty) | study | `DC/DiskCleanPurgeScanner.swift` | Better than kondo (F-0033, F-0035), but still offers a tracked `build/`. |
| StorageExplorer parallel scanner + deterministic hard-link charging | study (GPL) | `SE/StorageExplorerScanner.swift` | Re-implement the lexicographic-minimum charging (fixes F-0054). Do not copy the directories-only devid guard. |
| StorageExplorer staging folder that keeps the original name | study (GPL) | `SE/StorageExplorerSafetyPolicy.swift:256-316` | The right idea for F-0064. Keep the folder until the trash call returns, and own the restore. |
| Nested treemap layout (binary split, top-N + Other, 500-rectangle cap) | ignore | `SE/StorageExplorerHierarchyLayout.swift` | Not squarified, and hides files (F-0016 class). WinDirStat's MIT Hilbert/Moore layout and Radix are better bases. |
| XcodeClean | ignore | `Plugins/XcodeClean` | Pre-selects Archives, deletes permanently, uses a string-prefix guard. DiskClean supersedes it. |

## Open questions

- Is the 2.0 design document (the "§3.3", "§7.4" references) published anywhere? It would explain the thresholds (20 s per item, 300 s gate, abandon budget 3). Not found in `docs/`.
- What does Finder's Put Back do for an item whose recorded original folder (StorageExplorer's `.mactools-trash-<UUID>`) no longer exists? Unverified, because it needs a GUI click.
- Does `FileManager.trashItem` record Put Back metadata at all for non-Finder callers on macOS 26? MacTools asserts it does ("lands under the staged name"). Not checked.
- How common are single cache folders above about 0.7M files among real users? This sets the priority of F-0065. The largest on this Mac is 28k entries.
- Is the Apache-2.0 grant for pre-`bcd9f9f` DiskClean code clean for every contributor? `LICENSING.md` says yes. rkrkrkk and cursoragent wrote the 2.0 code on 2026-07-30/31, while the repo was Apache-2.0. Posted on T-0003 for the license matrix.
