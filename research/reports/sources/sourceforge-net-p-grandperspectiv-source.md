# Source deep dive: GrandPerspective (SourceForge `grandperspectiv/source`)

Task T-0023, researcher `dive-sourceforge-net-p-grandperspectiv-source`, 2026-09-23. Clone: `research/sources/sourceforge-net-p-grandperspectiv-source` at `3e0088c` (2026-09-14 22:33 +0200, "Bump project version to 28"). I deepened it by 60 commits to see the release cadence.
Paths below are relative to that clone unless marked otherwise. "Verified" means I ran it on this Mac (macOS 26.6 25G72, M1, built-in Retina display). Everything else comes from reading the code.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://git.code.sf.net/p/grandperspectiv/source (official). Project page https://sourceforge.net/p/grandperspectiv/, homepage http://grandperspectiv.sourceforge.net. Also sold on the Mac App Store (id1111570163). | `README.md:25-34`, `curl https://sourceforge.net/rest/p/grandperspectiv` |
| License | **GPL-2.0-or-later**. The LICENSE file is the GPLv2 text, and the Credits say "either version 2 of the License, or (at your option) any later version". No per-file headers. | `LICENSE:1-2`, `Credits.rtf` |
| Stars | n/a: SourceForge has no stars. 310,970 downloads in the 12 months 2025-09-23..2026-09-22 (231,581 macOS). The GitHub copies are stale, unofficial mirrors: `patmoore/grandperspective` (10 stars, last push 2011-05-19) and `bezigon/GrandPerspective` (8 stars, 2015-04-27). | SF stats JSON API, `gh api repos/...` |
| Created / last commit | SF project 2005-09-11. Last commit 2026-09-14. Version 3.8.1, build 28. Releases in 2026: 3.6.2 (Jan) through 3.8.1 (Sep). | SF REST, `git log`, `GrandPerspective.xcodeproj/project.pbxproj:1825,1921` |
| Maintainers | Effectively one person: 61 of the last 62 commits are by Erwin Bonsma ("eriban" on the tracker), and 1 is from "Cœur" (retain/release fixes). | `git shortlog -sn` |
| Language | Objective-C with **manual retain/release** (no ARC; `-fobjc-weak` via `CLANG_ENABLE_OBJC_WEAK`). AppKit plus XIBs. 30,789 lines of .m/.h. No Swift. Deployment target is "recommended" (14.0 since 3.8.0, per commit "Update to recommended deployment target (14.0)"). | `wc -l`, `project.pbxproj:1915` |
| Distribution | Sandboxed in every build configuration, including the SourceForge DMG: `app-sandbox`, `files.user-selected.read-write`, `downloads.read-only`, `assets.*.read-only`, hardened runtime. | `GrandPerspective.entitlements`, `project.pbxproj` (CODE_SIGN_ENTITLEMENTS on Development/Deployment/Default) |
| Issues | 6 open bugs and 18 open feature requests on the SF tracker (details under Known problems). | `sourceforge.net/rest/p/grandperspectiv/{bugs,feature-requests}/search?q=status:open` |

**What the license lets us do: study only.** macontrol is not GPL (see the T-0003 license task and the sibling reports), so no GrandPerspective code, XIB, help text or palette file may be copied. Algorithms and ideas are free to re-implement from our own description. Every "take" below is therefore an idea or behaviour, never code. The bench probes I wrote (`research/bench/sourceforge-net-p-grandperspectiv-source/*.m`) are our own code. They compile against the gitignored clone and ship nothing of GP.

## Summary

GrandPerspective (GP) is the long-running reference treemap for macOS. It scans one folder or volume, builds a size tree and draws it as a shaded ("cushion-like" gradient) treemap. Its core features:

