# Source deep dive: munki removepackages / rmpkgs (munki/munki)

- **Task:** T-0037, researcher `dive-munki-munki`, 2026-09-23. Parent: T-0005 (uninstaller survey).
- **Clone:** `research/sources/munki-munki` at `28d92fe` (2026-08-24, "Multiple typo fixes in munki cli tools source code", branch `main`). Paths below are relative to that clone. `code/cli/munki/shared/installer/rmpkgs.swift` has the same blob (`4379bf7`) on `main`, on the `v7.3.0` release, on `v7.4.0b1` (2026-09-21) and on the `Munki7_4dev` branch (`gh api .../contents/...?ref=<ref> --jq .sha`), so every finding below applies to the shipping Munki 7.
- **"Verified":** `research/bench/munki-munki/run.sh` compiles munki's own `rmpkgs.swift`, `sqlite3.swift`, `errors.swift` and `utils/{fileutils,cliutils,plistutils,stringutils}.swift` **unmodified**, plus `stubs.swift` (logging, prefs and status only) and `main.swift`. `fixture` mode builds a receipt DB whose paths all live in a `mktemp -d` tree and runs munki's `removePackages()`. `rebuild` mode runs munki's `initReceiptDB(forcerebuild: true)` against this Mac's real receipts, read-only, into the temp dir. Apple's receipt DB is never touched: every call passes `noUpdateApplePkgDB: true`, and the probe runs as a normal user, so `pkgutil --forget` could not succeed anyway. macOS 26.6, system SQLite (`import SQLite3`, CLI reports 3.51.0). The output of both modes is in `research/bench/munki-munki/results-2026-09-23.txt`.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/munki/munki (homepage https://www.munki.org/munki/), not a fork, not archived | `gh api repos/munki/munki` |
| License | Apache-2.0. The API says NOASSERTION; `LICENSE.md` is the Apache 2.0 short form, and every Swift file carries the Apache header, for example `rmpkgs.swift:8-18`. There is no NOTICE file in the root. | `LICENSE.md`, `ls` |
| Stars / forks | 3,472 / 371 | `gh api repos/munki/munki` (2026-09-23) |
| Created / last commit / last push | 2014-09-19 / `28d92fe` 2026-08-24 on `main` / 2026-09-21 (v7.4.0b1) | same, plus `git log -1` |
| Releases | v7.4.0b1 2026-09-21 (pre-release), v7.3.0 2026-08-25, v7.2.0 2026-06-30, v7.1.2 2026-05-11 | `gh api .../releases` |
| Language | Swift 1.60 MB, Python 0.99 MB (the Munki 6 client in `code/client`, kept in the tree), Shell, Obj-C. The Swift CLI suite is 29,652 lines. | `gh api .../languages`, `wc -l` |
| rmpkgs size | `rmpkgs.swift` 670 lines, and the `removepackages` CLI wrapper is 86 lines. The Python predecessor `code/client/munkilib/installer/rmpkgs.py` is 838 lines. | `wc -l` |
| History of rmpkgs.swift | 20 commits, from "More WIP" (2024-07-31) and "Initial implementation of removepackages tool" (`068d6e9`, 2024-08-01) to `28d92fe`. The latest functional changes were `cf708d8` (2026-01-09, faster receipt import) and `73bcfff`/`4909eb9`/`5eab584` (2026-02-11, filetype refactor and #1310). | `gh api "repos/munki/munki/commits?path=..."` |
| Open issues | 68 open (issues and PRs). Uninstall-related: #594 (2016, "removepkgs can be confused by update_for items that share receiptids"), #607 (uninstall also targets shared update_for items), #1149 (supported_architecture ignored for uninstalls), #985 (force removal with other users logged in), #389 (no uninstall_method loops), #953 (uninstallcheck_script). #1211 is the stale GarageBand loops wiki. The rest are MDM features (Managed Software Center, repoclean, auth). | `gh api "repos/munki/munki/issues?state=open&per_page=50"` |

**What the license lets us do:** Apache-2.0 allows copying and modifying the code, including in a closed or commercial app. The conditions: ship a copy of the license, keep the copyright and attribution notices in copied files ("Copyright 2024-2026 The Munki Project"), mark modified files as changed, and carry over any NOTICE file (there is none). There is no Commons Clause and no copyleft. **Lineage:** the Swift file is Greg Neagle's port of his own Python `rmpkgs.py`. The schema comment at `rmpkgs.swift:24-54` says it is "a subset of Apple's schema in Leopard". Nothing is vendored from a third party (unverified beyond the file headers and the commit list).

## Summary

`removepackages` removes what an Apple flat or bundle package installed, using the package's own receipt. It does not guess by name. The engine is one file, `code/cli/munki/shared/installer/rmpkgs.swift`, and it is used in two places:
- the `removepackages` CLI (`code/cli/munki/removepackages/removepackages.swift:23-86`), which must run as root unless `--listfiles` is given (`:66-69`);
- `managedsoftwareupdate`, whose `uninstall_method: removepackages` calls `removePackages(packages)` (`shared/installer/installer.swift:487-503`).

The algorithm is the right idea for macontrol's "remove a pkg-installed app" path:
1. **Build a receipt DB** (SQLite, `b.receiptdb` under Managed Installs, `:57-59`) with one row per installed package and one row per path. The package list comes from `pkgutil --regexp --pkg-info-plist '.*'` (`:284-309`). Each package's file list comes from `lsbom -s /private/var/db/receipts/<id>.bom` (`:236-254`), or from `pkgutil --files <id>` (10 s timeout) for `com.apple.*` ids and for receipts without a BOM there (`:257-273`). The DB is rebuilt only when `/Library/Receipts/InstallHistory.plist` is newer than it (`:62-84`).
2. **Remove only unshared paths.** Paths of the selected packages minus paths of every other package, as one SQL set difference (`getPathsToRemove`, `:373-389`).
3. **Delete bottom-up.** Paths are sorted and reversed, so children come before parents. Files and symlinks are unlinked. Directories go only when empty, or when they hold just `.DS_Store`. Non-empty bundles go only with `-f` (`removeFilesystemItems`, `:514-594`).
4. **Forget the receipts** in munki's DB and in Apple's (`pkgutil --forget`, `:411-463`).

munki also reference-counts at the package level before it gets here. `analyze.swift:1021-1062` drops any receipt id that another catalog item also lists, and it refuses the uninstall if none is left.

The Swift port has three regressions from the Python version, and all three are verified with munki's own code:
- **F-0069:** the bundle test never matches. `pathIsBundle` compares `NSString.pathExtension` ("app") with a list of dotted extensions (".app", `:466-497`). So `-f/--forcedeletebundles` is a no-op, and managedsoftwareupdate no longer asks for it anyway: Python passed `forcedeletebundles=True` (`code/client/munkilib/installer/core.py:535-536`), Swift passes nothing (`installer.swift:489`). An app that gained files after install, for example through its own updater, ends up as a gutted `.app`: its Info.plist and main binary are deleted and the rest stays. The run still returns 0 and the receipt is forgotten, so the leftovers can no longer be found by receipt.
- **F-0071:** package ids are pasted into SQL as double-quoted strings (`quoteAndJoin`, `:354-357`). SQLite reads `"pkgid"` and `"pkgname"` as column names, so either id selects every receipt. A dry run then lists every pkg-installed file on the machine, shared files included. Python used bound parameters and rejected any unknown id (`rmpkgs.py:471-510`).
- The dry run (`-l`) prints the DB set difference, not what the remover will do (`:644-649`). It listed 7 items in the probe, and 4 of them were then kept. This is folded into F-0069.

## Architecture

- **Suite layout.** `code/cli/munki/<tool>/` holds one ArgumentParser `@main` per CLI tool (managedsoftwareupdate, removepackages, makepkginfo and others). `code/cli/munki/shared/` is the common library: `installer/` (`installer.swift`, `pkg.swift`, `dmg.swift`, `rmpkgs.swift`), `updatecheck/`, `utils/`, plus `sqlite3.swift`, `display.swift` and `munkistatus.swift`. The GUI apps are in `code/apps/` (Managed Software Center, MunkiStatus, munki-notifier). The legacy Python client is in `code/client/munkilib`, and its tests in `code/client/tests`.
- **Engine/UI split.** `rmpkgs.swift` has no UI. Progress and status go through free functions: `display.majorStatus/minorStatus/detail/error` (`DisplayAndLog`, `display.swift:75-190`), `displayPercentDone` (`display.swift:45`), and `munkiStatusPercent`, `munkiStatusDisableStopButton`, `munkiStatusEnableStopButton` (`munkistatus.swift:82-111`). These post to MunkiStatus/MSC. The stop button is disabled for the whole delete phase (`rmpkgs.swift:651-653, 664-666`).
- **SQLite.** A thin wrapper over the C API, `SQL3Connection`/`SQL3Statement` (`shared/sqlite3.swift`, 179 lines), opened `READWRITE|CREATE|NOMUTEX` (`:154`). Writes use WAL and `synchronous=normal` (`rmpkgs.swift:128-129, 346-347`).
- **External tools.** `pkgutil` and `lsbom` run through `runCLI`/`runCliAsync` (`utils/cliutils.swift:222, 543-583`). Each call captures the whole stdout as a String.

## Scanning

"Scanning" here means importing the receipt database. There is no filesystem walk.

- **Enumeration.** One `pkgutil --regexp --pkg-info-plist '.*'` call returns every receipt as concatenated XML plists, split by `parseFirstPlist` (`:287-309`). Each package then gets its own `lsbom` or `pkgutil --files` process, one after the other, and its own SQLite connection and transaction (`:125-148`, `:314-323`). A path row is looked up by `SELECT` and then inserted (`:176-190`).
- **Cost on this Mac (verified).** `run.sh rebuild` imported 32 receipts, 276,122 unique paths and 276,522 pkg-path rows in **4.41 s and 4.42 s** wall time over 2 runs. The largest single item is `com.apple.pkg.Xcode` (57% of the path rows): `pkgutil --files` took 1.59 s for 156,993 lines, against 0.12 s for `lsbom -s` on the same `.bom`. The `com.apple.` prefix check (`:258`) forces the slow path even though `/var/db/receipts/com.apple.pkg.Xcode.bom` exists. Apple's other receipts live in `/Library/Apple/System/Library/Receipts/` (25 receipts here: 25 `.bom` + 25 `.plist`), which `getBomFilesForPkg` never looks in (`:237`). I did not file this: 4.4 s, and only after an install, is acceptable. It is in the reuse table as "improve".
- **Staleness.** Only `InstallHistory.plist`'s mtime is checked (`:62-84`). Python also checked the mtimes of `/Library/Receipts`, `/Library/Receipts/boms` and `/private/var/db/receipts` (`rmpkgs.py:62-103`). A `pkgutil --forget` by another tool therefore leaves a stale DB. That errs on the safe side (the forgotten package's paths still count as "shared"), so it is not filed.
- **Cancellation.** `stopRequested()` is checked between packages during import (`:315-317`) and once before the delete (`:628-630`). The delete phase itself cannot be cancelled.
- **Sizes, hard links, clones:** not applicable. Receipts are not sized. BOMs do carry size and CRC32 (see below), and munki discards them.

