#!/bin/bash
# Creates the self-signed code-signing identity "macontrol Self-Signed" once, on the maintainer's Mac.
#
#   scripts/make-signing-cert.sh
#
# An ad-hoc signature changes on every build, and macOS ties Full Disk Access to the signature, so
# every rebuild and every update loses the grant. A certificate that never changes gives the app the
# same designated requirement (identifier + certificate leaf hash) on every build.
#
# Everything lives outside the repo and outside the login keychain, and nothing opens a dialog:
#   ~/Library/Keychains/macontrol-signing.keychain-db   the identity; added to the user search list
#   ~/.config/macontrol/signing.env                     keychain and .p12 passwords (0600)
#   ~/.config/macontrol/macontrol-signing.p12           password-protected backup of the identity (0600)
#   ~/.config/macontrol/macontrol-signing.p12.b64       the same, base64, for the GitHub secret (0600)
#
# Run it again at any time: an existing setup is kept, the keychain is unlocked, put back on the
# search list and codesign's key access is set again. Half-made setups are refused, never deleted.
# The certificate is not marked trusted (that needs an admin dialog); codesign signs without it.
# docs/RELEASING.md has the GitHub secrets that use these files.
set -euo pipefail

NAME="macontrol Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/macontrol-signing.keychain-db"
CONF="$HOME/.config/macontrol"
ENV_FILE="$CONF/signing.env"
P12="$CONF/macontrol-signing.p12"
OPENSSL=/usr/bin/openssl    # the system LibreSSL writes a .p12 that `security import` reads
umask 077

die() { echo "make-signing-cert: $*" >&2; exit 1; }

on_search_list() { security list-keychains -d user | grep -qF "\"$KEYCHAIN\""; }

add_to_search_list() {
    on_search_list && return 0
    local list=()
    while IFS= read -r kc; do list+=("$kc"); done \
        < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')
    security list-keychains -d user -s ${list[@]+"${list[@]}"} "$KEYCHAIN"
}

present=()
for f in "$KEYCHAIN" "$ENV_FILE" "$P12" "$P12.b64"; do [ -e "$f" ] && present+=("$f"); done

if [ ${#present[@]} -eq 0 ]; then
    mkdir -p "$CONF"
    chmod 700 "$CONF"
    WORK="$(mktemp -d)"
    CREATED=0 DONE=0
    cleanup() {
        /bin/rm -rf "$WORK"
        # A failed first run removes what it made (none of it existed before), so the next run starts clean.
        if [ "$CREATED" = 1 ] && [ "$DONE" = 0 ]; then
            security delete-keychain "$KEYCHAIN" 2>/dev/null || true
            /bin/rm -f "$ENV_FILE" "$P12" "$P12.b64"
        fi
    }
    trap cleanup EXIT

    MACONTROL_KEYCHAIN_PASSWORD="$($OPENSSL rand -hex 32)"
    MACONTROL_SIGNING_PASSWORD="$($OPENSSL rand -hex 32)"
    export MACONTROL_SIGNING_PASSWORD

    cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    $OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 -config "$WORK/cert.cnf" \
        -set_serial "0x$($OPENSSL rand -hex 16)" -keyout "$WORK/key.pem" -out "$WORK/cert.pem"
    $OPENSSL pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -passout env:MACONTROL_SIGNING_PASSWORD -out "$WORK/identity.p12"

    security create-keychain -p "$MACONTROL_KEYCHAIN_PASSWORD" "$KEYCHAIN"
    CREATED=1
    security set-keychain-settings "$KEYCHAIN"        # no auto-lock timeout, no lock on sleep
    security unlock-keychain -p "$MACONTROL_KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$MACONTROL_SIGNING_PASSWORD" \
        -T /usr/bin/codesign >/dev/null

    base64 -i "$WORK/identity.p12" -o "$WORK/identity.p12.b64"
    printf 'MACONTROL_KEYCHAIN_PASSWORD=%s\nMACONTROL_SIGNING_PASSWORD=%s\n' \
        "$MACONTROL_KEYCHAIN_PASSWORD" "$MACONTROL_SIGNING_PASSWORD" > "$WORK/signing.env"
    chmod 600 "$WORK/identity.p12" "$WORK/identity.p12.b64" "$WORK/signing.env"
    mv "$WORK/identity.p12" "$P12"
    mv "$WORK/identity.p12.b64" "$P12.b64"
    mv "$WORK/signing.env" "$ENV_FILE"
    DONE=1
    echo "created $NAME"
elif [ ${#present[@]} -eq 4 ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    security unlock-keychain -p "${MACONTROL_KEYCHAIN_PASSWORD:?missing in $ENV_FILE}" "$KEYCHAIN"
    echo "already set up, keeping it"
else
    die "half-made setup, found only: ${present[*]}
Remove what is there and run again (this also discards the old certificate):
  security delete-keychain \"$KEYCHAIN\"; /bin/rm -f \"$ENV_FILE\" \"$P12\" \"$P12.b64\""
fi

# The partition list is what keeps codesign from asking "allow access to the key?".
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACONTROL_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
add_to_search_list
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" \
    || die "no \"$NAME\" identity in $KEYCHAIN"

# Self-check: sign a scratch copy of /usr/bin/true and require a certificate-based requirement.
CHECK="$(mktemp -d)"
cp /usr/bin/true "$CHECK/probe"
codesign --force --sign "$NAME" "$CHECK/probe"
REQ="$(codesign -d -r- "$CHECK/probe" 2>&1 | grep '^designated' || true)"
/bin/rm -rf "$CHECK"
case "$REQ" in *'certificate leaf = H"'* | *'certificate root = H"'*) echo "codesign ok: $REQ" ;;
    *) die "unexpected requirement: $REQ" ;; esac

cat <<EOF

Files: $KEYCHAIN
       $ENV_FILE
       $P12(.b64)
GitHub secrets (docs/RELEASING.md), run them yourself:
  gh secret set MACONTROL_SIGNING_P12 --repo Ege-BULUT/macontrol < "$P12.b64"
  (. "$ENV_FILE" && printf %s "\$MACONTROL_SIGNING_PASSWORD" | gh secret set MACONTROL_SIGNING_PASSWORD --repo Ege-BULUT/macontrol)
EOF
