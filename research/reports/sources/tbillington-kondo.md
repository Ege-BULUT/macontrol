# Source deep dive: kondo (tbillington/kondo)

- **Task:** T-0020, researcher `dive-tbillington-kondo`, 2026-09-23.
- **Clone:** `research/sources/tbillington-kondo` at `1d351ca` (2026-01-28 23:21 +1100, "dont remove .venv for python (#182)"). Paths below are relative to that clone unless marked otherwise.
- **Unmerged branch:** `discovery-rework` at `eab2099` (2025-04-21). I read it through `gh api .../contents?ref=discovery-rework` and did not clone it. Paths from it are marked "(rework)".
- **"Verified":** I ran the official **v0.9 release binary** (`kondo-aarch64-apple-darwin.tar.gz`, ad-hoc linker-signed) on this Mac (macOS 26.6), always in dry-run mode `-n`. No Rust toolchain is installed here, so I built nothing. `-n` never deletes: `kondo/src/main.rs:255-258` sets `clean_project = false`, and clap makes `-n` conflict with `--all` (`main.rs:62`).
- **Probe:** `research/bench/tbillington-kondo/probe.sh` (synthetic home, 7 cases). Output is in `research/bench/tbillington-kondo/results-2026-09-23.txt`.

## Facts

| Field | Value | Source |
|---|---|---|
| URL | https://github.com/tbillington/kondo (no homepage), not a fork | `gh api repos/tbillington/kondo` |
| License | MIT, "Copyright (c) 2020 Trent Billington". Each crate also says `license = "MIT"`. | `LICENSE`, `kondo/Cargo.toml`, `kondo-lib/Cargo.toml`, `kondo-ui/Cargo.toml` |
| Stars | 2 413 | `gh api repos/...` (2026-09-23) |
| Created / last commit / last push | 2020-01-27 / `1d351ca` 2026-01-28 on `master` / 2026-04-24 (dependabot branches) | `gh api repos/...`, `/commits` |
| Releases | v0.9 2026-01-23, v0.8 2023-12-19, v0.7 2023-07-06. The release assets are CLI only (6 targets). No kondo-ui build is published (`deploys.yaml` builds `BIN: kondo` only). | `gh api .../releases`, `.github/workflows/deploys.yaml:9` |
| Language / size | Rust. `kondo-lib/src/lib.rs` 639 lines, `kondo/src/main.rs` 409, `kondo-ui/src/game.rs` 778. About 1.8k lines in total. | `wc -l` |
| Deps | lib: `walkdir 2`, `ignore 0.4.25`. CLI: `clap 4`, `clap_complete 4`, `console 0.15`. UI: `bevy 0.18` (feathers widgets, experimental), `rfd 0.17.2`. | the three `Cargo.toml` files |
| Distribution | brew, MacPorts, winget, pacman, and cargo from source | `README.md:62-118` |
| Open issues / PRs | 34 open issues and 12 open PRs (`open_issues_count` 46). The themes are under Known problems. | `gh api .../issues?state=open&per_page=50` |

**What the license lets us do:** MIT, so we may copy both code and data if we keep the copyright and permission notice. The only part worth copying is the *data*: marker files and artifact-folder names (`kondo-lib/src/lib.rs:9-119`). None of the Rust code fits a native Swift app. The table came in through PRs from many contributors (see `CHANGELOG.md`), all under the repo's MIT license. I found no sign that it was copied from another tool (unverified beyond reading the CHANGELOG). If we import the names, credit them in `THIRD_PARTY_NOTICES` (for T-0003).

## Summary

kondo is a small cross-platform CLI, with an optional GUI. It finds software projects by marker files and deletes their build-artifact folders. It covers 24 project kinds: 23 `ProjectType` variants plus a React Native variant of Node. They are identified by 25 marker constants, and 63 artifact-folder entries are listed across the per-type arrays (`lib.rs:9-94`). The CLI streams projects as it finds them. For each one it prints the artifact folders with sizes and a "last modified" age, then asks `y/n/a/q`. Its features are dry run (`-n`), an age filter (`-o 3M`), ignore dirs (`-I`), clean all (`-a`), quiet mode (`-q`, requires `-a`), same filesystem (`-s`), follow symlinks (`-L`), a single-key prompt, and shell completions (`main.rs:24-68`).

For macontrol it is **a seed list for the "developer junk" category, and a set of cautionary tales**. Its detection and deletion model is exactly what macontrol must not copy:
- A project is any folder with a marker file.
- An artifact is any subfolder with a listed name.
- Deletion is permanent, with `fs::remove_dir_all`.