## Deletion & rules

- **Rule source.** The rules are data from Apple, not a curated list: whatever the package's BOM says it installed. munki's own data is only the pkginfo `receipts`/`packages` list per catalog item, with reference counting across items (`analyze.swift:1021-1062`, which prints "could not find unique packages to remove"). Two items that share receipt ids are the open issues #594 and #607.
- **Shared-path protection.** `getPathsToRemove` (`:373-389`) is `paths(selected) − paths(every other receipt)`. The probe confirmed it: `Library/Shared/common.dylib`, listed by both fixture packages, was kept, and so were the shared `Applications` and `Library` directories. This is the single most valuable idea in the source.
- **Delete mechanics.** `FileManager.removeItem` runs as root. It is permanent, with no Trash and no journal (the class of F-0012). The file type comes from `attributesOfItem`, which does not follow a symlink at the last path component (`utils/fileutils.swift:28-34`). Symlinks are unlinked, not followed. A directory is removed when empty or holding only `.DS_Store`, but by `removeItem`, which is recursive (`:562-566`). Python emptied `.DS_Store` and then used `os.rmdir`, which fails safely if something appeared in between (`rmpkgs.py:719-736`). Files of an unknown type (FIFO, socket) are reported and skipped (`:545-551`).
- **Bundle handling (broken, F-0069).** The intent (`:568-586`) is: if a directory is still non-empty and it is a bundle, remove the whole bundle under `-f`, and do not warn about non-empty directories inside it. `pathIsBundle` (`:466-497`) cannot match, because `(path as NSString).pathExtension` returns `app` while the list holds `.app`. I checked with a 2-line Swift probe: `("/Applications/Foo.app" as NSString).pathExtension` gives `app`, and `[".app"].contains(...)` gives `false`. Python's `os.path.splitext` keeps the dot (`rmpkgs.py:673-676`).
- **No identity check.** `lsbom -s` prints paths only (`:241-243`). The BOM also records mode, size and CRC32, as `lsbom -p fmsc` shows. For example, `./Applications/Karabiner-Elements.app/Contents/Info.plist	100644	1649	3735891025`, verified on this Mac. munki deletes whatever file sits at a receipt path now, even when it has been replaced since install. How often that happens in practice is not established. On this Mac, all 1,202 regular files of the 6 third-party receipts still had their BOM size, and 7 were missing (`scratchpad/dive-munki-munki/drift.py`).
- **Background items.** Nothing unloads a LaunchDaemon or LaunchAgent before its plist is deleted. munki leaves that to the pkginfo's `preuninstall_script` (`installer.swift:471-478`). This is the class of F-0023.
- **Dry run.** `-l/--listfiles` prints the DB result (`:644-649`) and needs no root. It does not model what the remover will do: non-empty directories kept, missing items skipped, and (if `-f` worked) whole bundles.
- **Errors.** `removeFilesystemItems` returns `Void` (`:514`), so errors only reach the log (`:588-593`). `removePackages` returns 0 and forgets the receipts either way (`:654-669`).
- **Privilege.** It runs as root: the CLI refuses otherwise, and managedsoftwareupdate is a root LaunchDaemon. There is no helper split and no per-path authorization.

