# Source deep dive: DaisyDisk (closed source)

Task T-0028, researcher `dive-daisydisk`, 2026-09-23. Journal M-0023, findings F-0055 and F-0056.
DaisyDisk is closed source. Everything here comes from public material: the v4 user guide, release log, blog, specs, FAQ, the Homebrew cask, the App Store lookup API, and the **metadata** of the downloadable bundle (Info.plist, code signature, entitlements, the helper's embedded plists, Sparkle's Info.plist). I did not disassemble, decompile or launch the app. Launching it would mean a trial-email step, TCC prompts and an admin prompt for the helper.

**How to read the citations.** Text snapshots of every page are in `research/sources/daisydisk/`, which is gitignored and can be re-fetched. A citation gives the snapshot line number:

| Tag | Snapshot file | Live URL |
|---|---|---|
| `G:<Page>:n` | `guide4/<Page>.txt` | https://daisydiskapp.com/guide/4/en/<Page>/ |
| `R:n` | `site_releases.txt` | https://daisydiskapp.com/releases |
| `S:n` | `site_specs.txt` | https://daisydiskapp.com/specs/ |
| `FAQ:n` | `site_support_faq.txt` | https://daisydiskapp.com/support/faq |
| `P:n` | `site_support_pricing.txt` | https://daisydiskapp.com/support/pricing |
| `H:n` | `home.txt` | https://daisydiskapp.com/ |
| `B:<slug>:n` | `blog/<slug>.txt` | https://daisydiskapp.com/blog/<slug>/ |
| `blog index:n` | `site_blog.txt` | https://daisydiskapp.com/blog/ (the first page of posts) |
| `M:n` | `bundle-metadata.txt` | metadata dump of `DaisyDisk.zip` 4.34.2, sha256 `45ef4639…4257` |

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://daisydiskapp.com. Mac App Store id 411643860 (bundle `com.daisydiskapp.DaisyDisk`). Stand-alone bundle `com.daisydiskapp.DaisyDiskStandAlone`. | `M:144`; iTunes lookup API |
| Vendor | Software Ambience Corp. Founded by Taras Brizitsky (interaction design) and Oleg Krupnov (programming); first release late 2008. | https://en.wikipedia.org/wiki/DaisyDisk; `M:89` "© 2008 – 2026" |
| License | **Proprietary, closed source.** $9.99 one-time lifetime license, up to 5 personal Macs. "DaisyDisk®" is a registered trademark. | `P:9-14`; `FAQ:15`; site footer |
| What the license lets us do | **Study the public behaviour only.** No code to take. Don't copy its visual identity (the "daisy" petals, icon, wording) closely: the name is a registered trademark. The *pattern* (staging tray, sunburst drill-down) is not protected. OpenDisk (MIT) already reimplements it as "Collector". | — |
| Open code from the vendor | GitHub `AJet` (name "DaisyDisk", company Software Ambience Corp., 4 public repos). `AJet/DFeedback`: 109 stars, Objective-C, **MIT** per `MIT License.txt` and README:60 (the API reports `null`), pushed 2023-10-03. It is the feedback and crash-report window that ships inside DaisyDisk (`DFFeedbackWindow.nib`, `DFCrashReportWindow.nib` in `Resources/en.lproj`). The other 3 repos are forks: `AJet/Sparkle` (see Distribution), `AJet/LetsMove`, `AJet/hfsinspect`. | `gh api users/AJet/repos`, 2026-09-23; blog `B:sharing-code:6-20` |
| Stars | n/a (closed). The vendor's site shows App Store "4.7 out of 5, 3691 ratings, 2912 reviews". That figure is self-reported, and the US iTunes lookup returns `userRatingCount=0` for the Mac app. | `H:88-94`; `itunes.apple.com/lookup?id=411643860` |
| Last release | Stand-alone **4.34.2, 2026-07-10**. Mac App Store 4.34.1, 2026-07-05. Releases have come every 1-6 months since 2010. v4.0 shipped 2015-09-03. | `R:2-3`; `P:21-22`; `M` CFBundleShortVersionString; iTunes lookup |
| Language / stack | AppKit with nibs (`MainMenu`, `SourcePageView` = disk list, `ReportPageView` = map + sidebar, `PreferencesWindow`). The UI has been built on Core Animation since 2.0. The executable is a universal x86_64 + arm64 Mach-O of 6.0 MB, and the helper is 390 KB. There is no Metal library, no XPC service and no app extension in the bundle. Probably Objective-C: the deployment target is 10.13, yet no Swift runtime dylibs are embedded, which a Swift app targeting macOS earlier than 10.14.4 would need (an inference, **unverified**). The App Store download is 2.86 MB. | `M:14-20,145,168,220-221`; `R:381`; `G:ScreenSharing:6`; iTunes lookup `fileSizeBytes` |
| Min macOS | 10.13 | `M` LSMinimumSystemVersion; `P:20` |
| Distribution | The stand-alone app is Developer ID signed (team 4CBU3JHV97), notarized with a stapled ticket, hardened runtime, **no entitlements** (not sandboxed). It updates through Sparkle. A separate sandboxed Mac App Store edition has features removed. | `M:146-164`; `G:Editions:9-35` |
| Updater | A **private Sparkle fork at 1.15.0** (`AJet/Sparkle` master @aa179f95, 73 commits ahead of and 13 behind upstream 1.15.0, last push 2023-04-02; the commits are mostly localizations). It uses a **DSA** key (`SUPublicDSAKeyFile`, `M:98`) and the appcast signs every item with `sparkle:dsaSignature` only (5 of 5 items). `SUEnableSystemProfiling=YES` (`M:96`). | `M:212-216`; `gh api repos/sparkle-project/Sparkle/compare/1.15.0...AJet:Sparkle:master`; `appcast.xml` |
| Issue tracker | None public. Known problems come from the vendor's blog and release log (see Known problems). | — |

