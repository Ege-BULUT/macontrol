# Contributing to macontrol

The repository is private for now. It will be opened once licensing is final, and until then only people with access can send changes. This guide already applies to them.

Questions about using the app are answered in the [docs](https://macontrol.vercel.app/docs/) and the [FAQ](https://macontrol.vercel.app/docs/faq.html). Bugs, safety reports and feature requests go through the issue forms. Security problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Build and test

You need an Apple Silicon Mac with macOS 14 or later and Xcode 26 (Swift 6.2). There are no third-party dependencies.

```sh
swift build                    # the app, mcscan and the helper
swift test                     # every test; must stay green on main
scripts/bundle-app.sh          # release build, ad-hoc signed, as build/Macontrol.app
scripts/bundle-app.sh debug    # the same from a debug build
build/Macontrol.app/Contents/MacOS/Macontrol --snapshot /tmp/shots   # every screen, light and dark, with demo data
```

- **Signing.** Full Disk Access is tied to the app's signature, and an ad-hoc signature changes with every build. Set `SIGN_IDENTITY` to an Apple Development identity to keep the grant across rebuilds.
- **UI tests run headless.** A test or tool that draws a window creates it only through `SnapshotRenderer.offscreenWindow(size:styleMask:)`, never `NSWindow(...)` directly. It calls `runHeadless()` itself and keeps the window outside every display (`OffscreenWindowTests`). With `runHeadless()` alone, AppKit still moves titled windows onto your screen. The snapshot tests render every screen this way. Set `MACONTROL_SNAPSHOT_DIR=<folder>` to keep their PNGs.
- **Opt-in tests.** A few suites need a fixture or extra time and only run when asked:
  - `research/bench/make_fixture.sh && MACONTROL_BENCH_FIXTURE=research/bench/fixtures/tree swift test --filter BenchFixtureTests`. The fixture is gitignored, so a fresh clone builds it first (about 1.7 GB on an APFS volume).
  - `MACONTROL_FD_PRESSURE=1 swift test --filter DescriptorPressureTests`
  - `MACONTROL_DISK_IMAGE_TESTS=1` attaches a small disk image inside the test's own folder.

How the modules fit together, and why: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Safety rules

These are not style preferences. A change that breaks one is not merged.

- **Only `Sources/Safety` moves or deletes files.** `SafetyTests/SinkAuditTests` fails if any other source file deletes, moves, renames or changes flags on files, runs a shell or script, or launches a process. The few fixed-path tool launchers (such as the uninstaller's `launchctl` call) are allowed per file in that test. Do not widen the allowlist to make a change pass.
- **Every new safety check has a test**, and the PR says which deliberate bug made that test fail.
- **Tests only touch temporary folders.** Build fixtures in a `TemporaryDirectory` (`TestSupport`) and use the injectable Trash backend. A test never reads or changes real user data and never moves anything to the real Trash.

## Branches

Branch from `main` with a prefix and a short name:

| Prefix | For |
|---|---|
| `feat/` | new features (`feat/uninstall-sort`) |
| `fix/` | bug fixes |
| `docs/` | documentation and the site |
| `chore/` | tooling, templates, version bumps |
| `test/` | tests only |

## Commits

- Imperative subject line, about 72 characters at most: "Add the parallel getattrlistbulk scan engine". Add the board task when there is one: "(T-0079)".
- The body says why: the problem, what was wrong before, and anything a reviewer would otherwise have to work out.
- Small commits that each build. Keep unrelated changes out.
- Code adapted from an MIT, BSD or Apache-2.0 project gets an entry in `THIRD_PARTY_NOTICES.md` in the same commit. GPL and unlicensed sources are for study only: never copy their code, data or assets.

## Pull requests

1. Push your branch and open a pull request against `main`.
2. Fill in the template: Summary, Changes, Testing, Notes, and the checklist.
3. After review, the branch is merged with a merge commit ("Merge the product site from feat/site (T-0080)"), not squashed or rebased, so its commits stay in the history.

User-facing changes add a line to `CHANGELOG.md`. UI changes attach light and dark snapshots.

## Planning

Planning lives on the [board](https://macontrol.vercel.app/board/): the roadmap, tasks (`T-0079`) and review findings (`F-0004`). It is kept on the `board` branch and edited through its scripts only. Reference the task in your commits and in the PR's Notes ("Board: T-0079").
