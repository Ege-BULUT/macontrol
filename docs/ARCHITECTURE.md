# macontrol architecture (v1)

Decisions, with the evidence each rests on. Reports live in `research/reports/`; `F-xxxx` are defects
found in other tools (analysis board, `.board`), which macontrol must not repeat. "Contract" means a
public signature in `Sources/`: builders may add to it freely, but a change that breaks another module
needs a comment on that module's board task first.

## 1. Platform and distribution

| Decision | Why |
|---|---|
| **macOS 14+** | Observation, `SectorMark`, `inspector`, `ContentUnavailableView`, `onChange(of:initial:)` are 14.0; ~96% of Macs; Radix ships 14 (topic-distribution-permissions M1-M2, D4). 15-only APIs (`Mutex`, `TaskExecutor`) are not needed: use `OSAllocatedUnfairLock`/`NSLock` and our own threads. |
| **Liquid Glass for free, explicit only on floating surfaces** | Standard controls adopt it when built with the 26 SDK (topic-distribution-permissions M4). `floatingSurface()` in `Shell/Theme.swift` uses `glassEffect` behind `#available(macOS 26, *)`, `.regularMaterial` before. |
| **Developer ID, notarized, hardened runtime, not sandboxed** | App Store 2.4.5 bans what the product does (sandbox, root, own updater); PureMac, Radix, Pearcleaner ship this way (topic-platform-constraints F1-F2, topic-distribution-permissions D1-D4). Sparkle 2 arrives in M8. |
| **SwiftPM package, no Xcode project** | `swift build` / `swift test`; `scripts/bundle-app.sh` wraps the executable into `build/Macontrol.app` (Info.plist, resource bundle in `Contents/Resources`, codesign). Zero third-party dependencies in v1. |
| **No privileged helper in v1** | A helper is an `SMAppService.daemon` with a typed XPC API and `setCodeSigningRequirement` (topic-platform-constraints E1-E4, F-0002). v1 marks root-owned items "Needs admin" and offers Reveal in Finder. Revisit after v1 (user decision). |

## 2. Modules

One SwiftPM target per module, so builders own disjoint folders and the dependency direction is
compiler-checked. `Package.swift` declares every target; only the architect edits it.

| Target | Owns | Depends on | Board task |
|---|---|---|---|
| `MacontrolCore` | `FileIdentity`, `ScanTree`/`NodeFlags`, `ItemMeasurement`/`ReclaimEstimate`, `UInt64.formattedBytes`, `Permissions/FullDiskAccess` | - | T-0043 owns `ScanTree.swift`, `ItemMeasurement.swift`; T-0047 owns `Permissions/`; the rest is frozen |
| `ScanEngine` | every size: `ScanEngine.scan/measure/reclaimable`, `VolumeSummary` | Core | T-0043 scan-engine |
| `Safety` | every file mutation: `TrashService`, `ProtectedPaths`, undo journal | Core | T-0044 safety-trash |
| `Cleaner` | `CleanupCatalog` (JSON resource), `Cleaner.scan()`, `CleanupItem` | Core, ScanEngine, Safety | T-0045 cleaner-catalog |
| `Uninstaller` | `Uninstaller.installedApps/plan/uninstall`, `InstalledApp`, `Leftover` | Core, ScanEngine, Safety | T-0046 uninstaller |
| `MacontrolUI` | SwiftUI: `Shell/ Overview/ Onboarding/ History/ Snapshot/` (app-shell), `DiskMap/` (disk-map), `Clean/ Uninstall/` (clean-uninstall-ui) | all above | T-0047, T-0048, T-0049 |
| `Macontrol` | executable: `App`, `--snapshot <dir>` mode | UI | T-0047 app-shell |
| `mcscan` | CLI printing the scan total, for `research/bench/run.sh` | ScanEngine | T-0043 |
| `TestSupport` | `TemporaryDirectory` fixture builder (frozen; add helpers in your own test target) | - | architect |

Feature models keep their scaffold initializers (`DiskMapModel(engine:trash:)`, `CleanModel(cleaner:trash:)`,
`UninstallModel(uninstaller:)`, `HistoryModel(trash:)`) and a static `demo()`; new parameters get defaults,
so `AppModel.live()`/`demo()` never needs a cross-team edit.

