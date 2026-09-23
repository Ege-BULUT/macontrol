# Feasibility: Apple app debloat and sealed system apps

Task T-0070 (M7, tag debloat), by feas-apple-apps, 2026-09-23. Answers user decisions 4 and 6 in journal M-0045.
Related: T-0068 (privileged deletion, `docs/research/feasibility-privileged.md`) and T-0069 (permanent delete and
restore points, `docs/research/feasibility-permanent.md`). Builds on `research/reports/topic-platform-constraints.md`
(T-0010, facts A1-A10, B1-B3, C6-C8), which this document does not repeat.

**Test machine:** MacBookPro17,1 (M1), macOS 26.6 (25G72), SIP enabled, Authenticated Root enabled, FileVault off,
4.6 GiB free of 228 GiB. Every probe here was read-only (`du`, `stat`, `ls -lO`, `codesign`, `pkgutil`, `ioreg`,
`launchctl print`, `xcrun simctl runtime list`, man pages) plus three small programs compiled in the scratchpad.
Nothing outside the scratchpad was written, moved or deleted, and nothing ran as root.

**Status labels:** **verified-locally** = reproduced on this Mac in this run. **sourced** = from a cited document.
Where the URL comes from the T-0010 report it was fetched on 2026-09-23; URLs marked *(not re-fetched)* come from
prior knowledge, because this run made no network requests (the machine's global rule requires the user's approval
for any remote access, and a subagent cannot ask). Check those before quoting them in UI copy. **inferred** =
follows from verified facts but was not observed. **unverified** = not checked.

## Answer in five lines

1. **Apple's own apps in `/Applications` (GarageBand, iMovie, Pages, Numbers, Keynote, Xcode, Logic, Final Cut...)
   can be removed completely, with their content libraries, once T-0068 gives us a privileged path.** SIP does not
   protect them. They are root-owned, so a normal admin user cannot even move them to the Trash (F4 below). A few
   Xcode leftovers sit in SIP-restricted places and can only be removed through Apple's own tool (`simctl`) or not at all.
2. **Apps in `/System/Applications` (Chess, Stocks, News, Tips...) cannot be removed by any app, helper or root
   process while SIP and Authenticated Root are on.** No API exists. The only route is for the user to boot into
   recoveryOS, turn off FileVault, SIP and Authenticated Root, then mount the live system volume, delete, and
   `bless --create-snapshot`. macontrol can detect the state reliably and can guide the user, but it cannot do the
   Recovery part.
3. **Removing sealed apps saves almost nothing.** All 65 bundles in `/System/Applications` add up to 0.73 GB.
   Chess + Stocks + News + Tips are 21.5 MB. Their daemons stay, the old sealed snapshot probably keeps the bytes
   anyway, and the next macOS update puts the apps back. One removable Apple app on this Mac, Xcode, occupies
   **26.3 GB**, 36 times the whole `/System/Applications`.
4. **Recommendation:** make "debloat" mean Apple's removable apps plus their content (curated per-app profiles,
   shared-content rules, receipts, `simctl` runtimes). For sealed apps, show them honestly, offer the alternatives
   that work with SIP on, and put an expert-only guided procedure (generated commands the user runs) behind
   hardcore mode. Do not automate `mount`/`bless` in M7.
5. **The Windows comparison has a limit.** Windows lets an administrator remove Microsoft's built-in apps with a
   supported command (`Remove-AppxPackage`, https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage,
   *not re-fetched*). macOS has no such command for `/System/Applications`. What Apple lets you remove are the App
   Store apps it preinstalls (iWork, iMovie, GarageBand), and those are exactly the part macontrol can deliver.

## Facts

### Detection (how macontrol knows what it may do)