## UI

There is none in rmpkgs. Progress is `displayPercentDone` plus MunkiStatus notifications, and the stop button is disabled during deletion. The CLI prints plain lines. Nothing here is useful to macontrol's UI beyond one pattern: show the receipt's file list as the preview, but compute it from the same plan the executor runs (see F-0069 "after").

## Tests & quality

- **No tests for removal, in either language.** `grep -rln "rmpkgs|removepackages|removePackages|pathIsBundle|getPathsToRemove|receiptdb"` over `code/cli/munki/munkiCLItesting` (22 files, 193 `func test`/`@Test`) and `code/client/tests` returns nothing. A single test with a real `.app` directory would have caught the `pathExtension` bug.
- The code is plain, readable Swift written by the original author, with doc comments on every function. There are loose ends: `// maybe print an error or warning?` where `DELETE` results are ignored (`:397-407, 458-461`), statements that are never finalized (`getPkgKeysFromPkgDB`, `getPathsToRemove`, `:361-389`), and a schema comment saying most columns are unused (`:28-37`).
- The port kept the Python structure one to one, which makes the regressions easy to see side by side: bound parameters became string SQL, the staleness check lost 3 of its 4 sources, `forcedeletebundles=True` was dropped, and `os.rmdir` became a recursive `removeItem`.