- Scan any folder or whole volume, with three size measures: logical `st_size`, physical `st_blocks*512` (the default) and "tally" (file count). `tree/TreeBuilder.m:26-28,779-802`, `Info.plist:96-97`
- Drill down and zoom with animation, scroll-wheel zoom, keyboard navigation over the map, and a path that follows the mouse until clicked (click locks the selection). `view/DirectoryView.m:397-419,575-705,931+`
- Context menu: Open, Quick Look (Space), Reveal in Finder, Copy Path, Delete File/Folder (to Trash). `view/DirectoryView.m:720-765`, `control/DirectoryViewControl.m:329-472`
- Twelve colour mappings: top folder, folder, extension, name, level, nothing, uniform type, creation/modification/access time and size. 15 bundled palettes. `mapping/FileItemMappingCollection.m:139-160`, `Palettes/*.clr`
- **Filters as data**: a predicate tree of name, path, size, type, flags, And/Or/Not and "files only" tests. It is used as a scan filter (prunes while scanning) or a mask (hides while drawing), and can be edited in a Filters window. Defaults ship in `Info.plist:135-357`.
- Name search drawn as a highlight overlay. `control/DirectoryViewControl.m:490-505`, `view/DirectoryView.m:533-537`
- "Freed space" bookkeeping after deletes, and an optional whole-volume view with free space and "misc used space" tiles. `tree/TreeContext.m:277-328,482-513`, `view/TreeDrawerBase.m:126-145`
- FSEvents monitoring, plus a **Refresh** that rescans only folders marked dirty. `tree/TreeMonitor.m`, `tree/TreeRefresher.m`
- Save/load of scan results (gzip XML `.gpscan`), export as text, and save of the map as an image. `io/XmlTreeWriter.m`, `io/TreeReader.m`, `io/CompressedTextOutput.m:14-17`, `control/SaveImageDialogControl.m`
- Localized in 11 languages (`*.lproj`), with a help book. Unified logging since 3.8.0, including an opt-in "trusted" logger that prints real paths.

Maturity: 21 years old and actively maintained, with 8 releases in 2026. It is clearly careful code: asserts everywhere, and comments that explain every macOS quirk. It is a pure visualizer. It has **no cleanup rules, no uninstaller, no multi-select and no batch delete**. For macontrol it is the best reference for *tree model, layout and filter design*. It is a weak reference for *scan speed* (serial fts), *rendering* (CPU bitmap at 1x) and *deletion semantics* (single item, "freed" means "trashed").

## Architecture

Classic AppKit MVC. The engine and the UI share the model classes but live in separate folders:

| Folder | Role | Key files |
|---|---|---|
| `tree/` | Model and engine: nodes, scan, refresh, layout, FSEvents, tree context with a readers-writer lock | `TreeBuilder.m` (fts scan), `TreeRefresher.m`, `TreeMonitor.m`, `TreeBalancer.m`, `TreeLayoutBuilder.m`, `TreeContext.m`, `FileItem.h`, `DirectoryItem.m`, `CompoundItem.m` |
| `filter/`, `test/` | Filter model: `Filter`/`FilterSet`/repositories, plus the predicate classes (`test/` is **not** unit tests) | `test/FileItemTest.m:18-54` (whitelisted deserialization), `test/Item*Test.m`, `test/strings/*` |
| `mapping/` | Colour mapping schemes (hash per item into palette index) | `FileItemMappingCollection.m`, `TimeBasedMapping.m`, `MappingBySize.m`, `UniformTypeMappingScheme.m` |
| `view/` | Rendering and interaction | `DirectoryView.m` (NSView, zoom animation, events), `TreeDrawerBase.m`/`TreeDrawer.m` (layout traverser that paints), `GradientRectangleDrawer.m` (CPU rasterizer), `ItemLocator.m`/`ItemPathBuilder.m`/`ItemPathDrawer.m` (hit-test and selection outline) |
| `task/`, `util/AsynchronousTaskManager.m` | Background work: one NSThread per task manager, "latest input wins", abortable | `ScanTaskExecutor.m`, `DrawTaskExecutor.m`, `FilterTaskExecutor.m`, `ReadTaskExecutor.m`, `WriteTaskExecutor.m` |
| `control/` | Window and panel controllers (XIB-backed) | `MainMenuControl.m` (1,602 lines), `DirectoryViewControl.m`, `ControlPanelControl.m`, `PreferencesPanelControl.m`, `StartWindowControl.m` (FDA check) |
| `io/` | Scan dump XML reader/writer, gzip, text export | `TreeReader.m` (1,549 lines), `XmlTreeWriter.m`, `RawTreeWriter.m` |

