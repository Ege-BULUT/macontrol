# Source deep dive: Homebrew brew (cask uninstall engine)

Task T-0036, author `dive-homebrew-brew`, 2026-09-23. Category: uninstaller (engine).
Scope split with T-0035 (`dive-homebrew-homebrew-cask`, report `homebrew-homebrew-cask.md`). T-0035 owns the **data** (the cask `uninstall`/`zap` stanzas in `cask.json`). This report owns the **engine** that executes them. Where T-0035 already analysed an engine line, this report adds measurements and does not repeat the analysis.

Code read at **Homebrew/brew@3f12c3e** (2026-09-22), sparse clone in `research/sources/homebrew-brew`. The five key files (`abstract_uninstall.rb`, `cask/utils.rb`, `extend/os/mac/cask/utils/trash.rb`, `cask/pkg.rb`) are byte-identical to the installed `/opt/homebrew@570982948a` (Homebrew 7.0.6), checked with `diff`. So the probes below exercised the same code. All paths are relative to `Library/Homebrew/` unless they say otherwise.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/Homebrew/brew (file: `Library/Homebrew/cask/artifact/abstract_uninstall.rb`) | |
| License | BSD-2-Clause ("Copyright (c) 2009-present, Homebrew contributors") | `gh api repos/Homebrew/brew/license` |
| Stars | 49,753 | `gh api repos/Homebrew/brew`, 2026-09-23 |
| Last commit | 3f12c3e, 2026-09-22 ("Merge pull request #24066"); pushed 2026-09-23 | clone, `gh api` |
| Language | Ruby (Sorbet `typed: strict`), with Bash helpers and Fiddle FFI into Foundation/AppKit/libproc | tree |
| Fork | no | `gh api` |
| Open issues | 2 real issues (the other 8 of `open_issues_count` 10 are PRs). Neither is about casks: #24074 (binary relocation) and #24060 (download sandbox and ssh agent) | `gh api repos/Homebrew/brew/issues?state=open` |
| Activity on these files | 8 commits to `abstract_uninstall.rb` from 2026-08-29 to 09-05 (FFI process ancestry, `rmdir` symlink fix). `cask/utils.rb` got an ownership check on 2026-08-12 (1d852a73e) and fixes on 09-12 | `gh api .../commits?path=` |

**Reuse:** BSD-2-Clause lets us copy code or data (for example the `SYSTEM_DIRS`/`UNDELETABLE_PATHS` lists) if we keep the copyright notice and license text in our distribution. We will not copy Ruby code, because macontrol is Swift. Take the design and the lists, with attribution in `THIRD_PARTY_NOTICES`. Post the attribution requirement to T-0003.

## Summary

The engine that runs `brew uninstall --cask` and `--zap`. A cask declares **directives**, and one abstract class runs them in a fixed, commented order: `early_script, launchctl, quit, signal, login_item, kext, script, pkgutil, delete, trash, rmdir` (`cask/artifact/abstract_uninstall.rb:23-35`). The reasons are in the comments:
- launchctl comes before quit, so an app cannot instantly relaunch (:214).
- quit/signal come before kext, so the kext is not in use (:82).
- signal comes after quit, as a backup (:439).
- script comes before pkgutil/delete/trash, so the script still exists (:555).
- kext is unloaded before its file is deleted (:517).

`Uninstall` and `Zap` are two thin subclasses:
- `Uninstall` skips `:signal` on upgrade/reinstall unless `on_upgrade` names it, can skip `:quit`, and defers `:rmdir` to a post phase (`cask/artifact/uninstall.rb:20-54`).
- `Zap` runs everything in order (`cask/artifact/zap.rb:11-13`).
- `Installer#zap` always runs `uninstall_artifacts` first, then the zap stanzas (`cask/installer.rb:763-777`).

This is the most battle-tested teardown sequence for macOS apps in open source (about 7,755 casks use it; see T-0035). Its safety net, though, is thin. It has an exact-match path denylist, a trash fallback that changes ownership and permissions, and no ownership check across receipts or casks. There is no dry run.

## Architecture

