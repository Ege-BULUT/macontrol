# Source deep dive: dua-cli and its engine crate dua-core (Byron/dua-cli)

Task T-0029, a child of the T-0006 engine survey. Author: dive-byron-dua-cli, 2026-09-23. Unless stated otherwise, every code citation refers to `Byron/dua-cli@cf59618`. The clone is at `research/sources/Byron-dua-cli`. macOS matches paths case-insensitively, so `byron-dua-cli` opens the same folder; the clone is gitignored. The probes are in `research/bench/byron-dua-cli/`. Runtime checks used the Homebrew binary `dua 2.45.0`, the same version as the source. Nothing was built here, because this machine has no cargo.

## Facts

| | |
|---|---|
| URL | https://github.com/Byron/dua-cli. The engine is published as the crate `dua-core` 4.1.0 (`crates/dua-lib/Cargo.toml`). |
| License | MIT, "Copyright (c) 2019 Sebastian Thiel" (`LICENSE`). The workspace license covers dua-core too (`Cargo.toml` `[workspace.package] license = "MIT"`). The GitHub API also reports MIT. |
| Stars / forks | 6,292 / 170 (`gh api repos/Byron/dua-cli`, 2026-09-23) |
| Created / last commit | 2019-05-29 / 2026-09-22 (`cf59618`, "Merge pull request #404") |
| Latest release | v2.45.0, 2026-09-12 (`gh api .../releases/latest`) |
| Issues | 0 open issues and 0 open PRs. The most discussed closed issues are Windows builds (#2), glob search (#154), refresh (#96), hangs and slow scans (#116, #223, #302), terminal redraw (#28, #143), and safety: #248 "Dangerous CTRL+r hotkey" was closed *not_planned*, #365 is escape injection in printed paths, #245 is trash errors. Many old issues were bulk-closed on 2026-08-29. |
| Language | Rust, edition 2024, MSRV 1.88 (`crates/dua-lib/Cargo.toml`). About 31.7k lines of `.rs` including tests. dua-core itself is about 4.2k lines (`lib.rs` 2,319, `macos/` 1,643). |
| Engine dependencies | `crossbeam` 0.8 (deque, Parker) and `libc` on macOS (`crates/dua-lib/Cargo.toml`). No jwalk and no rayon. |
| App dependencies | `ratatui`/`crossterm` (TUI), `gix` (gitignore, Git-aware clean), `trash` 5.2.5 (Byron/trash-rs, MIT), `inferno` (flame graphs), `open` (`Cargo.toml`) |
| Platforms | CI runs on ubuntu-latest, macos-15 and windows-latest with `clippy ... -D warnings` at pedantic level (`.github/workflows/rust.yml:12,36,51`, `Cargo.toml [workspace.lints.clippy]`) |

## Summary

dua ("Disk Usage Analyzer") is a terminal tool. `dua` / `dua aggregate` prints totals, `dua i` is a TUI explorer where you can mark entries and delete or trash them, `dua clean` finds build and cache directories, and `dua stacks`/`flamegraph`, snapshots and `dua diff` cover export and comparison. It has no GUI, no app uninstaller, no treemap or sunburst, and no system-junk rules.

The reason to study it is **dua-core**, the most complete MIT-licensed parallel walker we found, with a native macOS path:
- a crossbeam work-stealing pool: an injector for roots, a LIFO deque per worker, stealing, park/unpark, and a bounded output channel (`crates/dua-lib/src/lib.rs:1-26, 784-970`);
- a `getattrlistbulk` reader that deliberately reproduces Apple FTS, and therefore `du`, semantics, including `FSOPT_PACK_INVAL_ATTRS`, the rule that directories are always stat'd, a firmlink lookup, and 512-byte allocation rounding (`macos/mod.rs:351-512`, `macos/attributes.rs:29-56, 372-400`);
- optional APFS clone deduplication through `FSOPT_ATTR_CMN_EXTENDED` with `ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_EXT_FLAGS` (`attributes.rs:55-56, 152-164`, `macos/mod.rs:361-363`);
- a per-directory probe that switches from bulk reads to parallel per-entry `lstat` when the bulk refills are I/O-bound (`macos/mod.rs:256-323`, `lib.rs:1150-1168`).

The app side keeps a compact arena tree: 64-byte nodes, one names arena, and `u32` links (`src/traverse.rs:131-152, 234-243`).

Measured on the shared bench (T-0004, `research/bench/results/*-summary.json`, M1 with 8 GB, warm cache, heavy background load):
- dua is the **fastest tool**: 0.70 s on the 311k-inode fixture against 1.2-8.3 s for the others, and 1.88 s on ~/projects.
- It uses 5.6 MB peak footprint for `aggregate`.
- Its totals are byte-stable across 3 runs.
- It is 8,417,280 B short on the fixture's PATH_MAX-deep subtree and exits 1 (F-0008).

What I verified myself:
- **Per-folder sizes change between identical scans.** A shared hard link or clone is charged to whichever folder the parallel walk reaches first: 17/13 of 30 runs for a hard link, 16/14 for clones, 5/7 of 12 runs in the TUI. Filed as **F-0054**.
- **TUI "refresh selected" counts a hard link twice.** The total goes from 8,716,288 to 17,104,896 B (F-0037 class, evidence posted on T-0022).
- **Clone dedup misses partial clones.** On the fixture it removes exactly the full clones (503,635,968 B) and still double-counts the 119 MiB partial clone (F-0004 class, evidence on T-0009).
- **Building the TUI tree costs little.** `dua stacks --depth 1000`, which runs the same integration path as the TUI, took 0.81-0.87 s against 0.65-0.75 s for `aggregate`, with 49-52 MB peak against 5.2-5.7 MB, on 311k entries (2 runs each, load average ~16, not a benchmark).

A quality warning: the maintainer writes in `CHANGELOG.md:23-27` and `:170-174` that the 2.45.0 commits (Git-aware clean, background deletion and the macOS I/O-bound probe) were agent-written and "mostly rubber-stamped ... Too much to look at, too foreign by now". Treat the newest engine code as reviewed by its tests, not by its author.

## Architecture

- **dua-core** (`crates/dua-lib/`) is a library with no UI. Its public API is `walk` (one root, entries in order), `walk_roots` / `walk_root_entries` (several indexed roots with per-root `Finished` events), `stream_roots` (roots added while the walk runs, which dua clean uses), and `read_dir` (`lib.rs:381-645`). It has `#![deny(unsafe_code)]`, with unsafe allowed only in the `macos`/`windows` modules (`lib.rs:27, 53-59`).
- **Entry model.** Each `Entry` holds `depth`, `file_name`, `file_type`, `metadata: Option<io::Result<Metadata>>`, `parent_path: Arc<Path>` (one shared per directory), and dense `u32` `DirectoryId`s for itself and its parent (`macos/mod.rs:30-45`, `lib.rs:178-197`). Consumers rebuild the tree from the directory IDs, never from path strings (`traverse.rs:1458-1486`).
- **The app** (`src/`) contains:
  - `aggregate.rs`, which sums per root in completion order and keeps no tree;
  - `traverse.rs`, with the arena `Tree`, `BackgroundTraversal` (a dispatcher thread feeding a `crossbeam::channel::bounded(100)`, `:1053`) and `integrate_traversal_event`, which runs on the UI thread (`:1274-1534`);
  - `inodefilter.rs` for hard-link and clone accounting;
  - `clean.rs` + `clean/git.rs` for cleanup discovery;
  - `interactive/` for the ratatui TUI, marks, deletion and the clean hub;
  - `snapshot/` for a streaming, zlib-compressed, digest-checked format (`snapshot/mod.rs:13-31, 291`);
  - `diff.rs` and `stacks.rs`.
- **UI and engine separation is clean.** The TUI only consumes `TraversalEvent`s (`traverse.rs:785-809`) and a `Tree`. dua-core knows nothing about sizes, trees or the UI.

## Scanning

**Scheduler** (`lib.rs`):
- `start_pool` creates `threads` workers, each with a `Worker::new_lifo()` deque and a crossbeam `Parker`, plus a shared `Injector` and a `sync_channel(threads * 2)` for output (`:784-822`).
- `find_job` checks, in order: the injector (new roots, so large trees cannot starve them), then the local LIFO, then steals from peers (`:947-970`).
- A worker that steals successfully wakes one more idle worker, so parallelism ramps up only while work is stealable. Idle workers mark themselves in `idle[]` and park; `wake_worker` claims one with a CAS (`:717-742, 903-925`).
- Per-root completion uses `pending` job counters. The last job emits `RootFinished`, and the last root emits `Finished` (`:1443-1459`).
- **Order.** `ParentFirst` publishes a directory's batch before its child jobs become stealable. The TUI needs this, because a child must find its parent node, and it panics otherwise (`traverse.rs:1267-1270, 1471`). `Completion` schedules the children first (`lib.rs:1399-1440`). "Sibling order is unspecified in both modes" (`lib.rs:6`). That is the root cause of F-0054.
- **Batching and backpressure.** Entries are published in chunks of 4 (`ENTRY_CHUNK_SIZE`, `:137`), which streams wide directories. Metadata jobs are capped at 64 queued per worker; past that, a chunk is processed inline (`:140, 1241-1264`).
- **Cancellation.** `Walk::next_cancellable` polls an `AtomicBool` every 100 ms while it waits (`:526-583`). Dropping a `Pool` sets `stop`, unparks every worker, swaps the receiver for a disconnected one so blocked senders fail, and joins the threads (`:927-938`). The tests cover cancellation with a full channel (`:1569-1767`).
- **Default thread count.** macOS uses 8 (`src/options.rs:64-66`, "without saturating macOS with syscalls"). Other platforms use all cores. History: it was 3 on macOS because "16 threads ... 4.1s ... 3 threads 550ms" (`CHANGELOG.md:1622-1625`, issue #325).

**macOS reader** (`macos/mod.rs`, `macos/attributes.rs`):
- The directory is opened with `open(path, O_RDONLY|O_DIRECTORY)` **by full path** (`mod.rs:325-344`). That is why it fails past PATH_MAX (F-0008).
- `getattrlistbulk` fills a 64 KiB 8-byte-aligned buffer (`mod.rs:27`, `attributes.rs:58-74`). It requests the FTS attribute set: name, devid, objtype, the times, owner, group, mode, flags, fileid, plus linkcount, allocsize, iosize, devtype and datalength (`attributes.rs:29-53`), with `FSOPT_PACK_INVAL_ATTRS` (`mod.rs:356-363`).
- The parser is a bounds-checked cursor. Every offset and length is validated, and it handles packed-invalid attributes and pre-epoch timestamps (`attributes.rs:172-358, 403-436`). This is good reference code to port.
- **Directories are always `lstat`ed by path.** The FTS contract rejects `VDIR` (`attributes.rs:384-400`, `mod.rs:491-498`), so each directory costs one extra path-based syscall. Firmlinks (`SF_FIRMLINK`) are also looked up by path "to expose the visible target" (`mod.rs:491-496`).
- **Error handling:**
  - `EACCES` (readable but not searchable) triggers a retry with a list-only attribute set that XNU allows with LIST_DIRECTORY alone (their claim, citing `vfs_attrlist.c`), so each entry carries its own error (`mod.rs:391-395`, `attributes.rs:42-48`).
  - `EINVAL`/`ENOTSUP`/`ENOSYS` with extended attributes drops the APFS attributes (`mod.rs:396-403`).
  - An unsupported filesystem falls back to `fs::read_dir` + `lstat` (`mod.rs:404-418`).
  - `EINTR` retries.
- **I/O-bound probe.** For each directory, when threads > 1, the first two bulk refills are timed as thread CPU time (`CLOCK_THREAD_CPUTIME_ID`) against wall time. If both spend more than half their time waiting, the directory is reopened with plain readdir and each entry's `lstat` becomes a stealable job (`mod.rs:256-323, 520-533`; `lib.rs:1150-1168`). The code says the classification "remains sensitive to scheduling, since time off-CPU also counts as waiting" (`mod.rs:277-278`). Unverified: whether a loaded machine flips many directories into per-entry `lstat` mode (see Open questions). The trigger was a directory with 1M+ files, where the switch gave a claimed 2.5x speedup (`CHANGELOG.md:18-20, 168-190`, their measurement).

**Sizes:**
- The default is allocated size: `ATTR_FILE_ALLOCSIZE` rounded up to 512 B, which matches `stat`/`du` (`attributes.rs:311-316, 372-376`; `traverse.rs:1845-1862`).
- `-A` gives apparent size, `st_size`, **including directory `st_size`**. On the fixture that reads +10.7 MB against the files-only ground truth, the same as ncdu (bench `apparent_delta_bytes`). This is a matter of definition, not a bug.
- **Hard links** are counted once by `(dev, ino)` with a countdown map. An entry leaves the map once all `nlink` links have been seen, which keeps memory small (`inodefilter.rs:149-168`).
- Directories from bulk reads report a link count without `.` and `..`, so the first sighting is marked `UNRESOLVED` and only a repeat sighting pays for an `lstat` (`inodefilter.rs:92-142`).
- `-l` counts every link.
- **APFS clones** (`--deduplicate-apfs-clones`, opt-in):
  - The walker also requests `ATTR_FILE_DATAALLOCSIZE`, `ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_EXT_FLAGS` (`attributes.rs:54-56, 114-117`). The clone ID counts only when `EF_MAY_SHARE_BLOCKS` is set (`attributes.rs:152-164`).
  - The first member of a `(dev, cloneid)` group pays full allocation. Later members pay only the non-data-fork bytes, so resource forks stay private (`inodefilter.rs:177-212`).
  - Partial clones are not deduplicated. The README says so, and I verified it against the fixture numbers (see T-0009).
  - Roots and stat'd entries get the clone attributes through a separate `getattrlist` call (`mod.rs:563-589`).
- **Crossing filesystems.** The default is to cross (`src/main.rs:718`; `-x` is opt-in, `options.rs:162-170`). The `-x` check compares `st_dev` only (`src/crossdev.rs:11-16`). There is no `ATTR_DIR_MOUNTSTATUS` and no `SF_DATALESS` handling (grep finds nothing). F-0031 class, see the comment on T-0018.
- **Progress.** Consumers throttle updates (`Throttle` 250 ms in `traverse.rs:1138`, 100 ms in `aggregate.rs:43`). The TUI keeps ancestor sizes live, because `integrate_traversal_event` adds each entry's size up its ancestor chain, O(depth) per entry (`traverse.rs:1488-1495`; test `ancestor_sizes_update_before_traversal_finishes`, `:2256`).

**Memory model:**
- The arena `Tree` stores `TreeNode`s of 64 bytes: `u128` size, `SystemTime`, `u64` count, `u32` name start and length, and `u32` parent / first child / next sibling / flags. Names live in one append-only `Vec<u8>`. Removed slots go on a free list (`traverse.rs:131-152, 234-243, 537-555, 593-610`).
- There is a test for the node size (`tree_nodes_and_optional_indices_are_compact`, `:2659`). Limits: `u32` nodes and `u32` name bytes, so 4 GiB of names (`:278-293`). `rename` leaks the old name bytes (`:487-497`).
- The README's "60MB for 1 million entries" and its petgraph note are stale, since petgraph is gone (`README.md` "Limitations", `traverse.rs:137-139`).
- I measured about 50 MB peak for 311k entries through `dua stacks`. That includes the stacks output, so it is an upper bound.

## Deletion and rules

**Clean rules** (`src/clean.rs`):
- The rules are **hard-coded**, not data-driven. The directory names are `.mypy_cache .pytest_cache .ruff_cache .tox .venv .zig-cache __pycache__ node_modules target venv zig-cache zig-out` (`:17-35`).
- Content gates: `target` needs a sibling `Cargo.toml`, and `.venv`/`venv` must contain `pyvenv.cfg` (`:150-161`).
- Inside a Git repository, a candidate must be **ignored as expendable and contain no tracked paths**. The check fails closed on a broken `.git` or a truncated index, and honours "precious" ignore patterns (`clean/git.rs:15-58, 60-90`, `gitoxide.parsePrecious=true`). Anything named `.git` in any case, and bare repositories, are skipped (`clean.rs:12-14, 201-203`).
- While sizing, a candidate is **rejected** if any descendant is a Git marker, matches an exclude, crosses a device, or has a metadata error (`traverse.rs:1559-1625`). Candidates are staged in the tree and published only once accepted (`:1289-1341`).
- This is clearly safer than kondo (F-0033, F-0035). The weak spot is that discovery is a single serial path-based reader (`clean.rs:97`).

**Deletion** (`src/interactive/app/deletion.rs`):
- The flow: mark entries (space, `x`, `d`), move to the mark pane, then press Ctrl+t to trash or **Ctrl+r to delete "without prompt"** (`config.rs:574-575`, `widgets/i18n.rs:838-839`, `widgets/mark.rs:170-208`). #248 asked for a safer key and was declined; you can unbind the keys (PR #389).
- A target path is rebuilt from the tree and walked again at delete time with `skip_metadata`. Files are then unlinked in parallel with path-based `fs::remove_file`, and directories are removed deepest-first on one thread (`deletion_progress.rs:123-156`, `deletion.rs:137-225`).
- There is no identity check against the scanned node, no journal and no dry run. A permanent delete cannot be undone.
- Deletion runs in the background with live "bytes remaining", can be cancelled, and blocks new scans while it runs (`deletion_progress.rs:104-171`).
- **Trash** goes through `trash::delete` per path. In trash-rs 5.2.5 on macOS that runs `osascript` telling Finder to delete (`Byron/trash-rs@v5.2.5 src/macos/mod.rs:112-150`). It escapes `"` and `\`, so it avoids F-0018's injection. It needs an Automation grant, and failures are counted, never followed by a permanent delete.
- There is no privilege escalation anywhere.

## UI

- The TUI is built with ratatui and crossterm. It shows a sorted list per directory with percentage and bar columns (`interactive/app/bytevis.rs`), sorting by size, mtime, count or name, glob search (`/`), marks, a help pane and i18n in de/ja/ko/zh (`widgets/i18n.rs`).
- Keys:
  - Drill in with `o`, `l`, Enter or Right, and back out with `u`, `h`, Backspace or Left (`config.rs:551-552`).
  - `U` scans the parent incrementally and reuses existing subtrees (`traverse.rs:1014-1041`).
  - `r` / `R` refresh the selection or everything. The `r` path is the one that double counts (above).
- `O` **opens** an entry with the default app (`open::that`, `handlers.rs:81`). There is no reveal-in-Finder.
- After a scan, every view update `lstat`s every visible row by full path to mark vanished entries (`interactive/app/common.rs:120-128, 163-169`). `-e` / `--no-entry-check` turns that off.
- The rest: gitignore-aware marking (`i`/`I`), snapshots (`--export` / `--import`, read-only), `dua diff`, and flame-graph SVGs through inferno.
- Visual quality is utilitarian. The README says it "only looks good in dark terminals" (issue #13).

## Tests and quality

- There are 320 `#[test]` functions in 39 files.
- The engine tests cover:
  - scheduling: starvation, cancellation with a full channel, dense directory IDs, parent-first order, the backlog bound (`lib.rs:1472-2319`);
  - macOS bulk-versus-std parity for regular files, resource forks, symlinks, clones, hard links, devfs, fractional pre-epoch times and search-less directories (`macos/tests.rs:13-450`);
  - the parser's contract (`attributes.rs:443-530`).
- The app tests include TUI "journeys" (read-only, deletion, clean, writes) and snapshot/diff tests.
- The gaps I found:
  - The hard-link and clone tests assert totals, mostly with `threads: 1` (`aggregate.rs:738-900`). Nothing checks per-folder attribution with several threads (F-0054) or refresh with shared inodes.
  - There is no PATH_MAX test (F-0008).
- Clippy runs at pedantic level with `-D warnings` on three operating systems. The code is heavily documented, with `#![deny(missing_docs)]` in dua-core. The newest parts are agent-written and, in the maintainer's words, rubber-stamped (`CHANGELOG.md:23-27, 170-174`). Two in-code comments even use a `ponytail:` convention (`clean.rs:97`, `clean/git.rs:113`).

## Known problems

1. **PATH_MAX.** Opens, `lstat`s and unlinks all use full paths, so subtrees past 1024 bytes are skipped (8,417,280 B on the fixture, exit 1) and cannot be deleted. F-0008, verified by T-0004.
2. **Per-folder attribution race** for hard links and clones. **F-0054**, verified.
3. **TUI refresh double-counts** shared inodes, because every refresh gets a fresh `InodeFilter` (`traverse.rs:1137`). 8.7 MB became 17.1 MB. F-0037 class, verified, posted on T-0022.
4. **Clone dedup** is opt-in and misses partial clones (124,780,544 B on the fixture). F-0004 class, posted on T-0009.
5. **Crosses mounts by default** and resolves firmlinks, so `dua /` very likely counts the Data volume twice. F-0031 class, code-read, posted on T-0018.
6. **Ctrl+r deletes permanently without a prompt.** There is no journal and no identity recheck, and the path is walked again at delete time. F-0012 class, posted on T-0013.
7. **The I/O-bound probe depends on scheduling by design** (`macos/mod.rs:277-278`). Its effect under load is unverified.
8. **Directory entries always cost one extra path `lstat`,** because the FTS contract applies to directories (`attributes.rs:384-400`).
9. **The README is stale** about petgraph and memory figures, and the newest code has had little review.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Work-stealing walker (injector, per-worker LIFO, steal, park/unpark wake-on-steal, per-root pending counters, bounded output, ParentFirst/Completion, streaming roots, cancellation) | take (port to Swift) | `crates/dua-lib/src/lib.rs:128-1469` | MIT, small, well tested, and the fastest engine on our bench. Every scheduling decision is documented in the code. Port it onto `Dispatch`/`pthread` workers with lock-free deques or a Mutex-guarded ring per worker. |
| getattrlistbulk reader and packed-attribute parser | improve | `crates/dua-lib/src/macos/mod.rs:238-533`, `macos/attributes.rs` | Take the bounds-checked parser, the PACK_INVAL handling, the EACCES list-only retry and the ENOTSUP fallback. Change three things: use `openat(parentfd, name, O_NOFOLLOW)` (F-0008); request `ATTR_DIR_LINKCOUNT`/`ALLOCSIZE`/`MOUNTSTATUS` in the same call instead of an `lstat` per directory (F-0031); add `PRIVATESIZE`/`CLONE_REFCNT`/`SF_DATALESS` (F-0004). |
| I/O-bound bulk→stat switching probe | study | `macos/mod.rs:256-323`, `lib.rs:1150-1168` | A clever CPU-versus-wall classifier, but it depends on scheduling and has not been measured under load. Benchmark it (T-0004) before porting. |
| Hard-link filter (countdown map, UNRESOLVED directory marker) | improve | `src/inodefilter.rs:1-169` | The memory-lean countdown and the note about bulk directory link counts are worth keeping. Replace first-seen attribution with LCA (F-0047, F-0054), and route every writer through it (F-0037). |
| APFS clone accounting | improve | `src/inodefilter.rs:171-214`, `attributes.rs:152-164` | Correct `EF_MAY_SHARE_BLOCKS` gate and private-fork split. Add partial-clone handling via PRIVATESIZE (F-0004), make attribution deterministic (F-0054), and consider it for the default mode. |
| Arena tree (64-B nodes, names arena, u32 links, free list) | take (design) | `src/traverse.rs:131-695` | A ready answer to F-0041's 943 B/node. In Swift, use struct-of-arrays with `UInt32` indices and add name-arena compaction, which `rename` currently leaks. |
| Live ancestor-size integration from dense directory IDs | take (idea) | `src/traverse.rs:1274-1534` | Parent lookup by directory ID with no path strings, and live sizes while scanning. It measured cheap here: about 0.1-0.16 s extra on 311k entries. |
| Clean discovery rules and Git gate | take (rules), rewrite as data | `src/clean.rs:17-212`, `src/clean/git.rs` | Content-verified candidates plus a "Git-ignored and untracked" gate that fails closed and respects precious patterns. Move the names and gates into macontrol's rule file. |
| Candidate vetting while sizing (reject on git marker, exclude, device cross, error) | take (idea) | `src/traverse.rs:1537-1830` | Staged publish-on-accept is exactly the fail-closed shape a cleanup list needs. |
| Deletion task | rewrite | `src/interactive/app/deletion.rs`, `deletion_progress.rs` | It is path-based, walks again at delete time, has no identity check and no journal, and deletes permanently "without prompt". macontrol follows F-0012 and F-0036 instead. Keep the background, cancellable, live-bytes UX idea. |
| Trash via trash-rs (Finder osascript per path) | ignore | `Byron/trash-rs@v5.2.5 src/macos/mod.rs` | Use `FileManager.trashItem` directly. There is no need for an Automation grant or a process per item. |
| Snapshot format and `dua diff` | study | `src/snapshot/`, `src/diff.rs` | A streaming, checksummed tree format is a useful model for a scan cache and a "what grew since last week" view. It does not store dev/ino, so it cannot drive incremental rescans. |
| TUI, i18n, flame graphs, Windows module | ignore | `src/interactive/widgets/`, `crates/dua-lib/src/windows.rs` | Not relevant to a native macOS GUI. The keyboard-first marking flow is worth a look for power users. |

MIT permits copying and porting with the copyright notice kept. A Swift port of dua-core should credit "dua-cli (c) 2019 Sebastian Thiel, MIT" in THIRD_PARTY_NOTICES, and T-0003 should record it.

## Open questions

1. Under load (load average ~16 on this 8-core M1), how many directories does the probe move to per-entry `lstat`, and is that slower? Checking needs `fs_usage` (root) or an instrumented build. I am handing this to T-0004.
2. How much wall time does one `lstat` per directory cost against asking for `ATTR_DIR_*` in the bulk call? `research/bench/bulkwalk.c` could measure it, since the fixture has 10,505 directories.
3. Is the fixed 8 macOS threads right for macontrol's workload? The history went 3 → 8, and T-0004 should sweep 2-12 workers.
4. The double count on `dua /` (F-0031 class) is not verified. I did not run it because of the load.
5. Clone re-counting on `r` refresh with `--deduplicate-apfs-clones` is code-read only. My pty harness passes fixed arguments.