| # | Fact | Evidence | Status |
|---|---|---|---|
| D1 | `csr_get_active_config(uint32_t*)` and `csr_check(uint32_t mask)` are exported by `libsystem_kernel` and listed in the SDK's `usr/lib/system/libsystem_kernel.tbd:148`, so they link without tricks. The SDK has **no header** for them (`MacOSX26.5.sdk/usr/include/sys/csr.h` does not exist). They are SPI (undocumented, but stable since 10.11). | `nm -gU /usr/lib/system/libsystem_kernel.dylib`, `grep -n csr …/libsystem_kernel.tbd` | verified-locally |
| D2 | On this Mac `csr_get_active_config` returns 0 with config `0x0`, and `csr_check(1<<n)` returns -1 (denied = protection on) for all 13 bits, including bit 1 `CSR_ALLOW_UNRESTRICTED_FS` (SIP filesystem) and bit 11 `CSR_ALLOW_UNAUTHENTICATED_ROOT` (Authenticated Root). It works from Swift 6 with `@_silgen_name("csr_check") func csr_check(_: UInt32) -> Int32`. Bit names are from XNU `bsd/sys/csr.h` (https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/csr.h, *not re-fetched*). | `scratchpad/feas-apple-apps/probe/csrprobe.c`, `csr.swift` | verified-locally (on the SIP-on state only; the values with SIP off are unverified) |
| D3 | Whether the booted root is sealed can be read without root: `statfs("/")` gives `/dev/disk3s3s1` with `MNT_RDONLY`, `MNT_ROOTFS` and `MNT_SNAPSHOT` set (`f_flags 0x4480d001`), and IOKit `IOBSDNameMatching("disk3s3s1")` → property `"Sealed" = "Yes"`. | `probe/sealed.swift`, `ioreg -r -c AppleAPFSSnapshot -l` | verified-locally |
| D4 | `csrutil status` and `csrutil authenticated-root status` also work without root, but parsing their English output is fragile, and macontrol's sink audit allows `Process` only in `Uninstaller/Launchd*.swift`. D2 + D3 need no subprocess. `fdesetup status` works without root ("FileVault is Off."). | commands above | verified-locally |
| D5 | Recommended rule: *sealed apps are removable only if* `csr_check(1<<1) == 0` **and** `csr_check(1<<11) == 0`. Anything else, including a failed call, means "locked by macOS". | from D1-D3 | inferred |

### Apple apps in `/Applications` (the removable part)

