# Source deep dive: Mole (tw93/Mole)

Task T-0012, researcher `dive-tw93-mole`, 2026-09-23. Clone: `research/sources/tw93-mole` at `a7fa8dd` (2026-09-23 12:48 +0800).
All paths below are relative to that clone unless marked otherwise. "Verified" means I ran it on this Mac. Everything else is from reading the code.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/tw93/Mole (homepage https://mole.fit) | `gh api repos/tw93/Mole` |
| License | GPL-3.0 (LICENSE file is GPLv3). The "Mole" name and logo are trademarks, and forks must be renamed. | `LICENSE:1-2`, `README.md:450-454`, `TRADEMARK.md` |
| Stars / forks | 68 136 / 2 400, watchers 155, not a fork, not archived | `gh api repos/tw93/Mole`, 2026-09-23 |
| Created / last push | 2025-09-23 / 2026-09-23T04:48Z. Latest release V1.55.0 (2026-09-20). | `gh api`, `mole:97` `VERSION="1.55.0"` |
| Languages | Shell 3.97 MB, Go 0.69 MB, Python 19 KB (per the `languages` API). Code: 49.5 k lines of shell (bin, lib, `mole`, `install.sh`), 12.8 k lines of Go plus 11.3 k lines of Go tests, 56 k lines of Bats tests. | `gh api repos/tw93/Mole/languages`, `wc -l` |
| Platform | macOS 12+, Intel and Apple Silicon. Bash 3.2 compatible. There is an experimental Windows branch. | `README.md:31,47` |
| Issues | 9 open out of about 1 612. The newest are mostly bugs in the separate proprietary Mac app. | `gh api repos/tw93/Mole/issues?state=open` |

**What the license lets us do:** study only. macontrol is not GPL, so no Mole code, and no Mole rule list copied verbatim, may go into it. File-system facts (for example "`~/Library/Caches/com.x` is a rebuildable cache") are not copyrightable. We can re-derive them and cite Mole as the checklist that pointed us to them. The native "Mole for Mac" app is a separate proprietary product (`README.md:19,454`) and is not in this repo.

## Summary

Mole is a terminal-first macOS maintenance toolkit. `mo` offers `clean`, `uninstall`, `optimize`, `analyze`, `status`, `purge`, `installer`, `touchid`, `history`, `update` and `remove` (`README.md:52-67`). Most of it is Bash. Only `analyze` (the disk explorer TUI) and `status` (the live dashboard) are Go binaries built on Bubble Tea.

Its main asset is not speed. It is a very large rule set, hardened by incidents and aimed at safe deletion:
- 490 `safe_clean` and 33 `safe_clean_guarded` target declarations.
- A layered deletion gate: path validation, protected roots and categories, a symlink-ancestor check, live-process and SQLite-in-use checks, a whitelist, and dry-run.
- Uninstall leftover discovery by bundle id and name variants, with a proven-absence sibling guard.
- A strict `AGENTS.md` / `SECURITY_AUDIT.md` safety contract, enforced by 1 957 Bats tests and 373 Go test, fuzz and benchmark functions.

Its weak spots for us:
- The `analyze` explorer keeps only the top 30 children of each directory (verified).
- The scan cache trusts one directory's mtime, so sizes stay stale for up to 7 days (verified).
- The live-cache safety gate only covers cache directories whose names look like bundle ids, and open issue #1607 shows what that costs.
- Cleanup is permanent `rm -rf` with no undo.
- It has no clone awareness, and file sizing is a min(allocated, logical) hybrid (already filed as F-0004 and F-0006).

## Architecture

- **The router, `mole`.** It parses arguments, draws the menu and dispatches to `bin/<cmd>.sh`. It contains no business logic (`AGENTS.md` "Repository Map"). It refuses to run as root (`mole:10-13`) and asks for admin rights per operation instead.
- **The shell engine, `lib/`:**
  - `lib/core/file_ops.sh` (3.8 k lines) is the only deletion funnel: `validate_path_for_deletion` (1089), `safe_remove` (1376), `safe_sudo_remove` (1887), `mole_delete` (2190, which routes to Trash and logs), `safe_find_delete` (3092) and `safe_sudo_find_delete` (3210).
  - `lib/core/app_protection.sh` (2.3 k lines) holds protection logic and uninstall discovery (`find_app_files` 954-1661, `find_app_system_files` 1728, `find_app_receipt_files` 2001).
  - `lib/core/app_protection_data.sh` holds data only: bundle-id arrays such as `SYSTEM_CRITICAL_BUNDLES` (19), `APPLE_UNINSTALLABLE_APPS` (163), `OFFICIAL_UNINSTALLER_RULES` (179), `ENDPOINT_SECURITY_BUNDLE_PREFIXES` (194) and `DATA_PROTECTED_BUNDLES` (207).
  - The cleanup rules live in `lib/clean/{user,app_caches,dev,caches,system,apps,brew,project,purge_shared}.sh`. `lib/uninstall/{batch,brew,steam}.sh` handles uninstall. `lib/optimize/{catalog,tasks,maintenance,diagnostics,outcomes}.sh` handles optimize, and `lib/core/sudo.sh` handles admin sessions.
- **Go, `cmd/analyze`** (Bubble Tea and lipgloss). `main.go` is the bootstrap, `model.go` holds the types, `update.go` holds the Update chain and key handling, and `view.go` renders. The rest: `scanner.go` (the engine), `live_scan.go` (streamed first paint), `cache.go` (a gob cache per subtree plus a JSON overview snapshot), `delete.go` (Trash routing and protected paths), `cleanable.go` (CACHEDIR.TAG detection) and `insights.go` (overview shortcuts). `mo analyze --json` reuses the engine without the TUI (`json.go:64`).
- **Go, `cmd/status`.** It uses gopsutil and reads `statfs` and `diskutil` (`metrics_disk.go:304-385`). The dashboard is read-only.
- **How UI and engine are split:** by process and language. Shell commands print their own ANSI output and use Bash menus (`lib/ui/menu_paginated.sh`, `app_selector.sh`). The Go analyzer is self-contained and never calls the shell rules. Some rules are therefore duplicated by hand across the two languages. For example, `endpointSecurityBundlePrefixes` in `cmd/analyze/delete.go:521-531` is a comment-declared "mirror" of `app_protection_data.sh:194`.

## Scanning (`mo analyze`)

- **APIs.**
  - `os.ReadDir` plus `DirEntry.Info()`, which is readdir followed by one `lstat` per entry (`scanner.go:232,475`). There is no `getattrlistbulk`, `fts` or `searchfs`.
  - "Folded" directories (`.git`, `node_modules`, venvs, `tmp` and others, `constants.go:77-209`) are sized by running `du -skPx` as a subprocess (`scanner.go:1006-1070`), with a 30 s timeout (`constants.go:20`).
  - Large files come from a Spotlight query, `mdfind -onlyin <root> "kMDItemFSSize >= 100MB"` (`scanner.go:25-27,738-814`). It replaces the walked top-20 list when it finds more (`scanner.go:541-550`).
- **Concurrency.** Goroutines limited by five semaphores: entry, dir, du, du-queue and fast (`scanner.go:84-135`). The worker caps are deliberately low (`maxWorkers=12`, `maxDirWorkers=6`, `constants.go:54-64`). Every goroutine blocked in a syscall holds an OS thread, and issue #765 ("failed to create new OS thread") crashed the scan. When the budget is used up, work falls back to inline recursion (`scanner.go:464-471,898-911`).
- **Size semantics.**
  - Files use `min(st_blocks*512, st_size)` (`scanner.go:1255-1266`, already filed as F-0006).
  - Folded dirs and the overview use `du`'s allocated KiB. Sibling rows in one list are therefore measured two ways, and `node_modules` or `.git` get block-rounded sizes while their neighbours do not.
  - Hardlinks are de-duplicated with a `(dev, ino)` `sync.Map` when `nlink>1` (`scanner.go:1239-1253`), but only in the main walker. The fallbacks `calculateDirSizeFastWithLimiter` and `calculateDirSizeConcurrent` call `getActualFileSize` without de-duplication (`scanner.go:715,920`).
  - There is no APFS clone or purgeable awareness (F-0004).
  - Symlinks are shown with a " →" suffix and counted at link size (`scanner.go:315-340`).
- **Skips.** At `/` the scanner skips `private`, `System`, `Volumes`, `.fseventsd` and others (`constants.go:211-233`, see F-0005). It always skips VM and container mounts by name (`defaultSkipDirs`, `constants.go:235-249`). `~/Library` is measured separately (`scanner.go:352-396`), and the Home overview measurement excludes it (`scanner.go:973-983`).
- **Progress and cancellation.** Atomic file, dir and byte counters, plus a `currentPath` `atomic.Value` sampled every 100 files (`scanner.go:683-685,932-935`) and shown on a 100 ms UI tick (`constants.go:67`). Cancellation runs through `context` plus `scanPublication`, a linearizable commit so that a cancelled scan cannot write cache side effects (`scanner.go:29-82`).
- **Memory model for huge trees.** No full tree is kept.
  - Each directory level keeps a top-N heap of entries (`maxEntries=30`, `constants.go:8`, `scanner.go:252-288`) and a top-20 large-file heap.
  - Subtree results are persisted as gob files under `~/.cache/mole/analyzer` (`cache.go:268-317,646-706`). A subtree is only admitted with at least 100 files or 10 MB, and the cache is capped at 5 000 entries and 50 MB (`constants.go:28-43`). The comment there records a real incident: the cache grew to 1.88 M files and 7.82 GB for one user before the caps existed.
  - Drilling down first loads from the disk cache, then from a stale cache (shown first, then refreshed), then runs a live scan (`update.go:75-102`).
- **Streaming first paint.** The live scan lists every child immediately, with directory sizes shown as pending (-1), then streams each child's total as it finishes. It has two live-sort modes, continuous and freeze-on-move (`live_scan.go:137-232`, `update.go:401-459,737-745`).
- **Two verified defects** (probe `research/bench/tw93-mole/zz_macontrol_probe_test.go`, `go test` inside the clone, 2026-09-23):
  1. **Top-30 truncation.** A directory with 45 subdirectories shows 45 rows while scanning and 30 after completion. 983 040 B are counted in the total but belong to no row (`live_scan.go:346-348`, `update.go:201-218`). The hidden rows cannot be drilled into, filtered, or deleted. Filed as a finding.
  2. **Stale cache.** A 12 MB file two levels deep was deleted after a scan. `scanCmd` still reported 12 582 912 B with `stale=false`. `loadCacheFromDisk` compares only the root directory's mtime, and within 24 h it even ignores that (`cache.go:585-621`, `constants.go:24-26`). `~/Library` inside a Home scan uses a JSON snapshot for up to 7 days without any freshness check (`scanner.go:359-363`, `cache.go:138-157`). `mo clean` and `mo purge` never invalidate the analyzer cache (`grep analyzer lib bin` finds nothing). Filed as a finding.

## Deletion and rules

- **Where the rules live.** Rules are shell calls, not data: `safe_clean <glob> "<label>"` spread over `lib/clean/*.sh`, for example `app_caches.sh:440-467` (editors) and `user.sh:983-1001` (Apple containers).
  - The generic `~/Library/Caches/*` sweep takes every top-level entry (`user.sh:156-205`, loop at 178).
  - Only the protection lists (`app_protection_data.sh`) and purge targets (`purge_shared.sh:18`: `node_modules target build dist venv .venv … DerivedData Pods .build`) are data arrays.
  - Optimize tasks sit in a catalog of aligned arrays (`lib/optimize/catalog.sh:21-30`).
- **The deletion gate, `validate_path_for_deletion`** (`file_ops.sh:1089-1300`), runs these checks in order:
  1. Path is non-empty, absolute, has no `..` component (but allows `name..files`) and no control characters.
  2. If the leaf is a symlink, its target must not be a critical path.
  3. If any ancestor is a symlink, the path is canonicalized and the deny checks run again (deny-only, and fork-free unless a link exists).
  4. An allow-exception for the coresymbolicationd cache, and a deny for the active powerlog database.
  5. A live reverse-DNS cache check (tri-state, "could not tell" means deny).
  6. SQLite family in-use (bounded `lsof`, fails closed), incomplete downloads with an open handle, and EDR caches.
  7. An allowlist under `/private`, then the critical-path deny, then `should_protect_path`.

  The gate runs twice, once when a target is found and again at the `safe_remove` sink. Callers can add a final guard (`_MOLE_SAFE_REMOVE_FINAL_GUARD`, `file_ops.sh:1643-1662`).
- **Trash vs rm.**
  - `safe_remove` ends in `rm -rf "$path"` (`file_ops.sh:1692`), which is permanent. `SECURITY_AUDIT.md:343` admits "Most cleanup flows do not provide undo."
  - `mole_delete` (uninstall) routes to Trash. Items that need root are staged through a root-owned folder under `/Library` and then moved into the user's Trash (`file_ops.sh:2603-2657`, `AGENTS.md` "Critical Safety Rules").
  - `mo analyze` always sends to Trash: `/usr/bin/trash` (macOS 15+), then `renameatx_np(RENAME_EXCL)` into `~/.Trash` or `/.Trashes/<uid>`, then Finder via AppleScript (`delete.go:127-299`). The rename fallback writes no Put Back metadata.
- **Privilege escalation.**
  - `sudo` with a keepalive loop (`sudo.sh:244-270`) and optional Touch ID PAM setup (`bin/touchid.sh`).
  - Admin deletes refuse a path when any ancestor can be changed by the invoking user (`file_ops.sh:1832-1886`).
  - There is no privileged helper or XPC. macontrol will need SMAppService plus a helper instead (see T-0011).
- **Protections.**
  - Critical roots.
  - Categories: keychains, password managers, VPNs, AI tools, OrbStack and Docker state, browser history and cookies, Apple group containers, iCloud `Mobile Documents` (`SECURITY_AUDIT.md:118-162`).
  - Endpoint-security vendors must use their own uninstallers, and their caches are never touched (`app_protection_data.sh:179-205`).
  - Shared XDG roots are never removed by name match (`SECURITY_AUDIT.md:234`).
  - Purge refuses directories that contain `*-keypair.json`, nested `.git`, or git-tracked files (`project.sh:516-527`, after incident #1551).
  - Artifacts touched in the last 7 days start unselected.
- **Uninstall.**
  - Apps are listed from `/Applications`, `~/Applications` and `/Volumes/*/Applications` (`bin/uninstall.sh:490-505`).
  - The live-root check also covers `/System/Applications`, Setapp and the Caskroom (`batch.sh:674-683`).
  - Apple apps that users installed themselves (Xcode, iWork, GarageBand, iMovie, Logic) can be removed. Core system apps are blocked (`app_protection.sh:120-133`, `app_protection_data.sh:19-176`).
  - Leftovers (`find_app_files`, 954-1661) are found through literal paths from the name and bundle id in about 30 `~/Library` subfolders, plus XDG paths.
  - Name variants cover spaces, hyphens, underscores, lower case and a stripped channel suffix such as Nightly or Beta. A bundle-leaf-derived name is used only if it extends the display name.
  - ByHost preferences, LaunchAgents with boundary-aware bundle-id matching (`base.sh:814-830`) and Group Containers are included.
  - System files and receipts come from `pkgutil`/BOM, with a payload allowlist (`app_protection.sh:2106`).
  - A sibling guard with three states keeps shared leftovers when another copy of the same bundle id might exist (`SECURITY_AUDIT.md:59`).
- **Dry run and history.** `MOLE_DRY_RUN=1` or `--dry-run` works for every destructive command, and targets are de-duplicated by `(dev, ino)`. `~/Library/Logs/mole/operations.log` gets one line per action, `[ts] [cmd] ACTION path (detail)` (`log.sh:214-233`). A tab-separated `deletions.log` is also written (`file_ops.sh:2183-2186`). `mo history` reads both.
- **Whitelist.** `~/.config/mole/whitelist` holds one absolute path or glob per line, with `~` and `$HOME` expanded. Traversal and system roots are rejected (`base.sh:362-452`). The whitelist is checked again at the `safe_remove` sink (`file_ops.sh:1428-1436`).

## UI

- **Analyze** is a TUI list with a 24-cell Unicode bar, a percentage and a size per row (`view.go`, `constants.go:10`). There is no treemap or sunburst. The overview shows Home, User Library, Applications, System Library and insight shortcuts such as iOS backups and "Old Downloads (90d+)" (`main.go:183-213`, `insights.go:17-145`).
- **Keys** (`update.go:593-916`):
  - arrows or `hjkl` to move, Enter or `l` to drill in, `h`/`b` to go back
  - `r` to rescan without the cache, `t` for the top-files view, `/` to filter
  - `s` for live sort, `o` to open, `f` to reveal in Finder (multi-select, at most 20), `p` for Quick Look
  - space to multi-select, Delete or Backspace to confirm a move to Trash
- **Cleanable marking.** Directories carrying a valid `CACHEDIR.TAG` signature, or with names such as `node_modules`, are marked cleanable (`cleanable.go:12-60`).
- **Performance on big trees.** First paint is immediate thanks to the streamed pending rows. After that, cost is bounded by the top-30 heaps and the caches, which also causes the truncation and staleness above. Search only covers the 30 kept rows.
- **Visual quality.** A good-looking terminal UI, but it cannot show a visual map.
- **The shell commands** use paginated Bash menus (`lib/ui/menu_paginated.sh`) with one-screen summaries, and skip reasons such as "◎ pnpm cache · skipped (pnpm busy)" (`README.md:137-165`).

## Tests and quality

- 64 Bats files with 1 957 `@test`s, 373 Go test, fuzz and benchmark functions, and a path-validation fuzz corpus (`tests/fuzz_corpus/`, `delete_fuzz_test.go` `FuzzValidatePath`).
- CI runs on macos-latest plus a macOS 14 and 15 matrix (`.github/workflows/test.yml:19,53`), with CodeQL, shellcheck and shfmt.
- `scripts/audit_destructive_sinks.py` fails the build on any raw `rm -rf` or `find -delete` that lacks a same-line `# SAFE: <reason>` annotation (`AGENTS.md` "Critical Safety Rules").
- Release integrity: SHA-256 checksums plus `gh attestation verify` at install time (`SECURITY_AUDIT.md:277-294`).
- Weaknesses:
  - A 5 k-line shell file (`lib/clean/dev.sh`).
  - Bash 3.2 constraints force string-encoded caches, for example "Process-state results are memoized … pipe-delimited string" (`file_ops.sh:168-170`).
  - Rule lists are duplicated by hand between Go and shell.
  - A very large number of timeout constants (`lib/core/timeouts.sh`). Closed issues #1570, #1576 and #1595 show a single probe timeout cancelling a whole `mo clean` run.
- **Durable knowledge from `AGENTS.md`**, valid for macontrol too:
  - Never machine-parse `plutil -p`. Its boolean rendering changed between macOS 15 and 26, and issue #1512 regressed for 8 days while CI stayed green.
  - Never auto-delete `/Library/Updates` or `/macOS Install Data`.
  - Never touch the active PowerLog `CurrentBackgroundProcessingDB.BGSQL` or its `-wal`/`-shm` files.
  - `lsregister -u` fails with `-10814` on macOS 15+ for apps that are already gone (`SECURITY_AUDIT.md:58`).
  - Optimize removed Dock resets (they reset the wallpaper, #995 and #1300) and font-cache rebuilds (`SECURITY_AUDIT.md:273-275`).

## Known problems (issues and code)

- **Open #1607:** the generic `~/Library/Caches/*` sweep deleted `GIPPseudonymousID` while Gemini was running. The result was an unthrottled write loop of about 200 GB/h. The same class as #1390 (Fusion 360 SQLite cache, closed). Root cause in code: the live-owner check only accepts directory names containing a dot (`file_ops.sh:207-211`). Filed as a finding.
- **Recent incidents that were fixed:**
  - #1551: purge deleted Solana keypairs, which could not be recovered.
  - #1594: clean deleted active Homebrew downloads.
  - #1590: an active Clash subscription was treated as an orphan (in the proprietary Mac app).
  - #1602: dry-run counted nested candidates twice.
  - #1549: an uninstall-time LaunchServices refresh killed a VPN extension.
  - #765: OS thread exhaustion during scans.

  The pattern: every new false positive gets a special-case rule after it happens.
- **Code problems:**
  - Top-30 truncation and stale cache (verified above).
  - Two different size metrics among siblings (du for folded dirs, min() for everything else).
  - Hardlink de-duplication missing in the fallback walkers.
  - Permanent `rm -rf` for cleanup.
  - The Trash rename fallback loses Put Back (`delete.go:181-209`).
  - Rule lists mirrored between Go and shell.

**Board records.**
- Findings filed from this dive:
  - F-0015: the live-cache check only covers reverse-DNS names.
  - F-0016: top-30 truncation.
  - F-0017: stale scan cache.
- The permanent `rm -rf` / no-undo problem duplicates F-0012 (PureMac). The Mole evidence is a comment on T-0013 instead of a new finding.
- The mixed-metric sibling sizing (du for folded dirs, `min()` for everything else) extends F-0006 and is noted on T-0012.
- Journal: M-0007.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Cleanup target catalog (≈523 `safe_clean*` rules) | study | `lib/clean/{user,app_caches,dev,caches,system}.sh` | The broadest known list of safe cache and log locations. GPL, so re-derive it as our own data file (JSON/plist rules with id, glob, owner bundle id, guard kind) and use Mole only as a checklist. |
| Protection data (critical bundles, data-protected apps, EDR vendors, Apple removable apps) | study | `lib/core/app_protection_data.sh:19-627`, `SECURITY_AUDIT.md:118-162` | Hard-won category knowledge. Re-express as a macontrol data file shared by the cleaner, the uninstaller and the visualizer's delete (one list, not two mirrors). |
| Layered deletion gate (validate twice, symlink-ancestor, fail-closed tri-state) | rewrite | `lib/core/file_ops.sh:1089-1300,1376-1750` | The design is right. Rewrite it natively in Swift as one `DeletionGate` that every delete goes through, working on file descriptors (`openat`/`O_NOFOLLOW`, `unlinkat`) instead of path strings to close the gap between check and delete. |
| Live-cache / SQLite in-use check | improve | `file_ops.sh:172-213,409-497,583-631,843-958` | Keep the idea. Extend it to every cache directory (not only reverse-DNS names), and use libproc (`proc_listpidspath` / `PROC_PIDLISTFDS`) plus `NSWorkspace.runningApplications` instead of forking `pgrep`/`lsof`. See the finding. |
| Uninstall leftover discovery (`find_app_files`, name variants, bundle-leaf rule, ByHost, LaunchAgents, Group Containers, receipts) | study → improve | `lib/core/app_protection.sh:954-2140` | The most complete open heuristics seen so far. Rebuild them natively. Add Spotlight `kMDItemCFBundleIdentifier`, a container-metadata owner (`.com.apple.containermanagerd.metadata.plist`) and team-id matching. |
| Shared-bundle sibling guard (proven absence, 3 states) | study | `SECURITY_AUDIT.md:59`, `lib/uninstall/batch.sh:669-690` | A good principle: absence has to be proven. |
| Official-uninstaller routing for EDR/MDM vendors | take (as a concept and a fact list) | `app_protection_data.sh:179-205` | Facts about vendors plus a policy. Re-express, don't copy. |
| Analyzer scan engine (readdir + lstat, `du` subprocesses, Spotlight large files) | ignore | `cmd/analyze/scanner.go` | Slower primitives than the planned `getattrlistbulk` engine (see T-0006/T-0004). Semaphore limits exist only because of Go's thread-per-blocked-syscall model. |
| Streaming first paint with pending rows and live-sort freeze-on-move | study | `cmd/analyze/live_scan.go:137-359`, `update.go:401-459` | Good UX pattern for our visualizer: show children at once and fill in sizes, with a freeze-on-move sort so rows don't jump under the cursor. |
| Analyzer on-disk cache (gob per subtree, mtime freshness) | rewrite | `cmd/analyze/cache.go` | Wrong freshness model (verified stale). Use FSEvents event IDs for invalidation. See the finding. |
| Trash routing (`trash(8)` → `renameatx` → Finder) | rewrite | `cmd/analyze/delete.go:127-299` | Natively, `FileManager.trashItem(at:resultingItemURL:)` keeps Put Back and needs no subprocess. |
| Analyze protected paths | study | `cmd/analyze/delete.go:314-460` | A useful list of paths to refuse in the visualizer (a `/Users/<other>` root, Docker and OrbStack state, `/opt/homebrew` itself). |
| CACHEDIR.TAG detection | take (concept, from the public spec) | `cmd/analyze/cleanable.go:12-60` | Cheap and standard (https://bford.info/cachedir/). Implement it ourselves from the spec. |
| Purge targets and project evidence (keypairs, nested `.git`, git-tracked files, 7-day recency) | study → improve | `lib/clean/purge_shared.sh:18-70`, `lib/clean/project.sh:516-527,576-720` | Good guards. We can size artifacts from our own scan tree instead of running `fd`/`find` again. |
| Operation log, deletions log, `history` | improve | `lib/core/log.sh:214-233`, `file_ops.sh:2183-2186,3051-3090`, `lib/core/history.sh` | Keep the audit trail, but as structured JSON Lines tied to an undo journal. |
| Whitelist file | improve | `lib/core/base.sh:362-452` | Same concept in our settings. Optional: import `~/.config/mole/whitelist` for users switching from Mole (reading a user's file is fine). |
| Optimize catalog and the history of removed dangerous tasks | study | `lib/optimize/catalog.sh`, `SECURITY_AUDIT.md:269-275` | Tells us which "optimizations" not to ship (Dock reset, font cache). |
| `status` dashboard | ignore | `cmd/status/` | Out of scope for M1. Maybe revisit for a menu-bar extra later. |
| Safety test strategy (sink audit with `# SAFE:` annotations, fuzz corpus, source-invariant tests) | study → take (as process) | `scripts/audit_destructive_sinks.py`, `tests/path_validation_fuzz.bats`, `tests/fuzz_corpus/` | Adopt it: a lint rule that forbids `FileManager.removeItem`/`unlink` outside the `DeletionGate` module, plus path-validation fuzz tests. |

## Open questions

1. Scan speed: Mole's analyzer against a `getattrlistbulk` engine on the same tree. Not measured, left for the benchmark task T-0004. The probe shows the build works: `go test` in the clone took about 23 s of CPU, including module download.
2. Does `/usr/bin/trash` (macOS 15+) write Put Back metadata? I assume yes but have not verified it. `FileManager.trashItem` does, according to Apple's documentation.
3. #1607 shows the owner can crash even when no file handle is open, because the app read the ID file at launch and then lost it. Is an open-handle check enough, or should macontrol keep every cache directory with an unknown owner out of the automatic selection? The recommendation in the finding is the latter.
4. Legal: does re-deriving a location list that is mostly a compilation of facts from a GPL repo need attribution? Hand this to T-0003 (license matrix). My proposal is to cite Mole in a credits file anyway.
5. The proprietary "Mole for Mac" app has a disk map, a menu bar and VoiceOver support (`README.md:19`). I did not review it because it is closed source. Issues labelled `[Mac App Bug]` hint at its problems (update detection, apps installed from a pkg not detected, #1596).
