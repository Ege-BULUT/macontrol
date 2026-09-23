# M1 decisions

Outcome of M1 research (T-0001..T-0042), as decided for v1. The full reasoning is in
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md); this page is the index with the evidence behind each call.

| # | Decision | Evidence |
|---|---|---|
| 1 | macOS 14+, Developer ID, notarized, not sandboxed; no App Store edition | topic-distribution-permissions D1-D4, M1-M2; topic-platform-constraints F1-F2 |
| 2 | SwiftPM package, one target per module, zero dependencies in v1 | scaffold `b5224eb`, `swift build && swift test` green |
| 3 | Scan: fd-relative `getattrlistbulk` on a fixed pool of blocking threads; total only from the finished tree | bench-scan-engines (dua 0.70 s fast but loses PATH_MAX subtrees, ncdu exact but serial; gdu race F-0007; F-0008, F-0009) |
| 4 | APFS extended attributes only for "frees now", not in the first pass | bench-scan-engines: +61-70% kernel CPU |
| 5 | Map number = allocated, hard links once with a deterministic owner; clones at full size in v1 | topic-size-accounting 1-16; F-0010, F-0054 |
| 6 | "Frees now" = PRIVATESIZE with the compressed, hard-link and clone-group rules | topic-size-accounting "Experiment" (deleting a clone frees ~0); F-0004 |
| 7 | Whole disk = walk `/System/Volumes/Data` once, never cross mount points | topic-size-accounting 18-21; F-0005, F-0031 |
| 8 | Compact tree: parallel arrays, no stored paths | F-0041 (943 B/node in Radix) |
| 9 | No incremental rescans or on-disk scan cache in v1 | F-0017, F-0037, F-0038, F-0045 |
| 10 | One deletion door (`Sources/Safety`), enforced by a sink-audit test | Mole sink audit; F-0002, F-0018, F-0025 |
| 11 | Move to Trash only, `FileManager.trashItem`, identity re-check, containment policy, undo journal; no permanent delete in v1 | topic-platform-constraints D1-D7; F-0012, F-0024, F-0026, F-0039, F-0050, F-0070 |
| 12 | No privileged helper in v1: root-owned items are "Needs admin", Reveal in Finder | topic-platform-constraints E1-E4, A10; F-0002, F-0055 |
| 13 | Catalog as signed JSON resource, validated fail-closed, three safety levels, generic in-use guard | F-0015, F-0021, F-0027, F-0032, F-0065 |
| 14 | Uninstaller leftovers by evidence (bundle id, container metadata, app groups, launchd program); names only as unselected hints; user-content roots never searched | F-0011, F-0022, F-0066; cask matcher oracle (bundle id + exact name ≈ 88%) |
| 15 | Uninstall order: quit, `launchctl bootout` by exact label, one Trash batch | Homebrew `ORDERED_DIRECTIVES`; F-0023, F-0067, F-0069 |
| 16 | "Remove system apps" = Apple's App Store apps only; built-ins shown as "Part of macOS" | topic-platform-constraints A1-A10 |
| 17 | FDA only; per-user probe, never the system TCC.db; poll + Relaunch fallback | topic-distribution-permissions P1-P8; F-0001 |
| 18 | Charts: byte-proportional sunburst and treemap in `Canvas`, "smaller items" group instead of dropping, CVD-checked palette | F-0016, F-0020, F-0040, F-0043, F-0049 |
| 19 | UI verification through `Macontrol --snapshot <dir>` (own-window capture, no Screen Recording permission) | verified locally, also when launched with `open` |

## Reuse policy (T-0003)

- **Study only:** GPL (Mole, MangoDisk, GrandPerspective, WinDirStat, QDirStat, Neodisk, Lemon, KnockKnock,
  MacTools at HEAD), Pearcleaner (Commons Clause) and PureMac's four Pearcleaner-derived scanning files,
  unlicensed code (dumac).
- **Adapt with a THIRD_PARTY_NOTICES entry:** Radix, OpenDisk (+ inket/FullDiskAccess), dua-cli, gdu, PureMac
  (other files), Mac Sai (BSD-3), kondo, Kudu, mac-cleanup-sh/-py, Homebrew brew and cask data (BSD-2), munki
  (Apache-2.0), MacTools DiskClean at `9197035` (Apache-2.0), varg-dev hilbert-moore treemap (MIT).
- Lineage evidence per source: comments on T-0003.

## Build plan

| Task | Module | Milestone |
|---|---|---|
| T-0043 | Scan engine | M2 |
| T-0044 | Safety (policy, Trash, journal) | M7 |
| T-0045 | Cleaner catalog | M5 |
| T-0046 | Uninstaller | M6 |
| T-0047 | App shell, Overview, onboarding, History | M3 |
| T-0048 | Disk map | M4 |
| T-0049 | Clean and Uninstall screens | M3 |

UI tasks build against the scaffold contracts and demo data, so none is blocked on core work.

## Open, for the user

See "Decisions the user must confirm" in the architect's hand-off: license, bundle id and Developer ID,
privileged helper, permanent delete, default scan scope, clone dedup in the map.
