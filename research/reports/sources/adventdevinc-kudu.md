# Source deep dive: Kudu (AdventDevInc/kudu)

- **Task:** T-0018, researcher `dive-adventdevinc-kudu`, 2026-09-23.
- **Clone:** `research/sources/adventdevinc-kudu` at `0ef4292` (2026-09-22 14:18 +0200, "chore(release): 3.4.0").
- **Paths:** all paths below are relative to that clone unless marked otherwise.
- **"Verified":** I ran it on this Mac (macOS 26.6, 25G72). Everything else comes from reading the code.
- **Probes:** they live in `research/bench/adventdevinc-kudu/`.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/AdventDevInc/kudu (homepage https://usekudu.com) | `gh api repos/AdventDevInc/kudu` |
| License | MIT, "Copyright (c) 2026 Advent Development Inc" | `LICENSE`, `gh api .../license` |
| Stars | 3 562, not a fork. 547 commits, 8 contributors. | `gh api repos/...`, `/commits` Link header, `/contributors` (2026-09-23) |
| Created / last push | 2026-03-14 / 2026-09-22. The latest release, v3.4.0 (2026-09-22), has 5 macOS assets. v3.3.0 has about 189k downloads in total. | `gh api .../releases` |
| Languages | TypeScript 4.5 MB, CSS 144 KB, JS 88 KB, Shell 13 KB. The main process has about 52.9k lines of non-test TS (`src/main`, `src/shared`). | `gh api .../languages`, `wc -l` |
| Stack | Electron ^44.4, electron-vite, React ^19.2, Tailwind 4, zustand, recharts, better-sqlite3, yara-x, pusher-js (cloud) | `package.json:73-109` |
| Platforms | Windows, macOS (DMG, Intel + Apple Silicon), Linux (AppImage, deb) | `README.md:39-46` |
| Issues | 0 open. 30+ recent closed issues, mostly Windows. The ones that matter here are listed under Known problems. | `gh api .../issues?state=all` |

**What the license lets us do:** MIT allows copying code and data if we keep the copyright and permission notice. The darwin rule files (`rules/darwin/*.json`) are the valuable part. All 22 commits that touch `rules/darwin` are by the maintainer `dbfx`. A grep for `bleachbit|cleanerml|pearcleaner|puremac` found no lineage markers, so the data looks original. That is unverified beyond this check. If we import the data, add a `THIRD_PARTY_NOTICES` entry. We should **not** reuse the Electron code; macontrol is native Swift. Ideas and data only.

## Summary

Kudu is a cross-platform Electron "system cleaner and security scanner". It has 37 renderer pages (`src/renderer/src/pages/`):
- the cleaner (system, browser, app, gaming, GPU cache, DB vacuum)
- a disk analyzer with a treemap, and a large-file finder, duplicate finder, empty-folder cleaner and file shredder
- an uninstaller and a bloatware remover
- a YARA malware scanner, a CVE scanner, privacy hardening, startup and service managers, a software and driver updater, and game mode
- scheduled scans, a CLI (`CLI.md`) and a "cloud" remote agent (`src/main/services/cloud-agent.ts`, 4 032 lines, pusher-js)

It is Windows-first. Many subsystems are PowerShell, registry or Restart-Manager only, and they either no-op or misbehave on macOS.

For macontrol, three things are worth taking:
1. **The data-driven rule format** (`rules/`, `src/main/rules/`) and its MIT darwin rule data: 74 app rules, 6 gaming, 22 system, 21 DB and 13 Chromium-family bases.
2. **The deletion engine's safety layer** (`src/main/services/file-utils.ts`):
   - the renderer passes only opaque scan IDs
   - the recency gate checks whole subtrees, not just a directory's mtime
   - the tree is re-validated immediately before delete
   - ancestor and descendant selections are serialized
   - partial deletes are salvaged, and every run gets a cleanup receipt
3. **Identity-checked delete in the large-file finder**, which re-checks dev, ino, size, mtimeNs and ctimeNs before deleting.

Its disk analyzer is weak, and the macOS uninstaller is dangerous. Both are filed as findings F-0030 and F-0031.

## Architecture

- **Process split.** This is the standard Electron split. Main (`src/main/`) owns every filesystem and OS action. The renderer (`src/renderer/src/`, React + zustand stores) talks to it through a preload bridge (`src/preload/index.ts`, exposed as `window.kudu`) over typed channel names (`src/shared/channels.ts`). The window is created with `contextIsolation: true` and `nodeIntegration: false`, and `sandbox: !isRoot` (`src/main/index.ts:488-494`).
- **Platform layer.** `src/main/platform/{darwin,linux,win32}/` implements one `PlatformPaths/Commands/Elevation/Browser` interface (`src/main/platform/types.ts`). On darwin:
  - `paths.ts` merges the JSON rules with hard-coded malware and uninstall-leftover dirs (`platform/darwin/paths.ts:35-89`)
  - `commands.ts` lists apps via `system_profiler SPApplicationsDataType -json` plus `du -sk` (`:106-166`)
  - `elevation.ts` is just `getuid() === 0` (`:1-9`)
- **Rules.** The JSON is statically imported and bundled at build time (`platform/darwin/paths.ts:7-15`). `buildCleanerPaths` (`src/main/rules/loader.ts:178-367`) resolves `${VAR}` templates. Nothing loads at runtime from user-writable locations, which avoids the F-0021 class of problem.
- **IPC modules.** There is one file per feature (`src/main/ipc/*.ipc.ts`), backed by services (`src/main/services/*`). Scans put their results in an in-memory `scan-cache` keyed by random UUID (`services/scan-cache.ts:1-60`). The clean IPC accepts only IDs and looks up the paths in main (`file-utils.ts:305-315`). A compromised renderer therefore cannot name arbitrary paths for the cleaner. The uninstaller IPC takes a `programId` that main resolves from its own cached list (`ipc/program-uninstaller.ipc.ts:33-37`).
- **Scheduling and cloud.** Scheduling (`services/scheduler.ts`), the CLI (`src/main/cli.ts`, 2 384 lines) and the cloud agent (`services/cloud-agent.ts`) all reuse the same services. The cloud path skips native actions and cache resets (`file-utils.ts:383-412`).

## Scanning

**Cleaner scan** (`src/main/services/file-utils.ts:670-1130`):
- **APIs and concurrency.** Node `fs/promises` `readdir(withFileTypes)` and `lstat`, one `await` per entry, so it is serial. It never follows symlinks (`:743-746`, `:765-768`).
- **Recency.** A file counts as settled when its mtime is older than the cutoff: `skipRecentMinutes`, default 60 (`:826-829`), or the rule's `minAgeDays`. A directory is offered as one item only if **every** descendant is settled. Otherwise it is opened and its children are judged the same way (`resolveChildren` / `resolveEntry`, `:714-796`; the rationale is in the doc comment at `:670-692`, issue #265).
- **Bounds.** Depth is capped at `MAX_RECENCY_DEPTH = 8`. A subtree beyond that depth is "withheld" (not offered), never deleted blindly (`:285`, `:783`). The item budget is 250k (`:289`).
- **Sizes.** Sizes are **logical** (`stats.size`, `:776`; `cleanup-measurement.ts:18`). There is no `st_blocks`, no hard-link dedupe and no clone awareness, which is the same class as F-0004 and F-0010.
- **Progress and cancellation.** Progress is throttled to 120 ms (`:554-561`), and a `CooperativeScheduler` yields to the event loop. I found no cancellation in the cleaner scan.
- **Rule shapes.** `childSubdir` expands to `path/*/childSubdir` (`:1106-1130`). `recursiveMatch` is a bounded search: an anchor directory, exact target names, `excludedAncestors`, maxDepth ≤ 32, and a 100k-directory cap (`:1132-1300`). `fileMatch` covers an exact-filename allowlist, `minAgeDays` and `skipIfChildExists: ["pending"]` (`:898-974`). These shapes are well designed: they keep a broad base path from becoming directly cleanable.

**Disk analyzer** (`src/main/ipc/disk-analyzer.ipc.ts`):
- **Walk.** It is a serial recursive `readdir` plus `stat`. Note `stat`, not `lstat`, for files (`:57`, `:141`). The tree returned to the renderer is capped at `MAX_DEPTH = 3`. Below that, sizes are summed without nodes (`:21`, `:36-43`). The whole tree goes back in one IPC reply. There is no cancellation, and progress is a constant `progress: 50` at depth 0 (`:62-71`).
- **Roots.** The roots are every `/dev/*` mount from `df -Pk` (`:186-211`): `/`, VM, Preboot, Update, xarts, iSCPreboot, Hardware and Data all appear as "drives". A walk of `/` has no mount-point or firmlink handling, so it counts the Data volume twice and descends into VM, Preboot and `/Volumes` (**F-0031**, verified with a probe).
- **Default selection.** The store defaults `selectedDrive` to `'C'` (`src/renderer/src/stores/disk-store.ts:47`). On macOS `resolveRootPath('C')` returns null, so the first Analyze click returns an empty tree until the user changes the dropdown. This is from reading the code; the runtime behaviour is unverified.
- **File-type view.** It is capped at depth 4 (`:22`, `:83-126`).

**Other scanners:**
- Large-file finder (`ipc/large-file-finder.ipc.ts:67-130`): serial `lstat` walk, `cancelled` flag, `excludePatterns` by directory name.
- Duplicate finder (`ipc/duplicate-finder.ipc.ts:120-200`): size, then partial SHA-256, then full SHA-256, with batch concurrency 8.
- Memory model: plain arrays and Maps in the main process. There is no compact tree and nothing sized for millions of nodes, because the analyzer never keeps more than 3 levels.

## Deletion and rules

- **Rule definitions** are data-driven. There are 8 JSON files per platform (`rules/RULES.md:17-28`), validated by a draft-07 schema (`rules/schema/rules.schema.json`) and a CI validator (`src/main/rules/validate.ts`). The validator runs the schema, the per-platform `${VAR}` allowlist and a duplicate-id check.
- **Rule tooling:**
  - `npm run new-rule`, `find-cache` (finds uncovered cache dirs on the local machine), `preview-rule` (dry run), `parity-check` and `catalog` (`scripts/*.js`)
  - a PR bot that validates and summarises rule diffs (`.github/workflows/rules-bot.yml`)
- **Weakness:** paths are unconstrained strings. `${HOME}`, `/` and `..` all validate, and there is no runtime deny list (**F-0032**, verified with a probe).
- **Rule fields worth copying:**
  - `minAgeDays`
  - `cacheReset` (visible but unselected, "slower next launch", excluded from CLI and cloud unless opted in; `RULES.md:182`)
  - `cleanupAction` (a native prune command instead of deletion: `uv-prune`, `pnpm-prune`, `docker-build-prune`; `services/managed-cleanup.ts`)
  - `description` ("why safe")
  - `group`
- **Delete primitive.** `safeDelete` (`file-utils.ts:230-281`) is `fs.rm(recursive, force, maxRetries 3)` and deletes **permanently**; nothing goes to the Trash. That is the F-0012 class, so I filed no new finding. If `rm` fails with EBUSY, EPERM, EACCES or ENOTEMPTY, `deleteDirectoryBestEffort` removes the tree leaf-first without following symlinks. It records every path it could not remove (`:90-129`) and counts partially freed bytes (`:523-545`).
- **Optional "secure delete".** It overwrites the file with random data and then zeros. Before writing it re-checks that `nlink == 1` and that dev and ino are unchanged, and that no ancestor is a symlink (`:159-228`). On APFS SSDs this gives no real guarantee (wear levelling, snapshots). macontrol should not offer it.
- **Protections, in order, in `cleanItemsNow`** (`:305-667`):
  1. IDs that are no longer in the cache are reported as `scan-result-expired`, never silently dropped (`:333-340`).
  2. The item is `lstat`ed.
  3. User exclusions are applied as path prefixes and `*.ext` globs (`isExcluded`, `:135-153`).
  4. The subtree is measured, to account for the bytes.
  5. **The recency check is re-validated just before delete** (`revalidateRecencyItem`, `:799-818`).
  6. The item is deleted.
  
  Selections that are ancestors or descendants of each other are grouped and deleted serially, and independent groups run in an 8-worker pool (`:566-620`). Every run writes a receipt (`services/cleanup-receipts.ts`). The freed-bytes check against `statfs` runs only on Windows (`:182-200`). There is an opt-in deletion log with batched appends (`:343-353`).
- **The `mtime` recency gate is the only liveness test on macOS.** `cleaner-blockers.ts` is Windows Restart Manager only (`:40-60`). A socket or lock file more than 60 minutes old in `${TMPDIR}` or `/private/tmp` (`rules/darwin/system.json:5-6`) is offered for deletion even while its process is alive. For example, `/private/tmp/claude-mcp-browser-bridge-egeb/` exists on this Mac. This is the same class as F-0015 (Mole), so the evidence goes on the task, not a new finding.
- **Browser handling.** `closeBrowsers` on darwin runs `killall` on 18 browsers, Safari included, when `closeBrowsersBeforeClean` is set (`platform/darwin/browser.ts:9-40`, `ipc/cleanup-receipts.ipc.ts:51`). The DB "optimizer" runs SQLite `VACUUM` on live browser databases with a 250 ms busy timeout (`services/database-vacuum.ts:5-17`).
- **Privilege escalation on macOS:**
  - There is no cleaner elevation. Relaunching as admin is "not supported" on darwin (`ipc/index.ts:258-260`), so `needsAdmin` rules such as `/Library/Logs` simply fail. That matches issue #443, "Admin settings not taking effect".
  - The privacy hardening feature uses `osascript ... with administrator privileges` and quotes arguments with `shellEscape` (`platform/darwin/privacy.ts:39-76`).
  - There is **no Full Disk Access handling anywhere**: a grep for `Full Disk Access|Privacy_AllFiles` returns nothing. TCC-protected paths (Safari, Containers) just return empty scan results.
- **Uninstaller on macOS.** It lists apps from `system_profiler`, then runs the Windows pipeline. `spawn('')` fails. `verifyUninstall` fails open, because `reg` runs through `cmd.exe`, which gives ENOENT, which is read as "uninstalled". Fuzzy name matching then runs over `~/Library/{Application Support,Caches,Preferences}` with `selected: true`, and the matches are `rm -rf`'d **without any review** (**F-0030**, verified with probes; not verified end to end in the packaged app). The standalone leftover scanner is Windows-only (`services/uninstall-leftovers.ts:192-196`). Its "ownership proof" design is good, though: a folder is a leftover only if an owner was previously *seen installed* and is now absent (`:129-146`, `:250-255`).
- **Dry run:** `npm run preview-rule` covers rule authors. In the app, scan is a dry run and clean is a separate step with selections.

## UI

- **Rendering.** React DOM with Tailwind and framer-motion, and recharts for time-series charts.
- **Treemap.** Hand-written `squarify` (`src/renderer/src/pages/DiskAnalyzerPage.tsx:39-117`) that draws absolutely positioned `div`s with percentage geometry (`:391-420`).
  - Only one level is drawn: the current node's children.
  - Items under 1.5 % are merged into "N other items" (`:119-146`).
  - Tiles are keyed by name (`:397`) and have **no click handler**. Drill-down happens only from the table rows (`:450`), and only into nodes that have children, down to depth 3.
  - Loose files are never nodes (`disk-analyzer.ipc.ts:55-58`). Their bytes are in the parent total but not in the map. The map is normalised to the sum of its children (`layoutTreemap`), so file-heavy folders are under-represented.
- **No actions in the analyzer.** It offers no reveal in Finder and no delete. Those exist only in the large-file, duplicate and empty-folder tools, via `shell.showItemInFolder` and `shell.trashItem` (`ipc/large-file-finder.ipc.ts:268-292`).
- **Other UI:**
  - Confirm dialogs for destructive actions (`components/shared/ConfirmDialog.tsx`)
  - Cleanup receipts page (`components/cleaner/CleanupReceipts.tsx`)
  - 30 locales
  - Onboarding
  - Admin banner

  The README's animated GIF (`resources/kudu-animated.gif`) shows the visual quality: a polished dark theme. I did not launch the app.
- **Performance on big trees:** it is not designed for them. The capped tree keeps IPC small, but the serial walk and full re-walk on every analysis make it slow. This is from reading the code, not measured.

## Tests and quality

- **Scale:** 165 test files and about 2 845 `it`/`test` cases (vitest).
- **CI:**
  - `npm run check` runs typecheck, lint, prettier, rule validation and tests (`CLAUDE.md`, `AGENTS.md`).
  - The test job runs on a matrix of `windows-latest`, `macos-latest` and `ubuntu-latest` (`.github/workflows/ci.yml:67-89`).
  - Packaging smoke tests (`package-smoke.yml`).
- **Coverage gaps:** the tests are strong around `file-utils` (recency, delete, recursive rules, file match, secure delete). There is no darwin case in `services/program-uninstaller.test.ts`: every `process.platform` override is `win32` (`:1062-1212`). That is how F-0030 got through.
- **Code quality:** high on the Windows cleaner path, where comments cite issues and explain their invariants. On macOS, the code often reuses the Windows flow without platform guards (uninstaller, blockers, receipts).
- **Process:** releases go through one `npm run release` command with conventional commits. macOS signing broke CI for v2.7 and v2.8, so there were no DMGs for two releases (issue #403).

## Known problems

- **#406** (closed): the leftover detector flagged installed apps' data and game saves ("data-loss risk"). This led to the Windows ownership-proof redesign. The macOS path (F-0030) never got it.
- **#443** (closed, macOS): "Admin settings not taking effect". This follows from there being no darwin elevation and no FDA handling.
- **#403:** no macOS release for v2.7 or v2.8 because of keychain signing errors in CI.
- **#438:** the cleaner got stuck on VS Code's `state.vscdb` (DB optimizer).
- **#405 and #413:** CLI `leftovers clean` never deleted anything; exit codes returned 0 after failures.
- **#415:** the malware scanner preselected vulnerable-driver hits for deletion.
- **Rule-data issues to fix if we import the darwin rules:**
  - `${CACHES}/com.unity3d.UnityEditor` is defined twice (`apps.json:46`, `gpu-cache.json:6`), which double-counts in totals.
  - "Android Studio" covers all of `${CACHES}/Google` (`apps.json:44`).
  - `~/.m2/repository` holds non-rebuildable `mvn install` output (`apps.json:26`).
  - The whole of `Saved Application State` is a target (`system.json:12`).
  - `/private/tmp` is a target (`system.json:6`).
  - Two `${HOME}` placeholder paths are guarded only by `cleanupAction` (`apps.json:5,21`).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| darwin rule data (apps, browsers, gaming, gpu-cache, system) | improve | `rules/darwin/*.json` | MIT, original. About 100 macOS cache targets with "why safe" descriptions and a Chromium-family base list. Run it through macontrol's stricter validator (F-0032) and fix the items in Known problems. Add attribution. |
| Rule schema and field vocabulary | improve | `rules/schema/rules.schema.json`, `rules/RULES.md` | `minAgeDays`, `cacheReset`, `cleanupAction`, `recursiveMatch` (anchor + excludedAncestors + maxDepth) and `fileMatch` (+ `skipIfChildExists`) are proven shapes. Add path constraints plus `owner` and `regenerates` fields. |
| Rule tooling (find-cache, preview-rule, parity-check, rules-bot) | study | `scripts/find-cache.js`, `scripts/preview-rule.js`, `.github/workflows/rules-bot.yml` | Good contributor workflow. Rebuild as a Swift CLI target, or keep as scripts in the repo. |
| Subtree recency gate + delete-time revalidation | take (idea) | `src/main/services/file-utils.ts:670-818` | Offers a directory only if every descendant is settled, and re-checks right before `rm`. Port the logic to Swift. It fixes the "dir mtime" trap (issue #265). |
| Opaque scan-ID → path cache for the delete IPC | take (idea) | `src/main/services/scan-cache.ts`, `file-utils.ts:305-340` | For macontrol's XPC boundary: the UI or helper passes IDs that the engine minted, never raw paths. |
| Ancestor/descendant grouping + bounded parallel delete | take (idea) | `file-utils.ts:566-620` | Avoids double-claiming bytes and races. It is simple. |
| Best-effort leaf-first salvage + per-path failure list | take (idea) | `file-utils.ts:90-129, 230-281` | A good partial-failure report. Change the sink to Trash or quarantine (F-0012). |
| Identity-checked delete (dev, ino, size, mtimeNs, ctimeNs) | take (idea) | `src/main/ipc/large-file-finder.ipc.ts:249-275, 26-59` | A TOCTOU guard for every delete in macontrol. It even refreshes hard-link ctime. |
| Cleanup receipts | improve | `src/main/services/cleanup-receipts.ts` | A per-run record with outcomes and reasons. Add the macOS `statfs` delta, which Kudu skips on darwin. |
| Leftover "ownership proof" (owner seen installed before, now absent) | take (idea) | `src/main/services/uninstall-leftovers.ts:118-146, 250-283` | A strong false-positive guard. Use it with a bundle-id history on macOS. |
| macOS uninstaller | ignore (anti-pattern) | `src/main/services/program-uninstaller.ts`, `src/main/ipc/program-uninstaller.ipc.ts` | Fails open and deletes without review (F-0030). |
| Disk analyzer engine | ignore | `src/main/ipc/disk-analyzer.ipc.ts` | Serial, depth 3, logical sizes, double-counts `/` (F-0031). |
| Treemap UI | ignore | `src/renderer/src/pages/DiskAnalyzerPage.tsx` | One level, DOM divs, no tile interaction, files missing. |
| Secure overwrite / file shredder | ignore | `file-utils.ts:159-228`, `ipc/file-shredder.ipc.ts` | Not meaningful on APFS SSDs. |
| DB vacuum of live browser DBs, `killall` browsers | ignore | `services/database-vacuum.ts`, `platform/darwin/browser.ts` | Risky, and the benefit is small. |
| Cloud agent, telemetry, malware/CVE, game mode | ignore | `services/cloud-agent.ts` etc. | Out of scope. |

## Open questions

- Does the macOS Uninstall button really reach the delete loop in the shipped v3.4.0 DMG? I verified the pieces with node probes and read the code path, but did not run the Electron app, and I did not want to risk real data. A throwaway VM or user account test would settle it. This does not block anything, because we are not reusing the code.
- The empty first Analyze click (`selectedDrive: 'C'`) is from reading the code, not tested.
- Do the darwin cache rules hold on macOS 26? Kudu's rule descriptions are not versioned. The T-0010 platform-constraints work should spot-check `com.apple.*` targets (for example `com.apple.iconservices.store` and `com.apple.ATS`) before we import them.
- How large a share of the macOS user base runs Kudu (downloads by asset)? Unverified. It is useful only as a signal of how often the uninstaller issue fires.