Engine/UI separation: `TreeBuilder` knows nothing about views. It reports progress through `ScanProgressTracker`, and alerts are built as an `AlertMessage` value so the main thread creates the `NSAlert` (`TreeBuilder.h:92-97`). The tree is shared between the scan, draw and monitor threads under `TreeContext`'s own readers-writer lock (`TreeContext.m:341+`). Deletion takes the write lock (`:292-323`) and the FSEvents callback takes only a read lock (`TreeMonitor.m:117-128`). Background tasks run through `AsynchronousTaskManager`: a dedicated NSThread waits on an `NSConditionLock`, a new input replaces the pending one, and a running task is aborted through the executor (`util/AsynchronousTaskManager.m:39-120`). This is a simple and robust "coalesce to latest" pattern for redraws.

## Scanning

- **API:** BSD `fts_open(path, FTS_PHYSICAL | FTS_XDEV)` and `fts_read`, one `stat` per entry, **single-threaded** (`TreeBuilder.m:838-849`, loop `:341-373`). No `getattrlistbulk`, no parallelism. The only concurrency is tree balancing on a serial GCD queue behind the scan (`:686`, waited for at `:384`).
- **Tree construction:** an explicit reusable stack of `ScanStackFrame`s is unwound to each entry's `fts_parent` (`:628-671`). Directories are finalized bottom-up: size = sum of children (`DirectoryItem.m:113-115`), then the folder is passed to the balancer. Children are first collected as a linked list of `CompoundItem`s (`DirectoryItem.m:91-111`), then **re-shaped into a Huffman-style binary tree**: sort by size, repeatedly merge the two smallest (`TreeBalancer.m:39-122`). That binary tree *is* the treemap layout. It keeps files and subfolders in two separate subtrees per folder (`DirectoryItem.m:117-128`).
- **Sizes:** Physical = `st_blocks * 512` (`:779-780`) and is the app default (`Info.plist:96-97`). Logical = `st_size`, except that legacy `.icloud` placeholder files are read as a plist to get `NSURLFileSizeKey` (`:447-459`). With logical sizes the scanner also sums physical size and warns when logical > physical overall, or per file (`:412-440,786-795`). "Tally" counts 1 per file (`:800-801`). Folders' own blocks are not counted. **Not clone-aware**: grep finds no `clone`, `PRIVATESIZE`, `getattrlist` or `purgeable` anywhere (the same class of defect as F-0004).
- **Hard links:** a file with `st_nlink > 1` is kept only the first time its `st_ino` is seen (`:704-715,829-836`). Later links vanish from the map entirely, so they cannot be seen or deleted at their other path. On APFS, directory link counts are ignored because they count children (`:558-568,699-703`). Keying by inode alone is safe here: `FTS_XDEV` limits the walk to one device, and on this Mac `/`, `/Users` and `/System/Volumes/Data` all report st_dev 16777229, with System-volume inodes in a disjoint high range (`stat -f '%d %i'`, verified).
- **Firmlinks and volumes:** scanning `/` skips `/System/Volumes/Data` by exact path, so Data is not counted twice (`:751-757`; the comment admits there is no generic API). Compare F-0031 (Kudu), which gets this wrong. Other volumes are excluded by `FTS_XDEV`. Bug #130 (see below) suggests `FTS_XDEV` also truncates some SMB shares. The maintainer suspects it, but this is unverified.
- **Cloud:** folders with `SF_DATALESS` are not entered, so a scan never triggers downloads (`:743-750`). The default *mask* hides `CloudStorage` and `Mobile Documents` (`Info.plist:84-85,155-178`).
- **Packages:** `NSURL.isPackage` per folder costs "about 30% of total scanning time" by the author's own measurement (`:720-726`). The "adaptive" default checks only folders whose name has an extension (`:214-219`, `Info.plist:68-69`). The comment admits this misses `Photo Booth Library` and `SyncServices/Local`.
- **Progress:** estimated from the fraction of sub-folders done in the top 6 levels, found with `fts_children` (`:38,646-648,856-867`, `task/ScanProgressTracker.m:75-87`). Every sibling folder weighs the same regardless of size, so progress is uneven, but it never needs a pre-count.
- **Cancellation:** a plain `abort` BOOL checked before each `fts_read` (`:341`). `progressInfo` returns nil once aborted (`:314-319`).
- **Errors:** `FTS_DNR/ERR/NS` are counted and logged, with paths only on the opt-in trusted logger (`:349-356,293-302`). The user never sees which folders were unreadable. Bug #130's reporter had to use the Console with a privacy profile to find them.
- **Memory model:** one Objective-C object per file and per folder: an `NSString` label, a weak parent, `item_size_t`, 3 `CFAbsoluteTime`s, `UInt8` flags, and a `UTType` for files (`tree/FileItem.h:9-43`, `PlainFileItem.h`). Paths are rebuilt from the parent chain. Each folder with more than one child adds `CompoundItem` inner nodes, about one per child. Measured with GP's own classes (the mirror probe below, `-Os`, no UTType, zeroed times): **167.6 MB max RSS for 622,664 non-empty files of `~/projects`, about 270 B per file all-in**. That is well below Radix's 943 B/node (F-0041) and far above a compact struct-of-arrays. The wall time was 22.5 s (0.8 s user, 6.6 s sys, cold-ish: kern.maxvnodes is smaller than the tree). That is our probe's walk, not the GP app, so treat it as unverified for GP itself.
- **Incremental refresh:** `TreeMonitor` watches the scan root with directory-level FSEvents (`kFSEventStreamCreateFlagNone`, latency 3 s, `TreeMonitor.m:8,79-87`). It de-duplicates paths and walks the tree by label to set `DirectoryNeedsShallowRescan` or `...FullRescan` flags (`:130-183`). Dropped events are only logged (`:42-46`), but FSEvents also sets `MustScanSubDirs` in that case. **Refresh** rebuilds a new tree: clean folders are copied from the old tree, shallow-dirty folders are re-listed, and full-dirty folders are rescanned (`TreeRefresher.m:82-217`). Hard-link inaccuracies are detected by comparing sets of hard-linked labels and shown as a warning instead of being silently wrong (`:64-76,109-113,179-183,219-271`). Compare F-0037 (OpenDisk silently re-counts).

