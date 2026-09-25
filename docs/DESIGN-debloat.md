# Design: debloat and hardcore mode

Designer: design-debloat, 2026-09-23. **Revision r2** by design-debloat-r2, same day. It applies the honesty-ux and
security reviews at the end of this document. Each changed rule names its source as *(r2: ux N)* or *(r2: sec N)*, and
each review issue has a Resolution under its review table. Milestone "Debloat & hardcore" (board roadmap). Inputs:
the user's decisions after v1 (journal M-0045, points 4-6, and the user's own words relayed with this task), the
three feasibility reports `docs/research/feasibility-{privileged,permanent,apple-apps}.md` (T-0068, T-0069, T-0070),
and the v1 code (`Sources/Safety`, `Sources/Uninstaller`, `Sources/MacontrolUI/Shell`). This document replaces the
"not in v1" lines of `ARCHITECTURE.md` §1 (no privileged helper), §5 (Move to Trash only), §7 (Apple apps admin-only)
and §12.

**This Mac:** macOS 26.6 (25G72), SIP on, Authenticated Root on, FileVault off, ad-hoc signing only, no paid
developer account. Nothing here ran as root. **Tags:** *verified-locally* = a probe on this Mac (by this design, a
feasibility report or a review, which is named); *sourced* = Apple doc, man page, Apple open source or DTS, with a
URL (*not re-fetched* = from a feasibility report or prior knowledge, no network access in these runs); *unverified*
= could not be checked here; *inferred* = follows from verified facts but was not run; *decision* = a design choice,
with its reason.

What the user asked for, in their words (translated): hardcore mode is "definitely a must, it will be our biggest
promise: like Microsoft debloaters remove Microsoft's own apps, this must do it for the Mac"; a toggle "always visible
in the app header", with a tooltip on hover, "ticked: delete permanently; unticked (the default): delete to the
Trash", and "trying to tick it opens a pop-up confirmation modal with a risk disclaimer"; admin deletions "like
PureMac, remove Apple apps with all their leftovers"; for sealed system apps "add a warning at most: strongly not
recommended, create a backup point".

## 0. Decisions on one page

| # | Decision | Why |
|---|---|---|
| D1 | Hardcore mode is one session-wide switch, a checkbox in the window toolbar on every screen, **off at every launch**, never stored. | The user's spec (checkbox, tooltip, modal). A permanent-delete state that survives a relaunch is how a user deletes without knowing it. |
| D2 | Turning it on opens a modal with a short risk disclaimer and a red "Turn On Hardcore Mode" button with no keyboard shortcut. Return and Esc cancel. No extra "I understand" checkbox. *(r2: ux 13)* | The user asked for a confirmation modal with a risk disclaimer. Every delete still has its own sheet; T-0058 lesson (no destructive default). |
| D3 | One Safety pipeline, two modes, shared pre-flight. Trash mode is v1. **Permanent mode moves a folder to the Trash first** (v1's single rename, identity checked before and after) **and then erases the trashed copy** with an fd-relative remover. A file is one `unlinkat` in place. *(r2: ux 4, sec 4)* | A stop halfway (App Management, a lock that appeared, `EMFILE`, a crash) then leaves the original path empty and the rest in the Trash under its own name. It never leaves a half-deleted app where it was. |
| D4 | Some items always go to the Trash, even in hardcore mode: items in iCloud Drive or a cloud provider folder, and a short `trashOnly` list of personal databases (Notes, Contacts, Calendars, Safari, iPhone backups). *(r2: sec 5)* | A permanent delete in iCloud deletes on every device. The personal databases were never on the never-touch list; in v1 the Trash was their safety net. |
| D5 | Root work goes through a bundled helper `Contents/Helpers/macontrol-priv`, started by `do shell script … with administrator privileges` from `NSAppleScript`. Only three macontrol-owned strings go on the shell line; the paths travel in a 0600 request file bound by its SHA-256. **One helper request per user action** (a clean, an uninstall, a Debloat run). *(r2: ux 9)* | feasibility-privileged: the only non-deprecated route that works without a paid account. One request means one dialog, whatever the grace period does. |
| D6 | The helper checks the request, then `fork()`s **without exec**. The child keeps the checked bytes in memory and detaches with `setsid`, so the admin dialog is the only main-thread block. Results go to a root-owned file that the app reads through one checked fd. *(r2: sec 1, sec 2)* | `NSAppleScript` is main-thread only, and a 20 s root delete must not freeze the UI. After the password, nothing a same-user process can write is read again. |
| D7 | Root may act only inside a short allowlist (`PrivilegedScope`, which also refuses Apple's own configuration names), then the full v1 `ProtectionPolicy` built with the requesting user's home, then the identity check, all as root. `systemNeverTouch` gains the live macOS configuration folders. *(r2: sec 3, sec 6)* | By code reading, `ProtectionPolicy` does not protect what is inside `/private/etc` or `/Library/Preferences`: a user is stopped only by `canMove`, which root passes (`/private/etc/sudoers`, `SystemConfiguration/preferences.plist`: root-owned, not `restricted`, `ls -lO`, verified-locally). |
| D8 | A new sidebar section **Debloat** (⌘5; History moves to ⌘6), a PureMac-style checklist of Apple's apps with their content, built on the same `Uninstaller` plan and uninstall. **App rows start unticked.** The root route serves Clean, Uninstall and Debloat; **Disk Map keeps v1's "Needs admin"** and Reveal in Finder. *(r2: ux 3, sec 3)* | The user calls debloat the product's main promise, so it needs a place of its own (M-0032: PureMac's list-and-review feel). Xcode is a tool someone chose, not bloat. The user asked for PureMac-style app removal, not root file browsing. |
| D9 | Apple app content comes from a bundled, validated `apple-apps.json` of per-app profiles. Only Xcode is verified here; the other profiles ship with every content item unselected until a real install checks them. | feasibility-apple-apps F1, F10, recommendation 1. |
| D10 | Sealed system apps: macontrol shows them locked with real sizes and an expert guide, reachable from the locked panel **at all times** *(r2: ux 14)*. It never runs `mount`/`bless` until a VM run on 14, 15 and 26 has proved the procedure and its revert, and that code is compiled out until then *(r2: sec 12)*. | SIP makes removal impossible with SIP on (verified-locally); the procedure is unverified and a failed `bless` affects booting. The user asked for "a warning at most", and a guide that runs nothing needs no mode switch. |
| D11 | Restore point = `tmutil localsnapshot`, an unchecked box in every hardcore confirmation, never automatic. The box states its costs: it keeps the deleted bytes while it exists, and rolling back returns **every** file to that moment. *(r2: ux 5, ux 6)* | feasibility-permanent facts 20-27: unprivileged and it works, but purgeable, it pins deleted blocks, and rollback is a whole-volume Recovery operation. |
| D12 | **Items the helper moved to the Trash have no in-app Undo.** The helper has no `restore` op. History tells the user to drag them back in Finder. *(r2: sec 2)* | An "undo" whose source and target come from records a same-user process can write is a root write primitive into system folders. |
| D13 | Xcode's simulator runtimes are deleted **first**, by CoreSimulator's own `simctl` at its fixed path, while Xcode is still installed. In Trash mode their row starts unticked, under "Deleted by Xcode's tool, not moved to the Trash". *(r2: ux 1, ux 2, sec 10)* | The real `simctl` lives in a framework that the Xcode profile removes (verified-locally, §4.4), and runtimes can't go to the Trash. |

## 1. Hardcore mode UX

### 1.1 State

`@Observable public final class HardcoreMode` (in `MacontrolUI/Shell/HardcoreMode.swift`) holds `isOn` (default
`false`) and `mode: DeletionMode` (`.permanent` when on). `AppModel` owns one instance and passes it to every
screen model. **It is never persisted**: no `UserDefaults`, no `@AppStorage`, no scene storage. Every launch starts
in Trash mode. No "remember my choice" setting in this milestone; add one only if users ask, and even then the modal
runs again after each launch.

**The mode is captured when a confirmation opens.** Each confirmation value (`CleanModel`'s review,
`UninstallConfirmation`, `DiskMapModel.review`, the Debloat confirmation) stores `mode` at `begin…()`. The sheet
renders from that value and the confirm action passes that value to Safety. A sheet is window-modal, so the toolbar
cannot change underneath it, and a batch already running keeps the mode it started with.

### 1.2 The toggle

- A `ToolbarItem(placement: .primaryAction)` attached to the detail column in `RootView`, so it is on every screen,
  independent of `ScanToolbar` (T-0061 wants the scan items only on Overview and Disk Map). It is the last trailing
  item, so it never moves.
- `Toggle(isOn:)` with `.toggleStyle(.checkbox)` (the user asked for a tick box). Label: `flame` icon + "Hardcore
  mode" in secondary text when off; `flame.fill` + "Hardcore mode" in `Theme.dangerText` when on.
- The binding does not set `isOn = true` directly: it presents the turn-on modal (§1.3). Unticking turns it off
  at once, with no confirmation.
- No keyboard shortcut and no menu command to turn it on, so it cannot be switched on by accident. A View menu
  item "Turn Off Hardcore Mode" exists only while it is on.
- Accessibility: label "Hardcore mode", value "On, deletions are permanent" / "Off, deletions go to the Trash".

**Tooltip (`.help`), exact text:**
- Off: "Hardcore mode is off. Files macontrol removes go to the Trash, and you can put them back until you empty it.
  Turn it on to delete permanently instead." *(r2: ux 2. It speaks of files, and it stays true for items the helper
  trashed, which go back through Finder, D12. Simulator runtimes are not files macontrol moves; their row says so.)*
- On: "Hardcore mode is on. Removals skip the Trash and can't be undone. macontrol still never deletes macOS itself,
  your top-level folders or Photos libraries, locked files, or anything that changed since the scan. Files you
  select inside your folders are deleted for good." *(r2: ux 7)*

**Banner while on.** A thin bar in `.safeAreaInset(edge: .top)` of the detail column, red-tinted: `flame.fill`
"Hardcore mode is on: removals are permanent." and a "Turn Off" button. It shows the state even when the user hides
the toolbar (View > Hide Toolbar), which the "always visible" requirement needs.

### 1.3 Turn-on modal *(r2: ux 5, ux 7, ux 13)*

A sheet, 480 pt wide:

> **Turn on hardcore mode?**
> macontrol will delete permanently instead of moving to the Trash.
> - Nothing goes to the Trash, and History can't put anything back.
> - It stays on for Clean, Uninstall, Debloat and Disk Map until you turn it off or quit macontrol.
> - macontrol still never deletes macOS itself, your top-level folders (Documents, Desktop…), Photos libraries,
>   locked files, or anything that changed since the scan. Files you select inside your folders are deleted for
>   good. Items in iCloud Drive, and your notes, contacts, calendars and Safari data, still go to the Trash.
>
> Back up your Mac with Time Machine first. A mistake here can't be fixed from inside macontrol.
>
> [Cancel]  [Turn On Hardcore Mode]

- "Cancel" carries `.keyboardShortcut(.cancelAction)` **and** `.defaultAction`: Return and Esc both cancel.
- "Turn On Hardcore Mode": `role: .destructive`, `.borderedProminent`, `.tint(.red)`, no keyboard shortcut. It is the
  confirmation; there is no checkbox in front of it.
- Closing the sheet any other way leaves hardcore mode off.

### 1.4 What changes while it is on

| Surface | Off (v1, unchanged) | On |
|---|---|---|
| Clean footer summary | "N selected, frees about X once you empty the Trash" | "N selected, frees up to X" *(r2: ux 5)* |
| Uninstall footer | "X on disk, moved to the Trash" | "X on disk, deleted permanently" |
| Disk Map context menu, inspector | "Move to Trash" | "Delete Permanently…" (opens the same review) |
| Confirmation sheets (`TrashSheet`, Disk Map `ReviewSheet`, Debloat) title | "Move N items to the Trash?" / "Uninstall App?" | "Delete N items permanently?" / "Uninstall App permanently?" |
| Sheet header | `trash.circle.fill`, accent | `flame.circle.fill`, red, plus a red strip inside the sheet: "Permanent: skips the Trash" *(r2: ux 12; the window banner sits under the sheet)* |
| Sheet message | v1 text | "They skip the Trash and can't be put back. Frees up to X." With the restore-point box ticked, it adds: "Space comes back when the restore point is removed." *(r2: ux 5)* |
| Sheet list header | "Moves to the Trash" | "Deletes permanently". D4 items are listed apart, under "Moved to the Trash", each with its reason ("stored in iCloud", "holds your notes", …), and are not counted in X. *(r2: ux 5, sec 5)* |
| Confirm button | "Move to Trash" / "Uninstall" / "Clean" (red) | "Delete Permanently" (red) |
| Restore point | not offered | checkbox, §2.6 |
| Result title | "Moved N items to the Trash" | "Deleted N items permanently" / "Deleted M of N items" |
| Result message | "Items stay in the Trash…" | "Freed X. These can't be put back." X is the **measured** change in available space on each volume the batch touched (`VolumeSummary.available`, read when the user confirms and after the batch). If X is below half of the estimate, it adds: "The rest is held by local snapshots or shared with other files, and comes back when macOS removes those snapshots." *(r2: ux 5)* |
| Partly deleted item | - | "Partly deleted. The rest is in the Trash as "<name>"; empty the Trash to finish." *(r2: sec 4)* |
| Items needing admin in **Clean, Uninstall and Debloat** | v1: refused, Reveal in Finder | Both modes, when the helper is present: selectable, badge "Admin". "Also happens": "macOS asks for your administrator password for N items owned by the system." (no "once", r2: ux 9). Trash mode also: "Finder may ask for your administrator password when you empty the Trash, because these belong to the system." *(r2: ux 11)* |
| Items needing admin in **Disk Map** | v1 | v1 unchanged in both modes: "Needs admin", Reveal in Finder. *(r2: sec 3a)* |

Colour: one new token `Theme.danger` (`Color.red`) for icons and fills and `Theme.dangerText` for text, built with
the existing `statusText(light:dark:)` helper at a light shade that reaches 4.5:1 on `#E5E5E5`, measured from
snapshot pixels (M-0001 verify-ux lesson), not assumed.

Measured free space is a sound basis for the result: `statfs` available space showed a 64 MiB unlink within the same
second, 63 MiB each time in 3 runs, with no local snapshot present (`df -k` before and after, scratchpad
`design-debloat-r2/`, verified-locally). Other processes writing at the same time can move the number, so the copy
says "Freed X", not "exactly".

### 1.5 History

- A permanent entry has `trashedPath == nil` (§2.5). Its batch card uses a red `xmark.bin.fill` icon and the status
  "Deleted permanently · freed X · can't be undone". No Undo button.
- The "in the Trash from Macontrol" figure counts trashed, unrestored entries only, including helper-trashed ones.
- If the batch had a restore point *(r2: ux 6)*: "A restore point was made before this:
  `com.apple.TimeMachine.<date>.local`. Rolling back returns every file on this Mac to that moment; anything newer
  is lost. macOS may have removed it since. To roll back: macOS Recovery > Restore from Time Machine."
- Items the helper moved to the Trash (`asAdministrator`, §2.5) have no Undo *(r2: sec 2)*: "N items belong to the
  system, so History can't put them back. They're in the Trash: drag them back in Finder, which may ask for your
  administrator password." The batch's Undo restores its other items and skips these.
- Empty state: "Nothing removed yet" / "Everything macontrol removes shows up here. Items moved to the Trash can be
  put back."

### 1.6 Keyboard safety (all modes)

1. No destructive button anywhere carries `.defaultAction`. Return never confirms a delete. In the sheets it does
   nothing; in the turn-on modal it cancels. Esc cancels everywhere.