- **Data → engine:** each cask's `uninstall`/`zap` hash is validated against the directive whitelist (`abstract_uninstall.rb:51`, `Utils::Data.assert_valid_keys`). The dispatcher is `send(:"uninstall_#{directive}")` over `ORDERED_DIRECTIVES` (`:186-199`).
- **Artifact ordering across the whole cask:** `AbstractArtifact#sort_order` (`cask/artifact/abstract_artifact.rb:72-127`). `Uninstall` sorts right after preflight "as it may depend on other artifacts still being installed", and `Zap` sorts last. `ArtifactSet#to_a` sorts (`cask/artifact_set.rb:20-22`).
- **OS split:** shared code, plus `extend/os/mac/...` prepends. On macOS:
  - `undeletable?` → `MacOS.undeletable?` (`extend/os/mac/cask/artifact/abstract_uninstall.rb:16-19`).
  - Trash → NSFileManager through FFI (`extend/os/mac/cask/utils/trash.rb`, `os/mac/ffi/foundation.rb:12-67`).
  - Process ancestry → `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` + `NSRunningApplication` (`os/mac/ffi/libproc.rb:35-46`, `os/mac/ffi/app_kit.rb:22-39`).
  - Linux uses an XDG trash (`cask/utils/trash.rb:22-86`).
- **Privilege model:** brew runs as the user. Individual commands take `sudo: true` through `SystemCommand`:
  - `delete`: always (`:609-614`).
  - `kext`: always (`:522-550`).
  - `pkgutil`: always (`cask/pkg.rb:32-70`).
  - `launchctl`: tried both without and with sudo (`:217, 234-275`).
  - the trash fallback: `sudo chown` (`cask/utils.rb:123-127`).
- **UI/engine:** a CLI only. Output uses `ohai`/`opoo`/`odie`, and there is no GUI.

## Scanning

Not a disk scanner. What it "finds" is resolved on demand:
- **Paths:** `~` is expanded only as a leading component (`:143`). Relative paths and any `.`/`..` segment are rejected (`:145-153`). Then `Pathname.glob` runs, and each match is dropped if `undeletable?` (`:156-161`). `EPERM` while globbing ends with an instruction to grant Full Disk Access, unless FDA already looks enabled (`:163-167`). FDA is detected by `File.readable?("~/Library/Application Support/com.apple.TCC")` (`cask/utils.rb:28-31`). That is `access(2)`, and whether it reflects TCC is **unverified**: this agent's process has FDA, so the negative case could not be tested (see F-0001 for the same class of probe).
- **launchd jobs:** `launchctl list` in the caller's own domain, parsed as text (`:173-181, 279-288`). `launchctl print <domain>/<label>` goes through `Homebrew::Services::System.launchctl_find_service` (`services/system.rb:131-148`).
- **Running apps:** a JXA `Application(id).running()` per bundle ID (`:299-320`). Wildcards use a JXA dump of `NSWorkspace.runningApplications` (`:322-358`).
- **Receipts:** `pkgutil --pkgs=<regex>`, `--files`, `--pkg-info-plist` (`cask/pkg.rb:13-110`).
- There are no sizes, no concurrency, no progress reporting and no cancellation. Everything is sequential, with fixed `sleep 1` or `sleep 3` pauses after most steps (`:246, 274, 476, 513, 535, 588`).

## Deletion & rules

