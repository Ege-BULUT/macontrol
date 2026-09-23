# Source deep dive: homebrew-cask zap stanzas (formulae.brew.sh cask.json)

Task T-0035, author `dive-homebrew-homebrew-cask`, 2026-09-23. Category: uninstaller (dataset + reference engine).

What was read:
- **Dataset:** `research/sources/homebrew-homebrew-cask/cask.json`, from `curl https://formulae.brew.sh/api/cask.json` (18,924,923 bytes, `last-modified: Wed, 23 Sep 2026 07:42:02 GMT`, `etag: "6ab382ca-120c57b"`, headers in `headers.txt`). The task's `git clone` of a JSON URL cannot work, so it was downloaded.
- **Cask sources:** `research/sources/homebrew-homebrew-cask/repo`, a sparse `git clone --depth 1` of Homebrew/homebrew-cask at `0e47c3a` (2026-09-23 07:34 UTC), all 7,755 `Casks/**/*.rb`.
- **Engine that applies the data:** Homebrew/brew as installed on this Mac, `/opt/homebrew` at `570982948a` (Homebrew 7.0.6, 2026-09-21). Paths like `Library/Homebrew/...` are relative to that checkout. No second clone was made.

Scripts that produced every number here (macontrol-owned, read-only):
- `research/bench/homebrew-homebrew-cask/analyze_zap.py` writes `zap_stats.json`.
- `research/bench/homebrew-homebrew-cask/matcher_coverage.py` writes `matcher_coverage.txt`.
- `research/bench/homebrew-homebrew-cask/wildcard_probe.rb` runs brew's own resolver on fake input.

Labels: "verified" means I ran it here; "code-read" means read, not run; "unverified" means I could not check it.

## Facts

| Field | Value | Source |
|---|---|---|
| URL (data) | https://formulae.brew.sh/api/cask.json (unsigned). Signed twin: https://formulae.brew.sh/api/cask.jws.json (20,606,855 bytes). Per cask: `/api/cask/<token>.json` | curl -I, `Library/Homebrew/api/cask.rb:17` |
| URL (source) | https://github.com/Homebrew/homebrew-cask (casks), https://github.com/Homebrew/brew (engine), https://github.com/Homebrew/formulae.brew.sh (site that publishes the feed) | `gh api repos/...` |
| License | **BSD-2-Clause** for all three. Cask LICENSE: "Copyright © 2013, Paul Hinze & Contributors" | `gh api repos/Homebrew/homebrew-cask/license`, API `.license.spdx_id` |
| What it permits us | Copy, modify and ship the data and the code, commercially too, **if the copyright notice, conditions and disclaimer are reproduced in the docs or other materials** of a binary distribution. So: an Acknowledgements entry plus a NOTICE line in the app. No copyleft. | LICENSE clauses 1-2 |
| Stars / forks | homebrew-cask 22,226 / 11,937; brew 49,753; formulae.brew.sh 2,079 | API, 2026-09-23 |
| Age / activity | cask repo created 2012-03-05, last push 2026-09-23T07:43Z, about 477,719 commits and about 13,149 contributors incl. anonymous (API Link headers). The feed regenerates within minutes of merges: feed 07:42 GMT, HEAD merge 07:34 UTC | API |
| Language | Ruby. The data is a Ruby DSL (`Casks/<letter>/<token>.rb`), evaluated by brew into JSON | repo tree |
| Size | 7,755 casks. **4,716 casks with a `zap`**, 21,517 zap path entries (`trash` + `delete` + `rmdir`, base artifacts); 21,661 unique per-cask paths once per-OS `variations` are included (114 casks have OS/arch-specific zaps). Base `uninstall`: `quit` in 1,161 casks, `pkgutil` 678, `launchctl` 437, `delete` 379, `login_item` 84, `signal` 69, `kext` 23 | `zap_stats.json`, inline count (base only) |
| Open issues | cask: 4 open issues plus 2 tracking issues, #172732 (homepage/source problems, 558 comments) and #170994 (livecheck); none about zap. brew: 2 open, unrelated (#24074, #24060). Maintainers close issues fast, so open issues show little; the closed history is what matters, for example cask #30256 "glob expansion in zap :delete" and #16339 "Proposal: new stanza `bundle_id`" (both closed) | `gh api repos/.../issues?state=open&per_page=50`, `gh search issues` |