## Summary

DaisyDisk is the benchmark UX for "find what's big and remove it by hand". It lists every mounted volume with a live free-space gauge. It scans a disk or folder in seconds and shows the result as an interactive **sunburst**: folders are coloured petals, files are grey, and anything too thin to see is merged into one semi-transparent "smaller objects" petal. Hover a petal to list its contents in the sidebar, click to drill down, and click the centre to go up (`G:UnderstandingSunburst:6-8`). Deletion is staged: you drag petals (or press ⌘⌫, or use the context menu) into a **Collector** bar at the bottom. The bar shows a running "N GB collected" total and expands into a reviewable list (`G:DeletingFiles:6-11`). Delete starts a **5-second countdown** with Cancel, then removes the items **permanently**, never through the Trash, "so that the disk space is actually recovered" (`G:DeletingFiles:16-17`).

Beyond the map, it accounts for the space a plain scan cannot see:
- **Hidden space** is used space minus scanned space (`S:45`), broken down into purgeable space, other APFS volumes, snapshots and "still hidden".
- It counts **hard links** and, since 4.34 (July 2026, macOS 14+), **full APFS clones** only once.
- It lists and deletes local Time Machine **snapshots**, and it can force-purge purgeable space (stand-alone edition only).

What DaisyDisk deliberately does **not** do is macontrol's other half. It has no cleanup rules, no cache sweeps, no uninstaller and no duplicate finder. The vendor's pitch is against "cleaner apps" (`H:43-64`; `S:58`; `FAQ:46-47`). It also keeps no scan across launches and does not track changes made outside the app (`G:TipsAndTricks:26-27`; `R:383`).

For macontrol, DaisyDisk is the **interaction spec** to meet or beat. That covers the hover-to-preview drill-down, the Collector, the named refusal of protected folders, the hidden-space breakdown, the keyboard map and Quick Look everywhere. Its weak spots, which macontrol must do better:
- permanent deletion with no undo (the class of F-0012),
- snapshot purging through the same Collector as files (F-0056),
- a root helper that outlives the app (F-0055),
- a 2016-era updater with DSA signing,
- no persistence and no live updates.

## Architecture

What is observable from the bundle and the docs. Nothing more is knowable without the code.

