# dumac (healeycodes/dumac): source deep dive

Task T-0030 · label `dive-healeycodes-dumac` · 2026-09-23 · clone `research/sources/healeycodes-dumac` @ `1ffbe3c` (gitignored)
Probes: `research/bench/healeycodes-dumac/` (`run_probes.sh`, `results.txt`, `cmn_error_probe.c`, hyperfine JSON). Finding filed: **F-0060**.

## Facts

| | |
|---|---|
| URL | https://github.com/healeycodes/dumac |
| Description | "Very fast alternative to 'du -sh' for macOS that uses getattrlistbulk." |
| License | **None.** `gh api repos/healeycodes/dumac` gives `license: null`, `/license` returns 404, and there is no LICENSE file in the tree. All rights reserved: **we may study ideas only, never copy code.** |
| Stars / forks / open | 63 stars, 5 forks, 1 open item (PR #7), from `gh api repos/healeycodes/dumac` on 2026-09-23 |
| Created / last commit | 2025-07-31 / `1ffbe3c` 2025-08-07 ("add second blog post link"). 20 commits in total, all within 8 days. |
| Language | Rust 2021, one file: `src/main.rs` (353 lines). Dependencies: `libc 0.2.174`, `parking_lot 0.12.4`, `rayon 1.10.0` (`Cargo.toml:6-9`). |
| Other files | `tests/integration_tests.rs` (124 lines), `setup_benchmark.py` (benchmark tree generator), `previousattamps/` (4 earlier Go versions), `flamegraph.svg` |
| Maturity | A blog-post experiment. Nobody has merged anything since 2025-08-07. Six outside PRs (#1, #3, #4, #5, #6, #7, dated 2025-08-04 to 2026-08-04) are all unmerged (`gh api .../pulls/N` `merged_at: null`). There is no CI (no `.github/`) and no release binaries (`gh release list` is empty). |
| Blog posts | [Maybe the Fastest Disk Usage Program on macOS](https://healeycodes.com/maybe-the-fastest-disk-usage-program-on-macos), [Optimizing My Disk Usage Program](https://healeycodes.com/optimizing-my-disk-usage-program) |

## Summary

dumac is a 353-line CLI that prints one number: the allocated size of a folder, as `du -sh` would. It runs one `getattrlistbulk(2)` loop per folder on a rayon work-stealing pool, and deduplicates hard links through a global sharded `HashSet<u64>` of inode numbers. It has no UI, no deletion, no per-child output, no progress and no cancellation.

**Speed checks out, and ties dua.** On our shared fixture (311k inodes), dumac took 0.670 s ± 0.061 s, against 0.722 s for dua, 1.325 s for diskus and 6.58 s for BSD du. That is 1.98x diskus (the README claims 3.26x) and 9.8x du (the README claims 5.66x). On ~/projects (single run) it took 2.34 s against 2.63 s for dua.

**Robustness is weak.** Every defect we found under stress fails silently, with exit 0. The worst is a hard abort, with no output, on any tree nested 127 levels deep.

For macontrol, dumac is a clean, measured statement of the fast path: bulk attributes, one folder per task and work stealing. It is also a checklist of what that fast path must not skip.

## Architecture

- **Single binary, no layers.** `main` (`src/main.rs:108-141`) builds a rayon pool and calls `calculate_size(root)` inside `pool.install`. `calculate_size` (`:144-186`) calls `get_dir_info` (`:188-353`), sums the files it returned, and recurses into subfolders with `into_par_iter()`. The output is `format_size` (`:69-103`), a du `-h` string with one decimal place. There is no byte, JSON or per-child output.
- **No engine/UI split**, because there is no UI. `calculate_size` is `pub` so that the tests can `#[path = "../src/main.rs"] mod main;` it (`tests/integration_tests.rs:7-10`). The hard-link state is a process-wide `static` (`:37-38`), so the walker cannot run twice in one process without `clear_seen_inodes()` (`:44-50`, `#[cfg(test)]` only).
- **History** (`previousattamps/`, blog 1): Go goroutines (6.8 s), then Go + cgo `getattrlistbulk` (`fastestgoversion/lib.h`), 0.56 s. Go `RawSyscall6` (`gosyscall/main.go:93`) was slower than cgo. Then Rust + Tokio (0.52 s), and finally Rust + rayon (blog 2: 910 → 712 ms and about 80 % fewer context switches, 1.2M → 235k, measured in Instruments).

## Scanning

- **API.** `open(path, O_RDONLY)` on the full path string (`:190-191`), then `getattrlistbulk` into a 128 KiB buffer that lives on the stack (`:218`, `:222-231`). The request is `ATTR_CMN_RETURNED_ATTRS | NAME | ERROR | OBJTYPE | FILEID` plus `ATTR_FILE_ALLOCSIZE` (`:204-216`). It asks for no `LINKCOUNT`, no `ATTR_DIR_MOUNTSTATUS`, no clone ID and no flags.
- **Parsing** (`:247-343`) uses `unsafe read_unaligned`, driven by the returned-attributes bitmap. **It reads `ATTR_CMN_NAME` before `ATTR_CMN_ERROR`.** The man page puts ERROR first: "The ATTR_CMN_ERROR attribute will be after ATTR_CMN_RETURNED_ATTRS attribute in the returned buffer" (`man getattrlistbulk`, lines 85-86 and its example at 237-248). Verified: `research/bench/healeycodes-dumac/cmn_error_probe.c` races `/dev/fd` and got 39,132 error entries out of 937,680, each with `returned.commonattr = 0xa0000001` and the error word before the name reference. Read in dumac's order, an EBADF (9) entry named "48" becomes "error 3" with 7 garbage name bytes. The entry is still skipped, so totals are unaffected, but the messages are wrong. The same order is in the C version (`previousattamps/fastestgoversion/lib.h:89-97`).
- **Concurrency.** A rayon pool with `min(available_parallelism, 224)` threads (`:118-122`) and 16 MiB stacks (`:123-128`). Parallelism is per folder: `subdirs.into_par_iter()` (`:162-180`). The files of one folder are summed serially by the thread that listed it. The blog says lock time was about 1.5 % of the profile and syscalls about 91 %.
- **Sizes.** The size is `ATTR_FILE_ALLOCSIZE` ("bytes on disk used by all of the file's forks", `man getattrlist`), rounded up to 512-byte blocks (`:64-66`, `:316-325`). Folders count 0 (`:326-331`). Devices, FIFOs and sockets count 0 (`:336-338`). **Symlinks are hard-coded to 1 block, 512 B** (`:332-335`), but APFS reports 0 for them. Open PR #7 fixes this, with 3,556 symlinks = 1.7 MiB of over-count on `/usr/share`. **APFS clones count at full size**, as in du (class of F-0004). There is no apparent-size mode.
- **Hard links.** `check_and_add_inode` (`:53-61`) inserts **every** regular file and symlink into one of 128 `parking_lot::Mutex<HashSet<u64>>` shards, chosen by `(inode >> 8) % 128` (`:36-42`). Blog 2 reports that this cut lock collisions from 176.66 to 4.66 per run, compared with `inode % 128`. Those collisions are out of about 409,500 acquisitions, so they were never a bottleneck. On our fixture only 503 of 300,000 file entries are extra links (`research/bench/results/ground_truth.json`). With `ATTR_FILE_LINKCOUNT` requested in the same call, about 99.8 % of files would never touch the set. There is also a dead per-folder `all_inodes` Vec (`:148`, `:156`), which PR #5 removes.
- **The key is the inode alone, not `(dev, ino)`, and the walk crosses mount points.** Verified (`run_probes.sh` section 5): two fresh 40 MB APFS images mounted side by side both number their files from inode 16. `du -sk` counts 6,553,600 B, while dumac counts 3,276,800 B, so the whole second volume is dropped as "already seen". macontrol is already specified against this: `(st_dev, st_ino)` in F-0010's after, and never descending into a mount point in F-0031's after. We also checked that `(st_dev, st_ino)` is unique across the System and Data volume group. Both have `st_dev` 16777229, but System-volume inodes sit at 1152921500311xxxxxx (for example `/bin/ls` = 1152921500312571391), while Data inodes are small (for example `/Users` = 26305).
- **Paths.** A full path is built per folder with `Path::join(..).to_string_lossy()` (`:167-170`), then `open()` is called on it. Past PATH_MAX this fails with ENAMETOOLONG, which is reported as "Cannot access directory" and counted as 0. Verified: the fixture's `pathmax/` subtree is dropped (class of F-0008). The open uses no `O_DIRECTORY`, `O_NOFOLLOW` or `O_CLOEXEC`. A name that is not valid UTF-8 fails `from_utf8` (`:273`), and a folder with such a name is silently skipped (`:328-330`). APFS rejects such names (`mkdir b'bad\xff'` → EILSEQ, verified), so this can only happen on other file systems. That part is unverified.
- **Errors.** Every open or list failure becomes `Err`, then 0 bytes (`:173-179`), and the process exits 0 (`:132-135`). A listing that fails after `open()` succeeded **leaks the fd** (`:233-243` returns before the `close` at `:347-350`) and throws away the entries already read. A per-entry `ATTR_CMN_ERROR` is only printed. See **F-0060** (EMFILE and the leak) and F-0057 (the class of "unreadable shows as 0 B").
- **Memory model.** No tree is kept. The memory in use is the running sums, one `DirInfo` (files Vec plus subfolder names) per folder level still active, the global inode set (O(files), all files), and **128 KiB of stack per active nesting level**. `get_dir_info` is inlined into the recursive `calculate_size`, whose prologue reserves `sub x9, sp, #0x20, lsl #12` (128 KiB) (`otool -tV` on our release build). Measured max RSS: a flat folder 2.0 MB, a 100-level chain 14.8 MB, a 126-level chain 18.1 MB. The fixture took 42.9 MB against 11.2 MB for dua (T-0004 results), and ~/projects took 59.2 MB against 17.9 MB for dua.
- **Depth limit (verified, `run_probes.sh` section 2).** A single chain of **127 nested folders aborts the process**: "thread '<unknown>' has overflowed its stack", SIGABRT (exit 134), and no total at all. 126 levels work, and this is deterministic across 3 of 3 runs. This is the class of F-0044 (GrandPerspective, 3,500 levels at 512 KiB). Here it is the scanner, and it fails 27x shallower. With short names, 127 levels is only about 254-1,000 bytes of path, well below PATH_MAX, so F-0008's fd-relative walk alone would not prevent it.
- **Progress / cancellation.** None. It is a CLI, so Ctrl-C kills it.

### Measured on this Mac (M1, 8 GB, macOS 26.6, load average 17 → 12 during runs)

| Target | dumac | dua 2.45 | diskus 0.9 | du (BSD) | bulkwalk (serial) |
|---|---|---|---|---|---|
| Fixture, hyperfine `-N --warmup 1 --runs 5` | 670 ms ± 61 (user 79 ms, sys 1.91 s) | 722 ms ± 68 | 1,325 ms ± 139 | 6,582 ms ± 196 (3 runs, separate invocation) | 6,204 ms ± 140 |
| Fixture total (ground truth 2,368,040,960) | 2,360,152,064, 3 of 3 stable, exit 0 | 2,359,623,680 (T-0004) | n/a | 2,359,623,680 (T-0004) | n/a |
| Fixture max RSS | 42.9 MB | 11.2 MB (T-0004) | 17.7 MB (T-0004) | n/a | n/a |
| ~/projects, 1 run, `/usr/bin/time -l` | 2.34 s, 59.2 MB, 33,452,641,280 B | 2.63 s, 17.9 MB, 33,450,483,712 B | n/a | n/a | n/a |

dumac's fixture total is du's total plus 528,384 B, which is 1,032 symlinks × 512 B. Its symlink over-count therefore hides 6 % of the PATH_MAX under-count (8,417,280 B). The raw files are `research/bench/healeycodes-dumac/fixture-hyperfine.json` and `fixture-du-hyperfine.json`. The README's benchmark (a 12-level binary tree with 409,500 small files, warm cache, M1 Pro per blog 1) has no hard links, symlinks, errors or deep chains, so none of the failure paths above ever run in it.

## Deletion & rules

None. dumac only measures. It has no cleanup targets, rule files, trash, privilege escalation or dry-run.

## UI

None. It prints one line, `<du -h size>\t<path>`, to stdout and errors to stderr. It takes one root argument; PR #1, which would allow several roots, is unmerged. There is no JSON, no byte output, no per-child breakdown, and no `-x`, exclude or apparent-size option.

## Tests & quality

- There are three integration tests (`tests/integration_tests.rs:12-125`), and `cargo test --release` passes all 3. The build took 7.5 s, using rustup installed into the scratchpad only.
  - `test_nested_directories` asserts only `total_blocks >= 2` (`:71-73`). A 5-byte file already takes 8 blocks, so the test would pass even if subfolder traversal were broken.
  - `test_hardlink_deduplication` is a real test.
  - All tests clear the shared global `SEEN_INODES` (`:15, :47, :79, :108`), and cargo runs tests on parallel threads, so one test can clear the set in the middle of another's scan. This is a latent flake that we did not see.
- There are no tests for symlinks, errors, fd limits, deep trees, mount points or per-entry errors, and there is no CI.
- Code quality: the code is compact and readable, with unsafe parsing that trusts `entry_length`. Minor issues: `is_dot_or_dotdot` (`:105-107`) is dead in practice, because bulk reads never return `.` or `..`; release builds have `debug = true` (`Cargo.toml:15-16`); and `MAX_FILE_HANDLES` is a thread cap named as an fd cap.
- The outside PRs are useful signals. #3 and #5 say "six workers was fastest on the repository's deep and wide macOS benchmark fixtures" (unverified here). #4 dropped an FSEvents cache after finding "an FSEvents history-delivery race that could briefly return stale totals" (compare F-0017 and F-0037).

## Known problems

| # | Problem | Evidence | Status |
|---|---|---|---|
| 1 | Abort at 127 nesting levels: a 128 KiB stack buffer per recursion level on 16 MiB stacks | `:218`, `:123-125`; `run_probes.sh` §2; `otool` prologue | verified; evidence posted to F-0044 (T-0023) |
| 2 | EMFILE turns into a 0 B subtree; a failed listing leaks its fd; exit 0; totals vary between runs | `:191-201`, `:233-243`, `:173-179`; issue #2; `run_probes.sh` §3-4 | verified, **F-0060** |
| 3 | Subtrees past PATH_MAX are dropped (and ENAMETOOLONG is reported as "Cannot access directory") | `:167-191`; fixture `pathmax/` | verified, class of F-0008 |
| 4 | Hard-link key is the inode without the device, and the walk crosses mounts: a second volume is dropped | `:37-61`; `run_probes.sh` §5 | verified, covered by F-0010/F-0031 afters |
| 5 | Symlinks counted as 512 B each | `:332-335`; PR #7; +528,384 B on the fixture | verified, low impact, not filed |
| 6 | ATTR_CMN_ERROR parsed after NAME, against the man page | `:261-294`; `cmn_error_probe.c` | verified layout; only diagnostics are wrong; not filed |
| 7 | Unreadable folders show as 0 B, with exit 0 | `:173-179`, `:132-135` | class of F-0057 |
| 8 | Every file goes through the global mutex set; no LINKCOUNT; the set grows with O(files) | `:53-61`, `:151-159` | code read; small cost (blog: about 1.5 %) |
| 9 | Clones counted at full size | `:316-325` (ALLOCSIZE only) | class of F-0004 |

## Reuse table

No license, so every row is ideas only. "study" means we adopt the idea in our own code; nothing is copied.

| Component | Decision | Paths | Reason |
|---|---|---|---|
| One folder = one task, parallel `getattrlistbulk` on a work-stealing pool | study | `src/main.rs:118-186` | Measured as fast as dua on our fixture (0.67 vs 0.72 s) with half dua's user CPU. This is the shape F-0009 asks for. Re-implement as an explicit work queue (no recursion) in Swift. |
| The bulk attribute request | study | `:204-216` | Correct minimal set for allocated size. macontrol adds `ATTR_FILE_LINKCOUNT`, `ATTR_DIR_MOUNTSTATUS`, and the `ATTR_CMNEXT_*` clone attributes (F-0004, F-0031), and parses ERROR right after RETURNED_ATTRS. |
| Bulk read buffer | rewrite | `:218` | 128 KiB on the stack of a recursive function sets the 127-level depth limit and about 128 KiB of RSS per level. Use one heap buffer per worker, reused across folders. |
| Sharded inode set with `(inode >> 8) % N` | study | `:19-61`; blog 2 | The locality idea is fine, but it fixes a contention problem that a `nlink > 1` filter removes (503 of 300,000 entries on the fixture). Key by `(dev, ino)`, give ownership by F-0054's LCA rule, and keep no global static. |
| Thread cap as fd protection (`MAX_FILE_HANDLES = 224`) | rewrite | `:16-17`, `:118-122` | A constant tuned for a 256 soft limit. Use a `getrlimit`-derived fd budget and retry on EMFILE (F-0060). |
| Error handling (Err → 0, exit 0) | rewrite | `:173-179`, `:191-243` | See F-0060 and F-0057. |
| Full-path `open()` per folder | rewrite | `:167-191` | Use fd-relative `openat` (F-0008). |
| Symlink = 1 block | ignore | `:332-335` | Wrong on APFS. Use ALLOCSIZE for every non-folder (as PR #7 does). |
| `format_size` du `-h` output | ignore | `:69-103` | Not useful for an app. |
| Benchmark tree generator | study | `setup_benchmark.py` | The "deep" (12-level binary, 409,500 files) and "wide" shapes are cheap perf regression shapes. Our fixture (`research/bench/make_fixture.sh`) is a superset for correctness. |
| Profiling method (Instruments System Trace, context-switch counts, lock-collision counting) | study | blog posts 1-2 | A good template for macontrol's own engine tuning. Record context switches next to wall time. |
| Earlier Go versions | ignore | `previousattamps/` | Historical. Only useful for the finding that raw syscalls from Go were slower than cgo. |
| Tests | ignore | `tests/integration_tests.rs` | Too weak to port. The fixture and ground truth from T-0004 are stronger. |

## Open questions

1. Does a TCC denial (no Full Disk Access) fail at `open()` or at `getattrlistbulk()`? If it is the latter, dumac leaks one fd per protected folder, and macontrol's walker must expect EPERM mid-listing. Unverified: this terminal has FDA, so it needs the ad-hoc `.app` probe from T-0010.
2. Worker count: outside PRs #3/#5 claim 6 workers beat all-cores on their fixtures. We did not measure this on the 8-core M1. macontrol's bench should sweep 2-8 workers (F-0009's "how" already asks for a serial baseline).
3. Cold-cache behaviour was not measured (no `sudo purge`). The blog asserts that warm and cold results correlate on Apple SSDs; that is unverified.
4. The README's 3.26x/5.66x speed-ups came from the author's M1 Pro and tree. On ours we got 1.98x/9.8x. du's larger gap here fits the vnode-cache limit noted in T-0004 (`kern.maxvnodes` 120,350 against about 311k inodes).
5. How deep do real trees get on users' Macs? We did not measure it (a full walk of ~/projects was skipped because of the machine's load). The 127-level abort only matters for pathological trees, such as runaway copy loops or the SMB symlink cycles cited in F-0044, but a scanner should never lose the whole result to one of them.