## Deletion & rules

- **No cleanup rules exist.** GP has no junk, cache or leftover definitions, no uninstaller and no dry run. The only data-driven rule system is the **filter** language:
  - Defaults live in `Info.plist:135-357`: `GPDefaultFilterTests` (Audio, Cloud folders, Hard-linked items, Huge/Large/Medium/Small/Tiny files, Images, Packages, Version control) and `GPDefaultFilters` (No cloud files, No hard-links, No version control).
  - User filters are stored in user defaults through `dictionaryForObject`.
  - Deserialization is a closed whitelist of class names, not `NSClassFromString` (`test/FileItemTest.m:18-54`, `test/strings/StringTest.m:11-29`), so a crafted plist cannot instantiate arbitrary classes.
  - Filters are applied either while scanning (pruning) or as a mask while drawing (`tree/FilteredTreeGuide.m`, `view/TreeDrawerBase.m:147-151`). Re-filtering an existing tree runs `tree/TreeFilter.m` on a background task without touching the disk.
- **Delete:** a single selected item only, and the path must be "locked" by a click (`control/DirectoryViewControl.m:661-681`).
  - `NSFileManager trashItemAtURL:` by the stored path (`:688-699`). There is no permanent delete, no admin escalation and no helper.
  - The default preference is **"delete nothing"**, so delete is off until the user enables it (`Info.plist:94-95`). Files and folders are gated separately (`:899-919`).
  - Confirmation dialogs are on by default (`Info.plist:70-73`). They name the item and warn that hidden (filtered) contents of a folder are deleted too, and that hard-linked items keep using space (`:421-460`). The dialog shows **no size and no item count**.
  - The scan root on a volume root cannot be deleted (`:673-676`). The window must be key, so there is no click-through delete (`:678-680`).
  - There is no identity check between the scan and the delete. It trashes whatever sits at that path now (compare the recheck F-0012 asks for). The Trash makes this recoverable.
