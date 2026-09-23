# Topic: True disk usage on APFS

Task T-0009, researcher `topic-size-accounting`, 2026-09-23.
Test machine: macOS 26.6 (25G72), SDK MacOSX26, one APFS container `disk3` of 245.1 GB, allocation block 4096 B.
Reproducible experiment: `research/bench/size-accounting/run.sh [workdir]` (fixture + `du`/`stat` + `bulk.c` getattrlistbulk probe + `urlkeys.swift` URLResourceValues probe + `freecheck.py` free-space delta).

Status labels: **verified-locally** (measured on this Mac with the commands shown), **sourced** (cited document or code, not re-measured), **unverified** (could not check; treat as a hypothesis).

## Summary

1. **There are four sizes, not one.** For every file macontrol needs: *logical* (`st_size`, `ATTR_FILE_TOTALSIZE`), *allocated* (`st_blocks*512`, `ATTR_FILE_ALLOCSIZE`, `totalFileAllocatedSize`), *private* (bytes that deleting it frees now: `ATTR_CMNEXT_PRIVATESIZE`), and *identity* (`(dev, ino)` for hard links, `ATTR_CMNEXT_CLONEID` for full clones). Only allocated size is safe to sum for a disk map. Only private size is true for "delete this to free N".
2. **Every surveyed tool counts APFS clones at full size.** PureMac, Mole and dust sum allocated blocks. None reads a private size or a clone id. On this Mac, deleting a 64 MiB clone freed −0.04 MiB. Deleting the last copy freed +63.94 MiB. A "frees N GB" figure built on allocated size is overstated whenever clones exist (filed as a finding on the analysis board).
3. **`ATTR_CMNEXT_PRIVATESIZE` has two traps**, both verified here. It is **0 for decmpfs-compressed files**, whose allocated size is really 86 KB. It gives the **full size for each hard link**, because it is per inode, not per path. macontrol has to fall back to allocated size for `UF_COMPRESSED` files and apply a "last link" rule for hard links.
4. **Foundation has no key for private size or clone refcount.** `URLResourceValues` covers logical and allocated size, link count, `fileContentIdentifier` (equal to `ATTR_CMNEXT_CLONEID`, verified), `mayShareFileContent` and `isSparse`. The rest needs `getattrlistbulk` with `FSOPT_ATTR_CMN_EXTENDED`, which is also the fast path for scanning.
5. **Walking `/` both double-counts and under-counts.** Firmlinks make `/Users` and `/System/Volumes/Data/Users` the same directory (same `dev` and `ino`, verified), so a walk of `/` without a skip rule traverses the Data volume twice. At the same time, content at the Data volume root has no firmlink and is never reached from `/`. On this Mac that includes **`/System/Volumes/Data/macOS Install Data`, 12.1 GB** of update leftovers dated 2026-07-27, plus `.Spotlight-V100`, `.fseventsd` and `.DocumentRevisions-V100`. Recommendation: walk `/System/Volumes/Data` as one volume and map paths back through `/usr/share/firmlinks`.
6. **"Free space" is three numbers, and purgeable space is a promise, not a measurement.** On this Mac at one moment: `volumeAvailableCapacity` 43.15 GB (matches `df`), `…ForImportantUsage` 48.35 GB (+5.2 GB purgeable), and `…ForOpportunisticUsage` 30.8 GB (*less* than raw free). Later in the same session purgeable was 0.66 GB. The purgeable figure comes from CacheDelete (`deleted`), which has 27 providers in `/System/Library/CacheDelete` on 26.6 (sourced: eclecticlight).
7. **"System Data" in Storage settings is a remainder,** not a folder: used space minus every named category (sourced: Apple 102624, eclecticlight). macontrol can beat it by attributing the remainder explicitly. The pieces are: the other volumes in the container (Preboot 10.8 GB, Recovery 2.6 GB, VM 1.1 GB here), snapshots, `/private/var` (per-user `/var/folders` 2.3 GiB, `/private/var/db` ≥2.0 GiB readable), Data-root-only folders, and whatever the scan could not read.

