<div align="center">

<img src="docs/assets/icon.png" width="128" height="128" alt="macontrol app icon">

<h1>macontrol</h1>

<p><strong>See where your disk space went, and get it back safely.</strong><br>
A native macOS app that maps your disk and cleans it up, with every removal going to the Trash first.</p>

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)](#install)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-6E56CF)](#install)
[![License: MIT](https://img.shields.io/badge/license-MIT-2EA043)](LICENSE)
[![Release: v0.1.0 preview](https://img.shields.io/badge/release-v0.1.0%20preview-F59E0B)](https://github.com/Ege-BULUT/macontrol/releases/tag/v0.1.0)

**[Download](https://github.com/Ege-BULUT/macontrol/releases/tag/v0.1.0)** · [Features](#features) · [Safety](#safety) · [Build from source](#build-from-source)

</div>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/disk-map-sunburst-dark.png">
  <img src="docs/assets/screenshots/disk-map-sunburst-light.png" alt="The Disk Map: a sunburst of the home folder, with the inspector and the folder's contents on the right and two items waiting in the Discard Pile">
</picture>

> [!NOTE]
> **0.1.0 is a preview.** It runs on Apple Silicon Macs with macOS 14 or later, it is not notarized yet, and it never deletes anything permanently: whatever it removes goes to the Trash.

## Why macontrol

Most disk tools either show you where the space went or offer to clean it up. macontrol does both in one window, on one scan engine and one safety layer.

- **See it.** A sunburst or a treemap of your home folder, the whole disk or any folder, sized by what each item takes up on disk.
- **Free it.** Caches, logs and developer leftovers from a vetted catalog, and apps together with the files they leave behind.
- **Trust the numbers.** Hard links count once, folders it cannot read say "not scanned" instead of 0 B, and every confirmation tells you how much emptying the Trash will actually free.
- **Change your mind.** Every removal goes to the Trash and into a journal. History puts a whole batch back in one click.

## Features

### Disk Map

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/disk-map-treemap-dark.png">
  <img src="docs/assets/screenshots/disk-map-treemap-light.png" alt="The Disk Map as a treemap: Library, Pictures, Movies, projects, Downloads and Music as nested rectangles with their sizes">
</picture>

- **Sunburst or treemap** over the same scan. Scan your home folder, the startup disk, or any folder with ⌘O.
- **Proportional to bytes.** Area and angle follow size on disk. Items too small to draw are grouped into one "N smaller items" entry that lists them, so nothing silently disappears.
- **Explore.** Drill into folders, go back and forward, follow the breadcrumb up. The inspector shows size on disk, logical size and share of the folder and of the scan, with Reveal in Finder and Quick Look.
- **Discard Pile.** Stage items (they turn hatched on the map), then review them together before anything moves.
- **Keyboard first.** Arrow keys move the selection, Return opens, Esc or ⌘↑ goes up, ⌘[ and ⌘] go back and forward, Space opens Quick Look.
- **Readable colours.** Every pair of top-level colours stays distinct under deuteranopia and protanopia, and a test keeps it that way.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/disk-map-review-dark.png">
    <img src="docs/assets/screenshots/disk-map-review-light.png" width="560" alt="The review sheet: moving 2 items to the Trash frees about 22.3 GB once the Trash is emptied, while 3.6 GB stays in use by clones, snapshots or other hard links">
  </picture>
  <br>
  <sub>The review says what emptying the Trash will free, and what stays in use because clones, snapshots or other hard links share it.</sub>
</p>

### Clean

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/clean-dark.png">
  <img src="docs/assets/screenshots/clean-light.png" alt="Clean: app caches, logs and developer data grouped by category, each item labelled Safe, Review or Manual with its size">
</picture>

- **A vetted catalog** of 27 rules, compiled into the app: browser caches (Safari, Chrome, Firefox, Edge, Brave, Arc), Xcode build data, device support files and simulator caches, package manager caches (Homebrew, npm, Yarn, pnpm, pip, Cargo, Go, Gradle, Maven, CocoaPods, Carthage, SwiftPM), app caches and logs.
- **Safe, Review, Manual.** Only Safe items are preselected. Review items wait for you. Manual items (iPhone and iPad backups, Xcode archives, macOS installer leftovers) show their size and a Reveal in Finder button, and are never cleaned in bulk.
- **Hands off live data.** Anything changed in the last 10 minutes, or belonging to an app that is running, is skipped and the reason is shown.
- **Rules fail closed.** Every rule is checked when the catalog loads. A pattern that reaches outside the folders the catalog is meant for drops the whole rule.

### Uninstall

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/uninstall-dark.png">
  <img src="docs/assets/screenshots/uninstall-light.png" alt="Uninstall: an app with its leftovers grouped by the evidence that ties them to it, and a Needs admin item with Reveal in Finder">
</picture>

- **Leftovers with evidence.** Files named with the app's bundle identifier in the places apps keep data (Application Support, Caches, Preferences, Containers, Saved Application State, logs and more), sandbox containers that name the app, and group containers from its entitlements. Each group says why it matched.
- **Cautious by default.** Folders that only share the app's name are shown but not preselected. Data that another installed app also uses is never preselected.
- **In the right order.** The app is asked to quit (never force-quit) and its own background agents are stopped first. Then the app and the leftovers you chose go to the Trash as one batch, so a single Undo brings everything back.
- **Honest about Apple's apps.** Apps that are part of macOS live on the sealed system volume and are listed with the reason no app can remove them. Apple's App Store apps and root-owned files show "Needs admin" with Reveal in Finder for now.

### Overview and History

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/overview-dark.png">
        <img src="docs/assets/screenshots/overview-light.png" alt="Overview: disk capacity, the largest folders in the home folder, and how much is safe to clean">
      </picture>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/history-dark.png">
        <img src="docs/assets/screenshots/history-light.png" alt="History: two batches, one in the Trash with an Undo button and one already put back">
      </picture>
    </td>
  </tr>
  <tr>
    <td><strong>Overview</strong> shows capacity, the largest folders in your home and how much is safe to clean. Purgeable space appears as a dated note and is never counted as free.</td>
    <td><strong>History</strong> lists every batch macontrol moved, what it frees once you empty the Trash, and an Undo button that puts the batch back.</td>
  </tr>
</table>

## Performance

The scan engine walks folders in parallel with `getattrlistbulk`, opening each folder relative to its parent, so trees nested deeper than `PATH_MAX` are still measured. It backs off in Low Power Mode and when the Mac runs hot. `mcscan` is the same engine as a command-line tool, measured here against two fast scanners on a warm cache (hyperfine, 5 timed runs):

| Tree | macontrol | ncdu -t8 | dua |
|---|---|---|---|
| Fixture, 311k items | **0.68 s**, exact | 1.58 s, exact | 0.60 s, 8.4 MB short |
| `~/projects`, about 850k items | 2.10 s | 2.88 s | 1.95 s |

The fixture is built to be hard: hard links, clones, deep chains and an unreadable folder. "Exact" means the allocated total matches its ground truth to the byte. On `~/projects` all three tools agree to the byte. dua is a little faster, but it misses hard-linked data on the fixture. macontrol keeps the whole tree in memory for the map: about 75 bytes per item on the fixture.

Measured on an Apple M1 (8 cores, 8 GB, macOS 26.6) while another process kept one core busy (load average 5.5 to 8.4), so compare the tools with each other rather than with your own Mac. Method and raw data: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Safety

macontrol is built to be boring about your files:

- **Trash only.** Removals go through macOS's own Move to Trash. Nothing is deleted permanently, and macontrol never empties the Trash: the space comes back when you do.
- **Undo journal.** Every moved item is recorded in `~/Library/Application Support/Macontrol/trash-journal.jsonl`, readable only by you. History puts a batch back as long as it is still in the Trash and its original place is free.
- **Checked again at the last moment.** Right before an item moves, its identity is compared with what the scan saw. A file that was replaced, or swapped for a link, since the scan stays where it is.
- **Protected places.** Your home folder, Desktop, Documents, Downloads, Pictures, Movies and Music, `/Applications`, `/Library`, and system folders are never trashed, nor is any folder that contains them. Keychains, `~/.ssh`, `~/.gnupg`, Mail, Messages, photo libraries, privacy (TCC) data, cloud sync state and `/System` are off limits entirely, contents included.
- **Cloud needs consent.** Items in iCloud Drive or other cloud storage folders need an extra confirmation, because removing them removes them on every device.
- **No admin powers.** There is no privileged helper and no password prompt. Root-owned items are marked "Needs admin", with Reveal in Finder.
- **One door.** Only the Safety module can move files. A test fails if any other source file deletes, moves or renames files, runs a script or launches a process (the uninstaller's `launchctl` call is the one exception). An attack suite tries link swaps in the middle of a batch, hostile file names, locked files and paths deeper than `PATH_MAX`.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/clean-results-dark.png">
    <img src="docs/assets/screenshots/clean-results-light.png" width="560" alt="Clean results: five items moved to the Trash, one not moved because it changed since the scan">
  </picture>
  <br>
  <sub>One cache changed after the scan, so it was left alone.</sub>
</p>

## Install

1. Download **Macontrol-0.1.0.zip** from the [latest release](https://github.com/Ege-BULUT/macontrol/releases/tag/v0.1.0) and unzip it.
2. Move **Macontrol.app** to Applications.
3. Open it. macOS blocks the first launch because the app is not notarized yet: open **System Settings › Privacy & Security** and click **Open Anyway**.
4. Allow **Full Disk Access** when asked. macontrol walks you through it and continues by itself once access is on.

Without Full Disk Access the app still works. Mail, Messages, Safari, cookies and the Trash then show as "not scanned" instead of as smaller numbers.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/full-disk-access-dark.png">
    <img src="docs/assets/screenshots/full-disk-access-light.png" width="440" alt="The Full Disk Access onboarding: open System Settings, turn on Macontrol, come back">
  </picture>
</p>

**Requirements:** an Apple Silicon Mac with macOS 14 Sonoma or later.

**Known limits in 0.1.0**

- The app is ad-hoc signed, so Full Disk Access has to be granted again after installing a new version.
- Root-owned items and Apple's App Store apps (GarageBand, iMovie, iWork) are shown as "Needs admin" but cannot be removed from the app yet.
- While an iOS Simulator is running, Clean skips the caches it cannot inspect.

## Build from source

You need Xcode 26 (Swift 6.2). There are no third-party dependencies.

```sh
git clone https://github.com/Ege-BULUT/macontrol.git
cd macontrol
swift build              # build the app and the mcscan tool
swift test               # run the tests
scripts/bundle-app.sh    # release build, wrapped and ad-hoc signed as build/Macontrol.app
open build/Macontrol.app
```

Full Disk Access is tied to the app's signature, and an ad-hoc signature changes with every build. Set `SIGN_IDENTITY` to an Apple Development identity to keep the grant across rebuilds.

```sh
# Allocated size of a folder, in bytes, from the same engine the app uses
swift run -c release mcscan ~/Downloads

# Every screen as PNG, light and dark, with demo data
build/Macontrol.app/Contents/MacOS/Macontrol --snapshot /tmp/shots
```

How the pieces fit together, and why: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Roadmap

- [ ] Hardcore mode: permanent delete, behind an explicit confirmation
- [ ] Admin deletions through a privileged helper
- [ ] Removing Apple's optional apps and their content libraries
- [ ] A live map that fills in while the scan runs
- [ ] Intel and universal builds
- [ ] Notarized builds with in-app updates

## Acknowledgements

macontrol was designed after studying two MIT-licensed apps: [PureMac](https://github.com/momenbasel/PureMac) for cleanup and [Radix](https://github.com/colinvkim/Radix) by Colin Kim for disk visualization.

Two lists are adapted with credit: the protected system and home folders come from [Homebrew](https://github.com/Homebrew/brew) (BSD-2-Clause), and the cloud-provider paths from PureMac (MIT). Both license texts are kept in [`Sources/Safety/ProtectedLocations.swift`](Sources/Safety/ProtectedLocations.swift). Scan speed is measured against [dua](https://github.com/Byron/dua-cli) and [ncdu](https://dev.yorhel.nl/ncdu).

## License

[MIT](LICENSE) © 2026 Ege BULUT
