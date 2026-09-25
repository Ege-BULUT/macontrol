# Changelog

What changed in each release. Releases before 1.0 are previews.

## 0.2.0, unreleased, preview

macontrol can now delete permanently, remove what belongs to the system, and take Apple's optional apps off your Mac. Everything still goes to the Trash unless you turn on hardcore mode.

### New

- Hardcore mode: a checkbox in the toolbar on every screen. Off, the default at every launch, removals go to the Trash. Turning it on opens a warning you confirm first, and a red banner stays on every screen while it is on. Every permanent removal still has its own confirmation, with a red "Delete Permanently" button that Return never presses.
- Some items go to the Trash even in hardcore mode: anything in iCloud Drive or another cloud folder, and your notes, contacts, calendars, Safari data and iPhone and iPad backups. The confirmation lists them apart, with the reason.
- Restore point: the hardcore confirmations in Clean, Uninstall and the Disk Map can make a Time Machine local snapshot first. It is never automatic, and it is offered only for items on the startup disk.
- Administrator removals: Clean, Uninstall and Debloat can now remove items owned by the system, such as Apple's App Store apps and leftovers in `/Library`. macOS shows one administrator password dialog per removal, and a helper inside the app checks every item again as root before it acts. The Disk Map still marks these items "Needs admin".
- Debloat, a new section (⌘5): remove Apple's optional apps (Xcode, GarageBand, Logic Pro, MainStage, iMovie, Pages, Numbers, Keynote, Final Cut Pro, Motion, Compressor) with the content they install. No app starts ticked. For Xcode, its simulator runtimes are deleted first, with Xcode's own tool.
- Apps that are part of macOS say why macOS keeps them. An expert guide explains how to remove them yourself in Terminal, with the risks, and how to undo it. macontrol never removes them.
- History shows permanent deletions, partly deleted batches and restore points.

### Changed

- Releases are signed with the macontrol certificate instead of ad hoc, so macOS should keep your Full Disk Access grant through future updates. Updating from 0.1.x asks for it one more time.
- History moves to ⌘6.
- Uninstall shows each app's file name instead of its localized name for apps macOS doesn't protect: asking macOS for the localized name registered every scanned bundle with LaunchServices.

### Fixed

- A Trash result where nothing moved no longer says the items stay in the Trash.

### How it was tested

- 583 automated tests, including an attack suite that tries link swaps, hostile names, replayed helper results and rewritten requests against the permanent remover and the administrator helper. The helper's tests run it as the current user on temporary folders.
- The Xcode profile was checked against a real Xcode 26.6 install on macOS 26.6. The simulator runtime step was run only with `--dry-run`.
- The release build was signed and checked with `codesign`, but not launched.

### Known limits

- The administrator helper has not run as root yet. The first real run, with an administrator password on a real Mac, is the next verification step (T-0078). Until then, treat administrator removals as the least tested part of this preview.
- The Debloat profiles for GarageBand, Logic Pro, MainStage, iMovie, Pages, Numbers, Keynote, Final Cut Pro, Motion and Compressor are not checked against real installs yet, so none of their content starts ticked.
- Debloat's hardcore confirmation has no restore point box yet, and its "Frees up to" includes simulator runtimes that are listed only in its notes (T-0086).
- A hardcore confirmation's title counts items that still go to the Trash, such as your Safari data. The list shows them apart, under "Moved to the Trash" (T-0085).
- Items the helper moved to the Trash can't be put back from History. Drag them back from the Trash in Finder, which may ask for your password.
- That Full Disk Access survives an update is checked against the signature macOS stores, not yet through a real update.
- Apple Silicon only. Requires macOS 14 or later. Not notarized: the first launch needs Open Anyway.
- While an iOS Simulator is running, Clean skips the caches it cannot inspect.

## 0.1.1, 24 September 2026, preview

### New

- Uninstall: sort the app list by name (A to Z, Z to A), date added (newest or oldest first) or size (largest or smallest first). Date added is when the app arrived in its folder, or its creation date when that is missing. Under a size sort, apps are measured in the background, 3 at a time.
- Uninstall: filter All, User or System, with a count on each. System means Apple's apps (`com.apple.*`) and the sealed system apps. The filter works together with search.
- The chosen sort and filter are kept between launches. Keyboard: ⌥⌘1 to ⌥⌘3 pick the filter, ⌃⌥⌘1 to ⌃⌥⌘6 pick the sort.

### Changed

- Each filter has its own empty state, with a Show All Apps button. Empty states now fill the pane, so the search field stays at the top.

### Fixed

- An app whose size walk was cancelled (its row scrolled away, or you left the size sort) is measured again, instead of staying last with no size.

## 0.1.0, 23 September 2026, preview

The first preview: disk cleanup and disk space visualization in one native macOS app.

### What works

- Overview: disk usage at a glance, with a Full Disk Access onboarding that continues by itself once access is granted.
- Disk Map: sunburst and treemap, drill into any folder, breadcrumbs and back and forward, inspector, Reveal in Finder, Quick Look, and a Discard Pile to stage items before removing them.
- Clean: caches, logs and developer data from a validated catalog. Each item is labelled Safe, Review or Manual, and only Safe items are preselected. Anything changed in the last 10 minutes or held by a running app is skipped.
- Uninstall: apps with their leftovers, matched by bundle identifier with evidence. Data shared with another app is never preselected.
- History: every removal is journaled and can be put back.
- Scanning: a parallel `getattrlistbulk` engine. Hard links and clones count once, so totals match the ground truth exactly.

### Safety

Everything goes to the Trash. Protected locations (your documents, keychains, cloud drives, system folders) are refused. Items are checked again right before they move, so a file swapped for a link after the scan is not touched.

### Known limits

- Apple Silicon only. Requires macOS 14 or later.
- Not notarized: the first launch needs Open Anyway.
- Ad hoc signed, so Full Disk Access has to be granted again after installing a new version.
- Root-owned items and Apple's App Store apps (GarageBand, iMovie, iWork) are marked "Needs admin" and cannot be removed yet.
- While an iOS Simulator is running, Clean skips the caches it cannot inspect.
