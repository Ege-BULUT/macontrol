#!/bin/sh
# Leftover-matcher oracle for macontrol's uninstaller (T-0014).
# Builds a fake home under $1 (default: ./fx/home) with user data that name-based matchers
# wrongly pick up, then prints the paths macontrol must NEVER pre-select for each app.
# Each case is a real false positive of Pearcleaner@7724df7 (GitHub issue or local repro,
# see research/reports/sources/alienator88-pearcleaner.md "Known problems").
set -eu
H=${1:-./fx/home}
mk() { mkdir -p "$H/$(dirname "$1")"; printf 'user data\n' > "$H/$1"; }

mk "Documents/OpenSCAD/projects/gear.scad"                               # Pearcleaner #587
mk "Documents/chrome (film simulation)/roll1.jpg"                        # Pearcleaner #571
mk ".claude/settings.json"                                               # bare-$HOME root (PureMac Locations.swift:44-47)
mk "Public/Drop Box/.keep"                                               # Pearcleaner #553
mk "Library/Application Support/Objective-See/BlockBlock/rules.plist"    # vendor folder shared by sibling apps
mkdir -p "$H/Library/Application Support/Objective-See/LuLu"
mk "Library/Application Support/JetBrains/IntelliJIdea2024.1/options/keymap.xml"
mkdir -p "$H/Library/Application Support/JetBrains/PyCharm2024.1"
mk "Library/Preferences/org.openscad.OpenSCAD.plist"                    # a true leftover (control)

cat <<EOF
app (bundle id)                        | must NOT be pre-selected
OpenSCAD (org.openscad.OpenSCAD)       | ~/Documents/OpenSCAD
Google Chrome (com.google.Chrome)      | ~/Documents/chrome (film simulation)
Claude (com.anthropic.claudefordesktop)| ~/.claude
Steam (com.valvesoftware.steam)        | ~/Public
LuLu (com.objective-see.lulu)          | ~/Library/Application Support/Objective-See (only .../Objective-See/LuLu may be)
PyCharm (com.jetbrains.pycharm)        | ~/Library/Application Support/JetBrains (only .../JetBrains/PyCharm* may be)
control: OpenSCAD SHOULD pre-select    | ~/Library/Preferences/org.openscad.OpenSCAD.plist
EOF
