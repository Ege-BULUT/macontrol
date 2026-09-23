# macontrol

A native macOS app that merges system cleanup (PureMac-style: app uninstall incl. leftovers, caches, logs, bloat) with disk visualization (Radix-style: sunburst/treemap, drill into folders, reveal in Finder, delete) in one fast, modern app.

## Approach

We do not reinvent the wheel. Proven, well-starred open-source projects are studied first; we take the parts we need, improve them, and rewrite from scratch where they fall short. Each area runs through the same loop:

research → analysis → small spikes → benchmarks → report → integration → improvements → tests → fixes → verification

## Project board

Roadmap, task board, agent journals and review findings live in an [OpenLead](https://github.com/Ege-BULUT/openlead) workspace on the `board` branch, served at https://macontrol.vercel.app.

## Build

Requires macOS 14+ to run, Xcode 26 / Swift 6.2+ to build. Design and module ownership: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```
swift build && swift test
scripts/bundle-app.sh                                   # build/Macontrol.app (ad-hoc signed)
build/Macontrol.app/Contents/MacOS/Macontrol --snapshot /tmp/shots   # every screen as PNG, demo data
```
