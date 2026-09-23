# Scan engines benchmark: du, gdu, dua, dust, pdu, ncdu, diskus

Board task T-0004 (owner: bench-harness). Harness: `research/bench/make_fixture.sh` and `research/bench/run.sh`. Raw data: `research/bench/results/`. Run date: 2026-09-23.

## Summary

- **Fastest and correct on what it can see: dua-cli 2.45.0.** It took 0.70 s on the 300k-file fixture and 1.88 s on ~/projects, with the lowest CPU of the parallel tools (2.2 s user+sys) and 11 MB RSS. It reads metadata with `getattrlistbulk` on macOS, and it is the only tool here that can count APFS clones once (`--deduplicate-apfs-clones`).
- **Only ncdu got the exact ground-truth total.** ncdu walks with directory fds (`openat`/`fstatat`). Every other tool, du included, silently skips a subtree whose absolute path is longer than PATH_MAX (1024 bytes). ncdu's default of one thread made it the slowest tool (8.3 s). With `-t8` it took 1.47 s.
- **gdu's non-interactive total is nondeterministic.** Identical warm runs returned totals up to 27 MB (1.2%) below its own correct value, differently each time, with exit 0. That is up to 34 MB below ground truth once the PATH_MAX loss is added. On ~/projects one of three runs was 520 MB short. The code points to a race in its home-made WaitGroup (F-0007).
- **pdu double-counts hard links by default** (+370 MB, +16% on the fixture), and **dust double-counts them in apparent-size mode**.
- **The warm cache is not really warm on this Mac.** `kern.maxvnodes` = 120,350 on the 8 GB M1, well below the fixture's ~311k inodes and ~/projects' ~469k entries. Single-threaded walkers spend 68-79% of their wall time off-CPU even on repeat runs (du 1.23 s CPU in 5.88 s, ncdu 2.68 s in 8.27 s). Parallelism is what hides that, which is the main reason the parallel tools are 3.4-12x faster than du and ncdu.
- **A plain serial fd-relative `getattrlistbulk` walker (bulkwalk, ~80 lines of C) matches ground truth exactly** and uses 2.6 MB RSS, but at 7.1 s it is as slow as the other serial tools. Correctness comes from walking relative to the directory fd; speed comes from parallelism.
- **Asking APFS for `ATTR_CMNEXT_PRIVATESIZE|CLONEID|EXT_FLAGS` is not free** (question from T-0009). Serially, kernel CPU went up 61-70%: +0.78 s sys on the fixture and +2.17 s on ~/projects. Wall time went up 12% on the fixture and 64% on ~/projects. The numbers are right, though. On the fixture, the summed private size (1,446,752,256) equals the clones-counted-once total minus the shared extents, to the byte.
- **For macontrol's engine:** do an fd-relative walk with `getattrlistbulk` on a bounded worker pool. Count (dev, ino) once in every mode, use `ATTR_CMNEXT_CLONEID` for clones, and fold the tree bottom-up so a total only ever comes from a finished tree. Target: dua's speed with ncdu's correctness.

## Setup

| | |
|---|---|
| Machine | Apple M1, 8 cores, 8 GB, macOS 26.6 (25G72), APFS, `kern.maxvnodes` 120,350 |
| Load | Other agents were running during the benchmark. The load average was 15-18 during the fixture pass, 10-14 during the real-tree pass and 11-15 during the bulkwalk subset. Absolute times are noisy, and ratios are more trustworthy. |
| Cache | Warm only: 1 hyperfine warmup plus 5 timed runs (`hyperfine -N -i`). A cold-cache pass needs `sudo purge`, which this run did not have, so it was not measured. |
| CPU and RSS | user and sys are hyperfine means. Max RSS and peak footprint come from a separate `/usr/bin/time -l` run. |
| Totals | Each tool ran 3 more times untimed to record its reported total, and "same total" compares those runs. The bulkwalk subset on ~/projects used RUNS=3 REPEAT=2 to stay inside the 20-minute budget. |
| Versions | du from macOS 26.6 `/usr/bin/du`, gdu 5.37.0, dua-cli 2.45.0, dust 1.2.6, pdu 0.24.0, ncdu 2.9.2, diskus 0.9.0, hyperfine 1.20.0 (all Homebrew bottles, arm64_tahoe) |

Commands (`{}` = root). All run in disk-usage (allocated blocks) mode, with each tool's own thread default:

| name | command |
|---|---|
| du | `du -sk {}` |
| gdu | `gdu-go -n -p -s --no-prefix {}` |
| dua | `dua -f bytes aggregate {}` |
| dua-apfs-clones | `dua -f bytes --deduplicate-apfs-clones aggregate {}` |
| dust | `dust -d 1 -c -P -b -o b {}` |
| pdu / pdu-H | `pdu [-H] -d 1 -b plain {}` |
| ncdu / ncdu-t8 | `ncdu --ignore-config -0 [-t8] -o /dev/null {}` (totals come from a JSON export run) |
| diskus | `diskus {}` |

## Fixture

`make_fixture.sh` builds the tree deterministically (fixed seed) in about 33 s. A `FORCE=1` rebuild reproduced every count and byte total in ground_truth.json exactly. The tree has 300,000 file entries (299,497 inodes), 10,505 dirs and 1,032 symlinks. It holds 7.30 GB apparent and 2.37 GB allocated by `st_blocks`, and about 1.74 GB is physically on disk once clones are counted once. Contents:

- wide trees: one dir with 20k files, plus 200 dirs × 400 files
- bushy tree: 4^6 leaf dirs × 30 files
- 1,500 node_modules-like packages
- a 120-level deep chain
- a `pathmax/` chain whose path exceeds 1024 bytes, with an 8 MiB file at the bottom
- 8 `.app` bundles with versioned framework symlinks, plus `.photoslibrary` and `.xcassets` dirs
- 280 MiB of real big files and 5 GiB of sparse files (1 MiB allocated)
- APFS clones (`cp -c`): 3 full clones of 160 MiB, 1 clone with 1 MiB rewritten, 100 small clones
- 503 extra hard links, including 3 to a 120 MiB file
- 1,000 file symlinks, a 2-link loop, `..` and `.` loops, a dangling link and a link outside the tree
- a chmod-000 dir with 100 files and a chmod-000 file
- unicode and hostile names: NFC/NFD, emoji, ZWJ, RTL, newline, tab, leading dash, 254-byte name

Ground truth comes from a Python `os.fwalk` + `lstat` pass (fd-relative, so it reaches `pathmax/`), taken before the dir is locked. It is in `results/ground_truth.json`. A non-root scanner should report `visible_to_non_root.allocated_all` = **2,368,040,960 bytes**. The value with clones counted once is 1,739,624,448 bytes.

### Results: fixture (warm)

| tool | wall mean ± sd (s) | CPU user + sys (s) | max RSS (MB) | disk total (MB) | Δ vs truth (MB) | same total, 3 runs | exit |
|---|---|---|---|---|---|---|---|
| dua-apfs-clones | 0.69 ± 0.06 | 0.16 + 2.03 | 11.1 | 1,856.0 | -512.1 | yes | 1 |
| dua | 0.70 ± 0.08 | 0.16 + 2.08 | 11.2 | 2,359.6 | -8.4 | yes | 1 |
| diskus | 1.21 ± 0.03 | 0.28 + 5.38 | 17.7 | 2,359.6 | -8.4 | yes | 0 |
| pdu | 1.33 ± 0.12 | 0.24 + 4.62 | 14.2 | 2,738.5 | +370.4 | yes | 0 |
| dust | 1.38 ± 0.06 | 0.38 + 4.39 | 155.0 | 2,359.6 | -8.4 | yes | 0 |
| ncdu-t8 | 1.47 ± 0.11 | 0.11 + 4.05 | 14.0 | 2,368.0 | +0.0 | yes | 0 |
| pdu-H | 1.70 ± 0.34 | 0.25 + 4.69 | 14.6 | 2,359.6 | -8.4 | yes | 0 |
| gdu | 1.73 ± 0.57 | 0.56 + 5.01 | 36.5 | 2,333.6 | -34.5 | **no**: 2,333.6 / 2,359.6 / 2,335.4 | 0 |
| du | 5.88 ± 0.05 | 0.04 + 1.19 | 8.0 | 2,359.6 | -8.4 | yes | 1 |
| bulkwalk | 7.10 ± 0.02 | 0.01 + 1.27 | 2.6 | 2,368.0 | +0.0 | yes | 1 |
| bulkwalk-ext | 7.94 ± 0.06 | 0.01 + 2.05 | 2.6 | 2,368.0 | +0.0 | yes | 1 |
| ncdu | 8.27 ± 0.21 | 0.08 + 2.60 | 2.4 | 2,368.0 | +0.0 | yes | 0 |

