# Source deep dive: QDirStat (`shundhammer/qdirstat`)

Task T-0027, researcher `dive-shundhammer-qdirstat`, 2026-09-23. Clone: `research/sources/shundhammer-qdirstat` at `88a577f` (2026-09-20 13:49 +0200, "Merge duplicate msgids"), shallow.
Paths below are relative to that clone unless marked otherwise. There is no Qt on this Mac, so I did **not** build or run QDirStat. "Verified" means one of two things. Either I ran a behavioural model of the source's function on this Mac (`research/bench/shundhammer-qdirstat/expand_probe.py`), or I inspected the shipped macOS binary (`QDirStat.dmg` 2.0-macos.2 from `jesusha123/qdirstat-macos`, mounted read-only, `strings` only). Everything else comes from reading the code.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/shundhammer/qdirstat | |
| License | **GPL-2.0-only**. The LICENSE file is the GPLv2 text. The packaging metadata says `GPL-2.0-only`. File headers say "GPL V2 - See file LICENSE". | `LICENSE`, `package/flatpak/metainfo/io.github.shundhammer.qdirstat.metainfo.xml:11`, `package/opensuse/qdirstat-stable/qdirstat.spec:23`, `gh api repos/shundhammer/qdirstat` (spdx GPL-2.0) |
| Stars / forks | 2,593 stars, 162 forks, 50 watchers (2026-09-23) | `gh api repos/shundhammer/qdirstat` |
| Created / last commit | Repo created 2015-11-28, last push 2026-09-20. Latest release `2.0` on 2026-01-18 (Qt 6 port). | same, plus `/releases/latest` |
| Maintainer | Stefan Hundhammer, the original KDirStat author (2002). Very active in 2026: issues #297-#319 were all answered and closed. | README.md:1-11, issue list |
| Open issues | **0 open.** The maintainer closes everything, so the open-issue themes come from the 159 most recent issues (all states). | `gh api repos/.../issues?state=all` |
| Language / size | C++ with **Qt 6 Widgets** (qmake). 52,473 lines in `src/*.cpp,*.h`, 241 files in `src/`. No Swift/ObjC. | `qdirstat.pro:19-22`, `wc -l` |
| macOS | Upstream calls macOS a "target platform" but has only 5 `Q_OS_MAC*` spots. Binaries are built by a third party, `jesusha123/qdirstat-macos` (131 stars, GPL-2.0, release `2.0-macos.2` of 2026-08-23). Its CI compiles upstream at pinned commit `cb014eb` with **no source patches**: it only appends to `src.pro` (TARGET, Info.plist, entitlements). Signed with Team ID XKURB6WHH2, not sandboxed. | README.md:1025-1043, `jesusha123/qdirstat-macos/.github/workflows/build.yml` (QDIRSTAT_REF, "Patch Project File" step), `codesign -dv` on the mounted DMG |

**What the license lets us do: study only.** GPL-2.0-only cannot be combined with a non-GPL app. It is not even compatible with GPL-3.0 or Apache-2.0. No code, UI file, icon, help text or default rule table may be copied. The two algorithms worth having are published papers: the squarified treemap (Bruls, Huizing, van Wijk 2000) and the cushion treemap (van Wijk and van de Wetering 1999). We can re-implement both from the papers. Every "take" below is an idea or a behaviour, never code. The probe in `research/bench/shundhammer-qdirstat/` is our own model of the behaviour, written from the cited lines. It is not a copy.

## Summary

QDirStat is the Qt successor of KDirStat. It scans one directory tree into memory and shows it as a **sortable tree list plus a squarified cushion treemap** below it, with a details panel on the right. Features:

- A tree view with size, percent bar, item/file/subdir counts, latest mtime, oldest file, and (optionally) user/group/permissions. The columns are configurable. Sorting is lazy and cached per directory. (`DirTreeModel.cpp`, `DirInfo.cpp:985-1063`, `HeaderTweaker.cpp`)
- A treemap: squarified or simple slice-and-dice, cushion shading, colours by MIME category, zoom in/out by double-click, middle-click, wheel or menu, and a parent highlight on middle-click. (`TreemapTile.cpp`, `TreemapView.cpp:222-300`)
- **Configurable cleanup actions**: shell command templates with `%p` (path), `%n` (name), `%d` (dir), `%terminal` and `%filemanager`. Each action has flags for dir/file/pseudo-dir, recursive, confirm, a refresh policy (None, This, Parent, AssumeDeleted), an output-window policy and a shell. Nine are shipped by default (`StdCleanup.cpp:18-38`), and the user can edit them all in a settings page.
- "Move to Trash" as a separate built-in action (`MainWindow.cpp:1139-1183`, `Trash.cpp`).
- Statistics windows: file type stats (per suffix and per MIME category, with "locate files of this type"), a file size histogram with percentiles and buckets, and **file age stats** (per year, then per month for the current and previous year). (`FileTypeStats*.cpp`, `FileSizeStats*.cpp`, `HistogramView.cpp`, `FileAgeStats.cpp`, `doc/File-Age-Stats.md`, `doc/stats/*.md`)
- Data-driven **MIME categories**: suffix and wildcard patterns, each with a colour, stored in `QDirStat-mime.conf`. Default categories include "Junk" (`*~`, `*.bak`, `core`). (`MimeCategorizer.cpp:336+`)
- Exclude rules: wildcard, regexp or fixed string, matched on the name or the full path, plus "directory contains a file matching X". (`ExcludeRules.cpp:25-120,216-226`)
- Cache files: a gzip text dump of the tree (`[qdirstat 2.0 cache file]`). They are written from the UI or by the Perl script `scripts/qdirstat-cache-writer`, so a headless server can be scanned and the result viewed on a desktop. A `.qdirstat.cache.gz` found during a scan is used in place of reading that subtree. (`DirTreeCache.cpp`, `doc/cache-file-format.txt`, `DirReadJob.cpp:292-307,469-530`)
- Linux-only package views: which files belong to which dpkg/rpm/pacman package, and "unpackaged" files outside every package. (`PkgReader.cpp`, `MainWindowUnpkg.cpp`, `doc/Pkg-View.md`, `doc/Unpkg-View.md`)
- Breadcrumbs, back/forward history, bookmarks, "Find files", an "unreadable dirs" window and a mounted-filesystems window.