2. The buttons that open a review ("Review and Clean…", "Uninstall…", "Remove…") may keep `.defaultAction`: they only
   open the sheet, which is the gate.
3. ⌘⌫ in Disk Map stays "stage", never delete.
4. Checked by a hosted-window key-event test per sheet in both modes (Return sent, nothing removed), not by review.

### 1.7 What hardcore mode does not change

Protected-path containment, never-touch areas, `SF_RESTRICTED`, locked items, identity re-check, `keep`, nested
selection, mount refusal, the Cleaner's `manual` tier (never in a bulk clean) and the in-use guard all apply
unchanged. iCloud, cloud-provider and `trashOnly` items go to the Trash (D4). Hardcore mode never skips a
confirmation sheet.

## 2. Permanent delete engine (Safety)

### 2.1 API

```swift
public enum DeletionMode: String, Sendable, Hashable, Codable { case trash, permanent }

public enum TrashOutcome {                       // one new case
    case trashed(original: URL, trashedTo: URL)
    case deleted(original: URL)                  // NEW: gone for good
    case refused(URL, RefusalReason)
    case failed(URL, message: String)
}

public struct TrashItem {                        // v1 fields unchanged
    /// NEW (r2: ux 9, sec 4). Remove this item only if nothing exists at this path when its turn comes.
    /// An app's leftovers name the app's bundle here, so no leftover is touched while the app is installed.
    public var requiresGone: URL?                // init parameter, default nil
}

extension TrashService {
    /// One batch in either mode, items in array order. `.needsAdministrator` items go to the helper in one
    /// request when `administrator` is given (§3.6).
    public func remove(_ items: [TrashItem], mode: DeletionMode, cloudConfirmed: Bool = false,
                       administrator: PrivilegedLauncher? = nil, restorePoint: String? = nil) async -> TrashReport
    // moveToTrash(_:cloudConfirmed:) stays and means remove(items, mode: .trash).
}
```

`requiresGone` is checked with `lstat` just before the item's own pre-flight. Anything at that path (the app, a link,
a new copy an updater put back) gives `.failed(url, "Not removed, because <name> is still there.")`. This is v1's
`!FileSystem.exists(plan.app.url)` rule from `Uninstaller.uninstall`, moved into the one place every route passes.

`TrashBatch` gets `let mode: DeletionMode` and keeps its whole `process` pipeline. Only its sink step changes
*(r2: ux 4, sec 4)*:
- `.trash`: `backend.moveToTrash` (v1).
- `.permanent`, not a folder: `RemovalEngine.unlink(canonical:identity:)`.
- `.permanent`, a folder: `backend.moveToTrash` exactly as in v1 (including the T-0053 identity check after the move),
  then `RemovalEngine.erase(trashed:identity:)` on the Trash URL it returned. The erase runs on the object Safety has
  just moved, found by `(st_dev, st_ino)`. The protection policy is not applied again to its Trash path: it would
  refuse `~/.Trash` and `.Trashes`, and the item has already passed it at its original path.
- A D4 item stops after the Trash move.

If the Trash move fails (a volume with no Trash), the item fails with v1's message. There is no in-place fallback
*(decision: it would bring back the half-deleted case)*. `trashedAncestor(of:)` gets its twin `deletedAncestor(of:)`,
so an item inside an already deleted folder reports `.deleted`.

### 2.2 Pre-flight: the v1 steps, plus one walk

Unchanged, in order: `requiresGone` (new, §2.1); canonicalize with `F_GETPATH`; skip kept and already covered items;
`ProtectionPolicy.refusal` (containment, never-touch, mount, flags, read-only volume, `com.apple.rootless`, cloud,
can-move); `samePlace` (no link on the way); identity against the scan; `keep` expansion.

**Trash-only rule (D4)** *(r2: sec 5)*. In `.permanent` mode an item goes to the Trash and is not erased when
`isInCloud` is true, when its walk (below) meets an `SF_DATALESS` folder, or when it equals, contains or lies inside
one of `ProtectedLocations.trashOnly`:

```
~/Library/Group Containers/group.com.apple.notes      ~/Library/Containers/com.apple.Notes
~/Library/Application Support/AddressBook             ~/Library/Calendars
~/Library/Safari                                      ~/Library/Application Support/MobileSync/Backup
```

All present here, user-owned, not `restricted` (challenge-security, verified-locally). The sheet reasons are "stored
in iCloud", "holds your notes", "holds your contacts", "holds your calendars", "holds your Safari data" and "holds
iPhone and iPad backups".

**`ProtectedLocations.systemNeverTouch` gains** *(r2: sec 3b)* `/Library/Preferences/SystemConfiguration`,
`/Library/Preferences/OpenDirectory`, `/Library/Application Support/Apple`, `/Library/Apple` and
`/Library/Developer/CommandLineTools`. All five are `root:wheel` or `root:admin` here; only `/Library/Apple` is
`restricted`, and `SystemConfiguration` carries `sunlnk`, which protects the folder but not its files (`ls -ldO`,
verified-locally). The list applies in the app and in the helper. No `apple-apps.json` path lies inside them
(feasibility-apple-apps catalog table, checked by this revision). `ProtectedLocations.swift` moves to
permanent-engine.

**Replace `lockedItem(inside:)` with `removalBlocker(inside:)` for folders in both modes.** It is the same fd-relative
walk (no link followed, stays on the volume, never lists an evicted folder) and returns the first of:

| Found inside the folder | Result |
|---|---|
| `UF_IMMUTABLE`/`UF_APPEND` entry | `.holdsLocked(relativePath)` (v1) |
| `SF_RESTRICTED`, `SF_NOUNLINK`, `SF_IMMUTABLE`, `SF_APPEND` | `.systemProtected` |
| a folder on another `st_dev` (mount point) | `.protectedLocation(path)` |
| a folder this process cannot write (`faccessat(W_OK, AT_EACCESS)`) | `.needsAdministrator` (permanent mode only: the Trash move renames only the top item, but the erase needs write access to every folder inside) |
| an `SF_DATALESS` folder | trash-only rule above |

So a permanent delete is all or nothing in the common case, and a user-owned cache holding one root-owned file goes
to the helper instead of stopping half-way.

### 2.3 The remover (`Sources/Safety/RemovalEngine.swift`)

Two entry points, one walk: `unlink(canonical:identity:)` for a non-folder at its own place (steps 1-3), and
`erase(trashed:identity:)` for a folder that the Trash sink has just moved (steps 1, 2 and 4, with the Trash folder as
the parent). Depth-first, fd-relative, single thread (feasibility-permanent facts 1, 2, 7, 8, 15):

1. `parent = open(dirname, O_RDONLY|O_DIRECTORY|O_NOFOLLOW_ANY|O_CLOEXEC)`: no link anywhere on the way.
2. `fstatat(parent, name, AT_SYMLINK_NOFOLLOW)`; `(st_dev, st_ino)` must equal the pre-flight identity, or
   `.refused(.identityChanged)` with nothing touched.
3. Not a folder: `unlinkat(parent, name, 0)`, on macOS 26 with `AT_NODELETEBUSY` behind `#available` (fact 11).
4. Folder: `openat(parent, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`, `fstat` must equal the identity. Then
   empty it: read **all** names first (never unlink while `readdir` is running), and for each entry
   `fstatat(AT_SYMLINK_NOFOLLOW)`:
   - folder on the same `st_dev` and not dataless: `openat(O_DIRECTORY|O_NOFOLLOW)`, check that the `fstat` of the
     new fd matches the `fstatat` result (a swap in between is a failure, not a follow), recurse, then
     `unlinkat(fd, name, AT_REMOVEDIR)`;
   - `openat` fails with `ELOOP`/`ENOTDIR` (swapped for a link or file): `unlinkat(fd, name, 0)` removes the link;
   - folder on another `st_dev`: failure `EXDEV`, never entered;
   - anything else: `unlinkat(fd, name, 0)`.
   Each failure is recorded as `{relative path, errno}` and the walk goes on with the siblings. Last:
   `unlinkat(parent, name, AT_REMOVEDIR)`, which fails `ENOTEMPTY` if anything was left or appeared. What is left
   stays in the Trash under the item's visible name.
5. **Never** `removefile`/`removefileat` (as root they clear `uchg`, and they walk by full path: facts 3-5),
   `FileManager.removeItem`, `rm`, `chflags`, `chmod`, `chown`. The sink audit enforces this (§3.10).
6. Only `O_NOFOLLOW[_ANY]`, `openat` and `unlinkat(AT_REMOVEDIR)` are relied on: all exist on macOS 14.
   `AT_RESOLVE_BENEATH`, `AT_UNIQUE` and `O_RESOLVE_BENEATH` do not exist on 14 (fact 9) and are not used.

`// ponytail: single thread, one fd per depth level.` Parallel subtrees (fact 19: about 2x on 150k entries) come
when a measured delete feels slow. A tree deeper than the fd limit reports `EMFILE` for what is left, safely: the rest
is in the Trash.

### 2.4 Errors → outcomes

| Situation | Outcome | Journal line |
|---|---|---|
| All removed | `.deleted(original:)` | yes, `trashedPath: nil` |
| Pre-flight refusal (any reason) | `.refused(url, reason)`, nothing touched | no |
| `requiresGone` path still exists | `.failed(url, "Not removed, because <name> is still there.")`, nothing touched | no |
| Identity differs at step 2 or 4 of `unlink` | `.refused(url, .identityChanged)`, nothing touched | no |
| Identity differs when `erase` opens the trashed copy | `.failed(url, "Moved to the Trash, but not deleted: it changed there. Empty the Trash to finish.")`, nothing erased | yes, as trashed (it is in the Trash) |
| The Trash move of an `.app` fails `EPERM` (App Management, unverified) | `.failed(url, "macOS blocked this. Allow Macontrol in System Settings > Privacy & Security > App Management.")`, nothing changed *(r2: ux 4)* | no |
| Some entries failed during `erase` | `.failed(url, "Partly deleted. N items inside could not be removed; the rest is in the Trash as "<name>". Empty the Trash to finish. First: <rel path>: <strerror>")` *(r2: sec 4)* | yes, `trashedPath: nil`: bytes were removed, History must show it, and a half-app is not worth an Undo |
| Journal line cannot be written | batch stops, like v1 (`journalError`) | - |

### 2.5 Journal and History record

```swift
public struct JournalEntry {
    public var trashedPath: String?      // CHANGED from String. nil = deleted permanently
    public var restorePoint: String?     // NEW: snapshot made before this batch, if any
    public var asAdministrator: Bool     // NEW (r2: sec 2): moved by the helper; no in-app Undo. Absent = false
    public var isPermanent: Bool { trashedPath == nil }
    public init(batch: UUID, date: Date, originalPath: String, trashedPath: String?, identity: FileIdentity,
                allocated: UInt64, restored: Bool, restorePoint: String? = nil, asAdministrator: Bool = false)
}
```

Old journals decode unchanged (`trashedPath` is present in every v1 line). `TrashJournal.entries()` keys restores on
`batch + trashedPath` and ignores permanent lines there. `undo(batch:)` **keeps its v1 signature** and skips
permanent and `asAdministrator` lines. Same fsync-per-line write.

### 2.6 Restore point (optional, never automatic)

`public enum RestorePoint { public static func create() async throws -> String }` in `Sources/Safety/RestorePoint.swift`
runs `/usr/bin/tmutil` with the argument array `["localsnapshot"]` (no shell), parses
`Created local snapshot with date: (\d{4}-\d{2}-\d{2}-\d{6})` and returns `com.apple.TimeMachine.<date>.local`.
Verified-locally by feasibility-permanent (fact 20: unprivileged, no Time Machine destination needed, 44 s here).

Every hardcore confirmation shows an **unchecked** box (no per-session state to keep) *(r2: ux 6)*:

> [ ] Create a restore point first (Time Machine local snapshot, about a minute)
> *Rolling back returns every file on this Mac to this moment; anything newer is lost. While it exists, the deleted
> items still use their space. macOS may remove it on its own. It is not a backup.*

Unchecked by default because a debloat user usually has little free space, and a snapshot pins every deleted block
until it is purged (facts 24, 25). When `VolumeSummary.available` is below 1 GB, the box is disabled with "Not enough
free space for a restore point." *(r2: ux 6. The 1 GB threshold is a decision; what `tmutil` needs is unverified. This
Mac had 117 MiB to 2.3 GiB free during these runs, `df`, verified-locally.)* If ticked: run `create()` with a progress
row, then delete, recording the name on every journal line of the batch. If it fails: "Couldn't create a restore
point: <reason>. Delete anyway?" [Cancel] [Delete Permanently] (Cancel is the default). No in-app rollback: rollback
is a whole-volume Recovery operation (fact 26), and History says how. Whether Recovery lists a `tmutil` snapshot on a
Mac with no Time Machine destination is unverified (T-0078).

### 2.7 Tests (engine)

- Every `TrashServiceTests` and `SafetyAttackTests` case that applies runs in both modes (parameterized), each
  asserting `Sandbox.tree` after == before minus the intended items (verify-safety lesson 3).
- New: symlink to an outside canary at the leaf and mid-tree; a folder swapped for a link during the walk (hook
  between list and open, as `TrashBackend` hooks do today); a mounted 20 MB APFS image inside the tree (canary on
  the image survives); a 300-level tree past PATH_MAX; a locked file deep inside (refused before anything goes);
  a root-owned file inside a user folder (fixture: a `0555` folder stands in; `needsAdministrator`); an iCloud-path
  item in permanent mode (goes to the fixture Trash).
- New in r2: a folder whose entry 500 of 1,000 fails (hook) leaves the original path gone and 500 entries in the
  fixture Trash under the folder's name, with the "Partly deleted" outcome *(sec 4)*; an `.app` whose Trash move
  fails `EPERM` (injected backend) leaves the tree unchanged with the App Management message *(ux 4)*; a leftover
  whose `requiresGone` path exists is not touched, in both modes *(sec 4)*; each `trashOnly` path goes to the
  fixture Trash in permanent mode and each new `systemNeverTouch` path is refused, one test each *(sec 3b, sec 5)*;
  `remove` runs the three passes of §3.6 in order against a routing stub, and a stub that throws `.cancelled` for a
  root-owned bundle leaves every leftover untouched, in both modes *(sec 4)*.
- Deliberate-bug proofs, one each: drop `O_NOFOLLOW` → canary test fails; skip step 2 → identity test fails; ignore
  `st_dev` → mount test fails; call `removefile` → audit fails; read-while-unlink → the 10k-entry folder test fails;
  erase in place instead of after the Trash move → the entry-500 test fails *(r2)*.
- `RestorePoint` output parser against captured `tmutil` output; the live call only with `MACONTROL_TMUTIL=1`.

## 3. Privileged helper

### 3.1 Mechanism

**(a) `NSAppleScript` → `do shell script … with administrator privileges` → bundled helper**, per
feasibility-privileged. Rejected: `SMAppService.daemon`/`SMJobBless` (needs notarization, `SMAppService.h:55`;
ad-hoc daemons fail, DTS forum threads 799910/757463), `sudo`+askpass ("not appropriate to use as API",
https://developer.apple.com/forums/thread/708765). `AuthorizationExecuteWithPrivileges` stays the documented
fallback (no shell; deprecated, Swift-unavailable), with no protocol change.

### 3.2 Bundle layout and `scripts/bundle-app.sh`

```
Macontrol.app/Contents/
  MacOS/Macontrol
  Helpers/macontrol-priv        NEW: SwiftPM product "macontrol-priv" (target PrivilegedHelper)
  Resources/…
```

`Contents/Helpers` is Apple's place for helper tools (https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle,
sourced, not re-fetched). Changes to `bundle-app.sh`:

```bash
swift build -c "$CONFIG" --product Macontrol
swift build -c "$CONFIG" --product macontrol-priv
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/macontrol-priv" "$APP/Contents/Helpers/macontrol-priv"
# Inner code first. Hardened runtime makes dyld ignore DYLD_* for the process that runs as root.
codesign --force --options runtime --identifier "${BUNDLE_ID}.priv" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/macontrol-priv"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
```

Verified-locally (first design, scratchpad `design-debloat/`): an ad-hoc binary signed with `--options runtime`
(`flags=0x10002(adhoc,runtime)`) ignored `DYLD_INSERT_LIBRARIES`; the same binary without it loaded the injected
library. `swift run Macontrol` has no bundle, so `PrivilegedLauncher.bundled()` is nil and admin items keep the v1
"Needs admin" behaviour. `$SIGN_IDENTITY` is the self-signed certificate when present (M-0045), ad-hoc otherwise.

### 3.3 Launch sequence (app side, `Sources/Safety/PrivilegedLauncher.swift`, `PrivilegedRouting.swift`)

1. `mkdtemp` `~/Library/Application Support/Macontrol/priv/<batch>.XXXXXX` (mode 0700; inside the journal folder,
   which the policy already protects). Write `request.json` (0600, `O_CREAT|O_EXCL|O_NOFOLLOW`). Compute its
   SHA-256 (CryptoKit).
2. **Environment** *(r2: sec 8)*. The first line of `Sources/Macontrol/main.swift` calls
   `PrivilegedLauncher.scrubEnvironment()`, before `NSApplication` or Dispatch starts any thread. It keeps `HOME USER
   LOGNAME TMPDIR LANG LC_* __CF_USER_TEXT_ENCODING`, sets `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and unsets everything
   else (this removes `BASH_ENV`, `ENV`, `SHELLOPTS`, `PS4`, `BASH_FUNC_*`, `DYLD_*`, `DEVELOPER_DIR`). The launcher
   only checks that the environment still matches the allowlist, and throws `.launchFailed("environment")` if not.
   feasibility-privileged fact 14 verified-locally that these variables inject code into `do shell script`'s
   `/bin/sh` even with perfect quoting. Whether the *admin* shell inherits the caller's environment is unverified; the
   scrub costs nothing either way, and it also keeps these variables away from `launchctl`, `tmutil` and `simctl`.
3. On the main actor (`NSAppleScript` is main-thread only: https://developer.apple.com/documentation/foundation/nsapplescript,
   sourced, not re-fetched), run this fixed source, passing arguments as a typed list in an `aevt/oapp` event
   exactly as feasibility-privileged's `quoteprobe.swift` did (verified-locally 21/21 hostile names byte-exact):

   ```applescript
   on run argv
       do shell script (quoted form of item 1 of argv) & " " & (quoted form of item 2 of argv) & " " & ¬
           (quoted form of item 3 of argv) with prompt (item 4 of argv) with administrator privileges
   end run
   ```

   argv = [helper path, request path, SHA-256 hex, prompt]. The prompt is data, never code:
   "macontrol needs your administrator password to move N items owned by the system to the Trash." / "… to delete
   N items owned by the system permanently." (`with prompt` is in the StandardAdditions dictionary on this Mac,
   verified-locally with `sdef`.) AppleScript error −128 → `PrivilegedError.cancelled`; any other number is the
   helper's exit status → `.helperRejected(status)`.
4. **Detach without exec** *(r2: sec 1)*. The helper validates the request in the foreground and creates
   `result.jsonl`. Then it calls `fork()` through `@_silgen_name("fork")` (Swift marks `fork` unavailable). Before the
   fork the process has started no thread: the checks, the SHA-256 and the JSON decode start no Dispatch or
   Foundation thread. The parent exits 0 at once. The child calls `setsid()`, points stdin, stdout and stderr at
   `/dev/null`, and works from the request bytes it already holds. It never opens `request.json` again and never
   execs, so a swap of the request or of the helper file after the password changes nothing. `do shell script`
   returns as soon as the output closes: verified-locally for a detached child (first design,
   `design-debloat/detach.c`: `osascript` returned in under a second, the child finished 3 s later); `fork` +
   `setsid` from Swift compiles and gives the child its own session (challenge-security,
   `challenge-security/forkprobe.swift`, `forkprobe2`, verified-locally). As root: unverified, same mechanism.
5. **Results** *(r2: sec 2)*. When `do shell script` returns, the app opens `result.jsonl` once
   (`O_RDONLY|O_NOFOLLOW`) and requires `fstat` to show a regular file with `st_uid == 0` and `st_nlink == 1` (DEBUG
   tests inject the expected uid). It then polls that fd, never the path, every 100 ms off the main actor, and turns
   each line into a `TrashOutcome` and a journal line (`asAdministrator: true` for helper-trashed items) as it arrives,
   so the sheet shows progress. The child's first line is `{"pid":N,"sha256":"…"}`, the hash it was given in argv 3.
   The app reads no line of a file whose first line names another hash: owner and link count only say root made the
   file, and a same-user hard link kept from another run is back to one link once the app unlinks its own name
   (T-0089). Every request carries a random `nonce`, so two runs of the same list never share a hash. If the first
   line has not appeared within 5 s, or the pid
   is gone (`kill(pid, 0)` → `ESRCH`) before the `done` line, every unanswered item gets
   `.failed(url, "The administrator helper stopped before it got to this.")`. Then the request folder is removed.

### 3.4 Request and result format

`request.json` (the helper is the authority; the app is not trusted):

```json
{ "version": 1, "op": "trash" | "permanent", "nonce": "<random UUID>",
  "items": [
    { "path": "/Applications/GarageBand.app", "device": 16777232, "inode": 123456, "allocated": 2100000000,
      "keep": [], "bundleIdentifier": "com.apple.garageband10" },
    { "path": "/Library/Application Support/GarageBand", "device": 16777232, "inode": 234567, "allocated": 900000000,
      "keep": [], "bundleIdentifier": "com.apple.garageband10", "requiresGone": "/Applications/GarageBand.app" } ] }
```

No `restore` op and no `restores` *(r2: sec 2)*. `bundleIdentifier` is optional: the app the item belongs to, absent
for Clean items *(r2: sec 3c)*. `requiresGone` is optional (§2.1) *(r2: ux 9, sec 4)*. JSON is enough: APFS names
are valid UTF-8. Limits: 1 MiB, 10,000 items. `result.jsonl`, one fsync'd line each: `{"pid":123,"sha256":"…"}` (from
the child; the request's SHA-256, T-0089),
then `{"index":0,"status":"trashed","to":"…"}` | `{"index":0,"status":"deleted"}` |
`{"index":0,"status":"refused","reason":"identityChanged"}` | `{"index":0,"status":"failed","message":"…"}`, and last
`{"done":true}`. Exit codes of the foreground check (`sysexits.h`): 0 detached; 65 `EX_DATAERR` malformed; 77
`EX_NOPERM` owner/mode/hash check failed; 71 `EX_OSERR` fork or result file failed.

### 3.5 Helper side (as root; `Sources/PrivilegedHelper/main.swift` is argv parsing and the fork only, the logic is `Safety.PrivilegedExecutor`)

**At entry:** clear the environment; refuse unless `geteuid() == 0` (release builds).

**Request checks, fail closed:** open the folder with `O_DIRECTORY|O_NOFOLLOW_ANY`, `fstat`: owned by a uid `U != 0`,
mode `0700`. `openat` `request.json` with `O_NOFOLLOW`, `fstat`: regular file, owner `U`, mode `0600`, size ≤ 1 MiB.
Read through the fd, SHA-256 must equal argv 3 (this binds the file to the call the user authorized: a same-user
process that rewrites the file afterwards fails here, and the child never reads it again). Decode, `version == 1`.
Home = `getpwuid(U).pw_dir`, canonicalized, owned by `U`. `result.jsonl` is created with
`openat(dirfd, …, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_APPEND, 0644)`, so a pre-placed link fails. Then the fork (§3.3
step 4).

**Per item, before any change:**
1. `PrivilegedScope.refusal(canonical:home:bundleIdentifier:)`, the root allowlist. Everything outside it is
   `.protectedLocation(path)`:
   - `/Applications/<name>.app` and `/Applications/<folder>/<name>.app` (bundles only, never `/Applications` or a
     folder in it);
   - `/Library/<F>/<item>…` with `F` ∈ {Application Support, Audio, Caches, Developer, LaunchAgents, LaunchDaemons,
     Logs, Preferences, PrivilegedHelperTools}, at least one component below `F`;
   - `/private/var/db/receipts/<id>.plist` and `…/<id>.bom`: regular files, `id` matches `^[A-Za-z0-9._-]+$`;
   - `<home>/Library/<F>/<item>…` of the requesting user (root-owned leftovers in their Library);
   - **first-component rule** *(r2: sec 3c)*: for both `/Library` forms, the first component below `F` must not
     start with `com.apple.`, `Apple` or `.`, unless it starts with the item's `bundleIdentifier` or the path lies
     inside one of `PrivilegedScope.appleContent`: the `/Library/…` paths of `apple-apps.json`, kept as a constant
     here, with a debloat-catalog test that fails when the catalog has a path the constant lacks.
2. The full v1 `ProtectionPolicy.refusal` built with `home:` and `journal:` spelled out from user `U`, never
   defaulted *(r2: sec 6)*, then `samePlace`, identity against the request, `keep`, and `removalBlocker` (as root the
   writability row never fires; locked and restricted rows still do). **The helper never clears a flag**:
   user-locked files stay refused even for root.
3. `requiresGone`: `lstat` must fail with `ENOENT`, else `.failed("Not removed, because <name> is still there.")`.
4. `/Library/LaunchDaemons/<x>.plist` *(r2: sec 11)*: read its `Label` as root, check it against
   `^[A-Za-z0-9._-]+$`, and run `/bin/launchctl` with `["print", "system/<Label>"]` (argument array, empty
   environment). Only when the output holds the line `path = <this plist's path>` does the helper run
   `["bootout", "system/<Label>"]`; exit 0 or 3 (not loaded) goes on, anything else refuses the item. Any other print
   result (no such line, another path, not loaded, a new format) skips the bootout; the file is still removed and the
   result says "It stops at the next restart." `man launchctl` says print's output "is NOT API in any sense at all"
   (verified-locally), so the parse is written to fail safe: a format change can only turn bootouts off.
5. Sink:
   - `trash`: `renameatx_np(parentfd, name, trashfd, name, RENAME_EXCL)` into `<home>/.Trash`, opened with
     `O_DIRECTORY|O_NOFOLLOW_ANY` and checked owned by `U`. On `EEXIST` retry as "Name 14.03.27.app" (Finder's
     pattern), 20 tries. Then `fstatat(trashfd, newName, AT_SYMLINK_NOFOLLOW)` must equal the checked identity;
     otherwise rename it back with `RENAME_EXCL` and report `.refused(.identityChanged)`, as v1's `putBack` does
     (T-0053) *(r2: sec 9)*. Different volume (`EXDEV`): `.failed("Only items on the startup disk can be moved to the
     Trash as administrator.")`. **Never `FileManager.trashItem` as root**: it would use root's Trash, which the user
     can neither see nor undo (feasibility-apple-apps, inferred). Ownership is **not** changed: the item stays
     `root:wheel` in the user's Trash. No Finder Put Back record exists for these, and History has no Undo for them
     (D12).
   - `permanent`: a file → `RemovalEngine.unlink`; a folder → the `trash` sink above, then `RemovalEngine.erase` on
     the trashed copy (D3). The same code the app uses.
6. Append the result line, fsync.

**F-0014:** there is no scheduled path. The launcher is built in exactly one place (`AppModel.live()`) and handed
to the Clean, Uninstall and Debloat models, which only use it from a confirmation the user pressed. `DiskMapModel`
never receives it *(r2: sec 3a)*. A test fails if `.bundled(` appears in any other file.

### 3.6 Routing: which items go to the helper, and in what order *(r2: ux 9, sec 4)*

`TrashService.remove` runs the items in array order, in three passes:
1. **In-process pass.** Each item's pre-flight and sink. Items refused with `.needsAdministrator` (and only those) are
   set aside. An item whose `requiresGone` names a set-aside item is deferred.
2. **One helper request**, if anything was set aside and `administrator` is non-nil. The app applies
   `PrivilegedScope` itself first, so an out-of-scope item is refused with a clear reason and never reaches the
   dialog. The request carries the set-aside items in order, with the batch's `mode`. Without a launcher they stay
   refused (v1).
3. **Deferred pass.** The deferred in-process items, each checking `requiresGone` again.

Outcomes replace the refusals in place. One `remove` call gives at most one dialog. In practice this routes:

| Item | Why it needs root |
|---|---|
| Apple's App Store apps in `/Applications` (`root:wheel 0755`) | moving a folder rewrites its `..`, which needs write access to the folder (feasibility-apple-apps F4, verified-locally) |
| Root-owned leftovers in `/Library/{Application Support, Caches, Logs, Preferences, PrivilegedHelperTools}` | root-owned |
| `/Library/LaunchDaemons/*.plist` (with the checked `bootout system/<label>`) | system domain |
| `/Library/LaunchAgents/*.plist` | root-owned file; macontrol boots out `gui/<uid>/<label>` as the user first (v1), then the helper removes the file |
| Apple content (`/Library/Audio/Apple Loops/Apple`, `/Library/Developer/CoreSimulator/Caches`, …) | root-owned |
| Package receipts `/private/var/db/receipts/<id>.{plist,bom}` | root-owned (same as `pkgutil --forget`) |
| Anything in the user's own Library that a root process left there | root-owned |

**Uninstaller** changes with it. A root-owned bundle is no longer a `blocker` when the uninstaller has a launcher;
`uninstall` no longer throws `.needsAdministrator` for chosen admin leftovers when it has one; its allowed-area check
adds `<systemRoot>/private/var/db/receipts/<file>`; `Leftover.isPreselected` stops excluding admin items (the UI
disables them when there is no launcher). New batch entry point: `uninstall(_ jobs: [UninstallJob], mode:)` runs the
v1 pre-checks, quits and bootouts per app (an app that fails them is skipped with its error, and the others go on),
then makes **one** `remove` call: each app's bundle followed by its leftovers, every leftover with `requiresGone` =
its bundle. The v1 two-batch code (bundle, check, leftovers) goes: `requiresGone` does its check. The single-app
`uninstall(_:leftovers:mode:)` wraps the batch.

### 3.7 Prompt frequency *(r2: ux 9)*

One helper call per user action (a clean, an uninstall, a Debloat run of any number of apps), so at most one dialog
per action. macOS's `system.privilege.admin` right has `timeout=300` and `shared=false` (verified-locally with
`security authorizationdb read`, feasibility-privileged and challenge-security). The 5-minute grace is sourced only
for the same script (TN2065, feasibility-privileged fact 12), and each call passes different argv, so a second action
within 5 minutes may ask again (unverified, T-0078 counts dialogs). The copy never says "once". The app cannot
shorten the grace; the in-app confirmation is the per-batch gate. The dialog names the count and the mode (§3.3).

### 3.8 Crash recovery

`public func recoverPrivilegedResults()` on `TrashService`, called once at launch by `AppModel.live()`: for every
`priv/*` folder whose `result.jsonl` opens (`O_NOFOLLOW`) as a regular file with `st_uid == 0` and `st_nlink == 1`
*(r2: sec 2)* and whose first line names the SHA-256 of the folder's `request.json` (T-0089), and whose helper pid
is gone, journal every result line not yet in the journal (match on batch and
original path; helper-trashed lines with `asAdministrator: true`), then remove the folder. Any other result file is
removed unread. Folders with a request and no result are removed. So a quit or crash during a root batch still
leaves an accurate History, and a planted result file adds nothing.