- **Two editions, one product.** The stand-alone app `com.daisydiskapp.DaisyDiskStandAlone` has everything. The App Store app `com.daisydiskapp.DaisyDisk` is sandboxed. It can only *detect* hidden and purgeable space, cannot scan as administrator, and cannot delete "stuck" files (`G:Editions:6-35`; the 2013 rationale is in `B:daisydisk-3-and-app-sandboxing:6-9`). This confirms the macontrol decision to ship outside the Mac App Store (topic-distribution-permissions.md:10, D2).
- **Main app.** AppKit, with nibs per page: `SourcePageView.nib` is the disk and folder list and `ReportPageView.nib` is the map and sidebar (`Resources/en.lproj`). Rendering is Core Animation (`R:381`), and the app goes black on headless Screen Sharing for that reason (`G:ScreenSharing:5-7`). Sidebar, Collector and map share one selection and preview model: "Preview works on the disk map, sidebar and Collector items" (`G:Previewing:10`).
- **Privileged helper** `com.daisydiskapp.DaisyDiskStandAlone.AdminHelper`, installed with **SMJobBless**:
  - `SMPrivilegedExecutables` in Info.plist (`M:93-95`).
  - The tool sits at `Contents/Library/LaunchServices/<label>` (`M:17`).
  - The embedded `SMAuthorizedClients` pins the app's Developer ID requirement (`M:184-186`).
  - The embedded launchd plist has `MachServices` and `AssociatedBundleIdentifiers = com.daisydiskapp.DaisyDiskStandAlone` (`M:205-211`).
  - It is installed on the first "Scan as Administrator" (`G:EnableAdmin:7`), and the documented install paths are `/Library/PrivilegedHelperTools/…` and `/Library/LaunchDaemons/…` (`G:EnableAdmin:24-25`).
  - Its duties per the docs: admin scans ("Quick Rescan as Administrator" rescans only what was restricted, `G:AdminScan:11`), deletion with raised permissions (`G:Restricted:11`), deleting stuck files, purging and snapshot deletion (`G:Editions:19-26`; `G:Snapshots:26`). Which duty runs in which process is **unverified**.
  - SMJobBless has been deprecated since macOS 13 (SDK `ServiceManagement.h:253,260`).
- **Cloud connectors** (Dropbox, Google Drive, OneDrive, Box) scan over each provider's API with OAuth, with no local cache (`G:CloudScan:5-29`; `Resources/en.lproj/CSGoogleDrive.strings`). Google's yearly security assessment for Drive access is a recurring cost the vendor had to pay (`blog index:48-51`, 2024-10-09).
- **Third-party parts:** the Sparkle fork, DFeedback (their own, MIT), and LetsMove (a fork of a well-known move-to-Applications helper, matching "move itself to Application folder" in `R:361`). Nothing else is embedded.
- **Engine and UI separation:** not observable. Scan results live in memory per scanned root and can be dropped with "Forget Scan Results" (`G:TipsAndTricks:27`). Several scans run at once (`G:ParallelScan:5`).

## Scanning