- **Freed-space accounting:** the deleted node is replaced by a same-size `FreedSpace` tile drawn in the free-space black, and `_freedSpace` grows by the scanned size (`tree/TreeContext.m:281-288,482-513`, `view/TreeDrawer.m:114-120`). Keeping the map stable is a good idea. Calling trashed bytes "freed" is not: **F-0042**, where a trash is verified to free 0 bytes.
- **Permissions:** `appHasDeletePermission` is hard-coded `YES` with "TODO: Re-enable once this works again" (`control/PreferencesPanelControl.m:82-85`). The real check (`:303-351`) is dead code. The FDA check lists `~/Library/Safari`, rewriting a sandbox-container home to the real home (`control/StartWindowControl.m:17,395-418`). Bug #123 reports a permanent false "no FDA" with an earlier probe path. This is the opposite failure to F-0001 (false "granted"). Evidence only, no new finding.
- **Reveal in Finder** works around `selectFile:inFileViewerRootedAtPath:` failing inside packages by rooting at the outermost package (`control/DirectoryViewControl.m:356-379`). A custom reveal app can be configured (`:347-353`). Worth copying as behaviour.

## UI

- **Rendering:** a CPU software rasterizer. `TreeLayoutBuilder` recursively splits each binary node's rect along its longer side by the size ratio (`tree/TreeLayoutBuilder.m:29-82`). This is a slice layout over the Huffman-balanced tree, which gives reasonable aspect ratios with no squarify pass. The traverser (`view/TreeDrawerBase.m:97-197`) paints each file with a 256-step "pyramid" gradient per palette colour, filling the pixels of an `NSBitmapImageRep` directly (`view/GradientRectangleDrawer.m:141-193,200-266`). This runs on a background thread, abortable, and the image is then blitted in `drawRect:` (`view/DirectoryView.m:496-550`).
  - **The bitmap is sized in points**, so on Retina the map is half resolution, and tiles under 1 pt are never drawn: **F-0043**. Measured on ~/projects: 22.4% of files get a tile at 1x, 52.0% at 2x.
  - Colours are packed DeviceRGB, with no colour management.
  - Layout is not cached. Every draw, hit-test (`view/ItemLocator.m:30`) and selection outline (`view/ItemPathDrawer.m:43`) re-runs the layout, pruned to the relevant rects.
