# Feasibility: permanent-delete engine and restore points

Task T-0069 (M7, debloat). Researcher: feas-permanent, 2026-09-23.
Question from M-0045.5: "hardcore mode" (a header toggle, off by default) makes deletions **permanent**
instead of Move-to-Trash. Design that permanent path so it keeps **every v1 safety property**, and decide
whether macontrol can create a **restore point** (an APFS local snapshot) before a destructive batch.

This machine: macOS 26.6 (build 25G72), SIP enabled, Authenticated Root enabled, ad-hoc signing only, no
paid Apple Developer account. All probes ran non-root in the scratchpad
(`/private/tmp/claude-501/.../scratchpad/feas-permanent/`); the only system-state change was one Time Machine
local snapshot, created to test feasibility and deleted in the same run (fact 21). Nothing else on the system
was created, moved or modified.

Evidence tags: **verified-locally** (a probe I ran on this Mac), **sourced** (Apple man page / doc / Apple
open-source / reputable third party with a URL), **unverified** (could not be confirmed here).

Sibling docs: T-0068 `feasibility-privileged.md` (how a root delete is authorized — the permanent engine
below is what its helper runs as root), T-0068 comments (removefile / flag-availability findings I posted),
and `feasibility-apple-apps.md` (sealed system apps; system "restore point" = the previous sealed snapshot,
out of scope here). Builds on `ARCHITECTURE.md` §5 and `research/reports/topic-size-accounting.md` (snapshots).

## TL;DR recommendation

1. **Write one removal engine in `Sources/Safety` and reuse it for both Trash and hardcore delete.** It is a
   fd-relative, depth-first recursive remover: pin the parent with `open(O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC)`,
   re-check the scan's `(dev, inode)` identity, then descend only through `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`
   fds, listing each folder, `unlinkat(name, 0)` for non-directories and `unlinkat(name, AT_REMOVEDIR)` for
   emptied folders, never crossing onto another `st_dev`. This is the same walk ScanEngine already uses. It is
   the only design that keeps the v1 no-follow / identity / mount / protected-path guarantees under a hostile
   tree (facts 1–8), and on this 8 GB M1 it is **~2–5× faster than `/bin/rm -rf`, `removefile(3)` or
   `FileManager.removeItem`**, and scales with worker threads (fact 15).
2. **Do NOT use `removefile(3)`/`removefileat`, `FileManager.removeItem`, `rm -rf`, or the `AT_UNIQUE`/
   `AT_RESOLVE_BENEATH` flags** in the engine. `removefile` is full-path fts and, as root, silently clears
   `UF_IMMUTABLE` before unlinking (breaks F-0024/F-0070); `removefileat` just joins `F_GETPATH`+name and calls
   `removefile` (no fd safety); the new at-flags do not exist on macOS 14, the deployment floor (facts 3–6, 9).
3. **The permanent engine keeps the exact v1 pre-flight**: `ProtectedPaths` containment policy, `F_GETPATH`
   canonicalization, per-item identity re-check, `keep`-set expansion, mount-point refusal, locked-item
   refusal — all of it runs *before* the first `unlink`, unchanged from `TrashBatch`. Hardcore mode changes
   only the sink (unlink instead of `trashItem`) and the confirmation, never the guards.
4. **Restore point: yes, but as a prompt, not an automatic snapshot.** `tmutil localsnapshot` runs
   **unprivileged** and made a real snapshot here in 44 s (fact 20). But `fs_snapshot_create(2)` needs root +
   a restricted entitlement macontrol cannot get (fact 23), snapshots are **purgeable** — the OS can delete
   one at any moment, so it is not a dependable safety net (facts 24–25), and rolling back is a whole-volume,
   Recovery-mode operation that loses everything since the snapshot (fact 26). So: **before the first hardcore
   batch, offer a one-click "Create a restore point now" that shells `tmutil localsnapshot`** (best-effort,
   labelled "macOS may remove this automatically"), tell the user how to roll back, and recommend a real Time
   Machine/clone backup. Never make it the thing that makes hardcore mode "safe".
5. **History**: hardcore deletions are journaled like Trash moves, but with `trashedPath: null`, an outcome of
   `.deleted`, and status **"Deleted permanently — not recoverable"**. No Undo button. Record the batch,
   the canonical path, identity and bytes, and (if one was made) the restore-point snapshot name so History
   can show "A restore point was created before this batch: <name>".