Its own README says "Kondo is *essentially* `rm -rf` with a prompt" (`README.md:66`). Three concrete defects, all verified here, are filed on the analysis board:
- **F-0033:** it walks `~/Library` and package stores. `kondo -n ~/Library` offered 47 tool-owned "projects" on this Mac, including pnpm global installs. The real-world trigger is #191, where it broke Zed's language server.
- **F-0034:** discovery stops at the first marker. A stray `.py` file hides every project below it, and a Cargo + Node folder cleans only one of the two.
- **F-0035:** rules match names only. A git-tracked `build/`, Unreal `Saved/` autosaves and, in v0.9, `.venv` are all offered like `node_modules`.

The maintainer acknowledges the discovery problems (#111, #175). An unmerged `discovery-rework` branch has the right shape: per-kind trait objects, every kind checked on every folder, only artifacts pruned, and a work-stealing parallel walk. It has been idle since 2025-04.

## Architecture

- **Cargo workspace** with three crates (`Cargo.toml:1-4`). `default-members = ["kondo"]`, and the release profile uses `panic = "abort"`, `lto = "thin"` and `strip` (`Cargo.toml:9-15`).
  - `kondo-lib`: the whole engine, in one file. It holds the `ProjectType` enum with marker and artifact constants (`lib.rs:9-147`), `Project` with `artifact_dirs`, `size`, `last_modified`, `size_dirs` and `clean` (`lib.rs:162-330`), the discovery iterator `ProjectIter` (`lib.rs:361-456`), `dir_size` (`lib.rs:505-513`), and formatting helpers.
  - `kondo`: the CLI, `main.rs`. It runs three threads connected by std `mpsc` channels:
    - a **discover** thread (`main.rs:158-216`) → `sync_channel(5)` (`main.rs:352`)
    - the **main-thread prompt** (`main.rs:228-324`) → unbounded channel
    - a **delete** thread (`main.rs:218-226`, `375`)
    
    Discovery runs ahead of the user by at most 5 projects, and deletions run while scanning continues. When the user presses `q`, the receiver is dropped, and the discover thread stops at its next `send` (`main.rs:203-214`).
  - `kondo-ui`: the GUI, `game.rs`, on the **Bevy 0.18 game engine** (ECS, experimental "feathers" widgets, dark theme only; `game.rs:24-70`). It uses a `rfd` folder picker, background `std::thread`s feeding an `mpsc` that an Update system drains (`game.rs:416-483`), and `AsyncComputeTaskPool` for deletions (`game.rs:358-369`). The UI was switched from `druid 0.7` to Bevy in `e72d891` (2026-01-28, #180), so the v0.9 tag still ships the druid UI source.
- **UI/engine split:** clean. Both frontends only call `kondo_lib::scan`, `Project::{size, size_dirs, last_modified, clean}` and `dir_size`. `kondo_lib::clean(&str)` (`lib.rs:536-585`) is public but **has no caller** in the repo (`grep -rn "clean(" kondo kondo-ui kondo-lib`). Its private copy of the marker table has already drifted: it lacks Gradle, Unreal, Jupyter, Python, .NET and Turborepo.
- **Rework branch (unmerged):**
  - A `Project` trait with `is_project`, `is_root_artifact`, `root_artifacts`, `name` and `project_focus`, dispatched through `enum_dispatch` over one file per kind (`kondo-lib/src/project.rs:18-50`, `project/{rust,node,cmake,unity,godot,unreal}.rs`, rework).
  - Names come from parsing manifests: `Cargo.toml` via `cargo_util_schemas`, `package.json` via serde, `CMakeLists.txt` via `cmake_parser` (rework `project/rust.rs:59-64`, `node.rs:17-23`, `cmake.rs:33-49`).
  - A crossbeam-deque work-stealing search (`search.rs:12-223`, rework).
  - A ratatui TUI (`kondo/src/widgets/*`, rework).
  - A `path-trie` crate.
  - `TestDirectoryBuilder` fixtures (`kondo-lib/src/test.rs`, rework).

## Scanning

- **API:** the `walkdir` crate, single-threaded, depth-first (`lib.rs:488-495`). For every directory it yields, `ProjectIter` calls `read_dir()` **again** to look for marker files (`lib.rs:387-397`). Every non-project directory is therefore listed twice: once by kondo, and once more by walkdir when it descends.
- **Detection (`lib.rs:393-452`):**
  - The first regular file in readdir order that matches a marker decides the type. Markers are exact names (`Cargo.toml`, `package.json`, `pom.xml`, `Podfile`, ...) or suffixes (`.uproject`, `.ipynb`, **`.py`**, `.csproj`/`.fsproj`).
  - `.csproj` is split into Godot, Unity or .NET by checking for `project.godot` or `Assembly-CSharp.csproj` (`lib.rs:432-443`).
  - Node becomes "React Native" if the folder has an `ios` or `android` subdir (`lib.rs:478-480`).
  - After a match the walk calls `skip_current_dir()`, so it never looks inside a project. According to CHANGELOG 0.3 this made discovery 97.5 % faster, and it also avoids treating the packages inside `node_modules` as projects. The cost is F-0034: nested projects, multi-type folders, and trees masked by one stray `.py` file are all missed.
- **Exclusions:**
  - Names that start with `.` are skipped (`lib.rs:357-359, 383-386`).
  - `-I` dirs: the help text claims they are pruned (`main.rs:29`: "Will also prevent recursive traversal within"), but `discover` only filters the *results* by path prefix (`main.rs:169`). The walk still descends into them. You also cannot ignore a single artifact folder, because the filter compares against the project path.
  - Nothing excludes `~/Library`, bundles or tool stores (F-0033).
- **Sizes:**
  - `dir_size` sums `metadata().len()` of regular files (`lib.rs:505-513`). That is the **logical size**, not the allocated size.
  - Hard links are counted once per link. Verified: two pnpm-style `node_modules` that link one 4 MiB store file are offered as 4.0 MiB each (8 MiB), while deleting both frees 0 B, because the store keeps the inode (`probe.sh` case 5; `stat` shows 3 links). That is F-0010's class, and the evidence went on T-0020 instead of a new finding.
  - APFS clones count at full size (F-0004's class), and sparse files at their logical length.
  - Symlinks are not followed by default (since 0.6, #61/#63). With `-L`, sizes include the link targets, but deletion removes only the link. Rust's `remove_dir_all` does not follow a top-level symlink: https://doc.rust-lang.org/std/fs/fn.remove_dir_all.html.
  - Mount points are crossed unless `-s` is given.
- **Age filter:** `last_modified` walks the **whole project again** with `ignore::WalkBuilder` and takes the newest mtime (`lib.rs:209-228`). That walker honours `.gitignore` and skips hidden files by default, so gitignored artifacts do not count as recent activity, which is a nice side effect. The cost is two to three walks per project (artifact sizes, `last_modified`, and discovery), all serial on the discover thread. Parallelism is issue #8, open since 2020. Issue #99 reports a bogus "72 years ago" (cause unverified).
- **Memory:** everything streams. The walkdir stack is O(depth) and at most 5 projects are buffered. No tree is kept, so there is nothing to drill into later.
- **Progress / cancel:** there is no progress counter. Projects simply appear as they are found. `q` stops the scan (see Architecture). Deletions that are already queued still finish, because `process_deletes` drains the channel.
- **Speed (verified, informal):** `kondo -n ~/Library` took 5.1 s wall (0.16 s user, 2.0 s sys) on this Mac. That is fast only because it stops at every "project" it finds there.

## Deletion & rules

- **Rules are code, not data.** They are `const` arrays plus two `match` blocks per kind (`lib.rs:9-119, 162-195, 282-314, 402-445`). Adding a kind means touching 5 places. The CLI help lists 17 of the 23 kinds (`main.rs:18-23`: "Below needs updating every time a new project type is added!"), and the unused `clean(&str)` copy has drifted (see Architecture).
- **Deletion:**
  - `Project::clean` checks `path.exists()` and then calls `fs::remove_dir_all` for each listed name (`lib.rs:316-329`). It is **permanent**. There is no Trash (#96, open since 2023-07), no quarantine and no journal. That class is F-0012.
  - Errors are printed with `eprintln!` and then ignored. #97 ("Directory not empty") is a concurrent writer, such as rust-analyzer, refilling `target/` during the delete.
  - Rust std's `remove_dir_all` has resisted symlink races since 1.58.1 (CVE-2022-21658, https://blog.rust-lang.org/2022/01/20/cve-2022-21658.html). That is one good property kondo gets for free.
- **Freed bytes are claimed, not measured.** `process_deletes` returns `(project, artifact_bytes)` whatever `clean()` did (`main.rs:218-226`). The summary "Bytes deleted" sums those scan-time sizes (`main.rs:396-397`). A failed or partial delete still counts in full, and hard-linked or cloned bytes count even though they are not freed.
- **Protections:**
  - A per-project prompt, `-n` dry run, and `-o` age filter. The default is to answer, not to delete.
  - Nothing else guards the delete: no git-tracked check, no generator signature, no content check, no protected-path list. That is F-0035. The contrast is Mole's `purge_artifact_has_authored_content` (tw93/Mole@a7fa8dd `lib/clean/project.sh:506-532`).
  - `.venv` was removed from the Python list in `1d351ca` after user feedback, but that change is not in v0.9: the v0.9 tag still lists it (`lib.rs:76` @v0.9), and the v0.9 binary offers it (verified, `probe.sh` case 6).
- **Privilege escalation:** none. kondo runs as the user, and EACCES is simply printed.
- **Risky entries in the table** (`lib.rs:35-94`):
  - `build`, used by CMake, Gradle and Pub. CMake's build dir name is only a convention (#120, 9 comments).
  - `bin` (.NET), `vendor` (Composer), `Pods` (CocoaPods). Teams sometimes commit these.
  - Unity `Library`, `Build` and `Builds`.
  - Unreal `Saved`, which holds autosaves, config and save games.
  - The React Native heuristic, where any `ios` or `android` folder next to `package.json` adds `ios/Pods`, `ios/build`, `android/build` and more.
  
  None of these carries any weight or warning in the UI.

## UI

- **CLI:** plain `println!` with a tree glyph per artifact folder, plus the `y/n/a/q` prompt (`main.rs:244-310`). `a` switches to "clean all remaining" without asking again. `stdin().read_line(..).unwrap()` and `read_key().unwrap()` (`main.rs:271, 275, 285`) panic on a closed stdin, and with `panic = "abort"` the process aborts. That is minor and unverified at runtime.
- **GUI (kondo-ui, Bevy):**
  - A left column lists projects as text buttons with the name, type, size and status. "Sort by Name", "Sort by Size" and "Select Directory" sit on top.
  - The right column shows the selected project: path, type, total size, artifact size, a per-folder list with an "(Artifact)" tag, and a **"Delete Artifacts" button with no confirmation** (`game.rs:335-371`).
  - **Main-thread work:** selecting a project calls `size_dirs` inside an ECS Update system (`game.rs:265`). That walks every subfolder of the project, including `node_modules`, on the frame thread.
  - Each incoming project despawns and rebuilds the **whole list** (`game.rs:386-404`), which is O(n²) as results stream in.
  - There is no reveal in Finder, no multi-select, no chart or map, no light theme, and no macOS package (#23 has been open since 2020).
  - Visual quality is basic. It is not a UI reference for macontrol.

## Tests & quality

- **One unit test in the default branch:** `print_elapsed` (`lib.rs:597-639`). Discovery, sizing and deletion have no tests. Issue #7 "Add tests/integration tests" has been open since 2020-01-28, and PR #98 "Add a simple test" since 2023.
- **CI:** `cargo test --all` on ubuntu (`.github/workflows/tests.yaml`), and `cargo fmt --check` plus `clippy -D warnings` on PRs (`lint.yaml`). There is no macOS test job.
- **Rework branch:** it has `TestDirectoryBuilder` and per-kind tests (rework `kondo-lib/src/test.rs`, `project/rust.rs:83-125`).
- **Code:** small and readable, with idiomatic error-tolerant iterators. The weak spots:
  - the duplicated, drifting tables
  - the help-text drift
  - `// TODO does this need to exist as is??` on `dir_size` (`lib.rs:504`)
  - errors swallowed with `filter_map(ok)` throughout, so unreadable folders vanish without a trace

## Known problems

Grouped from the open issues (2026-09-23):
- **Detection is wrong or incomplete:**
  - #175: a `.py` file masks projects (verified, F-0034).
  - #29 and #117: no nested projects.
  - #111: the "Discovery Rework" meta issue.
  - #149: Unity projects detected as .NET, 5 comments.
  - #105 and #108: Python detection needs a root `.py` file, and `__pycache__` is cleaned only at the root.
  - #120: CMake build dirs with other names.
  - #55: "`kondo .` does not work inside $HOME", 14 comments. This is likely the same masking problem (unverified).
- **Safety:**
  - #191: deleted Zed's `node_modules` under `~/Library/Application Support`. Verified, generalised as F-0033.
  - #182: `.venv` deleted. Fixed on master but not released.
  - #96: no Trash support.
  - #97: "Directory not empty" during deletes.
  - #195 and #150: requests for an allow/block list and an ignore marker.
- **Feature requests:** Go (#187), uv (#188, PR #194), `.next` (#176), home-directory package-manager caches (#166), system-level cleaning (#94), Makefile (#121), sort/filter (#164), and deferring to `cargo clean` and similar tools (#122, where the maintainer leans no).
- **Maintenance:** releases are rare (v0.8 → v0.9 took 25 months), the rework branch has been idle for 17 months, and there are 12 open PRs, some from 2021-2023.

## Reuse table

| Component | Decision | Paths | Reason |
|---|---|---|---|
| Marker → artifact table (24 kinds, 63 folder entries) | improve | `kondo-lib/src/lib.rs:9-119` | MIT, broad, contributed by users of each ecosystem. Convert it to macontrol's JSON dev-rules file with `verify` + `tier` (F-0035). Drop `*.py` as a project marker (F-0034). Merge it with Mole's purge list (GPL, study only; `purge_shared.sh:18-70`) and npkill (MIT, unverified). Add a THIRD_PARTY_NOTICES entry. |
| Kind disambiguation (Unity/Godot/.NET by sibling file; React Native by `ios`/`android`) | study | `lib.rs:432-443, 478-480` | The idea is right: the more specific kind wins a shared name. Express it as rule data (`requires_sibling`), and use a stronger React Native signal (`react-native` in `package.json` dependencies, unverified). |
| Node rule that excludes Unity packages by reading `package.json` → `unity` | take (idea) | `kondo-lib/src/project/node.rs:25-48` (rework) | A cheap content check that stops UPM packages (Unity Package Manager) from being treated as Node projects. It is the kind of `verify` step F-0035 asks for. |
| All-kinds-per-folder + prune-artifacts-only search | take (idea) | `kondo-lib/src/search.rs:40-74` (rework) | This fixes F-0034. macontrol does the same on its own getattrlistbulk scan tree. The crossbeam code itself does not apply. |
| `ProjectIter` walker | rewrite | `lib.rs:361-456` | It reads each folder twice, is serial, stops at the first marker, and has no location exclusions (F-0033, F-0034). |
| `dir_size` | ignore | `lib.rs:505-513` | Logical size, hard links counted per link. macontrol takes sizes from its own scan tree (F-0004, F-0010). |
| "Untouched for N" age filter | improve | `lib.rs:209-228`, `main.rs:127-153, 188-201` | A good UX feature ("only projects idle for 3 months"). Compute it from the newest mtime of non-artifact, non-ignored files already in the scan tree, with no second walk. |
| Streaming scan → confirm → delete pipeline with a bounded channel | study | `main.rs:352-385` | The user acts on the first results while the scan continues, and deletions overlap the scan. Keep the shape, but put the journal/quarantine executor (F-0012) behind it. |
| `Project::clean` / `remove_dir_all` | rewrite | `lib.rs:316-329` | Permanent, no verification, errors swallowed, and the freed bytes are claimed rather than measured (`main.rs:218-226, 396-397`). |
| `kondo_lib::clean(&str)` | ignore | `lib.rs:536-585` | Dead code with a drifted table. |
| `pretty_size`, `print_elapsed` | ignore | `lib.rs:332-355, 515-534` | Foundation has `ByteCountFormatter` and `RelativeDateTimeFormatter`. |
| kondo-ui (Bevy) | ignore | `kondo-ui/src/game.rs` | A game engine for a list UI. It walks the tree on the frame thread and deletes on one click with no confirmation. |
| CLI flag set (`-n`, `-o 3M`, `-I`, `-a`, `-q`, `--single-key`) | study | `main.rs:24-68` | A reference if macontrol ever ships a CLI companion. |

## Open questions

1. **Which other tools write `CACHEDIR.TAG` or set `NSURLIsExcludedFromBackupKey`?** Cargo does both (rust-lang/cargo@70ce895 `crates/cargo-util/src/paths.rs:796-815, 865`). pytest, ruff, mypy, Gradle, Bazel and others are unverified. Each confirmed tool gives macontrol a verification step that needs no per-ecosystem logic.
2. **Content signatures for the `review`-tier kinds** (Unity `Library`, Unreal `Intermediate`/`Saved`, Gradle `build`, yarn `node_modules`): unverified. They need small fixtures or real projects.
3. **Default scan roots for the dev category:** "folders that hold `.git` under ~" versus user-chosen roots. This is a UX decision for T-0007. kondo's history (#55, #175, #191) shows that "scan all of ~" is both too broad and too easy to mask.
4. **Should macontrol defer to `cargo clean`, `gradle clean` and similar tools (#122)?** The maintainer's objections are uncontrolled side effects, version drift and `buck2 clean` killing a daemon. They also apply to a GUI, so I lean no, and would keep folder-level deletion with verification. Unverified with users.
5. **pnpm reclaim:** for projects linked to a global store, deleting `node_modules` frees about 0 B (hard links; verified with a synthetic store). Should macontrol show "frees ~0 B, run `pnpm store prune` to reclaim" (F-0010 plus F-0029's ToolRunner)? That needs a decision in the dev-rules design.