- **Interaction:**
  - Mouse-over selects, and a click locks the selection (`view/DirectoryView.m:641-705`). Arrow keys move the selection when locked (`:590-606`). Space opens Quick Look (`:580-588`).
  - Scroll-wheel zoom with a sensitivity threshold (`:611-639`). Animated zoom in/out between cached images (`:931+`). "Display focus" limits the drawn depth, "selection focus" controls how deep a click selects, and "Show entire volume" draws free and used space around the scan.
  - The resize path scales the old image until the redraw is ready (`:501-515`).
  - `isOpaque` returns NO as a workaround for zoom artefacts (bug #94, `:553-560`).
- **Info:** a floating control panel with Info, Display and Focus tabs (`control/ControlPanelControl.m`), a colour legend, and a UTType ranking window that decides which type wins for colouring.
- **Look:** dated but consistent AppKit with XIBs and a toolbar. 3.7.0 added a Liquid-Glass-compatible icon and toolbar margins for Tahoe. There is no SwiftUI, no sidebar or list view next to the map, and no breadcrumb other than the path in the status bar.
- **Performance on big trees:** drawing cost is O(visible tiles) plus O(pixels), and it is abortable and coalesced. Deep recursion in layout and refresh on 512 KiB NSThread stacks crashes at around 3,300 nested folders (**F-0044**, verified with GP's classes).

## Tests & quality

- **No unit tests or test target.** There is one application target (`project.pbxproj:1177`), and `test/` holds filter predicates. There is no CI configuration in the repo, and no XCTest anywhere.
- Heavy use of `NSAssert` for invariants (for example `DirectoryItem.m:83,92,126`, `TreeBalancer.m:47-48`), clear comments that explain platform quirks, and small focused classes.
- The cost of MRC shows in the history: "Fix crash on unretained colorScheme" (2026-01-19), "Fix memory leak" (2026-04-26), and a merged `coeur/retain-release` branch.
- Logging moved to `os_log` in 3.8.0, with a separate opt-in "trusted" logger that prints real paths (`TreeBuilder.m:642-644`). Paths still show as `<private>` for some users on macOS 14.8 (bug #130 thread).
- The bus factor is 1.

## Known problems

Open bugs (https://sourceforge.net/p/grandperspectiv/bugs/, fetched 2026-09-23):
- **#130** "Scan of 1.52 TB server volume stops after 147 GB" (SMB). The log shows "Error reading directory …: No such file or directory" for folders that scan fine on their own. The maintainer suspects `FTS_XDEV` on the Samba mount. Unresolved. Lesson for macontrol: network volumes need their own walker checks and a visible "N folders unreadable" list.
- **#125** crash "Thread stack size exceeded due to excessive recursion" (3.6.4, macOS 26.3.1). Not symbolized, root cause unknown. F-0044 shows one mechanism that produces exactly this signature.
- **#123** Full Disk Access check always reports missing on macOS 26.2 (sandbox denies the probe path), and the app is not pre-listed in System Settings.
- #129 the control panel moves off-screen when resized. #118 the app does not show in the Applications folder. #131 asks for a pie chart and update checks.

Open feature requests show the gaps users feel: #111/#33 command-line or unattended scans, #110 pause a scan, #114 queue permission requests, #93 a date-based filter test, #98 mark files and rescan without them, #26 "super user mode" (scan as root), #76 account for /Volumes by default, #44 map of all drives.

From the code: no clone-aware sizes (F-0004 class); hard-link duplicates invisible at their second path; "freed" counts trashed bytes (F-0042); 1x rendering (F-0043); deep-recursion crash (F-0044); no size in the delete confirmation; single-item delete only; delete permission check disabled (`PreferencesPanelControl.m:82-85`).

## Reuse table

GPL-2.0-or-later, so every decision is about the idea, never the code.

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Huffman-balanced binary layout (merge the two smallest, split the longer side) | study | `tree/TreeBalancer.m:39-122`, `tree/TreeLayoutBuilder.m:29-82` | Cheap O(n log n) per folder, stable, decent aspect ratios, and the layout falls out of the model with no separate pass. Benchmark it against squarified layout in macontrol's own implementation. |
| Separate "files" and "subfolders" subtrees per folder | study | `tree/DirectoryItem.m:81-128` | Enables "group files" drawing (`TreeDrawerBase.m:98-103,168-171`) and fast folder-only views. |
| Filter predicate tree as data (And/Or/Not, name/path/size/type/flags, files-only) with a whitelisted decoder | study | `test/*.m`, `test/FileItemTest.m:18-54`, `Info.plist:135-357` | A good model for macontrol's filter and rule DSL and its safe deserialization. Add date tests (FR #93). |
| Scan filter vs mask filter distinction | study | `tree/FilteredTreeGuide.m`, `view/TreeDrawerBase.m:147-151`, `tree/TreeFilter.m` | Re-filter in memory without a rescan. The mask default hides cloud folders. |
| FSEvents dirty flags plus partial Refresh, with a hard-link mismatch warning | improve | `tree/TreeMonitor.m`, `tree/TreeRefresher.m` | The right shape. macontrol should add event-id persistence (F-0017), in-place splicing without a whole-tree copy, and correct hard-link handling (F-0037) instead of a warning. |
| Latest-input-wins background task manager | study | `util/AsynchronousTaskManager.m` | Correct coalescing for redraws. In Swift this becomes a single-slot actor with an explicit thread `stackSize` (F-0044). |
| Edge-case handling: `SF_DATALESS` skip, `/System/Volumes/Data` skip, APFS dir nlink ignore, physical/logical warning | study | `tree/TreeBuilder.m:558-568,699-757,412-440` | A checklist of macOS traps to cover in macontrol's scanner tests. The skip-by-path should become a generic firmlink rule. |
| Package detection shortcut (extension first) | rewrite | `tree/TreeBuilder.m:214-219,719-733` | Right trade-off, but it misses packages without an extension. macontrol can combine the extension→UTType cache with the FinderInfo bundle bit from `getattrlistbulk` (unverified cost, hand to T-0004). |
| Scanner (serial fts + stat) | rewrite | `tree/TreeBuilder.m:330-387,838-849` | Serial and latency-bound (F-0009 class), not clone-aware (F-0004), unreadable folders hidden from the user. |
| Renderer (CPU bitmap, 1x, DeviceRGB) | rewrite | `view/GradientRectangleDrawer.m`, `view/DirectoryView.m:496-550` | F-0043. GPU and native scale. Keep the pyramid-shading *look* as one theme option. |
| "Freed space" tile that keeps the map stable after a delete | improve | `tree/TreeContext.m:277-328` | Keep the in-place tile idea, but as an "In Trash" state (F-0042). |
| Delete flow (single item, trash, off by default, confirm) | rewrite | `control/DirectoryViewControl.m:403-472,661-715,899-919` | Safe defaults worth matching (off until enabled, trash, key-window only, no root). But macontrol needs multi-select, sizes in the confirmation, an identity recheck and a journal (F-0012). |
| Reveal-inside-package workaround, custom reveal/open app | study | `control/DirectoryViewControl.m:344-400,925-944` | Small, real UX details. |
| Progress estimate by folder fractions | study | `task/ScanProgressTracker.m:75-87` | No pre-count needed. macontrol can do better with bytes seen / volume used bytes on volume scans. |
| Scan dump (gzip XML) and text export | ignore | `io/*` | Useful feature, but GP's format is specific to GP. macontrol will pick its own snapshot format (possibly with a GP import later). |
| Palettes (`.clr`), help book, XIBs | ignore | `Palettes/`, `*.lproj/` | GPL assets. Build our own. |

## Open questions

1. What are the real scan throughput and memory of the GP *app* on the T-0004 fixture? My numbers come from GP's classes in a probe, not the app, and the app is GUI-only (FR #111). A hand-driven run with `/usr/bin/time`-style sampling of the app process would settle it. Handed to T-0004 as a hypothesis.
2. Is rendering at 1x deliberate (4x fewer pixels for the CPU rasterizer)? No comment in the code says so. Unverified.
3. Is the #125 crash the deep-recursion mechanism of F-0044, or something else (for example recursion in `TreeFilter`, the XML writer or dealloc chains)? It needs the reporter's Binary Images.
4. Does `FTS_XDEV` cut SMB shares (#130)? If so, macontrol's scanner needs a per-mount-type policy. This needs an SMB test mount, which I could not test here.
5. Does GP's shallow-rescan path ever drop hard links or double count them in practice? It warns rather than fixes (`TreeRefresher.m:64-76`). Not measured.