## Facts table

### A. Removal primitives and safety

| # | Fact | Status | Source / probe |
|---|------|--------|----------------|
| 1 | `unlinkat(fd, name, 0)` removes a non-directory entry relative to a dir fd; `unlinkat(fd, name, AT_REMOVEDIR)` removes an empty directory. Symlinks are removed as the link, never followed. This is the primitive a no-follow recursive remover is built from. | sourced | `man 2 unlink`; SDK `sys/fcntl.h:180` |
| 2 | Opening every directory with `O_DIRECTORY\|O_NOFOLLOW\|O_CLOEXEC` via `openat` from a pinned parent fd means a symlink swapped in for a folder can never be descended (open fails `ELOOP`/`ENOTDIR`); the entry is then unlinked as a plain link, never its target. | verified-locally | `rmprobe fd` on a tree holding a dir-symlink and a file-symlink to an outside canary: root removed, canary intact |
| 3 | **`removefile(3)` is pathname-based and follows the full path each call.** Its own man page warns: "removefile() is pathname-based; … there are potential race conditions that may add risk when run with privileges" and "removefile() operates on symbolic links, rather than the target of the link." Internally it is an `fts_open(FTS_PHYSICAL\|FTS_NOCHDIR\|FTS_XDEV)` walk over the path. | sourced | `man 3 removefile`; apple-oss-distributions/removefile @ `removefile-85.100.6` `removefile_tree_walker.c:238` |
| 4 | **`removefile`, run as root (euid 0), calls `chflags` to clear `UF_APPEND\|UF_IMMUTABLE` before unlinking.** In a privileged helper this would delete files the *user* Locked, violating F-0024/F-0070 ("flags and ownership are never changed to force a delete"). | sourced (code-read) | `removefile_tree_walker.c:117,166,200` (`geteuid()==0 && … chflags(path, … &= ~(UF_APPEND\|UF_IMMUTABLE))`) |
| 5 | **`removefileat(fd, name, …)` gives no fd safety.** It does `fstat(fd)`, `fcntl(fd, F_GETPATH, base)`, joins `base + "/" + name`, and calls `removefile(base_path)` — i.e. it degrades to the full-path fts walk of #3. | sourced (code-read) | `removefile.c:255-297` |
| 6 | `FileManager.removeItem` and `/bin/rm -rf` are also full-path recursive deleters with no per-item identity re-check; neither is acceptable as the hardcore sink (they are exactly the F-0012 class we criticise in other tools). | verified-locally + sourced | `fmprobe`, `rm -rf` in the safety suite; ARCHITECTURE §5; F-0012 |
| 7 | A directory a walk descends can be swapped for a symlink to an outside folder mid-walk. Full-path removers detect it only by luck: in the race probe `removefile` and `FileManager` both **stopped with errors** (`ENOTEMPTY`/perm) and left the tree, and **the outside canary survived** because the swapped link was itself unlinked, not followed. The fd-relative remover detected the swap deterministically (`openat` → `ELOOP`, unlink the link). **None of the four followed the link off-tree**, but only the fd remover fails *safely and predictably*. | verified-locally | `rmprobe race-fd`, `race-rf`, `fmprobe` race: canary intact in all three; fd remover reported the swap and stopped |
| 8 | A **mounted volume inside the tree** (disk image at `root/a/mnt`) is never entered by the fd remover: after `openat` it `fstat`s the child and refuses when `st_dev` differs (`EXDEV`), exactly as `removefile` without `REMOVEFILE_CROSS_MOUNT` and `rm -rf` do. The image's files and the outside canary on it were untouched. | verified-locally | `rmprobe fd` mount case: `fail root/a/mnt errno=18 (Cross-device link)`, image contents intact |

### B. Flag availability on the macOS 14 floor

