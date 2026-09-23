# Source deep dive: gdu (dundee/gdu)

Task T-0032 · agent dive-dundee-gdu · 2026-09-23 · clone `research/sources/dundee-gdu` @ `848a5dd` (commit 2026-09-21). All `path:line` refer to that commit unless marked otherwise.

## Facts

| | |
|---|---|
| URL | https://github.com/dundee/gdu |
| License | MIT (`LICENSE.md`, "Copyright 2020-2021 Daniel Milde"; `gh api` spdx = MIT). Code can be copied with the notice kept. |
| Stars / forks | 5,999 / 234 (`gh api repos/dundee/gdu`, 2026-09-23) |
| Last commit / push | 848a5dd, 2026-09-21; pushed 2026-09-21T23:53Z. Latest release v5.37.0, 2026-08-18. Created 2018-02-24. Not a fork, not archived. |
| Language | Go 1.26 (`go.mod`), CGO off (`pkg/fs/dataless_darwin.go:45`). Web UI in React 18 + TypeScript + d3-hierarchy (`webui/frontend/package.json`). |
| Size | 15.6k lines of Go (non-test), 23.6k lines of Go tests (99 test files, 997 `func Test`). |
| Open issues | 39 of the first 50 open items are issues (53 open incl. PRs). Themes: Windows/OneDrive and WSL sizing (#265, #407, #162), terminal input and flicker (#190, #564, #522), hard links (#439 sizes move between folders on rescan, #267 deleting a link frees nothing, #667 filtered export drops `ino`), wrong totals with bind mounts or `-x` (#666, #204), feature requests (#504 bulk delete by age, #142 auto-rescan, #422 browse while scanning). |

## Summary

gdu is a fast terminal disk-usage analyzer (ncdu-style) with a newer local web UI (`--web`) that draws a squarified treemap and a donut chart. It scans with one goroutine per directory, `os.ReadDir` plus `lstat`, and keeps the whole tree in memory for the TUI. It counts hard links once by inode, opts out of iCloud/File Provider materialization on macOS, and has optional badger/SQLite storage, ncdu-JSON import/export, archive browsing, and type/time filters. It is not a cleaner: there are no cleanup rules, no uninstaller and no privilege escalation. Delete is `os.RemoveAll` by path; Move to Trash is refused on macOS.

Worth taking for macontrol: the dataless opt-out, the best-first node budget for the treemap API, the web UI's relocation check and local-action guard, the ADR/CONTEXT discipline around "displayed item count", and the SQLite `parent_id,name` schema. Not worth taking: the path-string engine (PATH_MAX, F-0008), the home-made WaitGroup (F-0007), the fat `fs.Item` interface, and the delete paths (three new findings below).

## Architecture

- **Entry**: `cmd/gdu/main.go` (cobra flags) → `cmd/gdu/app/app.go` picks a UI (TUI, stdout, export, web) and an analyzer (`app.go:272-293`).
- **Engine** `pkg/analyze/`: six analyzers behind `common.Analyzer`: `ParallelAnalyzer` (default TUI/export, `parallel.go`), `ParallelStableOrderAnalyzer` (`parallel_stable.go`), `SequentialAnalyzer` for HDDs (`sequential.go`, `--sequential`), `TopDirAnalyzer` for non-interactive totals (`parallel_top_dir.go`, `stdout/stdout.go:67`), `StoredAnalyzer` (badger, `stored.go`/`storage.go`) and `SqliteAnalyzer` (`sqlite.go`, `--db x.sqlite`). The maintainer's own `docs/architecture-todo.md` P0 says these duplicate ~700 lines of per-entry logic and have already drifted (tar missing in stored, preview broken in 4 of 6).
- **Model** `pkg/fs/file.go:31-54`: a 24-method `fs.Item` interface; `analyze.File`/`analyze.Dir` implement it (`pkg/analyze/file.go:21-31, 255-263`). Nodes hold `Name` + `Parent`; full paths are rebuilt by joining (`file.go:53-56, 463-472`).
- **UIs**: `tui/` (tview/tcell; the `UI` struct has 84 fields per `architecture-todo.md` P9), `stdout/`, `report/` (JSON export/import), `webui/` (Go HTTP API + embedded React build in `webui/dist`). UI and engine are separated by the `Analyzer` and `fs.Item` interfaces, but `report` type-asserts concrete `*analyze.Dir` (`architecture-todo.md` P6).
- **Docs discipline**: `CONTEXT.md` glossary, `docs/adr/0001..0002`, `AGENTS.md`. ADR 0001 fixes one "displayed item count" used by every frontend.

## Scanning

- **API**: `os.ReadDir(path)` then `DirEntry.Info()` (= `lstat` on the full path) per non-directory entry (`parallel.go:81, 115`). Directories get an extra `syscall.Stat` (follows symlinks) only for mtime (`parallel.go:94`, `dir_unix.go:34-41`). Every symlink also costs a `readlink` even when not following (`symlink.go:14-23`, `parallel.go:134`). Path strings everywhere, so subtrees deeper than PATH_MAX are silently dropped (F-0008).
- **Concurrency**: one goroutine per subdirectory is spawned at once (`parallel.go:108`) and then blocks on a package-global semaphore of `2*GOMAXPROCS` (`parallel.go:13, 50`). Each directory also gets a collector goroutine that waits for all its children (`parallel.go:196-205`). So the goroutine count is bounded by the number of pending directories, not by the semaphore. The semaphore is sized at package init, before `--max-cores` calls `runtime.GOMAXPROCS` (`app.go:436-445`), so `-m` does not change I/O concurrency (code-read; Go runs package var initializers before `main`).
- **Completion**: a home-made `WaitGroup` (`wait.go:5-49`) whose `Add` never re-locks after the count hits 0. I reproduced it with gdu's own type: `Init; Add(1); Done(); Add(1); Wait()` returns at once with a job outstanding (`research/bench/dundee-gdu/probe_engine_test.go` TestProbeWaitGroupRearm). That is the verified root cause of F-0007 in `TopDirAnalyzer`. `ParallelAnalyzer` is not affected because each parent's `Done` waits for its children's results. The maintainer works around it elsewhere with a sleep: "nasty hack to close storage after all goroutines are done … few last goroutines might still start after that" (`stored.go:41-46`).
- **Sizes**: disk usage = `st_blocks * 512` (`dir_unix.go:11-31`); apparent = `st_size`. Directories are charged 0 usage and a fixed 512 B apparent "EmptyDirSize" (`file.go:176-216`). APFS clones are counted in full (F-0004 class). Hard links: `Mli = st_ino` when `st_nlink > 1`, with no `st_dev` (`dir_unix.go:28-30`). The first link reached in `UpdateStats` gets the bytes (`file.go:108-121`). Child order is goroutine completion order (`parallel.go:199-201`), so which folder owns the bytes changes between runs (issue #439; same class as F-0054). A package-global `fileFlagMu` guards every `File.Flag` (`file.go:14-17`).
- **macOS specifics**: `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, PROCESS, OFF)` through purego before scanning (`pkg/fs/dataless_darwin.go:53-77`, called at `app.go:781-786`). This is good and is the documented TN3150 route. Firmlinks: only `--no-cross` maps mount points through `/System/Volumes/Data` (`pkg/device/mountpoint_alias_darwin.go:5-17`, `dev.go:51-70`). Without `-x`, `gdu /` would walk both `/Users` and `/System/Volumes/Data/Users` (F-0031 class; unverified, I did not scan `/`). Mount list comes from parsing `/sbin/mount` text (`pkg/device/dev_freebsd_darwin_other.go:23-49`).
- **Progress/cancel**: atomic counters published by a 50 ms ticker (`analyzer.go:139-153`). `Cancel` only stops scheduling new work; in-flight reads finish and the partial tree is kept ("Stopped scan" in `CONTEXT.md`; `analyzer.go:106-119`). Preview during a scan deep-copies the whole tree built so far on every call (`analyzer.go:51-60`, `file.go:265-288`), which is O(n) per preview.
- **Memory**: on the bench fixture (311k entries, `research/bench/fixtures/tree`) the full-tree path (`gdu-go -p -o /dev/null`, which also buffers the whole JSON in memory, `report/export.go:245-270`) peaked at 181 / 187 MB footprint (2 runs, 1.9-2.0 s). That is at most ~600 B per entry; the tree alone is less (not separated). `-n` (top-dir only) peaked at 25 MB. Per-node fields: `time.Time`, interface parent, name + symlink strings, two int64, inode, rune, plus a `sync.RWMutex` per dir (`file.go:21-31, 255-263`).
- **Persistence**: `--db x.sqlite` stores `items(id, parent_id, name, is_dir, size, usage, mtime, item_count, mli, flag)` with `(parent_id, name)` index (`sqlite.go:57-97`), `PRAGMA synchronous=OFF`. The repo's own warm benchmark on `~` (Linux, their numbers, unverified) shows 0.47 s in memory vs 8.2 s SQLite vs 15.6 s badger (`docs/benchmarks/bench-warm.md`). `-r` reads stored data with no freshness check (`tui/actions.go:270-286`).
- **Import/export**: ncdu JSON (`pkg/analyze/encode.go`, `report/import.go`). Export writes `ino` only for hard links and only in full exports (#667). Import trusts names (see F-0061).
- **Extras**: zip/jar/tar browsing (`zipdir.go`, `tardir.go`), git-annex sizes (`symlink.go:25-54`), gitignore-style ignore (`internal/common/gitignore.go`), time filters (`pkg/timefilter`), type filters (`internal/common/ignore.go:160-309`), PGO profile (`default.pgo`).

## Deletion & rules

- **Rules**: none. gdu has no cleanup targets, leftover heuristics or data files. Nothing to reuse for the cleaner/uninstaller.
- **Delete**: `os.RemoveAll(item.GetPath())`, then `dir.RemoveFile(item)` subtracts the item's raw stats up the parent chain (`pkg/remove/remove.go:11-19`, `file.go:513-543`). "Empty" truncates a file to 0 or deletes a dir's children (`remove.go:21-39`, `tui/actions.go:310-318`). Optional parallel delete of subdirs with a `3*GOMAXPROCS` semaphore (`pkg/remove/parallel.go:11-62`); on a partial failure it returns before `RemoveFile`, so the tree keeps showing already-deleted subdirs (code-read). Optional background delete queue (`tui/background.go`).
- **Trash**: refused on macOS: "The XDG trash location is ignored by Finder, so use permanent delete" (`pkg/remove/trash_darwin.go:11-14`). This is better than QDirStat's fake trash (F-0053). Linux gets a real XDG trash with `.trashinfo` reservation and EXDEV copy fallback (`trash.go:63-207`). `--trash-command` runs `/bin/sh -c <user script> gdu <absPath>`, passing the path as `$1`, not interpolated (`trash_command.go:60-110`).
- **Privilege**: none. No sudo, helper or elevation.
- **Protections**: `--no-delete` (`tui/tui.go:491-494`); delete blocked while a *time* filter is active unless `GDU_ALLOW_DELETE_WITH_FILTER=1` (`tui.go:722-763`); no delete inside archives (`tui/keys.go:454-470`); the parent row cannot be deleted (`keys.go:607-611`). Confirmation is `Are you sure you want to delete "<name>"?` with no size, and a "don't ask me again" button that turns confirmation off for the session (`tui.go:689-705`). The web UI is stricter: loopback plus same-origin plus per-run action token (`webui/server.go:142-150`), DNS-rebinding host check (`server.go:80-100`), refuses the scanned root and archive members, blocks delete under *any* file filter (`webui/handlers.go:123-133`), and re-resolves the parent chain to catch an ancestor swapped for a symlink (`webui/tree.go:209-265`, which says openat traversal would be the real fix). The TUI has none of these checks.
- **Dry run**: none (not a cleaner).
- **Defects found** (all verified with gdu's own packages, `research/bench/dundee-gdu/run.sh`):
  - F-0061: `gdu -f report.json` keeps delete enabled and trusts names from the file. A nested entry whose name is an absolute path, or a file named `../x`, deletes outside the report root. ncdu disables delete on import (`ncdu.1:79-84`).
  - F-0062: with `--type log`, the TUI shows a folder at its filtered size (4 KiB) but `d` + Yes removed the whole folder, 4 MiB of hidden files included. The web UI blocks the same state.
  - F-0063: deleting one hard link subtracts the full file size from every ancestor. A folder read −4,194,304 B and the root dropped 4 MiB below what was still on disk.

## UI

- **TUI** (tview/tcell): a sortable table per folder with size bar, optional item count, mtime and relative-size columns; drill down with Enter/arrows; mark several rows (`tui/marked.go`) and delete or empty them; `v` views a file, `o` opens it with `open` (`tui/actions.go:456-476`), `b` spawns a shell, `E` exports, `r` rescans, `-d` lists devices. There is no treemap in the TUI. Bars use "sum of siblings" or "largest sibling" as the denominator, and ignored rows are excluded (`CONTEXT.md`).
- **Web UI** (`--web`, `webui/`): React 18 + d3-hierarchy squarified treemap (`webui/frontend/src/components/treemap/treemap.ts:22-46`, nested layout with `minArea` culling in `treeLayout.ts:32-110`), donut view, breadcrumbs and file table. `GET /api/v1/tree` returns at most 5,000 nodes, expanded best-first by usage through a max-heap (`webui/tree.go:299-363`), so the map fills the biggest areas first instead of the deepest branch. Reveal runs `open <containing dir>` on macOS (`webui/reveal.go:18-38`, `handlers.go:179-212`): it opens the folder but does not select the item. Live updates arrive over `/api/v1/events` (`server.go:75`).
- **Performance on big trees**: the TUI sorts a copy of the children on every listing (`file.go:382-416`). The web API caps payloads at 5,000 nodes. Mid-scan preview copies the whole tree (see Scanning).
- **Visual quality**: a terminal UI (screenshot `gdu.png`). The web UI is plain d3 rectangles with no cushion shading. Not benchmarked visually.

## Tests & quality

- 997 Go tests, run with `-race` and coverage in CI (`Makefile:104`, `.github/workflows/test.yml`), golangci-lint (`Makefile:176`), CodeQL, and vitest for the web UI (`webui/frontend/src/**/*.test.ts*`). There are parity tests across analyzers (`pkg/analyze/analyzer_parity_test.go`) and race tests for cancel, preview and the partial tree.
- Gaps that match the defects: no unit test for `WaitGroup`; `TopDirAnalyzer` tests use tiny trees (`parallel_top_dir_test.go`); hard-link tests only link inside one folder (`dir_test.go:117`, `sequential_test.go:117`); no test deletes a hard link, deletes under a type filter, or deletes from an imported report.
- The maintainer's own `docs/architecture-todo.md` is an honest defect list (six duplicate analyzers, four hard-link trackers, a global mutex, a god-object TUI).
- The repo accepts agent-written issues and PRs (`AGENTS.md`, `docs/agents/`; #667 has an AI-disclosed comment).

## Known problems

1. Non-interactive totals are nondeterministic (F-0007). Root cause now verified: `wait.go` `Add` does not re-arm after the count reaches 0.
2. Paths longer than PATH_MAX are silently skipped (F-0008).
3. Import keeps delete enabled and trusts names (F-0061, new).
4. The TUI deletes whole folders under a type filter (F-0062, new).
5. Hard-link delete accounting drives folders negative (F-0063, new). Hard-link ownership follows goroutine order (#439, class F-0054). Inode is not paired with dev (`dir_unix.go:28-30`).
6. APFS clones are counted in full (F-0004 class).
7. `gdu /` on macOS without `-x` likely double-walks the Data volume (F-0031 class, unverified).
8. `--max-cores` does not resize the scan semaphore (`parallel.go:13` vs `app.go:436-445`, code-read). One parked goroutine per pending directory.
9. A partial parallel delete leaves the tree showing removed subdirs (`pkg/remove/parallel.go:44-60`, code-read).
10. The storage analyzers are 17-33x slower than in-memory (their own bench, unverified) and `-r` has no freshness check.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Dataless materialization opt-out | take | `pkg/fs/dataless_darwin.go:11-77` | The correct, documented macOS call (TN3150); port to Swift as one `setiopolicy_np` call at scan start. MIT. |
| Best-first node budget for the map | take (idea) | `webui/tree.go:299-363` | A max-heap by size with a 5,000-node cap keeps the treemap fast on `/` and fills the biggest areas first. Use it for macontrol's render budget. |
| Web action guard (loopback, same-origin, token, host check) | study | `webui/server.go:80-150` | Only relevant if macontrol ever serves a local web view. Good pattern. |
| Relocation check before delete | improve | `webui/tree.go:209-265` | Right idea (re-resolve the parent chain), but string/EvalSymlinks based with a TOCTOU window. macontrol does it fd-relative (openat + O_NOFOLLOW + dev/ino compare), as the comment itself says. |
| Squarified treemap layout | ignore | `webui/frontend/src/components/treemap/*.ts` | Thin wrapper over d3-hierarchy in TypeScript. macontrol draws natively; take ordered/Hilbert layouts from other dives. |
| Scan engine (ReadDir + lstat, goroutine per dir) | rewrite | `pkg/analyze/parallel.go`, `dir_unix.go` | Path-based (PATH_MAX), lstat per file, no dev in hard-link key, no clone handling, custom WaitGroup. macontrol uses fd-relative getattrlistbulk on a bounded pool (T-0006). |
| Hard-link "count once" | rewrite | `pkg/analyze/file.go:108-121` | Order-dependent attribution, inode without dev, wrong subtraction on delete (F-0063). Use the (dev, ino) side table with LCA attribution (F-0047, F-0054). |
| Custom WaitGroup | ignore | `pkg/analyze/wait.go` | Buggy (F-0007). Use DispatchGroup or TaskGroup semantics. |
| Empty-dir size rule + ADR on displayed count | take (idea) | `pkg/analyze/file.go:176-216`, `docs/adr/0001-*.md`, `CONTEXT.md` | One definition used by every frontend, locked by a cross-analyzer parity test. Copy the discipline: one accounting function, one parity test. |
| SQLite tree schema | study | `pkg/analyze/sqlite.go:57-97` | `(id, parent_id, name, …)` plus a `(parent_id, name)` index is a compact persisted tree without full paths. Add dev+ino per node and a freshness key before any use (see F-0017, F-0061). |
| ncdu JSON import/export | study | `pkg/analyze/encode.go`, `report/import.go` | A useful interchange format for bench comparison. If macontrol imports it, the tree is read-only and names are validated (F-0061). |
| XDG trash implementation | ignore | `pkg/remove/trash.go` | Linux only. macontrol uses `FileManager.trashItem` / NSWorkspace recycle. |
| `--trash-command` pattern | study | `pkg/remove/trash_command.go:60-110` | Passes the path as `$1` to `sh -c`, never interpolated. A safe pattern if macontrol ever runs user actions (contrast F-0051). |
| TUI | ignore | `tui/` | A terminal UI, 84-field god object by the maintainer's own account. Nothing to port into a native app beyond key ideas (marking, bar denominator modes). |
| Time-filter delete block | improve | `tui/tui.go:722-763`, `webui/handlers.go:123-133` | Right instinct, applied inconsistently (F-0062). macontrol puts the rule in one delete planner. |

## Open questions

- Does `gdu /` on macOS 26 double-count the Data volume without `-x`, and does `-x` fix it? I did not scan `/` (unverified; see F-0031).
- How many bytes per node does the in-memory tree alone take, without the export's JSON buffer? It would need a heap profile (`--enable-profiling`, `cmd/gdu/main.go:80`, `app.go:749-757`) rather than max RSS.
- The storage analyzers' slowdown was measured by the maintainer on Linux. It was not re-measured on APFS.
- gdu's own claim that it beats dua/dust on warm `~` (`docs/benchmarks/bench-warm.md`) conflicts with our T-0004 fixture run, where gdu `-n` was 1.73 s vs dua 0.7 s. Different trees and platforms; see `research/reports/bench-scan-engines.md`.

## Probe

`bash research/bench/dundee-gdu/run.sh` (about 7 s after the first module download). It uses `go test -overlay` to stub badger and the modernc SQLite driver and to inject `probe_engine_test.go` (into `pkg/remove`) and `probe_tui_test.go` (into `tui`). The clone is never modified. Output from the run on 2026-09-23:

```
RESULT waitgroup: Wait() returned while 1 job is still outstanding (bug reproduced)
RESULT hardlink deleteCounted=false before[root=5242880 a=4194304 b=0] deleted=b/data.bin after[root=1048576 a=4194304 b=-4194304] real_on_disk=5242880
RESULT hardlink deleteCounted=true before[root=5242880 a=4194304 b=0] deleted=a/data.bin after[root=1048576 a=0 b=0] real_on_disk=5242880
RESULT import row name="victim" -> GetPath()="<tmp>/elsewhere/victim"
RESULT import row name="../elsewhere/victim2.txt" -> GetPath()="<tmp>/elsewhere/victim2.txt"
RESULT import delete row="victim" removed="<tmp>/elsewhere/victim" err=<nil> still_exists=false
RESULT import delete row="../elsewhere/victim2.txt" removed="<tmp>/elsewhere/victim2.txt" err=<nil> still_exists=false
RESULT typefilter row logs shown usage=4096 size=2048
RESULT typefilter front page after d: "confirm" (modal) IsFilteringFiles=true noDeleteWithFilter=false
RESULT typefilter after Yes: logs/ exists=false video.mov exists=false
```