`bulkwalk` / `bulkwalk-ext` is the harness's own serial, fd-relative `getattrlistbulk` walker (`research/bench/bulkwalk.c`, about 80 lines), described under "Baseline" below. They exit 1 because of the locked dir.

### Correctness against ground truth (fixture)

| tool | disk total − truth | why |
|---|---|---|
| ncdu, ncdu-t8 | **0** | fd-relative walk reaches `pathmax/`. Hard links counted once. Every APFS clone counted at full size, which is also what the ground truth's `allocated_all` does. |
| du, dua, diskus, dust, pdu-H | −8,417,280 | Everything below the PATH_MAX boundary in `pathmax/` is missing. du and dua exit 1 and print an error. diskus, dust and pdu exit 0 (diskus hides the error unless `-v`). |
| gdu | −34,471,936 on run 1. Totals over 3 runs: 2,333.6 / 2,359.6 / 2,335.4 MB | `pathmax/` is missing, plus a nondeterministic under-count from a race. 5 earlier manual runs gave 2,332.4 to 2,359.6 MB. |
| pdu (default) | +370,421,760 | Hard links are counted once per link unless `-H` is given, and `pathmax/` is missing. |
| dua-apfs-clones | −512,053,248 | The 3 fully shared 160 MiB clones (503,316,480) and 100 small clones (319,488) are counted once, and `pathmax/` is missing. The partially rewritten clone (119 MiB still shared) is counted in full, as documented ("fully shared" only). Against the clones-once truth it is +124,780,544, which is exactly that partial clone. |

Apparent size (the ground truth counts files only): diskus and gdu match the truth once `pathmax/` is excluded. dua, pdu-H and ncdu add about 10.6 MB of directory `st_size`. `du -A -k` rounds each entry up to 1 KiB, which adds 57.9 MB. dust `-s` and pdu without `-H` count hard links every time (+380 MB).

Other edge cases all passed. No tool followed the symlink loops or hung on them, or counted the 5 GiB of sparse files at logical size in disk mode. The unicode names and the chmod-000 dir were handled the same way by every tool. The locked dir's 100 files are invisible to all of them as non-root, and each tool flags or ignores it quietly. dust at `-d 0` printed **nothing** (exit 1) when the tree contained the >PATH_MAX path, so the harness uses `-d 1`.

## Results: real tree (~/projects, read-only, warm)

| tool | wall mean ± sd (s) | CPU user + sys (s) | max RSS (MB) | disk total (MB) | same total, 3 runs | exit |
|---|---|---|---|---|---|---|
| dua | 1.88 ± 0.09 | 0.51 + 5.98 | 18.1 | 30,860.8 | yes | 1 |
| dua-apfs-clones | 1.92 ± 0.16 | 0.55 + 6.27 | 22.2 | 27,717.6 | yes | 1 |
| diskus | 2.52 ± 0.08 | 0.62 + 12.44 | 19.3 | 30,861.0 | yes | 0 |
| pdu-H | 2.81 ± 0.22 | 0.53 + 10.00 | 13.7 | 30,860.8 | yes | 0 |
| gdu | 2.82 ± 0.10 | 1.33 + 11.76 | 37.4 | 30,340.5 | **no**: 30,340.5 / 30,860.8 / 30,860.8 | 0 |
| ncdu-t8 | 2.85 ± 0.10 | 0.28 + 9.57 | 26.2 | 30,861.0 | yes | 0 |
| dust | 3.00 ± 0.30 | 0.89 + 10.07 | 220.2 | 30,860.8 | yes | 0 |
| pdu | 3.11 ± 0.24 | 0.55 + 10.15 | 13.6 | 31,171.6 | **no**: 31,171.6 / 31,171.6 / 31,171.7 | 0 |
| bulkwalk | 11.41 ± 0.26 | 0.04 + 3.12 | 2.1 | 30,880.0 | yes | 1 |
| du | 12.62 ± 0.97 | 0.14 + 4.20 | 3.7 | 30,796.3 | **no**: 30,796.3 / 30,861.8 / 30,861.8 | 1 |
| ncdu | 15.16 ± 1.13 | 0.20 + 5.94 | 2.2 | 30,861.0 | **no**: 30,861.0 / 30,861.0 / 30,861.0 | 0 |
| bulkwalk-ext | 18.74 ± 0.17 | 0.04 + 5.29 | 2.1 | 30,880.0 | yes | 1 |