| # | Fact | Status | Source / probe |
|---|------|--------|----------------|
| 9 | On **macOS 14** (`xnu-10002.1.13`), `unlinkat` accepts only `AT_REMOVEDIR \| AT_REMOVEDIR_DATALESS \| AT_SYMLINK_NOFOLLOW_ANY`; anything else returns `EINVAL`. `AT_RESOLVE_BENEATH` and `AT_NODELETEBUSY` first appear in `xnu-12377.1.9` (macOS 26.0), `AT_UNIQUE` in `12377.121.6`; `O_RESOLVE_BENEATH`/`O_UNIQUE` in `xnu-11417` (15.4+). | sourced (code-read) | `vfs_syscalls.c:6294` (14) vs `:6762` (26); `bsd/sys/fcntl.h` per tag |
| 10 | ⇒ The engine must rely only on `O_NOFOLLOW`/`O_NOFOLLOW_ANY`, `openat`, and `unlinkat(…, AT_REMOVEDIR)` — all present since 10.10 — plus its own `fstat`-and-compare `(dev,ino)` check. `AT_UNIQUE` (refuse a multi-linked vnode) and `AT_NODELETEBUSY` (refuse a busy file) are macOS-26-only niceties: **use them only behind `if #available(macOS 26)`**, never as the sole guarantee. | verified-locally (reasoning) | facts 9, 14, 16 |
| 11 | `AT_NODELETEBUSY` (macOS 26) makes `unlinkat` refuse a file any process holds open (`errno EBUSY`); an idle file is removed. | verified-locally | `rmprobe nodeletebusy`: busy file "still there" `errno 16`, idle file removed `rc=0` |
| 12 | `AT_UNIQUE` (macOS 26) makes `unlinkat` refuse a vnode with >1 hard link (`errno 107 ENOTCAPABLE`, "Capabilities insufficient"). Useful to avoid deleting a name that shares its inode elsewhere, but macOS-26-only and off by default. | verified-locally | `rmprobe unique` on a 2-link file → `rc=-1 errno=107` |

### C. Locked files, deep trees, partial failure

| # | Fact | Status | Source / probe |
|---|------|--------|----------------|
| 13 | A **user-locked (`uchg`) file or folder** inside the tree stops all four removers unprivileged: `unlink` returns `EPERM` and the enclosing dirs stay. The fd remover reports it as one failure (`root/a/locked.txt errno=1`) and removes everything else; `rm`/`removefile`/`FileManager` leave more of the tree. Matches the v1 rule that we never `chflags` to force a delete. | verified-locally | safety suite §3/§4: locked item left, `ls -lO` shows `uchg` still set after every method |
| 14 | Because the pre-flight already refuses a batch that contains a locked item (`ProtectionPolicy.lockedItem`, `TrashBatch.trash`), the engine should never *reach* a locked file. If one appears between pre-flight and unlink (TOCTOU), the fd remover surfaces it as a per-item `EPERM` failure rather than clearing the flag. | verified-locally | `ProtectedPaths.swift:159-211`; safety suite §3 |
| 15 | On a tree deeper than `PATH_MAX` (300 nested dirs, ~1638-byte leaf path): the **fd remover and `rm -rf` both succeed**; `removefile` **fails at ~181 levels** (`ENAMETOOLONG`); `removefile` with `REMOVEFILE_ALLOW_LONG_PATHS` succeeds but `chdir`s the process (its man page: "making it not thread safe"); `REMOVEFILE_RECURSIVE_SLIM` fails (`ENAMETOOLONG`, its `cur_path[MAXPATHLEN]`); `FileManager.removeItem` fails ("file name … is invalid"). fd-relative is the only walk that is both deep-safe and thread-safe. | verified-locally | safety suite §5 |
| 16 | **Partial-failure reporting is natural in the fd engine and lost in the others.** The probe collects `{path, errno}` per failed entry and keeps going (`unlinked=…, rmdir=…, failures=N`); `removefile` only exposes errors through a C error-callback; `rm`/`FileManager` give one aggregate error. The engine must return a per-item outcome list (like `TrashReport`), never a single bool. | verified-locally | `rmprobe fd`/`par` failure lists; ARCHITECTURE §5 "any failed step stops the uninstall" |

### D. Speed on huge trees

