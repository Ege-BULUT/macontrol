# Source deep dive: Radix (colinvkim/Radix)

Task T-0021, researcher `dive-colinvkim-radix`, 2026-09-23. Journal M-0016, findings F-0040 and F-0041, follow-up task T-0026. Clone: `research/sources/colinvkim-radix` at `14a76df` (2026-09-19, "docs: refresh app screenshots").
All paths are relative to that clone unless marked otherwise. "Verified" means I ran it on this Mac. Everything else comes from reading the code.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/colinvkim/Radix (homepage https://tryradix.app) | `gh api repos/colinvkim/Radix` |
| License | MIT, "Copyright (c) 2026 Colin Kim" | `LICENSE:1-3`; API `license.spdx_id=MIT` |
| Stars / forks | 861 / 24. Not a fork, not archived. | `gh api`, 2026-09-23 |
| Created / last push | 2026-04-02 / 2026-09-20. 926 commits. Latest release v1.8.0 (2026-09-20). Releases v1.5.0 to v1.8.0 shipped between July and September. | `gh api .../releases`, commits `Link` header |
| People | colinvkim wrote 920 of the commits (99 of the last 100). 4 outside contributors have 1-3 commits each. Many files have the header "Created by Codex", and `AGENTS.md` is the agent contract. | `gh api .../contributors`, `Models/TrashSafetyPolicy.swift:5` |
| Language / size | Swift 6.2, SwiftUI plus AppKit where needed. 48.3 k lines of app and core code and 42.9 k lines of tests. macOS 14+, built with Xcode 26. | `find ... | xargs wc -l`, `README.md` |
| Dependencies | `RadixCore` (the SwiftPM target) has none. The app uses Sparkle only, with an EdDSA key and an appcast. | `Package.swift`, `Radix/Info.plist` (`SUFeedURL`, `SUPublicEDKey`) |
| Distribution | Not sandboxed. Hardened runtime in Release. Available as a Homebrew cask (`brew install --cask radix`). | `Radix.xcodeproj/project.pbxproj:379-380`, `README.md` |
| Issues | 1 open: #38, "smart cleanup recommendations". That is exactly the half of macontrol that Radix lacks. 25 closed issues, covering crashes on macOS 27 beta (#55, #58), FDA false negatives (#10, #11), a large "unattributed" area (#24), slow deletes (#15), clone memory (#53) and a discard-pile hang (#36). | `gh api .../issues` |
| Lineage | Radix is the original. `tkslucas/Neodisk` (GPL-3.0, 580 stars) credits "Radix by Colin Kim (MIT), the scan…" in its README Credits section and copies the `AtomicDirectory*` and `ScanIncrementalModels` files. `bysiber/cleardisk` vendors Radix (see M-0001, sweep-ui). | `gh api repos/tkslucas/Neodisk/readme` lines 80-97 |

**What the license lets us do:** copy, modify and ship the code, provided the MIT notice (copyright line plus permission text) stays in our source or in our about/acknowledgements. This is the most reusable disk-map codebase in the survey. Take code from Radix itself, never from Neodisk: Neodisk's own changes are GPL-3.0.

## Summary

Radix is a native, read-mostly disk-space analyzer. It scans a folder or volume, then shows the result as a sunburst or a treemap, with a sortable, searchable file browser and an inspector alongside. It can compare two scans, save or load `.radixscan` snapshots (LZFSE), and stage deletions in a **Discard Pile** before moving them to the Trash. It does **no cleanup intelligence at all**: there are no cache rules, no leftover detection and no uninstaller. Issue #38 is a request for exactly that.

What makes it valuable to us is the engineering under the UI:
- A `getattrlistbulk` scanner with descriptor-relative traversal, hardware- and thermal-aware worker limits, and a Foundation fallback.
- Correct APFS accounting: hard links counted once, full clones deduplicated through `ATTR_CMNEXT_CLONEID`/`CLONE_REFCNT`, and partial clones flagged honestly.
- Firmlink-aware volume boundaries.
- Incremental rescans driven by an FSEvents history replay, falling back to a full scan in 26 enumerated cases.
- 963 Swift Testing tests plus 33 benchmarks that are gated behind environment variables.

Weak spots for us:
- The auto-summary heuristic samples 100 entries and can fold a multi-GB file, or a subfolder of any size, into an opaque "Summarized" node (verified by probe, finding F-0040).
- The per-node memory model is heavy: 943 B per node, measured (F-0041).
- The trash guard is an exact-path blocklist (same class as F-0024).
- There is no undo after Move to Trash, whole-volume rescans are always full, and nothing persists across launches.

## Architecture

- **Two build products.** The `RadixCore` SwiftPM target lists every non-UI file explicitly (`Package.swift` sources list). It is compiled with `.defaultIsolation(MainActor.self)`, `InferIsolatedConformances` and `NonisolatedNonsendingByDefault`. The Xcode project adds `App/`, `Features/` and `Shared/` (SwiftUI views). The engine, models and view models are therefore testable without the UI.
- **Layers** (routing table in `AGENTS.md:9-40`):
  - `Services/`: scanning, archive, comparison, geometry, formatting. Mostly `nonisolated` structs and enums.
  - `Models/`: `FileNodeRecord`, `FileTreeStore`, `ScanSnapshot`, `ScanTarget`, `TrashSafetyPolicy`.
  - `ViewModels/`: `AppModel` is a 3 267-line `@MainActor` coordinator, plus focused controllers: `TrashFlowController`, `WorkspaceNavigationModel`, `SidebarScanCacheController`, `ComparisonFlowController`, `ArchiveWorkflowCoordinator`.
  - `Features/*`: SwiftUI.
- **Side effects are injected.** `AppSystemActions` is a struct of closures, with `.live` and `.inert` variants (`Services/AppSystemActions.swift:18-158`), so tests can swap out trash, reveal, the FDA probe and panels.
- **Size hotspots:** `ScanEngine.swift` 3 191 lines, `FileTreeStore.swift` 2 899, `AppModel.swift` 3 267, `ScanCoordinator.swift` 992, `AtomicDirectorySummaryPool.swift` 1 014. Dense, very defensive, heavily commented agent-written code: correct-looking, but a lot to port.

## Scanning

- **Entry point and cancellation.** `ScanEngine.scan(target:options:)` returns an `AsyncThrowingStream<ScanProgressEvent, Error>`. The stream's `onTermination` cancels the scan task (`ScanEngine.swift:896-927`). The scan path is `nonisolated` on purpose, so a scan that is still cancelling cannot block a new one (comment at `ScanEngine.swift:1057-1063`, regression test named there). Cancellation checks run every 256 items throughout.
- **Traversal.** Iterative work items with `parentKey`, `depth` and a progress `weight`. A directory's weight is split among its children, which gives a real progress fraction rather than a spinner (`ScanEngine.swift:265-305`, `2436-2475`). Progress is throttled to every 64 items and at least 150 ms apart (`ScanEngine.swift:3122-3144`).
- **Syscalls.** `BulkDirectoryEnumerator` calls `getattrlistbulk` on an `open(O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)` descriptor (`BulkDirectoryEnumerator.swift:11-17, 216, 361`). It requests: name, devid, objtype, modtime, flags, useraccess, fileid, Finder info (package bit), linkcount, totalsize, allocsize, dataallocsize, and `ATTR_CMNEXT_REALDEVID|CLONEID|CLONE_REFCNT|EXT_FLAGS` (`:447-488`).
  - On `EINVAL/ENOTSUP/ENOSYS`, or when required attributes are missing, it falls back to the Foundation enumerator (`:307`, `:490-502`).
  - Children are opened relative to the parent descriptor through a pooled lease (`ScanDirectoryDescriptorPool.swift`, `NativeName` at `:26-72`).
  - Directory identity is re-verified when a directory is opened, to detect replacement during the scan (`ScanEngine.swift:2946-2957`).
- **Concurrency.** There are three worker pools. Traversal and classification each get 2-8 workers (active cores/2). Atomic summaries get 4-8. All pools are halved in Low Power Mode and at serious/critical thermal state, and reduced at `.fair` (`ScanEngine.swift:780-894`). Each pool can be overridden with an env var such as `RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS`. This is a good default for a Mac that is already busy (this one was).
- **Size semantics** (`FileNodeRecord.swift:10-30`):
  - Each node records `allocatedSize` (after dedup), `unduplicatedAllocatedSize`, `dataAllocatedSize` (the data fork only, used for clone groups) and `logicalSize`.
  - The map uses allocated bytes. The maintainer confirms this in issue #9: Finder shows logical size, which explains the "wrong numbers" report.
- **Hard links and clones** (`SharedAllocationDeduplicator.swift:11-35`, `SharedAllocationOwnerAccumulator.swift:10-20, 149-194`):
  - A file with `linkCount > 1` claims its (dev, ino). A file with `cloneID > 0 && CLONE_REFCNT > 1` claims `(REALDEVID, CLONEID)` (`BulkDirectoryEnumerator.swift:717-733`).
  - The lexicographically smallest path wins and keeps the bytes. Every other claimant has its `allocatedSize` (or, for clones, its `dataAllocatedSize`) subtracted. Ancestors are then rebuilt.
  - Hard links are resolved first, then clone groups, so resource forks are not lost.
  - Partial clones (`EF_MAY_SHARE_BLOCKS`) are flagged "May share APFS storage" and **not** deduplicated. The UI copy says so plainly (`FileNodeRecord.swift:225-249`). This is the reference implementation of the "on disk" half of F-0004.
- **Volume boundaries.** Foreign mounts (DMGs, network shares, other disks) become leaf nodes. Volumes of the scan root's own APFS container stay traversable, so a scan of `/` reaches the Data volume through firmlinks (`ScanEngine.swift:170-263`). The firmlink list is read from `/usr/share/firmlinks`, with a hard-coded fallback (`TrashSafetyPolicy.swift:51-76`).
  - On APFS, container capacity is kept out of the tree: there is no synthetic "unattributed = capacity − sum" node (`ScanEngine.swift:3153-3176`).
  - Issue #24 ("major chunk unattributed", fixed in 1.5.1) shows what goes wrong when this is done badly.
- **iCloud dataless files.** Entries with `SF_DATALESS` are skipped in the bulk path and never materialized, so nothing triggers a download (`BulkDirectoryEnumerator.swift:571-574`, `ScanMetadataLoader.swift:619-622`). The consequence is that evicted files are invisible in the browser. Contrast F-0019, where Lemon pays for 1-2 iCloud URL lookups per entry.
- **Auto-summary ("atomic directories").** A directory at depth ≥ 2 with ≥ 5 000 files whose average logical size is ≤ 4 KiB becomes one node with a size and a file count (`ScanEngine.swift:767-778`). It can be expanded on demand ("Expand Fully", `Features/FileList/FileBrowserTableView.swift:388-392`). node_modules-style layouts are also probed from depth 1.
  - This is Radix's main memory-control lever. Its decision is sampled, see **F-0040**.
- **Memory model.**
  - The final `FileTreeStore` is an arena: `[FileNodeRecord]`, `parentRawIndices: [UInt32]`, `childSpans`, `childIndices`, plus `indexByNodeID: [String: FileTreeNodeIndex]` (`FileTreeStore.swift:23-31`, built at `ScanEngine.swift:2255-2289`).
  - Each record carries `id = url.path`, a Foundation `URL` and a `name` (`ScanEngine.swift:2958-2984`). Measured cost: 943 B per node, of which the URL alone is 579 B, see **F-0041**.
  - Issue #53 (fixed) records a related retention bug: 73.8 MiB peak for 50 000 clones in 3 visible nodes.
- **Incremental rescan.** At scan start, `FileSystemEventHistory` records `FSEventsGetCurrentEventId()` (`FileSystemEventHistory.swift:12-40`). On Rescan it replays `(since, through]` through `FSEventStreamCreateRelativeToDevice` with `FileEvents|WatchRoot|NoDefer|FullHistory` (`:44-110`). `IncrementalRescanPlanner` then turns the events into directory relists or subtree rescans spliced into the old store (`IncrementalRescanPlanner.swift:18-165`).
  - It falls back to a full scan on any of 26 reasons (`ScanIncrementalModels.swift:84-118`): dropped events, id wrap, clone or hard-link topology changes, an auto-summarized boundary, or more work than half the tree.
  - Whole-volume targets always do a full scan (`IncrementalScanService.swift:617-632`).
  - No state survives an app relaunch (maintainer, issue #25).
- **Archives.** `.radixscan` format v5 streams node and topology sections through a bounded LZFSE encoder, with a topology validator on import. It reads v3 and v4 as well (`ScanArchiveSectionStream.swift:65-120`, `ScanArchiveTopologyValidator.swift`, README Architecture). Imported scans are read-only, and live actions on them re-verify file identity (`FileActionValidation.swift:4-27`).

## Deletion & rules

- **Cleanup rules: none.** There are no cache, leftover or app-uninstall rule files anywhere in the tree (grep for "cache", "leftover", "uninstall" in `Services/` returns only scan-cache code). Radix is a visualizer with a Trash button.
- **The action is Trash only.** `SystemIntegration.moveToTrash` does three things (`Services/SystemIntegration.swift:435-466`):
  1. `validateCanMoveToTrash` runs the protected-root policy.
  2. `verifyTrashIdentity` compares the scanned (dev, ino), or the `fileResourceIdentifier` for non-POSIX volumes, with a fresh `lstat` (`:469-490`).
  3. `FileManager.trashItem` moves the item.

  The comment admits the remaining path-based TOCTOU window. There is no `rm`, no root helper and no privilege escalation. The `resultingItemURL` is thrown away (`:448-449`), so there is **no in-app undo or Put Back**.
- **Guard.** `TrashSafetyPolicy.blockReason` is an **exact-match** set (`Models/TrashSafetyPolicy.swift:32-49, 84-112, 130-134`). It contains:
  - 16 static roots;
  - `$HOME` and its `/System/Volumes/Data` twin;
  - every mounted volume root;
  - every firmlink root.

  Children of those roots are not refused: `~/Library`, `~/Documents`, `~/.ssh` and `~/Library/Keychains` all pass. This is the same defect class as **F-0024** (Pearcleaner), so the evidence went there as a comment and was not filed again. Two ideas worth taking: adding mounted volumes, and parsing `/usr/share/firmlinks`. Unlike OpenDisk (F-0039), Radix also blocks the Data-volume twin of `$HOME` and of every firmlink (`/System/Volumes/Data/Users/<me>`, `TrashSafetyPolicy.swift:94-109`). That covers only the exact roots, though, not their children.
- **Staging (the Discard Pile).** It is a set of node IDs bound to one snapshot ID (`ViewModels/TrashFlowController.swift:63-67, 146-159`).
  - `topLevelNodeIDs` removes descendants of selected ancestors (`:161-168`).
  - Moving to the Trash asks for confirmation (`pendingTrashSelection`), then moves items one at a time. It stops at the first identity mismatch or error and reports what it did move (`:244-277`). Moved nodes are hidden optimistically and restored if the move fails (`:188-240`).
  - The pile is in memory only.
- **Cloud warning.** Adding to the pile or trashing anything under `~/Library/CloudStorage` or `~/Library/Mobile Documents` (or a folder that contains them) shows an extra confirmation, because the delete propagates to the cloud (`Models/ScanTarget.swift:167-221`, `ViewModels/AppModel.swift:2322-2347`). iCloud "Desktop & Documents" sync is not detected (unverified whether it should be; see Open questions).
- **Stats.** "Bytes moved to Trash" sums the deduplicated `allocatedSize` of the moved nodes (`Services/AppUsageStatsStore.swift:97-123`). The Discard Pile shows "N items • size" from the same sum (`ViewModels/AppModel.swift:43-60`, `Features/DiscardPile/DiscardPileReviewSheet.swift:195-196`).
  - A hard-link or clone "winner" carries the shared bytes even when its siblings stay outside the selection, so the pile total can overstate what is freed. This is the F-0004 class; the evidence is on T-0009.
- **Dry run.** Not applicable: nothing is deleted without the confirmation sheet.

## UI

- **Rendering.** SwiftUI `Canvas`. There is a base canvas for the fills and separate label and overlay canvases, and the views are `Equatable` so SwiftUI skips redraws (`Features/Visualization/SunburstChartCanvases.swift:3-17`, `TreemapChartCanvases.swift:3-34`). Layout is computed off the main thread by `ChartLayoutRequestCoordinator` and can be cancelled. When layout fails the app shows a banner (`ChartLayoutFailureBanner.swift`) rather than hanging. Issue #36 was an earlier hang of exactly this kind.
- **Sunburst** (`Services/SunburstGeometry.swift`):
  - Center radius 0.22. Ring width is `(0.98 − 0.22) / depthLimit`.
  - Children under 2° (`π/90`) merge into one "Smaller Items" wedge (`:195-260`).
  - Depth comes from settings, 3-10 rings, default 6 (`Features/Settings/SettingsView.swift:82-84`, `ViewModels/AppModel.swift:147`).
- **Treemap** (`Services/TreemapGeometry.swift`):
  - Squarified layout (`:259-340`). Nested containers get an 18 pt header and a 2 pt inset, and are only drawn when at least 52×46 pt.
  - The minimum tile area is 120 pt².
  - Hit-testing uses a 32×24 bucket grid (`:593-680`).
  - Tile area is proportional to bytes. Compare F-0020, where Lemon uses log bytes.
- **Interaction.**
  - Hover shows an inspector and a tooltip (`TreemapTooltipPlacement.swift`). Double-click drills down. There is a breadcrumb bar and back/forward navigation.
  - Zoom and pan are supported (`ChartViewportTransform/Motion/ScrollInput`), along with keyboard navigation (`ChartKeyboardInteractionView.swift`), rectangle multi-select (`ChartSpatialSelection.swift`), and Quick Look (`AppQuickLookController.swift`).
  - The file-action menu has Reveal in Finder, Copy Path, Open in Terminal and Move to Trash (`AppSystemActions.swift:20-27`).
  - Items in the Discard Pile get an overlay on the map (`DiscardPileVisualizationOverlay.swift`).
  - There is an optional free-space wedge.
  - The app is localized into 7 languages, and there is a guided workspace tour that uses a practice directory.
- **Onboarding and permissions.** The FDA probe depends on the OS version. macOS ≤ 26 reads the user TCC.db plus 2 of the Mail/Messages/Safari/HomeKit folders. macOS 27 reads `/Library/Preferences/com.apple.TimeMachine.plist` and `~/Library/Containers/com.apple.stocks`, with the system TCC.db as a third fallback (`Services/SystemIntegration.swift:573-713`).
  - Unlike PureMac (F-0001), a readable system TCC.db alone is never enough for "granted" on macOS ≤ 26.
  - On 27, when a primary probe file is missing, the fallback needs 2 readable files out of 3 (`requiredReadableMacOS27SentinelCount = 2`, `SystemIntegration.swift:51`). If the system TCC.db can be read without FDA (F-0001), one of those 2 must still be an FDA-only file. So there is no F-0001-style false "granted" from reading code (not run).
  - Issues #10 and #11 were false "not granted" reports, since fixed.
- **Performance.** There is no measured UI number from this dive. Radix ships benchmarks for sunburst, treemap, file-browser and chart responsiveness (`RadixCoreTests/*ResponsivenessBenchmarkTests.swift`), which T-0004 can reuse.

## Tests & quality

- 963 `@Test` cases (Swift Testing, no XCTest) across 63 files, including 33 benchmarks tagged `.benchmark` and gated behind env vars such as `RADIX_BENCH`, `RADIX_BENCH_FULL_SCAN_SCALING` and `RADIX_BENCH_RETENTION` (`RadixCoreTests/ScanBenchmarkTests.swift:64-695`, `PerformanceAuditBenchmarkTests.swift`). Memory is sampled through `task_info` (`BenchmarkSupport.swift:112-121`, `PerformanceAuditBenchmarkTests.swift:665-673`).
- CI runs `swift test` and `xcodebuild test` on `macos-26` with Xcode 26.6 for every PR and push, and uploads the xcresult (`.github/workflows/tests.yml`).
- Quality is high but heavy. Invariants are enforced with `precondition` in the store builders (`FileTreeStore.swift:80-133`), identities are re-verified at action time, and most decisions carry a comment explaining why.
- The gap I found: the auto-summary tests only cover "all files large" (`ScanEngineTests.swift:4822-4851`) and never "many tiny files plus one huge file", which is the F-0040 case.
- Not run here: `swift test` builds about 91 k lines. It was skipped because the machine is loaded. Both probes below compile only 1-2 source files.

## Known problems

1. **Sampled auto-summary hides large items.** Verified with a verbatim copy of `immediateChildrenSuggestAtomicDirectory` (`research/bench/colinvkim-radix/autosummary_sample_probe.swift`). With 6 000 × 1 KiB files and one 2 GiB file, the true average is 350 KB (87× the 4 KiB threshold), yet the folder is summarized in 5 901 of 6 001 listing positions. A subfolder of any size never vetoes the decision, because directory entries are skipped by the sample. **F-0040.**
2. **Per-node memory.** Verified with an unmodified copy of `FileNodeRecord.swift` (`research/bench/colinvkim-radix/node_memory_probe_main.swift`), macOS 26 / Swift 6.3.3, 1 M nodes, 91 B average path:
   - Radix's record plus the path index: 943 B per node (900 MiB).
   - `URL(fileURLWithPath:)` alone: 579 B per node.
   - A name + parent-index record: 120 B per node.
   - Stable across 2 runs. **F-0041.**
3. **Exact-match trash guard.** Same class as F-0024 (commented on T-0014).
4. **No undo after Trash, and the Discard Pile is in memory only.** A feature gap, recorded on the task board as T-0026, not as a finding.
5. **Whole-volume rescans are always full, and no scan state persists across launches.** By design, per issue #25 and `IncrementalScanService.swift:629-632`.
6. **Pile and stats totals can overstate freed bytes for hard-link or clone winners.** F-0004 class, evidence on T-0009.
7. **History:** crashes when resizing the window during a scan on macOS 27 (#55, #58, fixed in 1.8.0), and the "Loading Disk Map" hang (#36, fixed). Maturity is still settling on new OS releases.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Bulk directory enumerator | take | `Radix/Services/BulkDirectoryEnumerator.swift`, `ScanDirectoryDescriptorPool.swift`, `ScanMetadataLoader.swift` (`isDataless`, `FileIdentity`, `CloneIdentity`) | MIT. The `getattrlistbulk` attribute set, the fallback rules, `O_NOFOLLOW` opens relative to the parent descriptor, and the dataless skip are exactly what macontrol needs. Keep the notice. |
| Worker-limit policy | take | `ScanEngine.swift:780-894` (`ScanConcurrencyPolicy`) | Small, and aware of thermal state and Low Power Mode. Hand it to T-0004 to tune. |
| Hard-link and clone dedup | take | `SharedAllocationDeduplicator.swift`, `SharedAllocationOwnerAccumulator.swift` | A correct two-stage dedup ("on disk" semantics). Extend it with the "frees now" math from F-0004. |
| Volume boundary and firmlinks | take | `ScanEngine.swift:170-263`, `TrashSafetyPolicy.swift:51-76, 136-165` (firmlink parser) | Handles `/` → Data volume and foreign mounts correctly. |
| Incremental rescan | improve | `FileSystemEventHistory.swift`, `IncrementalRescanPlanner.swift`, `IncrementalScanService.swift` | A conservative FSEvents replay. Extend it to volume targets and persist the checkpoint and tree across launches. |
| Tree store | rewrite | `Models/FileTreeStore.swift`, `Models/FileNodeRecord.swift` | Keep the arena idea (parent, child spans, u32 indices). Drop the per-node `URL`, full-path id and path-keyed index (F-0041). |
| Auto-summary | improve | `AtomicDirectory*.swift`, `ScanEngine.swift:767-778` | Keep the pooled summarizer. Decide on full data and keep the top-K large files and subfolders materialized (F-0040). |
| Sunburst and treemap geometry | take | `SunburstGeometry.swift`, `TreemapGeometry.swift` (+ hit-test index), `DiskMapColorBranchContext.swift` | Pure functions, tested, true byte-proportional area, can be cancelled. |
| Chart views and interaction | take | `Features/Visualization/*`, `ChartViewport*`, `ChartSpatialSelection.swift` | SwiftUI `Canvas`, layered and `Equatable`, with zoom, keyboard and rectangle select. A good baseline, adapted to our design. |
| Trash flow | improve | `SystemIntegration.swift:435-490`, `TrashFlowController.swift`, `FileActionValidation.swift` | Keep the identity re-check and the top-level reduction. Add an undo journal with `resultingItemURL`, and replace the guard with F-0024's prefix policy. |
| Cloud-storage warning | take | `Models/ScanTarget.swift:167-221` | Cheap and correct for CloudStorage and Mobile Documents. Also check iCloud Desktop & Documents sync. |
| Discard Pile UX | improve | `Features/DiscardPile/*`, `DiscardPileVisualizationOverlay.swift` | Good staging pattern for our cleaner too. Persist it and show "frees now" rather than allocated size. |
| `.radixscan` archive and comparison | study | `ScanArchive*.swift`, `ScanComparison*.swift` | Useful later (history, "what grew"). Not MVP. |
| FDA probe | study | `SystemIntegration.swift:573-713` | Better than PureMac's, but OS-version specific. Compare with T-0011's design before copying. |
| AppModel coordinator | ignore | `ViewModels/AppModel.swift` | A 3 267-line god object. Take the smaller controllers instead. |
| Benchmarks | study | `RadixCoreTests/*Benchmark*.swift`, `BenchmarkSupport.swift` | Env-gated harness patterns for T-0004. |

## Open questions

- What is the real node count, and the memory, of a Radix scan of `/` on a typical Mac after auto-summarization? F-0041 measures the per-node cost only. The total depends on how many nodes survive summarization (unverified; the `RADIX_BENCH_FULL_SCAN_SCALING` benchmark would answer it, not run).
- On macOS 14/15, where `URL` is CFURL-backed, does the per-node URL cost differ from the 579 B measured on macOS 26? (Unverified.)
- Should trashing `~/Desktop` or `~/Documents` content with iCloud "Desktop & Documents" enabled also show the cloud warning? `CloudStorageLocation` only knows `~/Library/CloudStorage` and `~/Library/Mobile Documents` (unverified how those folders appear on disk when sync is on).
- Does `FileManager.trashItem` record Finder "Put Back" information? Radix drops `resultingItemURL`, so even an in-app undo would have to rebuild it (unverified).