| Topic | What DaisyDisk does | Source |
|---|---|---|
| Size metric | "The application calculates the physical file size, not logical one (except for network drives)." HFS+-compressed files count at their physical size ("Finder wrongly counts…"). | `G:TipsAndTricks:23`; `G:FinderMismatch:11-13`; `H:67` |
| Hard links | Counted once. The first occurrence is "primary" and the others get "a virtual size of 0 bytes". Sidebar bullets mark each role: a white rectangle for primary, a dark circle for secondary. Deleting a link in-app updates its siblings. | `G:HardLinks:11-15` |
| APFS clones | Since 4.34 (2026-07-01), a **full** clone counts once (first occurrence, the rest are 0 B). **Partial clones are not accounted for** ("macOS does not currently provide any reliable tools"). Clone detection "is only supported by macOS 14 Sonoma and later". 4.34 broke scanning on earlier macOS and was hot-fixed in 4.34.1. | `G:HardLinks:18-20`; `R:7-11`; `blog index:6` |
| "First occurrence" caveat | Under this policy a folder's size depends on traversal order, and the Collector's "N GB collected" for a clone's primary copy frees nothing while the other copy survives. This is the class of F-0004. It is inferred from the docs and **unverified at runtime**. | derived from `G:HardLinks:11,18` |
| Dataless files | Handled since 4.31 (2025-01-10): iCloud-evicted files do not count as local usage. | `R:46`; `blog index:40-41` |
| Firmlinks and system volumes | Since 4.9 the scan adds "Non-firmlinked items of the Data volume in /System/Volumes/Data", `/private/var/VM`, and Recovery and Preboot when mounted. So it follows `/` via firmlinks and adds only the Data-volume remainder, without double counting (compare F-0031). | `R:141-144`; `B:important-update-daisydisk-4-10-adds-support-of-apfs-snapshots:10` |
| Hidden space | "The unaccounted difference between the total used disk space and the total of all files that have been available for scanning." It is shown as a virtual item with children: **purgeable space** (the system's figure), **other volumes** (APFS siblings in the container), **snapshots** (listed "for reference", not added to the total, because purgeable already includes them) and **still hidden**. The numbers refresh without a rescan when the system updates purgeable. | `S:45`; `G:HiddenSpace:6-23`; `G:Snapshots:13,18` |
| Speed | "Up to 20x" faster in v4 (2015). Vendor beta benchmarks: a 250 GB MacBook Pro SSD took 6-7 s, down from 120 s. Specs page: an APFS SSD startup disk takes 12-20 s and HFS+ SSD 6-12 s. APFS "takes somewhat longer and consumes more CPU power" than HFS+. The OpenDisk README claims 37 s for DaisyDisk against 17 s for OpenDisk on a 1 TB cold scan. All of these numbers are **the vendors', unverified**. | `R:259`; `B:daisydisk-4-0b4-beta-update-stunning-speed-boost:6-11`; `S:37-43`; `G:APFS:22`; OpenDisk `README.md:39-60` |
| Syscalls | Not published. The specs say only "low-level disk access, parallelization and optimization" (`S:35`). Whether it uses `getattrlistbulk` or `searchfs` is **unknown**. | `S:35` |
| Concurrency | Several disks or folders scan at once. For rotational HDDs, requests "are queued when necessary" per physical device, and SSDs always run in parallel. | `G:ParallelScan:5-9` |
| Timeouts | A single file that takes more than one minute raises "File system not responding" during scan or delete. The guide treats it as a file-system fault and points to Disk Utility. | `G:TimeoutError:5-10` |
| Sonoma privacy slowdown | Scans stalled in `~/Library/Containers` and `~/Library/Group Containers` because of Sonoma's per-access privacy checks. Apple acknowledged the bug. The workaround is **⌥-click Scan**, which skips both folders and moves their size into hidden space. | `B:daisydisk-4-26-1-released:6-14` |
| Memory | "Scanned snapshots may take hundreds of megabytes of your RAM." The user frees them with **Forget Scan Results**. Marketing claims "the lowest possible memory footprint" (unverified). | `G:TipsAndTricks:27`; `G:ReasonsToBuy:44` |
| Persistence and freshness | Results are "remembered while the application is running" and never saved. External changes are not tracked: deleted or moved items show **struck out**, and the fix is a rescan (⌘R for the folder, ⇧⌘R for the whole disk). Only in-app deletes update the map. | `R:383`; `G:TipsAndTricks:26`; `G:UnderstandingSunburst:11`; `G:Hotkeys:48-52` |
| Restricted items | Folders it cannot read show as 0 B, coloured **purple**, and their size lands in hidden space. Two fixes: FDA plus a relaunch, or "Scan as Administrator". | `G:Restricted:6-8`; `G:UnderstandingSunburst:12`; `G:HiddenSpace:19-20` |
| Packages | Bundles are solid, as in Finder, with a "Show Package Content" command. Since 4.25 an app bundle dropped on the window scans as a folder. | `G:TipsAndTricks:24`; `R:63` |
| Disk images, network | Disk-image capacity and used figures come straight from macOS and can be misleading (sparse images). Network shares show used size only. | `G:DiskImages:5-14` |

## Deletion & rules

- **Collector (staging).** Items get in by drag-and-drop, the context menu "Move … to Collector", or ⌘⌫ on the pointed item. "The files remain intact until you click the Delete button." The Collector expands into a list that "works just like the sidebar": Quick Look, drag an item out, or × per item (`G:DeletingFiles:6-11`; `G:Previewing:10`). A ring gauge shows the running total, with a red Delete button next to it (screenshots `dd_c_full.png`, `intro-ss1.png`).
- **Protection rules** are a curated, closed list inside the app. They are not user-editable and not documented as data.
  - Documented examples: `/System`, `/Library` and "current user's home folder" are refused at drop time with a named reason ("'System' is required by OS X and should not be removed", `dd_c_system.png`) (`G:DeletingFiles:13-14`; `G:WhatToDelete:6-7`).
  - The list has been revised several times: "Updated list of locations that cannot be deleted" (2.0.7, `R:342`), "Updated list of system files that should not be deleted" (3.0, `R:291`), and "Updated the safety rules to allow deletion of some non-critical files in /private folder" (4.9, `R:145`).
  - Whether `~/Library`, `~/Documents` or a firmlink alias of home is blocked is **not documented and unverified**. OpenDisk mirrors the idea with an exact-path set that includes `~/Library` (`OpenDisk/Services/ProtectedPaths.swift:1-30`), and F-0039 shows how that style is bypassed.
- **Other hard stops.**
  - Consolidated "smaller objects" petals cannot be collected. The user has to expand them first (`G:DeletingFiles:15`).
  - Nothing can be deleted from a Time Machine volume (`G:TimeMachine:19`).
  - The docs defer to each app's own UI for iTunes/Photos libraries and Steam games (`G:LocatingSpaceWasters:12,18`; `G:WhatToDelete:10`).
  - For apps and their leftovers, the guide points to a separate tool, AppDelete (`G:LocatingSpaceWasters:23`).
- **Delete semantics.** A 5-second countdown with Cancel, then permanent removal: "DaisyDisk doesn't move the files to the system Trash, because in that case, no disk space would actually be recovered" (`G:DeletingFiles:16-17`; `G:Undelete:6`). Recovery advice consists of third-party tools and turning the Mac off (`G:Undelete:7-8`). This is the class of **F-0012**. The counter-argument ("Trash frees nothing") is what F-0042's "Empty these from Trash" answers.
- **Privilege escalation.** "DaisyDisk automatically attempts to raise its deletion permissions, when possible" (`G:Restricted:11`). "Deleting 'stuck' files" is stand-alone only (`G:Editions:19-20`). The only privileged component in the bundle is the SMJobBless helper (see Architecture). The IPC shape, path checks and TOCTOU handling are **unknown**.
- **Purgeable space and snapshots.**
  - Dragging the "purgeable space" item, the "snapshots" item or any single snapshot into the Collector purges or deletes it "as you'd do with a regular file or folder" (`G:PurgeableSpace:20`; `G:Snapshots:25`).
  - A purge takes 2-10 minutes and 7-10 GB of purgeable space remain afterwards (`G:PurgeableSpace:23-25`).
  - The App Store edition can only copy a Terminal script (`G:Snapshots:26`).
  - Third-party snapshots (Carbon Copy Cloner) are listed but can only be deleted by the app that made them (`G:Snapshots:20-21`).
  - Right after a delete, the guide suggests purging when free space does not grow (`G:DeletingFiles:18-20`). That destroys the local restore points that `G:WhatToDelete:12` presents as the safety net. See **F-0056**.
- **Dry run.** The Collector *is* the preview: nothing happens before Delete, and the countdown gives 5 s to cancel. There is no export, log or journal of what was deleted (none documented).
- **Rules for junk and caches:** none, by design. "No automated cleaning is performed" (`S:58`); the comparison against cleaner apps is at `H:47-64`.

## UI

- **Disk overview (home screen).** One row per volume: icon, name, capacity and kind ("1.1 TB encrypted startup disk"), a gauge bar, free space as the only number, and a **Scan** split button whose menu holds "Scan as Administrator" and "Quick Rescan as Administrator" (screenshot `dd_overview.png`; `G:DisksOverview:6-16`).
  - The gauge is green when at least half the disk is free and red when "a clear call to action".
  - Purgeable space counts as free, matching Finder; holding ⌥ shows it as used (`G:DisksOverview:8-9`).
  - Frequently scanned folders can be **starred** so they stay in the list (`G:DisksOverview:16`).
  - Figures update live without a scan (`G:TipsAndTricks:25`).
  - "Scan Folder…" and "Scan Cloud" sit at the bottom. Dragging a disk or folder onto the window or Dock icon scans it (`G:DisksOverview:14`).
- **Report page** (hero screenshot `intro-ss1.png`):
  - A path bar at the top (Disks and Folders › Macintosh HD › Users › oleg) with back and forward buttons.
  - The sunburst on the left, with the current folder's size in the centre disc.
  - The sidebar on the right lists the hovered folder's children: colour bullets match the petal hue, sizes are right-aligned, and a grey "smaller objects…" row comes last.
  - The Collector bar sits at the bottom.
  - Hue follows the top-level branch, and files are grey (`G:UnderstandingSunburst:6`).
- **Navigation.** Point (hover) to preview a folder in the sidebar, click to drill down, and click the centre to go up (`G:UnderstandingSunburst:8`). History has back and forward (⌘[ / ⌘]).
- **Keyboard map** (`G:Hotkeys:9-55`), added only in 4.25 in 2023 (`R:61`, "yes, finally!"):
  - ↑↓, PgUp/PgDn, Home/End: move the selection within the folder.
  - ⌘↑ or pinch-close: go to the parent folder.
  - Return or pinch-open: drill into a folder, or expand "smaller objects".
  - Space: Quick Look.
  - ⌘⌫: move the item to or from the Collector.
  - ⌘-click: reveal in Finder.
  - ⌘R and ⇧⌘R: rescan the folder or the whole disk.
  - ⌥: switch the gauge mode.
- **Sidebar virtual rows.**
  - "smaller objects": click to list them all, possibly thousands. Since 4.25, "Always expand" is remembered per folder (`R:62`).
  - Struck-out rows for items that changed outside the app.
  - Purple rows for restricted items.
  - "hidden space…" (purple), which expands into purgeable / other volumes / still hidden.
  - Two footer rows: "free space" and "~ free + purgeable" (`G:UnderstandingSunburst:9-13`; screenshots `dd_hidden2.png`, `dd_purgeable.png`).
  - Hard-link role bullets (`G:HardLinks:13`).
- **Quick Look everywhere**: map, sidebar and Collector (`G:Previewing:7-10`). Also "Open in Terminal" (4.10, `R:137`).
- **FDA onboarding** is a Preferences tab, not a first-run step (`G:FullDiskAccess:11-14`; screenshot `dd_fda.png`).
  - It shows the current status.
  - Step 1 is "Open System Preferences" plus unlocking the lock icon. Step 2 is to drag the app icon, which bounces, into the FDA list. Then the user relaunches.
  - The copy explains the privacy model: DaisyDisk "only reads metadata … names and sizes" (`G:FullDiskAccess:9`; `FAQ:23-25`).
  - The screenshot still shows the pre-Ventura "System Preferences" wording and lock icon.
- **Progress:** a scan-progress indicator appears on the Dock icon (`R:386`). A "Stop" button is visible during a purge (`dd_c_purging.png`). Mid-scan cancel UI is not documented.
- **Visual quality:** a dark UI and a flat v4 design (2015). Many guide screenshots are still from the OS X era (for example "required by OS X" in `dd_c_system.png`). 4.33 added dark and Liquid Glass icons for Tahoe (`R:35`), and there is no public statement about Liquid Glass inside the app.
- **Not present** (none documented anywhere in the guide): search or filter, a list or treemap view, sorting other than by size, breakdowns by file type or age, a duplicate finder (`FAQ:46-47`), scan persistence, live FSEvents updates, undo.

## Tests & quality

No public code, tests or issue tracker, so quality can only be read from the outside:
- **Longevity.** Releases from 2010 to 2026 (`R`), and v4 has been maintained since 2015. The vendor reports App Store Editors' Choice and three "Best of the Year" awards (`H:13-15`, vendor claim).
- **Regressions visible in the release log:**
  - FAT32/exFAT size estimation was wrong until 4.33 (`R:37`).
  - Clone detection broke scanning before Sonoma: 4.34 on 2026-07-01, fixed by 4.34.1 on 2026-07-04 (`R:7`).
  - Repeated hidden-space fixes: display in 4.4, discovery in 4.9, 4.11 and 4.25, accuracy in 4.33 (`R:36,60,131,141,209`).
  - Antivirus false positives (4.7.2.1, 4.21.2).
- **Stale documentation:**
  - The helper reinstall step names `/Library/LaunchDaemons/com.daisydiskapp.DaisyDiskStandAlone.AdminHelper` without `.plist` (`G:EnableAdmin:24`).
  - Info.plist declares `CFBundleHelpBookFolder = DaisyDisk.help`, but the 4.34.2 bundle contains no `.help` folder (`find` over the bundle, verified).
  - Screenshots still show OS X-era text.
- **Dependency hygiene.** The Sparkle fork froze at 1.15.0 (December 2016). Upstream is now at 2.10 with EdDSA. Sparkle's own advisories GHSA-3x7w-j75x-ppq5 and GHSA-gmj2-gq3j-vqmj list affected ranges `<= 2.9.5` and `<= 2.9.4`. Whether the 1.x code paths share those defects is **unverified**. Updates are signed with DSA only (`appcast.xml`), and delivery is over HTTPS.

## Known problems

1. **No undo after Delete.** Deletion is permanent after a 5-second countdown (`G:DeletingFiles:16-17`; `G:Undelete:6-8`). This is the class of F-0012.
2. **Snapshot and purgeable purging runs through the same Collector as files.** The guide suggests it right after a delete, which removes the local restore points it elsewhere calls the safety net (`G:DeletingFiles:18-20`; `G:WhatToDelete:12`; `G:Snapshots:25`). This is **F-0056**.
3. **The root helper outlives the app.**
   - It is an SMJobBless helper with no in-app removal. The guide's manual removal path is wrong (missing `.plist`).
   - The Homebrew cask uninstalls `com.daisydiskapp.DaisyDiskAdminHelper`, but the bundle installs `com.daisydiskapp.DaisyDiskStandAlone.AdminHelper` (`homebrew-cask@4691afd4c4 Casks/d/daisydisk.rb:20-21` against `M:94,209`).
   - This is **F-0055**.
4. **Stale maps.** There are no live updates and nothing persists between launches. Struck-out rows mean "rescan" (`G:TipsAndTricks:26`; `G:UnderstandingSunburst:11`; Wikipedia's "doesn't keep displayed information up to date"). This is a feature gap, not a defect. macontrol's FSEvents plan (Radix and OpenDisk dives) covers it.
5. **Clone accounting only on macOS 14+, and partial clones never.** The "first occurrence" rule makes folder sizes depend on order (`G:HardLinks:18-20`).
6. **The Sonoma Containers stall** needs a hidden ⌥-click workaround that silently grows hidden space (`B:daisydisk-4-26-1-released:13-14`).
7. **Tahoe App Store edition** forgot its sandbox "Unlock" grant on every launch (Apple r.157722315), fixed in 4.33 (`blog index:27-32`).
8. **Headless or background Screen Sharing** leaves the Core Animation UI black or frozen (`G:ScreenSharing:5-7`).
9. **Outdated updater:** a Sparkle 1.15.0 fork with DSA-only signatures (see Tests & quality).

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Collector staging tray (drag, ⌘⌫ and context menu in; expandable list; per-item ×; Quick Look inside; running total) | **study** (build ourselves; OpenDisk's MIT code is the starting point) | `G:DeletingFiles:6-11`; OpenDisk `OpenDisk/Models/Collector.swift`, `Views/Components/CollectorBar.swift` | This is the benchmark interaction. Keep it, and make it survive relaunch (T-0026). |
| Drop-time refusal of protected items with a named reason | **study** (rewrite the guard) | `G:DeletingFiles:13-14`; OpenDisk `Services/ProtectedPaths.swift:1-30` | Saying "no" before the drop is good UX. The guard itself must be identity-based, not path-string based (F-0024, F-0039). |
| 5 s countdown, then permanent delete | **rewrite** | `G:DeletingFiles:16-17` | Keep the cancel window, but deletes go to the Trash or quarantine with a journal and undo, plus "Empty these from Trash" for real space (F-0012, F-0042). |
| Hidden-space breakdown (used − scanned → purgeable / other volumes / snapshots / still hidden) and free vs free+purgeable rows | **study** (implement) | `S:45`; `G:HiddenSpace:6-23`; `dd_hidden2.png`, `dd_purgeable.png` | This is the best-known answer to "what is System Data". Pair it with F-0005's Data-volume coverage. |
| Gauge counts purgeable as free, ⌥ toggles | **study** (take the idea) | `G:DisksOverview:8-9` | Matches Finder, with one keypress to see the truth. |
| Snapshot list and delete, purge purgeable | **rewrite** | `G:Snapshots:13-26`; `G:PurgeableSpace:17-25` | Keep it as a separate, explained action with `tmutil thinlocalsnapshots` by amount. Never stage it next to files (F-0056). |
| Hard links and full clones counted once; sidebar role bullets | **improve** | `G:HardLinks:11-20` | Keep "count once" for totals, and add clone-aware *reclaimable* sizes (F-0004) so the Collector total is what Delete actually frees. |
| Sunburst interaction (hover to preview in the sidebar, click to drill, centre click for up, grey files, small-item merge, hue per top branch) | **study** (implement natively) | `G:UnderstandingSunburst:6-13`; `intro-ss1.png` | This is the core model. The small-item merge must stay expandable and listable (F-0016, F-0040). |
| Keyboard and gesture map | **take** (as a spec) | `G:Hotkeys:9-55` | It is complete and conventional. Ship it in v1; DaisyDisk took until 2023. |
| Quick Look on map, sidebar and Collector | **take** (native `QLPreviewPanel`) | `G:Previewing:7-10` | Native, cheap, expected. |
| FDA Preferences tab with drag-the-icon step | **study** | `G:FullDiskAccess:11-14`; `dd_fda.png` | Drag-to-list is a nice touch. macontrol needs the tri-state probe and onboarding from T-0007/T-0011 (F-0001), not a Preferences-only flow. |
| Per-device scan queue (HDD serial, SSD parallel); 1-minute per-file timeout message | **study** | `G:ParallelScan:5-9`; `G:TimeoutError:5-10` | Cheap wins for external and network disks. |
| Sonoma Containers stall and ⌥-click skip | **study** | `B:daisydisk-4-26-1-released:6-14` | Benchmark it on macOS 26 (T-0004/T-0010). If it still reproduces, show the skipped size explicitly rather than folding it into hidden space. |
| SMJobBless admin helper | **ignore** (use SMAppService) | `M:93-95,184-186,205-211` | Deprecated since macOS 13, and it outlives the app (F-0055). |
| Sparkle 1.15 fork with DSA | **ignore** | `M:96-98,212-216`; `appcast.xml` | Use Sparkle 2.10 with EdDSA (topic-distribution-permissions.md:11). |
| Cloud scanning (Dropbox, Drive, OneDrive, Box) | **ignore** (for M1) | `G:CloudScan` | Out of scope. Google Drive access also needs a paid yearly security audit (`blog index:48-51`). |
| DFeedback (MIT) | **ignore** | `AJet/DFeedback` | A 2011 Objective-C feedback window. We don't need it. |
| Two editions (MAS and stand-alone) | **study** | `G:Editions` | Confirms the choice to ship outside the Mac App Store. |

## Open questions

1. Scan engine API (`getattrlistbulk`, `searchfs`, or something else) and memory per node. These are not public. Only a black-box benchmark (T-0004), timed under `fs_usage`, could tell. That means installing and running the app, which is a user decision: trial email, TCC prompts.
2. Does the Collector survive a relaunch? Does the purge flow show any extra warning beyond the Collector? (Docs say "as you'd do with a regular file"; runtime **unverified**.)
3. The full protected-path list. Are `~/Library`, `~/Documents` and a firmlinked `/System/Volumes/Data/Users/<me>` refused?
4. How is purgeable space purged: by filling the disk, through CacheDelete, or with `tmutil thinlocalsnapshots`? The docs give only a duration (2-10 min) and a leftover (7-10 GB).
5. How are struck-out rows detected: a lazy `stat` while drawing, or a periodic check?
6. Does the Collector total for a clone primary count as "collected" bytes? (Inferred yes from the docs, which would make it the class of F-0004.)
7. Does the helper get removed on a DaisyDisk update or reinstall? SMJobBless only replaces it when the version changes. Nothing documents removal.