## Experiment (verified-locally)

Fixture made by `run.sh`: an 8 MiB random file `orig.bin`, a full clone `clone.bin` (`cp -c`), a partial clone `pclone.bin` (`cp -c`, then 1 MiB overwritten), a hard-link pair `hl_src/hl_dst` (4 MiB), a sparse file `sparse.bin` (100 MiB with 1 byte at the end), a 1-byte file `tiny.txt`, an empty file `empty.txt`, and a compressible 10.4 MB text file stored plain (`comp_src.txt`) and decmpfs-compressed (`comp.txt` via `ditto --hfsCompression`).

| file | logical | allocated (stat/du/URL/ALLOCSIZE agree) | PRIVATESIZE | CLONEID / fileContentIdentifier | CLONE_REFCNT | EXT_FLAGS / URL flags |
|---|---|---|---|---|---|---|
| orig.bin | 8 388 608 | 8 388 608 | **0** | 5c94951 | 2 | 0x41 MAY_SHARE+SHARES_ALL, mayShare=true |
| clone.bin | 8 388 608 | 8 388 608 | **0** | 5c94951 (same) | 2 | 0x41, mayShare=true |
| pclone.bin | 8 388 608 | 8 388 608 | **1 048 576** | 5c94954 (new id) | 1 | 0x1 MAY_SHARE, mayShare=true |
| hl_src / hl_dst | 4 194 304 each | 4 194 304 each (same inode, nlink 2) | 4 194 304 **each** | 5c94955 | 1 | 0 |
| sparse.bin | 104 857 600 | **16 384** | 16 384 | — | 1 | 0x10 SPARSE, isSparse=true |
| tiny.txt | 1 | **4 096** | 4 096 | — | 1 | 0 |
| empty.txt | 0 | 0 | 0 | — | 0 | 0 |
| comp_src.txt | 10 400 000 | 10 403 840 | 10 403 840 | — | 1 | 0 |
| comp.txt | 10 400 000 | **86 016** (`UF_COMPRESSED`) | **0** | — | **0** | 0 |

Totals for the directory:

- `du -sk .` = 38 936 KiB. It counts hard links once and each clone in full.
- `du -skl .` = 43 032 KiB. It counts the hard link twice.
- True unique allocation = 23 576 KiB: 8192 shared + 1024 private (pclone) + 4096 (hard link) + 10 160 + 84 + 16 + 4.

**`du` overstates this directory by 65 %.**

Free-space delta on delete (64 MiB random file plus a clone and a hard link; `statvfs` after `sync`; two runs, plus a third run from `run.sh`):

- `rm clone.bin`: −0.04, −0.05, −6.61 MiB
- `rm orig_hl.bin` (one of two links): −0.07, −11.82, −0.39 MiB
- `rm orig.bin` (last reference): **+63.94, +64.04, +61.06 MiB**

Negative deltas are writes from other agents running in parallel on the same volume. The pattern is clear: deleting a clone, or a hard link that still has another link, frees nothing.

Directory URL: `totalFileAllocatedSize` and `fileSize` return **nil** for a directory. They do not recurse.

## Facts