There is no ground truth here. The tree was being written to by other agents during the run (repo clones under `macontrol/research/sources`), so tools that ran later see slightly more bytes. The fixture dir was chmod 000 during this pass so it did not count, and every tool therefore saw one unreadable dir.

- **Parallel tools cluster at 1.9-3.1 s, serial ones at 11-19 s** for 469k entries. The ranking matches the fixture: dua first, du and ncdu (1 thread) last.
- **The gdu race shows up here as well.** Its first run came in 520 MB short (30,340.5 vs 30,860.8 MB), while every other tool's repeated runs moved by at most 0.1 MB.
- **Drift, not tool error, explains the small differences.** The "no" for pdu and ncdu is drift under 0.1 MB. bulkwalk's +19 MB is drift too: run back to back after the pass, dua and bulkwalk both reported exactly 30,934,523,904 bytes. du's first run was 65 MB low. It was the first scan of the pass and its later runs agree, so this is probably drift, but that is unverified.
- **pdu without `-H` over-counts hard links by 311 MB.**
- **`dua --deduplicate-apfs-clones` finds 3.14 GB (10%) of ~/projects is fully shared APFS clone data** that every other tool counts twice. The clone-aware accounting of F-0004 matters on real developer trees, not just on synthetic ones.
- **dust peaks at 220 MB RSS** here, against 14-37 MB for the others.

## How each tool walks (the tricks)

Line numbers refer to the shallow clones in `research/sources/<slug>` at the commit given. The installed Homebrew versions may differ slightly from HEAD.

| tool (stars, license) | enumeration + metadata | parallelism | hard links | APFS clones | > PATH_MAX |
|---|---|---|---|---|---|
| **du** (macOS `/usr/bin/du`; apple-oss-distributions/file_cmds @659a8a301e; Apple source license, `gh api` reports none) | `fts_open(FTS_PHYSICAL \| FTS_NOCHDIR)` (du/du.c:165-168, 330). Apple's fts reads each dir with **`getattrlistbulk`** (apple-oss-distributions/Libc gen/fts.c:757 @71bbe350ab) | 1 thread | `linkchk()` on (dev, ino) (du.c:126) | counted in full | fails: NOCHDIR means full-path access, "File name too long" |
| **gdu** 5.37.0 (dundee/gdu @848a5dd; 5,999★; MIT) | `os.ReadDir(path)` + `DirEntry.Info()` = `lstat` per entry on a full path (pkg/analyze/parallel_top_dir.go:172, 183, 208) | goroutine per dir, semaphore `2*GOMAXPROCS`, runs inline when full (parallel.go:13, parallel_top_dir.go:191-201) | `sync.Map` keyed by **inode only** (not dev) when nlink > 1 (parallel_top_dir.go:236-239, dir_unix.go:15-16) | counted in full | fails |
| **dua-cli** 2.45.0 (Byron/dua-cli @cf59618; 6,292★; MIT) | `open(path, O_DIRECTORY)`, then **`getattrlistbulk`** with a 64 KiB buffer (crates/dua-lib/src/macos/mod.rs:27, 325-329, 369). Switches to parallel stat when bulk refills are I/O-bound (CHANGELOG.md 2.45.0) | crossbeam worker pool (crates/dua-lib/src/lib.rs:381-382), default = logical CPUs (`dua --help`) | `InodeFilter` on (dev, ino) (src/inodefilter.rs:7-13) | opt-in: `ATTR_CMNEXT_CLONEID` + `ATTR_CMNEXT_EXT_FLAGS` (crates/dua-lib/src/macos/attributes.rs:55-56). A stream is counted once per (dev, clone_id) (src/inodefilter.rs:172-215), fully shared clones only | fails: the open uses the full path |
| **dust** 1.2.6 (bootandy/dust @ae5c770; 12,292★; Apache-2.0) | `fs::read_dir` + metadata by path (src/dir_walker.rs:220, 275) | rayon scope (dir_walker.rs:114-115) | (inode, dev) set, **disk mode only** (dir_walker.rs:134-139) | counted in full | fails |
| **pdu** 0.24.0 (KSXGitHub/parallel-disk-usage @c30e46f; 732★; Apache-2.0) | `read_dir` + `symlink_metadata(path)` (src/fs_tree_builder.rs:12, 105, 134) | rayon `into_par_iter` (src/tree_builder.rs:7, 54) | **opt-in** `-H` (src/args.rs:112-114) | counted in full | fails |
| **ncdu** 2.9.2 (code.blicky.net/yorhel/ncdu @v2.9.2; not on GitHub; MIT, LICENSES/MIT.txt) | **`fstatat(parent.fd, name)`**, and dirs opened relative to the parent fd (src/scan.zig:49-52, 242) | N threads with a LIFO queue (scan.zig:100-113). **Default 1** (src/main.zig:83) | (dev, ino) when nlink > 1 (scan.zig:65) | counted in full | **works** |
| **diskus** 0.9.0 (sharkdp/diskus @90196e9; 1,246★; Apache-2.0 OR MIT) | `symlink_metadata` + `read_dir` on a PathBuf (src/walk.rs:92, 113) | rayon pool of **3 × cores**, capped at 64 (walk.rs:165-174, 245). No tree kept, only a total | (dev, ino) when nlink > 1 (src/unique_id.rs:8-19) | counted in full | fails |
| **bulkwalk** (this harness, `research/bench/bulkwalk.c`) | `openat(parentfd, name)` + **`getattrlistbulk`**, names only, no full paths | 1 thread (baseline) | fileid set when nlink > 1 | `-x` reads PRIVATESIZE / CLONEID / EXT_FLAGS | **works** |