| # | Fact | Status | Source / probe |
|---|------|--------|----------------|
| 17 | Fixture: an Xcode.app-shaped tree, 7,000 dirs × 21 files = 147,000 files (154,111 entries), 1 file in 10 holding 8 KiB; each run removes a fresh **APFS clone** of the template (`clonefile`). `kern.maxvnodes`=120,350, 8 cores, 8 GB. Machine under heavy parallel load (load avg ~40) during the run, so absolute times are pessimistic; the **ranking** is stable across 3 rounds. | verified-locally | `speed.sh`, `speed-run.log` |
| 18 | Deletion is **I/O-bound and unlink-heavy**, so it never crosses `kern.maxvnodes` the way scanning does; a warm clone deletes in seconds. | verified-locally | round-3 times below |
| 19 | Median wall-times (3 rounds, seconds): single-thread fd ≈ 11–29, `rm -rf` ≈ 18–80, `removefile` ≈ 10–56, `FileManager` ≈ 19–54, **fd 4-thread ≈ 9–18, fd 8-thread ≈ 5–8**. The parallel fd remover (one worker per subtree, a pending-count that removes a folder when its last child is gone) is the fastest by 2–5× and the only one that improves with cores. Round 3 (warmest): rmrf 18.4, rf 10.5, fm 19.6, fd1 11.0, **par4 9.0, par8 5.5**. | verified-locally | `speed-run.log` |

### E. Restore points (APFS local snapshots)

