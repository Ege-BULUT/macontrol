# Source deep dive: parallel-disk-usage (pdu)

Task T-0031 · dive-ksxgithub-parallel-disk-usage · 2026-09-23 · clone `research/sources/KSXGitHub-parallel-disk-usage` @ `c30e46f` (the path is case-insensitive, so `ksxgithub-parallel-disk-usage` resolves to the same directory). All `file:line` citations refer to that commit. The checks ran the Homebrew build `pdu 0.24.0` (arm64, `/opt/homebrew/bin/pdu`) on macOS 26.6, M1, 8 GB, on a machine under load (load average 3-16). There is no cargo here, so nothing was built from source.

## Facts

| | |
|---|---|
| URL | https://github.com/KSXGitHub/parallel-disk-usage (fork=false, homepage crates.io/crates/parallel-disk-usage) |
| License | Apache-2.0 (`LICENSE`, `Cargo.toml:8`; there is no NOTICE file) |
| Stars | 732 (`gh api repos/KSXGitHub/parallel-disk-usage`, 2026-09-23) |
| Last commit | `c30e46f`, 2026-08-09, "ci(benchmark): update dua from 2.34 to 2.41.1 (#454)". Last push 2026-09-14. Latest release 0.24.0, 2026-05-28 |
| Language | Rust 2024 edition, toolchain 1.97.1 (`rust-toolchain`), about 14.3k lines including 6.6k lines of integration tests |
| Activity | 9 contributors. 12 open issues and 9 open PRs. Created 2021-05-16 |
| Release assets | Only `pdu-x86_64-apple-darwin` is provided for macOS (issue #135 asks for arm64). Homebrew builds its own arm64 bottle |

What the license permits: Apache-2.0 lets us copy, modify and ship code in a closed or MIT app, provided we keep the license text and state our changes. Because macontrol is Swift, only algorithms, test scenarios and the benchmark design transfer. Those are ideas, not code, so no notice is needed, but crediting pdu in the acknowledgements costs nothing.

## Summary

pdu is a read-only CLI that scans one or more paths in parallel and prints a Unicode bar chart of the tree. It can also export the tree as versioned JSON and re-render it later. There is no deletion, no cleanup rules and no GUI. It is useful to macontrol for four things:

1. A compact, generic **fork-join tree builder** on rayon. It prunes the tree below `--max-depth` while it builds, so memory stays bounded (`src/tree_builder.rs:41-70`).
2. The **most thoroughly tested hard-link accounting** of the engines studied: a (dev, ino) record with nlink, per-subtree deduplication, and a summary that separates links inside the tree from links outside it (`src/hardlink/*`, `tests/hardlinks_deduplication*.rs`, about 1,950 lines of tests).
3. A **cheap progress model**: atomic counters plus a 100 ms sampler thread.
4. A **published, reproducible benchmark pipeline** that runs on every release and includes a self-regression gate. This is the model the discovery note pointed to for T-0004.

Its weaknesses, all verified here: an unreadable folder looks exactly like an empty one (F-0057). A firmlink alias of a root makes `-H` panic (F-0058). With `-H`, sorting and the 1% cutoff use sizes from before deduplication (F-0059). Hard links are double-counted by default (F-0010). Paths longer than PATH_MAX are dropped silently (F-0008). Clones are ignored (class of F-0004). On the fixture it is about 1.9x slower than dua, because it makes a full-path `lstat` call for every entry.

## Architecture

- **Crate layout.** One library crate `parallel_disk_usage` (`src/lib.rs`) and small binaries in `cli/` (pdu, completions, man page, USAGE.md generator, AI-instructions sync). The engine and the output are separate modules, so the library can be embedded without the CLI (`Cargo.toml` features `cli` and `json`).
- **Engine.**
  - `tree_builder.rs` is generic over `Path`/`Name`/`Size` and two closures, `get_info` and `join_path`.
  - `fs_tree_builder.rs` plugs the real filesystem into it.
  - `data_tree/*` holds the in-memory tree with parallel `sort`, `retain` and `hardlink` passes.
  - `hardlink/*` holds the (dev, ino) record and the deduplication pass.
  - `get_size.rs` has three size getters: apparent, block size and block count.
- **Output.** `visualizer/*` renders the text chart. `json_data/*` provides the JSON export and import (with `schema-version` "2026-04-02" and the binary version). `reporter/*` and `status_board.rs` handle progress and error lines on stderr.
- **App layer.**
  - `app.rs` picks one of 12 monomorphised pipelines (size getter × progress × hard links) through a macro, so the hot path has no dynamic dispatch (`src/app.rs:64-70, 323-378`).
  - `app/sub.rs` runs the scan, then cull, sort and dedup, then prints.
  - `app/hdd.rs` limits the scan to 1 thread on rotational disks.
  - `app/overlapping_arguments.rs` removes duplicate roots when `-H` is given.
- **Process tooling.** `AGENTS.md`, `CLAUDE.md` and `.github/copilot-instructions.md` hold agent instructions. `dylint.toml` configures custom "perfectionist" lints, and most recently closed issues (#410-#444) are about that lint tooling. `test.sh` runs fmt, clippy, build, test and doc across feature combinations.

## Scanning

- **APIs.** The scan uses `std::fs::read_dir` for names and `std::fs::symlink_metadata(full_path)` for every entry (`src/fs_tree_builder.rs:12, 105, 134`):
  - It keeps only `file_name()` from each directory entry (`:157`). The directory handle and `d_type` are discarded.
  - Each child is later stat'ed by a full `PathBuf` built with `prefix.join(name)` (`:167`).
  - So every entry costs one kernel path lookup from the root, instead of an fd-relative `fstatat` or a `getattrlistbulk` batch.
  - Consequences: paths longer than 1024 bytes fail and are dropped (F-0008), and the scan pays extra kernel time. On the shared fixture pdu took 1.33 s (4.62 s sys) against dua's 0.70 s (2.08 s sys). On ~/projects, pdu `-H` took 2.81 s (10.0 s sys) against dua's 1.88 s (5.98 s sys) (research/reports/bench-scan-engines.md:66-69, 99). I did not isolate the full-path cost from other effects.
- **Concurrency.** Rayon fork-join. Each directory's child names go into `into_par_iter().map(TreeBuilder::from)`, recursively (`src/tree_builder.rs:53-62`), so work stealing balances wide and deep trees with no explicit queue. Thread count is `--threads auto|max|N`. `auto` drops to 1 thread when any root is on an HDD (`src/app.rs:186-204`). On macOS that check never fires: pdu's own comment says sysinfo reports `DiskKind::Unknown` there (`src/app/hdd.rs:135-139`). IOKit does expose the medium type: `ioreg -r -c IOBlockStorageDevice` shows `"Medium Type"="Solid State"` on this Mac, and the keys are `kIOPropertyMediumTypeKey`, `...RotationalKey` and `...SolidStateKey` (SDK `IOKit/storage/IOStorageDeviceCharacteristics.h:606, 634, 662`).
- **Recursion depth.** Stack use grows with folder depth, and open issue #243 reports a stack overflow on Linux. On macOS, PATH_MAX caps the walk first. A 511-level chain of 1-character names (the deepest that fits in a 1024-byte relative path) scanned without a crash here. A walker without the PATH_MAX cap, such as macontrol's fd-relative one, needs an explicit work queue (class of F-0044).
- **Sizes.**
  - Default quantity on Unix is `block-size` = `st_blocks * 512` (`src/args/quantity.rs:24`, `src/get_size.rs:26-37`). The options are `apparent-size` (`st_size`) and `block-count`.
  - Directories count their own inode size (`DataTree::dir`, `src/data_tree/constructors.rs:7-14`). On APFS that is 0 blocks, but 10.6 MB of apparent size on the fixture (bench report line 88).
  - APFS clones are not detected. The README lists "Ignorant of reflinks" as a limitation (class of F-0004).
  - iCloud dataless files: open issue #225 ("shows incorrect size for files stored on cloud") was never resolved. The maintainer has no Mac. Unverified.
- **Hard links (opt-in `-H`).**
  - Recording: every non-directory with `nlink > 1` goes into `HardlinkList`, a `DashMap<(ino, dev), {size, links, paths: Vec<PathBuf>}>` (`src/hardlink/aware.rs:60-92`, `src/hardlink/hardlink_list.rs:52-175`).
  - Conflicts: a size or nlink change between two links of the same inode returns an error, which the caller drops with `.ok(); // ignore the error for now` (`src/fs_tree_builder.rs:124-128`). That link is then simply not recorded.
  - Correction happens after the scan, top-down. At each node, the groups with 2 or more link paths under that node are kept by `strip_prefix`, and the node subtracts `size × (links_in_subtree − 1)` (`src/data_tree/hardlink.rs:16-44`). The result has du semantics: each folder counts each inode once, whatever the walk order, so it is deterministic (compare F-0054). A folder holding one link of an inode still counts the full size, even though deleting it frees 0 (compare F-0047's lowest-common-ancestor rule).
  - Performance: the pass hands every child, including files, the parent's whole group list, so a wide folder costs children × groups × links. Measured with N same-folder link pairs, `--json-output`, 1 run each: N = 1k/2k/4k/8k took 0.14/0.53/1.94/7.89 s of user CPU, about 4x per doubling. Without `-H` it took 0.03 s (`research/bench/ksxgithub-parallel-disk-usage/repro.sh quadratic`). On the real ~/projects tree (62 shared inodes, 576 links) the pass is invisible (4.15 s with `-H` vs 4.08 s without), so I did not file this. Recorded under Known problems.
  - Ordering: this pass runs **after** cull and sort (`src/app/sub.rs:134-138`). See F-0059.
  - Summary: the report separates inodes whose links are all inside the tree ("exclusive") from inodes linked from outside it (`src/hardlink/hardlink_list/summary.rs`). It **panics** when the filesystem shows more paths than nlink (`:91-95`). See F-0058.
- **Progress and cancellation.** Every entry does two `fetch_add(Relaxed)` calls on shared `AtomicU64`s (items, total). A dedicated thread samples them every 100 ms and rewrites one stderr line (`src/reporter/progress_and_error_reporter.rs:39-107`, `progress_report_state.rs:9-54`, `src/app.rs:279-283`). There is no current-path display and no ETA. Cancellation means killing the process.
- **Memory model.**
  - A node is `{name: OsString, size: u64, children: Vec<Self>}` (`src/data_tree.rs:25-29`). There are no parent pointers, and the full path exists only while the node is being built.
  - Nodes below `--max-depth` (default 10) are summed and dropped while the tree is built (`src/tree_builder.rs:64-69`). This moved from the visualizer into the builder in v0.12.0 after #277 (killed with out-of-memory at 63M-351M entries).
  - Measured on the shared fixture (311.5k entries, short names), 1 run each: keeping the whole tree (`-d 200 --min-ratio 0.5`) peaked at 30.7 MB footprint and 38.5 MB RSS, against 6.6 MB and 14.3 MB at `-d 1`. That is about **77 B per node** including names. Radix measured 943 B per node (F-0041).
  - Each directory's name list comes from `read_dir().collect()` with no size hint. The maintainer notes it can hold about 2x the needed capacity until it is dropped (#277 comments).

## Deletion & rules

None. pdu never modifies the filesystem: no delete, no trash, no cleanup targets, no privilege escalation, no dry run. The only "rules" are the display filters `--max-depth`, `--min-ratio` (default 0.01) and `--no-sort`. An exclude option was requested (#86, #134) and declined "to follow the UNIX philosophy". The workaround is to pass the roots explicitly (#134).

## UI

- A terminal chart only. Each row shows the size, a box-drawing tree, a proportion bar in four shades (█▓▒░) and a percentage (`src/visualizer/*`, `proportion_bar.rs:16-20`). The layout can be bottom-up (default) or `--top-down`, with left or right bar alignment, and the width comes from the terminal size or `--total-width`/`--column-width`.
- There is no interaction: no drill-down, selection or reveal in Finder. "Drill into a folder" means running the scan again on that path.
- `--json-output` / `--json-input` let you scan once and render many times. The JSON is versioned (`schema-version`, `pdu`, `unit`, `tree`, optional `shared` hard-link details). `--json-input` re-applies depth, ratio and sort (#420 fixed that). The JSON has no error or state field (F-0057), and the export panics on non-UTF-8 names (`src/app/sub.rs:153-156`). That panic cannot happen on APFS, which rejects such names with EILSEQ (checked here).
- Large trees: the default 1% cutoff and depth 10 keep the chart short. With `--min-ratio 0`, a 300k-entry tree prints 300k lines.

## Tests & quality

- 120 `#[test]` functions across 21 integration files and unit tests. CI runs on ubuntu, windows and macos-latest (`.github/workflows/test.yaml:11-19`). The sync tests check that help text, the man page, completions and USAGE.md match the code.
- Hard-link coverage is the best of the engines studied. `tests/hardlinks_deduplication.rs` has 6 scenarios: internal links, external links, mixed, exclusive-only, external-only, and a complex shared/unique tree. There are also multi-argument and without-dedup suites. Two gaps let F-0059 through: every test re-sorts the output by name (`:60`) and passes `--min-ratio=0` (`:454, 680, 891, 1020, 1187`). No test covers a root reached by two spellings (F-0058).
- The error test `tests/cli_errors.rs:120-190` asserts only the stderr lines and the library's own rendering. It never asserts the exit status or that the node is marked (F-0057).
- Code style is strict and consistent: typed errors via derive_more, no `unwrap` in non-test code as a rule (`AGENTS.md`), and generic "capability" traits for testing without a real disk (`src/app/hdd.rs:20-61`). The genericity costs readability, for example 12 monomorphised pipelines built by a macro.
- The maintainer has no Mac: "I don't have a MacBook" (#134) and "I don't have a Mac, so I can't reproduce this bug" (#225). macOS-specific behaviour (TCC, firmlinks, clones, dataless files) has never been designed for.

## Benchmark pipeline (model for T-0004)

- **When it runs.** The `competing_benchmark` job in `.github/workflows/deploy.yaml:497-700` runs only on releases, on `ubuntu-latest`, after every other job, "in a quiet environment". It pins versions of dust, dutree, dua, ncdu, gdu and GNU du.
- **The sample.** The Linux v5.12 source zip, plus `ci/make-tree-with-hardlinks.sh`: 20 inodes with 1-50 links each.
- **Competing benchmark.** `ci/github-actions/competing-benchmark.ts` runs `hyperfine --warmup=1` for each category (`apparent-size`, `block-size`, `deduplicate-hardlinks`), with each competitor given the flags for the same semantics (`benchmark/matrix.ts`).
- **Self benchmark.** 48 categories (quantity × depth × min-ratio × progress × no-sort, `matrix.ts:1-38`), run against the pinned previous release. `check-for-performance-regressions.ts` fails CI when any category is more than 10% slower (`ACCEPTABLE_PERFORMANCE_REGRESSION = 1.1`).
- **Publishing.** Reports ship as `benchmark-reports.tar.gz` release assets, with an attestation, and as per-release repos (`KSXGitHub/parallel-disk-usage-{0.5.2,0.8.1,0.10.0,0.12.0,0.20.0}-benchmarks`).
- **Worth copying:** the regression gate against the last release, a matrix of flag combinations, pinned competitor versions, and published raw reports.
- **Missing:** it is Linux only, so it says nothing about APFS. It never checks totals, so a faster but wrong run passes (compare the T-0004 lesson on `total_stable_across_runs`). Its hard-link tree has 20 inodes, too small to show the quadratic pass. It is warm-cache only.

## Known problems

- **F-0057** (new, verified): an unreadable folder shows as 0 B with no children, the same as an empty one, with no flag in the tree or JSON and exit code 0. Issue #134's TCC errors were answered with "use --silent-errors".
- **F-0058** (new, verified): `X` plus `/System/Volumes/Data/X` passes the realpath overlap check, sizes double, and `-H` panics (`nlink (3) < detected paths (6)`) with exit 101 and 0 bytes of JSON. `pdu -H /` probably hits the same panic, because `/` holds both firmlinks and their Data-volume paths. That part is inferred and was not run.
- **F-0059** (new, verified): with `-H`, sort and `--min-ratio` use pre-dedup sizes, so the order is wrong and a 1.2% file is hidden.
- **F-0010**: hard links are counted once per link by default (+16% on the fixture).
- **F-0008**: subtrees past PATH_MAX are dropped, and pdu exits 0.
- Class of **F-0004**: clones are counted at full size.
- Class of **F-0031**: `-x` compares `st_dev`, which cannot tell the System volume from the Data volume (`src/fs_tree_builder.rs:84-97, 120-121`, `device_id.rs:13-16`).
- Not filed: the quadratic `-H` pass (see Scanning). It is measured on a synthetic tree but negligible on real trees here.
- Not filed: a conflicting link is dropped silently (`src/fs_tree_builder.rs:128`).
- Not filed: the HDD thread cap is a no-op on macOS.
- Open issues: #277 (out-of-memory on a 300 TB volume, partly fixed by depth pruning), #243 (stack overflow on deep trees, Linux), #225 (cloud files, unresolved), #134 (macOS TCC errors), #86/#55 (exclude/filter, declined).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Fork-join tree builder (closures `get_info`/`join_path`, recursive `into_par_iter`) | study | `src/tree_builder.rs:41-70` | A clear, minimal model of a recursive parallel walk. macontrol's walker is fd-relative with `getattrlistbulk` and an explicit queue (F-0008, F-0009, F-0044), so the structure is rewritten in Swift, but the "per-directory task, aggregate on return" shape carries over. |
| Filesystem adapter (`read_dir` + full-path `symlink_metadata`) | rewrite | `src/fs_tree_builder.rs:62-172` | It discards the dir fd and `d_type`, pays one full path lookup per entry, fails past PATH_MAX (F-0008) and drops errors (F-0057). |
| Node layout `{name, size, children}` with no stored path | take (idea) | `src/data_tree.rs:25-29` | About 77 B per node measured, including names. Add a state field (F-0057) and a parent index for reveal and delete. A compact arena as in F-0016/F-0041 is still better. |
| Depth-bounded retention (sum below depth, drop nodes) | take (idea) | `src/tree_builder.rs:64-69` | Gives bounded memory for a quick-overview or menu-bar mode that needs totals, not the full tree. |
| (dev, ino) hard-link record with nlink | improve | `src/hardlink/hardlink_list.rs:52-175`, `src/hardlink/aware.rs:60-92` | The key and the nlink capture are right, and a lock-sharded map suits parallel walkers. Store node ids instead of `PathBuf`s, count conflicts instead of `.ok()`-dropping them, and never panic (F-0058). |
| Per-subtree dedup pass | rewrite | `src/data_tree/hardlink.rs:16-44` | Its deterministic du semantics are good, but it filters by path prefix per child (4x cost per doubling of groups) and runs after sort and cull (F-0059). Use F-0047's lowest-common-ancestor rule through parent pointers, applied during aggregation. |
| "Exclusive vs external links" summary | take (idea) | `src/hardlink/hardlink_list/summary.rs` | Maps directly to the badge "linked elsewhere: deleting frees 0" (F-0010, F-0047). Drop the panic. |
| Progress: atomic counters plus a 100 ms sampler | take (idea) | `src/reporter/progress_and_error_reporter.rs:39-107`, `.../progress_report_state.rs` | Cheap and lock-free. macontrol adds per-worker counters (no shared cache line), a sampled current path and cooperative cancellation. |
| Typed error report `{operation, path, error}` | improve | `src/reporter/error_report.rs`, `src/reporter/event.rs` | A good shape, but it must be stored on the node and summarised in the UI, not only printed (F-0057). |
| HDD concurrency cap | take (idea) | `src/app.rs:186-204`, `src/app/hdd.rs` | Right idea. On macOS use IOKit `kIOPropertyMediumTypeKey` ("Rotational"), which sysinfo does not (`hdd.rs:135-139`). |
| Overlapping-root removal | rewrite | `src/app/overlapping_arguments.rs:54-107` | Right intent, wrong identity: a realpath string prefix misses firmlinks (F-0058, F-0039). Compare (dev, ino) of the roots and their ancestors. |
| Versioned JSON export and re-render (`--json-output/--json-input`) | study | `src/json_data*.rs`, `src/app.rs:73-170` | Scanning once and viewing many times, with an explicit schema version, suits macontrol's scan cache and export. Add node state, keep it private (F-0045), and do not require UTF-8 round-trips. |
| Hard-link test scenarios and `SampleWorkspace` fixtures | take (test cases) | `tests/hardlinks_deduplication.rs`, `tests/hardlinks_deduplication_multi_args.rs`, `tests/hardlinks_without_deduplication.rs`, `tests/_utils.rs` | Port the 6 scenarios as macontrol fixtures, and add the gaps: display order, cutoff, alias roots and more paths than nlink. |
| Release benchmark pipeline | take (idea) | `.github/workflows/deploy.yaml:497-700`, `ci/github-actions/benchmark/matrix.ts`, `ci/github-actions/check-for-performance-regressions.ts`, `ci/make-tree-with-hardlinks.sh` | Copy the regression gate against the last release (10%), the flag matrix, pinned competitors and published reports into T-0004. Add total checks, APFS and a larger hard-link tree. |
| Text chart visualizer | ignore | `src/visualizer/*` | Terminal output. macontrol is a GUI. |
| CLI, completions, man page and AI-instruction generators | ignore | `src/args.rs`, `cli/`, `src/man_page.rs`, `src/usage_md.rs` | Not relevant. |

## Open questions

1. Does `pdu -H /` panic on macOS, as the code suggests (F-0058)? It needs a full-disk scan. It was not run on this loaded machine.
2. How much of pdu's ~2x system time over dua comes from full-path lookups, as opposed to `read_dir` + `lstat` versus `getattrlistbulk`? A single-thread C probe comparing `lstat(fullpath)` with `fstatat(dirfd, name)` on the fixture would answer it. That belongs to T-0006/T-0004.
3. How often do wide folders hold many hard-link groups on real Macs (pnpm stores, rsnapshot or `cp -al` backups, HFS+ Time Machine disks)? ~/projects here has 62 shared inodes. This decides whether the quadratic pass matters in practice. For macontrol it is moot if the lowest-common-ancestor rule is used.
4. #225: how are iCloud dataless files counted in block-size mode? Unverified. It is relevant to F-0019 (SF_DATALESS).