**Concurrency.** Swift 6 language mode everywhere. UI targets use `defaultIsolation(MainActor)`; core
targets do not, because with that default a `nonisolated async` scan runs on the main thread
(topic-distribution-permissions S1-S3). Blocking file I/O never runs on the cooperative pool (it has
exactly `ncpu` threads, S4): the engine owns its threads. Results cross to the UI as `Sendable` values
(`ScanTree` is a struct of arrays). Verify isolation claims with a real build, never `-typecheck` (S5).

## 3. Scan engine (M2)

**API (contract, `Sources/ScanEngine/ScanEngine.swift`).** `scan(_ root) -> AsyncThrowingStream<ScanEvent>`:
progress at most ~10 Hz, then one `.completed(ScanTree)`; ending the stream cancels the walk.
`measure(_ url) -> ItemMeasurement` sizes one item without keeping a tree (cleaner, uninstaller).
`reclaimable(_ urls) -> ReclaimEstimate` answers "what does trashing these free". `VolumeSummary.of(url)`.

**Walk.** Only this design was both fast and exact in the benchmark (bench-scan-engines "What macontrol should take"):
- fd-relative: `openat(parentFD, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` + `getattrlistbulk` into a
  per-worker heap buffer. Full-path walkers lose subtrees past PATH_MAX (F-0008); a stack buffer caps depth (F-0044, dumac).
  Parent fds are reference-counted and closed when their last child folder is open.
- A fixed pool of blocking worker threads with a LIFO work stack and a pending counter; the total comes
  only from the finished tree, never from a shared counter at a barrier (F-0007). Workers =
  `activeProcessorCount` capped at 8, halved in Low Power Mode or serious thermal state (Radix policy).
  Serial walkers are 8-12x slower even warm (F-0009): `kern.maxvnodes` is 120k on an 8 GB Mac.
- Attributes per entry: NAME, DEVID, OBJTYPE, FLAGS, FILEID, MODTIME, FILE_LINKCOUNT, FILE_TOTALSIZE,
  FILE_ALLOCSIZE, DIR_MOUNTSTATUS. The APFS extended attributes cost +61-70% kernel CPU, so they are **not**
  in the first pass; `reclaimable` fetches them for the selection only (bench-scan-engines "Baseline").
- Errors are data: EACCES/EPERM mark a folder `.unreadable`, other failures `.incomplete`; EMFILE waits and
  retries. Nothing is ever silently 0 (F-0057, F-0060). The UI shows these as "not scanned".
- Cancellation is checked between folders.

**Node storage.** `ScanTree`: parallel arrays indexed by node number, children as first-child/next-sibling
`Int32` links, no stored paths or URLs (paths are rebuilt from parents). Radix's path-per-node model costs
943 B/node (F-0041); target here is under 80 B/node plus name bytes, measured on the 300k fixture.
Children always have larger indices than parents, so `finalizeTotals()` is one reverse pass.

**Hard links, clones, firmlinks, dataless.**
- Hard links (nlink > 1) are counted once per `(dev, ino)`. The link with the lexicographically smallest
  path keeps the bytes, so per-folder sizes are identical across runs (F-0054, F-0010, F-0047); the other links
  are `.sharedHardLink` at 0 B. Deleting one subtracts only its charged bytes (F-0063).
- APFS clones count at full allocated size in the map in v1, as in Finder and du. "Frees now" is exact
  anyway (below). Spike in M2: if `ATTR_CMNEXT_CLONEID` alone is cheap, dedup fully shared clones (3.1 GB of
  ~/projects, bench-scan-engines).
- Volumes: never cross a mount point (`DIR_MNTSTATUS_MNTPOINT` or devid change → `.mountPoint` leaf).
  "Macintosh HD" means walking `/System/Volumes/Data` once and showing user-facing paths via
  `/usr/share/firmlinks`; walking `/` double-counts (F-0031) and misses Data-root folders like
  `macOS Install Data` (F-0005, topic-size-accounting 5).
- `SF_DATALESS` files are `.dataless`, 0 B local, and never materialized
  (`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, …, OFF)`, topic-size-accounting 34; F-0019).
- `.package` bundles are sized in full and shown as one item (F-0028). `SF_RESTRICTED` → `.systemProtected`.