| # | Fact | Status | Source / probe |
|---|------|--------|----------------|
| 20 | **`tmutil localsnapshot` runs unprivileged and works with no Time Machine destination configured.** It created `com.apple.TimeMachine.2026-09-23-152529.local` on `/` in 43.9 s here as user `egeb`; `tmutil destinationinfo` reported "No destinations configured". If TM is off it snapshots only the current Data volume. | verified-locally | `tmutil-run.log` (`tmutil localsnapshot` → "Created local snapshot with date: …", exit 0) |
| 21 | I deleted it in the same run. `tmutil deletelocalsnapshots <date>` returned an error (POSIX 70, "Stale NFS file handle") **but the snapshot was gone afterward** — `backupd` removed it via the kernel (`apfs_snap_vnop_remove: … deleting snapshot name (com.apple.TimeMachine.2026-09-23-152529.local)`). `tmutil listlocalsnapshots /` and `diskutil apfs listSnapshots` both showed zero afterward. Net system change from this research: **none**. | verified-locally | `tmutil-run.log`, unified log (`snaplog.txt` 15:25:34), `listlocalsnapshots` empty |
| 22 | `tmutil localsnapshot` on the sealed `/` shows a normal `.local` snapshot on the Data volume; it does not (and cannot) snapshot the read-only system volume, which is fine — hardcore mode only ever deletes user- or root-owned Data-volume items. | verified-locally | before/after `diskutil apfs listSnapshots /System/Volumes/Data` (0 both) |
| 23 | **Programmatic snapshot APIs are closed to macontrol.** `fs_snapshot_create(2)`: "All snapshot functions require superuser privileges and also require an additional entitlement." The entitlement is `com.apple.developer.vfs.snapshot`, a **special/restricted** entitlement Apple grants only to backup-app developers after review, via DTS, and it must be on the provisioning profile — impossible with ad-hoc signing and no paid account. My unprivileged `fs_snapshot_create` on a scratch image returned `EPERM`. | verified-locally + sourced | `man 2 fs_snapshot_create`; developer.apple.com/forums/thread/89635 (Apple DTS); `rmprobe snapshot` → `errno 1` |
| 24 | **Local snapshots are purgeable and can vanish on their own.** `tmutil localsnapshot` prints "NOTE: local snapshots are considered purgeable and may be removed at any time by deleted(8)." Apple: "Time Machine automatically deletes snapshots as they age or as space is needed"; TM keeps hourly ones ~24 h. So a restore point macontrol makes may already be gone when the user needs it — **it is not a dependable safety net.** | verified-locally + sourced | snapshot NOTE (fact 20); support.apple.com/en-us/102154; eclecticlight.co 2026-08-24, 2026-05-10 |
| 25 | This Mac had **4.7 GB free**. Apple: "Time Machine stores snapshots only on disks that have plenty of free space." On a nearly-full disk (the debloat user's likely state) a snapshot may be refused or purged immediately, and it pins the blocks of everything you delete, so **deleting files while a snapshot exists frees ~0 until the snapshot is purged** — the opposite of what a debloat user wants. | verified-locally + sourced | `df -h`; support.apple.com/en-us/102154; `man 2 fs_snapshot_create` ("deletion of files … may not result in the storage being available if the snapshot contains the file") |
| 26 | **Rollback is whole-volume and destructive**, not per-file: it is done from **Recovery → "Restore from Time Machine"**, reverts the entire Data volume to the snapshot, is near-instant, and **deletes every snapshot made after the one you roll back to**. There is no in-app, per-file "restore from snapshot" without the restricted mount/revert entitlements. macontrol can *make* a restore point and *tell the user how to use it*; it cannot drive the restore. | sourced | eclecticlight.co 2026-05-07 ("how to make and roll back to a snapshot"); `man 2 fs_snapshot_create` (`fs_snapshot_revert` "requires … an additional entitlement", "destructive operation") |
| 27 | Third-party (`tmutil`) snapshots "may not behave the same as Time Machine's, and may not be included in Purgeable space" — so a macontrol-made snapshot may *not* be auto-counted as free space and may sit as real usage until purged/deleted. Another reason to label it plainly and let the user delete it. | sourced | eclecticlight.co 2026-08-24 |

## Recommendation (design)

**One engine, two sinks.** Add `RemovalEngine` to `Sources/Safety` (the one door; SinkAuditTests already
guard it). `TrashBatch` keeps its entire pre-flight — canonicalization, `ProtectedPaths` containment,
`(dev,ino)` re-check, `keep`-expansion, mount/`SF_RESTRICTED`/locked refusal, `samePlace` no-follow ancestor
check — and then dispatches to a sink:

- **Trash sink (default):** today's `FileManager.trashItem` path, unchanged.
- **Permanent sink (hardcore):** the fd-relative recursive remover proven above. Never `removefile`,
  `removeItem`, `rm`, and never `chflags` to force a delete. Per item:
  1. `open(parent, O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC)`, `fstatat(AT_SYMLINK_NOFOLLOW)` the leaf, compare to
     the scan identity (refuse `identityChanged`); for a folder, `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` and
     `fstat`-confirm the same `(dev,ino)`.
  2. Depth-first: list, `unlinkat(name, 0)` non-dirs, recurse into same-`st_dev` subdirs only, `unlinkat(name,
     AT_REMOVEDIR)` on the way up. A child that stopped being a folder (`ELOOP`/`ENOTDIR`) is unlinked as a
     link, never followed. A different `st_dev` is refused (mount point).
  3. Collect `{path, errno}` per failure and continue; return a per-item outcome list. Any pre-flight refusal
     (protected, locked, identity) means the item is **not** touched.
  4. Optional macOS-26 hardening behind `#available`: pass `AT_NODELETEBUSY` for the "regenerating caches"
     case so a file a process still holds open is skipped rather than deleted.
- **Parallelism:** for a big tree (Xcode DerivedData, `~/Library/Developer/CoreSimulator`, a large vendor
  `Application Support`), fan out one worker per subtree with a per-node pending count (fact 19). Cap workers
  at `activeProcessorCount` (8), same policy as ScanEngine, and keep a single-thread path for small items.

**Hardcore-mode UX (M-0045.5, and the user's clarifications):**
- A toggle always visible in the app header; hover tooltip explains it. Unchecked = Trash (default).
- Ticking it opens a modal risk disclaimer the user must confirm ("Permanent deletions cannot be undone and
  do not go to the Trash. Create a restore point or a backup first."). Store the choice per session, never
  persisted-on by default.
- In the confirmation sheet for a hardcore batch, restyle destructively (red), require an explicit confirm,
  never fire on Return (cf. T-0058), and show the exact **frees-now** bytes (which, unlike Trash, are real
  immediately — permanent delete does free space, subject to snapshots, fact 25).

**Restore point (before the first hardcore batch of a session):**
- Offer "Create a restore point (Time Machine local snapshot)" as a one-click, best-effort action that shells
  `tmutil localsnapshot` (fact 20; no root, no entitlement). Label it honestly: "macOS may remove this
  automatically to reclaim space; it is not a substitute for a backup." Show the returned snapshot date.
- Do **not** block hardcore mode on it and do **not** claim it makes permanent delete safe. Also surface the
  bigger, dependable options: recommend a Time Machine backup or a bootable clone, and explain that rolling
  back a snapshot is a whole-volume Recovery operation that loses everything since (fact 26).
- Record the snapshot name in the batch's History entries.

## History (what it must show)

Extend `JournalEntry`/`HistoryModel` so a permanent deletion is a first-class, honest record:
- `trashedPath` = null, `identity` = the deleted item's `(dev,ino)`, `allocated` = bytes freed, plus a new
  outcome/flag `.deleted` (vs `.trashed`).
- Batch status: **"Deleted permanently — not recoverable"**; no Undo button (the current Undo relies on a
  `trashedPath` that no longer exists). `HistoryBatch.status` must not say "In Trash, frees X" for these.
- `inTrashBytes` must exclude permanent deletions (they already freed space; they are not "in Trash").
- If a restore point was made for the batch, show "Restore point created before this batch:
  `com.apple.TimeMachine.<date>.local` — restore via macOS Recovery" with a help link, and note it may have
  been purged.
- Keep the journal's crash-safety (one fsync'd JSONL line per item) so a permanent batch interrupted midway
  leaves an accurate record of what was already deleted.

## Risks

- **No undo, by definition.** The whole safety burden shifts onto the pre-flight and the confirmation. Every
  guard that today protects a Trash move must be proven to run on the permanent path too, with the same
  deliberate-bug tests (M-0001 V4; the reviewer found several stale-state gaps in v1). The batch must **stop
  the whole item** on any pre-flight refusal, never delete "the rest".
- **TOCTOU between pre-flight and unlink** is unrecoverable for a permanent delete. The fd re-check (open
  parent no-follow, re-`fstat`, compare identity, verify the parent's link-free identity did not change — as
  `TrashBatch.linkFreeIdentity` already does) must wrap the unlink, not just the plan.
- **Restore point is weak insurance.** Purgeable, needs free space, pins deleted blocks, rollback is
  whole-volume. If we oversell it we give false confidence. Copy must be honest (facts 24–26).
- **Speed vs. safety of parallelism.** The parallel remover holds one fd per live subtree; cap workers and
  the fd budget (v1 ScanEngine already learned EMFILE lessons — M-0001 review-scan-engine). A per-worker
  failure must not abandon sibling subtrees silently.
- **`removefile` temptation.** It is one call and looks convenient; facts 3–5 and 15 are why it must not be
  used. Add it to the "do not use" list next to `rm`/AppleScript in the sink audit rationale.

## Open questions (for the builder / product)

1. **Which delete gets a permanent option?** M-0045.5 frames hardcore mode as global. But the safest first
   ship is "permanent delete only for regenerable caches" (Cleaner `safe` tier), where re-creation is cheap —
   the user's own note in M-0045.5 ("cache'ler için … hemen sil"). Should hardcore mode be **all-or-nothing**
   or gated per safety tier? (Recommend: honour the global toggle, but keep `manual`-tier and protected items
   refused exactly as in Trash mode.)
2. **Restore point default.** Auto-offer once per session, or only on the first batch over N GB / touching
   non-cache data? (Recommend: offer once per session, pre-checked only when the batch includes non-`safe`
   items.)
3. **`AT_NODELETEBUSY`/`AT_UNIQUE` on macOS 26.** Adopt behind `#available` as extra insurance for hardcore
   deletes of caches (skip a file a process holds open)? Verify they do not break legitimate deletes of
   multiply-linked cache files first.
4. **Does the privileged helper (T-0068) run the same engine as root?** Yes per its design — but its root
   `removefile` clearing `uchg` (fact 4) must be replaced by this fd engine. Confirmed with feas-privileged
   via a T-0068 comment; the shared engine must build cleanly in the helper (no SwiftUI, no app deps).
5. **Secure erase.** `removefile`'s `REMOVEFILE_SECURE_*` overwrite passes are meaningless on APFS/SSD (wear
   levelling, copy-on-write) and Apple dropped "Secure Empty Trash" for this reason. Confirm we will **not**
   offer a "secure delete" toggle (it would be a false promise). (Recommend: no.)
6. **Verifying the restore-point shell call at ship time.** `tmutil localsnapshot` took 44 s here and the
   result parsing ("Created local snapshot with date: …") should be smoke-tested on a machine with TM on and
   off, and on a nearly-full disk where it may refuse.