## Known problems

1. **Gutted bundle, receipt forgotten, success reported (F-0069, verified).** Fixture: package `com.fixture.foo` installs `Foo.app/Contents/{Info.plist,MacOS/Foo}`, `Library/Foo/foo.conf`, and a dylib shared with `com.fixture.bar`. After "install", the app's updater adds `MacOS/FooUpdateHelper` and the user adds `PlugIns/UserAdded.plugin`. The preview listed 7 items. Both the default run (managedsoftwareupdate's call) and the `-f` run deleted `Info.plist` and the main binary, logged 4 "Did not remove ... because it is not empty" errors, left `Foo.app` in place, returned `rc=0`, and removed the receipt. A retry returned `-4` ("No matching pkgs found in database").
2. **String-built SQL (F-0071, verified).** `getPkgKeysFromPkgDB(["pkgid"])` and `(["pkgname"])` both returned both fixture packages. `(["vers"])` returned none. `(["no.such.pkg","com.fixture.foo"])` silently returned only foo. `(["a\"b"])` threw `near "b": syntax error`. The dry run of `["pkgname"]` listed `Library/Bar/bar.conf` and the shared `common.dylib`, so a real run as root would delete every file of every receipt, Xcode and the CLTools included. The trigger needs an id that equals a column name, which makes it unlikely, but the result would be catastrophic.
3. **Recursive removeItem after the emptiness check** (`:555-566`). The window is small (list, then delete), and a file created in between is deleted with the folder. Not filed: I did not measure it, and it is a narrow race.
4. **Intermediate symlinks are followed.** `"/" + item` is passed to `removeItem`, and only the last component is checked with lstat. If `/Library/Foo` were replaced by a symlink, `Library/Foo/x` would be deleted through it. Writing `/Library` needs root, but `/Applications` is admin-group writable, so this is a local-admin-only concern. Unverified and not filed.
5. **GarageBand / Logic content.** The munki wiki says the old `MAContent10_GarageBandCoreContent2.pkg` and `_v3.pkg` share **one package identifier** (`GarageBand.md:46`, fetched from `raw.githubusercontent.com/wiki/munki/munki/GarageBand.md`). One receipt per id means one BOM, so files only the older pack installed are probably in no receipt (inference, unverified: no content packs are installed here). The same page says that since January 2026 Logic Pro and MainStage content ships as `.aar` Apple Archives, not packages (`GarageBand.md:4-5`), and those leave no pkg receipt to remove by (unverified). **So receipts cover pkg-installed content packs, not the new `.aar` content.** macontrol needs a second, path-based rule for loops (owner: T-0010).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Shared-path set difference ("remove only paths no other receipt lists") | **take** (idea; reimplement as in-memory `Set<String>`) | `rmpkgs.swift:373-389`, `analyze.swift:1021-1062` | The core safety property, proven across a large fleet. There is no need for SQLite: one `Set` of other receipts' paths is enough for a single removal. Apache-2.0 permits copying, but the code is SQL and does not fit. |
| Receipt enumeration + BOM listing | **improve** | `rmpkgs.swift:236-309` | Keep `pkgutil --pkg-info-plist` for metadata. Use `lsbom -p fmsc` for every receipt that has a BOM (13x faster than `pkgutil --files` on Xcode, measured), and look in `/Library/Apple/System/Library/Receipts/` too. Keep mode/size/CRC for an identity check, and run the lsboms concurrently with a bound. |
| `install-location` normalisation | **take** | `rmpkgs.swift:221-229` | Handles the `""`, `"/"` and relative `"Applications"` forms, all 3 seen on this Mac (Karabiner, macFUSE, Cloudflare WARP receipts). |
| Bottom-up delete order, empty-dir rule, `.DS_Store` tolerance, lstat type check | **take** (with `rmdir` semantics) | `rmpkgs.swift:532-566` | A correct, simple ordering. Use non-recursive `rmdir` after removing `.DS_Store` (as Python did), not `removeItem`. |
| Bundle-as-unit removal | **rewrite** | `rmpkgs.swift:466-511, 568-586` | Broken in Swift (F-0069). Compare undotted extensions, or use `URLResourceValues.isPackage`, which is true for `.app`/`.plugin` and false for `.framework` (verified), so it needs the list too. Remove the whole bundle to the Trash after an identity check. |
| Package-id lookup | **rewrite** | `rmpkgs.swift:354-370` | F-0071. Use exact-match lookup and require every id to resolve. |
| Receipt forgetting (`pkgutil --forget`) | **take, reorder** | `rmpkgs.swift:411-420` | Correct call. Run it only after every planned path is gone, and show the result per item. |
| Dry run `--listfiles` | **rewrite** | `rmpkgs.swift:644-649` | The preview must be the executor's plan, whole-bundle contents included. |
| Staleness check | **study** | `rmpkgs.swift:62-84`, `rmpkgs.py:62-103` | macontrol does not need a persistent DB. Read receipts per operation, or cache keyed on the receipts dirs' mtimes, as the Python version did. |
| SQLite wrapper, MunkiStatus plumbing, ArgumentParser CLI | **ignore** | `shared/sqlite3.swift`, `munkistatus.swift`, `removepackages.swift` | Not needed. |
| GarageBand/Logic content knowledge | **study** | wiki `GarageBand.md`, issue #1211, carlashley/loopdown | The content-pack ids and the 2026 `.aar` change matter for T-0010. |

## Open questions

- Do Mac App Store apps (GarageBand, iMovie, Pages) leave pkgutil receipts on current macOS? This Mac has none of them, and `pkgutil --pkgs` lists only 32 receipts, none of them MAS. Unverified. It decides whether "remove GarageBand by receipt" is possible at all, or only removal of its pkg content packs.
- Does a MAContent10 content pack still register its BOM under `/Library/Apple/System/Library/Receipts/` or under `/var/db/receipts/`? It needs a Mac with loops installed.
- How often do pkg-installed apps drift from their BOM after self-updates (Office via MAU, Zoom, Adobe)? On this Mac, 0 size changes in 1,202 files, but none of those apps self-update.
- Brew's `uninstall_pkgutil` (T-0036) removes a cask's pkg receipts. Does it apply a shared-path check like munki's? That is the Homebrew dive's call. I asked on T-0036.
