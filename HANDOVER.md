# Handover: paused 2026-09-23 evening

Work was paused safely by the user (computer shut down). Nothing is running. Everything is committed and pushed.

## Released

- **v0.1.0** (pre-release, arm64): https://github.com/Ege-BULUT/macontrol/releases/tag/v0.1.0. Installed locally at `/Applications/Macontrol.app`.
- On main since the tag: UX fixes T-0057/T-0058/T-0060, MIT LICENSE, README with screenshots, third-party notices, headless snapshot fix, debloat design docs.

## Release plan (user decisions, board journal M-0045)

| Version | Content | State |
|---|---|---|
| v0.1.1 | Uninstall: sort (name, date added, size), filter All / User / System (T-0079) | Built on `feat/uninstall-sort` (26acec8), **review not run yet** |
| v0.2.0 | Hardcore mode, permanent delete engine, privileged helper, Apple app debloat, sealed-app guide, self-signed signing + GitHub Actions tag releases | Design done (`docs/DESIGN-debloat.md`, tasks T-0072..T-0077). Contracts (T-0072) **WIP** on `feat/debloat-contracts` (84f100f, does not build yet). Module builders not started. |
| v0.3.0 | Live map while scanning (T-0063) | On `feat/ux-polish` (1bb1c26), main merged in, finisher mid-work, **review not run yet**. Merge into main only after v0.2.0 is tagged. |

## Branches and worktrees

| Branch (pushed) | Worktree | State |
|---|---|---|
| `main` | `~/projects/macontrol` | clean |
| `board` | `~/projects/macontrol/.board` | OpenLead board, served at https://macontrol.vercel.app |
| `feat/uninstall-sort` | `~/projects/macontrol-wt/uninstall-sort` | builder done, needs review + fix, then merge + v0.1.1 |
| `feat/debloat-contracts` | `~/projects/macontrol-wt/debloat-contracts` | WIP commit, continue T-0072 |
| `feat/ux-polish` | `~/projects/macontrol-wt/ux-polish` | T-0063 finisher mid-work |

## Resume order

1. `feat/uninstall-sort`: review (+ fix), merge into main, bundle, tag **v0.1.1**, release, install to /Applications.
2. v0.2.0: finish T-0072 contracts on its branch, land on main, then the parallel module builders T-0073..T-0077 + signing-ci, review/fix, integrate, safety attack, UX check, release prep. The workflow script used: `macontrol-v0-2-and-v0-3` (its prompts are the spec for each stage).
3. v0.3.0 in parallel on `feat/ux-polish`: finish, review, keep on the branch until v0.2.0 is tagged.
4. Before releasing v0.2.0 the user runs one real admin-password test of the helper (T-0078).

## Rules that must hold for every agent

- The user works on this Mac: never bring windows to the front (`SnapshotRenderer.runHeadless()`, `open -g -j`, headless Playwright), no password or keychain prompts, never run the helper as root.
- Tests only touch temp dirs. No AI attribution anywhere. All remote actions as `Ege-BULUT`.
- Board: claim before work, CLIs only, lessons to M-0001, playbook M-0044.
