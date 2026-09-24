#!/bin/bash
# Checks scripts/make-signing-cert.sh and the release workflow's signature check. Opens no dialog
# and never touches a real keychain: `security` and `codesign` are fakes on PATH, in a scratch HOME.
#
#   scripts/test-signing.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
T="$(mktemp -d)"
trap '/bin/rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- make-signing-cert.sh, with fake security/codesign that only touch files in $T ---
mkdir -p "$T/bin" "$T/home/Library/Keychains"
cat > "$T/bin/security" <<'SH'
#!/bin/bash
case "$1" in
  create-keychain) printf %s "$3" > "$4.pass"; : > "$4" ;;                   # -p PASS KEYCHAIN
  unlock-keychain) [ "$3" = "$(cat "$4.pass")" ] ;;                         # wrong password fails
  delete-keychain) /bin/rm -f "$2" "$2.pass" ;;
  list-keychains) if [ "${4:-}" = -s ]; then shift 4; printf '    "%s"\n' "$@" > "$HOME/search-list"
                  else cat "$HOME/search-list" 2>/dev/null || true; fi ;;
  find-identity) echo '  1) 00 "macontrol Self-Signed"' ;;
esac
SH
printf '#!/bin/bash\necho %s >&2\n' "'designated => identifier \"probe\" and certificate leaf = H\"00\"'" > "$T/bin/codesign"
chmod +x "$T/bin/security" "$T/bin/codesign"

cert() { HOME="$T/home" PATH="$T/bin:$PATH" "$REPO/scripts/make-signing-cert.sh" "$@" > "$T/out" 2>&1; }
[ "$(HOME="$T/home" PATH="$T/bin:$PATH" command -v security)" = "$T/bin/security" ] || fail "fake security not first on PATH"
C="$T/home/.config/macontrol"

cert || { cat "$T/out"; fail "first run"; }
for f in "$T/home/Library/Keychains/macontrol-signing.keychain-db" "$C/signing.env" "$C/macontrol-signing.p12" "$C/macontrol-signing.p12.b64"; do
    [ -f "$f" ] || fail "first run did not make $f"
done
grep -q 'macontrol-signing.keychain-db' "$T/home/search-list" || fail "keychain not on the search list"
grep -q -- '--remove-export' "$T/out" || fail "first run does not say how to remove the export"

cert && grep -q 'already set up' "$T/out" || fail "second run did not keep the setup"

cert --remove-export || fail "--remove-export"
[ ! -e "$C/macontrol-signing.p12" ] && [ ! -e "$C/macontrol-signing.p12.b64" ] || fail "--remove-export left a .p12"
grep -q '^MACONTROL_SIGNING_PASSWORD=' "$C/signing.env" && fail "--remove-export left the .p12 password"
[ "$(stat -f %Lp "$C/signing.env")" = 600 ] || fail "signing.env is not 0600 after --remove-export"
# The keychain password must survive: the fake unlock fails on a wrong or empty one.
cert && grep -q 'already set up' "$T/out" || { cat "$T/out"; fail "run after --remove-export"; }
grep -q -- '--remove-export' "$T/out" && fail "run after --remove-export still asks for it"

: > "$C/macontrol-signing.p12"
cert && fail "a .p12 without its .b64 was accepted"
grep -q 'half-made' "$T/out" || fail "a lone .p12 was not reported as half-made"

# --- release.yml: the pinned requirement, checked with the real codesign ---
YML=.github/workflows/release.yml
REQ="$(sed -n "s/^ *RELEASE_REQUIREMENT: '\(.*\)'$/\1/p" "$YML")"
[ -n "$REQ" ] || fail "no RELEASE_REQUIREMENT in $YML"
grep -qF -- '--test-requirement="=$RELEASE_REQUIREMENT"' "$YML" || fail "$YML does not check RELEASE_REQUIREMENT"
verify() { /usr/bin/codesign --verify --strict --test-requirement="=$1" "$2" 2>/dev/null; }

cp /usr/bin/true "$T/adhoc"
/usr/bin/codesign --force -i dev.macontrol.Macontrol --sign - "$T/adhoc" 2>/dev/null
verify "$REQ" "$T/adhoc" && fail "an ad hoc build passes the release check"

# On the maintainer's Mac, a certificate-signed build must pass, and a one-digit change must not.
if /usr/bin/codesign -d -r- build/Macontrol.app 2>&1 | grep -qF 'certificate leaf = H"'; then
    verify "$REQ" build/Macontrol.app || fail "build/Macontrol.app does not satisfy $REQ"
    D="${REQ#*H\"}"; D="${D:0:1}"
    OTHER="${REQ/H\"$D/H\"$([ "$D" = 0 ] && echo 1 || echo 0)}"
    [ "$OTHER" != "$REQ" ] || fail "could not change the pinned hash"
    verify "$OTHER" build/Macontrol.app && fail "the check accepts another certificate"
    echo "certificate check: pinned leaf passes, a changed leaf fails"
else
    echo "certificate check skipped: build/Macontrol.app is not certificate-signed"
fi
echo "test-signing: ok"