## Summary

This is not an app. It is **the largest hand-curated uninstall knowledge base for macOS**, plus the Ruby engine that applies it.

For each cask, `uninstall` says how to stop and remove what the installer put on the system: launchd jobs, running apps, login items, kexts, pkg receipts and files. `zap` lists the per-user leftovers to delete: preferences, caches, containers, saved state, logs and dot-folders. `brew uninstall --zap <token>` runs both.

For macontrol it is three things:
1. A **leftover-path dataset** covering 4,716 apps, with a permissive license.
2. A **test oracle** for our matcher: for a known app, which paths should be found.
3. A **reference ordering and set of guards** for the teardown steps: launchctl before quit, quit before kext, script before files, rmdir-if-empty last.

Its weaknesses, which macontrol must handle when it takes the data:
- zap mixes the app's own files with user work and with resources shared by other products (**F-0066**).
- Version-specific folder names are frozen to one version (**F-0068**).
- Wildcard launchd entries are resolved only against running jobs in the user's domain (**F-0067**).
- Some labels and helper names are stale (already **F-0055**, DaisyDisk).

## Architecture

- **Data layer** (homebrew-cask): one Ruby file per cask. `zap` and `uninstall` take the directives `early_script, launchctl, quit, signal, login_item, kext, script, pkgutil, delete, trash, rmdir`, plus `on_upgrade` metadata (`Library/Homebrew/cask/artifact/abstract_uninstall.rb:23-39`). Values are strings or arrays, and they may interpolate `#{version...}`, `#{appdir}` or `on_arm/on_intel` blocks.
- **Feed generation** (brew): `Cask#to_hash_with_variations` (`Library/Homebrew/cask/cask.rb:612-660`) evaluates the DSL once per OS/arch tag and stores only the keys that differ under `variations`.
  - `APIHashable#generating_hash!` (`Library/Homebrew/api_hashable.rb:5-19`) swaps HOME for `/$HOME` and HOMEBREW_PREFIX for `$HOMEBREW_PREFIX`. `$APPDIR` and `$HOMEBREW_CELLAR` placeholders also exist (`api/cask_struct.rb:250-270`).
  - In the zap/uninstall paths of this feed: `$HOMEBREW_PREFIX` 19, `$APPDIR` 16, `/$HOME` 0. Almost all paths use a literal `~`.
- **Feed format:** a JSON array of cask objects. `artifacts` is a list of one-key dicts (`{"zap":[{"trash":[...],"rmdir":[...]}]}`), `variations` is `{tag: {artifacts: [...]}}`, and the tags include `x86_64_linux`, which must be filtered out. There is **no bundle-ID field**; bundle IDs appear only inside `quit`/`signal` values and inside paths. Per-user keys (`installed`, `outdated`, ...) are null.
- **Engine:**
  - `Cask::Artifact::Zap` is 16 lines and calls `dispatch_uninstall_directives` (`cask/artifact/zap.rb`).
  - All work is in `AbstractUninstall` (710 lines), `Cask::Pkg` (`cask/pkg.rb`, 140), `Cask::Utils` (`cask/utils.rb`, 171; `cask/utils/trash.rb` + `extend/os/mac/cask/utils/trash.rb`), and the protected-path sets (`cask/macos.rb`, 391).
  - Sorbet `typed: strict` throughout.