**Not in v1:** FSEvents incremental rescans and an on-disk scan cache. Both are where competitors break
(F-0017, F-0037, F-0038) or leak (F-0045: a 0644 cache of every scanned name). After an in-app delete the
tree is spliced in memory (`removeSubtree`), never rescanned (F-0052, F-0013).

## 4. Size model

| Number | Source | Used for |
|---|---|---|
| On disk (`allocated`) | ALLOCSIZE, hard links once | map areas, lists, folder totals |
| Size (`logical`) | TOTALSIZE | inspector only |
| Frees now (`ReclaimEstimate.freesNow`) | Σ PRIVATESIZE; ALLOCSIZE for `UF_COMPRESSED` (PRIVATESIZE is 0 there); a hard-linked inode only if all its links are in the selection; a full clone group once if all its members are | every "Clean"/"Move to Trash" confirmation |
| Shared elsewhere | the rest | shown next to "frees now", never promised |

This is the F-0004 fix: every surveyed cleaner promises allocated size, but deleting a clone frees ~0
(topic-size-accounting "Experiment"). Decimal units (`ByteCountFormatter .file`), like Finder. Purgeable
space is shown as a dated "macOS can free about N" note, never added to free space, with no purge
action (topic-size-accounting 6, 25-28). Trashed bytes are "In Trash", not "freed" (F-0042).

## 5. Deletion model (M7)