Maturity: a 23-year code lineage with one careful maintainer and a thorough design doc for each feature. It is a power-user tool first. The maintainer rejects safety changes to the delete flow on principle (issues #267, #293 and #316, quoted under Known problems). For macontrol it is the best reference for the **list+treemap layout, the statistics views, and data-driven categories/rules**. It is a poor reference for **scan speed** (single-threaded, on the GUI thread), **deletion safety** (shell `rm -rf` on the raw selection) and **macOS integration** (XDG trash, Linux mount logic).

## Architecture

- **One process, no threads.** A grep for `QThread|QtConcurrent|std::thread|pthread` in `src/` returns nothing. Scanning, the model, the treemap layout and cushion rendering all run on the Qt GUI thread. Scanning is time-sliced through a `QTimer(0)`, as described in the next section.
- **Engine and model:**
  - `DirTree` owns the tree and the job queue.
  - `FileInfo` (a leaf), `DirInfo` (a directory), `DotEntry` (a pseudo-dir that holds a directory's files when it also has subdirs) and `Attic` (a pseudo-dir for ignored items).
  - `DirReadJob` / `LocalDirReadJob` / `CacheReadJob` and `DirReadJobQueue`.
  - `MountPoints`, `ExcludeRules`, `MimeCategorizer`, `DirTreeCache`, the `*Stats` classes.
- **UI:**
  - `DirTreeModel` is a `QAbstractItemModel` over the tree.
  - `SelectionModel` is shared by the tree view and the treemap. `SelectionModelProxy` and `SignalBlocker` prevent ping-pong.
  - `DirTreeView` is a `QTreeView`, `TreemapView` a `QGraphicsView`, and `TreemapTile` a `QGraphicsRectItem` with one per tile.
  - `MainWindow*.cpp` holds actions, menus, layouts and the Unpkg view.
  - `.ui` files come from Designer.
- **Cleanups:** `Cleanup` is a `QAction` subclass. `CleanupCollection` owns the list, builds menus and toolbars, confirms and executes. `OutputWindow` runs the QProcess queue one process at a time. `Refresher` re-reads the affected subtrees after a cleanup.
- **Settings:** plain QSettings INI files per area (`QDirStat.conf`, `-cleanup.conf`, `-mime.conf`, `-exclude.conf`). `Settings.h:28,138,169,200`
- **The UI/engine split is weak but real.** The tree classes have no widget dependencies, and the views observe `DirTree` signals (`childAdded`, `deletingChild`, `finished`). Because everything shares one thread, a slow directory stalls the UI.

## Scanning

- **APIs.** `access(R_OK|X_OK)` pre-check, `opendir` on the full path, and `readdir` of every entry into a `QMultiMap<ino_t, QString>`. Then one `fstatat(dirfd, name, AT_SYMLINK_NOFOLLOW [|AT_NO_AUTOMOUNT])` per entry, **in inode order** ("minimizes seek times on rotational disks"). `DirReadJob.cpp:225,234,255-264,268-280`. Symlinks are never followed. There is no `getattrlistbulk`, no `fts`, no parallelism.
- **Concurrency and scheduling.** Each directory is a job. Subdirectories are appended to a FIFO, so the traversal is **breadth-first**. `DirReadJobQueue::enqueue` starts a `QTimer` with 0 ms (`:758`), and each timer tick runs `_queue.first()->read()` (`:854-860`). One tick handles **a whole directory**: readdir, sort, and every fstatat. A directory with a million entries therefore blocks the GUI thread for the whole read. The maintainer explains the BFS queue in issue #219 (pending read jobs reached about 200k there).
- **Progress and cancel.** There is no global estimate. The UI shows per-directory pending read-job counts and elapsed time. The model sends `layoutChanged` every 333 ms (3 s in "slow update" mode) (`DirTreeModel.cpp:43-55,139-143`). `abortReading` clears the queue and marks unread dirs aborted (`DirReadJob.cpp:784-802`). The directory being read at that moment always finishes first.
- **Sizes.**
  - `_size = st_size` and `_allocatedSize = st_blocks * 512`. If blocks is 0 and the filesystem cannot report blocks, size is used. `FileInfo.cpp:109-134`
  - A **sparse** file is one where `allocated + 2048 < size`. For sparse files `size()` returns the allocated size. `:130-134,250`
  - **Hard links:** QDirStat does not deduplicate by inode. It **divides** both size and allocated size by `st_nlink` for regular files (`FileInfo.cpp:252-253,263-264`). That is exact when all links are inside the scanned tree. It undercounts when some links are outside, and the "size" of one link says nothing about what deleting it frees. There is a global "ignore hard links" switch (`FileInfo.cpp:617`). NTFS link counts are forced to 1 (`DirReadJob.cpp:309-326`). The history of this area includes issues #124, #227, #253 and #260.
  - The treemap and the percent column use **allocated** size (`TreemapTile.cpp:130,197-211`). Issue #270 added an "apparent size" option and issue #306 asked for data size in the treemap.
  - **Clones: not handled** (APFS clone ids are never read). Same class as F-0004.
- **Filesystem boundaries.** `crossingFilesystems` compares `st_dev` and then the device names from `/proc/mounts` or `QStorageInfo` (`DirReadJob.cpp:107-160`, `MountPoints.cpp:301,426`). The user can choose to cross mount points, except system, duplicate/bind and network mounts (`:167-186`). **macOS firmlinks:** since PR #307 (2026-05-13) the code skips the literal path `/System/Volumes/Data` under `Q_OS_MACOS` (`DirReadJob.cpp:399-414`). It is a hardcoded string, the same approach GrandPerspective uses. It is correct for a scan of `/`, but it knows nothing about other volumes in the group (VM, Preboot). See F-0031 for why `st_dev` cannot tell the System volume from the Data volume.
- **Long paths.** Each directory is opened by its full path. When a path goes over PATH_MAX (1024 on macOS), `access()` fails first, and the directory is marked `DirPermissionDenied`, which is the wrong label (`DirReadJob.cpp:225-230`). It is listed in the unreadable-dirs window, not dropped silently. This is code-read only, not run. Same class as F-0008, but QDirStat surfaces the error.
- **Memory model** (good reference).
  - Each node stores only its **name**, as a `QString` (UTF-16), plus a parent pointer, a `_next` sibling pointer, and a `_firstChild` pointer for dirs (`FileInfo.h:959-979`, `DirInfo.cpp:529-531`). There is no per-node child array.
  - Full paths are built on demand by walking up the parents (`FileInfo.cpp:283-299`).
  - The maintainer gives `sizeof(FileInfo)` = 128 B, plus the name at 2 B/char and some overhead (issue #219). That is theirs and unverified here. `DirInfo` adds about 20 counters and 2 cached sorted lists (`DirInfo.h:602-631`).
  - Totals are updated incrementally in `childAdded` up the whole ancestor chain (`DirInfo.cpp:577-651`). After a delete they are marked dirty and recalculated lazily (`:241-318,654+`).
  - Compare F-0041: Radix uses 943 B/node.
- **Cache files** let a huge tree be read without a scan. A `CacheReadJob` reads 1000 lines per timer tick (`DirReadJob.cpp:706-724`).

## Deletion & rules

- **Where the "rules" live.** QDirStat has **no cleanup targets and no leftover heuristics**. It is a visualizer with user-defined actions.
  - The data-driven parts are the shell action templates (`StdCleanup.cpp` defaults, user copies in `QDirStat-cleanup.conf`, read in `CleanupCollection.cpp:499-592`), the MIME categories (`MimeCategorizer.cpp:336+`, `QDirStat-mime.conf`) and the exclude rules (`ExcludeRules.cpp`, `QDirStat-exclude.conf`).
  - The only built-in "junk" notion is the Junk MIME category and the "Delete Junk Files" action. That action is `rm -f *~ *.bak *.auto core`, it is recursive, and it asks for **no confirmation** (`StdCleanup.cpp:145-159`, and `Cleanup.cpp:41` defaults confirmation to false).
- **Execution.**
  - `Cleanup::expandVariables` replaces `%p`, then `%n`, then `%d`, each as `'…'` with POSIX `'\''` escaping (`Cleanup.cpp:176-225`).
  - The result runs as `QProcess($SHELL or /bin/bash or /bin/sh, ["-c", cmd])` with the cwd set to the item's directory (`:265-294,336-372`). The macOS default `$SHELL` is zsh.
  - **Verified defect:** the replacements run one after another, so a `%d` or `%n` inside an already-substituted path is expanded again. That breaks the quoting: words split, `&` and `;` act as operators, and `$(…)` runs. See F-0051 and `research/bench/shundhammer-qdirstat/expand_probe.out`.
- **Delete.**
  - `Delete (no way to undelete!)` is `rm -rf %p`, with confirmation and RefreshParent, on Ctrl+Delete and on the toolbar (`StdCleanup.cpp:162-176`). "Clear Directory Contents" is `rm -rf %d/*` with confirmation. "Compress" is `cd ..; tar cjvf %n.tar.bz2 %n && rm -rf %n` with **no** confirmation (`:96-109`).
  - `CleanupCollection::execute` runs the action on **every selected item, deliberately without normalizing the selection**. The comment is "Intentionally not using the normalized FileInfoSet here" (`CleanupCollection.cpp:295-308`). The confirmation lists at most 7 items (`:26,361-379`), in `QSet` hash order.
  - The scan root is auto-selected after every scan (`MainWindow.cpp:595,495,808-809`). So a Ctrl-click on children adds them to a selection that **still contains the root**. Issues #15, #267 and #316 are users losing parents or `/home` this way. See F-0050.
- **Trash.**
  - `Trash::trash` follows the freedesktop.org spec: `$XDG_DATA_HOME/Trash` or `~/.local/share/Trash`, and `$TOPDIR/.Trash/$UID` or `$TOPDIR/.Trash-$UID` on other devices (`Trash.cpp:40-53,106-174`). The move is a `QFile::rename` (`:300-313`). `restore()` and `empty()` are "Not implemented" (`:204-218`).
  - On macOS this means Finder's Trash never sees the item. **Verified in the shipped macOS binary:** `strings` finds `/.local/share`, `/.Trash` and `/.Trash-%1`, and nothing refers to `~/.Trash`. See F-0053.
  - Move to Trash does normalize the selection (`MainWindow.cpp:1144`) but asks for no confirmation.
- **Refresh after delete.** RefreshParent re-reads the parent directory from disk. If the parent is the scan root, it re-reads the whole tree (`DirTree.cpp:201-245`). While that runs, every action that refreshes is disabled (`CleanupCollection.cpp:156-157`, `MainWindow.cpp:335`), so the user cannot delete the next item. An `AssumeDeleted` policy (splice out, no re-read) exists but is opt-in per action (`Cleanup.h:188`, `CleanupCollection.cpp:313-327`). See F-0052.
- **Privilege escalation:** none. Actions run as the user. Issue #311 ("Request elevated privileges") was closed.
- **Protections:**
  - No path denylist, no "scan root" guard and no size warning.
  - The protections are the confirmation dialog, the bold "Directory" label, and the busy-state disabling of actions.
  - **No dry run:** `#define SIMULATE_COMMAND 1` exists but is never used (`Cleanup.cpp:23`, and a grep finds no other use).
  - The output window shows each command and its stderr (`OutputWindow.cpp`), which gives a per-run log, but nothing is persisted.

## UI

- **Rendering tech.** Qt Widgets. The treemap is a `QGraphicsScene`, where each tile at least `MinTileSize` (3 px, `TreemapView.h:30`) wide is a `QGraphicsRectItem`.
  - Leaf tiles render their cushion **per pixel on the CPU** into a `QImage`, one `sqrt` per pixel, with `setPixel`. This happens lazily on the first paint and is cached as a `QPixmap` per tile (`TreemapTile.cpp:383-528`).
  - Directory tiles get an optional gradient.
  - The whole scene is rebuilt on resize or zoom, on the GUI thread, debounced by `DelayedRebuilder` (`TreemapView.cpp:304-408`).
  - Below `UpdateMinSize` (20 px, `TreemapView.cpp:28,346`) the treemap is not built at all. The maintainer suggests shrinking the treemap to make big deletes fast.
- **Layout algorithm.**
  - Squarified rows with the standard worst-aspect-ratio stop rule (`TreemapTile.cpp:223-283`).
  - Rows are laid along the shorter side (`:286-379`). A ridge is added per row and per tile for the cushion surface.
  - Items smaller than `MinTileSize` are skipped, and their area stays as blank space. When `minSize > 0` the code keeps `remainingTotal = total` (`:199-211`), so the tile areas stay proportional. That is unlike F-0020 (Lemon, ln^12) and F-0040 (Radix auto-summary).
  - A skipped row (thinner than 3 px) returns the rectangle **unchanged** (`:313-314`). The next rows then get slightly more area than their share. This is minor: less than 3 px of strip per skipped row.
- **Interaction.**
  - Click selects (synced with the tree), double-click zooms in, middle-double-click zooms out, and the wheel zooms. Middle-click highlights the parent chain. Right-click opens the cleanup context menu (`TreemapTile.cpp:637-815`).
  - Keyboard navigation happens in the tree view. Breadcrumbs, back/forward and bookmarks are all there.
  - "Reveal" is `%filemanager %d`, which is `open <dir>` on macOS (`Cleanup.cpp:486-489`). It opens the folder but does not select the item.
  - Multi-select is `ExtendedSelection` (`DirTreeView.cpp:43`).
- **Performance on big trees.**
  - The scene holds one item per visible tile only, not per file, which is good.
  - Selection sync is `O(selected × tiles)`: `updateSelection` calls `findTile` for every selected item (`TreemapView.cpp:570-590`), and `findTile` walks `scene()->items()` with a `dynamic_cast` per item (`:637-651`). That is code-read, not timed, so I did not file it. macontrol should keep a node-to-tile map.
  - The tree view model emits `layoutChanged` for the whole model on every update tick.
- **Visual quality.** A classic, dense, utilitarian desktop UI. The cushion shading gives good depth cues. The colours follow MIME categories, and issue #294 asked for a colour legend. The screenshots are in `screenshots/`.

## Tests & quality

- **No unit tests and no CI.** `.github/` contains only `FUNDING.yml`.
  - `test/` has a tarball of edge-case files (special names, sparse files, hard links, broken symlinks, unreadable dirs; `test/data/README.md`) and a script that creates many files (`test/util/create-files`). Testing is manual.
- **Code style:** consistent, heavily commented and defensive.
  - `CHECK_NEW`/`CHECK_PTR` macros, a magic number in every `FileInfo` to detect dangling pointers (`FileInfo.cpp:240-243`, `FileInfoSet::invalidRemoved`), and explicit comments on every past crash (for example issues #122, #149, #251).
  - Its age shows: `QRegExp` through Qt5Compat, `foreach`, raw owning pointers, and `int` counters for item totals (`DirInfo.h:615-621`).
- Crash history clusters around **pointer lifetime after cleanups and refreshes** (#122, #149, #231, #251, #255, #259, #262, #264, #312). That is a direct result of mutating a raw-pointer tree on the same thread as the UI.

## Known problems

Recent issues (all closed; the maintainer closes everything):
- **Accidental deletion through ancestor selection.**
  - #316 (2026-08, "QDirStat wiped my /home directory"). The maintainer reconstructs it: the scan root stays selected, and Ctrl-clicks add children to that selection.
  - #267 (2023): the parent was deleted "in the middle of a list of its subdirectories". The maintainer: "I do that all the time… I don't want or need yet another babysitter".
  - #293 (2025, "Make delete button less dangerous": 100 GB lost). The maintainer: "More warnings are completely useless". Filed as F-0050.
- **Refresh cost after delete.** In #293 a user reports that "full refresh each time… can take over an hour", with AssumeDeleted as the workaround. Filed as F-0052.
- **Size semantics.**
  - Hard links: #124, #227, #253, #260.
  - Apparent vs allocated: #270, #306.
  - Filesystem quirks: CephFS (#281), NTFS (#302), Btrfs (`doc/Btrfs-Free-Size.md`).
- **Memory on huge trees.** #219: 9 GB for a 28 TB RAID, still unfinished after 2 days. The maintainer suspects a mount loop and rejects a disk-backed model.
- **macOS.**
  - Double counting through `/System/Volumes/Data` (qdirstat-macos#10 and #14, upstream PR #307). Fixed by a hardcoded skip.
  - `xdg-open` was used for URLs until PR #313 (2026-08).
  - The trash is not Finder's (F-0053, not reported upstream as far as I found).
- **Placeholder expansion.** F-0051 is not reported upstream as far as I found (unverified).

Board classes this source also shows, posted as a comment on T-0027 rather than filed again:
- F-0004 (clones counted at full size)
- F-0008 (PATH_MAX, but surfaced here as an error)
- F-0009 (serial walker)
- F-0010 (QDirStat divides by nlink instead of counting per link, a different undercount/overcount trade-off)
- F-0031 (firmlinks, hardcoded skip)
- F-0012 (permanent `rm -rf`, no journal)
- F-0026 (hierarchical selection semantics)

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Squarified layout | study (re-implement from paper) | `src/TreemapTile.cpp:191-379` | Correct, area-proportional, and tiny items become blank area rather than distorted area. It is GPL-2.0-only, so we write our own from Bruls et al. 2000. Fix the "skipped row keeps the rect" nit. |
| Cushion shading | improve | `src/TreemapTile.cpp:469-528,840+` (CushionSurface ridges) | Good depth cue. Re-implement from van Wijk 1999 as a Metal/Core Image shader, or render per tile off the main thread, at the display scale. QDirStat's per-pixel `setPixel` loop on the GUI thread is the thing not to copy. |
| List + treemap + details layout, synced selection | take (idea) | `src/MainWindowLayout.cpp`, `SelectionModel*.cpp`, `TreemapView.cpp:136-166` | The proven arrangement. Use a node-to-tile map instead of `findTile`'s linear scan. |
| File age stats (years, then months) | take (idea) | `src/FileAgeStats.cpp`, `doc/File-Age-Stats.md` | Cheap to compute from mtimes we already have. It answers "what is old and big", which suits a cleaner. |
| File size histogram, percentiles, buckets | study | `src/HistogramView.cpp`, `src/FileSizeStats*.cpp`, `doc/stats/*.md` | Good docs on why percentiles and an overflow area are used. Probably a later feature. |
| Data-driven MIME categories (suffix map, multi-dot fallback, wildcard patterns) | take (idea) | `src/MimeCategorizer.cpp:90-165,197-233,336+` | Hash lookup on the full suffix chain (`tar.gz`, then `gz`) before regexps. It is fast and user-editable. We would use UTType as the primary source and suffix rules as a fallback. |
| Exclude rules (name/full-path, wildcard/regexp/fixed, "dir contains file X") | take (idea) | `src/ExcludeRules.cpp:25-120,216-226` | "Contains a file matching X" is a neat project-dir detector (for example a `.git` or `CACHEDIR.TAG` marker). |
| User-configurable actions (shell templates) | rewrite | `src/Cleanup.cpp`, `src/StdCleanup.cpp`, `src/CleanupCollection.cpp` | The concept is useful for power users (Reveal, Open Terminal, custom scripts). The mechanics are unsafe: the multi-pass expansion (F-0051), the raw selection (F-0050) and `rm -rf` as the default delete. If we ship it, expand in one pass into argv (`sh -c '… "$@"' sh <paths>`), and never use shell actions for delete. |
| Hard delete / Move to Trash / refresh | ignore (anti-pattern) | `src/StdCleanup.cpp:162-176`, `src/Trash.cpp`, `src/DirTree.cpp:201-245` | Use FileManager.trashItem with a journal (T-0026). Splice the node out and verify with lstat (F-0052). Never follow the XDG trash spec on macOS (F-0053). |
| Tree node memory model (name only, parent/sibling/firstChild pointers, path on demand, lazy totals) | take (idea) | `src/FileInfo.h:959-979`, `src/DirInfo.cpp:241-318,508-651` | About 128 B/node plus the name (maintainer, #219), compared with 943 B for Radix (F-0041). In Swift we would go further, with a flat array of indices instead of pointers. |
| Cache file (gzip text tree dump, and a server-side writer script) | study | `src/DirTreeCache.cpp`, `doc/cache-file-format.txt`, `scripts/qdirstat-cache-writer` | "Scan now, view later" and reuse of a cached subtree during a scan. Useful for a persistent scan cache. The format is Linux-centric (uid/gid/perm, 512-byte blocks). |
| Inode-order fstatat | ignore | `src/DirReadJob.cpp:255-282` | Aimed at rotational disks. On APFS/SSD, `getattrlistbulk` makes the ordering moot (see T-0006). |
| BFS job queue on a GUI-thread timer | ignore | `src/DirReadJob.cpp:733-860` | Single-threaded, and it blocks the UI per directory. macontrol scans off the main actor in parallel (F-0009, T-0006). |
| `/System/Volumes/Data` string skip | ignore (improve) | `src/DirReadJob.cpp:399-414` | Use volume-role and `ATTR_DIR_MOUNTSTATUS` logic (F-0031) instead of a literal path. |
| Package / Unpkg views | study (idea only) | `src/PkgReader.cpp`, `src/MainWindowUnpkg.cpp`, `doc/Unpkg-View.md` | Linux-only. The macOS analogue, "files not owned by any installed app or pkg receipt" (via `pkgutil --files`), is a possible leftover finder for T-0005. |

## Open questions

1. Is the O(selected × tiles) treemap selection sync noticeable at macontrol scales (for example Select All on a folder with 10k children)? Code-read only, not timed, because there is no Qt here. It does not matter for our design as long as we key tiles by node id.
2. Does `QFile::rename` into `~/.local/share/Trash` ever fall back to copy+delete on macOS (cross-volume, when the home is on another volume)? The code picks a per-device trash dir, so it should be same-volume. Unverified.
3. How much faster is a full rescan of `~` on this Mac with QDirStat's serial `readdir`+`fstatat` than with our engine? This decides how bad F-0052 is in practice. Measure it in T-0004 with a C model of `LocalDirReadJob::startReading`, if the benchmark task wants it.
4. Does the upstream maintainer accept a single-pass expansion fix (F-0051)? That is not our concern, since we must not file remotely, but it is worth noting for T-0003 if someone reports it.
