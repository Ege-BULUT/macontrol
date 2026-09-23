# Source deep dive: MangoDisk (harry0703/MangoDisk)

Task T-0019. Researcher: `dive-harry0703-mangodisk`. Date: 2026-09-23. Clone: `research/sources/harry0703-mangodisk` at `19e55d2` (2026-09-22 17:36 +0800, "feat(duplicates): protect selected scan locations").

All paths below are relative to the clone. Most Rust paths sit under `src-tauri/crates/`, shortened here to `core/` (= `mangodisk-core/`) and `platform/` (= `mangodisk-platform/`). "Verified" means I ran it on this Mac. Everything else comes from reading the code at that commit. I did not build or launch the app, to keep CPU load low on a loaded machine (the Rust workspace pulls in rusqlite-bundled, reqwest, tokio and objc2).

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/harry0703/MangoDisk (homepage https://mangodisk.app/) | `gh api repos/harry0703/MangoDisk` |
| License | GPL-3.0 (LICENSE is GPLv3; the API reports `GPL-3.0`). No vendored code or UPSTREAM/NOTICE files. The UI kit is shadcn-vue (`components.json`). | `LICENSE:1-2`, `README.md` "License" |
| Stars / forks | 3 059 / 223. Not a fork, not archived. | `gh api`, 2026-09-23 |
| Created / last push | 2026-08-01 / 2026-09-22. 14 releases between v1.0.0 (2026-08-07) and v1.1.3 (2026-09-18), about 188 commits. | `gh api .../releases`, commits `Link` header |
| Languages | Rust 7.0 MB, TypeScript 1.27 MB, Vue 1.0 MB, and a little C++, PowerShell and AppleScript. By line count: 189 k lines of Rust in 400 files, and 64 k lines of TS/Vue. | `gh api .../languages`, `wc -l` |
| Platforms | macOS 12.5+ and Windows 10+ x64 (WebView2). Distributed as a Homebrew cask, a DMG, an NSIS installer and a separate `mangodisk` CLI. | `README.md` "Install and Run" |
| Open issues | 9 open issues (14 including PRs), all enhancement requests: Linux, WinGet, exclude folders (#47), auto-scan (#29), registry cleanup on uninstall (#36), deeper node_modules/target discovery (#51). | `gh api .../issues?state=open` |

**What the license lets us do:** study only. macontrol is not GPL, so we cannot copy MangoDisk code, rule TOML files or their evidence text. File-system facts are not copyrightable: we can re-derive a path from the official reference that each rule cites (every rule has `references = [...]`) and use MangoDisk only as the checklist that pointed us to it. This matches the T-0003 license plan.

## Summary

MangoDisk is the closest existing merge of macontrol's two halves in one app. It offers Deep Cleanup (rule catalogue), Large Files, exact Duplicates, Disk Space Analysis (a one-level squarified treemap plus a list), Privacy Cleanup, App Uninstall with orphan leftovers, Startup Items, System Optimization (defaults and registry), System Maintenance, Operation History, a menu-bar/tray resource monitor, and optional AI explanations (`README.md` sections 1-10). The UI is Tauri 2 + Vue 3. All filesystem work happens in a Rust core that a CLI shares.

It is the most safety-engineered source reviewed so far. What stands out:
- **Data-driven rules validated at build time.** 120 macOS, 87 Windows and 31 project-artifact TOML rules. `build.rs` validates them against the same schema module the runtime uses and embeds them in the binary (`core/build.rs:6-40`, `core/rules/README.md`).
- **Fail-closed deletion.** Every delete captures a physical identity and renames into staging, where the identity is checked again. A failed delete rolls back (`core/src/filesystem/permanent_delete.rs`).
- **A fast native macOS scanner.** It uses parallel `getattrlistbulk` with allocated and logical sizes and skips File Provider placeholders (`platform/src/macos/analysis.rs`, `bulk_directory.rs`).

Its weak spots for macontrol's goals:
- Everything is **permanent delete**. There is no Trash, and a failed delete produced by the old Trash path is now migrated to a "permanent delete failed" result (`core/src/applications/leftovers/models.rs:118`).
- **The disk map is shallow.** Only one level is shown, capped at 80 children.
- **Hard links and APFS clones are not handled** when sizing.
- **The uninstaller is deliberately narrow.** It removes exact-bundle-ID paths under `~/Library` only. It does not remove LaunchAgents/LaunchDaemons, Group Containers or pkg receipts, and it never touches system apps.
- **A WebView UI.** It is not native AppKit/SwiftUI.

## Architecture

- **Workspace.** `core/` (product domains, platform-neutral, no Tauri), `platform/` (OS contracts plus macOS/Windows implementations), `mangodisk-cli/` (a sibling adapter), and `src-tauri/src/` (a thin Tauri adapter: commands validate input, call Core and publish events). The boundary rules are written down in `AGENTS.md:7-20`, `src-tauri/AGENTS.md:5-12` and `src-tauri/crates/README.md`.
- **Core domains.** `cleanup` (rules, preview, preflight, execute, verify), `storage` (`analysis`, `large_files` and `duplicates`, kept deliberately separate), `applications` (inventory, uninstall, leftovers, quit), `filesystem` (permanent delete, identity), `history`, `reporting` (benchmarks), `privacy`, `startup`, `system_settings`, `system_maintenance`, `ai`.
- **Frontend.** Vue 3 + Pinia stores (`src/stores/*.ts`) and pages (`src/pages/<feature>/`). Locales exist for en, zh-CN, zh-TW, ja and ko. Rules carry no UI text: locale files own `cleanupRules.entries.<rule-id>` (`core/rules/README.md:239-241`).
- **Cross-process safety.** An `OperationGuard` holds per-resource claims. Inside one process they queue FIFO. Across GUI and CLI they are process locks that fail fast (`core/src/shared/operation.rs:74-79, 415-418`).
- **Reuse for macontrol.** The domain split (cleanup, storage.analysis, storage.duplicates, applications, filesystem) and the "rules are data, cleaners only when TOML cannot express it" rule are worth copying as architecture. The code itself is not.

## Scanning

**Disk analysis (macOS native path)** is in `platform/src/macos/analysis.rs` and `bulk_directory.rs`:
- **API.** It calls `getattrlistbulk` with a 64 KiB aligned buffer (`bulk_directory.rs:14,146-167`). The requested attributes are NAME, DEVID, OBJTYPE, MODTIME, FLAGS, ATTR_DIR_MOUNTSTATUS, ATTR_FILE_ALLOCSIZE and ATTR_FILE_DATALENGTH (`:182-198`). A separate name-only attribute set serves project discovery (`:200-213`). Directories are opened with `O_NOFOLLOW|O_NONBLOCK|O_DIRECTORY` (`:58-76`).
- **Concurrency.** A pool of up to 8 worker threads (`analysis.rs:28`, `worker_count` at `bulk_directory.rs:175-180`) pulls directory tasks from a Condvar queue. One coordinator thread receives the results with a 40 ms `recv_timeout` poll (`analysis.rs:27,453-477`) and rolls totals up to the parents when a directory's last child finishes (`finalize_directory_chain`, `:754-788`). When a scan fails or is cancelled, the stuck workers go to a bounded "reaper" thread, so the UI does not wait on a kernel call that cannot be interrupted (`:520-594`). A new scan returns `Busy` while reapers are still active (`:509-518`).
- **Sizes.** It tracks logical (`ATTR_FILE_DATALENGTH`) and allocated (`ATTR_FILE_ALLOCSIZE`) bytes separately. Disk analysis and large files use allocated bytes, and duplicates use logical bytes (`analysis.rs:40-50`). A test confirms that sparse holes are not charged (`:1071`).
- **Hard links.** Not handled. FILEID and LINKCOUNT are not requested (`bulk_directory.rs:182-198`), and every regular file adds its allocation (`analysis.rs:731`), so a file with N links is counted N times. The size test covers symlinks but not hard links (`analysis.rs:950-1069`). The benchmark dataset creates a hard link (`core/src/reporting/benchmark/dataset.rs:562-574`) but only reports it. This is the F-0010 class (evidence posted on T-0019). I read the code; I did not run it.
- **APFS clones.** Not handled. Each clone is charged its full allocation. This is the F-0004 class.
- **Boundaries.** A different `st_dev` or a mount point is skipped (`analysis.rs:691`). Symlinks and other non-regular entries are counted as skipped (`:750`). Dataless (`SF_DATALESS`) files and directories are skipped without being opened, so no iCloud materialisation is triggered (`:698-704, 721-727`; `platform/src/macos/mod.rs:174-179`). For analysis, `/System`, `/Library/Apple`, `/private/var/vm`, `/dev` and `/Volumes/.timemachine` are skipped (`platform/src/macos/directories.rs:119-129`). I checked on this Mac that `/`, `/Users` and `/System/Volumes/Data` share one `st_dev` (`stat -f %d`), so skipping `/System` is what prevents the Data volume from being counted twice through its firmlinks.
- **Memory model.** Each scan keeps one `HashMap<PathBuf, DirectoryAggregate>` holding every directory, plus a `HashMap<PathBuf, IndexedFile>` holding only files of 50 MiB or more (`core/src/storage/traversal/index_sink.rs:15-17`, `core/src/storage/large_files/models.rs:7`). Small files are never stored. Each page re-lists its folder live with `read_dir` and one `symlink_metadata` per child (`core/src/storage/index/cache.rs:274-286`). A whole-volume scan therefore holds one full-path key per directory. I did not measure its peak RSS.
- **Result cache.** Results stay in memory for at most 2 roots, as an LRU, only for the life of the process (`cache.rs:22,119-120`). Each root carries an FSEvents change token (`FSEventsGetCurrentEventId`) captured before the scan, and only for the system volume (`platform/src/macos/change_tracking.rs:287-318`). Drilling into a descendant reuses the snapshot without revalidating it (`cache.rs:170-178`, `if is_descendant_page` at :175). The root is revalidated through FSEvents history, and an explicit Refresh always rescans (`storage/traversal.rs:197-213`).
- **Result shape.** Only the direct children of the current folder, sorted by size and **truncated to 80** (`cache.rs:302`). There is no pagination for analysis.
- **Fallback.** A generic `std::fs` traversal (`traverse_memory_only`) runs when the native path is unsupported or fails, and the fallback reason is logged (`storage/traversal.rs:254-293`).

**Large files.** A quick mode uses Spotlight: `mdutil -s` must report indexing enabled, then `mdfind -0 "kMDItemFSSize >= N"` runs, with argument-vector quoting and NUL-separated output (`platform/src/macos/mod.rs:470-569`). A complete mode uses the same bulk scanner (`storage/traversal.rs:1120-1200`).

**Duplicates.** Files are grouped by size, then filtered by head/middle/tail 16 KiB samples (`core/src/storage/duplicates/service.rs:121`), then confirmed with a full BLAKE3 hash (1 MiB buffer, 4 hash workers; `:62-63`). An all-sparse group is certified without reading content (`:1928-1960`). A hash cache holds up to 500 k entries (`hash_cache.rs:12`). A (volume, inode) identity keeps hard links from being reported as copies (`candidates.rs:27-30, 675-720`). Each group always keeps at least one copy, and protected entries are always kept (`models.rs:74-98`). Core checks group membership again before deleting (`service.rs:626-629`). Reclaimable bytes are the sum of `allocated_bytes`, so APFS clones are overstated (F-0004 class).

**Progress and cancellation.** Progress is throttled per stage (`ProgressTracker`). Cancellation is checked per entry, and the scan emits typed `Cancelled` and `Busy` errors (`analysis.rs:359-361, 447-450`).

## Deletion and rules

- **Rule files** live in `core/rules/filesystem/<platform>/<category>/<id>.toml`. They use schema v3 with the fields id, rule_version, platform, category, `risk` (safe/recoverable/highImpact), `default_selected`, `recommended_selected`, `required_stopped_processes`, `[[applicability]]` probes, `[[roots]]` templates restricted to controlled variables (`${user_library}`, `${darwin_user_cache}` and similar), `[matcher]` (all, nameGlob, extensionIn, olderThan, largerThan, maxDepth, and the combinators allOf/anyOf/not), `[execution]` (`deleteMatchingContents` or opt-in `deleteWholeRoot`), and `[verification]` (lifecycle, evidence, verified_at, references). The schema is documented in `core/rules/README.md:35-155`. Example files: `dev.xcode-derived-data.toml` and `system.darwin-user-cache.toml` (7-day age gate, excludes db/sqlite/plist and SIP-protected sandbox containers).
- **Build-time validation** rejects parent traversal, uncontrolled variables, protected locations, broad matchers on mixed roots, overlapping rules, and `default_selected` on anything that is not `safe` (`core/rules/README.md:82-88, 125, 260`; `core/src/cleanup/rules/declarative_schema.rs`, `validation.rs`, `root_validation.rs`). A lint script also rejects non-English developer text and UI fields in TOML (`scripts/check-rule-sources.mjs`).
- **Protected paths** block the credential dirs under `~` (.ssh, .aws, .gnupg and others), sync and backup roots (Dropbox, iCloud Drive and others), repo roots (`projects`, `src` and others), `.git`/`.hg`/`.svn` at any depth, Library user-state roots (Mail, Messages, Keychains, Photos, Safari, Mobile Documents) and File Provider/CloudKit subtrees (`core/src/cleanup/rules/protected_paths.rs:1-80`). Cleanup roots under Desktop, Documents, Downloads, Pictures, Movies and Music are refused (`platform/src/macos/mod.rs:330-358`).
- **Project artifacts** (node_modules, target and similar, 31 ecosystems) are always opt-in. Before deletion, a nested `.git` or a `*-keypair.json` blocks the artifact, and an isolated `git ls-files` probe must show that the artifact contains no tracked files (5 s timeout, fail-closed) (`core/rules/README.md:197-206`, `core/src/cleanup/cleaners/project_artifact_protection.rs:58`).
- **Dedicated cleaners** exist where TOML cannot express the rule: Xcode storage, AI model stores (Ollama/LM Studio with shared-blob awareness), Docker build cache, conda, Rust toolchains, Dropbox cache, an opt-in "additional user caches" sweep, and universal-binary thinning (`core/src/cleanup/cleaners/`).
- **Process gating.** Rules with `requires_app_close` list the executables that must be stopped. A time-bounded process guard re-checks during long deletes and fails closed when inspection is unavailable (`core/src/cleanup/rule_execution.rs:52-160`). The "additional user caches" sweep is opt-in (`default_selected: false`, `recommended_selected: false`; `user_cache_inventory.rs:153-154, 192-193`). Its "is this cache active?" check only matches a cache folder name against process and app names (`:562-586`). This is the F-0015 class, softened by the opt-in.
- **Permanent delete everywhere** (`core/src/filesystem/permanent_delete.rs`), in these steps:
  1. `prepare_path_for_permanent_delete` rejects links, reparse points, FIFOs and sockets before opening the target. It captures (dev, ino) and keeps a handle open (`:128-190`). This FIFO fix came from issue #24.
  2. `delete_via_staging` renames the target into `<parent>/.mangodisk-delete-<pid>-<n>/target` (`:551-563, 1078-1110`) and compares the identity again.
  3. It removes the tree, serially or with at most 2 macOS workers (`:26-36`).
  4. If removal fails, the remainder is restored to its original path (`rollback_staged_target`, `:1018`).
  - Nothing reconciles staging after a crash or Quit. This is the finding filed for this source.
  - The analysis view can delete only a direct child of the current folder (`:337-343`). It reports the size from scan time as the freed size (`:385-395`), and a test locks that behaviour in (`storage/analysis/service.rs:207-214`).
- **Dry-run.** The CLI runs `mangodisk clean --apply --selection all --dry-run`, and non-interactive use needs `--yes` (`README.md` "CLI Quick Start"). Every cleaner takes `dry_run`.
- **Privilege escalation.** Root-owned apps in `/Applications` are removed through `osascript` running `do shell script ... with administrator privileges`. Every value is passed as `argv` and wrapped in `quoted form of`. The script does mv to staging, a `stat -f %d:%i` identity check, then `rm -rf`, and restores on failure (`platform/src/macos/privileged_uninstall.applescript:1-55`). The quoting is correct, unlike the F-0002 and F-0018 cases, but it depends on the deprecated AppleScript authorization path.
- **Uninstall (macOS)** accepts only `.app` bundles in `/Applications` or `~/Applications`, at most 1 level deep and never through a symlink (`core/src/applications/uninstall/macos.rs:696-716`). Associations are exact `CFBundleIdentifier` paths in 8 locations under `~/Library`: Caches, Application Support, Preferences plist, Logs, Saved Application State, Containers, WebKit and HTTPStorages (`:578-642`). Only rebuildable items are preselected (`:584-641`). No display-name matching is done anywhere (test `exact_associations_never_use_display_names`, `:1051`). Not covered: LaunchAgents/LaunchDaemons, Group Containers, `/Library` system-level files, PrivilegedHelperTools, pkg receipts, and system apps (`system_classification.rs:36-50` classifies only Windows).
- **Orphan leftovers** are found only through `~/Library/Containers/*/.com.apple.containermanagerd.metadata.plist`. A container counts as an orphan when the identity in that plist says the former bundle is missing, no installed app has the identifier and no process is running, plus the same 7 exact-ID companions (`core/src/applications/leftovers/macos.rs:69-275`). This is very safe but finds nothing for apps that are not sandboxed.

## UI

- **Stack.** Vue 3 SFCs inside the Tauri WebView, with shadcn-vue primitives (button, dialog, context-menu, tooltip and others; `src/components/ui/`) and Tailwind CSS variables. There are light and dark themes. Screenshots are linked from `README.md`.
- **Treemap.** A squarified layout in TypeScript (`src/lib/utils/treemap-layout.ts:27-158`). Area is proportional to bytes, which is correct (contrast F-0020). Entries below 0.75 % of the total are merged into one "N smaller items" remainder tile (`:26, 37-55`). Each tile is a DOM `<button>` placed with percentage coordinates (`src/pages/analysis/components/md-analysis-treemap.vue:117-160`). The map shows **one level only**, with no nested rectangles and no cushion shading.
- **Interactions.** Click a folder to drill down. Double-click or Enter opens a file. A right-click context menu offers Open, Reveal (`tauri_plugin_opener::reveal_item_in_dir`, `src-tauri/src/commands/file_manager.rs:10-27`) and Delete. Delete asks for confirmation with the text "Permanently delete this item? The file or folder will be deleted immediately and cannot be recovered" (`src/locales/en-US.json:1915-1916`). Tiles have aria-labels and a tooltip.
- **Performance on big trees.** Each page holds at most 80 DOM tiles, because the backend truncates the list (`cache.rs:302`). The remainder tooltip promises "Full details are available in the list" (`en-US.json:1902`), but the list is the same truncated set of 80, so any children beyond 80 cannot be seen or deleted in either view. This is the F-0016 class.
- **Other pages.** Large-file, duplicate and cleanup lists are paginated ("load more", `src/components/custom/md-load-more-button.vue`, used by cleanup, duplicates and large-files but not by analysis).

## Tests and quality

- **Rust tests.** 1 701 `#[test]` functions. 270 of them are `#[ignore]`: these need a real app, NTFS, a Windows restart or a real scan root, and each carries its reason string. There are many fixture tests for safety races: same-path replacement, FIFO, a junction, a locked child, a symlink during cancellable delete, and rollback (`permanent_delete.rs:1433-2126`).
- **Frontend tests.** 155 `*.test.ts` files with about 770 `it`/`test` cases (vitest).
- **CI.** `.github/workflows/cross-platform-check.yml` runs `pnpm check` (lint, type, i18n and architecture checks from `scripts/check-*.mjs`), `cargo test --workspace` and a Tauri build check on both `macos-latest` and `windows-latest`, for every PR.
- **Engineering hygiene** is unusually high:
  - Every native fast path has a logged fallback reason.
  - Log lines use stable `domain_event key=value` names, which makes them easy to grep.
  - Persisted schemas carry versions.
  - `AGENTS.md` sets rules against "giant services" and "utils" modules.
- **Weak spots.**
  - The codebase is large and moving fast (189 k lines of Rust in 7 weeks).
  - Some files are very long (`privacy/service.rs` has 5 248 lines, `uninstall/service.rs` 3 307).
  - Parts of the test suite are gated behind environment variables or ignored, and CI never runs them.

## Known problems

From issues (closed issues with the most comments, read on 2026-09-23):
- #44: cleaning the Chrome/Edge offline cache deleted `Service Worker/ScriptCache`, and Manifest V3 extension background workers then failed to start. It was fixed in 1.0.9 by keeping the ScriptCache. Lesson: browser "cache" roots contain state that is not a cache. Rule roots need an exclusion list per browser.
- #24: Deep Cleanup hung forever on FIFOs in `$TMPDIR`, because it opened them in blocking mode before checking their type, and cancellation never finished. The fix was non-blocking no-follow opens plus FIFO and socket tests. Users had to force-quit, which matters for the finding below.
- #21: macOS app inventory came back incomplete when one directory failed to read. It was fixed in 1.0.5 by skipping the failing directory and continuing.
- #22: the treemap and ratio bar did not render on macOS 12.6 (a WebView difference). Fixed.
- #40: free space in the header stayed stale after the first launch. #38: System Optimization wrote wrong key-repeat defaults, and "restore" never deleted keys.
- Open themes: exclude folders (#47), deeper node_modules and target discovery (#51), registry cleanup on uninstall (#36), and Linux support.

From code:
- **Staging is never reconciled** after a crash or Quit. Quit is not guarded while a delete runs (`src-tauri/src/commands/resident.rs:136-138`; no `ExitRequested` handler in `src-tauri/src/lib.rs:363-377`). This is the new finding; see the board.
- **Analysis lists are cut at 80 entries** (F-0016 class), **hard links are counted once per link** (F-0010 class), and **clone and duplicate reclaim sizes are overstated** (F-0004 class). Deletion is permanent with no quarantine (F-0012 class). The "additional caches" active check is name-based (F-0015 class, opt-in here).
- **The analysis delete reports the scan-time size as freed** (`permanent_delete.rs:385-395`) and never measures the actual change.
- **The AI provider API key is stored as plain JSON** in `data/ai.json`. On an explicit request, startup and cleanup explanations send unredacted paths to the configured provider; the default provider is `https://mangodisk.app` (`core/src/ai/README.md` "Boundaries", `core/src/ai/official.rs:45-47`).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Declarative rule schema design: risk tiers, applicability probes, controlled root variables, matcher combinators, verification block with evidence and references, build-time validation | improve | `core/rules/README.md`, `core/src/cleanup/rules/declarative_schema.rs`, `core/build.rs` | This is the best rule model seen in any source. GPL blocks copying, so we re-author it in Swift or JSON, and add a `disposal` field (trash, quarantine or unlink) per F-0012. |
| Rule catalogue (120 macOS TOML rules) | study | `core/rules/filesystem/macos/**` | Use it as a checklist only. Re-derive each path from the official URL the rule cites. Do not copy the TOML or the evidence text (GPL). |
| Project-artifact protection: nested `.git`, keypair files, `git ls-files` must show no tracked files | improve | `core/rules/README.md:197-206`, `core/src/cleanup/cleaners/project_artifact_protection.rs` | A sound idea to reimplement. Consider a faster check than `git ls-files`, for example reading the git index directly. |
| Protected path lists (home credential dirs, Library user state, File Provider subtrees) | study | `core/src/cleanup/rules/protected_paths.rs` | A good seed list. We must write our own list and extend it. |
| Native bulk scanner: parallel `getattrlistbulk`, SF_DATALESS skip, mount/device boundary, reaper for stuck kernel calls | rewrite | `platform/src/macos/analysis.rs`, `bulk_directory.rs` | The design is right but lacks FILEID and LINKCOUNT (hard links) and clone accounting. Rewrite in Swift with ATTR_CMN_FILEID and ATTR_FILE_LINKCOUNT (and, where used, ATTR_CMNEXT_PRIVATESIZE, see T-0009). The reaper pattern is worth keeping. |
| Keeping allocated and logical size separate, with the size unit chosen by purpose | take (idea) | `analysis.rs:40-50` | A one-line policy that is correct. No code is needed. |
| Identity-pinned staging delete with rollback on failure | improve | `core/src/filesystem/permanent_delete.rs:128-190, 551-730` | Keep the dev/ino re-check and the rollback. Add a write-ahead journal, one staging directory per volume and launch-time reconciliation (see the new finding), and offer Trash or quarantine instead of permanent delete. |
| FSEvents token for cache revalidation (`FSEventsGetCurrentEventId` before the scan, history replay after) | improve | `platform/src/macos/change_tracking.rs:287-330` | A good approach. Persist the index across launches, which MangoDisk does not do (it keeps results in process only, `cache.rs:119-120`). |
| Duplicate pipeline: size, 3×16 KiB samples, BLAKE3, sparse certification, keep at least one, core re-verifies membership | improve | `core/src/storage/duplicates/` | A solid pipeline. Add clone-aware reclaim (ATTR_CMNEXT_CLONEID) and offer "replace with clone" instead of delete. |
| Spotlight quick large-file scan (mdutil status gate, then `mdfind -0`) | take (idea) | `platform/src/macos/mod.rs:470-569` | A cheap instant first pass, with a full scan as the authoritative result. |
| Treemap layout (squarified, area proportional to bytes, one remainder tile) | rewrite | `src/lib/utils/treemap-layout.ts` | The algorithm is correct but one level deep and built from DOM tiles. macontrol needs nested, GPU/Canvas-rendered maps and no 80-entry cap. |
| Uninstaller: exact bundle-ID associations and orphan containers from containermanagerd metadata | improve | `core/src/applications/uninstall/macos.rs:578-642`, `core/src/applications/leftovers/macos.rs:69-275` | The safe core to start from (no name matching). Extend it to LaunchAgents/LaunchDaemons with bootout (F-0023), Group Containers by team ID, pkg receipts and `/Library` through a helper. |
| Privileged removal through AppleScript `do shell script` (quoted argv) | ignore | `platform/src/macos/privileged_uninstall.applescript` | Correct quoting, but macontrol will use an SMAppService helper (T-0011). |
| Operation coordination (per-resource claims, cross-process locks shared by GUI and CLI) | study | `core/src/shared/operation.rs` | Useful if macontrol ships a CLI. |
| Tauri/Vue shell, tray resource monitor, Windows code, AI explanations | ignore | `src-tauri/src/`, `src/`, `core/src/ai/` | Not native, not in scope, or out of scope for M1. |

## Open questions

- Actual scan speed and peak RSS of `darwin_parallel_getattrlistbulk_allocated_files_v4` on a whole volume, compared with our Swift prototype. Unverified: I did not build it. Hand this to the T-0004 benchmark harness if we want a GPL tool as a reference point. Their own benchmark runner is `core/src/reporting/benchmark/runner.rs`, and MANGODISK_ANALYSIS_ROOT gates it.
- How the UI explains the gap between the "/" total and the used space when `/System` and `/private/var/vm` are skipped (F-0005 class). I did not check this in the running app.
- Whether `deleteWholeRoot` for DerivedData leaves a partially removed tree in `~/Library/Developer/Xcode/.mangodisk-delete-*` when killed. This follows from the code but was not reproduced.
- Whether their `required_stopped_processes` lists (for example `["Xcode"]`) miss helper processes such as `XCBBuildService` that also write to DerivedData.