| # | Fact | Evidence | Status |
|---|---|---|---|
| 1 | APFS allocates in 4096 B blocks. A 1-byte file costs 4096 B and an empty file 0 B. | `diskutil info /` "Allocation Block Size: 4096 Bytes"; tiny.txt/empty.txt above | verified-locally |
| 2 | `stat` `st_blocks*512` = `ATTR_FILE_ALLOCSIZE` = `URLResourceValues.totalFileAllocatedSize` = `fileAllocatedSize` for every fixture file (no resource forks involved). | experiment table | verified-locally |
| 3 | A full clone (`cp -c`) reports full allocated size in `stat`, `du`, `ls` and Foundation. `du` sums clones in full. | experiment; `du -sk` 38 936 vs 23 576 KiB unique | verified-locally |
| 4 | `ATTR_CMNEXT_PRIVATESIZE` = "bytes that are not trapped inside a clone or snapshot, and which would be freed immediately if the file were deleted". | `man getattrlist` (lines ~776-779); `sys/attr.h` `#define ATTR_CMNEXT_PRIVATESIZE 0x00000008` | sourced |
| 5 | PRIVATESIZE is 0 for both members of a full clone pair and 1 MiB for a partial clone with 1 MiB rewritten. | experiment | verified-locally |
| 6 | Deleting a full clone frees ~0. Deleting the last copy frees the full size. | `freecheck.py` deltas | verified-locally |
| 7 | PRIVATESIZE is **0 for a decmpfs-compressed file** (`UF_COMPRESSED`) with 86 016 B allocated. CLONE_REFCNT is also 0. | experiment (comp.txt) | verified-locally. Cause (data stored in the resource fork / xattr, not a data stream) is unverified. |
| 8 | PRIVATESIZE reports the full size on **each** hard link to one inode. Deleting one of two links frees ~0. | experiment (hl_*), `freecheck.py` | verified-locally |
| 9 | `ATTR_CMNEXT_CLONEID` groups only *full* clones. After a partial rewrite the clone gets a new id while still sharing 7 MiB. `ATTR_CMNEXT_CLONE_REFCNT` counts full clones including the file itself (2 for a pair). | experiment; man page "number of full clones" | verified-locally |
| 10 | `URLResourceValues.fileContentIdentifier` equals `ATTR_CMNEXT_CLONEID`, and `mayShareFileContent` equals `EF_MAY_SHARE_BLOCKS`. Foundation has **no** key for private size or clone refcount. | experiment (both print 5c94951 etc.); Apple doc `filecontentidentifierkey` "APFS allows only cloned files and their originals to have the same identifier" | verified-locally + sourced |
| 11 | The extended attrs need `getattrlist`/`getattrlistbulk` with `FSOPT_ATTR_CMN_EXTENDED`, with the CMNEXT bits in `attrlist.forkattr`. Buffer order is common → dir → file → fork. | `bulk.c`; `sys/attr.h:53,559-569`; `man getattrlist` | verified-locally |
| 12 | `EF_*` flags (`sys/stat.h:368-374`): MAY_SHARE_BLOCKS, NO_XATTRS, IS_SYNC_ROOT, IS_PURGEABLE, IS_SPARSE, IS_SYNTHETIC, SHARES_ALL_BLOCKS. `EF_NO_XATTRS` lets a scanner skip `listxattr`. `EF_IS_PURGEABLE` marks files the FS may delete to free space. | header + man page; SPARSE/SHARES_ALL observed | SPARSE and SHARES_ALL verified-locally; the rest sourced |
| 13 | Sparse file: 100 MiB logical, 16 KiB allocated. `du -A` shows apparent size. `isSparse` = true. | experiment; `man du` `-A` | verified-locally |
| 14 | Compressed file: 10.4 MB logical, 86 KB allocated. `ls -lO` shows `compressed`. Logical-size tools overstate it 120×. | experiment | verified-locally |
| 15 | `du` counts hard links once per run by default; `-l` counts each. | `man du` lines 56-60, 92-94; experiment 38 936 vs 43 032 KiB | verified-locally |
| 16 | `URLResourceValues.totalFileAllocatedSize` and `fileSize` are nil for a directory. There is no recursive size key. | `fmt.swift` probe | verified-locally |
| 17 | `ATTR_DIR_ALLOCSIZE` and `ATTR_DIR_DATALENGTH` exist. APFS "extended directory statistics, for fast directory sizing" are tied to directories marked *maintain-dir-stats* (`ATTR_CMNEXT_RECURSIVE_GENCOUNT` is 0 otherwise). | `man getattrlist` lines 641-648, 888-896; `sys/attr.h` VOL_CAP_FMT_CLONE_MAPPING comment | sourced. Whether arbitrary directories can use this is **unverified**; spike candidate. |
| 18 | `/usr/share/firmlinks` maps 19 System-volume paths to the Data volume, including `/pkg`, which is new in 26.4. | `cat /usr/share/firmlinks`; eclecticlight 2026-09-19 | verified-locally + sourced |
| 19 | `/Users` and `/System/Volumes/Data/Users` have the same `st_dev` (16777229) and `st_ino` (26305). The same holds for `/Applications` and `/private`. | `stat -f "%d %i"` | verified-locally |
| 20 | `getattrlistbulk("/")` returns `SF_FIRMLINK` (0x00800000) in `ATTR_CMN_FLAGS` for Users, Applications, Library, private, opt, Volumes and cores. `stat()` on the path shows the target's flags, not the firmlink's. | `bulk /`; `man getattrlistbulk` lines 98-102 | verified-locally |
| 21 | The Data volume root holds items with no firmlink: `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`, `.PreviousSystemInformation`, `MobileSoftwareUpdate`, `.TemporaryItems`, `macOS Install Data`. On this Mac `macOS Install Data` is **12.1 GB** (dated Jul 27, while the running 26.6 sealed snapshot dates from Jul 28). | `ls -la /System/Volumes/Data`; `du -sk` | verified-locally. Whether it is safe to delete is **unverified**. |
| 22 | `/` is a sealed, read-only snapshot (`disk3s3s1`, `com.apple.os.update-…`, "Purgeable: No") of the System volume. | `diskutil info /`, `diskutil apfs listSnapshots /` | verified-locally |
| 23 | All volumes share the container's free space. Here: Data 174.6, System 12.6, Preboot 10.8, Recovery 2.6, VM 1.1 GB (a 1 GiB `swapfile0`); 202.0 GB in use, 43.1 GB free. | `diskutil apfs list`; `ls -la /System/Volumes/VM`; `sysctl vm.swapusage` | verified-locally |
| 24 | `statfs`/`df` on an APFS volume: "Used" is per volume, while "Size" and "Available" are container-wide. So used + avail ≠ size, and `/` and the Data volume show the same Available. | `df -k` output (Data used 170 498 720 KiB, `/` used 12 340 904 KiB, both avail 42 177 316) | verified-locally |
| 25 | `volumeAvailableCapacity` ≈ `df` avail (43.15 GB). `…ForImportantUsage` = 48.35 GB (includes purgeable). `…ForOpportunisticUsage` = 30.8 GB (below raw free). Later in the same session: 40.96 / 41.61 / 28.64 GB. | `urlkeys` probe, two runs | verified-locally |
| 26 | Apple's guidance: use ImportantUsage for user-requested storage and Opportunistic for predictive downloads. | developer.apple.com/documentation/foundation/checking-volume-storage-capacity | sourced |
| 27 | The `volumeAvailableCapacity*` keys are "required reason" APIs and must be declared in `PrivacyInfo.xcprivacy`. App Store Connect has rejected undeclared uses since 2024-05-01. | Apple docs for `volumeavailablecapacitykey`, `describing-use-of-required-reason-api` | sourced. Handed to T-0011. |
| 28 | Purgeable space is a sum of promises from CacheDelete (`deleted`) providers, not an APFS measurement. Disk Utility and the URL keys read CacheDelete. Finder reads a stored value that can be stale. `df` shows only unconditional free. | eclecticlight 2023-04-27, 2023-04-15, 2026-09-02 | sourced |
| 29 | `/System/Library/CacheDelete` has 27 provider plists on 26.6 (e.g. `com.apple.TMCacheDeleteService`, `com.apple.FileProvider.CacheDelete`, `com.apple.quicklook.ThumbnailsAgent.CacheDelete`). eclecticlight counted 32 in 2023. | `ls` | verified-locally |
| 30 | Time Machine local snapshots: "Your Mac counts the space used by snapshots as available storage". They are deleted "as they age or as space is needed". | support.apple.com/en-us/102154 | sourced. This Mac has no local snapshots (`tmutil listlocalsnapshots /` empty, Data volume "No snapshots"), so snapshot trapping of PRIVATESIZE is **unverified locally**. |
| 31 | "System Data (or Other) … measures the storage space used by all Apple and third-party files that don't belong to any more specific category." In practice it is used minus the named categories, so it includes snapshots and caches. | support.apple.com/en-us/102624; eclecticlight 2025-02-11 | sourced |
| 32 | Finder shows each clone at full size, but volume used/free totals are block-accurate. | eclecticlight 2022-12-30, 2020-04-14 | sourced (Finder GUI not checked) |
| 33 | `ByteCountFormatter` `.file` is decimal (1 000 000 → "1 MB"; 245 107 195 904 → "245,11 GB", matching the Storage settings style). `.memory` is binary. | `fmt.swift`; Apple doc `countstyle-swift.enum/file` | verified-locally |
| 34 | Dataless (evicted iCloud/File Provider) files carry `SF_DATALESS` (0x40000000). `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, …, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` disables materialization for a thread or process. The man page names OFF as the system default. | `sys/stat.h:359`, `sys/resource.h:509,539-544`, `man setiopolicy_np` | sourced. Whether reads download by default for a GUI app is **unverified**. |
| 35 | Per-user `/var/folders/…` is 2.3 GiB and `/private/var/db` is ≥2.0 GiB (readable part, no root) on this Mac. | `du -sk` | verified-locally |