- **Tooling around the data:**
  - `brew generate-zap` (`dev-cmd/generate-zap.rb`, 368 lines, added 2026-02-26 `8265b796fc`) proposes a zap stanza by scanning the disk.
  - `brew cask-ci zap-check` (`cask/ci/zap_check.rb`, 215 lines, 2026-09-07 `79d787b1cd`) launches the app in CI, runs generate-zap and warns about paths the stanza misses. Wired in `.github/workflows/ci.yml` of the cask repo (step "zap-check", about line 199).
  - RuboCop cops: `rubocops/cask/uninstall_wildcard.rb` (a wildcard needs at least 3 ID parts), `disallowed_patterns.rb` (`com.install4j.*`), `shared_filelist_glob.rb` (`.sfl*`), `array_alphabetization.rb`, `uninstall_methods_order.rb`.
- **UI/engine separation:** CLI only. Output is `ohai`/`opoo` lines, and there is no GUI.

## Scanning

brew does not scan disks for sizes. It has no size accounting, no concurrency and no progress. The only "scanner" is `generate-zap` (a dev command, code-read):

- **Search keys:** app name (`.app` basename) and `CFBundleIdentifier` from the installed app's Info.plist (`generate-zap.rb:176-188`). Without an app artifact it falls back to the apps inside pkg receipts (`:154-170`), then to the capitalized token (`:141`).
- **Roots:**
  - user roots `USER_TRASH_PATHS` (`:37-63`): 25 folders including `~/Desktop`, `~/Documents` and `~/Music`;
  - system roots `SYSTEM_DELETE_PATHS` (`:65-80`): `/Library/*` subfolders, `/Users/Shared`, `/etc/newsyslog.d`;
  - dot-entries directly under `~` (`:219-234`).
- **Match rule:** depth-1 `Dir.each_child` with a **case-insensitive substring** of name or bundle ID (`:197-216`). This is the same class as F-0011, but here a human reviews the output before it is merged.
- **Normalisation, worth copying:**
  - `collapse_to_wildcards`: siblings sharing a prefix become `prefix*` (`:245-265`, `:329-355`).
  - `replace_uuids`: UUID → `*` (`:91`, `:268-270`).
  - `glob_shared_filelists`: `.sflN` → `.sfl*` (`:94`, `:273-275`).
  - `derive_rmdir_candidates`: parents under Application Support/Containers/Group Containers become `rmdir` entries (`:278-296`).
- **Permissions:** EPERM/EACCES on a root skip it silently (`:236-242`), or stop the run with a Full Disk Access hint (`:109-118`). The FDA test is `File.readable?("~/Library/Application Support/com.apple.TCC")` on the per-user TCC *directory* (`cask/utils.rb:28-31`). That is an access(2)-style permission check, which may not reflect a TCC denial; that is unverified, because this shell has FDA (see M-0001). F-0001's "after" opens the per-user `TCC.db` instead. In brew the result only picks which error message is shown.

**Glob semantics that a consumer must reproduce:**
- Paths are expanded with Ruby `Pathname.glob` after `~` → `Dir.home` (`abstract_uninstall.rb:143,156`).
- Verified with Ruby 4.0.6 on this Mac's APFS: matching is **case-insensitive** (`Dir.glob("/APPLICATIONS/Saf*")` → `/Applications/Safari.app`), and `*` does **not** match a leading dot.
- Brace sets work (`{Safari,Nope}.app`).
- In the data: 2,175 paths use `*`, 12 use `[...]` (for example `"/Users/Shared/Max [0-9]"`), 3 use `**`, 2 use `?`.

## Deletion & rules

**Order.** `ORDERED_DIRECTIVES` (`abstract_uninstall.rb:23-35`), with the reasons as code comments:
- launchctl before quit, "for cases where app would instantly re-launch" (`:214`);
- quit/signal before kext (`:82`);
- signal after quit, as a fallback (`:439`);
- script before pkgutil/delete/trash, so the script still exists (`:555`).

**Per directive** (code-read unless marked):

