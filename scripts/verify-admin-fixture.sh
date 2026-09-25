#!/bin/bash
# Creates or removes a harmless, root-owned test app with leftovers, so the administrator helper can be
# checked on a real Mac without touching anything real (T-0078, check 1).
#
#   sudo scripts/verify-admin-fixture.sh create    # "Macontrol Verify" app + root and user leftovers
#   sudo scripts/verify-admin-fixture.sh status    # what is still there
#   sudo scripts/verify-admin-fixture.sh remove    # clean up whatever is left
#
# Everything it makes is named dev.macontrol.verify, and remove only deletes those exact paths.
set -euo pipefail

ID="dev.macontrol.verify"
APP="/Applications/Macontrol Verify.app"
ROOT_ITEMS=("/Library/Application Support/$ID" "/Library/Caches/$ID" "/Library/Preferences/$ID.plist")
[[ $EUID -eq 0 ]] || { echo "Run with sudo: it creates root-owned files, like Apple's own apps have."; exit 1; }
USER_HOME=$(dscl . -read "/Users/${SUDO_USER:?run through sudo, not as root}" NFSHomeDirectory | awk '{print $2}')
USER_ITEMS=("$USER_HOME/Library/Application Support/$ID" "$USER_HOME/Library/Preferences/$ID.plist")

create() {
    mkdir -p "$APP/Contents/MacOS"
    /usr/bin/defaults write "$APP/Contents/Info" CFBundleIdentifier "$ID"
    /usr/bin/defaults write "$APP/Contents/Info" CFBundleName "Macontrol Verify"
    /usr/bin/defaults write "$APP/Contents/Info" CFBundleExecutable verify
    /usr/bin/defaults write "$APP/Contents/Info" CFBundlePackageType APPL
    /usr/bin/defaults write "$APP/Contents/Info" CFBundleShortVersionString 1.0
    printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/verify" && chmod 755 "$APP/Contents/MacOS/verify"
    chmod 644 "$APP/Contents/Info.plist"
    mkdir -p "${ROOT_ITEMS[0]}" "${ROOT_ITEMS[1]}"
    dd if=/dev/zero of="${ROOT_ITEMS[0]}/data.bin" bs=1048576 count=8 2>/dev/null
    dd if=/dev/zero of="${ROOT_ITEMS[1]}/cache.bin" bs=1048576 count=4 2>/dev/null
    /usr/bin/defaults write "${ROOT_ITEMS[2]%.plist}" verify -bool true
    chown -R root:wheel "$APP" "${ROOT_ITEMS[@]}"
    sudo -u "$SUDO_USER" mkdir -p "${USER_ITEMS[0]}"
    sudo -u "$SUDO_USER" dd if=/dev/zero of="${USER_ITEMS[0]}/user.bin" bs=1048576 count=2 2>/dev/null
    sudo -u "$SUDO_USER" /usr/bin/defaults write "${USER_ITEMS[1]%.plist}" verify -bool true
    status
}

status() {
    for p in "$APP" "${ROOT_ITEMS[@]}" "${USER_ITEMS[@]}"; do
        if [[ -e "$p" ]]; then printf 'present  %-6s %s\n' "$(stat -f %Su "$p")" "$p"; else printf 'gone            %s\n' "$p"; fi
    done
}

remove() {
    for p in "$APP" "${ROOT_ITEMS[@]}" "${USER_ITEMS[@]}"; do
        case "$p" in *"$ID"*|"$APP") [[ -e "$p" ]] && rm -rf -- "$p" ;; esac
    done
    status
}

case "${1:-}" in
    create) create ;;
    status) status ;;
    remove) remove ;;
    *) echo "usage: sudo $0 create|status|remove"; exit 2 ;;
esac