## How the reference tools do it (read at shallow clones, not re-run)

| tool (stars, license via `gh api`) | size base | hard links | clones | firmlinks / scope |
|---|---|---|---|---|
| PureMac `momenbasel/PureMac@bef6083` (6 677, MIT) | Space explorer: `lstat` `st_blocks*512` (`PureMac/Services/StorageExplorer.swift:313-327`). App and orphan sizes: `totalFileAllocatedSize` with `.skipsHiddenFiles` (`PureMac/Logic/Utilities/FileSize.swift:44-66`) | explorer dedupes `(dev, ino)` (`StorageExplorer.swift:266`); `FileSizeCalculator` does not | not handled | explorer skips dataless and not-downloaded ubiquitous items (`:225,236,307-310`); root is user-picked |
| Pearcleaner `alienator88/Pearcleaner@7724df7` (14 715, NOASSERTION) | logical `fileSizeKey`/`totalFileSizeKey` (`Logic/Lipo.swift:444-461`, `Logic/FileSearch/FileSearchLogic.swift:256-262`) | no | no | — |
| Mole `tw93/Mole@a7fa8dd` (68 135, GPL-3.0) | `min(st_blocks*512, st_size)` (`cmd/analyze/scanner.go:1255-1266`) | `(dev, ino)` when `nlink>1` (`scanner.go:1239-1253`) | no | overview = Home, ~/Library, /Applications, /Library + fixed insight paths (`cmd/analyze/main.go:183-213`, `insights.go`); root walk skips `System`, `private`, `Volumes`… (`constants.go:211-233`, `scanner.go:348`) |
| dust `bootandy/dust@ae5c770` (12 292, Apache-2.0) | `blocks * block_size`, capped against over-reporting on NTFS (`src/platform.rs:25-66`); `-s` apparent | `(ino, dev)` dedupe unless apparent (`src/dir_walker.rs:133-139`) | no | — |

