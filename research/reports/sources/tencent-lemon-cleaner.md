# Source deep dive: Tencent Lemon Cleaner (Tencent/lemon-cleaner)

Task T-0015, researcher `dive-tencent-lemon-cleaner`, 2026-09-23. Clone: `research/sources/tencent-lemon-cleaner` at `7ff8676` (2026-05-08 16:48 +0800, "fix: 修复了若干问题 (#144)").
Paths below are relative to that clone unless marked otherwise. "Verified-locally" means I ran it on this Mac (macOS 26.6). Everything else comes from reading the code. Findings filed: **F-0018, F-0019, F-0020, F-0021**.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/Tencent/lemon-cleaner (product site https://lemon.qq.com) | `gh api repos/Tencent/lemon-cleaner`, `README.md` |
| License | GPL-3.0 for Lemon (the app) and LemonMonitor. GPL-2.0 for the `LemonDaemon` module. Third-party parts keep their own licenses (BSD-2/3, MIT, MPL-1.1). The API reports `NOASSERTION`. | `LICENSE.txt:5,689-1560`, `LICENSE_LemonCleaner_LemonDaemon.txt:5`, `README.md` "License" |
| Stars / forks | 6 328 / 796, 53 watchers. Not a fork, not archived. 6 contributors, 43 PRs ever. | `gh api repos/...`, `/contributors`, `/pulls?state=all`, 2026-09-23 |
| Created / last push | 2022-07-12 / 2026-05-08. Latest release v5.1.20 (2025-10-22). Commits are periodic code dumps titled "fix several problems". Open issue #151 asks when the shipping 5.3.5 will be open-sourced, so the public tree lags the product. | `gh api .../releases`, `/commits` |
| Language | Objective-C 5.65 MB, C 81 KB, ObjC++ 67 KB. About 170 k lines of first-party .m/.h/.c. The only Swift is the YMTreeMap pod. AppKit plus xib (50 xibs), Masonry, CocoaPods. Deployment target macOS 10.11. | `gh api .../languages`, `wc -l`, `Lemon.xcodeproj/project.pbxproj` |
| Open issues | 35. The themes are listed under Known problems. | `gh api repos/Tencent/lemon-cleaner/issues?state=open&per_page=50` |

**What the license lets us do: study only.** macontrol is not GPL, so no Lemon code and no verbatim rule XML can go into it. Facts about file-system locations ("`~/Library/Caches/com.apple.appstoreagent` must not be cleaned or the App Store update list breaks") are not copyrightable. We can re-derive them and cite Lemon as the pointer. The one reusable piece is **YMTreeMap** (`Pods/YMTreeMap`, MIT, © 2017 Yahoo, `Pods/YMTreeMap/LICENSE`). It is a third-party pod, not Lemon code, so we can take it with its notice.

## Summary

Lemon (腾讯柠檬清理) is a free, mature, Chinese-market Mac utility suite. It covers:
- Rule-driven junk cleaning (system, app, browser and mail caches and logs, language packs, unused Mach-O slices, and "leftovers").
- Large files (> 50 MB via Spotlight), duplicate files, and similar photos.
- Browser privacy cleaning, an app uninstaller with leftover discovery, login-item management, and "file move" (relocating chat-app data).
- A disk-space map (treemap) and a menu-bar monitor (CPU, memory, temperatures, fans, network).
- A microphone and camera privacy monitor ("Owl").

It has a root daemon for everything the user cannot delete.

For macontrol it is worth studying for two reasons. First, the **data-driven rule format** (XML filters, atoms and actions), and the incident-driven exclusions and per-app special cases collected over about 10 years (copyright headers go back to 2011 "Magican Software"). Second, a **negative checklist**. The engineering underneath is weak in exactly the places macontrol must be strong:
- The trash path is a Finder AppleScript with the path pasted in. A filename runs code (verified-locally, F-0018).
- The disk map throws away the speed of `getattrlistbulk` with per-entry `NSURL` lookups (12-13x in a bench, F-0019).
- The treemap distorts areas as `ln(bytes)^12` (F-0020).
- The rule file can be overridden from a user-writable path, protected only by an unkeyed MD5, and a failed delete escalates to root (F-0021).
- The root daemon has no client authorization and runs `bash -c` on paths. This is the same class as F-0002, and the evidence is on T-0015.
- Tests are the two Xcode template stubs.

## Architecture

- **Workspace.** `Lemon.xcworkspace` is the main app plus `Pods/`. Third-party pods: AFNetworking 3.2.1, FMDB 2.7.5, Masonry 1.1.0, YMTreeMap (`Podfile:17-21`). The features are **local pods** under `localPod/`, one per module:

  | Module | Lines | Purpose |
  |---|---|---|
  | QMCoreFunction | 25 k | Utilities, XPC client, file operations |
  | LemonClener (sic) | 21 k | Junk-rule engine |
  | QMUICommon | 18 k | Shared UI |
  | LemonDaemon | 16 k | Root daemon |
  | PrivacyProtect | 15 k | Mic and camera monitor |
  | LemonMonitor | 11 k | Menu-bar app |
  | LemonUninstaller | 9.7 k | Uninstaller |
  | LemonPhotoClean | 6.7 k | Similar photos |
  | LemonDuplicateFile | 5.2 k | Duplicate files |
  | LemonSpaceAnalyse | 4.5 k | Disk map |
  | LemonBigOldFile | 3.3 k | Large files |
  | Others | | Stat, hardware, net speed, login items, file move |

- **Processes.**
  - `Tencent Lemon.app` is the UI.
  - `LemonMonitor.app` is a LoginItem and LaunchAgent (`Lemon/PreLaunch/com.tencent.LemonMonitor.plist`) that runs the menu bar and quick clean.
  - `LemonDaemon` runs as root. It is a KeepAlive LaunchDaemon with the Mach service `com.tencent.LemonDaemon` (`Lemon/PreLaunch/com.tencent.Lemon.plist`).
  - `com.tencent.Lemon.trash` is a LaunchAgent with `WatchPaths ~/.Trash` that launches LemonMonitor `trashChanged` to offer leftover cleanup when an app is trashed (`Lemon/PreLaunch/com.tencent.Lemon.trash.plist`). Open issue #145 blames this agent for a Finder desktop hang.
  - `com.tencent.Lemon.uninstall` watches the app bundle and self-uninstalls.
- **Privilege model.**
  - Install runs `STPrivilegedTask`, a wrapper around `AuthorizationExecuteWithPrivileges`, which is deprecated since 10.7 and loaded with `dlsym` (`localPod/QMCoreFunction/.../Utility/STPrivilegedTask.m:3,191-198`, `Lemon/PreLaunch/PreLaunch.m:110-135`). It copies the daemon to `/Library/Application Support/Lemon/`.
  - The fallback is `do shell script "/bin/launchctl load -w …" with administrator privileges` (`localPod/QMCoreFunction/.../LMXpcClient/LMDaemonStartupHelper.m:96-98`). Open issue #108 reports "asks for the password on every launch".
  - The client sends C structs packed into `NSData` over XPC (`Tools/LemonDaemon/LemonDaemon/DaemonXpcService/LMDaemonXPCService.m:20-50`). The daemon switches on `cmd_magic` (`LMXPCFunction.m:52-430`).
- **UI and engine separation is weak.**
  - Engines are pods, but they call UI singletons. For example, `+[QMCleanUtils caluactionSize:]` checks the **main bundle id** to decide whether to ask `QMCleanManager` or `QMLiteCleanerManager` for the stop flag, and it posts progress to the main queue from inside a size walk (`LemonClener/LemonClener/libcleaner/QMCleanUtils.m:86-104`).
  - Cross-module communication goes through singletons and `NSNotificationCenter`, for example `SimilatorImageScanProgress` in `ImageGroupCompare.m`.

## Scanning

### Junk scan (LemonClener)
- **Engine.**
  - `QMScanCategory` runs each sub-item's actions on an `NSOperationQueue` (max 8 at once, `.userInitiated`) and waits with `addOperations:waitUntilFinished:YES`. It posts results to a serial queue (`LemonClener/LemonClener/libcleaner/QMScanCategory.m:53-57,183-225`).
  - Directory enumeration uses `NSFileManager enumeratorAtURL`. Aliases are skipped with `NSURLIsAliasFileKey`, and a depth `level` from the rule calls `skipDescendants` (`QMCleanUtils.m:268-291`).
- **Sizes.** `LMFileAttributesTool caluactionSize:` (`localPod/LemonFileManager/.../LMFileAttributesTool.m:45-144`):
  - Files: `lstat` `st_blocks*512` ("disk mode") or `st_size`.
  - Directories: first Spotlight `kMDItemPhysicalSize`, then a full `NSDirectoryEnumerator` walk summing `st_blocks*512`.
  - Verified-locally: `mdls` returns `kMDItemPhysicalSize = (null)` for both a folder (`~/Library/Caches`) and a package (`Calculator.app`), so the Spotlight shortcut effectively never hits.
  - No hard-link dedupe (no `st_ino`), so each link is counted. No clone awareness (see F-0004 and F-0010).
  - **A 10 s timeout silently truncates the walk** and returns the partial sum as the size (`LMFileAttributesTool.m:28,79-93,138-140`). Only CoreSimulator and DerivedData are exempt (`182-218`). The truncated number is then cached for the rest of the scan (`QMCleanUtils.m:105-106`, `QMScanFileSizeCacheManager`).
- **Cancellation.** An `isStopScan` flag is polled per operation, and every 100 files inside size walks (`LMFileAttributesTool.m:117-130`).
- **Bugs spotted.**
  - `checkURLFileType:` calls `isPipe(pathURL.absoluteString.UTF8String)`. `absoluteString` is `file:///…`, so `stat` always fails and the FIFO guard (written for an EasyConnect pipe that hung the scan) is dead code (`QMCleanUtils.m:238-265`, `isPipe` call at 254).
  - `isEmptyDirectory:` tests the parent `path` on every loop iteration instead of the child (`QMCleanUtils.m:159-169`).

### Disk map (LemonSpaceAnalyse)
- **Walker.** `LMFileScanTask` calls `getattrlistbulk` with a 10 000-byte stack buffer and requests name, objtype and `ATTR_FILE_ALLOCSIZE` (`localPod/LemonSpaceAnalyse/.../ScanManager/LMFileScanTask.m:102-131`). `LMFileScanManager` runs `processorCount` workers over a LIFO `NSMutableArray` task stack under a pthread mutex (`LMFileScanManager.m:54-56,146-254`).
- **Costs and bugs.**
  - Idle workers busy-poll with `usleep(1000)`. The `loopCondition` pthread cond is initialised but never waited on (`LMFileScanManager.m:27,151,247-251`).
  - `removeObject:` on the task stack is O(n) (`230`).
  - `hadScanDiskSize += size` runs from every worker without a lock (`65-67`, progress only).
  - Per-entry iCloud checks through `NSURL` cost 12-13x in a bench (**F-0019**, `research/bench/lemon-ubiquity-lookup/walk.m`).
- **Semantics.**
  - Sizes are allocated bytes, except `.app`, `.bundle` and `.simruntime` directories, which use Spotlight's logical `NSMetadataItemFSSizeKey` (`LMFileScanTask.m:238-245`). Verified-locally: Calculator.app is 6 006 599 B logical against `du -sk` 3 524 KiB.
  - No hard-link or clone dedupe.
  - The walk starts at `/` (`LMSpaceMainViewController.m:25`) and skips `/System/Volumes`, `/Volumes` and `/private/tmp/msu-*` by path string (`LMFileScanTask.m:249-257`).
  - The user cannot choose a root folder.
- **Memory model.**
  - One `LMItem` NSObject per entry, holding an `NSMutableArray` of children, a name **and a full-path `NSString`** (`LMItem.h:13-18`).
  - A comment claims an `@autoreleasepool` cut peak memory "from 27G to 2.7G" (`LMFileScanTask.m:87`). Unverified.
  - Sizes are rolled up in one recursive pass after the walk (`LMSpaceMainViewController.m:367-368`), so nothing is shown until the scan completes.
- **Progress** is bytes seen divided by (volume total minus available) of the home volume, polled every 0.2 s (`LMFileScanManager.m:57,70-86,130-135`).

### Other scanners
- **Large files.** Runs `mdfind -onlyin %@ "kMDItemFSSize > 52428800"` through `/bin/bash -c` with the folder path **unquoted** (`localPod/LemonBigOldFile/.../BigOldFile/LMBigFileScanManager.m:139`, runner `QMShellExcuteHelper.m:29-35`). A folder with a space in its name breaks the query, and `$(…)` in a folder name is executed. It is Spotlight-only, so unindexed locations return nothing. Issue #139 ("can't scan outside the user folder") may be related, but that is unverified.
- **Duplicates.** Files of 200 KB and up (`QMDuplicateFiles.m:14,125`) are grouped by size. Then:
  - MD5 of the first 10 MB (`245-283`).
  - For files over 10 MB, a CRC32 of the rest added to the key (`288-381`).
  - No byte-for-byte confirmation. No inode or clone check, so two hard links show as duplicates and deleting one frees nothing.
- **Similar photos.**
  - Photos are bucketed by **file creation minute** (`NSFileCreationDate`, not EXIF) (`localPod/LemonPhotoClean/.../ImageGroupCompare.m:70,330-349`).
  - Each image is decoded at full size and drawn into a 50x50 bitmap, then turned into 4-level grey quantisation (`GetSimilarity/CalculatePictureFingerprint.m:13,29-98,133-155`).
  - Pairs are compared within a bucket, and a match needs similarity > 0.88 (fixed, see issue #94) (`ImageGroupCompare.m:547-660`).
  - `compareDataA:` compares `NSNumber` objects with `==`, which only works because small NSNumbers are tagged pointers (`CalculatePictureFingerprint.m:105`).
- **Leftovers (junk "appleft" action).**
  - A preference plist whose bundle id has no app in the LaunchServices DB is a candidate (`absolutePathForAppBundleWithIdentifier`, deprecated) (`LemonClener/.../QMSpecialClean/QMAppLeftScan.m:57-81`).
  - The candidate is dropped if any installed app shares the first two bundle-id components ("company") (`195-238`).
  - Its app name is then matched case-insensitively against folder names (`246-300`).
  - The bundled XML contains no `appleft` action, so this runs only with a downloaded rule file. That is unverified.
- **Per-app caches.** `QMCacheEnumerator` fuzzy-matches `~/Library/Caches`, container caches and `$TMPDIR` entries to installed apps by bundle-id segments and letters-only app names. It has hard-coded special cases, for example a `163music` exception because stripping digits made it match Apple's `music` (`QMCacheEnumerator.m:226-300`, the exception at `272`).

## Deletion & rules

- **The rule format is data-driven (good idea, GPL content).** It lives in `LemonClener/LemonClener/libcleaner/garbage1_{en,zh}.xml` (version `2024.03.21.1`) and `garbage_appstore_{en,zh}.xml`. The format:
  - `<filter id column relation value action>`. Columns are `filename`, `filepath`, `filesize`, `subfilecount`, `time`, `bundleid`, `app=signed` and a language key. Relations are `is`, `begin with`, `end with`, `contains`, `match` (regex), `greater` and `smaller`. Actions are `include` and `exclude`.
  - There are 86 filters, 73 of them excludes, and many carry a comment naming the incident behind them (`garbage1_en.xml:2-112`).
  - `<category><item recommend fastmode bundleid appversion><action type clean><atom filters="(8+(9|10|11))"/><path type=abs|special level value filename=regex filters/>`. In the atoms, `+` means AND and `|` means OR (`QMFilterParse.m:36-160`).
  - Action types map to scanners (`QMXMLParse.m:295-340`). Clean types are `remove` (the default), `movetrash`, `truncate`, `removelanguage`, `cutbinary` and `deletebinary` (`QMXMLParse.m:352-372`, `QMXMLItem/QMActionItem.m:104`).
  - The bundled set is small: 18 items. The only per-app items are Xcode, Sketch and six browsers. The "hundreds of apps" the README claims must come from a downloaded rule file (see F-0021) or the encrypted uninstaller config. Unverified.
- **Rule provenance: F-0021.**
  - A higher-versioned file in `~/Library/Application Support/com.tencent.lemon/Knowledge*/2` wins.
  - Its "signature" is an unkeyed MD5 prefix, and a failed check falls through to parsing the raw XML.
  - A parse error deletes the file (`QMXMLParseManager.m:159-165`).
- **Delete primitive.**
  - Junk defaults to `McCleanRemoveRoot`. It tries `removeItemAtPath:` as the user, and on failure sends the path to the daemon, which deletes as root (`LemonClener/.../QMCleanerManager/QMRemoveManager.m:86-139`, `localPod/QMCoreFunction/.../FuncOpera/McFunCleanFile.m:181-205,269-330`).
  - Junk is deleted permanently, not moved to Trash. The user-selectable "Trash" and "Downloads" items (recommend=NO) are permanent too.
  - There is no protected-path denylist in the delete path. The daemon's only guard rejects the **first** path if it equals `/` (`Tools/LemonDaemon/LemonDaemon/FileAction/CmcFileAction.m:14-36`).
  - The daemon's own "trash" renames files into `~<user>/.Trash` as root with a Finder-like name, so no Put Back and root ownership is kept (`CmcFileAction.m:71-129`).
- **Large files and duplicates.** These go through the Finder AppleScript trash, with a silent fall back to `removeItemAtPath:` when Automation is not granted (**F-0018**, and open issue #149). The size is counted before the async AppleScript runs.
- **Uninstaller.**
  - Leftovers are found by regex over names in fixed folders: Application Support, Caches, Preferences, Saved Application State, Crash Reporter, Logs, Containers, LaunchAgents and LaunchDaemons, and `/Library` or `~/Library` "other". The regex is `\b((bundleName)|(executableName)|(showName))(\..*){0,}\b` over space-stripped lowercase names, plus a bundle-id regex and a company sub-folder match (`localPod/LemonUninstaller/.../Manager/LMLocalApp.m:813-1060,1504-1630`).
  - An inline incident note is worth remembering: FinalShell's bundle id is `st`, and an earlier `containsString:` match **deleted every launchd plist on the machine** (`LMLocalApp.m:1606-1611`).
  - The predefined per-app scanner is dead in this tree. `_curAppSettings` is never assigned, the loader is commented out (`McUninstallSoftManager.m:83-113`), and the 475 KB `json_setting.qce` is encrypted and unused.
  - Every group except "Other" is removed permanently through `McCleanRemoveRoot`. Only "Other" goes to the Trash (`LMFileGroup.m:186-192`).
  - Apple apps are excluded, except Keynote, Numbers and Transporter (`LMLocalAppListManager.m:629-645`). So **Lemon cannot remove bundled Apple apps** (GarageBand, iMovie and the like). That is a gap macontrol wants to fill.
  - It also kills running processes, unloads kexts and runs `launchctl unload` (`LMFileGroup.m:150-185`).
- **Language removal.**
  - Lemon removes every `.lproj` except the system language, `en`, `zh*` and a keep list. It skips `com.apple*`, Xcode, Microsoft, 1Password and IINA (`QMSpecialClean/QMAppUnlessFile.m:140-215`, `garbage1_en.xml` item 1003, filters 48-52, 71, 83).
  - Verified-locally: deleting a whole `.lproj` from an ad-hoc-signed bundle keeps `codesign --verify --strict` valid, because the default resource rules mark `.lproj` content as `"optional" => true` in `CodeResources`. So language cleanup is signature-safe for normally signed apps. I did not test App Store or notarized apps.
- **Binary thinning.** The root daemon runs `lipo "<path>" -thin <arch> -output "<path>"` in place through `/bin/bash -c` (`Tools/LemonDaemon/LemonDaemon/FileAction/CutBinary.m:82-94`, `cmd/ExecuteCmdHelper.m:13-41`). This is shell injection as root, the same class as F-0002. What it does to code-signature validity is unverified.
- **Xcode simulator runtimes.** Lemon calls `xcrun simctl runtime delete "<uuid>"` instead of removing files (`QMRemoveManager.m:144-163,171-220`). That is a good idea, but it goes through `bash -c`. Open issue #116 says the runtimes still reappear after cleaning.
- **Protections.** Protection lives only in scan-side filters. The "app is running, quit it first" warning (`checkWarnResultItem:`, `QMRemoveManager.m:223-253`) is **commented out** in the live removal loop (`QMRemoveManager.m:397-405`).
- **Dry-run.** There is no user-facing dry run. `#ifdef DEBUG` builds skip deletion in the App Store path and the large-file path only (`QMRemoveManager.m:64-65`, `QMLargeOldManager.m:441-452`).

## UI

- **Technology.** AppKit with xibs, Masonry, custom `NSView` drawing and many one-off controls (`QMUICommon`). Light and dark themes come from `LMThemeManager`. English and Simplified Chinese.
- **Disk map.**
  - A one-level treemap laid out by YMTreeMap, with one `LMSpaceView` NSView per tile holding an icon, a name and a size (`LMSpaceResultViewController.m:880-938`).
  - Tile areas are `ln(bytes)^12`, at most 30 tiles, and anything under 2% of the largest weight is dropped (**F-0020**). The arithmetic behind the numbers: `python3 -c "import math;f=lambda s:math.log(s)**12;print(f(1e9)/f(100e9))"` gives 0.090.
  - Clicking a folder tile drills in (`LMSpaceView.m:111-117`). A breadcrumb path bar (`LMSpacePathView`) and a three-column list mode (`tableViewOne/Two/Three`) are also available.
  - Reveal in Finder is on right-click and on the rows (`LMSpaceView.m:58-77`, `LMSpaceTableRowView.m:91,111`).
  - **There is no delete or trash action in the disk map.** The module has no delete code at all.
- **Cleaner results.** Categories and sub-items with checkboxes and recommended defaults, plus per-item "tips" text from the rules. The quick scan (`fastmode="YES"` items) runs in the menu-bar app.
- **Visual quality.** Polished in its screenshots (`Resource/lemon_app.png`), but hand-rolled. Open issue #128 reports layout breaking on macOS Tahoe, which shows the cost of fixed-frame xib layouts.

## Tests & quality

- The only tests are two Xcode template files (`LemonClener/LemonClenerTests/LemonClenerTests.m`, `Tools/LemonMonitor/LemonMonitorTests/QQMacMgrMonitorTests.m`) with `testExample` stubs. There is no CI config (no `.github/`) and no rule-file validation.
- Code style:
  - Frequent `@try/@catch` around ordinary collection access.
  - Commented-out blocks, including the running-app safety check.
  - Singletons everywhere.
  - Many `NSLog`s of full user paths.
  - Mixed Chinese and English comments. They are valuable, because they record incidents such as FinalShell, 1Password, IINA and the macOS 14.3 pipe slowdown.
- Shell use is widespread: `QMShellExcuteHelper`, `ExecuteCmdHelper` and `system()` with interpolated strings, in both the app and the root daemon.

## Known problems

Open issues are cited by number (fetched 2026-09-23). The rest are from the code review above.

- **Security (#148).** The root XPC service accepts any client ("TODO: xpc authorization" at `Tools/LemonDaemon/LemonDaemon/DaemonXpcService/LMDaemonListenerDelegate.m:21-49`). It casts caller `NSData` to C structs without length checks, and runs `launchctl list | grep <label>` through `bash -c` with a caller-supplied label (`LMXPCFunction.m:414-418`). I confirmed each cited line. This is the F-0002 class, and the extra evidence is on T-0015.
- **Data safety (#149).** Trash silently becomes permanent delete. Filed with more detail as F-0018.
- **Privacy questions (#150).** A web view loads from `sdi.3g.qq.com` with a guid. The hardware lookup sends a partial serial number to Apple over plain HTTP. There is an unused multipart uploader.
- **Stability and performance.**
  - #145: the Trash WatchPaths agent hangs Finder.
  - #114: the scan freezes on macOS 15.4.
  - #132: LemonMonitor CPU use.
  - #69: memory leak.
  - #101: antivirus alerts.
  - #108: password prompt on every launch.
- **Functionality.**
  - #116: simulator runtimes are not cleaned.
  - #139: cannot scan outside the home folder.
  - #94: the photo similarity threshold is fixed at 0.88.
  - #59: an input method is missed by the uninstaller.
  - #133: a login item is disabled by itself.
- **From the code.**
  - The 10 s silent size truncation.
  - The dead FIFO guard.
  - Unquoted `mdfind` paths.
  - MD5 plus CRC duplicates with no byte compare and no hard-link check.
  - Photo buckets use file creation time, not EXIF.
  - Logical and allocated sizes are mixed in one map.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Rule format (filters, atoms, actions; `recommend`, `fastmode`, `level`, `bundleid`/`appversion` gating, clean types) | study | `LemonClener/LemonClener/libcleaner/garbage1_en.xml`, `QMXMLParse.m`, `QMFilterParse.m`, `QMXMLItemDefine.h` | A proven data-driven shape for macontrol's rule schema. We re-express it as JSON with a validated schema and path-root allowlist (F-0021). GPL, so the design is borrowed, not the code. |
| Bundled rule content (exclusions and per-app paths) | study | `garbage1_en.xml:2-112` (filters), `:114-361` (items) | An incident-hardened list of "do not touch" caches (`com.apple.appstoreagent`, IconServices, FontRegistry, LaunchServices, Safari SafeBrowsing, 1Password, IINA, desktop-picture and ColorSync caches). Re-derive each entry and cite it. Do not copy verbatim (GPL). |
| Per-app cache matching by bundle id and name | study | `QMCacheEnumerator.m:120-300`, `QMAppLeftScan.m:57-300` | Shows how loose matching needs hand-made exceptions (163music). macontrol should key on exact bundle ids and container metadata, not letters-only names. |
| Uninstaller leftover regex and company match | study | `localPod/LemonUninstaller/.../LMLocalApp.m:813-1060,1504-1630` | The FinalShell incident (`:1606-1611`) is a test case to reproduce: an app whose bundle id is a short string must never match unrelated files. Our design follows T-0005. |
| getattrlistbulk disk walker | rewrite | `localPod/LemonSpaceAnalyse/.../ScanManager/LMFileScanTask.m`, `LMFileScanManager.m` | The right syscall, the wrong hot path (F-0019): a full path per node, no inode, device or clone attributes, busy-wait workers, no partial results. |
| Treemap layout (YMTreeMap, MIT, Yahoo) | take | `Pods/YMTreeMap/YMTreeMap.swift`, `Pods/YMTreeMap/LICENSE` | MIT third-party code. It is fine to vendor with its notice, or rewrite (about 60 lines). Feed it raw sizes, not Lemon's log weights (F-0020). |
| Disk map view (NSView per tile, one level, no delete) | rewrite | `LMSpaceResultViewController.m:880-1000`, `View/LMSpaceView.m` | Area distortion, a 30-tile cap, no multi-level view and no delete. macontrol needs a Radix-grade map. |
| Finder AppleScript trash | ignore | `localPod/LemonFileManager/.../LMAppleScriptTool.m` | Injection (verified) and a silent permanent-delete fallback (F-0018). `FileManager.trashItem` solves the Put Back problem Lemon worked around (T-0010 D3). |
| Root daemon, installer and XPC protocol | ignore | `Tools/LemonDaemon/**`, `Lemon/PreLaunch/**`, `STPrivilegedTask.m` | No client authorization, `bash -c` on paths, deprecated `AuthorizationExecuteWithPrivileges`, and GPL-2. macontrol uses an SMAppService helper with a typed XPC API (F-0002 "after"). |
| Duplicate finder staging (size, then head hash, then tail) | improve | `localPod/LemonDuplicateFile/.../QMDuplicateFiles.m:14,125,205-395` | The staged-hash idea is sound. Replace MD5 and CRC with a strong hash plus a byte compare before deleting, and skip same `(dev, ino)` and clone pairs. |
| Similar photos | rewrite | `localPod/LemonPhotoClean/**` | Full-size decode for a 50x50 grey fingerprint, file-creation-minute buckets and a fixed threshold. Use `CGImageSourceCreateThumbnailAtIndex` plus Vision feature prints and EXIF capture time. |
| Large files via `mdfind` through `bash -c` | ignore | `LemonBigOldFile/.../LMBigFileScanManager.m:139` | Unquoted path in a shell, and Spotlight-only coverage. macontrol gets large files from its own walk. |
| Language-pack removal | study | `QMSpecialClean/QMAppUnlessFile.m:140-215` | A useful feature. Removing a whole `.lproj` keeps the signature valid (verified-locally, ad-hoc bundle). Keep Lemon's exclusions as test cases (1Password, IINA). |
| Simulator runtimes through `simctl` | improve | `QMRemoveManager.m:144-220` | The right approach (let `simctl` delete runtimes), but use `Process` with an argv array, not `bash -c`. Issue #116 means we should verify the result by listing again. |
| Running-app check before cleaning an app's cache | improve | `QMRemoveManager.m:223-253` (disabled at `397-405`) | Worth having, and live, in macontrol: warn or skip when the owning app is running (compare F-0015). |
| Trash WatchPaths agent, menu-bar monitor, Owl privacy monitor, file move | ignore | `Lemon/PreLaunch/com.tencent.Lemon.trash.plist`, `Tools/LemonMonitor`, `Tools/PrivacyProtect`, `localPod/LemonFileMove` | Out of scope, or harmful (#145). |

## Open questions

1. Does the shipping Lemon (5.3.x) download rule files into `Knowledge*/2`, and are they signed with anything stronger than the MD5 prefix? The updater is not in this tree.
2. What is in `json_setting.qce` (475 KB, encrypted)? Is it the "hundreds of apps" uninstall knowledge the README describes? The decrypt path is commented out, and I did not try to decrypt it.
3. Does in-place `lipo -thin` of a universal binary inside a signed app keep the app launchable on Apple Silicon for nested helpers sealed in `CodeResources` by file hash? Unverified. It matters only if macontrol ever offers binary thinning. I recommend it does not.
4. Does `SF_DATALESS` (the F-0019 proposal) mark every "not downloaded" iCloud Drive and File Provider item that `NSURLIsUbiquitousItemKey` plus download status catches? This Mac has no iCloud Drive folder, so it is untested here. It needs a Mac with iCloud Drive or a File Provider test domain.
5. What is Lemon's real disk-map wall-clock on a full volume? I did not build Lemon. F-0019's 12-13x figure is from a single-threaded bench of its per-entry pattern, not from Lemon itself.