| # | Fact | Evidence | Status |
|---|---|---|---|
| F1 | Only Xcode 26.6 is installed here. GarageBand, iMovie, Pages, Numbers, Keynote are not, and none of their content folders exist (`/Library/Application Support/GarageBand`, `/Library/Audio/Apple Loops`, `/Library/Audio/Apple Loops Index`, `/Library/Application Support/Logic`, `/Library/Audio/Impulse Responses`, `~/Music/GarageBand`, the `com.apple.garageband10`, `com.apple.iMovieApp` and `com.apple.iWork.*` containers). So **no size for them is measured in this document.** | `ls -lO /Applications`, existence checks | verified-locally |
| F2 | `Xcode.app` is `root:wheel 0755`, has no `restricted` flag, has `Contents/_MASReceipt` and the xattr `com.apple.appstore.metadata`, is signed `Apple Mac OS Application Signing`, and has TeamIdentifier `59GAB85EFG`. Its designated requirement pins `certificate leaf[subject.OU] = "59GAB85EFG"`. Built-in apps (Chess) are signed `macOS Software Signing` with no team and the requirement `anchor apple`. | `codesign -dv`, `codesign -d -r-`, `ls -lOd`, `xattr -l` | verified-locally |
| F3 | **A Mac App Store install leaves a pkgutil receipt.** `com.apple.pkg.Xcode` is in `/private/var/db/receipts` (plist + a 39.6 MB BOM listing 156,993 files) with `InstallProcessName = appstoreagent`. `/var/db/receipts` has no `restricted` flag, so root can remove the receipt. This answers the munki report's open question for Xcode. Whether GarageBand, iMovie and iWork do the same is unverified. | `pkgutil --pkg-info`, `plutil -p …/com.apple.pkg.Xcode.plist`, `ls -lOd` | verified-locally (Xcode only) |
| F4 | **A non-root user cannot move a root-owned app bundle to the Trash**, even an admin whose group can write `/Applications` (`root:admin 0775`). Moving a folder to another parent needs write permission on the folder itself (to rewrite its `..` entry). A `0555` folder in the scratchpad: rename across parents → `EACCES`; rename in place → OK. So all Apple App Store apps (root:wheel 0755) need the privileged path of T-0068 for every step, including "Move to Trash". | `probe/` rename test in the scratchpad | verified-locally (proxy with a non-writable folder) |
| F5 | Xcode's first launch installs two more packages. `com.apple.pkg.XcodeSystemResources` puts 3,053 files in `/Library/Developer/{CoreDevice,CoreSimulator/Profiles,DeviceKit,PrivateFrameworks,DeveloperDiskImages}` (root, not restricted). `com.apple.pkg.MobileDeviceDevelopment` goes into `/Library/Apple/` (`RemoteVirtualInterface.kext`, LaunchDaemons, `usr/bin`), which is SIP-restricted, and its receipt sits in the restricted `/Library/Apple/System/Library/Receipts`. **Even root cannot remove that part.** | `pkgutil --pkg-info/--files`, `ls -lOd`, `rootless.conf` line 2 | verified-locally |
| F6 | Simulator runtimes are the biggest Xcode leftover, and they are **SIP-restricted**: `/System/Library/AssetsV2/com_apple_MobileAsset_{iOS,watchOS}SimulatorRuntime` (firmlinked onto the Data volume, `restricted`). `xcrun simctl runtime list -j` reports both as `"deletable": true`, `kind` "Patchable Cryptex Disk Image", 8,494,282,293 B + 3,935,033,546 B = **12.43 GB**. The supported removal is `xcrun simctl runtime delete <id> \| --notUsedSinceDays N [--dry-run] [--keep-asset]` (its own help text). Whether it asks for admin rights is unverified. | `ls -lOd`, `/usr/share/firmlinks`, `xcrun simctl runtime list -j`, `xcrun simctl runtime` | verified-locally (location, size, command). Admin prompt: unverified |
| F7 | Xcode's footprint on this Mac, excluding the Command Line Tools: **26.29 GB** (24.48 GiB). See the Xcode profile table below. | `du -xsk` per item | verified-locally |
| F8 | The Command Line Tools (`/Library/Developer/CommandLineTools`, 2.07 GB, 10 `com.apple.pkg.CLTools_*` receipts) are a separate product. git, clang and Homebrew use them without Xcode. They must not be removed as part of Xcode. | `pkgutil --pkgs`, `du`. The "used without Xcode" part is from prior knowledge | verified-locally (sizes, receipts); sourced (usage) |
| F9 | Apple-managed assets in `/System/Library/AssetsV2` total 15 GB here: the simulator runtimes (11.6 GiB) and Apple Intelligence/Siri models (`UAF_Siri_Understanding` 2.3 GB, `LinguisticData` 640 MB...). The whole folder is `restricted`, so only the owning feature can remove them. | `du -xsh /System/Library/AssetsV2/*`, `ls -lOd` | verified-locally (sizes, flag). How each feature frees them: unverified |
| F10 | v1's `LeftoverFinder.contentLibraries` knows only `com.apple.garageband10` → GarageBand, Logic, Apple Loops, and `com.apple.logic10` → Logic, Apple Loops. It misses `Audio/Apple Loops Index`, `Audio/Impulse Responses`, MainStage (which shares Logic content), and every Xcode item in the table below. | `Sources/Uninstaller/LeftoverFinder.swift:43-46,212-216` | verified-locally (code read) |
| F11 | The user's reference, PureMac (`bef6083`), skips every `/System` app and protects a list of Apple bundle ids that includes Xcode. It removes GarageBand, iMovie and iWork bundles through `do shell script "xargs -0 rm -rf …" with administrator privileges`, and has no content-library logic. So "like PureMac" is achievable, and macontrol can do better on content. | `PureMac/Logic/Scanning/AppInfoFetcher.swift:29-40,83-89`, `Services/CleaningEngine.swift:273` | verified-locally (code read) |
| F12 | Mole (`a7fa8dd`, GPL, study only) lists the Apple apps it allows removing: `com.apple.dt.*`, `FinalCut*`, `Motion`, `Compressor`, `logic*`, `garageband*`, `iMovie`, `iWork.*`, `MainStage*`, `server.*`, `Playgrounds`. Its `com.apple.iMovie` may not match iMovie 10, whose id is `com.apple.iMovieApp` (prior knowledge, unverified). A list keyed on bundle ids goes stale, so macontrol should classify by signature (F2) and use a list only for content profiles. | `lib/core/app_protection_data.sh:162-175` | sourced (code); iMovie id unverified |
| F13 | GarageBand keeps most of its size outside the bundle, in `/Library/Application Support/GarageBand`, `/Library/Audio/Apple Loops` and `/Library/Application Support/Logic`. | T-0010 A9: https://discussions.apple.com/thread/253946230, https://www.makeuseof.com/how-to-remove-garageband-sound-library-mac/ | sourced (third-party); paths unverified here |
| F14 | Since January 2026, Logic Pro and MainStage content ships as `.aar` Apple Archives, not packages, so it leaves no pkg receipt. Older GarageBand content packs (`MAContent10_*`) shared one package id across versions. | munki wiki `GarageBand.md`, via `research/reports/sources/munki-munki.md:87` | sourced (third-party); unverified here |

