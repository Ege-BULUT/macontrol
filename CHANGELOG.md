# Changelog

What changed in each release. Releases before 1.0 are previews.

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