Free-space math is right in both GUI cleaners: purgeable = ImportantUsage − Available (PureMac `Services/ScanEngine.swift:98-107`; Pearcleaner `Logic/AppState.swift:264-287`). Pearcleaner's variable names are swapped, though. It calls `volumeAvailableCapacity` `availableWithPurgeable`, and the ImportantUsage value `realAvailable`. Only the names are wrong; the output is correct.

Measured impact of Mole's `min()` rule: on `/opt/homebrew/lib/node_modules` (13 640 files, 9 629 under 4 KiB) it reports 688.6 MiB against 723.7 MiB allocated, a 4.9 % undercount. On `~/Library/Caches` the gap is 1.8 %. PureMac's `.skipsHiddenFiles` misses 15 MiB of 7 711 MiB (0.2 %) in `~/Library/Application Support` on this Mac, so it is not worth a finding.

## Implications for macontrol

1. **Scanner record per file** (one `getattrlistbulk` call per directory, `FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW`): name, objtype, `ATTR_CMN_FLAGS`, `ATTR_CMN_FILEID`, `ATTR_CMN_DEVID`, `ATTR_FILE_LINKCOUNT`, `ATTR_FILE_TOTALSIZE`, `ATTR_FILE_ALLOCSIZE`, and `ATTR_CMNEXT_PRIVATESIZE | CLONEID | EXT_FLAGS`. Do not use `FileManager.enumerator` + `resourceValues` on the hot path: it cannot return private size, and it pays for URL objects. The cost of `PRIVATESIZE` on large or fragmented trees is **unverified**; it has been asked of the T-0004 benchmark.
2. **Disk map number = allocated size**, hard links counted once by `(dev, fileid)`. This matches `du` and Finder "on disk". It lets map area add up to the parent, because shared clone blocks are not split.
3. **"You will free" number = reclaimable**, computed per selection:
   - Σ PRIVATESIZE over regular files;
   - use ALLOCSIZE when `UF_COMPRESSED` (PRIVATESIZE is 0 there);
   - count a hard-linked inode only when every one of its links is inside the selection, otherwise 0;
   - clones whose partners are all inside the selection: their shared blocks are also freed. Group by CLONEID and count ALLOCSIZE once per group if the whole group is selected; partial clones stay approximate.
   - Show "N GB freed now, M GB shared with clones or snapshots". Never promise more than this.