## Baseline: bulkwalk and the cost of the APFS extended attributes

`research/bench/bulkwalk.c` is the smallest walker that does what the table above says macontrol should do. It opens each directory with `openat(parentfd, name, O_DIRECTORY|O_NOFOLLOW)` and reads it with `getattrlistbulk` into a 256 KiB buffer (common: NAME, OBJTYPE, FILEID; file: LINKCOUNT, ALLOCSIZE). It counts hard links once by fileid and recurses only after a directory's listing is finished, so one buffer serves every level. It is serial on purpose, to isolate the syscall path from parallelism. `-x` adds `forkattr = ATTR_CMNEXT_PRIVATESIZE|ATTR_CMNEXT_CLONEID|ATTR_CMNEXT_EXT_FLAGS` with `FSOPT_ATTR_CMN_EXTENDED`, the attribute set T-0009/F-0004 want for "frees now".

| | fixture wall | fixture sys | ~/projects wall | ~/projects sys |
|---|---|---|---|---|
| bulkwalk | 7.10 s | 1.27 s | 11.41 s | 3.12 s |
| bulkwalk -x | 7.94 s (+12%) | 2.05 s (+61%) | 18.74 s (+64%) | 5.29 s (+70%) |

- Both variants hit fixture ground truth exactly (2,368,040,960) and report the same total, the `pathmax/` subtree included. That is the fd-relative walk working.
- On the fixture, `-x` sums private bytes to 1,446,752,256. That is exactly the clones-counted-once total (1,739,624,448) minus the extents shared by clones: 3 × 160 MiB full clones counted once, the partial clone's 119 MiB, and the small clones' 319,488 bytes. So PRIVATESIZE behaves the way F-0004 assumes, partial clones included.
- The +64% wall time on ~/projects comes from a serial walk, where the extra kernel work sits on the critical path. In a parallel walk the kernel CPU cost (+61-70%) is what remains, so request these attributes lazily (see above) or measure them again inside the parallel engine.
- Serial bulkwalk took 7.10 s on the fixture against du's 5.88 s, even though both read through `getattrlistbulk`. Under this load that gap is not explained: it could be noise, buffer size, or fts's own work. Either way it confirms that a serial walker cannot beat the parallel ones, whatever syscall it uses.

## Memory

For 300k files, max RSS was 8 MB for du, 11 MB for dua, 14-18 MB for pdu, ncdu-t8 and diskus, 36 MB for gdu and **155 MB for dust**. ncdu with `-o` streams its export and keeps no tree (2.4 MB). On ~/projects (469k entries) dust peaked at 220 MB and the rest at 2-37 MB. These numbers do not compare fairly with an app that must keep the whole tree for a treemap. Most of these modes keep no full tree: ncdu `-o` streams, gdu `-n` keeps only top-level totals (pkg/analyze/parallel_top_dir.go:18-21) and diskus keeps only a total. dust builds its whole tree. Budget macontrol's in-memory tree by measuring it on this fixture, not by these figures.

**Harness gotcha:** hyperfine 1.20's `memory_usage_byte` is the max RSS over *all* children reaped so far (`RUSAGE_CHILDREN`). In one multi-command hyperfine invocation, every command after dust "used" 160.9 MB. run.sh therefore takes RSS from `/usr/bin/time -l` only.

