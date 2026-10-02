# Research sources

The reports in `research/reports/sources/` and the probes in `research/bench/` read third-party code
from `research/sources/`, which is gitignored. This list is what that folder held on 2026-10-02, so it
can be rebuilt. Each repo was a `git clone --depth 1`; check out the commit shown to match the reports.

| Folder | Repository | Commit | Commit date |
|---|---|---|---|
| `137137137-opendisk` | https://github.com/137137137/OpenDisk | `6e3f1f7b7675` | 2026-09-22 |
| `Byron-dua-cli` | https://github.com/Byron/dua-cli | `cf596189fddf` | 2026-09-22 |
| `KSXGitHub-parallel-disk-usage` | https://github.com/KSXGitHub/parallel-disk-usage | `c30e46f16478` | 2026-08-09 |
| `adventdevinc-kudu` | https://github.com/AdventDevInc/kudu | `0ef4292b2c3b` | 2026-09-22 |
| `alienator88-pearcleaner` | https://github.com/alienator88/Pearcleaner | `7724df7111bf` | 2026-06-22 |
| `bootandy-dust` | https://github.com/bootandy/dust | `ae5c770d8431` | 2026-09-16 |
| `colinvkim-radix` | https://github.com/colinvkim/Radix | `14a76df4fe62` | 2026-09-19 |
| `dundee-gdu` | https://github.com/dundee/gdu | `848a5ddb2b00` | 2026-09-21 |
| `ggbond268-mactools` | https://github.com/ggbond268/MacTools | `bf6550aec055` | 2026-09-22 |
| `harry0703-mangodisk` | https://github.com/harry0703/MangoDisk | `19e55d2bb86b` | 2026-09-22 |
| `healeycodes-dumac` | https://github.com/healeycodes/dumac | `1ffbe3c38d10` | 2025-08-07 |
| `homebrew-brew` | https://github.com/Homebrew/brew | `3f12c3ee9d23` | 2026-09-22 |
| `homebrew-homebrew-cask/repo` | https://github.com/Homebrew/homebrew-cask | `0e47c3acf113` | 2026-09-23 |
| `iliyami-macsai` | https://github.com/iliyami/MacSai | `2c9ec771ae58` | 2026-09-22 |
| `mac-cleanup-mac-cleanup-py` | https://github.com/mac-cleanup/mac-cleanup-py | `ba4d6ef1e7d2` | 2025-10-04 |
| `macpaw-permissionskit` | https://github.com/MacPaw/PermissionsKit | `dc4487686036` | 2026-09-21 |
| `momenbasel-puremac` | https://github.com/momenbasel/PureMac | `bef6083ffda4` | 2026-09-23 |
| `mrkai77-loop` | https://github.com/MrKai77/Loop | `df26d565e07c` | 2026-09-06 |
| `munki-munki` | https://github.com/munki/munki | `28d92fef2ef0` | 2026-08-24 |
| `ncdu` | https://code.blicky.net/yorhel/ncdu.git | `1b3d0a670e73` | 2025-10-24 |
| `objective-see-knockknock` | https://github.com/objective-see/KnockKnock | `914f2c0c2d3f` | 2026-09-15 |
| `sharkdp-diskus` | https://github.com/sharkdp/diskus | `90196e950017` | 2026-02-14 |
| `shundhammer-qdirstat` | https://github.com/shundhammer/qdirstat | `88a577f942a7` | 2026-09-20 |
| `sourceforge-net-p-grandperspectiv-source` | https://git.code.sf.net/p/grandperspectiv/source | `3e0088ca8dab` | 2026-09-14 |
| `sunknudsen-guides` | https://github.com/sunknudsen/guides | `da98691fd9e3` | 2026-03-16 |
| `sveinbjornt-searchfs` | https://github.com/sveinbjornt/searchfs | `3afcfc349d52` | 2026-09-04 |
| `tbillington-kondo` | https://github.com/tbillington/kondo | `1d351ca80b3d` | 2026-01-28 |
| `tencent-lemon-cleaner` | https://github.com/Tencent/lemon-cleaner | `7ff8676f1dbe` | 2026-05-08 |
| `thaw-app-thaw` | https://github.com/thaw-app/Thaw | `46a306a9a2fc` | 2026-09-22 |
| `tkslucas-neodisk` | https://github.com/tkslucas/Neodisk | `b26a08c7b2e2` | 2026-09-07 |
| `tw93-mole` | https://github.com/tw93/Mole | `a7fa8dd60f61` | 2026-09-23 |
| `windirstat-windirstat` | https://github.com/windirstat/windirstat | `da13ad6c8f01` | 2026-09-23 |

Folders that were not clones:

- `homebrew-homebrew-cask/cask.json`: https://formulae.brew.sh/api/cask.json fetched 2026-09-23 07:43 UTC
  (`last-modified: Wed, 23 Sep 2026 07:42:02 GMT`). The API only serves the current file, so a new fetch
  will differ from the one the reports and `Tests/UninstallerTests/CaskOracle.swift` used.
- `daisydisk/`: pages saved from daisydiskapp.com (home, blog, guide, appcast) and the DaisyDisk cask on
  2026-09-23, for `research/reports/sources/daisydisk.md`.
- `alienator88-pearcleaner-repro/`: a transcription of Pearcleaner code, kept out of git because of the
  Commons Clause (see `research/reports/sources/alienator88-pearcleaner.md`).