### Sealed system apps in `/System/Applications`

| # | Fact | Evidence | Status |
|---|---|---|---|
| S1 | 46 apps plus 19 in `Utilities` = 65 bundles, all `root:wheel` with the `restricted` flag. Total **709,744 KiB = 0.73 GB**. Largest: Music 70 MB, Freeform 60, Books 58, Maps 51, TV 50, Podcasts 41, Find My 31. Chess 10.8 MB, News 4.1, Tips 4.5, Stocks 2.2. New on 26: Apps, Journal, Phone, Games, Image Playground, iPhone Mirroring. **Launchpad.app no longer exists** (Apps.app replaces it). Full list: `scratchpad/feas-apple-apps/sysapps.tsv`. | `du -sk`, `ls -lOd` on every bundle | verified-locally |
| S2 | They live on the sealed system snapshot (`/dev/disk3s3s1`, `com.apple.os.update-8EC5…`, `sealed, read-only`). The System volume uses 12.6 GB, so the apps are about 6% of it. | `mount`, `diskutil info /`, `diskutil apfs list` | verified-locally |
| S3 | Safari is not in `/System/Applications`. `/Applications/Safari.app` → `/System/Cryptexes/App/…` → `/System/Volumes/Preboot/Cryptexes/App`, 36 MB, `restricted`. | `ls -lOd`, `du` | verified-locally |
| S4 | **The app bundle is only the front end.** The background work of these apps runs from elsewhere: `newsd` from `PrivateFrameworks/NewsDaemon.framework`, `weatherd` from `WeatherDaemon.framework`, `tipsd` and `gamed` from `/usr/libexec`, all started by `/System/Library/LaunchAgents/*.plist`. Deleting News.app leaves `newsd` in place. The on-disk framework folders are small (3.9 MB for the News, Stocks, Tips and Weather frameworks); the code lives in the dyld shared cache in the OS cryptex. | `launchctl print gui/501/<label>`, `du -sk` | verified-locally (paths, sizes); dyld cache location: prior knowledge |
| S5 | `csrutil` on 26.6 still offers `authenticated-root disable`: "Allow booting from non-sealed system snapshots. Only available in Recovery OS." `disable`/`enable` of SIP are also Recovery-only. | `csrutil` usage text | verified-locally |
| S6 | `bless` documents the procedure's key options. `--create-snapshot`: "create an APFS root snapshot of the target APFS system volume and set it as root snapshot … will boot from this snapshot on its next boot". `--last-sealed-snapshot`: "Reverts back to using the previously signed APFS root snapshot reenabling Authenticated Root Volume". `--bootefi` copies the boot objects for either. | `man bless` (lines 144-160, 185-191) | verified-locally |
| S7 | Because `--last-sealed-snapshot` can go back to the previous sealed snapshot, that snapshot must still exist after `--create-snapshot`. So the deleted bundles keep their blocks, and **no space is freed** until the user also deletes the sealed snapshot, which removes the easy way back. | from S6 | inferred (unverified) |
| S8 | SSV cannot be turned off while FileVault is on. SIP applies to root too. | https://support.apple.com/guide/security/signed-system-volume-security-secd698747c9/web, https://support.apple.com/guide/security/system-integrity-protection-secb7ea06b49/web (T-0010 A2, B3) | sourced |
| S9 | Apple: "You can't remove apps that are required by your Mac … Mail, Music, Books, Notes, Podcasts, Maps, News, and Stocks." | https://support.apple.com/guide/mac-help/uninstall-apps-mh35835/mac (T-0010 A5) | sourced |
| S10 | `FileManager.trashItem` on `/System/Applications/Chess.app` fails (`NSCocoaErrorDomain 512`). | T-0010 A7, `research/bench/platform-probes/run.sh` | verified-locally (by T-0010) |
| S11 | A macOS update writes a new sealed system snapshot, so removed apps come back. With a modified system, updates may arrive as full installers instead of small deltas. | Prior knowledge (Apple Platform Security SSV chapter; Howard Oakley's eclecticlight.co articles), *not re-fetched* | sourced (not re-fetched) / unverified on 26 |
| S12 | On Apple silicon, turning SIP off lowers the boot policy to Permissive Security (Apple Platform Security, "Startup Disk security policy control", https://support.apple.com/guide/security/startup-disk-security-policy-control-sec7d92dc49f/web, *not re-fetched*). Third parties report that iPhone/iPad apps stop launching and Apple Pay stops working with SIP off. | *not re-fetched* | unverified |
| S13 | Time Machine does not back up the System volume, so a "restore point" for system apps can only be the previous sealed snapshot (S6) or Reinstall macOS from recoveryOS, which keeps user data. T-0069 covers Data-volume snapshots, which do not help here. | Prior knowledge, *not re-fetched* | unverified |
| S14 | Data that built-in apps keep in the home folder is small on this Mac: the largest Apple containers are `com.apple.geod` 31 MB, `com.apple.wallpaper.agent` 22 MB, Safari 9 MB, Maps 7 MB; the largest Apple group container is 18 MB. Other Macs may differ (Podcasts and TV downloads, Mail attachments). | `du -sk ~/Library/Containers/com.apple.*`, `~/Library/Group Containers/*com.apple*` | verified-locally |
| S15 | The user launchd domain already holds overrides for Apple services (`com.apple.Siri.agent => enabled`, `com.apple.FolderActionsDispatcher => disabled`). So `launchctl disable gui/<uid>/com.apple.newsd` is at least representable. Whether it works without root under SIP, and whether it survives updates, is unverified. | `launchctl print-disabled gui/501` | verified-locally (read); effect unverified |

## Xcode profile (verified on this Mac)

This is the model for every Apple app profile: each item has an owner, a SIP state, a removal route and a default.

| Item | Size | Owner / SIP | Route | Default |
|---|---:|---|---|---|
| `/Applications/Xcode.app` | 3.76 GB | root, not restricted | privileged delete (T-0068) | selected |
| Simulator runtimes (iOS 26.5, watchOS 26.5) in `/System/Library/AssetsV2/…SimulatorRuntime` | 12.43 GB | root, **restricted** | `xcrun simctl runtime delete <id>` only | selected |
| `/Library/Developer/CoreSimulator/Caches` | 6.05 GB | root, not restricted | privileged delete; regenerates | selected |
| `~/Library/Developer/CoreSimulator/Devices` | 3.32 GB | user | Trash | review (holds apps and data inside simulators) |
| `~/Library/Developer/Xcode/DerivedData` | 0.41 GB | user | Trash | selected (build output) |
| XcodeSystemResources payload: `/Library/Developer/{CoreDevice,DeviceKit,PrivateFrameworks,DeveloperDiskImages,CoreSimulator/Profiles}` | 0.23 GB | root, not restricted | privileged delete by receipt BOM, with munki's rule (skip paths other receipts list) | selected |
| Receipts `com.apple.pkg.Xcode`, `…XcodeSystemResources` in `/var/db/receipts` | 0.04 GB | root, not restricted | privileged delete of the `.bom` + `.plist` (same as `pkgutil --forget`) | selected |
| MobileDeviceDevelopment in `/Library/Apple/…` | small | root, **restricted** | none | shown as "kept by macOS" |
| `/Library/Developer/CommandLineTools` | 2.07 GB | root | separate product | not part of Xcode; own row, manual |
| **Total without CLT** | **26.29 GB** | | | |

## Catalog of other Apple apps (to verify on a Mac that has them)

Bundle ids and paths come from prior knowledge and from F12-F14. None is verified here (F1). Every row keeps the v1
rule: `~/Music`, `~/Movies`, `~/Documents` and iCloud Drive are never searched.

| App (bundle id) | System content (root) | User leftovers | Never touched (user content) | Shared with |
|---|---|---|---|---|
| GarageBand (`com.apple.garageband10`) | `/Library/Application Support/GarageBand`, `/Library/Audio/Apple Loops/Apple`, `/Library/Audio/Apple Loops Index`, `/Library/Application Support/Logic`, `/Library/Audio/Impulse Responses/Apple` | container, `~/Library/Application Scripts/com.apple.garageband10` | `~/Music/GarageBand` projects, `~/Library/Audio/Apple Loops` (user loops) | Logic Pro (`com.apple.logic10`), MainStage (`com.apple.mainstage3`): shared folders are kept, or shown unselected with "Also used by …", while either is installed |
| Logic Pro (`com.apple.logic10`) | same as GarageBand; `.aar` content since 2026 (F14) | container, prefs | `~/Music/Logic`, `~/Music/Audio Music Apps` | GarageBand, MainStage |
| iMovie (`com.apple.iMovieApp`) | none known outside the bundle | container, Application Scripts | `~/Movies/iMovie Library.imovielibrary`, `~/Movies/iMovie Theater.theater` | - |
| Pages, Numbers, Keynote (`com.apple.iWork.{Pages,Numbers,Keynote}`) | none known outside the bundles | containers, Application Scripts, extension containers | `~/Library/Mobile Documents/com~apple~{Pages,Numbers,Keynote}` (iCloud Drive) | Group containers may be shared between the three (unverified) |
| Final Cut Pro, Motion, Compressor (`com.apple.FinalCut`, `com.apple.motionapp`, `com.apple.Compressor`) | `/Library/Application Support/ProApps` (exists here, 0 B), Final Cut content (unverified) | containers | `~/Movies/*.fcpbundle` libraries | each other (ProApps) |
| `Install macOS *.app` | the bundle itself (~13-15 GB, unverified) | - | - | - |

## Recommendation

**1. Apple's removable apps: go. This carries the debloat promise.**
- Keep classifying by signature, not by bundle-id list: `appleAppStore` = `_MASReceipt` + Apple Mac App Store signing
  with team `59GAB85EFG` (F2). Add a second Apple class for Apple software installed by package (`Install macOS`,
  Safari Technology Preview, SF Symbols) that is signed with `anchor apple` but lives on the Data volume.
- Replace the hard-coded `contentLibraries` map with a signed, bundled `apple-apps.json` resource (same rules as
  `catalog.json`: compiled in, validated at load). One profile per app: system content, user leftovers,
  `neverTouch` user-content roots, `sharedWith` bundle ids, receipts, and "tool" items (`simctl runtime delete`).
  Ship the Xcode profile now (verified). Ship the others only after a verification pass on a Mac or VM where they
  are installed (GarageBand, iMovie and iWork are free on the App Store).
- Needs from T-0068's privileged path: delete root-owned bundles and folders in `/Applications`, `/Library/Application Support`,
  `/Library/Audio` and `/Library/Developer`; delete receipt files in `/var/db/receipts`; refuse `SF_RESTRICTED`
  items up front with the reason "kept by macOS" (the kernel refuses them anyway). With hardcore mode off, the
  helper must put items in **the user's** `~/.Trash`. If a root process calls `trashItem`, the item probably goes to
  root's Trash, where the user can neither see nor undo it (inferred, unverified).
- `simctl runtime delete` runs as the user with an argument array. That needs one more `Process` exception in the
  sink audit (`Uninstaller/SimRuntime*.swift`). Check `--dry-run` output first.

**2. Sealed system apps: be honest, offer alternatives, and do not automate the Recovery part.**
- Default view (SIP on, which is almost every Mac): list them as "Part of macOS, locked by macOS" with their real
  size. Show one sentence of truth: "macOS keeps these on a sealed, read-only system volume. No app can remove them
  while System Integrity Protection is on. Together they use 0.73 GB, and macOS updates reinstall them." Use D2 + D3
  to decide what to show.
- Alternatives that work with SIP on: **Remove from Dock** (user preference); **Clear this app's data**
  (containers, caches and downloads through the cleaner, review level); **Stop background activity** (`launchctl
  disable gui/<uid>/<label>` for the app's agents; only after S15 is verified, and reversible with `enable`).
  "Hide from Launchpad" is gone on 26 (S1) and was never a supported API on 14-15, so do not offer it.
- "Remove anyway (expert)": only visible in hardcore mode. It opens the red modal the user asked for ("Strongly
  not recommended. Back up your Mac first. This lowers your Mac's security, can break iPhone apps and Apple Pay, and
  the next macOS update brings the apps back.") and a step-by-step guide with commands generated for the chosen apps
  and this Mac's device node. The user runs them. When D5 says protections are off, the guide skips the Recovery
  steps. The guide is below.
- Do not let the helper run `mount`/`rm`/`bless` on the system volume in M7. Revisit only after the flow and its
  revert (`bless --last-sealed-snapshot`, then `csrutil authenticated-root enable` and `csrutil enable`) have been
  run end to end in a macOS VM on 14, 15 and 26. This Mac is not a test target: it has 4.6 GiB free, and a failed
  `bless` affects booting.

**Guide text (to verify in a VM before shipping; S5-S8 are its evidence):**
1. Back up with Time Machine (user data only, S13). Turn off FileVault and wait for decryption to finish (S8).
2. Apple silicon: shut down, hold the power button until "Loading startup options", choose Options. Intel: Command-R.
   In Utilities → Terminal: `csrutil disable`, then `csrutil authenticated-root disable`. Restart.
3. In macOS: find the system volume (`/dev/diskXsY` = the root device without its last `sN`, here `disk3s3`), then
   `mkdir ~/sysmount && sudo mount -o nobrowse -t apfs /dev/disk3s3 ~/sysmount`.
4. `sudo rm -rf ~/sysmount/System/Applications/Chess.app` (per chosen app).
5. `sudo bless --mount ~/sysmount --bootefi --create-snapshot`, restart.
6. To undo: `sudo bless --mount / --bootefi --last-sealed-snapshot` (unverified form), restart, then in recoveryOS
   `csrutil authenticated-root enable` and `csrutil enable`. If that fails: recoveryOS → Reinstall macOS.

## Risks

| Risk | Where | Mitigation |
|---|---|---|
| Shared content deleted while Logic Pro or MainStage still needs it | GarageBand profile | `sharedWith` check against installed bundle ids; shared folders never preselected (v1 already notes "Also used by …") |
| User projects deleted | `~/Music/GarageBand`, iMovie libraries, iCloud Drive app folders | `neverTouch` roots in each profile, on top of v1's never-search list |
| Root-trashed items land in root's Trash, invisible and not undoable | privileged path | helper renames into the invoking user's `~/.Trash` (same volume), or deletes permanently only in hardcore mode |
| The kernel refuses a restricted leftover mid-batch | `/Library/Apple`, `AssetsV2` | classify `SF_RESTRICTED` before the batch; show it as "kept by macOS" and never select it |
| A system-app removal leaves the Mac unbootable or insecure | expert guide | macontrol does not execute it; the guide includes the revert; hardcore gating and the modal |
| The user expects space back from system apps | UI copy | show real sizes (0.73 GB total, 0 until the sealed snapshot is gone) next to the removable Apple apps' sizes |
| The `csr_check` SPI changes | detection | a failed call or unknown value is treated as "locked"; `csrutil status` stays the manual cross-check |
| A bundle-id list goes stale (Mole's `com.apple.iMovie`) | catalog | classify by signature; lists only for content profiles, each verified on a real install |

## Open questions (each with the cheapest test)

1. **App Management / TCC for a root helper deleting a whole Apple app** (T-0010 C8). Test on a spare Mac or VM:
   install GarageBand, delete it through the T-0068 helper with and without Full Disk Access granted to the helper.
2. **Do GarageBand, iMovie and iWork MAS installs leave receipts like Xcode (F3)?** What are their exact leftovers and
   sizes on 14, 15 and 26, including the 2026 `.aar` content (F14)? Install them in a VM and diff the file system
   before and after.
3. **Does `xcrun simctl runtime delete` ask for admin rights?** Run `--dry-run` first, then delete one runtime on a
   machine where it can be lost.
4. **Space freed after removing a sealed app** (S7), and what 26 updates do with an unsealed system (S11). VM only.
5. **Which features break with SIP off on Apple silicon** (iPhone apps, Apple Pay, FairPlay video), on 26 (S12).
6. **Does `launchctl disable gui/<uid>/com.apple.<agent>` work without root under SIP, and does it survive
   updates** (S15)? Test on a disposable user account.
7. Side finding for T-0046: `lsregister -dump` holds **3,614 LaunchServices records** that point into deleted
   `macontrol-tests-*` temp folders, including fake `GarageBand.app` and Logic bundles from the uninstaller
   fixtures. The test suite pollutes the user's LaunchServices database. Something in the test path registers
   bundles; find it and unregister in teardown (`lsregister -u`) or avoid the registering API.

## Evidence files

- `scratchpad/feas-apple-apps/probe/csrprobe.c`, `csr.swift`, `sealed.swift`: SIP and seal probes (D1-D3).
- `scratchpad/feas-apple-apps/sysapps.tsv`: size, owner and flags of all 65 system app bundles (S1).
- `scratchpad/feas-apple-apps/pkgs.txt`: the 32 package receipts on this Mac.

(Scratchpad = `/private/tmp/claude-501/-Users-egeb-projects/45c9d2a4-ec2b-4761-8ad2-c890faaddc58/scratchpad`; it
is temporary. The probes are short enough to rewrite from the descriptions above.)