## What macontrol should take from this

1. **Walk fd-relative.** `openat(parentfd, name, O_DIRECTORY|O_NOFOLLOW)` plus `getattrlistbulk(fd)`, with names instead of full paths in the tree, like ncdu. Only ncdu got the fixture right, and paths longer than PATH_MAX are legal. See finding "Full-path walkers silently drop subtrees deeper than PATH_MAX".
2. **Parallelize with a bounded pool.** On an 8 GB Mac even rescans miss the vnode cache. Serial walks were 8.4x (du) and 11.8x (ncdu) slower than dua, and ncdu itself got 5.6x faster with `-t8`. dua's pool size (logical CPUs) was the best measured here. diskus's 3×cores did not beat it on this warm run.
3. **Get the total from a finished tree.** Every directory job is registered before dispatch and parents fold their children's results. Never read a shared counter at a barrier, which is the gdu bug. Keep a determinism test: the same total on 20 runs.
4. **Count (dev, ino) once in every mode, and mark shared bytes.** Hard links count once. For APFS clones, `ATTR_CMNEXT_CLONEID` gives fully shared clones (dua's approach). `ATTR_CMNEXT_PRIVATESIZE` covers partial sharing as well: on the fixture, the sum of private sizes is exact (see "Baseline: bulkwalk and the cost of the APFS extended attributes"). Because it costs +61-70% kernel CPU, fetch it lazily: per selection, or in a second pass after the map is drawn. Do not fetch it in the first-paint walk. T-0009 and F-0004 own the semantics.
5. **Flag incomplete subtrees** (EACCES, ENAMETOOLONG, cancelled) in the UI. No tool here does more than print to stderr or set a `!` flag, and three of them exit 0.

## Findings filed (analysis board)

- **F-0007** (high, bug): gdu non-interactive totals are nondeterministic (WaitGroup race).
- **F-0008** (high, bug): full-path walkers silently drop subtrees deeper than PATH_MAX (du, gdu, dua, dust, pdu, diskus).
- **F-0009** (medium, perf): serial walkers are latency-bound even when warm (ncdu defaults to 1 thread, du).
- **F-0010** (low, bug+ux): hard links counted once per link (pdu default, dust apparent size). F-0004 covers clones.

## Not measured / unverified

- Cold cache, which needs `sudo purge`. Rerun with `sudo purge` before each run, WARMUP=0 and RUNS=1, repeated.
- gdu's interactive TUI and `-o` export use a different analyzer (`pkg/analyze/parallel.go`). 5 runs of `gdu -n -p -o file` over the fixture, which uses that analyzer, all gave 2,359,623,680, so the race is specific to the non-interactive `TopDirAnalyzer`. The TUI itself was not run.
- The gdu race cause is inferred from reading `pkg/analyze/wait.go` and `parallel_top_dir.go`. It was not instrumented.
- `getattrlistbulk` versus `fstatat` was not isolated. dua and du both use bulk reads, and du is slow for being serial, not for its syscall.
- Swift/ObjC scanners (GrandPerspective, DaisyDisk-like apps) were not benchmarked: they are GUI apps without a CLI. They belong to T-0006, and their engine can be added to TOOLS once extracted.

## Rerun

```
cd ~/projects/macontrol/research/bench
./make_fixture.sh          # builds once (~35 s, ~1.7 GB); FORCE=1 rebuilds
./run.sh                   # fixture + ~/projects; or ./run.sh fixture|real
RUNS=10 REPEAT=5 REAL_TREE=~/Library ./run.sh real
ONLY='^bulkwalk' TAG=bulkwalk ./run.sh fixture   # subset -> results/fixture-bulkwalk-*.json
```
To add a scanner, for example a macontrol engine build, add one `name|disk-usage cmd {}|apparent cmd {}` line to `TOOLS` in run.sh.
Total wall time of the recorded run: 11 min 30 s for `./run.sh both` (10 tool configurations) plus 5 min 15 s for the bulkwalk subset, 16.8 min in total.

Homebrew formulae installed for this benchmark: `diskus dua-cli dust gdu hyperfine ncdu parallel-disk-usage`, plus the dependency `ncurses`, which only ncdu uses. To remove them: `brew uninstall diskus dua-cli dust gdu hyperfine ncdu parallel-disk-usage ncurses`.
