#!/bin/bash
# Prints the code-signing identity for scripts/bundle-app.sh: "macontrol Self-Signed" when this Mac
# has it (scripts/make-signing-cert.sh), else "-" (ad hoc). It unlocks the dedicated keychain with the
# password in ~/.config/macontrol/signing.env first, because codesign on a locked keychain asks in a dialog.
#
#   SIGN_IDENTITY="${SIGN_IDENTITY:-$(scripts/signing-identity.sh)}"
NAME="macontrol Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/macontrol-signing.keychain-db"
ENV_FILE="$HOME/.config/macontrol/signing.env"

# The search-list lookup is the one codesign does, so a keychain taken off the list falls back to ad hoc.
if [ -f "$KEYCHAIN" ] && [ -f "$ENV_FILE" ] && . "$ENV_FILE" \
    && security unlock-keychain -p "${MACONTROL_KEYCHAIN_PASSWORD:-}" "$KEYCHAIN" 2>/dev/null \
    && security find-identity -p codesigning | grep -qF "\"$NAME\""; then
    echo "$NAME"
else
    echo "-"
fi