### 3.9 Tests (no root needed)

- `PrivilegedRequest` round trip with the 21 hostile names of `quoteprobe.swift`; oversized and malformed input →
  65; wrong mode, wrong owner, folder not 0700, request is a symlink, hash mismatch → 77. The request type has no
  `restore` op.
- `PrivilegedScope` table: allowed (`/Applications/X.app`, `/Applications/Utilities/X.app`,
  `/Library/Application Support/Vendor/X`, receipts, `/Library/Preferences/com.apple.dt.Xcode.plist` with
  `bundleIdentifier: com.apple.dt.Xcode`, `/Library/Audio/Apple Loops/Apple/x` through `appleContent`) and refused
  (`/private/etc/sudoers`, `/Library/Keychains/x`, `/Library/Extensions/x.kext`, `/Applications`,
  `/Applications/Folder`, `/private/var/db/receipts/../x`, `/private/var/db/receipts/sub/x.plist`,
  `/System/Applications/Chess.app`, another user's home, `/Library/Preferences/com.apple.loginwindow.plist`,
  `/Library/Preferences/.GlobalPreferences.plist`, `/Library/Preferences/SystemConfiguration/preferences.plist`,
  `/Library/Application Support/Apple/ParentalControls/x`).
- `PrivilegedExecutor` run in-process as the current user on a `TemporaryDirectory`, with the system root, the
  `euid` check and the result-file owner injected (**`#if DEBUG` only**: the release helper has no test flags), both
  sinks, asserting `Sandbox.tree` diffs: trash lands in the fixture home's `.Trash` with collision names; permanent
  erases after the Trash move; a swap between the check and the rename is renamed back with `identityChanged`
  *(sec 9)*; `requiresGone` holds; a LaunchDaemon with an injected `launchctl print` output is booted out only for
  an exact `path = ` match, and without one its file is removed with no bootout *(sec 11)*.
- The built `macontrol-priv` binary run directly (not as root, debug build) against a temp request: detaches, writes
  pid/result/done. **A hook rewrites `request.json` right after the foreground check; the outcomes still match the
  original request** *(sec 1)*. `kill -9` mid-batch → the app side reports `helperStopped` for the rest. A leftover
  folder with a root-owned result (injected uid) is merged by `recoverPrivilegedResults()` exactly once; a user-owned
  or hard-linked result file is ignored *(sec 2)*, and so is a root result kept from another run, live and in
  recovery, including one from a byte-identical list (T-0089, `PrivilegedAttackTests`).
- The AppleScript source equals the constant in §3.3; `scrubEnvironment()` keeps exactly the allowlist; the launcher
  throws `.launchFailed` when the environment does not match.
- A grep test: `Sources/PrivilegedHelper/**` and `Sources/Safety/Privileged*.swift` contain no
  `homeDirectoryForCurrentUser`, `NSHomeDirectory`, `applicationSupportDirectory`, `defaultJournalURL`, and no
  `ProtectedPaths.refusal(for:` or `ProtectionPolicy(` without `home:` *(sec 6)*.
- Deliberate-bug proofs: drop the scope check → the `/private/etc` case fails; drop the hash check → the rewritten
  request case fails; drop `O_EXCL` → the pre-placed-link case fails; reopen `request.json` in the child → the
  rewrite test fails *(sec 1)*; drop the first-component rule → the `loginwindow` case passes and the test fails
  *(sec 3c)*; drop the `systemNeverTouch` additions → the `SystemConfiguration` case fails *(sec 3b)*; skip the
  post-rename check → the swap test fails *(sec 9)*; **build the policy with root's home → the item
  `<home>/Library/Caches/com.apple.bird/x`, sent with `bundleIdentifier: com.apple.bird` so that the scope passes, is
  removed and the test fails** *(sec 6: the old `~/Documents` proof could not fail, because the scope refuses it
  first)*.
- **Needs a person and a password** (task verify-debloat): one real run as root on this Mac.

### 3.10 Sink audit changes (`Tests/SafetyTests/SinkAuditTests.swift`) *(r2: sec 7)*

**One forbidden list for every file under `Sources/`**: today's list for non-Safety files and the Safety-only list
merged. The per-file allowlist below sits on top of it. Each row gets a one-line sample proven to fail outside its
allowed file.

| Token | Allowed only in |
|---|---|
| `Process` | `Uninstaller/Launchd*.swift` (v1), `Uninstaller/SimRuntime.swift` (the fixed CoreSimulator `simctl` path, §4.4), `Safety/RestorePoint.swift` (`/usr/bin/tmutil`), `PrivilegedHelper/LaunchdSystem.swift` (`/bin/launchctl` `print` and `bootout`) |
| `fork(`, `"fork"` | `PrivilegedHelper/main.swift`, once (the detach) |
| `posix_spawn`, `vfork(`, `exec*(` | nowhere |
| `NSAppleScript` | `Safety/PrivilegedLauncher.swift`, exactly one `NSAppleScript(source:` |
| `unlinkat` | `Safety/RemovalEngine.swift` |
| `renameatx_np`/`renamex_np` | `Safety/TrashService.swift` (v1 undo), `Safety/TrashBatch.swift` (v1 put-back), `Safety/PrivilegedExecutor.swift` (trash sink and its rename-back) |
| `FileManager.default.trashItem(at:` | `Safety/TrashService.swift`, exactly once (v1) |
| the regex `(^\|[^\w])[fl]?ch(mod\|own\|flags)(at)?\(`, `setAttributes(`, `setResourceValue`, `removefile`, `"/bin/rm"`, `"/bin/sh"`, `osascript`, `system(`, `popen(` | nowhere |

`request.forkattr` in `ScanEngine/BulkReader.swift` is the one near-match in today's sources; it must keep passing
(code read).

## 4. Apple app debloat

### 4.1 Where

A new sidebar section **Debloat** between Uninstall and History (`SidebarItem.debloat`, ⌘5; History becomes ⌘6),
icon `scissors`. Uninstall still lists Apple apps (one app at a time, the same plan). Debloat is the many-at-once
checklist, like PureMac's cleanup review (M-0032).

### 4.2 Screen *(r2: ux 2, ux 3, ux 15)*

Trash mode, Xcode ticked and expanded (Xcode sizes from §4.4; GarageBand and the installer are illustrative):

```
Debloat                                                                  [ ] Hardcore mode
Removes Apple's App Store apps (GarageBand, iMovie, Pages, Numbers, Keynote, Xcode…) and what they
install. macOS's built-in apps are locked by macOS.
Apple's removable apps and what they install use 26.3 GB on this Mac.
─────────────────────────────────────────────────────────────────────────────────────────
APPLE APPS YOU CAN REMOVE
 [x] ▾ Xcode                       10.49 GB selected of 26.29 GB                    Admin
       [x] Xcode.app                                              3.76 GB           Admin
       [x] Simulator caches (rebuilt when needed)                 6.05 GB           Admin
       [x] Build files (DerivedData)                              0.41 GB
       [x] Xcode system resources and receipts                    0.27 GB           Admin
       [ ] Simulator devices: apps and data inside simulators     3.32 GB
       DELETED BY XCODE'S TOOL, NOT MOVED TO THE TRASH
       [ ] Simulator runtimes (iOS 26.5, watchOS 26.5)           12.43 GB
           Download them again in Xcode > Settings > Components.
       🔒  Kept by macOS: MobileDeviceDevelopment
 [ ] ▸ GarageBand                  2.1 GB on disk · its content isn't checked on a real install yet
INSTALLERS
 [ ]   Install macOS Tahoe        15.0 GB
PART OF MACOS (LOCKED)                                                          0.73 GB
 🔒    Chess                      10.8 MB    Locked by macOS
─────────────────────────────────────────────────────────────────────────────────────────
1 app, 10.49 GB to the Trash.                                                  [Remove…]
```

- **App rows start unticked, always.** §4.5's defaults apply inside an app once the user ticks it. The headline
  states what exists, never what "you can remove".
- Each row shows what its current selection frees. Content that is not selected (unverified, shared, or unticked) is
  listed under it with its size.
- The footer splits the total by what happens to it: "1 app, 10.49 GB to the Trash · 12.43 GB deleted now" when the
  runtime row is ticked in Trash mode; "1 app, frees up to 22.92 GB" in hardcore mode (runtimes preselected there).
- Rows expand to the profile items (§4.4) plus the generic leftovers `LeftoverFinder` finds, each with a checkbox,
  size, an "Admin" badge when routed to the helper, and its note.
- "Installers" = Apple-signed `Install macOS *.app` bundles (no new `AppKind`: matched by name and `anchor apple`
  signature inside `DebloatModel`).
- "Part of macOS": selecting a row shows §5's panel instead of checkboxes.
- "Remove…" opens the shared `TrashSheet` (mode-aware, §1.4) listing every item, with "Also happens" notes: apps
  asked to quit, background items stopped, "First deletes N simulator runtimes with Xcode's own tool; they can't go
  to the Trash", receipts removed, the administrator prompt (§1.4), the git/clang note (§4.4), and in Trash mode
  Finder's password on emptying.
- Sizes from `ScanEngine.measure` per item, measured lazily per row as in Uninstall. States rendered: loading,
  empty ("No removable Apple apps on this Mac"), and at 900x600.

### 4.3 Catalog: `Sources/Uninstaller/Resources/apple-apps.json`

Compiled into the signed app, never read from a user-writable place (F-0021), validated at load and in a test,
fail closed (a bad file = no profiles, and the generic leftovers still work). The example is abbreviated: the Xcode
profile's full item list is §4.4.

```json
{
  "version": 1,
  "profiles": [
    {
      "bundleIdentifier": "com.apple.dt.Xcode",
      "name": "Xcode",
      "verified": true,
      "evidence": "macOS 26.6, 2026-09-23, T-0070",
      "items": [
        { "path": "/Library/Developer/CoreSimulator/Caches" },
        { "path": "~/Library/Developer/CoreSimulator/Devices", "note": "Holds the apps and data inside your simulators." }
      ],
      "receipts": ["com.apple.pkg.Xcode", "com.apple.pkg.XcodeSystemResources"],
      "simulatorRuntimes": true,
      "neverTouch": ["~/Library/Developer/Xcode/Archives", "/Library/Developer/CommandLineTools"]
    },
    {
      "bundleIdentifier": "com.apple.garageband10",
      "name": "GarageBand",
      "verified": false,
      "evidence": "feasibility-apple-apps catalog table; not installed on the test Mac",
      "items": [
        { "path": "/Library/Application Support/GarageBand" },
        { "path": "/Library/Application Support/Logic", "sharedWith": ["com.apple.logic10", "com.apple.mainstage3"] },
        { "path": "/Library/Audio/Apple Loops/Apple", "sharedWith": ["com.apple.logic10", "com.apple.mainstage3"] }
      ],
      "neverTouch": ["~/Music/GarageBand", "~/Library/Audio/Apple Loops"]
    }
  ]
}
```

