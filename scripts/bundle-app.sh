#!/bin/bash
# Builds build/Macontrol.app from the SwiftPM executable.
#
#   scripts/bundle-app.sh [release|debug]
#   build/Macontrol.app/Contents/MacOS/Macontrol --snapshot <dir>   # screen PNGs with demo data
#
# SIGN_IDENTITY defaults to "macontrol Self-Signed" when this Mac has it (scripts/signing-identity.sh,
# docs/RELEASING.md), else ad hoc ("-"). An ad-hoc signature changes on every build, and Full Disk
# Access is tied to the signature, so FDA must be granted again after each ad-hoc rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
BUNDLE_ID="${BUNDLE_ID:-dev.macontrol.Macontrol}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=-
    # A lookup that fails must not turn into a silent ad-hoc build: that loses Full Disk Access with no signal.
    if [ -e scripts/signing-identity.sh ]; then
        SIGN_IDENTITY="$(scripts/signing-identity.sh)" && [ -n "$SIGN_IDENTITY" ] \
            || { echo "scripts/signing-identity.sh failed. Fix it, or set SIGN_IDENTITY=- to sign ad hoc." >&2; exit 1; }
    fi
fi
if [ "$SIGN_IDENTITY" = - ]; then
    echo "Signing ad hoc: Full Disk Access must be granted again after this build (docs/RELEASING.md)." >&2
fi
VERSION="0.1.1"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$CONFIG" --product Macontrol
swift build -c "$CONFIG" --product macontrol-priv
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Macontrol.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Macontrol" "$APP/Contents/MacOS/Macontrol"
# The administrator helper (docs/DESIGN-debloat.md section 3.2), started as root through the password dialog.
cp "$BIN_DIR/macontrol-priv" "$APP/Contents/Helpers/macontrol-priv"
# SwiftPM resource bundles go in Resources; code looks there first (CleanupCatalog.bundled()).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Placeholder icon, drawn by the app itself (AppIconView).
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN_DIR/Macontrol" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Macontrol</string>
    <key>CFBundleDisplayName</key><string>Macontrol</string>
    <key>CFBundleExecutable</key><string>Macontrol</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Inner code first. Hardened runtime makes dyld ignore DYLD_* for the process that runs as root.
codesign --force --options runtime --identifier "${BUNDLE_ID}.priv" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/macontrol-priv"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
# DESIGN-debloat 6.3 criterion 6: the helper keeps its own identifier and the hardened runtime, ad hoc or signed.
HELPER_SIGNATURE="$(codesign -dv "$APP/Contents/Helpers/macontrol-priv" 2>&1)"
[ "$SIGN_IDENTITY" = "-" ] && HELPER_FLAGS="flags=0x10002(adhoc,runtime)" || HELPER_FLAGS="flags=0x10000(runtime)"
grep -qx "Identifier=${BUNDLE_ID}.priv" <<<"$HELPER_SIGNATURE" && grep -qF "$HELPER_FLAGS" <<<"$HELPER_SIGNATURE" \
    || { echo "macontrol-priv is not signed as ${BUNDLE_ID}.priv with $HELPER_FLAGS:" >&2; echo "$HELPER_SIGNATURE" >&2; exit 1; }
echo "$APP"