4. **Scope: scan volumes, not `/`.** Walk `/System/Volumes/Data` as one volume, so every byte is seen once and Data-root folders such as `macOS Install Data` are included. Show paths in their user-facing form by mapping through `/usr/share/firmlinks`; `ATTR_CMNEXT_NOFIRMLINKPATH` is the reverse. If the user picks `/`, skip `/System/Volumes` and treat `SF_FIRMLINK` directories as the Data volume. The sealed System volume is shown as one block ("macOS, read-only", from its volume used space), never walked or offered for deletion.
5. **Top-level accounting that closes to the byte:** container size = Σ volume used (Data, System, Preboot, Recovery, VM, …) + container free. Inside the Data volume, the result is scanned bytes + unreadable remainder (TCC/root; shown as a labelled bucket, not folded into anything). Purgeable is shown as a separate, dated figure from `volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity`, never added into used or free.
6. **Never materialize.** Set `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` for the scanner process. Detect `SF_DATALESS` from `ATTR_CMN_FLAGS` and show those files as "in iCloud, 0 B local".
7. **Units**: decimal via `ByteCountFormatter(.file)` to match Finder and Storage settings. Label "size" (logical) and "on disk" (allocated) the way Finder does.
8. **Test**: `research/bench/size-accounting/run.sh` is the acceptance fixture. The macontrol scanner should reproduce its expected table: 23 576 KiB unique, clone pair reclaimable 0, compressed 86 016 B, sparse 16 KiB.

## Decisions for the user