| Directive | Mechanism | Lines | Assessment |
|---|---|---|---|
| `launchctl` | Wildcards via `find_launchctl_with_wildcard`. Then, for each of no-sudo and sudo: `launchctl remove <label>` and `rm -f` of `{~,}/Library/Launch{Agents,Daemons}/<label>.plist`. Also an "undocumented and untested" path form (`unload -w` + `rm`) | `:172-181, 214-277` | Legacy `remove`, not `bootout` (F-0023). The plist must be named after the label (F-0055). The wildcard sees only running jobs in the user domain and is unanchored (**F-0067**, extra evidence below) |
| `quit` | JXA `Application(id).quit()`, looped until not running, 10 s timeout. Skipped when there is no GUI session or when the app is an ancestor of brew (`hosting_brew?`) | `:91-128, 367-437` | Good guards. It needs an Automation grant (`:290-297`), and the loop has no sleep, so it spawns `osascript` again and again for up to 10 s (code-read) |
| `signal` | `Process.kill(sig, *pids)`, with pids from the `application.<id>.N` rows of `launchctl list`. Sent as the user, never root. Has a TODO about the owning user | `:443-478` | Conservative. Ported as-is |
| `login_item` | AppleScript `System Events` → `delete every login item whose path/name is …`. Paths are derived from the cask's `app` artifacts | `:488-515` | Covers legacy login items only. SMAppService / Background Task Management items are not touched. "Success" even when nothing matched (code-read) |
| `kext` | `kextstat -l -b` → `kextunload -b` → `kextfind -b` → `sudo rm -rf` | `:518-553` | Legacy. SIP and system extensions make this rare |
| `script` / `early_script` | Runs a staged executable with args. `force` skips a missing script | `:210-212, 565-589` | n/a for macontrol (we run no vendor scripts) |
| `pkgutil` | `pkgutil --pkgs=<regex>`, then for each: `sudo xargs rm` over the BOM files, then the specials, then `rmdir.sh` over the BOM dirs deepest-first, then `rmdir` of the install root, then `pkgutil --forget` | `:592-600`, `cask/pkg.rb:29-138` | Good structure. **No check that another receipt lists the same file** (covered by F-0066's "after", extra evidence below) |
| `delete` | `sudo xargs -0 rm -r -f --` over the resolved globs | `:603-616` | Always root, even for the 91 `~/…` entries in the cask data (T-0035's `cask.json`). The only guard is the exact-match `undeletable?` |
| `trash` | `NSFileManager trashItemAtURL:resultingItemURL:error:` through Fiddle. On failure it calls `gain_permissions` with `-R` and retries | `:619-643`, `extend/os/mac/cask/utils/trash.rb:16-38`, `os/mac/ffi/foundation.rb:12-67` | The Trash call is right. **The fallback changes ownership, mode, flags and ACLs and never restores them** (**F-0070**) |
| `rmdir` | Recursive "remove if empty", where `.DS_Store` counts as empty. It does not follow symlinks (2abb5d2e5, 2026-09-03) | `:650-700`, `cask/utils/rmdir.sh` | Take it. Note that `rmdir.sh:29` also deletes *any* broken symlink directly inside each BOM dir, not only the package's own |

**Guards.**
- `MacOS.undeletable?` is `UNDELETABLE_PATHS.include?(Pathname.new(path).expand_path)` (`cask/macos.rb:387-389`): a set of 133 `~/…` folders plus 227 `SYSTEM_DIRS` (`:6-236, 241-378`).
- The match is exact, so children pass. The TODO at `:239-240` says "There should be a way to specify a containing directory under which nothing can be deleted".
- `expand_path` is lexical, so firmlink aliases, case variants and symlinks are not canonicalised.
- The tests cover only lexical forms (`test/cask/macos_spec.rb:5-54`).
- Both classes are already filed: F-0024 (exact list) and F-0039 (firmlink alias).
- The generic `undeletable?` (`!parent.writable?`, `:702-705`) is *replaced*, not combined, on macOS.

**Data-driven?** Yes: all targets come from the cask stanzas (T-0035). The engine has no heuristics of its own apart from wildcard expansion. There is no dry run: `brew uninstall` has `--force` and `--zap` but no preview (`cmd/uninstall.rb` at HEAD). The closest thing is reading the stanza (`brew cat`/`info --json`).

**Lint-time protections** (runs in CI on the cask repo, not at runtime):
- `RuboCop::Cop::Cask::UninstallWildcard` requires at least 3 ID parts in a `launchctl`/`quit`/`signal` wildcard (`rubocops/cask/uninstall_wildcard.rb:13-49`).
- `SharedFilelistGlob` forces `.sfl*` globs (`rubocops/cask/shared_filelist_glob.rb`).
- There is **no** cop for over-broad `trash`/`delete` paths (the file list under `rubocops/cask/` has none).

## UI

A CLI only. Output is line logs (`ohai "Removing launchctl service …"`, `opoo` warnings). The user sees the list of paths only as they are processed, never before. There is no selection, no size display, no reveal and no undo, apart from what the macOS Trash gives for `trash:` items. There is nothing to reuse for macontrol's UI except the wording of the permission hints (`automation_access_instructions` `:290-297`, `privacy_security_preference_pane` `cask/utils.rb:17-26`), which are version-aware (Monterey or older → "System Preferences").

## Tests & quality

- RSpec with Sorbet `typed: strict` everywhere. `AGENTS.md` requires `brew lgtm` (typecheck + style + tests) and red-green TDD for fixes, and it forbids `T.must`/`T.unsafe`.
- Shared uninstall/zap examples: `test/cask/artifact/shared_examples/uninstall_zap.rb` (364 lines). They cover launchctl (user, system, sudo failure, wildcard), pkgutil, kext, quit (no GUI, host app), signal (incl. skip on upgrade), delete/trash, script, early_script and login_item. There are also `pkg_spec.rb` (198), `utils/trash_spec.rb` (68), `macos_spec.rb` (55) and `uninstall_spec.rb` (378).
- Gaps found while reading them:
  - The wildcard fixture's matching rows all have a live PID (`uninstall_zap.rb:108-116`), so the idle-job case is untested (see F-0067).
  - `:trash` shared examples run only when `HOMEBREW_TESTS_COVERAGE` is set (`uninstall_zap.rb:285`).
  - The trash-fallback spec covers only "retry succeeds" (`test/cask/utils/trash_spec.rb:21-33`).
  - The macOS trash override ignores the `command:` it is given and hard-codes `::SystemCommand` (`extend/os/mac/cask/utils/trash.rb:16,23`), so test doubles such as `NeverSudoSystemCommand` cannot intercept its `sudo chown`.
  - The launchctl path form is explicitly "undocumented and untested" (`abstract_uninstall.rb:257`).
- Code is small and well commented. The order is documented in comments right next to the directives.

## Known problems

1. **The trash fallback changes ownership and permissions and never restores them** (**F-0070**, verified with brew's own code).
   - Case A (real commands): a scratch item in a read-only parent. Its `uchg` flag and deny-delete ACL are stripped, and it is left in place as untrashable.
   - Case B (recorded commands): an item not owned by the user gets `sudo chown -R -- <user>` and then still fails.
   - Root-owned items in root-owned folders always take this path. The cask data trashes 16 `/Library/PrivilegedHelperTools/*` and 53 `/Library/LaunchDaemons/*` paths. For example, `xcodes-app` trashes its helper but neither its plist nor its job.
   - History: brew#19903 (a spurious `sudo` ownership prompt during `--zap`, a regression reverted in #19941). The ownership check itself arrived only on 2026-08-12 (1d852a73e).
2. **The wildcard launchctl lookup keeps only rows with a non-zero PID, from the user-domain `launchctl list`, and matches unanchored** (`:173-181`). This is filed as **F-0067** by T-0035. Extra evidence from `research/bench/homebrew-brew/wildcard_probe.rb`, which calls the real method on this Mac:
   - `com.ollama.*` → `[]` while `com.ollama.ollama (pid -)` is loaded.
   - `homebrew.mxcl.*` → `[]` while `homebrew.mxcl.mwb (pid -)` is loaded.
   - `com.cloudflare.1dot1dot1dot1.macos.*` → `["application.com.cloudflare.1dot1dot1dot1.macos.75587622.75587627"]`. That is the GUI app's own job, matched because the pattern is not anchored. The real root daemon `com.cloudflare.1dot1dot1dot1.macos.warp.daemon` (`launchctl print system/…`: running, pid 350) is not listed at all.
   - The cask data has 26 wildcard `launchctl` entries in 21 casks. `paragon-ntfs` relies only on `com.paragon-software.ntfs*`.
   - For contrast, `expand_bundle_id` *is* anchored and case-insensitive, with a comment explaining why (`:355-357`).
3. **pkgutil removal has no shared-ownership check** (`cask/pkg.rb:29-60, 74-99`). This is covered by **F-0066**'s "after". Extra evidence from `research/bench/homebrew-brew/pkg_shared_probe.rb`, a read-only call of the real `pkgutil_bom_files`:
   - For receipt `com.apple.pkg.XProtectPayloads_10_15.16U4413`, all 43 files `#uninstall` would `sudo rm` are also listed by the current receipt `…16U4449`. `pkgutil --file-info` shows both owners.
   - On this Mac, 58 files are listed by 2 or more receipts.
   - In the cask data, 66 `pkgutil` IDs are claimed by 2 or more casks, and some of them are in plain `uninstall`: `com.microsoft.pkg.licensing` (Excel, Word, PowerPoint, Outlook, Office), `io.macfuse.installer.components.core` (macfuse, securesafe) and `com.microsoft.OneDrive` (onedrive, microsoft-office).
4. **`delete` always runs as root** (`:609-614`), including for 91 home-directory entries. Root `rm -rf` on a path the user controls is a confused-deputy pattern: a symlinked intermediate folder redirects it. Only the leaf name has to match, so the impact is limited. Code-read, not filed.
5. **`login_item`** covers only legacy System Events login items and reports success when nothing matched (`:494-514`). Code-read.
6. **`brew ruby` switches developer mode on as a side effect** (lesson for probes, reverted with `brew developer off`). Set `HOMEBREW_DEVELOPER=1` for the run instead.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Teardown order `ORDERED_DIRECTIVES` and the reasons in its comments | **take** (design) | `cask/artifact/abstract_uninstall.rb:23-35, 82, 214, 439, 517, 555` | Proven on about 7.7k casks. Reimplement in Swift: bootout → quit → signal → login items → (kext) → receipts → delete/trash → rmdir-if-empty |
| Uninstall vs zap split (zap = uninstall + extra; `rmdir` as a post phase; signal skipped on upgrade) | **take** (design) | `cask/artifact/uninstall.rb:20-54`, `cask/installer.rb:763-777` | Maps to macontrol's "Remove app" vs "Remove app + leftovers" |
| `hosting_brew?`: never quit or signal an ancestor of our own process | **take** (idea) | `abstract_uninstall.rb:367-400`, `os/mac/ffi/libproc.rb:35-46`, `os/mac/ffi/app_kit.rb:22-39` | macontrol must never kill Terminal or its own host. `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` walks through root-owned `login` |
| Anchored, case-insensitive bundle-ID wildcard | **take** | `abstract_uninstall.rb:343-365` | Correct and small. Use the same rule for launchd labels (this is F-0067's fix) |
| Quit via JXA/osascript polling | **rewrite** | `abstract_uninstall.rb:91-128, 299-437` | Use `NSRunningApplication.terminate()` + KVO on `isTerminated` with a timeout, then `forceTerminate()`. No `osascript` spawns. Whether terminate needs an Automation grant is **unverified** |
| `find_launchctl_with_wildcard` / `uninstall_launchctl` | **rewrite** | `abstract_uninstall.rb:172-181, 214-277` | F-0067 (idle and root jobs, unanchored), F-0023 (`bootout`), F-0055 (label ≠ file name). Find jobs from the plists (`Label`, `Program`), then `bootout` |
| Path resolution guards (leading `~` only, reject relative and `.`/`..`) | **take** | `abstract_uninstall.rb:139-170` | Cheap and correct |
| `SYSTEM_DIRS` + `UNDELETABLE_PATHS` lists | **take the data** (BSD-2, attribution) and **rewrite the check** | `cask/macos.rb:6-379` | A good seed list. The check must be subtree-aware and use canonical identity (F-0024, F-0039) |
| Trash via `trashItemAtURL` + `resultingItemURL` | **take** | `os/mac/ffi/foundation.rb:12-67` | Native `FileManager.trashItem(at:resultingItemURL:)`. Keep the resulting URL for undo (T-0026) |
| `gain_permissions` fallback (chflags/chmod/`-N`/`sudo chown`) | **ignore** (do not port) | `cask/utils.rb:95-153`, `extend/os/mac/cask/utils/trash.rb:21-26` | F-0070. Route root-owned items to the helper and never change metadata |
| `Cask::Pkg` receipt removal (files → specials → dirs deepest-first → forget) | **improve** | `cask/pkg.rb:29-138`, `cask/utils/rmdir.sh` | Keep the order. Add per-file owner checks (`pkgutil --file-info`, or munki's reference count, F-0066). Keep broken-symlink cleanup to the package's own entries |
| `recursive_rmdir` (`.DS_Store` counts as empty, no symlink follow) | **take** | `abstract_uninstall.rb:650-700` | Right for vendor folders after the app's own children are gone |
| `login_item` via System Events | **rewrite** | `abstract_uninstall.rb:488-515` | Legacy only. Show SMAppService / Background Task Management items and link to System Settings → Login Items |
| `kext` unload/remove | **study** | `abstract_uninstall.rb:517-553` | Rare on current macOS. Needs the root helper. Low priority |
| `script`/`early_script` | **ignore** | `abstract_uninstall.rb:206-212, 555-589` | macontrol does not run vendor scripts |
| FDA detection by `File.readable?` of the user TCC folder | **study** | `cask/utils.rb:15, 28-31` | Probably `access(2)`-based. Test with the throwaway-app method (F-0001 class) before relying on anything like it |
| Wildcard lint (at least 3 ID parts) | **take** (as a rule-build check) | `rubocops/cask/uninstall_wildcard.rb:13-49` | Apply to macontrol's rule JSON in CI (T-0035's rule builder) |

## Open questions

1. Does launchd refuse to exec a system-domain job whose `Program` is no longer root-owned? This decides whether F-0070 is a local privilege escalation or "only" leaves a broken, user-owned helper. **Unverified.** Needs a VM test with sudo.
2. Does `NSRunningApplication.terminate()` need an Automation (Apple Events) grant, the way the JXA `quit` does? **Unverified.** Test with a throwaway `.app` per the M-0001 TCC lesson, never against the user's real apps.
3. Is `File.readable?(~/Library/Application Support/com.apple.TCC)` a reliable FDA probe from a process without FDA? **Unverified** here, because this agent's process has FDA (`listdir` succeeded).
4. Can macontrol remove SMAppService / BTM login items for another app? `sfltool resetbtm` resets everything. Hand this to T-0010 (platform constraints).