- **One door.** Only `Sources/Safety` may move, delete or shell out. `SafetyTests/SinkAuditTests` fails the
  build's tests when any other source file calls `removeItem`, `trashItem`, `unlink`, `rename`, AppleScript
  or a shell; `Process` is allowed only in `Uninstaller/Launchd*.swift` for `launchctl bootout` with an
  argument array (Mole's sink audit, tw93-mole reuse table).
- **Move to Trash only** via in-process `FileManager.trashItem(at:resultingItemURL:)`: it writes Finder's
  Put Back record, returns the real destination for undo, and uses per-volume trashes
  (topic-platform-constraints D1-D5). Never `NSWorkspace.recycle`, Finder AppleScript (F-0018) or `rm`
  (F-0012, F-0025). **No permanent delete in v1**; emptying the Trash is the user's Finder action.
- **Per item, in order:** re-`lstat` and compare the scan's `FileIdentity` (refuse on mismatch); canonicalize
  with `F_GETPATH` so `/System/Volumes/Data/Users/me` is recognised as home (F-0039); apply the protected-path
  policy; expand `keep` so unchecked descendants survive (F-0026); drop items inside other selected items
  (F-0050); trash; append a journal line.
- **Protected-path policy is containment, not exact match** (F-0024): refuse the item if it equals or
  contains a protected root (`/`, `/System`, `/Users`, `~`, `~/Library` and its standard subfolders,
  `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, `/Applications`,
  `/Library`, volume and firmlink roots), or if it lies inside a never-touch area (Keychains, `~/.ssh`,
  `~/.gnupg`, Mail, Messages, photo libraries, TCC, `/private/var/vm`, `/.Spotlight-V100`, `/.fseventsd`,
  `/.DocumentRevisions-V100`, `/System`, `/usr` except `/usr/local`). `SF_RESTRICTED` or a read-only
  volume → `.systemProtected`. The user's Locked flag → `.locked`; flags and ownership are never changed to
  force a delete (F-0024, F-0070). iCloud Drive and `~/Library/CloudStorage` need an explicit extra
  confirmation (Radix `ScanTarget`). Root-owned and not writable → `.needsAdministrator`.
- **Undo journal:** JSON Lines at `~/Library/Application Support/Macontrol/trash-journal.jsonl`, mode 0600,
  one line per trashed item (batch, original path, trashed path, identity, size). Undo moves the item back
  with our own move, only if the original path is free. Items keep their visible names in the Trash, so a
  crash mid-batch leaves nothing hidden or orphaned (F-0036, F-0064, F-0053).
- **Tests never trash for real:** the Trash backend is injectable and tests move into their own
  `TemporaryDirectory`.

## 6. Cleanup catalog (M5)

- `Sources/Cleaner/Resources/catalog.json`, compiled into the signed app and never loaded from a
  user-writable place (F-0021). Rule: `id`, `title`, `category`, `safety`, `paths`, `minimumAgeDays`, `note`.
- **Safety levels** (F-0027): `safe` = regenerable, preselected; `review` = shown unselected with the note;
  `manual` = size and Reveal in Finder only, never in a bulk clean (device backups, Xcode Archives,
  `macOS Install Data`).
- **Rule validation, fail closed, at load and in a test** (F-0032): patterns start with `~/` or an allowlisted
  absolute root, no `..`, `*` only in the last component, at least three levels below home
  (`~/Library/Caches/*`, never `~/Library/*`), never inside user-content roots or iCloud (F-0066, PureMac #142).
- **In-use guard** (F-0015): an item is skipped with a reason when a running app's bundle id or name matches it,
  or anything inside changed in the last 10 minutes (`ItemMeasurement.newestModification`), not only for
  reverse-DNS names. Globs expand in-process (F-0025). No per-item timeout that makes large caches
  uncleanable (F-0065).
- Rule data may be adapted from permissively licensed catalogs (PureMac MIT, mac-cleanup-sh MIT, Kudu MIT,
  Mac Sai BSD-3, kondo MIT) with a THIRD_PARTY_NOTICES entry; Mole and MangoDisk (GPL) are a checklist only.

## 7. Uninstaller (M6)

- **Inventory:** `/Applications` (one level of subfolders), `~/Applications`, `/System/Applications`.
  Kind: `builtIn` (sealed/read-only volume, `SF_RESTRICTED`, `/System`), `appleAppStore` (`_MASReceipt` and
  Apple signing), `thirdParty`.
- **Leftovers are evidence-scored** (Pearcleaner/PureMac match by substring and preselect everything: F-0011, F-0022):
  - Preselected: an item named with the bundle id in the known Library roots (Caches, Application Support,
    Preferences incl. ByHost, Containers, Saved Application State, HTTPStorages, WebKit, Logs, Application
    Scripts); containers whose `MCMMetadataIdentifier` names the app; group containers from the app's
    entitlements; user LaunchAgents whose program lives in the bundle.
  - Shown, not preselected: folders named exactly like the app (case-insensitive equality, never substring).
  - Never searched: Documents, Desktop, Downloads, Music, Pictures, Movies, iCloud, `/Users/Shared` (F-0066).
  - Vendor folders: only the app's own subfolder is a candidate (F-0022). An item another installed app also
    uses carries a note and is not preselected. `/Library` items are `needsAdministrator` in v1.
    pkg receipts are reported ("installed by a package"), not removed.
  - Bundle id + exact name covers ~88% of what cask curators list (homebrew-homebrew-cask matcher oracle).
- **Order** (Homebrew `ORDERED_DIRECTIVES`): quit with `NSRunningApplication.terminate` (no pattern kill);
  `launchctl bootout` each user agent being removed, by its exact label (F-0023, F-0067); then one
  `TrashService` batch with the bundle and the chosen leftovers, so one Undo restores it all. What the
  preview lists is exactly what is trashed (F-0069); any failed step stops the uninstall (F-0030).
- **"Remove system apps", honestly:** apps in `/System/Applications` and Safari live on the sealed system
  volume and cannot be removed without disabling SIP and the seal (impossible with FileVault on, undone by
  the next update); they are listed as "Part of macOS" with their size. Apple's App Store apps (GarageBand,
  iMovie, Pages, Numbers, Keynote) are removable and free to download again; their content libraries
  (`/Library/Application Support/GarageBand`, `/Library/Audio/Apple Loops`, Logic) are separate
  admin-only items (topic-platform-constraints A1-A10, summary 1).

## 8. UI (M3, M4)

- **Structure:** `NavigationSplitView` sidebar: **Overview** (volume capacity, purgeable note, largest folders,
  "N GB safe to clean", permission banner) · **Disk Map** · **Clean** · **Uninstall** · **History** (journal,
  Undo per batch). Scan scope (Home, Macintosh HD, a chosen folder) in the toolbar. ⌘1-⌘5 switch sections.
- **Disk Map:** sunburst and treemap over the same tree, SwiftUI `Canvas` at native scale (F-0043), layout
  computed off the main actor and cancellable. Area and angle are **proportional to bytes** (F-0020).
  Children too small to draw merge into a labelled "N smaller items" element that opens in the side list;
  nothing is dropped and rows always add up (F-0016, F-0040). Side list + inspector explain every flag
  ("not scanned: needs Full Disk Access", "in iCloud", "linked elsewhere"). Staging tray ("Discard pile")
  → review sheet with the "frees now" figure → Move to Trash → in-place splice.
- **Keyboard first:** arrows move the selection, Return drills in, Esc/⌘↑ goes up, ⌘[ ⌘] back/forward,
  Space Quick Look, ⌘R Reveal in Finder, ⌘⌫ stage, ⌘F search. Everything reachable without a mouse;
  VoiceOver labels on chart elements; Reduce Motion respected.
- **Visual direction:** native controls and SF Symbols, Liquid Glass on macOS 26 through standard components,
  one accent color, calm type hierarchy, sizes in monospaced digits. Map palette: hue per top-level branch,
  lightness by depth, checked for colour-blind separation with
  `research/bench/windirstat-windirstat/palette_probe.py` (every pair ≥ dE00 10 under deutan/protan; F-0049).

## 9. Permissions onboarding

One permission: Full Disk Access (topic-platform-constraints summary 2). The probe opens the per-user
TCC.db, then `~/Library/Safari`: granted / denied (EPERM) / unknown. The system TCC.db is readable without
FDA and is never used (F-0001). Onboarding: deep link
`x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`, draggable app
icon plus Reveal in Finder (registration is not guaranteed, P8), poll every second while visible and on
app activation, continue automatically, and offer Relaunch if still denied (P5 is unverified).
Without FDA the app works, and protected folders show as "not scanned", never as smaller totals.

## 10. Testing

- Swift Testing, `swift test` must stay green on `main`. Fixtures are built per test in a
  `TemporaryDirectory` (hard links, clones, symlinks, deep chains, chmod-000 folders); tests never read or
  change real user data and never trash outside their temp folder.
- Engine acceptance: the bench fixture (`research/bench/fixtures/tree`, env-gated) must total
  **2,368,040,960 B** (`visible_to_non_root.allocated_all`) with identical per-folder sizes over 20 runs;
  the size-accounting fixture's expectations hold for `reclaimable`; `mcscan` goes into `research/bench/run.sh`.
- Sink audit (above). Each new safety check lands with a deliberate-bug proof in the task comment.
- UI: `Macontrol --snapshot <dir>` renders every screen with demo data, light and dark, to PNG. It reads the
  app's own off-screen window from the window server (no Screen Recording permission, verified by launching
  the bundle with `open`); `ImageRenderer` and `cacheDisplay` both drop AppKit-backed or scrolled content.
  UI tasks attach their PNGs to the board. `MacontrolUITests/SnapshotTests` renders every screen.

## 11. Reuse policy

- **Study only (never copy code, data or assets):** GPL sources (Mole, MangoDisk, GrandPerspective, WinDirStat,
  QDirStat, Neodisk, Lemon, KnockKnock, MacTools at HEAD), Pearcleaner (Apache-2.0 + Commons Clause) and
  PureMac's Pearcleaner-derived files (`Logic/Scanning/{AppPathFinder,Conditions,Locations,StringNormalization}.swift`),
  and sources without a license (dumac).
- **May be adapted with attribution:** MIT, BSD, Apache-2.0 sources: Radix, OpenDisk (and inket/FullDiskAccess),
  dua-cli, gdu, PureMac (other files), Mac Sai, kondo, Kudu, mac-cleanup-sh/-py, Homebrew brew and cask data
  (BSD-2), munki, MacTools DiskClean at `9197035` (last Apache revision), varg-dev hilbert-moore treemap.
  Every adaptation adds an entry to `THIRD_PARTY_NOTICES.md` (project, commit, files, license text) in the
  same commit.
- Lineage per source is recorded on board task T-0003.

## 12. Out of v1

Privileged helper and root deletes; permanent delete / in-app Empty Trash; FSEvents incremental rescans and
scan caches; duplicate finder; project-artifact discovery (node_modules etc.) unless M5 finishes early;
cask zap dataset shipped in the app (used as a test oracle only); Sparkle updates (M8); App Store edition.