| Directive | What brew does | Cite | Notes for macontrol |
|---|---|---|---|
| `launchctl` | For literal labels, `launchctl_find_service` in the user domain and then with sudo; `launchctl remove`; `rm -f` of `~/Library/Launch{Agents,Daemons}/<label>.plist` or the `/Library` variant. A wildcard goes to `find_launchctl_with_wildcard` | `:216-277`, `:173-181` | Assumes plist name == label (see F-0055). The wildcard path is F-0067 (**verified**). Uses legacy `remove`/`unload`, not `bootout` |
| `quit` | JXA `Application(id).quit()` in a 10 s loop. Skips when there is no GUI session and when brew runs inside that app (`hosting_brew?`, ancestor PID walk) | `:91-128`, `:367-400` | Needs an Automation grant ("Terminal → System Events", `:290-297`). macontrol: `NSRunningApplication.terminate` |
| `signal` | `Process.kill` on PIDs from `launchctl list` whose label is the bundle ID, anchored regex, not root (TODO at `:463-469`) | `:443-478`, `:280-288` | |
| `login_item` | AppleScript "System Events" delete by path (derived from the cask's apps) and by name | `:488-515` | Does not cover SMAppService/BTM items |
| `kext` | `kextunload` then `kextfind` then `sudo rm -rf` | `:519-553` | |
| `pkgutil` | `pkgutil --pkgs=<regex>`, then for each receipt `sudo rm` every file and special file in the BOM, `rmdir.sh` directories deepest first, `pkgutil --forget` | `:592-600`, `cask/pkg.rb:13-60` | **Anchored:** verified that `pkgutil --pkgs=pple` returns 0 and `com.apple.*` returns 26. **No reference counting:** a file that another receipt also lists is removed (`pkg.rb:91-99`). On this Mac, 276,122 receipt paths had 0 regular files shared with a non-Apple receipt (verified), so there was no live case. munki's `rmpkgs.swift:373-390` is the model (T-0005) |
| `delete` | `sudo` `xargs -0 rm -r -f --` on the resolved globs, even for `~` paths | `:603-616` | NUL-separated argv, no shell: injection-safe |
| `trash` | `NSFileManager trashItemAtURL` via FFI; on failure, `gain_permissions` then retry | `:619-643`, `extend/os/mac/cask/utils/trash.rb:16-38` | **Fallback clears flags and ACLs recursively:** `chflags -R 000`, `chmod -R u+rwx`, `chmod -R -N`, then `sudo chown -R $USER` (`cask/utils.rb:95-133`). The user's Locked (uchg) flag and ACLs are lost with no prompt: same class as **F-0024** |
| `rmdir` | Recursive remove-if-empty. A folder counts as empty when it holds only `.DS_Store` or empty subfolders; symlinks are never followed | `:651-700`, `cask/utils/rmdir.sh` | **Take this.** It is the right tool for vendor folders (Firefox: `rmdir "~/Library/Application Support/Mozilla"`) |

**Guards** (`each_resolved_path`, `:139-170`):
- relative paths are skipped;
- paths with `.` or `..` segments are skipped;
- targets in `UNDELETABLE_PATHS` are skipped. That set is about 130 `~` folders plus about 230 `SYSTEM_DIRS` (`cask/macos.rb:6-237`, `:241-379`), compared as **exact** `expand_path` values. It does not resolve symlinks or firmlinks (class of F-0039), and it has **no containment**; the TODO at `:239-240` says so.
- EPERM leads to a Full Disk Access hint (`:163-168`).
- There is **no dry run**. `brew uninstall --zap` acts at once.

**Integrity of the rules:**
- The unsigned `cask.json` is protected only by HTTPS.
- brew itself fetches `cask.jws.json` and verifies an RSA-PSS SHA-512 JWS (`kid` `homebrew-1`, `alg` PS512, `b64:false`) against the pinned `Library/Homebrew/api/homebrew-1.pem` (`Library/Homebrew/api.rb:338-379`).
- If macontrol ever refreshes rules at runtime, it should fetch the JWS variant and verify it the same way (`SecKeyVerifySignature` with `.rsaSignatureMessagePSSSHA512`, unverified in Swift). This is the positive counterpart of F-0021.

**Dataset profile** (`zap_stats.json`):

- **Zap roots:**

  | Root | Paths |
  |---|---|
  | `~/Library/Preferences` | 4,537 |
  | `~/Library/Application Support` | 4,361 |
  | `~/Library/Caches` | 3,114 |
  | `~/Library/Saved Application State` | 2,351 |
  | `~/Library/HTTPStorages` | 1,392 |
  | `~/` dot-folders and others | 1,073 |
  | `~/Library/Application Scripts` | 995 |
  | `~/Library/Logs` | 969 |
  | `~/Library/Containers` | 920 |
  | `~/Library/WebKit` | 508 |
  | `~/Library/Group Containers` | 310 |
  | `/Library/Application Support` | 123 |
  | `~/Library/LaunchAgents` | 114 |
  | `/Library/LaunchDaemons` | 57 |
  | `/Library/PrivilegedHelperTools` | 19 |

- **Zap directives,** including variations: trash 25,362, rmdir 427, delete 192, pkgutil 47, launchctl 37, script 34.
- **Ownership problems (F-0066):**
  - 272 trash/delete paths in 217 casks point into user-content roots: `/Users/Shared` 73, `~/Documents` 69, `~/Music` 19, `~/Pictures` 7, `~/Desktop` 6, `~/Movies` 5, iCloud `~/Library/Mobile Documents` 5, non-dot home folders 88.
  - 290 literal paths are trashed by 2 or more distinct products.
  - 6 paths are trashed by one cask and only `rmdir`'d by another (for example `~/Library/Application Support/Microsoft`: `microsoft-word.rb:62` vs `microsoft-edge.rb:45-46`).
  - 78 `pkgutil`/`launchctl` IDs in the default `uninstall` are listed by 2 or more products (for example `com.microsoft.pkg.licensing` in 6 Office casks).
- **Version pinning (F-0068):** 179 casks / 630 zap path lines interpolate `#{version...}`: `.major` 478, `.major_minor` 89, `.csv.first.major` 20, plain `#{version}` 10. In the feed, 111 paths in 40 casks carry the current major.minor literally.
- **Wildcard launchd labels (F-0067):** 26 patterns in 22 casks. 15 of them, in 12 casks, name real agents or daemons.

**Matcher oracle** (`matcher_coverage.txt`): 2,791 casks have a zap and a derivable bundle ID (from `quit` or the `Saved Application State/<id>.savedState` path). For their 14,858 trash/delete paths, the strongest key found in the path:

| Key | Share of paths |
|---|---|
| bundle ID | 64.8% |
| app name | 22.7% |
| vendor prefix (first two reverse-DNS parts) | 6.0% |
| none | 6.5% |

Per root, the bundle ID alone finds:
- `Saved Application State` 99%, `HTTPStorages` 93%, `WebKit` 92%, `Preferences` 81%, `Containers` 75%, `Caches` 72%;
- but only `Application Support` 32% (app name 54%) and `Logs` 9% (app name 78%).

The "none" 6.5% are Team-ID group containers (`2BUA8C4S2C.com.agilebits`), vendor folders (`SweetScape`, `ABBYY`, `4kdownload.com`) and user-content folders. A bundle-ID-only matcher (MangoDisk-style) therefore finds about two thirds of what curators list, bundle ID + name about 88%, and the rest needs Team ID or curated data.

## UI

None. brew is a CLI: `ohai "Trashing files:"` lists the zap entries before acting (`:624`), with no confirmation and no selection. For macontrol, the takeaway is what the data needs from a UI:
- a per-path reason ("listed by Homebrew cask *pycharm*");
- an ownership class (F-0066);
- a place for patterns that matched nothing (F-0067).

## Tests & quality

- **Engine specs** (code-read, not run):
  - `test/cask/artifact/shared_examples/uninstall_zap.rb` (364 lines), shared by `zap_spec.rb` (58) and `uninstall_spec.rb` (378);
  - `test/cask/pkg_spec.rb` (198), `test/cask/utils/trash_spec.rb` (68), `test/dev-cmd/generate-zap_spec.rb` (421), `test/cask/ci/zap_check_spec.rb`, plus RuboCop cop specs.
  - Everything is mocked through `fake_system_command`. **Gap:** the launchctl wildcard tests (`uninstall_zap.rb:91-150`) stub `find_launchctl_with_wildcard` in the phase test, and the resolver test has no stopped matching job. That is exactly where F-0067 lives.
- **Data QA:**
  - `brew audit --cask` has only one zap rule, "only a single zap stanza is allowed" (`cask/audit.rb:318-323`).
  - RuboCop checks ID wildcards (3 parts minimum), `install4j`, `.sfl*`, ordering and alphabetization.
  - **No automated check on path breadth or ownership.** Nothing flags `~/Documents/...`, `~/Music/...`, a vendor root, or a path another cask also trashes.
  - CI installs each changed cask, runs `uninstall --zap --force`, and since 2026-09-07 also `zap-check`, which warns but does not fail (`zap_check.rb:194-199`). Existing stanzas were curated by hand before that and are not re-checked.
- Sorbet `typed: strict` everywhere. `AGENTS.md`/`CLAUDE.md` in the cask repo tell contributors to verify zap paths by hand (`AGENTS.md:83,128,182`).
- Side effect seen during this dive: `brew ruby` silently switches Homebrew **developer mode on**. I switched it back with `brew developer off` (verified).

## Known problems

| # | Problem | Evidence | Board |
|---|---|---|---|
| 1 | zap trashes user work and resources shared by other products, with no ownership check | 272 user-content paths, 290 multi-product paths, 78 shared uninstall IDs; `microsoft-word.rb:62`, `eclipse-java.rb:24`, `ableton-live-suite.rb:33-35`, `omnigraffle.rb:48`, `fxfactory.rb:39` | **F-0066** (high) |
| 2 | Wildcard launchctl misses stopped and system jobs and is unanchored | `abstract_uninstall.rb:173-181`, probe output, 15 real-job patterns | **F-0067** (medium, verified) |
| 3 | Version-interpolated zap paths freeze to one version | `pycharm.rb:36-45`, 179 casks / 630 lines | **F-0068** (medium) |
| 4 | Stale helper labels / plist names assumed == label | `daisydisk.rb:20-21`; 85 casks hard-code PrivilegedHelperTools paths | F-0055 (by dive-daisydisk) |
| 5 | Trash fallback clears uchg/ACLs recursively, then `sudo chown -R` | `cask/utils.rb:95-133` | class of F-0024 (evidence on T-0035) |
| 6 | Exact-match protected set, no containment, no firmlink resolution | `cask/macos.rb:239-388` | class of F-0024/F-0039 (evidence on T-0035) |
| 7 | pkg receipt removal has no cross-receipt reference count and no check against other installed casks | `cask/pkg.rb:29-60,91-99`; `cask/installer.rb:311` (only `migrator.rb:116` restricts) | inside F-0066 "after" (munki model); no live case on this Mac |
| 8 | Launchd teardown uses legacy `launchctl remove`/`unload -w`, not `bootout` | `abstract_uninstall.rb:237-243,260-266` | ordering is covered by F-0023's "after"; no new finding |
| 9 | `generate-zap` substring-matches `~/Documents`, `~/Desktop`, `~/Music` | `generate-zap.rb:37-63,197-216` | class of F-0011 (dev tool, human-reviewed) |

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| zap/uninstall data (paths, labels, receipts, bundle IDs from quit/signal) | **take** | `cask.json` (feed) or `Casks/**/*.rb` | BSD-2, the largest curated set (4,716 apps). A zap/uninstall/app subset of 4,884 casks is 2.15 MB JSON / 313 KB gzip (measured), small enough to ship. Needs the NOTICE text, variation filtering (macOS tags only) and placeholder substitution (`$HOMEBREW_PREFIX`, `$APPDIR`, `/$HOME`) |
| Ownership classes on top of the data | **improve** | new `tools/build-cask-rules` | The data is unsafe to preselect as-is (F-0066). Add own/shared/user-content classes and version templates (F-0068) at build time |
| Teardown order `ORDERED_DIRECTIVES` + the reasons in comments | **take** (design) | `abstract_uninstall.rb:23-35,82,214,439,555` | Proven over years; reimplement in Swift |
| `rmdir` remove-if-empty (ignores `.DS_Store`, never follows symlinks) | **take** (design) | `abstract_uninstall.rb:651-700`, `cask/utils/rmdir.sh` | The right way to handle vendor folders |
| Path guards (relative, `.`/`..`) | **take** | `abstract_uninstall.rb:143-153` | Cheap and correct |
| `UNDELETABLE_PATHS` / `SYSTEM_DIRS` lists | **improve** | `cask/macos.rb:6-379` | Good seed list (BSD-2), but use it with containment and (dev, inode) identity (F-0024, F-0039) |
| Launchd handling | **rewrite** | `abstract_uninstall.rb:173-277` | Wildcard gap (F-0067), label == file name assumption (F-0055), no `bootout` (F-0023) |
| pkg receipt uninstall | **rewrite** | `cask/pkg.rb` | Add reference counting across receipts and installed-cask claims (munki `rmpkgs.swift`), plus a preview |
| Trash via `trashItemAtURL` | **take** (API) | `extend/os/mac/cask/utils/trash.rb:16-38` | Same API macontrol will use |
| Permission-gaining fallback | **ignore** | `cask/utils.rb:95-133` | Silently clears Locked/ACLs: ask instead (F-0024) |
| `generate-zap` scanner | **study** | `dev-cmd/generate-zap.rb` | Its roots and normalizers (UUID → `*`, `.sfl*`, prefix collapse, rmdir derivation) are good; substring over Documents/Desktop/Music is not (F-0011) |
| `cask-ci zap-check` (launch the app, then diff generated vs curated) | **study** | `cask/ci/zap_check.rb` | Blueprint for macontrol's matcher regression test: exercise a fixture app, run our matcher, diff against the cask oracle |
| JWS verification of the feed | **take** (design) | `Library/Homebrew/api.rb:338-379`, `api/homebrew-1.pem` | Only needed if rules update at runtime; pin Homebrew's key or re-sign our derived rules |
| RuboCop wildcard/pattern cops | **take** (rules) | `rubocops/cask/uninstall_wildcard.rb:13`, `disallowed_patterns.rb:9-15` | Lint for our own rule file: at least 3 ID parts, no bare `com.install4j.*` |
| JXA quit/running checks | **ignore** | `abstract_uninstall.rb:299-436` | Needs an Automation grant; NSRunningApplication does this natively |

## Open questions

1. **Refresh model.** Should macontrol ship a snapshot of the derived rules (reviewed, signed by us) or fetch `cask.jws.json` at runtime and verify Homebrew's key? A snapshot fits the F-0021 lesson better. Decision for T-0011 / T-0008.
2. **Installed-app detection for "shared".** Should another installed product be matched by bundle ID from `quit`, by `app` name, or by both? 2,791 of 4,716 zap casks have a derivable bundle ID. The remaining 1,925 need app-name matching, which is unverified for precision.
3. **iCloud `Mobile Documents` semantics.** Does trashing `~/Library/Mobile Documents/iCloud~<app>` delete the data on other devices immediately, or only after "Recently Deleted" expires? Unverified; needs a test Apple ID.
4. **Real-world impact of F-0068.** No JetBrains/Android Studio folders exist on this Mac, so the size of stale version folders is unmeasured. A user-run `du -sh ~/Library/Caches/JetBrains/*` would settle it.
5. **pkg cross-receipt sharing** on machines with Office/Adobe installed. This Mac had none (verified), so the munki-style refcount is a design choice, not a measured defect.
6. **Linux variations.** `x86_64_linux` zaps (for example `~/.local/share/...`) must be dropped. Are there macOS-relevant paths only inside a Linux variation? Unchecked.
