# Source deep dive: Neodisk (tkslucas/Neodisk)

Task T-0024, researcher `dive-tkslucas-neodisk`, 2026-09-23. Clone: `research/sources/tkslucas-neodisk` at `b26a08c` (2026-09-07, "fix: release scan memory and support Intel Macs"). All paths below are relative to that clone unless marked otherwise.

"Verified" means I ran it on this Mac (macOS 26.6). Everything else comes from reading the code. I did not build the app or run `swift test`: the package is about 47 k lines of source plus 28 k lines of tests, it pulls in swift-testing and Sparkle, and the machine was loaded. The two probes below compile single source files only.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/tkslucas/Neodisk (homepage https://neodisk.app) | `gh api repos/tkslucas/Neodisk` |
| License | **GPL-3.0-or-later** for Neodisk's own code. The LICENSE file adds a "Third-party notices" section: the scan engine, core data model, sunburst and flat treemap style "derive from Radix … used under the following license: MIT", followed by Colin Kim's MIT text. | `LICENSE:676-704`, `README.md` "Credits" and "License" |
| Stars / forks | 580 / 19. Not a fork, not archived. | `gh api`, 2026-09-23 |
| History | 287 commits, all by `tkslucas`. The first commit is `75ae65e6` (2026-07-07). The GitHub repo record says it was created 2022-06-10, so it looks like a reused repo, but no public history exists before 2026-07-07. The last commit on `main` is `b26a08c` (2026-09-07). The latest release is **v2.71.0 (2026-07-26)**. `main` says 2.72.0 (`Sources/NeodiskUI/App/AppVersion.swift:9`), which has not been released. | `gh api .../commits`, `.../releases`, `.../contributors` |
| Language / size | Swift 6 (swift-tools 6.0), SwiftUI plus AppKit, macOS 14+. Sources are about 47.2 k lines in 201 files. Tests are 27.7 k lines in 114 files, with 915 `@Test` cases (Swift Testing). | `Package.swift:1-19`, `wc -l`, `grep -c @Test` |
| Dependencies | swift-testing (for tests), and Sparkle ≥ 2.9.6 for the app only. Sparkle is configured properly: `SUFeedURL` is https://neodisk.app/appcast.xml and there is an `SUPublicEDKey`. That is the opposite of F-0003. | `Package.swift:44-51`, `Packaging/Info.plist:53-64` |
| Distribution | A DMG from GitHub Releases and a Homebrew cask (`brew install --cask neodisk`). There is no entitlements file in the repo, so it is not sandboxed. The packaging script `package-app.sh` is referenced but is not in the repo. | `README.md`, `ls Packaging`, `AGENTS.md` "Localization" |
| Issues | 4 open. #9 "Memory leak": 31.5 GB of RAM after a few scans, on v2.71.0. #8 "Not supported on Intel Macs", because v2.71.0 is arm64 only. #10 "file names cut off at a larger font size". #7 is an outside PR fixing a reentrant NSTableView selection. 3 closed (Homebrew, font size, volume tooltip). The fix for #8 and #9 is in `b26a08c` but has not been released. | `gh api .../issues?state=open`, commit `b26a08c` file list |
| CI | **None.** `.github/` holds only FUNDING, issue templates and a PR template. Nothing runs the 915 tests automatically. | `ls .github` |
| Agent-built | `AGENTS.md` (15 KB) is the contributor contract, and `CLAUDE.md` is just `@AGENTS.md`. | repo root |

**Lineage (the open question from the sweep), settled:** Radix is the original and Neodisk is the derivative.
- The notice has been in Neodisk since its initial commit. `75ae65e6:LICENSE` already reads "Neodisk's scan engine and core data model derive from Radix", and `75ae65e6:README.md:69-70` credits Radix. The sunburst and flat-treemap credits were added in `c925b152` (2026-07-09) and `fbff8872` (2026-07-19).
- `colinvkim/Radix` was created on 2026-04-02, three months before Neodisk's first commit.
- Both codebases have moved on since. Across 9 shared file names, 35-90 % of Neodisk's lines are changed or new compared with Radix@14a76df. `IncrementalScanService` has 942 of 1 083 lines changed, `ScanEngine` 287 of 627.
- But some code is still byte-identical. For example `AtomicDirectorySummaryProbe.swift:58-85` matches Radix's `:57-84` exactly.

**What the license lets macontrol do:**
- Neodisk's own code is GPL-3.0. We can copy it only if macontrol itself ships under GPL-3.0 (license decision: T-0003). Until then it is **study only**: ideas and algorithms, no code.
- For anything Neodisk took from Radix, use Radix directly under MIT. Never copy the Neodisk version, because that version is GPL-covered.

## Summary

Neodisk is a native, **read-only** macOS disk visualizer. It shows a cushion treemap (or a flat nested-box treemap) and a DaisyDisk-style sunburst over one scan tree, with an outline list, a statistics panel and a sidebar of locations. It never deletes: "Move-to-Trash was removed on purpose — do not reintroduce it" (`AGENTS.md:166-167`). The only file actions are Reveal in Finder, Open and Copy Path (`Sources/NeodiskUI/System/FileNodeActions.swift:36-38`).

Features that Radix does not have (per README and code):
- An **age heatmap**: the map is coloured by modification age, with buckets measured against the scan date (`Statistics/AgeStatistics.swift:15-17`).
- **Content-hash duplicates**: a tiered SHA-256 ladder, clone-aware reclaim figures, and dataless files skipped (`NeodiskKit/Services/DuplicateFinder.swift:1-24`).
- A **Changes tab**: an exact diff of the scan against the previous one, with Added / Deleted / Renamed / Grown / Shrunk rows (`NeodiskKit/Models/ScanChangeList.swift:1-29`).
- **Persisted snapshots** that reopen instantly, and incremental FSEvents rescans that also work after a relaunch.
- **Show Package Contents**: a bundle stays one solid tile at its full size until the user expands it.
- Arrow-key navigation in both charts, pinch to zoom or drill, ⌘F fuzzy search, Quick Look, volume free and hidden space, 6 palettes, and 8 languages.
- **CloudScan** of Google Drive, Dropbox and OneDrive through OAuth (`Sources/CloudScanKit`).

What it offers macontrol:
- A second, independently evolved implementation of the Radix engine that is **ahead of Radix on memory and incremental rescans** (see Scanning).
- The best duplicate-finder and "what changed" designs in the survey so far.
- A polished treemap interaction model.

What it does badly, or not at all, for us:
- No cleanup or deletion at all.
- A persisted scan cache that leaks everything the Full Disk Access scan saw (**F-0045**, verified).
- A duplicate hash cache that is unsafe to delete from (**F-0046**, verified).
- The Radix auto-summary defect, inherited (**F-0040**).
- No CI.
- A 31.5 GB memory report whose fix is not released.

## Architecture

- **SwiftPM only, Command Line Tools only, no Xcode** (`AGENTS.md` "Environment Facts"). There are six targets (`Package.swift:53-139`):
  - `NeodiskKit`: the scan engine and data model. It uses Foundation, Darwin, Dispatch, CryptoKit and UTType only, with no AppKit or SwiftUI, and the target graph enforces that.
  - `TreemapKit`: squarified layout plus the cushion and flat rasterizers. It is portable stdlib SIMD.
  - `SunburstCore`: layout, hit-testing and zoom math. It is Foundation-only, so it can be built "for a WebAssembly demo".
  - `CloudScanKit`: providers and OAuth. It can be dropped by editing the dependency list.
  - `NeodiskUI`: the SwiftUI/AppKit app.
  - `NeodiskCLI`: `diskscan`, a reference CLI with `--bench-rescan`.
- **UI and engine are separated by an event stream.** `ScanEngine.scan(target:options:)` returns an `AsyncThrowingStream<ScanProgressEvent, Error>` with `bufferingNewest(256)`, and `onTermination` cancels the scan (`NeodiskKit/Services/ScanEngine.swift:264, 435-460`). `AGENTS.md` notes that `.finished` must never be dropped.
  - `ScanEngine` is a `Sendable final class` rather than an actor. It used to be an actor, and a scan that was still cancelling blocked a new one (`ScanEngine.swift:10-15`, regression test named there).
- **UI state** lives in `NeodiskViewModel` (737 lines) with `+Navigation` and `+FileActions` extensions. Focused sub-models sit beside it: `ScanSessionModel`, `ScanCoordinator`, `DiffModel`, `FreeSpaceModel` and `CloudAccountsModel`. That is smaller than Radix's 3 267-line `AppModel`.
- **Dev hooks are first-class** (`AGENTS.md` "Dev hooks"):
  - `NEODISK_HEADLESS` runs the app off-screen.
  - `NEODISK_SCAN_TIMING=1` prints per-phase timings plus "felt-time" marks (`app.firstPartialDisplayed`, `app.feltTotal`).
  - `--render-png` does a headless treemap render.
  - `NEODISK_UI_SNAPSHOT` captures the window off-screen.
  - `NEODISK_INCREMENTAL=0` disables incremental rescans, and `NEODISK_SNAPSHOT_DIR` points the cache elsewhere.
  - T-0004 and our own harness can copy this pattern.

## Scanning

- **Syscalls.** `BulkDirectoryReader` opens each directory with `open(path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` on its **full path** and calls `getattrlistbulk` with `FSOPT_ATTR_CMN_EXTENDED` (`BulkDirectoryReader.swift:162-167, 178-199, 209-215`). The attributes it requests:
  - common: name, devid, objtype, modtime, Finder info, flags, useraccess, fileid;
  - directory: `ATTR_DIR_MOUNTSTATUS`;
  - file: linkcount, allocsize, datalength;
  - extended: `ATTR_CMNEXT_CLONEID | CLONE_REFCNT`.

  Differences from Radix:
  - Radix opens children relative to the parent descriptor through `openat` (`Radix/Services/ScanDirectoryDescriptorPool.swift:32`). Neodisk has no `openat` anywhere, so paths longer than PATH_MAX are the F-0008 class. How it behaves there is **unverified**.
  - Radix also requests `ATTR_CMNEXT_REALDEVID` and `EXT_FLAGS`, and Neodisk does not.
- **Dataless files are never materialized.** Each read calls `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, …OFF)` again, because cooperative-pool threads get reused (`BulkDirectoryReader.swift:153-160`).
  - Dataless files are kept in the tree, with `isDataless` and `cloudOnlyLogicalSize` (`FileNodeRecord.swift:29-39`). A toolbar toggle weights the map by cloud-only size, and the cushion raster hatches those tiles (`CushionTreemapRenderer.swift:36-42`).
  - This is better than Radix, which skips them (Radix report).
- **Blocking I/O stays off the Swift cooperative pool.** It runs on bounded, dedicated serial GCD workers, and each worker owns one reusable `getattrlistbulk` buffer (`DirectoryIOExecutor.swift:5-7`).
- **Concurrency policy** (`ScanConcurrencyPolicy.swift`):
  - Limits come from the core count, derated by Low Power Mode and thermal state. Thermal state is sampled again during traversal, so a long scan sheds workers as the machine heats up (`:5-10, 132-150, 196-213, 303-340`).
  - A "ruling" decides whether a second scan may run alongside the first (`:92-131`). On different devices they run together. On the same conservative disk, an explicit scan cancels the old one, and an implicit refresh defers.
- **Size semantics.** Each node keeps `allocatedSize` (after dedup), `unduplicatedAllocatedSize`, `logicalSize` and `cloudOnlyLogicalSize` (`FileNodeRecord.swift:8-40`). The map uses allocated bytes.
  - **Hard links:** the first path owns the bytes, and other links are subtracted (`HardLinkDeduplicator.swift:29-35`).
  - **Clones:** this differs from Radix. The first member of a full-clone family (same `CLONEID`, `CLONE_REFCNT > 1`) keeps its full allocated size. Every other member is charged `min(allocated, ATTR_CMNEXT_PRIVATESIZE)` (`CloneDeduplicator.swift:5-15, 76-140`).
  - The private-size reads overlap with the traversal (`ClonePrivateSizePrefetcher.swift:5-18`). The comment says they cost "~45 s on a 1.5 M-node home dir" when done serially (`CloneDeduplicator.swift:58-61`, their figure, unverified).
  - Private size is the "frees if deleted" figure that F-0004 asks for. The T-0009 traps still apply: PRIVATESIZE is 0 for decmpfs files and is counted per inode for hard links (`research/reports/topic-size-accounting.md` rows 7-8).
- **Volume boundaries.**
  - Child mounts stay visible but are not traversed. The scan root's own device set is widened for `/`, `/System` and `/System/Volumes/Data` (`MountBoundaryPolicy.swift:8-47`).
  - Firmlinks are translated from `/usr/share/firmlinks` for FSEvents paths (`FirmlinkPathTranslator.swift:5-12`).
- **Packages** are detected from the Finder bundle bit or a UTType package extension (`BulkDirectoryReader.swift:408-411, 500-535`). The engine summarizes them through the atomic-summary pool, so they get their real total size and count as one leaf (`ScanTraversal.swift:434-437`).
  - "Show Package Contents" rescans only that bundle with `treatRootPackageAsDirectory` and splices the result in (`NeodiskUI/Model/NeodiskViewModel.swift:672-722`). Nested bundles stay opaque.
  - This is the correct answer to F-0028 (Mac Sai sizes packages as 0 B).
- **Auto-summary** is inherited from Radix unchanged: at depth 2 or more, a folder with at least 5 000 files averaging 4 KiB or less is summarized, and the decision comes from the same 100-entry stride sample (`AtomicDirectorySummaryProbe.swift:58-85`, `ScanTraversalModels.swift:229-237`, on by default at `AppPreferences.swift:65`). That is **F-0040**. The evidence is posted on T-0021.
- **Memory model.** This is ahead of Radix (compare F-0041):
  - `FileNodeRecord` stores the path as a `String` and builds a `URL` only on demand (`FileNodeRecord.swift:9-13, 44-47`).
  - Storage is preorder arrays: `[FileNodeRecord]`, `parentIndices: [Int32]` and child spans (`TreeStorage.swift:1-35`).
  - The id index is split into 16 shards keyed by a precomputed FNV-1a hash, because SipHash on long paths was "~60 % of decoding a millions-of-nodes snapshot" (`NodeIDIndex.swift:1-10`).
  - Each node still carries a full-path `String` plus a name, so macontrol's F-0041 target (a name buffer plus a parent index) remains leaner.
  - Issue #9 reports 31.5 GB after a few scans on v2.71.0. The unreleased `b26a08c` changed 56 files to "release scan memory". Whether it is fixed is **unverified**.
- **Incremental rescans.** Also ahead of Radix:
  - An FSEvents checkpoint (volume UUID, event id, OS build) is taken at scan start and stored inside the snapshot (`ScanSnapshotCodec.swift:52-57`, `ScanIncrementalModels.swift:14-40`). So incremental rescans survive a relaunch, and volume targets are covered ("8x felt rescan win at /", commit `4ab95bf5`).
  - The service falls back to a full scan for 26 enumerated reasons, the same count as Radix (`ScanIncrementalModels.swift:158-185`).
  - Splices rebuild the contiguous storage in one copy pass and redo hard-link and clone dedup once (`FileTreeStore+NumericSplice.swift:1-25`, `HardLinkDeduplicator.swift:66-68`). The older dictionary path is kept as a test oracle.
  - By code reading, Neodisk therefore avoids both F-0037 (links re-counted after a splice) and F-0038 (replaced nodes never freed). That is **not run**.
- **Progress.** It is determinate, monotonic, and full only when the scan is done. That is a written product rule (`AGENTS.md:174-180`), and it applies to the duplicate pass too (`DuplicateFinder.swift:198-205`, `ProgressAccounting`).
- **Hidden space** is `capacity − availableForImportantUsage − scannedAllocated` (`VolumeSpaceInfo.swift:43-54`).
  - `FreeSpaceModel.swift:24-26` says hidden space includes "purgeable space, local snapshots". But `usedBytes` already treats purgeable space as available, so purgeable space cannot land in hidden space.
  - Scanned purgeable files (they are in the tree) push `scanned` above `used` and lower the hidden figure.
  - On this Mac, purgeable space is 1.83 GB (`important 40.25 GB − free 38.42 GB`, measured). That is too small to show the effect. This goes to T-0009 as a note, not a finding.

## Deletion & rules

- **None, by design.** There are no cleanup rules, no leftover heuristics, no trash, no `rm`, no helper and no privilege escalation.
  - The only writes in the whole codebase are to its own cache: `ScanSnapshotCache.swift:224-230, 305-364, 590-612`, plus a dev snapshot and a CLI bench file. I checked this by grepping for `trashItem|removeItem|unlink|rename|moveItem|write(to`.
  - The initial public commit has no trash code either (`git/trees/75ae65e6` lists no trash, discard or delete files).
- Double-click reveals in Finder rather than opening, for both treemap cells and file lists (`FileNodeActions.swift:21-26, 45-51`). That is a safe default to copy. "Open" is a separate menu item.
- The **Full Disk Access** status probe is the Radix design: the user TCC.db acts as gatekeeper, a quorum of Mail, Messages, Safari and HomeKit acts as evidence, and there is a macOS 27 sentinel set (`NeodiskUI/System/SystemIntegration.swift:217-345`). Settings encourages the grant "for protected macOS locations such as Mail, Safari, Messages" (`SettingsView.swift:268-269`).
- **Duplicates** are the closest thing to a cleanup feature. The design is careful:
  - Hard links are collapsed by `FileIdentity`, and APFS clone groups show 0 reclaimable bytes (`isAllClones`, `DuplicateFinder.swift:36-55, 142-158`).
  - Dataless, non-regular and vanished files are rejected by a `stat` before any `open`, so a stalled cloud provider cannot wedge a worker (`:160-189, 470-481`).
  - Files are read with `F_NOCACHE` (`:561-572`).
  - But the cross-run digest cache trusts size + mtime + inode (**F-0046**, verified). Hash reads use plain `open(path, O_RDONLY)` without `O_NOFOLLOW` or `O_NONBLOCK` (`:568`), so a path swapped for a FIFO after the `stat` would block a worker. That window is narrow and I did not file it. It is folded into F-0046's "how".

## UI

- **Treemap.**
  - Squarified layout (Bruls et al. 2000; `TreemapKit/TreemapLayout.swift:5`).
  - Cushion shading after van Wijk & van de Wetering 1999. It is rasterized in parallel on the CPU into RGBA8 with sRGB-aware Lambert shading (`CushionTreemapRenderer.swift:5-35`).
  - The flat style is a nested-box renderer with scaled corner radius and gaps (`FlatTreemapRenderer.swift:5-40`).
  - Small children are merged into one area-true "smaller items" cell per directory, and that cell can be expanded (`TreemapScene.swift:59-61, 116-121, 411-500`). No F-0016 or F-0020 problem.
- **Treemap interaction.**
  - Gestures change the `CALayer` transform directly, never through SwiftUI state (`TreemapNSView.swift:5-11`, `AGENTS.md` Notes). The controller keeps "one render in flight, latest viewport wins", with overscan so panning shows crisp pixels (`TreemapController.swift:5-10`, `TreemapScene.swift:53-55`).
  - It renders at `backingScaleFactor` (`TreemapController.swift:57-58`). That is the fix F-0043 asks of GrandPerspective.
  - Hover ring, selection ring, and tooltip hidden during gestures (`TreemapController.swift:23-31`).
- **Sunburst** is ported from Radix into `SunburstCore`. Arrow keys work: ←/→ move between siblings in angular order, ↑ goes to the parent, ↓ to the largest child, and pooled or out-of-depth arcs are skipped (`Sunburst/SunburstKeyboardNav.swift:5-30`).
  - Pinch drills one level per gesture through a shared latch (`Shared/PinchDrillRecognizer.swift:5-16`).
- **Navigation.**
  - ⌘↓ / ⌘↑ drill in and out, and there is a breadcrumb bar.
  - ⌘F opens fuzzy search over the whole snapshot (`Search/FuzzySearch.swift`), and space opens Quick Look.
  - Menu commands have shortcuts (`App/NeodiskCommands.swift:37-259`).
  - The outline can be docked to the left or bottom.
  - Toolbar buttons "stay persistent and disable" rather than appearing and disappearing (`AGENTS.md:172-173`).
- **Statistics panel.**
  - Tabs: Kinds, Largest, Age, Duplicates, Changes (`Statistics/*`).
  - Drilling into a kind, an age bucket or a duplicate group lights those tiles and dims the rest of the map (`TreemapScene.swift:26-31`).
  - Age uses **mtime only**. A file modified long ago but opened daily shows as "stale". For a cleaner's "old files" suggestions, macontrol should also use a last-used signal. This is a feature note, not a finding.
- **Text scale.** There is a workspace text size setting (⌘+/⌘−) and 8 localizations. Issue #10 shows an alignment bug at large sizes.
- **Performance.** I did not measure the UI. Two commits were perf work: `042642b0` "improve post-scan UI responsiveness" and outside PR #6 "eliminate O(n) allocations on sunburst hover path".

## Tests & quality

- 915 Swift Testing cases in 114 files (27.7 k lines). They include golden-image tests for the cushion render (`Tests/TreemapKitTests/Fixtures`) and **equivalence oracles**: numeric splice vs the dictionary path, incremental rescan vs a full scan, relist vs a full scan (`IncrementalRescanEquivalenceTests.swift`, `FileTreeStoreRelistEquivalenceTests.swift`, `ScanTreeAssemblerEquivalenceTests.swift`). That is a strong pattern for macontrol's own fast paths.
- Test hygiene: commit `fbf75dbe` "stop tests from leaking UserDefaults plists into ~/Library/Preferences". I did not run the suite. Before anyone does, grep the tests for real-home paths (M-0001 lesson).
- There is **no CI**, so the tests run only when the single maintainer remembers to run them.
- The code is dense and heavily commented, agent-written like Radix. Most decisions state their reason and point to the test that pins them.

## Known problems

1. **F-0045 (high, verified):** the scan cache persists every scanned name, including FDA-only and Files-and-Folders-protected ones, unencrypted and at mode 0644, in `~/Library/Application Support/Neodisk/ScanCache/`. Any same-user process without FDA can read it (`research/bench/tkslucas-neodisk/cache_tcc_probe.sh`).
2. **F-0046 (medium, verified):** the duplicate hash cache stamp omits ctime. An in-place rewrite with the old mtime restored returns the stale full digest (`research/bench/tkslucas-neodisk/run_hashcache_probe.sh`).
3. **F-0040 (inherited from Radix):** the sampled auto-summary can hide big files and subfolders. The code is byte-identical.
4. Issue #9: 31.5 GB of RAM after a few scans on v2.71.0. A fix sits on `main` since 2026-09-07, and there has been no release since 2026-07-26. Unverified whether it is fixed.
5. The claim in `SECURITY.md:26`, "it makes no network requests", is false for the shipped app. Sparkle polls `https://neodisk.app/appcast.xml`, and CloudScan calls the Google, Dropbox and Microsoft APIs once connected. It is a documentation error, but it matters for a "read-only, private" pitch.
6. No CI. Single maintainer (287 of 287 commits).
7. Directories are opened by full path, not with `openat`. Behaviour past PATH_MAX (the F-0008 class) is unverified.
8. The hidden-space comment and the math disagree (see Scanning). Not measured.
9. The Changes tab matches renames by (dev, inode) (`ScanChangeList.swift:131-145`). On filesystems that reuse inode numbers, such as exFAT or FAT, this can report false renames. Unverified; APFS does not reuse ids quickly.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Scan engine core (bulk reader, traversal, assembler) | ignore (take from Radix) | `Sources/NeodiskKit/Services/{BulkDirectoryReader,ScanTraversal,ScanEngine*,ScanTreeAssembler}.swift` | Derived from MIT Radix and GPL here. Radix@14a76df has the same design plus `openat`-relative opens. Take Radix under MIT (T-0021). |
| Dataless handling | study | `BulkDirectoryReader.swift:153-160`, `FileNodeRecord.swift:29-39`, `CushionTreemapRenderer.swift:36-42` | Keep evicted iCloud files visible as cloud-only, with a per-thread "no materialize" policy. Better than Radix's skip. Reimplement: it is a few lines. |
| Dedicated I/O workers | study | `DirectoryIOExecutor.swift`, `ScanConcurrencyPolicy.swift:92-131, 196-340` | Keeps blocking `getattrlistbulk` off the cooperative pool. Thermal re-sampling, and the same-disk contention ruling for parallel scans. Hand to T-0004 and T-0006. |
| Tree storage | study | `Models/{TreeStorage,NodeIDIndex,FileNodeRecord}.swift` | Confirms the F-0041 direction (no URL, preorder Int32 arrays, a cheap id hash). macontrol still goes leaner (a name buffer, no full path per node). |
| Clone dedup with private size | study | `Services/{CloneDeduplicator,ClonePrivateSizePrefetcher}.swift`, `Models/CloneInfo.swift` | Charges non-first clones their `PRIVATESIZE`, prefetched during traversal. Combine with the T-0009 traps (decmpfs, hard links) when we write ours. |
| Incremental rescan + persisted checkpoint | study | `Services/{IncrementalScanService,IncrementalRescanPlanner,FileSystemEventHistoryProvider,FirmlinkPathTranslator}.swift`, `Models/FileTreeStore+NumericSplice.swift`, `ScanIncrementalModels.swift` | Survives a relaunch, handles volume targets, compacts and re-dedups on splice. Start from Radix's MIT planner and add these ideas (checkpoint in the snapshot, numeric splice, oracle tests). |
| Snapshot cache + codec | improve | `Services/{ScanSnapshotCache,ScanSnapshotCodec}.swift` | Preorder records with names only, derived ids, LZFSE, metadata readable without decoding, rotation to `.prev` for diffs. Rebuild it with encryption and protected-root aggregation (F-0045). |
| Changes diff | study | `Models/{ScanChangeList,ScanSizeBaseline,ScanChangeListCache}.swift`, `Statistics/Changes*.swift` | The best "what grew since last time" design in the survey: leaf-only grown/shrunk, collapsed added and deleted subtrees, rename by identity. It fits a cleaner well ("this cache grew 4 GB this week"). |
| Duplicate finder | improve | `Services/{DuplicateFinder,DuplicateHashCache}.swift`, `Statistics/Duplicates*.swift` | Tiered head → head+tail → full SHA-256, clone and hard-link aware reclaim, dataless-safe `stat` gate, `F_NOCACHE`. For deletion, add ctime to the stamp and a byte-compare at action time (F-0046). |
| Cushion / flat treemap rendering | study | `Sources/TreemapKit/*`, `NeodiskUI/Treemap/{TreemapScene,TreemapController,TreemapNSView}.swift` | Implement from the papers (van Wijk 1999, Bruls 2000), not from this GPL code. Copy the patterns: layer-transform gestures, latest-viewport-wins renders, overscan, backing-scale raster, area-true "smaller items". |
| Sunburst | ignore (take from Radix) | `Sources/SunburstCore/*`, `NeodiskUI/Sunburst/*` | Ported from Radix. Take Radix's MIT geometry. Study `SunburstKeyboardNav.swift` and `PinchDrillRecognizer.swift` for the interaction rules. |
| Package handling | study | `BulkDirectoryReader.swift:408-411, 500-535`, `ScanTraversal.swift:434-437`, `NeodiskViewModel.swift:672-722` | Bundles sized in full but kept solid, and "Show Package Contents" rescans one bundle. The right model for macontrol's app sizes (contrast F-0028). |
| Age heatmap | study | `Statistics/{AgeStatistics,AgeStatsModel,AgeStatsPane}.swift`, `TreemapScene.swift:16-31` | Buckets measured against the scan date, so renders are reproducible. Add a last-used signal for cleanup use. |
| Volume free and hidden space | study | `Services/VolumeSpaceInfo.swift`, `NeodiskUI/Model/FreeSpaceModel.swift` | Useful "hidden" tile. Fix the purgeable double-count before copying (see Scanning). T-0009 owns the math. |
| Dev and bench hooks | study | `AGENTS.md` "Dev hooks", `NeodiskUI/Dev/*`, `NeodiskCLI/main.swift` | Headless app runs, felt-time marks and `--render-png` fit our benchmark and visual-regression harness. |
| FDA status probe | ignore | `NeodiskUI/System/SystemIntegration.swift:217-345` | Same design as Radix. T-0011's three-state probe is the plan. |
| CloudScanKit | ignore | `Sources/CloudScanKit/*` | Remote Google Drive, Dropbox and OneDrive scanning is out of scope for macontrol's MVP. |
| Read-only stance | ignore | `AGENTS.md:165-167` | macontrol has to delete. Keep only "double-click reveals, never opens". |

## Open questions

- Is issue #9 (31.5 GB) fixed by `b26a08c`, and what is Neodisk's real peak memory for a `/` scan? That needs a build plus `NEODISK_HEADLESS=1 NEODISK_AUTOSCAN=/ NEODISK_SCAN_TIMING=1` under `/usr/bin/time -l`. I did not run it because the machine was loaded. It is a candidate for T-0004.
- Does Neodisk drop, warn about, or mis-size subtrees deeper than PATH_MAX, given that it opens by full path (F-0008 class)? A fixture from `research/bench/make_fixture.sh` plus `diskscan` would answer it.
- For F-0045's fix: for a Developer ID (non-sandboxed) app, which keychain ACL is the most reliable way to keep the snapshot key from other same-user processes: a legacy file-keychain item ACL, or the data-protection keychain with an access group? This needs a probe (unverified).
- Hidden space: how large is the purgeable double-count on a Mac with local Time Machine snapshots? This Mac has none (`tmutil listlocalsnapshots /` is empty). Assigned to T-0009.
- License: if T-0003 picks GPL-3.0 for macontrol, the "study" rows for Neodisk-only code (duplicates, changes diff, cushion renderer, incremental splice) could become "take" with attribution. Under MIT or Apache, they stay reimplement-from-idea.
