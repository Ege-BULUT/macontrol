# Source deep dive: KnockKnock (objective-see/KnockKnock)

Task T-0038, author `dive-objective-see-knockknock`, 2026-09-23. Paths are relative to the clone at
`research/sources/objective-see-knockknock` (commit `914f2c0`, `git clone --depth 1`) unless they start with `http`,
`DumpBTM:` (objective-see/DumpBTM@19ba380, fetched with `gh api .../contents`) or `research/`.
"Verified" means I ran it on this Mac (macOS 26.6 25G72, uid 501, not root, terminal with Full Disk Access).
"Code-read" means I only read the code. Probes: `research/bench/objective-see-knockknock/run.sh {btm|launchd|sp}`
(counts only, read-only). They link the clone's own `Libraries/BTM/libDumpBTM.a`, and no GPL code is copied into `research/bench`.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/objective-see/KnockKnock (homepage https://objective-see.org/products/knockknock.html) | `gh api repos/objective-see/KnockKnock` |
| License | GPL-3.0 (`LICENSE`, 674 lines). The API agrees. Vendored: `3rdParty/HyperlinkTextField.*` (MIT, Toomas Vahter), `3rdParty/RFOverlayScroll*` (Rheinfabrik, "All rights reserved", no license text) | `LICENSE:1-2`, `3rdParty/HyperlinkTextField.m:1-8`, `3rdParty/RFOverlayScrollView.m:1-8` |
| What it permits us | Copyleft. Any code copied into macontrol would make macontrol GPL-3.0. **Decision: study only, no code copied.** That covers the prebuilt `libDumpBTM.a` (DumpBTM is also GPL-3.0). Ideas and the facts about macOS formats (BTM key names, launchd trigger keys, override file layout) are not copyrightable, so we reimplement them clean-room. | `gh api repos/objective-see/DumpBTM` (GPL-3.0, 152 stars) |
| Stars / forks / watchers | 794 / 46 / 12 | API, 2026-09-23 |
| Created / last push | 2021-02-01 (GitHub repo; the product dates from 2014-15, see `Plugins/PluginBase.h:5`) / 2026-09-15 | API |
| Latest release | v4.1.0, 2026-09-15 (v4.0.0 2025-12-14) | `releases?per_page=5` |
| Recent activity | 15 commits between 2026-09-11 and 09-15, all by Patrick Wardle: "improved macOS 27 compatibility #52", "domain-aware override fix (launch items) and the BTM uuid guard", "ignore missing files" (e38cad0) | `commits?per_page=15` |
| Language | Objective-C (501 KB), C (14 KB), Shell (5 KB). 110 `.m`/`.h` files, 19,217 lines | API `/languages`, `wc -l` |
| Build | Xcode project, ARC on, `MACOSX_DEPLOYMENT_TARGET` 10.15 (one target at 10.11). No SPM or Pod dependencies. Prebuilt fat static lib `Libraries/BTM/libDumpBTM.a` (arm64 + x86_64, built against the 13.3 SDK per `strings`). `release.sh` signs and notarizes with notarytool | `KnockKnock.xcodeproj/project.pbxproj`, `lipo -info`, `release.sh:6,25,50-55` |
| Open issues | 30 open (27 issues, 3 PRs). Themes by comment count: **BTM/background items missed** (#27 "Background Managed Tasks incomplete", #32 login items not detected, #49 "ChatGPTHelper not seen", #50 "LaunchAgents stored inside application bundles ... are invisible"), FDA prompt on macOS 27 (#52), VirusTotal UX (#17, #46, #51), missing categories (#15 PrivilegedHelperTools, #24 macFUSE kext, #47 browser extensions, #11 GlobalLoginItems), scan history/diff (#7) | `gh api .../issues?state=open&per_page=50` |

## Summary

KnockKnock is Objective-See's free persistence enumerator. It answers "what on this Mac starts automatically?" and has no cleanup function: `AppDelegate.m:17` still says `//TODO: support delete items`. It runs 20 plugins, one per persistence mechanism (`consts.h:16`): Authorization plugins, Browser extensions (Safari/Chrome/Firefox/Opera), **Background Managed Tasks (BTM, macOS 13+)**, Cron jobs, Directory Services plugins, Dock tiles, emond Event rules, App extensions (pluginkit), **Kernel extensions**, **Launch items**, DYLD_INSERT_LIBRARIES inserts, dylib proxies, **Login items**, login/logout hooks, periodic scripts, QuickLook plugins, Spotlight importers, rc startup scripts, shell configs, **System extensions**. For each item it hashes the file, checks the code signature (Apple / App Store / Developer ID / notarized), classifies it as trusted or untrusted, and can query VirusTotal. Extras: a CLI mode (`-whosthere -pretty -apple -skipVT -key`, `main.m:146-163`), JSON export, and a diff against a previously saved JSON scan (`diff.m`).

For macontrol it is the most complete **map of where apps leave background items**. That answers the discovery-note question "what kinds of background item can an app leave behind". Its enumeration logic, though, is tuned for a security reviewer: it shows what will run, not what is left over. It deliberately drops items whose binary is gone (commit e38cad0) and skips disabled items. It also misses SMAppService agents inside app bundles. I verified that on this Mac with a loaded agent (F-0072). We should reuse the knowledge (locations, keys, launchd trigger semantics, BTM record fields) and rewrite everything else.

## Architecture

- **Plugin model.** `PluginBase` (`Plugins/PluginBase.h:13-53`) has `name/description/icon`, four result arrays (`allItems`, `untrustedItems`, `unknownItems`, `flaggedItems`) and a `callback` block. Subclasses implement `-scan`, and the base `-scan` throws (`PluginBase.m:139-145`). Plugins are created by class name from the `SUPPORTED_PLUGINS[]` string table with `NSClassFromString` (`AppDelegate.m:547-576`). Adding a mechanism therefore means adding a class, and nothing is data-driven.
- **Result model.** `ItemBase` → `File` (a path, resolved to a bundle's executable if it is a directory; hashes, signing info, Mach-O info, VT info; `Results/File.m:38-150`), `Extension` (browser extensions) and `Command` (cron lines, shell config lines). `ItemBase.initWithParams:` standardizes the path and **resolves symlinks** (`Results/ItemBase.m:50`).
- **Trust filter.** `Filter.m` loads four JSON allow-lists (`WhiteList/whitelisted{Files,Commands,Extensions,Kexts}.json`, path → MD5 list), with `~` expanded per user (`Filter.m:90-150`). `isTrustedFile:` returns trusted on an allow-list hash match, an Apple-signed binary or an Apple App Store app with a `com.apple.` identifier (`Filter.m:160-230`). Signing requirements are `anchor apple`, `anchor apple generic` and the App Store leaf CN (`Signing.m:227-262`). One heuristic worth keeping: **an Apple-signed binary launched by a non-/System plist is not trusted** (`Plugins/BTM.m:161-170`, `Plugins/LaunchItems.m:182-190`).
- **UI vs engine.** There is no real separation. Plugins call `processItem:`, which invokes a callback into `AppDelegate itemFound:` on the scanner thread, and the UI updates are dispatched to main (`AppDelegate.m:666-731`). Plugins import `AppDelegate.h` and read globals (`sharedItemEnumerator`, `queryVT`). The CLI (`main.m:164-400`) reuses the same plugins with a JSON printer.
- **Privilege.** On a GUI launch it offers to relaunch the whole app as root through AppleScript `do shell script ... with administrator privileges` (`utilities.m:2057-2140`, `AppDelegate.m:141-255`). Per-user APIs then temporarily `seteuid` to the console user (`Plugins/LoginItems.m:117-138`, `utilities.m:1918-2042`). See F-0073.

## Scanning

This source is not a disk walker, so there is no size computation, no hard-link or clone handling and no memory model for huge trees. What it does:

- **Concurrency.** One `NSThread` runs the plugins **serially** (`AppDelegate.m:618-773`). A shared `ItemEnumerator` pre-computes two inputs on two more threads: the launchd plist list and the installed-app list (`ItemEnumerator.m:25-43`). Consumers busy-wait for them: `LaunchItems.m:72-82` waits forever, `DockTiles.m:66-83` gives up after 5 minutes. VirusTotal lookups run per plugin on the global queue and are joined with a dispatch group (`AppDelegate.m:710-751`).
- **Cancellation.** `NSThread cancel` plus `[NSThread exit]` inside `processItem:` (`PluginBase.m:94-98`). That kills the thread mid-plugin with no unwinding of `@synchronized`, `seteuid` or `@autoreleasepool` state. It works in practice because `processItem:` is only called after a plugin restores its privileges (code-read).
- **App inventory.** `system_profiler SPApplicationsDataType -xml -detailLevel mini` (`ItemEnumerator.m:116`). Verified: 2.80 s wall time, 374 apps on this Mac (`run.sh sp`). If it fails, `applications` stays nil, and DockTiles stalls for 5 minutes (code-read).
- **Launch items** (`Plugins/LaunchItems.m`). Plists come from 5 fixed folders (`ItemEnumerator.m:21`). `~` expands to every user when running as root and only to the current user otherwise (`utilities.m:293-345`). Keys are lower-cased before lookup (`:100-108`). The program is `Program`, then `ProgramArguments[0]`. `BundleProgram` is not read (`:117-164`). A relative program is resolved via the job's own `EnvironmentVariables.PATH` (`:200-259`). "Auto-run" means `RunAtLoad`, `KeepAlive` (bool or dict), `StartOnMount`, any of `StartInterval/StartCalendarInterval/WatchPaths/QueueDirectories/LaunchEvents/Sockets/MachServices`, or legacy `OnDemand=false` (`:429-546`). The enable/disable state comes from launchd's override database `/private/var/db/com.apple.xpc.launchd/disabled.plist` and `disabled.<uid>.plist`, with the right domain chosen per plist location (`utilities.m:756-862`, `LaunchItems.m:303-423`). Those files are 0644 and readable without root (checked with `ls -la`). **This is the most reusable piece of knowledge in the repo.**
- **BTM** (`Plugins/BTM.m`, `Libraries/BTM/dumpBTM.h`). `parseBTM(nil)` from the prebuilt lib finds the last `*.btm` in `/private/var/db/com.apple.backgroundtaskmanagement/` (`DumpBTM: library/code/dumpBTM.m:339-373`). It `dlopen`s the daemon binary `backgroundtaskmanagementd` to get the private `Storage`/`ItemRecord` classes (`dumpBTM.m:30-35`, `dumpBT_Internal.h:13-56`). It then `NSKeyedUnarchiver`-decodes the `store` key (`dumpBTM.m:93-164`) and flattens each record into a dictionary with `uuid, name, devName, teamID, type, disposition, id, url, executablePath, bundleID, associatedBundleIDs, parentID, embeddedIDs` (`dumpBTM.m:527-683`). BTM.m then keeps only records that are enabled, not parents (no `embeddedIDs`), have a string `executablePath` whose file exists, and are deduped on `path|plist` (`BTM.m:76-178`).
  - Verified (`run.sh btm`): the lib still decodes `BackgroundItems-v16.btm` on macOS 26.6 **as uid 501**, which means FDA is needed but root is not. There are 42 records: 5 parents, 11 without `executablePath`, 13 disabled, 15 that KnockKnock can show, and **1 enabled `agent` it drops**. That agent's `executablePath` is bundle-relative (`Contents/Frameworks/...`) and its plist path has no app prefix. Joined to the parent record's URL, both files exist, and `launchctl print gui/501/<Label>` exits 0: the job is loaded now. This is the same case as open issues #49 and #50. Filed as **F-0072**.
  - The 11 no-exe records are type `0x800` (appex, x5), `0x40` (mdimporter, x2), `0x80` (docktile, x1) and 3 `developer (0x20)` records with no URL, all disabled. DumpBTM's `typeDetails` knows none of the bits 0x40, 0x80 or 0x800 (`dumpBTM.m:380-431`). The developer records match the stale entries in #27 ("this software was uninstalled long ago").
  - 22 of 42 records carry `bundleID`, 31 carry `teamID`, 1 carries `associatedBundleIDs`. KnockKnock uses none of them. For an uninstaller, these fields are the way to group "background items owned by app X".
- **Login items** (`Plugins/LoginItems.m`). The deprecated `LSSharedFileList` API is called with `kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes` (`:144-175`). There is also `backgrounditems.btm` bookmark parsing (`:301-391`, the pre-13 per-user format), and "sandboxed" login items found by listing `/Applications/*/Contents/Library/LoginItems/` and cross-checking them against the registered list (`:506-580`, top-level `/Applications` only).
- **System extensions.** `/Library/SystemExtensions/db.plist` → `extensions[]` with `state == "activated_enabled"` → `originPath` (`Plugins/SystemExtensions.m:49-85`). `originPath` is the copy inside the app, so after the app is deleted the entry is dropped (`:97-101`), even though the staged copy under `/Library/SystemExtensions/<uuid>/` is still active (code-read).
- **Kexts.** Top-level `*.kext` in `/System/Library/Extensions/` and `/Library/Extensions/` (`Plugins/Kexts.m:20-95`). Not covered: `/Library/StagedExtensions`, `/Library/Apple/System/Library/Extensions`, plug-in kexts inside bundles (#24 macFUSE).
- **App extensions.** Parses `pluginkit -vmA` text, keeps lines starting with `+` and takes everything from the first `/` as the path (`Plugins/Extensions.m:60-190`). Extensions with no explicit election (leading space) are ignored.
- **Per-item cost.** Every regular file up to 1 GiB gets MD5/SHA-1/SHA-256 (`utilities.m:567+`), a static signature check with `kSecCSCheckNestedCode | kSecCSCheckAllArchitectures`, and a hand-written Mach-O parse with an entropy "packed" check (`Results/File.m:121-150`, `Libraries/MachO/MachO.m`). `openRegularFile` opens with `O_NONBLOCK` and checks by `fstat`, so FIFOs and devices cannot hang it (`utilities.m:520-565`). That is a nice defensive detail.

## Deletion & rules

- **Deletion: none.** There is no trash, no rm and no launchctl bootout (grep for `trash|removeItem|unlink|bootout` finds nothing in the scan or UI path). The only mutations are `toggleLoginItem` for KnockKnock's own login item (`utilities.m:1918-2042`) and the JSON export.
- **Rules.** There are no cleanup rules. The "rules" are the hard-coded location constants per plugin (all `#define`/`const` arrays; the full list is in the journal) plus four JSON allow-lists keyed by absolute path with MD5 values (`WhiteList/*.json`). The allow-lists are data, but they are MD5, path-exact and hand-maintained.
- **Protections.** For a remover these are irrelevant, but two identity rules transfer: trust follows the plist location, not the binary signer (`BTM.m:161-170`), and a macOS-version flag gates the old versus new login-item formats (`LoginItems.m:423-426`).
- **Privilege escalation.** Whole-app root relaunch through AppleScript, with a default "Yes" and "Remember my choice" (`AppDelegate.m:211-255`). Filed as **F-0073**.
- **FDA detection.** `hasFDA()` opens the **system** TCC.db first and returns YES if that works (`utilities.m:1721-1783`). That is the class of **F-0001**: the system TCC.db is readable without FDA on 26.6. The welcome window polls it (`WelcomeWindowController.m:60,149`) and so does the CLI (`main.m:89`), so both can report "granted" without FDA (code-read). Evidence posted on T-0038, and no duplicate finding filed.

## UI

- AppKit with XIBs (`Base.lproj/MainMenu.xib`, `Welcome.xib`) and view-based `NSTableView`s: a category list with per-plugin counts on the left (`CategoryTableController.m`) and an item table on the right (`ItemTableController.m:141-600`). Rows show an icon, name, path, plist, a signing-status icon (`getCodeSigningIcon`, `:928`), a VirusTotal ratio button and "show"/"info" buttons.
- **Reveal in Finder:** `-[NSWorkspace selectFile:inFileViewerRootedAtPath:@""]` on `pathForFinder` (`ItemTableController.m:770-815`). The info window shows hashes, signing, entitlements and the plist (`InfoWindowController.m`, `PlistWindowController.m`).
- By default only untrusted items are shown; the prefs toggle `showTrustedItems` changes that (`AppDelegate.m:797-805`, `ItemTableController.m:739-765`). There is no search, sort or filter field, and no multi-select actions.
- "Unknown items" window: submit hash-unknown files to VirusTotal (`UnknownItemsWindowController.m`, `VirusTotal.m:410-437`). Diff window: compare with a saved JSON scan by path, with changes detected on hashes, signatures, name, plist and command (`diff.m:13-48`, `AppDelegate.m:1641-1691`).
- Localized with `Localizable.xcstrings` (en, es, `mul.lproj` string catalogs). Dark mode is adopted from the console user when running as root (`utilities.m:1626-1677`).
- Performance on big trees is not applicable: result sets are tens to hundreds of rows.

## Tests & quality

- **No tests.** The Xcode project has no `xctest` target (`grep -c xctest project.pbxproj` = 0), and the repo has no test files and no CI config.
- The code style is 2014-era Objective-C: `goto bail`, long functions (`AppDelegate.m` 1,856 lines, `utilities.m` 2,181 lines), globals shared between UI and plugins, and deprecated APIs (`LSSharedFileList*`, `SecKeychain*`, `-[NSAlert alertWithMessageText:]` in `ItemTableController.m:812`, `directoryContentsAtPath:` in `LoginItems.m:534`).
- **Hardening is noticeably good for attacker-controlled input**, and this was recent work: type checks on every plist value (`stringValue`, `makeJSONSafe`, `utilities.m:864-1010`), `@try` around each plugin (`AppDelegate.m:696-708`), a Mach-O parser clamped to `sizeofcmds` (`MachO.m:479-485`), `O_NONBLOCK` + `fstat` file opens, `lchown` after the root export (`AppDelegate.m:1489-1490`), and no-UI/no-mount bookmark resolution (`LoginItems.m:163-164, 247-248`).
- The **binary blob** `libDumpBTM.a` has no build step in this repo. Its source is a separate repo last pushed 2023-10-18. That source has a visible bug: `contents[KEY_BTM_MDM_PAYLOAD] = storage.itemsByUserIdentifier;` stores user items under the MDM key (`DumpBTM: dumpBTM.m:326-330`, code-read). KnockKnock's header does not define that key, so it does not matter here.

## Known problems

1. **F-0072 (filed, verified):** background items whose path does not resolve are dropped. That covers in-bundle SMAppService agents (bundle-relative BTM paths, and `BundleProgram` is never read), orphaned launchd plists (deliberate since e38cad0), and system extensions whose `originPath` is gone. Upstream issues #49 and #50.
2. **F-0073 (filed, code-read):** the whole GUI is relaunched as root via AppleScript. Every user's plists, and the binaries they reference, are parsed as uid 0.
3. **Class of F-0001 (not filed; evidence on T-0038):** `hasFDA()` probes the system TCC.db first (`utilities.m:1737`).
4. Disabled BTM records and records without `executablePath` are skipped (`BTM.m:97`, `:113-119`). The stale `developer (0x20)` records of uninstalled apps are invisible (#27; 3 on this Mac, verified). Feature gap, noted on T-0005.
5. `getPath()` takes `lastObject` of an **unsorted** directory listing when several `BackgroundItems-v*.btm` exist (`DumpBTM: dumpBTM.m:364-368`). Unverified: this Mac has only `-v16`.
6. `/Library/PrivilegedHelperTools` is not enumerated (#15). An SMJobBless helper whose plist was removed stays invisible (code-read).
7. The app inventory relies on `system_profiler` (2.8 s here). If it fails, DockTiles waits 5 minutes (`DockTiles.m:66-83`).
8. Sandboxed login items are searched only in top-level `/Applications` (`LoginItems.m:534-541`).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Persistence location catalogue (20 mechanisms, all paths) | study | `consts.h:16,91-136`, `Plugins/*.m` constants, `ItemEnumerator.m:21` | The best single list of where apps leave background items. Facts, not code: re-express as macontrol's own data table (the journal has the full list). GPL. |
| launchd auto-run semantics (`isAutoRun`) | study → rewrite | `Plugins/LaunchItems.m:429-546` | The trigger key list and precedence (`Disabled` vs override, legacy `OnDemand`) are correct and subtle. Reimplement from `launchd.plist(5)`. |
| launchd override (enable/disable) per domain | study → rewrite | `utilities.m:756-862`, `LaunchItems.m:303-423` | Lets the uninstaller show "disabled but installed" leftovers. The files are readable without root. |
| BTM decoding via `libDumpBTM.a` (dlopen daemon + NSKeyedUnarchiver) | ignore (use as oracle only) | `Libraries/BTM/*`, DumpBTM repo | GPL binary blob, private classes, dlopen of a daemon. Works on 26.6 (verified) but fragile. macontrol writes its own bplist/keyed-archive reader, with this lib as the test oracle (`research/bench/objective-see-knockknock/btm_probe.m`). |
| BTM record → app attribution (bundleID/teamID/parent join) | improve | `Plugins/BTM.m:76-178` | KnockKnock throws away exactly the fields an uninstaller needs and drops bundle-relative items (F-0072). |
| "Apple binary via non-/System plist is untrusted" | study → rewrite | `BTM.m:161-170`, `LaunchItems.m:182-190` | A good protection rule for macontrol's "never touch Apple items" guard: judge by the plist/record location plus the signer, never the signer alone. |
| Code-signing classification (Apple / App Store / Dev ID / notarized) | study → rewrite | `Signing.m:227-302` | Requirement strings are standard. Useful for showing who made a leftover. |
| Safe file open for untrusted paths | study | `utilities.m:520-565` (`openRegularFile`) | `O_NONBLOCK` + `fstat` + size cap is the right pattern for reading plists and binaries named by user-writable config. |
| Login items via `LSSharedFileList` | ignore | `Plugins/LoginItems.m:96-200` | Deprecated. On macOS 13+ BTM is the source of truth. |
| Mach-O parser, entropy "packed" check, VirusTotal | ignore | `Libraries/MachO/MachO.m`, `VirusTotal.m` | Security features outside macontrol's scope. |
| Trust allow-lists (MD5 JSON) | ignore | `WhiteList/*.json` | MD5, path-exact and stale-prone. macontrol uses signing and location instead. |
| Whole-app root relaunch | ignore (anti-pattern) | `utilities.m:2057-2140`, `AppDelegate.m:141-255` | F-0073. Use an SMAppService daemon with a narrow XPC API. |
| Scan-diff against saved JSON | study | `diff.m`, `AppDelegate.m:1641-1691` | Idea: "new background items since last scan" would be a cheap, useful macontrol panel. |
| Reveal in Finder | take (trivial API, no code copy) | `ItemTableController.m:809` | `NSWorkspace selectFile:inFileViewerRootedAtPath:` (or `activateFileViewerSelectingURLs:` for many). A public API, nothing to license. |

## Open questions

- Is there any public API to remove a single stale BTM record (for example the `developer (0x20)` entries of uninstalled apps) short of `sfltool resetbtm`, which resets everything? Unverified. KnockKnock never removes records, and Pearcleaner's report asks the same thing (`alienator88-pearcleaner.md:124`).
- Does trashing an app that registered an `SMAppService` agent unload the job and drop the BTM record, or does the job keep running from the Trash? The dropped agent above lives inside an installed app, so this needs a throwaway ad-hoc-signed fixture app (plan in F-0072 "how"). Unverified.
- The BTM type bits `0x40`, `0x80`, `0x800` look like mdimporter, docktile and appex records on 26.6 (verified by extension). Are there more (Quick Look, Finder Sync, widgets)? Needs `sfltool dumpbtm` as root on a machine with more apps. Unverified.
- When several `BackgroundItems-v*.btm` files exist (after an OS upgrade), which is live? DumpBTM takes the last one in directory order. macontrol should pick the highest `-vN`. Unverified.
- Does reading the BTM database need FDA specifically, or is it readable by any process? The file is 0644, and my terminal has FDA, so I could not separate the two. Rerun `run.sh btm` from an FDA-less ad-hoc app, as in the F-0001 method.
