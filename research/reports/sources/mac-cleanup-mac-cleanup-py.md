# mac-cleanup-py: source deep dive

Task T-0017, by dive-mac-cleanup-mac-cleanup-py, 2026-09-23. All code citations refer to `mac-cleanup/mac-cleanup-py@ba4d6ef`, cloned to `research/sources/mac-cleanup-mac-cleanup-py`.

## Facts

| | |
|---|---|
| URL | https://github.com/mac-cleanup/mac-cleanup-py |
| License | Apache-2.0: `LICENSE` and `pyproject.toml:5`, and `gh api` agrees. No NOTICE file. The LICENSE copyright appendix still has the `[yyyy] [name of copyright owner]` placeholder (`LICENSE:189`). The author is listed only as `efa2d19` (`pyproject.toml:6`). |
| Stars / forks | 2,374 / 99 (`gh api repos/mac-cleanup/mac-cleanup-py`, 2026-09-23) |
| Created / pushed | 2022-06-29 / 2026-04-14. Last commit on `main`: ba4d6ef, 2025-10-04, "Test on Python 3.14 release candidate 2 and on macOS 26". |
| Version | 3.3.0 (`pyproject.toml:3`) |
| Language | Python 3.10-3.14, 1,742 lines in `mac_cleanup/`, 516 of them in `default_modules.py` |
| Runtime deps | rich, attrs, inquirer, toml, beartype, xattr (`pyproject.toml:33-40`) |
| Distribution | Homebrew formula `mac-cleanup-py`, PyPI `mac-cleanup` (`README.md:81-87`) |
| Open issues | 10 issues (the other 11 of the 21 open items are PRs). Themes: estimate vs. actual (#279), hangs (#192, 25 comments), a root-owned config crash (#266), a request for module descriptions in the picker (#80, #110, #143), a GUI request (#206), and new targets (rustup #275, OrbStack #274, background items #22). |
| Predecessor | mac-cleanup/mac-cleanup-sh: 2,816 stars, MIT, "Copyright (c) 2020 Florian Wartner", last push 2023-05-21, not archived. Its README has no deprecation notice (grep). |

## Summary

mac-cleanup-py is a terminal cleanup script. The user ticks "modules" in an inquirer checkbox. Each module is a Python function that registers `Path` targets (turned into `rm -rf`) and `Command` steps (shell commands such as `brew cleanup -s` or `docker system prune -af`). A `-n` dry run sums file sizes for the `Path` targets, and a real run deletes permanently and reports a whole-disk free-space delta.

For macontrol, its value is the **target list**: 43 modules, 102 `Path` literals and 26 `Command` steps. They cover system and user caches and logs, the Trash, Xcode, simulators, iOS backups, Homebrew, npm/pnpm/yarn/bun, CocoaPods, Go, Gradle, Composer, Conan, NuGet, Poetry, pyenv, Docker, Steam, Minecraft, Teams, Arc, Chromium, Obsidian, EA, Telegram, Dropbox and Google Drive. It also contributes the pattern "run the tool's official clean command, but size the tool's cache folder for the estimate" (`.dry_run_only()`).

The engine is a negative example. Glob targets never delete (F-0025, verified), the only guard is skipped for globs, external commands can hang forever (F-0029), sizes are logical and double-count links and clones, and everything is a permanent `rm -rf`.

Lineage: the rule list comes from mac-cleanup-sh (MIT). For example, `/private/var/folders/bh/*/*/*/*` is at `mac-cleanup-sh/mac-cleanup:154` and `default_modules.py:23`, `MobileSync/Backup/*` at `:190` and `:74`, `~/*.hprof` at `:444` and `:417`, and `sudo dscacheutil` at `:450` and `:423`. The shell original expanded globs at the call site and used one resolved `path_list` for both the dry run (`du -ck`) and the delete (`rm -rfv "$path"`) (`mac-cleanup:107-122`). The Python port lost that property.

## Architecture

- **Entry point.** `mac_cleanup/__init__.py:11` sets `main = EntryPoint().start`. `main.py:52-102` clears the console, loads `Config`, handles `-p`/`-c`, runs the enabled module functions (which register work), then either runs the dry run and asks "Continue?" or calls `cleanup()`.
- **Args** are parsed at import time from `sys.argv` into a module-global `args` (`parser.py:43-44`). Every module reads `args.force`, `args.update` and so on as globals (`core_modules.py:32`, `default_modules.py:260`).
- **Rule DSL** (`core.py`, `core_modules.py`):
  - `Collector` is a Borg singleton (`core.py:36-48`) used as a context manager. `with clc as unit:` opens a `Unit(message, modules)` and appends it to the shared `_execute_list` on exit (`core.py:62-86`).
  - `BaseModule.with_prompt(msg)` adds a y/n prompt, which `--force` skips (`core_modules.py:23-42`).
  - `Command(str)` is a shell string, with `.with_errors()` to capture stderr (`:90-111`).
  - `Path(str)` builds `rm -rf '<expanded path>'` (`:114-153`), with `.dry_run_only()` to count the path in the estimate but never delete it (`:134-147`).
- **Rules are code, not data.** Each default module is a top-level function in `default_modules.py`, discovered by `inspect.getmembers(default_modules, isfunction)` (`config.py:204-207`). Modules decide at *registration* time whether to add targets (`if check_exists(...)`, `if cmd("type 'brew'")`), so importing and enabling a module already runs shell probes.
- **Custom modules.** Every `*.py` under a user-chosen folder, default `~/Documents/mac-cleanup/` (`config.py:144`), is found with `rglob` and executed with `SourceFileLoader.exec_module` (`config.py:209-247`). A later file overrides a same-named function. `module_template.py` documents the DSL.
- **Config** is TOML at `$XDG_CONFIG_HOME/mac_cleanup_py/config.toml` or `~/.mac_cleanup_py` (`main.py:17-20`), holding `enabled: [names]` and `custom_path`. Stale names are pruned and written back (`config.py:79-100`).
- **UI.** `rich` Progress and Panels (`progress.py`, `console.py`) plus an `inquirer.Checkbox` (`config.py:181-188`). UI and engine are not separated: modules call `ProgressBar.prompt` from inside `_execute` (`core_modules.py:49-51`).

## Scanning

There is no general scanner. "Scanning" is only the dry-run size estimate for `Path` targets.

- **API.** `pathlib.Path.glob()` with `**/*` plus `stat(follow_symlinks=False).st_size` per entry (`core.py:109-187`). If a target contains `*`, `[` or `]`, `_get_size` splits it at the first wildcard and globs the rest (`:127-177`).
- **Concurrency.** One `ThreadPoolExecutor()` task per target, with default worker count, results consumed via `as_completed` (`core.py:211-233`). The walk inside a target is serial Python. Mapping a result back to its path is an O(n^2) `next(...)` scan (`:225`), which is negligible at about 100 targets.
- **Size semantics.** Logical `st_size`, directories' own `st_size` included, hard links counted once per link, APFS clones counted at full size. Verified with the source's own `_Collector._get_size` on a fixture (8 MiB file + hard link + `cp -c` clone): it returns 25,165,824 bytes (3x). `du -sk` says 16,384 KiB, and deleting all three frees about 8 MiB. This is the defect class of F-0004 and F-0010, so no new finding was filed.
- **Progress and cancellation.** A rich progress bar counts completed *targets*, not bytes. Ctrl-C calls `executor.shutdown(wait=False)` without `cancel_futures`, so running walks continue in their threads (`core.py:228-230`).
- **Memory.** Only running totals are kept, and no tree is built. That is fine for an estimate but gives nothing to drill into.
- **Speed.** Not measured, to avoid heavy disk I/O on a sluggish machine. A per-file Python `stat` loop is expected to be far slower than `getattrlistbulk` engines (T-0006). Unverified.

## Deletion & rules

- **Where the rules live.** `mac_cleanup/default_modules.py:8-516`, as 43 functions. The README list (`README.md:30-72`) uses different names from the functions, for example `chromium` vs `chromium_caches` and `ea` vs `ea_caches`, and the picker shows the function names.
- **How targets are removed.**
  - `Path` runs `rm -rf '<path>'` through `Popen(shell=True)` (`core_modules.py:124`, `utils.py:21`). The delete is permanent, with no Trash, no journal and no per-item result.
  - `Command` runs arbitrary shell strings.
  - Privilege escalation is plain `sudo` inside the command string (`default_modules.py:423-424, 430`). The sh original ran `sudo -v` plus a keep-alive loop (`mac-cleanup-sh/mac-cleanup:130-139`). Users run the Python tool under `sudo` (#279, #266).
- **Globs never expand at delete time.** Verified. Single quotes stop shell globbing, so the 28 glob targets delete nothing: Trash, `~/Library/Caches/*`, DerivedData, Archives, iOS backups, DiagnosticReports and others. The dry run does count them. This matches open issue #279: "estimates ~80GB ... removes 0B". Probe: `Path("<fx>/Caches/*")` gave a dry-run size of 1,052,864 B, and all 4 fixture entries survived `_execute()`. **F-0025.**
- **Guard.**
  - `check_deletable` (`utils.py:69-100`) is a raw string-prefix denylist: `/System`, `/usr`, `/sbin`, `/Applications`, `/Library`, `/usr/local` and 5 home folders. Then comes the `com.apple.rootless` xattr check.
  - Any path with `*` returns True before these checks (`:92-94`), and so does `check_exists` (`:62-64`). Probe: `/System/*` -> True and `~/Documents/*` -> True.
  - SIP by xattr misses restricted files without the xattr. For example, `/usr/bin` is `restricted` in `ls -lOd` but has no `com.apple.rootless` here. The prefix list catches `/usr` anyway.
  - This is folded into F-0025, and the guard requirements are in F-0024.
- **Path quoting.** Verified. A target containing `'` breaks the command. A directory named `x'; touch INJECTED; echo '` made the source's `Path._execute` create `INJECTED`, because the path is pasted into shell source. Default rule strings are static, but `brew --cache` output, `$GOPATH` and `$PYENV_VIRTUALENV_CACHE_PATH` feed `Path()` (`default_modules.py:254-257, 305-308, 372-375`). This is the same class as F-0002 and F-0018, so no new finding.
- **Dry run.** `-n` sizes `Path` targets only (`core.py:195-209`). `Command` effects (brew, docker, gem) are not estimated, and TODOs say so (`default_modules.py:269, 278`). The dry run then offers to continue straight into the real clean (`main.py:85-102`).
- **Risk handling.**
  - Only 8 `with_prompt` calls exist (grep): `~/Library/Caches/*`, gradle, poetry, nuget, `~/*.hprof`, simulators erase, docker prune and Telegram.
  - Irreplaceable data has no prompt: `ios_backups` (`:71-74`), Xcode `Archives/*` (`:81`), and `arc`. The README calls `arc` "Clears Arc Browser caches" (`README.md:32`), but it deletes `History`, `Cookies` and `Web Data` (`default_modules.py:505-516`), and those non-glob targets really are deleted. The same `ios_backups` and Archives problem was filed for Mac Sai as F-0027, so this evidence went to T-0016 as a comment.
- **Rule bugs worth knowing before copying.**
  - `/private/var/folders/bh/*/*/*/*` (`default_modules.py:23`, inherited from sh `:154`) hardcodes one user's per-user temp prefix. Here `getconf DARWIN_USER_CACHE_DIR` is `/var/folders/65/...`. Use `confstr(_CS_DARWIN_USER_CACHE_DIR)` instead, and do not wipe `T/` or `0/` of live processes.
  - `[!Library|var|tmp|Media]*` and `[!PreferencesCaches|Caches|AddressBook|Trial]*` (`:99, :103`) are character classes, not alternation. They are `dry_run_only`, so only the estimate is wrong.
  - `obsidian_caches` repeats `DawnWebGPUCache` (`:478-479`), and `minecraft` repeats `crash-reports` (`:165, :168`).
  - `~/Music/iTunes/iTunes Media/Mobile Applications/*` (`:68`) is likely obsolete, since iTunes dropped iOS apps in 12.7 (unverified on disk).
  - `steam` deletes `steamapps/download` (`:154`), which holds in-progress downloads.
- **Side effects.**
  - `docker` launches Docker Desktop silently if it is not running (`open -jga Docker`, `:285-299`).
  - `telegram` does `killall -KILL Telegram` and then reopens it (`:441-452`).
  - `xcode_simulators` runs `xcrun simctl erase all` behind a prompt (`:94-97`). The osascript quit lines nest single quotes inside single quotes (`:91-93`), so the AppleScript is malformed (unverified at runtime).
  - `inactive_memory` runs `sudo purge`. That is RAM, not disk.

## UI

- Terminal only. There is a rich live progress bar per `Unit` (`progress.py:25-34`, `transient=True`), panels for results, and an inquirer checkbox of bare function names for module selection (`config.py:181-183`). There is no drill-down, no reveal in Finder, no per-item selection and no visualization. A GUI was requested in #206 (open).
- The picker has no descriptions. Issue #80 has been open since 2023-05-31; the maintainer's reason was "I don't think it'll fit inside 100x30".
- Prompts stop the progress bar and ask y/n (`progress.py:36-84`). `--force` suppresses all of them (`core_modules.py:32-33`).
- Hangs: external commands run with no timeout and hidden stderr under the live bar. See #192 (open, 25 comments), #272 and #211. **F-0029.**
- `-v` prints each target and its size during the dry run (`main.py:77-78`). #280 reported that it does not work; it is closed.

## Tests & quality

- 8 pytest files, 1,642 lines. CI runs tox on macos-latest with Python 3.10-3.14 and on macos-26 (`.github/workflows/tox.yml`). Also CodeQL, pyright strict (`pyproject.toml:102-108`), ruff, black, isort and docformatter.
- The tests are mostly monkeypatch-driven unit tests. `default_modules.py`, the actual rules, is **excluded from coverage** (`pyproject.toml:93-97`) and has no tests.
- `test_core_modules.py:147` pins the string `rm -rf '<path>'`, and `test_execute` (:196-225) deletes only non-glob temp files. The glob path is untested, which is why F-0025 went unnoticed.
- `tests/test_config.py:247-284` calls the real `set_custom_path`, which runs `mkdir(parents=True)` on `~/Documents/my-custom-modules` and `~/Documents/mac-cleanup/` in the **real home** (`config.py:147-150`). I did not run the suite for that reason (TCC prompt risk and home pollution).
- Code style is tidy but over-built for its size. There is a Borg singleton plus a proxy, name-mangled privates read back through `getattr(self, "_Collector__temp_message")` (`core.py:50-60`), beartype decorators on internal helpers, and `__exit__` re-raising `exc_type(exc_value)`, which loses the traceback (`core.py:77-78`).
- Error handling: a single top-level `catch_exception` logs and exits (`error_handling.py`). Per-item failures are invisible, because stderr goes to DEVNULL.

## Known problems

| # | Problem | Evidence | Board |
|---|---|---|---|
| 1 | Glob targets never delete. The dry run counts them and the clean reports 0B. | Probe, `core_modules.py:124`, #279 | F-0025 |
| 2 | The guard is skipped for any `*` path, uses string-prefix matching and an xattr-only SIP check. | Probe, `utils.py:62-100` | folded into F-0025 (see F-0024) |
| 3 | External commands have no timeout, hidden stderr and inline sudo, so runs hang. | `utils.py:21`, #192, #272, #211 | F-0029 |
| 4 | Permanent `rm -rf`, no Trash or journal | `core_modules.py:124` | same class as F-0012 |
| 5 | Path pasted into shell source: `'` breaks it and allows injection | Probe | same class as F-0002, F-0018 |
| 6 | Logical sizes, hard links and clones counted repeatedly (3x on the fixture) | Probe | same class as F-0004, F-0010 |
| 7 | iOS backups, Xcode Archives and Arc cookies/history deleted without a prompt; the picker has no descriptions | `default_modules.py:71-81, 505-516`, #80 | same class as F-0027 (T-0016 comment) |
| 8 | "Removed" is a `statvfs("/")` delta, and values <= 0 print as "0B" | `main.py:25-50`, `utils.py:114-115` | part of F-0025 |
| 9 | Hardcoded `/var/folders/bh`; bracket globs used as alternation | `default_modules.py:23, 99, 103` | report only |
| 10 | Running under sudo leaves a root-owned config, and the next non-sudo run crashes | #266 | report only |

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Cleanup target list (paths) | take (with attribution) | `mac_cleanup/default_modules.py:8-516`, origin `mac-cleanup-sh/mac-cleanup` | Apache-2.0 plus MIT lineage, both permissive. Convert to macontrol JSON rules with `root`, `pattern`, `risk` and `disposal`. Drop or fix `folders/bh`, the bracket globs and obsolete iTunes paths. Put iOS backups, Archives and browser History/Cookies/Web Data in the user-data tier (F-0027). Keep credit to both projects in NOTICE. |
| "Official command + size path" pattern | improve | `default_modules.py:132-139, 311-375` (`Command(...)` + `Path(...).dry_run_only()`) | Good idea: let npm/yarn/pnpm/bun/pod/go/composer clean their own caches (they know their locking), and size their folders for the preview. Run through a ToolRunner with argv, a timeout and stdin=/dev/null (F-0029). |
| Official clean commands list | take | `default_modules.py:256, 272, 291, 317, 327, 337, 347, 357, 370, 138, 458, 94-96` | These are facts about third-party CLIs (`brew cleanup -s`, `npm cache clean --force`, `pnpm store prune`, `bun pm cache rm`, `pod cache clean --all`, `go clean -modcache`, `composer clearcache`, `conan remove "*" -c`, `docker system prune -af`, `xcrun simctl erase all`). Verify each on current tool versions. |
| Per-rule warning copy | study | `with_prompt(...)` strings in `default_modules.py:19-21, 96, 230-232, 291-294, 407-409, 417, 446-448, 466-468` | Useful wording for consequences ("Gradle cache ... chunky and kinda long to reinstall", "All non-local Poetry venvs will be deleted"). |
| Module DSL (Collector/Unit/Path/Command) | ignore | `mac_cleanup/core.py`, `core_modules.py` | Rules as executable Python, a global singleton, and shell strings. macontrol uses data rules. |
| Delete guard `check_deletable` | rewrite | `mac_cleanup/utils.py:69-100` | Glob bypass, string prefix, xattr-only SIP (F-0025, F-0024). |
| `rm -rf` via `Popen(shell=True)` | rewrite | `core_modules.py:124`, `utils.py:9-29` | Glob no-op, quoting and injection, permanent, no per-item result (F-0025, F-0012, F-0029). |
| Dry-run sizing `_get_size` | ignore | `core.py:109-187` | Logical size, repeated counting, serial per-file Python stat. Use the engine from T-0006 and the size rules from T-0009. |
| Result "Removed" via statvfs delta | rewrite | `main.py:25-50` | Replace with a per-item freed sum. A volume delta may be shown separately. |
| Custom modules loader | ignore | `config.py:209-247` | Executes arbitrary Python from `~/Documents`, often under sudo. macontrol user rules must be schema-validated data. |
| TOML config (enabled list, XDG path) | study | `config.py:102-125`, `main.py:17-20` | Persisting the selected rule set and pruning stale names (`config.py:79-100`) is worth copying as behaviour. The format is irrelevant. |
| rich/inquirer TUI | ignore | `progress.py`, `console.py`, `config.py:161-202` | Terminal UI. Nothing applies to a native app. |
| Tests | ignore | `tests/` | Mock-heavy, rules excluded from coverage, and the suite writes into the real `~/Documents`. |

## Open questions

1. Which of the 102 target paths still exist and matter on macOS 26 with current app versions? Candidates to check: Chrome `Default/Application Cache`, iTunes Mobile Applications, Teams classic vs new Teams paths, and Arc. Unverified. This needs a survey against real installs (T-0005/T-0010 scope).
2. Is a list of filesystem paths copyrightable expression at all, and which attribution does macontrol owe? That covers mac-cleanup-py (Apache-2.0, no NOTICE, placeholder copyright) and mac-cleanup-sh (MIT, Florian Wartner 2020). Handed to T-0003.
3. Should macontrol run third-party clean commands at all (brew, docker, npm), or only delete their cache folders? Commands respect tool locks but need the ToolRunner from F-0029. Folder deletes are simpler but can race a running tool. This is a product decision.
4. `~/Library/Caches/*` as one bulk target: combine it with the live-cache guard in F-0015 before copying. The per-app split is unverified here.
5. The sudo-prompt-under-progress-bar mechanism for #192 was not reproduced, because it needs a TTY and a password. It is marked plausible in F-0029.