1. **Headline "reclaimable" number: strict (PRIVATESIZE-based, what deletion frees right now) or familiar (allocated size, like Finder, PureMac and Mole)?** Recommendation: strict for the "free up" button, with allocated size in the map. The cost is that macontrol will sometimes show smaller numbers than competitors.
2. **Default scan scope: the whole Data volume (needs Full Disk Access to be complete; shows `macOS Install Data`, `/private/var`, Spotlight) or home-folder-first like Mole?** Recommendation: whole Data volume when FDA is granted, home otherwise, with the unreadable remainder shown.
3. **Offer deletion of `macOS Install Data` / update leftovers?** 12.1 GB here, but safety is unverified. It needs a platform-constraints check (T-0010) before any "Delete" button. Until then, show it read-only.
4. **Show purgeable space at all?** It is volatile (5.2 GB, then 0.66 GB later in the same session here) and is not ours to free. Recommendation: show it as "macOS can free about N GB on demand" with a timestamp, and do not add a "purge" action.

## Open / unverified

- The CPU/IO cost of requesting `ATTR_CMNEXT_PRIVATESIZE` / CLONEID on large trees (asked of T-0004).
- Whether PRIVATESIZE drops to 0 for files held by a Time Machine local snapshot. No snapshot exists on this Mac, and creating one was judged an unwanted side effect.
- Whether APFS dir-stats (`ATTR_DIR_ALLOCSIZE` on maintain-dir-stats directories) can be enabled or used by a third-party app for instant folder sizes.
- The exact Storage-settings category rules; only Apple's one-line definition and eclecticlight's analysis are available.
- Default dataless materialization behaviour for a sandboxed or GUI app.

## Sources

- Apple, Checking Volume Storage Capacity: https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity
- Apple, URLResourceKey docs (`totalfileallocatedsizekey`, `fileallocatedsizekey`, `filecontentidentifierkey`, `maysharefilecontentkey`, `volumeavailablecapacity*key`): https://developer.apple.com/documentation/foundation/urlresourcekey
- Apple, ByteCountFormatter.CountStyle.file: https://developer.apple.com/documentation/foundation/bytecountformatter/countstyle-swift.enum/file
- Apple, Describing use of required reason API: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- Apple Support, About Time Machine local snapshots: https://support.apple.com/en-us/102154
- Apple Support, Free up storage space on Mac: https://support.apple.com/en-us/102624
- WWDC19 session 710, What's New in Apple File Systems (firmlinks, volume groups): https://asciiwwdc.com/2019/sessions/710 and https://devstreaming-cdn.apple.com/videos/wwdc/2019/710aunvynji5emrl/710/710_whats_new_in_apple_file_systems.pdf
- eclecticlight: Free space on an APFS volume is an illusion (2022-12-30) https://eclecticlight.co/2022/12/30/free-space-on-an-apfs-volume-is-an-illusion/ ; Where does macOS get its volume free space figures from? (2023-04-27) https://eclecticlight.co/2023/04/27/where-does-macos-get-its-volume-free-space-figures-from/ ; What is purgeable disk space? (2023-04-15) https://eclecticlight.co/2023/04/15/what-is-purgeable-disk-space/ ; What is System Data in Storage Settings? (2025-02-11) https://eclecticlight.co/2025/02/11/what-is-system-data-in-storage-settings/ ; The arithmetic of free space (2026-08-21) https://eclecticlight.co/2026/08/21/the-arithmetic-of-free-space/ ; Caches and purging in macOS Tahoe (2026-09-02) https://eclecticlight.co/2026/09/02/caches-and-purging-in-macos-tahoe/ ; macOS Tahoe 26.4 changed boot volume structure (2026-09-19) https://eclecticlight.co/2026/09/19/macos-tahoe-26-4-changed-boot-volume-structure/ ; Copy, move and clone files in APFS (2020-04-14) https://eclecticlight.co/2020/04/14/copy-move-and-clone-files-in-apfs-a-primer/
- Local: `man getattrlist`, `man getattrlistbulk`, `man du`, `man setiopolicy_np`; SDK `usr/include/sys/attr.h`, `sys/stat.h`, `sys/resource.h` (MacOSX26 SDK in Xcode.app).
