#!/bin/bash
# Does PermissionsKit's FDA check say "Authorized" for an app that has NOT been granted Full Disk Access?
# Compiles the clone's MPFullDiskAccessAuthorizer.m unmodified into a throwaway ad-hoc-signed app
# (its own TCC identity), launches it with `open` and prints its log. Control: the same binary run
# directly from this shell (inherits the terminal's TCC grants).
# Touches no user data: only open()+read() of 16 bytes of the 5 probe files; no UI prompt is shown.
# Usage: research/bench/macpaw-permissionskit/run.sh [path-to-clone]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
SRC=${1:-$HERE/../../sources/macpaw-permissionskit}
PK="$SRC/PermissionsKit"
ID=local.macontrol.permissionskit-probe
W=$(mktemp -d)
W=$(cd "$W" && pwd -P)
APP="$W/PKProbe.app"
trap 'tccutil reset SystemPolicyAllFiles "$ID" >/dev/null 2>&1 || true; rm -rf "$W"' EXIT

echo "PermissionsKit @ $(git -C "$SRC" rev-parse --short HEAD), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -fmodules -O1 -I"$PK/Public" -I"$PK/Private" -I"$PK/Private/FullDiskAccess" \
  "$HERE/probe.m" "$PK/Private/FullDiskAccess/MPFullDiskAccessAuthorizer.m" \
  -framework AppKit -o "$APP/Contents/MacOS/PKProbe"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>PKProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
P
codesign -s - --force "$APP" >/dev/null 2>&1

echo "== as its own app (launched with open, no FDA granted to $ID)"
open -W -n "$APP" --args "$W/app.log"
cat "$W/app.log"
echo "== control: same binary run from this shell (terminal's TCC grants)"
"$APP/Contents/MacOS/PKProbe"