**Validation:** `path` starts with `/Library/<F>/` (`F` from §3.5's list) or `~/Library/`, has no `..`, `*`, empty
or `.` component, has at least three components (`/Library/Developer/X`), does not equal or contain a
`ProtectedPaths` root, and does not lie inside the profile's `neverTouch`; `receipts` match `^[A-Za-z0-9._-]+$`;
bundle ids are reverse-DNS; `note` is at most 200 characters. The loader lives in `AppleProfiles.swift`;
`LeftoverFinder` drops its hard-coded `contentLibraries` map and emits one `Leftover` per existing profile item with
the new evidence `.appleProfile`, and one per existing receipt `.plist`/`.bom`. Every `/Library/…` item path must also
be in `PrivilegedScope.appleContent` (§3.5), checked by a test here *(r2: sec 3c)*.

### 4.4 The Xcode profile (verified-locally by feasibility-apple-apps on this Mac)

| Item | Size here | Route | Default (inside a ticked Xcode) |
|---|---:|---|---|
| `/Applications/Xcode.app` | 3.76 GB | helper | selected |
| Simulator runtimes (`simctl runtime list -j`, `deletable: true`) | 12.43 GB | `simctl runtime delete <id>` as the user, **first**, while Xcode is installed (§4.6) *(r2: ux 1)* | hardcore mode: selected. Trash mode: not selected, under "Deleted by Xcode's tool, not moved to the Trash", note "Download them again in Xcode > Settings > Components." *(r2: ux 2)*. Another Xcode installed: never preselected, note "Also used by <name>" *(r2: sec 10)* |
| `/Library/Developer/CoreSimulator/Caches` | 6.05 GB | helper | selected (regenerates) |
| `~/Library/Developer/CoreSimulator/Devices` | 3.32 GB | in-process | not selected (note) |
| `~/Library/Developer/Xcode/DerivedData` | 0.41 GB | in-process | selected (a profile item: v1's leftover search does not look in `~/Library/Developer`) |
| `/Library/Developer/{CoreDevice, DeviceKit, PrivateFrameworks, DeveloperDiskImages, CoreSimulator/Profiles}` | 0.23 GB | helper | selected |
| Receipts `com.apple.pkg.Xcode`, `…XcodeSystemResources` | 0.04 GB | helper | selected |
| `/Library/Apple/…` (MobileDeviceDevelopment) | small | none, `SF_RESTRICTED` | shown "Kept by macOS", no checkbox |
| `/Library/Developer/CommandLineTools` | 2.07 GB | - | `neverTouch` and `systemNeverTouch`: git, clang and Homebrew use it |

**Where `simctl` really lives** *(r2: ux 1, sec 10; verified-locally by this revision)*. `xcrun --find simctl` gives
`/Applications/Xcode.app/Contents/Developer/usr/bin/simctl`, a 729-byte bash script (`file`, `head`). It sets
`DEVELOPER_DIR` from its own path, runs `"${DEVELOPER_DIR}/usr/bin/xcodebuild" -runFirstLaunch` when CoreSimulator's
`CFBundleVersion` differs from the one it expects (1051.55), and then execs
`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`. That binary is
`root:wheel` in root-owned folders and signed `com.apple.CoreSimulator.simctl`, team `59GAB85EFG` (`codesign -dv`). The
framework is one of this profile's items (`/Library/Developer/PrivateFrameworks`). So the runtime step must run before
any Xcode content goes. `SimRuntime` runs that binary at its fixed path, with an argument array and an environment of
the scrubbed allowlist plus `DEVELOPER_DIR=<plan bundle>/Contents/Developer` (what the script sets). It never uses
`xcrun` (which follows `xcode-select` and `DEVELOPER_DIR`) and never the script (bash, and a possible first-launch
install of the very framework being removed). Runtimes are CoreSimulator's, shared by every installed Xcode. Whether
the binary deletes runtimes without the script, and whether it asks for admin rights, is unverified (`--dry-run` in
T-0078).

**git and clang** *(r2: ux 8)*. When `readlink("/private/var/db/xcode_select_link")` points inside the bundle being
removed (here it points to `/Applications/Xcode.app/Contents/Developer`, verified-locally), "Also happens" says: "git,
clang and other developer tools stop working until you run `sudo xcode-select --reset` in Terminal." with a Copy
button. `--reset` "unsets any user-specified developer directory, so that the developer directory will be found via
the default search mechanism" (`man xcode-select`, verified-locally); that it then finds the Command Line Tools is
inferred (T-0078). macontrol does not switch it itself *(decision: one more root process for a line the user can
paste; add it if users ask)*.

Profiles for Logic Pro, MainStage, iMovie, Pages, Numbers, Keynote, Final Cut Pro, Motion and Compressor are
transcribed from feasibility-apple-apps' catalog table with `"verified": false`.

### 4.5 Defaults and shared content

- **App rows: never preselected** *(r2: ux 3)*. The rest applies inside an app the user ticked.
- The app bundle: selected.
- A profile item with no `note` and no `sharedWith`, in a `verified` profile: selected (evidence `.appleProfile`
  preselects).
- Simulator runtimes: §4.4 (by mode, and never with a second Xcode).
- An item with `sharedWith`: **never preselected**, installed or not. Note: "Also used by Logic Pro, which is
  installed." / "Also used by Logic Pro and MainStage (not installed)." If a sharer is installed the row also shows
  the caution colour.
- Any item of an unverified profile: not preselected, note "macontrol hasn't checked this location on a real
  install yet."
- In hardcore mode, `Containers` and `Group Containers` leftovers are not preselected, note "May hold documents you
  made in <App>." *(r2: sec 5)*
- `neverTouch` paths and v1's never-searched roots (`~/Music`, `~/Movies`, `~/Documents`, iCloud) are never listed.
- `SF_RESTRICTED` items are listed as "Kept by macOS" without a checkbox.

### 4.6 Order of a Debloat run *(r2: ux 1, ux 9, sec 4, sec 10)*

1. Plans (cached) for every ticked app.
2. **Simulator runtimes first**, if their row is ticked: `SimRuntime.delete(id)` for each, as the user, while Xcode and
   CoreSimulator are still installed. If any runtime delete fails, Xcode is skipped and reported: "Simulator runtimes
   couldn't be deleted, so Xcode was kept: without it, nothing can delete them." (Removing Xcode then would leave the
   rest stuck in SIP-restricted `AssetsV2`, feasibility-apple-apps F6.)
3. `uninstaller.uninstall(jobs, mode:)` (§3.6): quits and bootouts per app, then one `remove` call with every app's
   bundle followed by its leftovers, so **at most one administrator dialog** for the whole run. An app that fails its
   pre-checks is skipped and reported; the others still run.
4. If the dialog is cancelled or a bundle stays, the result says so. When runtimes were deleted in step 2: "Simulator
   runtimes were deleted; Xcode is still installed." *(r2: ux 1)*

### 4.7 Tests

Validator cases for every rule; every catalog `/Library` path is in `PrivilegedScope.appleContent`; a fixture system
root with an Xcode-shaped tree (the `Uninstaller` `systemRoot` pattern) planned with the expected defaults (app rows
unticked, runtime row by mode, runtimes not preselected with a second Xcode, `Containers` not preselected in hardcore
mode); shared items never preselected; `neverTouch` never listed; restricted items without a checkbox; `SimRuntime`
parsing a captured `simctl runtime list -j` and building the argv (fixed binary path, `["runtime", "delete", id]`,
`DEVELOPER_DIR` of the plan bundle); the Debloat model flow with injected `UninstallActions` and runner: runtimes
before any Xcode item (deliberate-bug proof: delete the bundle first and the test fails), a runtime failure keeps
Xcode, one `uninstall(jobs)` call per run, the cancel message, one app's failure does not stop the next; the git/clang
note only when the injected `readlink` points inside the bundle; snapshots at 900x600 and large, light and dark,
loading and empty. Fixtures that build `.app` bundles must not register them with LaunchServices
(feasibility-apple-apps lesson: 3,614 stale records).

## 5. Sealed system apps

### 5.1 Detection (`Sources/MacontrolCore/SystemIntegrity.swift`, read-only)

```swift
public struct SystemIntegrity: Sendable, Equatable {
    public var filesystemProtected: Bool     // csr_check(CSR_ALLOW_UNRESTRICTED_FS = 1 << 1) != 0
    public var authenticatedRoot: Bool       // csr_check(CSR_ALLOW_UNAUTHENTICATED_ROOT = 1 << 11) != 0
    public var rootIsSealedSnapshot: Bool    // statfs("/") has MNT_SNAPSHOT
    public var systemDevice: String?         // statfs("/").f_mntfromname minus its snapshot suffix: /dev/disk3s3s1 → /dev/disk3s3
    public var allowsSealedRemoval: Bool { !filesystemProtected && !authenticatedRoot }
    public static func current() -> SystemIntegrity
}
```

`csr_check` via `@_silgen_name`, exported by `libsystem_kernel` (verified-locally, feasibility-apple-apps D1-D3).
Any failure means protected. No subprocess.

### 5.2 SIP on (almost every Mac, and this one)

Selecting a "Part of macOS" app shows a panel, with no destructive button:

> **Chess is part of macOS** · 10.8 MB
> macOS keeps this app on a sealed, read-only system volume. No app can remove it while System Integrity Protection
> is on. All of macOS's own apps together use 0.73 GB, and macOS updates put them back.
>
> **What you can do instead**
> - Remove it from the Dock: Control-click its Dock icon, then Options > Remove from Dock.
>
> [Expert: remove system apps yourself…]

The expert button is always there, in both modes *(r2: ux 14)*: the guide runs nothing, and its own acknowledgement
box is the gate. The other alternatives in feasibility-apple-apps ("clear this app's data", "stop background
activity" via `launchctl disable`) are left out until verified (S14 shows the data is small; S15 is unverified).

### 5.3 Expert guide

A sheet, red header "Strongly not recommended", and before any command *(r2: ux 10)*:

> - This lowers your Mac's security. With protection off, iPhone and iPad apps and Apple Pay may stop working
>   (reported by others, unverified).
> - You must turn off FileVault first. Your files are not encrypted until you turn it back on, which takes hours.
> - The apps stay removed only while these protections stay off. Turning them back on brings the apps back.
> - macOS updates bring these apps back, and may then install as a full download.
> - Almost no space comes back: the previous sealed snapshot keeps the files (expected, not yet tested).
> - A mistake can leave your Mac unable to start until you reinstall macOS from Recovery.
> - **Make a Time Machine backup first.** Time Machine does not back up the system volume (expected, not yet
>   tested); the way back is the previous sealed snapshot or reinstalling macOS, which keeps your files.
>
> [ ] I have a backup and I accept these risks

Ticking reveals the steps from feasibility-apple-apps "Guide text", generated for the apps ticked in Debloat and
this Mac's `systemDevice`, each command with a Copy button, then the revert steps. **Every command uses literal
absolute paths, no shell variables**, and every path is single-quoted (`'` → `'\''`), tested with hostile names; a
test checks that every destructive line ends in `System/Applications/<X>.app'` or
`System/Applications/Utilities/<X>.app'` below the mount point *(r2: sec 12)*. Steps that are unverified say so
inline. When `allowsSealedRemoval` is true the Recovery steps are skipped and the sheet says "System Integrity
Protection and Authenticated Root are off on this Mac." The same text lives in `docs/guides/remove-system-apps.md`,
so the guide can be linked once the repo is public. **macontrol runs none of these commands.**

### 5.4 SIP and Authenticated Root off: removal through the helper (designed, gated)

The user wants this; it ships only after task verify-debloat has run the manual procedure and its revert end to end
in macOS VMs on 14, 15 and 26. Then a helper op `sealedRemove` does, as root, with argument arrays only:
re-check `SystemIntegrity.allowsSealedRemoval` in the helper; `mkdtemp` a root-owned mount point under
`/private/var/tmp`; `/sbin/mount` `["-t","apfs","-o","nobrowse", systemDevice, mnt]`; for each requested name,
require `System/Applications/<X>.app` or `System/Applications/Utilities/<X>.app` with the bundle id the app listed
(read from the mounted `Info.plist`), then `RemovalEngine` on it; `/usr/sbin/bless`
`["--mount", mnt, "--bootefi", "--create-snapshot"]`; `/sbin/umount`; report "Restart to finish". The in-app flow uses
the §5.3 warnings plus the confirmation sheet. **The `SF_RESTRICTED` waiver is a separate executor function that only
`sealedRemove` calls, compiled out with `#if MACONTROL_SEALED_REMOVE` until verification passes** *(r2: sec 12)*, so
no other caller can pass it. Nothing of this is built before verification passes.

### 5.5 What this Mac cannot verify

| Claim | Status here |
|---|---|
| `csr_check` values with SIP or Authenticated Root off | unverified (only the "on" values were observed) |
| The Recovery procedure, `bless --create-snapshot`, the revert with `--last-sealed-snapshot` | unverified; VM only |
| Space freed after removing a sealed app | unverified (inferred ~0, feasibility-apple-apps S7) |
| iPhone apps / Apple Pay with SIP off on 26 | unverified |
| The admin `/bin/sh` inheriting the caller's environment | unverified (needs a password) |
| A root rename, and a root erase, of a real App Store app passing App Management / TCC | unverified (T-0078 uses iMovie) |
| GarageBand, iMovie, iWork paths and sizes | unverified (not installed) |
| CoreSimulator's `simctl` run directly deleting runtimes; whether it prompts for admin | unverified |
| A second helper call within 5 minutes with different argv showing no dialog | unverified |
| Finder's prompt when emptying, or dragging back, a root-owned item in the user's Trash | unverified |
| Recovery listing a `tmutil` snapshot on a Mac with no Time Machine destination | unverified |
| `launchctl print system/<label>` showing a `path = ` line on 14, 15 and 26 | unverified (man page: "NOT API"); a miss only skips the bootout |
| git working after the selected Xcode is removed, and `xcode-select --reset` fixing it | inferred |

## 6. Modules for parallel builders

### 6.1 Contract changes, landed first by `debloat-contracts`

Stubs compile and keep `swift test` green; behaviour arrives with the owning module.

```swift
// Safety (stubs; owners: permanent-engine, privileged-helper)
public enum DeletionMode: String, Sendable, Hashable, Codable { case trash, permanent }
public enum TrashOutcome { … case deleted(original: URL) … }
public struct TrashItem { public var requiresGone: URL?      // + init parameter, default nil
}
public struct JournalEntry { public var trashedPath: String?; public var restorePoint: String?
    public var asAdministrator: Bool; public var isPermanent: Bool
    public init(batch: UUID, date: Date, originalPath: String, trashedPath: String?, identity: FileIdentity,
                allocated: UInt64, restored: Bool, restorePoint: String? = nil, asAdministrator: Bool = false) }
extension TrashService {
    public func remove(_ items: [TrashItem], mode: DeletionMode, cloudConfirmed: Bool = false,
                       administrator: PrivilegedLauncher? = nil, restorePoint: String? = nil) async -> TrashReport
    public func recoverPrivilegedResults()
    // undo(batch:) keeps its v1 signature (r2: sec 2)
}
public struct PrivilegedLauncher: Sendable {
    public var helperURL: URL
    public var start: @MainActor @Sendable (_ helper: URL, _ request: URL, _ sha256: String, _ prompt: String) throws -> Void
    public init(helperURL: URL, start: @escaping @MainActor @Sendable (URL, URL, String, String) throws -> Void)
    public static func bundled(_ bundle: Bundle = .main) -> PrivilegedLauncher?
    public static func scrubEnvironment()                          // NEW (r2: sec 8); stub: no-op
}
public enum PrivilegedError: Error, Sendable, Hashable { case cancelled, helperRejected(Int32), helperStopped, launchFailed(String) }
public enum RestorePoint { public static func create() async throws -> String }

// Uninstaller (owner: privileged-helper, except .appleProfile emission: debloat-catalog)
public enum LeftoverEvidence { … case appleProfile }                     // preselected == true
public struct Leftover { public var isPreselected: Bool { evidence.preselected && note == nil } }   // admin no longer excluded
public struct UninstallActions {
    public var remove: @Sendable ([TrashItem], DeletionMode) async -> TrashReport          // replaces moveToTrash
    public init(quit:bootout:remove:)
    public static func live(trash: TrashService, launchctl: LaunchctlRunner = .system,
                            administrator: PrivilegedLauncher? = nil) -> UninstallActions
}
public struct UninstallJob: Sendable { public var plan: UninstallPlan; public var leftovers: Set<URL>
    public init(plan: UninstallPlan, leftovers: Set<URL>) }                                  // NEW (r2: ux 9)
public struct UninstallBatchReport: Sendable { public var report: TrashReport; public var skipped: [URL: UninstallError] }
public final class Uninstaller {
    public init(home:applicationFolders:systemRoot:engine:trash:actions:administrator: PrivilegedLauncher? = nil)
    public var canUseAdministrator: Bool { get }
    public func uninstall(_ jobs: [UninstallJob], mode: DeletionMode = .trash) async -> UninstallBatchReport   // NEW
    public func uninstall(_ plan: UninstallPlan, leftovers selected: Set<URL>, mode: DeletionMode = .trash) async throws -> TrashReport
}

// MacontrolUI (owners: hardcore-ui; Debloat stubs: debloat-catalog; SealedAppPanel: sealed-expert)
@Observable public final class HardcoreMode { public var isOn: Bool; public var mode: DeletionMode; public init(isOn: Bool = false) }
public enum SidebarItem { case overview, diskMap, clean, uninstall, debloat, history }
// AppModel gains stored lets: hardcore: HardcoreMode, debloat: DebloatModel, administrator: PrivilegedLauncher?
// (init parameters with defaults: HardcoreMode(), .demo(), nil). DiskMapModel gets no launcher (r2: sec 3a).
@Observable public final class DebloatModel { public init(uninstaller: Uninstaller?, hardcore: HardcoreMode = HardcoreMode()); static func demo() -> DebloatModel }
struct DebloatScreen: View { init(model: DebloatModel) }
struct SealedAppPanel: View { init(app: InstalledApp, size: UInt64?) }                    // no hardcore parameter (r2: ux 14)
struct TrashSheet { var mode: DeletionMode = .trash; var restorePoint: Binding<Bool>? = nil }   // new stored params
```

Also in the contracts task: `Package.swift` (target `PrivilegedHelper` depending on `MacontrolCore`, `Safety`;
product `.executable(name: "macontrol-priv", targets: ["PrivilegedHelper"])`; `Uninstaller` gets
`resources: [.copy("Resources/apple-apps.json")]`), an empty valid `apple-apps.json`, the sink audit of §3.10, every
exhaustive `switch` updated with a minimal case, `Sources/Macontrol/main.swift` calling
`PrivilegedLauncher.scrubEnvironment()` as its first statement *(r2: sec 8)*, and `ARCHITECTURE.md` §1, §5, §7, §12
pointing here.

### 6.2 Modules

| Slug | Owns (disjoint) | Brief | Blocked by |
|---|---|---|---|
| `debloat-contracts` | `Package.swift`, `docs/ARCHITECTURE.md`, `Sources/Macontrol/main.swift`, `Tests/SafetyTests/SinkAuditTests.swift`, and the stub edits of §6.1 (ownership passes to the modules on merge) | Land every signature, the environment-scrub call and the audit first | - |
| `hardcore-ui` | `Sources/MacontrolUI/{Shell,Clean,DiskMap,Uninstall,History}/**`; `Tests/MacontrolUITests/` except `Debloat*`/`Sealed*` files | Toggle, modal, banner, per-screen copy, measured result, History, restore-point box, launcher wiring (not Disk Map) | contracts |
| `permanent-engine` | `Sources/Safety/{RemovalEngine,TrashBatch,TrashService,TrashJournal,RestorePoint,ProtectedPaths,ProtectedLocations}.swift`; `Tests/SafetyTests/` except `SinkAudit*`/`Privileged*`; `Tests/SafetyAttackTests/Permanent*.swift` | Trash-then-erase remover, `removalBlocker`, trash-only rule, `requiresGone` and the three passes, `.deleted`, journal, restore point | contracts |
| `privileged-helper` | `Sources/Safety/Privileged*.swift`, `Sources/PrivilegedHelper/**`, `scripts/bundle-app.sh`, `Sources/Uninstaller/{Uninstaller,Models,UninstallActions,LaunchdControl}.swift`; `Tests/SafetyTests/Privileged*.swift`, `Tests/SafetyAttackTests/Privileged*.swift`, `Tests/UninstallerTests/{UninstallFlow,Admin}*.swift` | Launcher, env scrub, request/result, scope, executor with fork detach, routing request, recovery, Uninstaller batch and admin path | contracts |
| `debloat-catalog` | `Sources/Uninstaller/{AppleProfiles,LeftoverFinder,AppBundle,SimRuntime}.swift`, `Sources/Uninstaller/Resources/**`, `Sources/MacontrolUI/Debloat/Debloat*.swift`; `Tests/UninstallerTests/{AppleProfile,LeftoverFinder,SimRuntime}*.swift`, `Tests/MacontrolUITests/Debloat*.swift` | `apple-apps.json`, validator, profiles in the plan, `SimRuntime`, Debloat screen and flow | contracts |
| `sealed-expert` | `Sources/MacontrolCore/SystemIntegrity.swift`, `Sources/MacontrolUI/Debloat/Sealed*.swift`, `docs/guides/remove-system-apps.md`; `Tests/MacontrolCoreTests/SystemIntegrity*.swift`, `Tests/MacontrolUITests/Sealed*.swift` | Detection, locked panel, expert guide, no destructive action | contracts |
| `verify-debloat` | `docs/research/verify-debloat.md` only | User-assisted checks: root run, App Management, Apple installs, simctl, xcode-select, Finder, Recovery, VMs; gates §5.4 | all five |

`permanent-engine` and `privileged-helper` meet at one seam: `TrashService.remove` (engine) runs the three passes of
§3.6 and calls `PrivilegedRouting.run(_:mode:launcher:)` (helper file) for pass 2, which the contracts task stubs to
return the refusals unchanged. `PrivilegedScope` (helper) reads `ProtectedLocations` (engine) through the policy. The
helper links the engine's `TrashBatch`/`RemovalEngine` through `Safety`, so the engine merges first (playbook O3),
then the helper rebases and runs its executor tests against the real engine.

### 6.3 Acceptance criteria

Common to all (playbook M-0044): full `swift test` green before ready_for_review, three runs under a watchdog when a
test file is added; every new safety check with a deliberate-bug proof in the task comment; B2 grep before changing
a public symbol; `/bin/rm -f`; release the claim.

**debloat-contracts**
1. Every signature of §6.1 exists; stubs: `remove(.permanent)` returns `.failed("Not built yet")`, routing returns
   the refusals, `bundled()` returns nil, `scrubEnvironment()` does nothing, `RestorePoint.create()` throws, Debloat
   and Sealed views are placeholders.
2. `Sources/Macontrol/main.swift` calls `PrivilegedLauncher.scrubEnvironment()` before anything else.
3. `swift build` and `swift test` green; `SnapshotTests` renders the new Debloat item.
4. The audit of §3.10: one forbidden list for every file under `Sources/` plus the per-file allowlist, with one sample
   per row proven to fail outside its file (including `fchmodat(`, `lchown(`, `setAttributes(`, `setResourceValue`,
   `fork(` outside the helper's `main.swift`, and `posix_spawn` inside the helper); `request.forkattr` still passes.
5. B2: grep every branch for the changed symbols (`TrashOutcome`, `TrashItem`, `JournalEntry.trashedPath`,
   `UninstallActions.moveToTrash`) before merging.

**hardcore-ui**
1. The toggle is inside the window (not in the toolbar overflow) on all six screens at 900x600 and 1600x1000, light
   and dark, and the banner shows while on (NSView-tree assertions, like `MinimumSizeTests`).
2. Tooltip, modal (three bullets, no checkbox), banner and §1.4 strings match this document exactly.
3. `AppModel.live()` starts with `hardcore.isOn == false`; nothing is written to `UserDefaults` (test reads the
   domain before and after toggling).
4. Return and Esc cancel the modal; Return in every confirmation sheet, in both modes, removes nothing (hosted-window
   key events).
5. A confirmation keeps the mode it opened with after the toggle changes (model test).
6. Permanent sheets show the red strip; D4 items are listed under "Moved to the Trash" with their reason and left out
   of "Frees up to X".
7. The result reports the measured change of `VolumeSummary.available` (injected before/after values), adds the
   snapshot line when it is below half the estimate, and shows the "Partly deleted" text.
8. History: a permanent batch shows its status, has no Undo, is excluded from "in the Trash"; the restore-point line
   carries the rollback clause; helper-trashed items (`asAdministrator`) have no Undo and show the Finder text, and
   the batch Undo skips them; demo data includes one permanent and one helper-trashed batch.
9. Restore-point box: unchecked by default, disabled below 1 GB available (injected), calls `RestorePoint.create`
   only when ticked (injected), failure asks before deleting.
10. With a launcher, `needsAdministrator` rows in Clean and Uninstall are selectable with the "Admin" badge and the
    sheet notes (the prompt note without "once"; Finder's password note in Trash mode); Disk Map keeps v1 "Needs
    admin" even with a launcher (`DiskMapModel` has no launcher parameter); without a launcher, v1 everywhere.
11. `Theme.dangerText` ≥ 4.5:1 measured from snapshot pixels in light mode.
12. Snapshots attached to the task.

**permanent-engine**
1. §2.7 passes, including every v1 Trash test re-run in permanent mode where it applies, with `Sandbox.tree` diffs.
2. The six deliberate-bug proofs of §2.7.
3. Old journal fixtures decode (`asAdministrator` absent → false); `undo` skips permanent and `asAdministrator`
   entries.
4. Trash-only rule: iCloud-path, dataless and each `trashOnly` item go to the (fixture) Trash in permanent mode; each
   new `systemNeverTouch` path is refused; one test each.
5. `remove` runs items in order with `requiresGone` and the three passes of §3.6 against a routing stub; a cancelled
   stub leaves every dependent leftover untouched, in both modes.
6. Entry 500 of 1,000 failing leaves the original path gone and the rest in the fixture Trash, with the message.
7. `EPERM` on an `.app` Trash move gives the App Management message and an unchanged tree.
8. A 150k-entry APFS clone tree deletes; time noted in the task (bench, not a test).

**privileged-helper**
1. §3.9 passes, with its eight deliberate-bug proofs.
2. `codesign -dv build/Macontrol.app/Contents/Helpers/macontrol-priv` shows `flags=0x10002(adhoc,runtime)` and the
   `.priv` identifier; `codesign --verify --strict --deep` passes on the app.
3. `Uninstaller.uninstall(jobs)` with injected actions: one `remove` call for N apps; every leftover carries its
   bundle as `requiresGone`; an app failing quit or bootout is skipped and the others go on; a root-owned bundle
   fixture is uninstalled through an injected launcher; a `/Library/LaunchDaemons` plist is booted out only after a
   matching `print` (argv checked through an injected runner); receipts accepted; without a launcher, v1 errors
   unchanged.
4. `recoverPrivilegedResults()` merges an orphaned root-owned result into the journal exactly once and ignores a
   user-owned or hard-linked one.
5. A test fails if `PrivilegedLauncher.bundled(` appears outside `Shell/AppModel.swift`; the request type has no
   `restore` op; the launcher throws `.launchFailed` when the environment is not scrubbed.

**debloat-catalog**
1. Validator rejects each rule of §4.3 (one case each), the shipped file passes, and every catalog `/Library` path is
   in `PrivilegedScope.appleContent`.
2. The Xcode fixture plan matches §4.4 and §4.5: app rows unticked; runtime row by mode, and not preselected with a
   second Xcode; `Containers`/`Group Containers` not preselected in hardcore mode; shared items never preselected;
   unverified-profile items unselected with their note; `neverTouch` never listed; restricted items without a
   checkbox.
3. `LeftoverFinder` no longer contains `contentLibraries`.
4. `SimRuntime` parse and argv tests (fixed CoreSimulator binary path, `DEVELOPER_DIR` of the plan bundle); live call
   gated by `MACONTROL_SIMCTL=1`.
5. Debloat flow with injected actions: runtimes before any Xcode item (reversed-order bug proof), a runtime failure
   keeps Xcode, one `uninstall(jobs)` call per run, the "runtimes were deleted; Xcode is still installed" message on
   cancel, one app's failure does not stop the next.
6. The git/clang note appears only when the injected `readlink` points inside the bundle.
7. Screen: subtitle, per-row selection sizes, footer split; snapshots at 900x600 and large, light and dark, loading
   and empty; `$TMPDIR/macontrol-tests-*` count unchanged; fixtures do not register bundles with LaunchServices.

**sealed-expert**
1. `SystemIntegrity` with an injected `csr_check`: failure → protected; `/dev/disk3s3s1` → `/dev/disk3s3`.
2. SIP-on panel copy exact; the view has no destructive button (view-tree test); the expert button is there in both
   modes.
3. The commands appear only after the acknowledgement; generated commands quote hostile names correctly (round-trip
   through `/bin/sh -c 'printf %s …'` in the test); no generated line contains `$`; every destructive line ends in the
   app's path below the mount point.
4. The risk list has the FileVault and "stay removed only while…" bullets, and S7/S13 are marked "expected, not yet
   tested".
5. SIP-off state (injected) skips the Recovery steps and says removal through macontrol waits for verification.
6. `docs/guides/remove-system-apps.md` mirrors the sheet, each step tagged verified or unverified.
7. Snapshots at 900x600 and large, light and dark.

**verify-debloat** (needs the user: a password, App Store downloads, VM images; ask before anything remote)
1. One real root run on this Mac with fixtures under `/Library/Application Support/macontrol-verify-<uuid>`: trash,
   permanent (Trash move, then erase), and a cancelled dialog that touches no leftover, in both modes; a
   `BASH_ENV`/`SHELLOPTS` canary in the app's environment creates nothing; `request.json` rewritten, and separately
   the helper file swapped, right after the foreground check: the child still acts on the original request.
2. Dialogs counted: one multi-app Debloat run, and two actions within five minutes.
3. A real, free App Store app (iMovie), in both modes, with and without App Management granted to Macontrol: record
   the errno and confirm no half-deleted app is ever left in `/Applications`.
4. GarageBand, iMovie, iWork installed: profile paths and sizes checked, `verified` flipped per profile.
5. Simulator runtimes deleted before the bundle with the CoreSimulator binary (`--dry-run` first; does it ask for
   admin?); after Xcode goes, does `/usr/bin/git` work, and does `sudo xcode-select --reset` fix it?
6. Finder: empty a Trash holding a helper-trashed root-owned bundle, and drag one back to `/Applications`; record the
   prompts.
7. `launchctl print system/<Label>` output recorded before a bootout (the `path = ` line on 26; on 14 and 15 in VMs).
8. Recovery > Restore from Time Machine: does it list a `tmutil` snapshot on a Mac with no Time Machine destination
   (VM)?
9. VMs 14, 15, 26: the §5.3 procedure and its revert; `csr_check` values with protections off; space freed. If all
   pass, open a builder task for §5.4; otherwise record why and keep it compiled out.

## 7. Risks

1. **No undo is the whole point, so the pre-flight is the product.** Review and attack rounds for
   `permanent-engine` and `privileged-helper` are not optional (retro M-0044: every high-severity v1 defect came
   from review probes, none from green suites).
2. **Same-user malware** can rewrite the app or show its own password dialog; macontrol cannot defend against that
   with ad-hoc signing (feasibility-privileged facts 6-8). After the password, nothing user-writable is read again
   (fork without exec, results read through one checked fd), so what remains is the window before the dialog, where a
   fake dialog works just as well. The helper limits a swapped request to the privileged scope and the protection
   policy.
3. **Root-owned items in the user's Trash**: Finder may ask for a password when emptying the Trash or dragging them
   back. The sheet says so before the user confirms (§1.4), and History says how to put them back (D12).
4. **Snapshots pin deleted bytes** (§2.6); the sheet says so, and the result reports what was really freed.
5. **Unverified Apple profiles** could list a wrong path; they preselect nothing, and every path still passes the
   protection policy and the privileged scope.
6. **Distribution**: an unnotarized app needs "Open Anyway" on first launch (feasibility-privileged risk 1). Not
   solved here.
7. **`launchctl print` is not API.** A format change can only turn bootouts off: the daemon keeps running until the
   next restart, and the result says so.
8. **Residual root scope.** System state whose name does not start with `com.apple.`, `Apple` or `.` (for example
   `/Library/Application Support/BTServer`, root-owned here per challenge-security) is still inside `PrivilegedScope`.
   Only leftovers the finder matched by bundle id or exact app name, and catalog paths, reach the helper (D8). If a
   probe finds a real case, tighten the rule to "starts with the item's `bundleIdentifier`, equals the app's name, or
   is a catalog path".

## Review: honesty-ux

Reviewer: challenge-honesty-ux, 2026-09-23. Lens: does the design promise anything macOS does not allow, are the
warnings and the hardcore modal clear and honest without preaching, is the default safe, would a normal user
understand what happens, does it match the PureMac/Radix direction (M-0032). Read-only probes on this Mac (macOS
26.6, SIP on); no network (not re-fetched sources are marked). Tags as in the header of this document.

**Verdict.** The defaults are right (hardcore off at every launch, never stored, Return never deletes, sealed
apps locked, unverified profiles select nothing), and the locked-panel copy is honest. Four things break a promise
the UI makes: the Xcode runtime step cannot run in the designed order (1), the default Trash mode deletes 12 GB
permanently (2), Debloat preselects a whole app (3), and "freed right away" is false while any snapshot exists,
including the restore point offered in the same sheet (5). Issue 4 is an unverified risk that the verify task, as
written, cannot detect.

| # | Severity | Issue | Concrete fix | Owner |
|---|---|---|---|---|
| 1 | High | **§4.6 runs simulator runtimes "only if the bundle is gone", but `simctl` lives only inside Xcode.app.** On this Mac `xcrun --find simctl` → `/Applications/Xcode.app/Contents/Developer/usr/bin/simctl`; the Command Line Tools have no `simctl` (`DEVELOPER_DIR=/Library/Developer/CommandLineTools xcrun --find simctl` → "unable to find utility"), and the same profile deletes `/Library/Developer/PrivateFrameworks/CoreSimulator.framework` (verified-locally). After the bundle goes, the runtime step always fails, and 12.43 GB (47% of the 26.29 GB promise) stays in SIP-restricted `AssetsV2`, which only `simctl` can remove (feasibility-apple-apps F6). | Delete the runtimes **first**, while Xcode is present, and only when their row is ticked. Then do the bundle and the leftovers. If the admin step is cancelled afterwards, say "Simulator runtimes were deleted; Xcode is still installed." The debloat-catalog test for "runtimes only after the bundle is gone" is reversed. | debloat-catalog |
| 2 | High | **The default Trash mode deletes permanently.** `simctl runtime delete` cannot go to the Trash, but in Trash mode the runtime row is preselected, the footer says "Moved to the Trash (freed once you empty it)", and the off-tooltip says "Everything macontrol removes goes to the Trash, and History can put it back". All three are false for 12.43 GB. `launchctl bootout` side effects are not undone by Undo either. | In Trash mode, leave the runtime row **unticked**, under its own heading "Deleted by Xcode's tool, not moved to the Trash". Its note: "Download them again in Xcode > Settings > Components." Split the footer total ("X to the Trash · Y deleted now"). Off-tooltip: "Files macontrol removes go to the Trash, and History can put them back until you empty it." | debloat-catalog, hardcore-ui |
| 3 | High | **Debloat preselects a whole app.** The §4.2 mockup ticks Xcode by default, and the headline reads "You can remove 26.3 GB". Xcode is a tool that someone chose to install (this Mac's owner uses git), not bloat. PureMac, the stated reference, *protects* Xcode entirely (feasibility-apple-apps F11, code read). One click on "Remove…", the default button, gets to the sheet. The mockup footer also says "2 apps" with one row ticked. | App rows start **unticked**, always. §4.5's defaults apply only inside an app the user ticked. Headline: "Apple's removable apps and what they install use 26.3 GB." Fix the mockup count. | debloat-catalog |
| 4 | High (unverified) | **App Management may stop a permanent delete halfway through an App Store app.** The Trash sink renames one folder. `RemovalEngine` unlinks every file *inside* the bundle, which macOS 13+ may treat as modifying a protected app (App Management, https://developer.apple.com/videos/play/wwdc2022/10096/, not re-fetched). `faccessat` does not see TCC, so `removalBlocker` passes and the user gets a half-deleted GarageBand.app in `/Applications`. verify-debloat item 2 uses an **ad-hoc** test app, which App Management probably does not protect (it targets notarized and App Store apps; unverified), so it cannot find this. | In verify-debloat item 2, use a real, free App Store app (iMovie), in both modes, with and without App Management granted. In permanent mode, first move a `.app` with the Trash sink (one rename), then delete the trashed copy, so a stop leaves a whole app in the Trash. Map `EPERM` on a bundle to "macOS blocked this. Allow macontrol in System Settings > Privacy & Security > App Management." | permanent-engine, privileged-helper, verify-debloat |
| 5 | Med-high | **"Freed right away" is not always true.** The modal bullet "Space is freed right away", the footer "frees about X right away", the sheet line "About X is freed right away" and the result "The space is free now" are all false while a local snapshot exists: Time Machine's hourly ones (kept about 24 h) or the restore point that the same sheet offers (feasibility-permanent facts 24-25). v1's `ReclaimEstimate.freesNow` counts clones and hard links, not snapshots (code read). With the restore-point box ticked, the sheet contradicts itself. Cloud items routed to the Trash (D4) are also counted. | Drop the bullet from the modal: it sells, it doesn't warn. Sheet: "Frees up to X". When the box is ticked: "Space comes back when the restore point is removed." In the result, report the measured change in free space (volume capacity before and after). If it is well below X, add: "The rest is held by a Time Machine snapshot and comes back when macOS removes it." Leave cloud-routed items out of X. | hardcore-ui |
| 6 | Medium | **The restore point copy leaves out what rollback costs.** Rolling back reverts the whole Data volume and loses everything made since (fact 26). Neither the box nor the History line ("Roll back from macOS Recovery > Restore from Time Machine") says so. Whether Recovery lists a `tmutil` snapshot on a Mac with no Time Machine destination (this Mac: "No destinations configured", verified-locally) is unverified. On a full disk the 44 s wait ends in a failure: this Mac had 117-373 MiB free during this review (`df`, verified-locally). | Box note: "Rolling back returns every file on this Mac to this moment; anything newer is lost. macOS may remove it on its own. It is not a backup." Add the same clause to History. Before running `tmutil`, check free space and say "Not enough free space for a restore point" up front. Add "Recovery offers the snapshot with no TM destination" to verify-debloat. | hardcore-ui, permanent-engine, verify-debloat |
| 7 | Medium | **"never deletes protected system and personal folders"** reads to a normal user as "my personal files are safe". The policy protects the folder itself (`~/Documents`) but not what is inside it (`ProtectedLocations.systemRoots`: "What is inside them may be", code read). In Disk Map, hardcore mode permanently deletes `~/Documents/thesis/`. | Modal and on-tooltip: "It still never deletes macOS itself, your top-level folders (Documents, Desktop…) or Photos libraries, locked files, or anything that changed since the scan. **Files you select inside your folders are deleted for good.**" | hardcore-ui |
| 8 | Medium | **Removing Xcode may break git and clang.** The profile keeps the Command Line Tools "because git, clang and Homebrew use it", but on this Mac `/var/db/xcode_select_link` points to `Xcode.app/Contents/Developer`. With a missing developer dir, `/usr/bin/git --version` prints "xcrun: error: missing DEVELOPER_DIR path" (verified-locally through a `DEVELOPER_DIR` proxy; the stale-link case is inferred). | "Also happens" note when `xcode-select -p` points into the bundle: "git and clang will stop working until you run `sudo xcode-select --reset`", with a Copy button. Optionally the helper runs `/usr/bin/xcode-select --switch /Library/Developer/CommandLineTools` (argument array) when the CLT exist. Add this to verify-debloat. | debloat-catalog, verify-debloat |
| 9 | Medium | **"Asks for your password once" is a promise nobody has verified.** The §1.4 note says so, and §3.6 says "the second one does not prompt". But the 5-minute grace is sourced for *the same script* (feasibility-privileged fact 12), and each call passes different argv. A Debloat run of k apps makes up to 2k helper calls, and a run longer than 5 minutes shows a dialog in the middle of it. | Make one helper request per user action: all apps and items, ordered, with an app's leftovers skipped if its bundle fails. Until verify-debloat item 1 passes, the copy reads "macOS asks for your administrator password" (no "once"). | privileged-helper, hardcore-ui, debloat-catalog |
| 10 | Medium | **The expert-guide risk list is incomplete, and some of it is stated as fact without evidence.** It does not say that FileVault must be off (S8), which leaves the Data volume unencrypted until it is back on and takes hours. It does not say that the apps stay removed only while Authenticated Root stays off: `bless --last-sealed-snapshot` "Reverts back to using the previously signed APFS root snapshot reenabling Authenticated Root" and boots the sealed snapshot that still has them (`man bless`, verified-locally; the consequence is inferred). "Almost no space comes back" (S7, inferred) and "Time Machine does not back up the system volume" (S13, unverified) are stated as facts. | Add two bullets: "You must turn off FileVault first; your files are not encrypted until you turn it back on." and "The apps stay removed only while these protections stay off. Turning them back on brings the apps back." Mark S7 and S13 "(expected, not yet tested)". | sealed-expert |
| 11 | Low-med | **Trash mode with root-owned items.** The "Finder asks for your password when emptying" note comes only in the result (Risk 3), after the user has confirmed. What Finder does when it empties a root-owned bundle is unverified. §3.5 runs "the full v1 `ProtectionPolicy`" per item, and `~/.Trash` is in `homeNeverTouch`: if that check is applied to a `restore`'s `from`, every helper Undo is refused, which breaks "History can put it back". v1's undo applies no policy (identity + `renamex_np`, code read). | Put the password-on-empty note in "Also happens". State that `restore` checks `to` against the policy and `from` only against the Trash-child rule, and add a test that a helper-trashed item undoes. Add "empty the Trash in Finder with a helper-trashed bundle" to verify-debloat. | privileged-helper, hardcore-ui, verify-debloat |
| 12 | Low | **The permanent sheet looks almost like the Trash sheet.** v1's Trash confirm buttons are already red `.borderedProminent` (`TrashSheet.swift`), and the window banner sits under the sheet. | Repeat the red strip inside the sheet header ("Permanent: skips the Trash"), keep the flame icon, and keep the "Delete Permanently" wording. | hardcore-ui |
| 13 | Low | **The turn-on modal gates twice.** An "I understand" checkbox plus a disabled button, on every launch, when every delete already has its own sheet. Five bullets, one of which sells. The user asked for a confirmation modal with a disclaimer, not a checkbox. | Keep three bullets (permanent, with no History undo; until you turn it off or quit; what the safety checks do and do not cover, per 7) and "Back up first". The red button with no shortcut is the confirmation. Drop the checkbox, or keep it only if the user asks. | hardcore-ui |
| 14 | Low | **The expert guide is gated on hardcore mode**, so reading a guide that runs nothing means switching every screen to permanent delete. | Show "Expert: remove system apps yourself…" in the locked panel at all times. Its own acknowledgement checkbox stays the gate. | sealed-expert |
| 15 | Low | **The scope of the promise is not stated where users see it.** "Like Windows debloaters" has a limit: macOS has no `Remove-AppxPackage` for built-in apps (feasibility-apple-apps answer 5). The GarageBand row shows a profile total ("2.1 GB") while ticking it frees only the bundle, because unverified content stays unticked. | Debloat subtitle: "Removes Apple's App Store apps (GarageBand, iMovie, Pages, Numbers, Keynote, Xcode…) and what they install. macOS's built-in apps are locked by macOS." Each row shows what its current selection frees, with the unselected content listed separately. | debloat-catalog |

### Resolutions (design-debloat-r2)

1. **Resolution: accepted.** Runtimes go first (§4.6 step 2, D13). This revision found more: Xcode's `simctl` is a
   bash script that execs the real binary in `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`, which is
   also a profile item (verified-locally, §4.4). So the order protects the binary too. A failed runtime delete now
   keeps Xcode, so no runtime is left stranded. The cancel message is in §4.6 step 4. debloat-catalog's test is
   reversed and gets a bug proof (§4.7).
2. **Resolution: accepted.** In Trash mode the runtime row starts unticked, under "Deleted by Xcode's tool, not moved
   to the Trash", with the download note (§4.4). The footer is split by what happens (§4.2). The off-tooltip is
   reworded (§1.2). It speaks of files only: bootouts stop background items and are listed in "Also happens".
3. **Resolution: accepted.** App rows never start ticked (§4.5, D8). The headline states what exists, and the mockup
   count and footer are fixed (§4.2).
4. **Resolution: accepted, merged with security 4 (D3).** A folder, `.app` included, is moved to the Trash with one
   rename before anything is erased (§2.1, §2.3, §3.5). `EPERM` on that move maps to the App Management message with
   nothing changed (§2.4). verify-debloat check 3 uses a real App Store app (iMovie), in both modes, with and without
   App Management (§6.3).
5. **Resolution: accepted.** The modal no longer claims the space is freed at once (§1.3). Sheets say "Frees up to X",
   plus the restore-point line when that box is ticked (§1.4). The result reports the measured change in available
   space, with the snapshot line below half. This revision verified locally that `statfs` sees an unlink within the
   same second. D4 items are left out of X.
6. **Resolution: accepted.** The box note and History state the rollback cost (§2.6, §1.5). Below 1 GB available the
   box is disabled up front (a decision: `tmutil`'s real need is unverified). The Recovery listing question is
   verify-debloat check 8.
7. **Resolution: accepted.** Modal and on-tooltip copy as proposed (§1.2, §1.3). Security 5 adds a mechanism under
   it for the most personal databases (D4).
8. **Resolution: accepted in part.** The "Also happens" note with a Copy button appears when
   `/private/var/db/xcode_select_link` points into the bundle (§4.4), and verify-debloat check 5 tests it. Not taken:
   the helper running `xcode-select --switch`. That is one more root process for a line the user can paste. Add it
   if users ask.
9. **Resolution: accepted.** One helper request per user action (D5). This needs `TrashItem.requiresGone`, the three
   passes of §3.6 and `Uninstaller.uninstall(jobs)` (§3.6, §4.6). The copy never says "once" (§1.4, §3.7).
   verify-debloat check 2 counts the dialogs.
10. **Resolution: accepted.** Both bullets are added, and S7 and S13 are marked "expected, not yet tested" (§5.3).
11. **Resolution: accepted.** The Finder note is now in "Also happens", before the user confirms (§1.4, Risk 3). The
    `restore` half is moot: security 2 drops the op. Finder's behaviour is verify-debloat check 6.
12. **Resolution: accepted.** Permanent sheets get a red strip inside the header (§1.4).
13. **Resolution: accepted.** The modal has three bullets and a back-up line, and no checkbox (§1.3, D2). The user
    asked for a confirmation modal with a risk disclaimer. The red button, with no shortcut and not the default, is
    that confirmation.
14. **Resolution: accepted.** The expert button is always in the locked panel (§5.2, D10). This matches the user's
    "a warning at most" for system apps. The guide's own acknowledgement box is still the gate.
15. **Resolution: accepted.** The subtitle states the scope, and each row shows what its current selection frees,
    with unselected content listed under it (§4.2).

**Matches the direction:** the Debloat checklist, the Admin badges and the review sheet follow PureMac's
list-and-review model (M-0032). The toolbar checkbox is not a PureMac/Radix pattern, but the user asked for it,
and the red banner keeps it visible when the toolbar is hidden. Nothing in this review asks for a new visual
language.

## Review: security

Reviewer: challenge-security, 2026-09-23. Lens: privilege escalation, injection, TOCTOU, confused deputy, a helper
other apps can call, permanent delete of the wrong thing, protected-path bypass as root, partial failure that leaves
a half-removed app. Read-only probes on this Mac (macOS 26.6, SIP on), small programs in
`scratchpad/challenge-security/`, no network (URLs not re-fetched). Tags as in the header of this document. Where the
honesty-ux review already names a problem, this review adds only the security side and says so.

**Verdict.** The core choices hold: root only for one call the user authorized, with no listening service; paths
only inside a 0600 file; fd-relative removal that never clears a flag; a root allowlist in front of the v1 policy.
Three gaps let the password dialog authorize more than the user agreed to. The detached child reads its request and
its own binary again after the password (1). `restore` lets records that any same-user process can write decide what
root moves into system folders (2). The root allowlist admits live macOS configuration (3). Each fix removes code or
narrows a rule; none adds a component.

| # | Severity | Issue | Concrete fix | Owner |
|---|---|---|---|---|
| 1 | High | **The detached child reads user-writable input again after the password.** §3.3 step 4 re-spawns the helper from `proc_pidpath` with stdin on `/dev/null`. So the root child can get its request only by opening `request.json` again, and it executes the helper file in the app bundle a second time. Both sit in folders the user owns: `priv/<batch>.XXXXXX` is 0700 and owned by the user, and a drag-installed app is user-owned (22 of 27 apps in `/Applications` here, and `build/Macontrol.app`: verified-locally). A same-user process can watch the folder with kqueue. Once the foreground hash check passes, it renames a new `request.json` into place or swaps `Contents/Helpers/macontrol-priv`. The child then runs, as root and on a real password entry, a request or a binary the user never confirmed. Risk 2 accepts a swap made before the dialog, where a fake dialog would work just as well. This window needs no fake dialog. | Detach without exec and without a second read. Parse and hash once, then `fork()`, `setsid()`, stdio to `/dev/null`. The child keeps the checked request in memory. Swift marks `fork()` unavailable ("Please use threads or posix_spawn*()"). `@_silgen_name("fork")` compiles, and the child gets its own session (verified-locally, `forkprobe.swift`, `forkprobe2.swift`). Fork before any Dispatch or Foundation thread starts; the check and the decode start none. Sink audit: `fork` is allowed only in `PrivilegedHelper/main.swift`, and `posix_spawn` nowhere in the helper. Test: a hook rewrites `request.json` after the foreground check, and the outcomes still match the original request. Bug proof: the child reopens the path, and the test fails. | privileged-helper, contracts, verify-debloat |
| 2 | High | **`restore` lets same-user records choose what root puts into system folders.** Undo sends op `restore` with a `from` (any direct child of `~/.Trash`) and a `to` (any free path in scope). The only check is against an identity that the request itself carries. Those values come from files any same-user process can write: the journal (0600, user-owned), `result.jsonl` (created by root, but in a user-owned folder, so it can be unlinked and replaced), and every `priv/*` folder that `recoverPrivilegedResults()` merges at launch. A forged batch looks like any other in History. History's Undo is one click with no sheet (`HistoryModel.undo`, code read). The password dialog names only a count, and inside the 300 s grace there may be no dialog at all (`system.privilege.admin` is `shared=false`, `timeout=300`, verified-locally; whether the grace covers a call with different argv is honesty-ux 9). Result: root renames a user-made file to, for example, `/Library/PrivilegedHelperTools/<a tool a LaunchDaemon still starts>`, and that file runs as root at the next start. Whether launchd checks who owns the program file is unverified. honesty-ux 11's fix (skip the policy for `from`) leaves this open. | Simplest: **drop op `restore` in v0.2.** Items the helper trashed get no Undo button. History says: "It's in the Trash. Drag it back in Finder; Finder asks for your administrator password." If Undo has to stay: the helper appends each root trash move to a root-owned ledger (`/Library/Application Support/Macontrol/ledger.jsonl`; folder root:wheel 0700, file 0600, opened `O_NOFOLLOW_ANY`, owner checked). `restore` then requires a ledger line with the same `(dev, ino)`, `to` equal to that line's original path, and `from` owned by root, with `st_nlink == 1` for a file (no same-user process can create a root-owned file). Undo of these items opens a confirmation sheet. In both cases the app opens `result.jsonl` once, requires `fstat` to show a regular file with `st_uid == 0` and `st_nlink == 1`, and polls that fd, never the path. Bug proof: a fixture journal line that names a user-owned file in the fixture Trash leads to no rename. | privileged-helper, hardcore-ui, contracts, verify-debloat |
| 3 | High | **The root allowlist admits live macOS configuration.** `PrivilegedScope` allows anything below `/Library/{Preferences, Application Support, Caches, LaunchDaemons, …}`. The v1 policy protects those folders but not what is inside them ("What is inside them may be", `ProtectedLocations.swift`). On this Mac the following are root-owned with no `restricted` flag, so as root they pass both gates (`ls -lO`, verified-locally): `/Library/Preferences/SystemConfiguration/{preferences,NetworkInterfaces}.plist` (the network setup), `/Library/Preferences/com.apple.{loginwindow,SoftwareUpdate,TimeMachine,mdmclient,MCX,apsd}.plist`, `/Library/Application Support/Apple/{ParentalControls,Remote Desktop,…}` and `/Library/Application Support/{ApplePushService,BTServer}`. Only `com.apple.TCC` and `SystemConfiguration/com.apple.Boot.plist` are `restricted`. §1.4 offers the Admin route on every screen, Disk Map included, so a hardcore user who right-clicks `SystemConfiguration` deletes its contents permanently as root. This is the design's own lesson ("permission checks in disguise"), one level down. `/Library/Developer/CommandLineTools` is protected only by the Xcode profile's `neverTouch`, not by the policy. | (a) The root route serves only Uninstall, Debloat and Clean-catalog items. Disk Map keeps v1's "Needs admin" with Reveal in Finder: the user asked for PureMac-style app removal, not root file browsing. (b) Add `/Library/Preferences/SystemConfiguration`, `/Library/Preferences/OpenDirectory`, `/Library/Application Support/Apple`, `/Library/Apple` and `/Library/Developer/CommandLineTools` to `ProtectedLocations.systemNeverTouch`, which applies in both contexts. (c) In `PrivilegedScope`, refuse a first component below `F` that starts with `com.apple.` or `Apple`, unless it starts with the request's `bundleIdentifier` (a new request field) or is an `apple-apps.json` path. Keep those paths as a constant in `PrivilegedScope`, with a test that every catalog path is in it. Bug proofs: drop (c) and `/Library/Preferences/com.apple.loginwindow.plist` passes; drop (b) and `SystemConfiguration/preferences.plist` passes. | privileged-helper, permanent-engine (takes `ProtectedLocations.swift` for this), hardcore-ui, debloat-catalog |
| 4 | Medium | **A permanent delete that stops halfway leaves a half-removed app.** This extends honesty-ux 4 (`.app` bundles, App Management) to every folder and to root. `RemovalEngine` empties a folder where it stands and carries on past errors. A `uchg` file that appears after the pre-flight, `EMFILE` on a deep tree, App Management, or a quit or crash mid-walk leaves a half-deleted `/Applications/X.app`, or a half-deleted `Application Support/<X>` of an app that is still installed. For a bundle, `Uninstaller.uninstall` then skips the leftovers because the path still exists (`!FileSystem.exists(plan.app.url)`, code read): the user keeps a broken app and all its data. | For a folder, permanent delete = the existing Trash move (one rename, identity checked before and after, T-0053), then `RemovalEngine` on the item in the Trash. As root: the helper's `trash` sink, then `RemovalEngine`. The original path empties at once. Whatever fails stays in the Trash under its visible name ("The rest is in the Trash; empty it to finish"), and a crash leaves the same (F-0036). The walk also runs below one parent the batch has just checked. A file stays one `unlinkat`. Keep v1's order (no leftover is touched until the bundle is gone), with a test that cancelling the admin dialog for a root-owned bundle touches no leftover, in both modes. honesty-ux 9's one-request merge must keep this order. Test: fail entry 500 of 1,000; the original path is gone and 500 entries are in the fixture Trash. | permanent-engine, privileged-helper, hardcore-ui, debloat-catalog |
| 5 | Medium | **Hardcore mode makes permanent what v1 left to the Trash, including personal databases the policy never listed.** This adds the mechanism behind honesty-ux 7's copy fix. v1's never-touch list covers Mail, Messages, Keychains, TCC and photo libraries; the rest of `~/Library` relied on the Trash as the safety net. With Full Disk Access, which macontrol asks for, hardcore mode deletes for good: `~/Library/Group Containers/group.com.apple.notes` and `~/Library/Containers/com.apple.Notes` (Notes), `~/Library/Application Support/AddressBook` (Contacts), the contents of `~/Library/Calendars` and `~/Library/Safari` (all present here, user-owned, not `restricted`: verified-locally), `~/Library/Application Support/MobileSync/Backup` (iPhone backups; the Cleaner's `manual` tier keeps them only out of bulk cleans), and app containers the Uninstaller preselects, which can hold documents made in the app. | Reuse D4's route. Add a short `trashOnly` list to `ProtectedLocations` (the paths above). Its items go to the Trash in both modes, with the sheet note "Moved to the Trash: holds your notes / contacts / …". In permanent mode, `Containers` and `Group Containers` leftovers are not preselected, with the note "May hold documents you made in <App>." One test per path. | permanent-engine, hardcore-ui, debloat-catalog |
| 6 | Medium | **The "root's home" bug proof cannot fail, and Safety's defaults mean root's home inside the helper.** §3.9's proof ("build the policy with root's home → the `~/Documents` case fails") never reaches the policy: `PrivilegedScope` refuses `~/Documents` first, so the test passes with the bug in place. Meanwhile the shared code defaults to the process's home, which in the helper is `/var/root`: `ProtectedPaths.refusal(for:home:)` and its static `defaultPolicy` (`ProtectedPaths.swift:13,25-26`), `ProtectionPolicy(home:journal:)` with `journal` defaulting to `TrashService.defaultJournalURL` (`URL.applicationSupportDirectory`, `TrashService.swift:105`), and `TrashService(home:)` (code read). One missed argument protects root's home instead of the user's, silently. | Prove it with a path that is in scope and that only the user's policy refuses: `<home>/Library/Caches/com.apple.bird/x` (Caches is in scope, `homeNeverTouch` lists it, and a policy built with root's home passes it). Add a test that `Sources/PrivilegedHelper/**` and `Safety/Privileged*.swift` contain no `homeDirectoryForCurrentUser`, `applicationSupportDirectory`, `defaultJournalURL`, or `ProtectedPaths.refusal(for:` without `home:`. The executor builds every policy with `home:` and `journal:` spelled out. | privileged-helper, permanent-engine |
| 7 | Low-med | **The sink audit cannot catch a flag or mode change in the helper.** Today `chmod(`, `chown(` and `chflags(` are forbidden only in `Sources/Safety` (`SafetySinkTests`). The list for all other files, which will include `Sources/PrivilegedHelper`, has none of them (`SinkAuditTests.swift`, code read). Both lists match substrings, so `fchmodat(` and `fchownat(` pass even in Safety. Neither lists `FileManager.setAttributes(` (`.immutable`, `.appendOnly`, `.posixPermissions`, `.ownerAccountID`) or `URL.setResourceValues` (`isUserImmutable`). Any one of these in root code clears a user's Locked flag, the one thing §3.5 says never happens. | One forbidden list for every file under `Sources`, with §3.10's per-file allowlist on top. Add the regex `(^|[^\w])[fl]?ch(mod|own|flags)(at)?\(` and the tokens `setAttributes(`, `setResourceValue`, `fork(`, `vfork(` and `"fork"` (the last three allowed only as issue 1 says). Each gets a one-line sample that is proven to fail. | contracts |
| 8 | Low | **The environment scrub runs in a live app with many threads.** §3.3 step 2 scrubs "before the first launch", when SwiftUI and Dispatch threads are already running. POSIX does not require `setenv`/`unsetenv` to be safe against a concurrent `getenv` (https://pubs.opengroup.org/onlinepubs/9799919799/functions/setenv.html, not re-fetched; whether Darwin locks is unverified). | Scrub once at the top of `Sources/Macontrol/main.swift`, before `NSApplication` starts. The launcher only checks the allowlist, and fails with `.launchFailed` when it does not hold. This also keeps `DEVELOPER_DIR` and similar variables away from `launchctl`, `tmutil` and `simctl`. | contracts (lands `main.swift`), privileged-helper |
| 9 | Low | **The helper's Trash move checks identity only before the rename.** `/Applications` is `root:admin 0775` (verified-locally), so an admin user's processes can rename entries in it between the helper's `fstatat` and `renameatx_np`, which moves by name. Whether a non-owner can rename a root-owned folder inside the same parent is unverified here. | After the rename, `fstatat(trashfd, newName, AT_SYMLINK_NOFOLLOW)` must equal the checked identity. Otherwise rename the item back with `RENAME_EXCL` and report `.identityChanged`, as v1's `putBack` does (T-0053). | privileged-helper |
| 10 | Low | **Simulator runtimes are shared by every installed Xcode, and `xcrun` picks a `simctl` from the environment.** This adds to honesty-ux 1 (delete runtimes first). `xcrun` follows `DEVELOPER_DIR` and `xcode-select`, which here points into `/Applications/Xcode.app` (verified-locally) but can name a second Xcode, for example a beta. | Run `<plan bundle>/Contents/Developer/usr/bin/simctl` by path (argument array; the bundle's identity checked first), not `/usr/bin/xcrun`. When another Xcode is installed, treat the runtimes as shared content: not preselected, with the note "Also used by <name>". Update §3.10's `Process` row. | debloat-catalog, contracts |
| 11 | Low | **Booting out a LaunchDaemon by label can stop a different daemon.** §3.5 step 3 boots out `system/<Label>`, with the label read from the plist being removed. A stale plist can carry the label of a service that another plist now defines and runs, such as a VPN or security agent after a rename. Bootout then stops that service until the next boot. How often this happens is unverified. | Run `launchctl print system/<Label>` first, and boot out only when its `path` equals this plist. Otherwise just remove the file. | privileged-helper, verify-debloat |
| 12 | Low | **Sealed guide and §5.4.** The user pastes the guide's commands into a Recovery shell, where they run as root. A generator that builds `rm -rf` from parts can land on the wrong folder when a part is empty. When §5.4 is built, a `RemovalEngine` flag that waives `SF_RESTRICTED` could be passed by any caller. | Guide: literal absolute paths only, no shell variables, and a test that every destructive line ends in `System/Applications/<X>.app'` or `System/Applications/Utilities/<X>.app'` below the mount point. §5.4: the waiver is a separate executor function that only `sealedRemove` calls, compiled out with `#if` until verify-debloat passes. | sealed-expert, verify-debloat |

### Resolutions (design-debloat-r2)

1. **Resolution: accepted.** The helper detaches by `fork()` + `setsid()`, with no exec and no second read (D6, §3.3
   step 4). The pid line now comes from the child. Sink audit: `fork` only in the helper's `main.swift`, and
   `posix_spawn` nowhere (§3.10). There is a rewrite-after-check test and a bug proof (§3.9), and verify-debloat check
   1 repeats it as root.
2. **Resolution: accepted, the simplest option.** The `restore` op is gone (D12, §3.4). Helper-trashed lines are
   journaled `asAdministrator: true` and have no Undo; History points to Finder (§1.5, §2.5). `undo(batch:)` keeps its
   v1 signature. The app reads `result.jsonl` through one fd checked for `st_uid == 0` and `st_nlink == 1` (§3.3 step
   5). Recovery merges only such files (§3.8). The forged-journal proof is moot without `restore`; a planted result
   file is tested instead (§3.9).
3. **Resolution: accepted, (a), (b) and (c).** (a): the launcher reaches only Clean, Uninstall and Debloat, and
   `DiskMapModel` has none (D8, §1.4, §3.5). (b): five folders join `systemNeverTouch` (§2.2). (c): the first-component
   rule, with a per-item `bundleIdentifier` and the `appleContent` constant (§3.4, §3.5, §4.3). (c) also refuses
   names starting with `.`, for example `/Library/Preferences/.GlobalPreferences.plist`. One gap remains: system state
   without an Apple-looking name, such as `BTServer` (Risk 8).
4. **Resolution: accepted (D3, §2.1, §2.3, §2.4, §3.5).** v1's order is kept through `requiresGone`, which both the
   in-process passes and the helper check. So the one-request merge (ux 9) still touches no leftover before its
   bundle is gone. The tests are as proposed (§2.7). A volume with no Trash fails as in v1; there is no in-place
   fallback.
5. **Resolution: accepted (D4, §2.2, §4.5).** `trashOnly` holds the six paths named here, and each gets its own sheet
   reason.
6. **Resolution: accepted, with a changed proof path.** Rule 3(c) refuses `com.apple.bird` before the policy runs,
   which would make the proposed proof unfailable again. So the proof sends that item with
   `bundleIdentifier: com.apple.bird` (§3.9). The executor spells out `home:` and `journal:` (§3.5), and a grep test
   bans the defaults.
7. **Resolution: accepted (§3.10).** There is now one list for all of `Sources/`, plus the new regex and tokens.
   `request.forkattr` in `BulkReader.swift` is the only near-match today, and it must keep passing.
8. **Resolution: accepted (§3.3 step 2).** The scrub runs on the first line of `main.swift`, which debloat-contracts
   now owns. The launcher only checks the environment.
9. **Resolution: accepted.** After the rename the helper checks the identity, and renames the item back when it does
   not match (§3.5 step 5).
10. **Resolution: accepted, adjusted.** `simctl` is run by a fixed path, but not the bundle's
    `Contents/Developer/usr/bin/simctl`. That file is a bash script that may run `xcodebuild -runFirstLaunch`, and it
    execs `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`
    (verified-locally). macontrol runs that binary directly, with the plan bundle's `DEVELOPER_DIR` (§4.4). With a
    second Xcode, runtimes are not preselected (§4.5). §3.10's `Process` row is updated.
11. **Resolution: accepted, with a parse that fails safe.** `man launchctl` says print's output "is NOT API in any
    sense at all" (verified-locally). So only an exact `path = <plist>` line allows the bootout, and anything else
    removes the file without a bootout and says the service stops at the next restart (§3.5 step 4, Risk 7).
12. **Resolution: accepted.** Guide commands use literal paths only, and a test checks every destructive line
    (§5.3). The waiver is compiled out behind `#if MACONTROL_SEALED_REMOVE` (§5.4).

**Checked, no issue.**
- Another app that launches the helper gains nothing. It needs its own administrator password, which already gives
  it root. `system.privilege.admin` is `shared=false` (verified-locally), so macontrol's grace period does not carry
  over to other processes. What remains are the windows after the password, issues 1 and 2.
- The scope strings match the kernel's spelling. `F_GETPATH` returns `/Applications`, `/Library/Application Support`
  and `/private/var/db/receipts` with no `/System/Volumes/Data` prefix (verified-locally, `getpath.c`).
- Paths with `..`, with a link on the way, or with hostile names are refused by `canonicalPath` and `samePlace` before
  scope and policy run (code read). A hard link is removed by name, so a same-user link to a root file removes only
  the link. The walk's own swaps (to a link, a mount, another volume) are caught by §2.3's `fstat` checks.
