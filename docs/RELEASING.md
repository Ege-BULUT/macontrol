# Releasing macontrol

Releases are signed with one self-signed certificate, "macontrol Self-Signed", made once on the
maintainer's Mac. macOS ties Full Disk Access to the app's designated requirement. With an ad hoc
signature that requirement is a hash of the exact build, so every rebuild and every update loses
the grant. With the certificate it is `identifier "dev.macontrol.Macontrol" and certificate leaf =
H"…"`, the same for every build signed with it. There is no paid Apple account (board journal
M-0045), so there is no notarization.

GitHub Actions builds and publishes a release when a `v*` tag is pushed, and only then. The repo is
private, and macOS runner minutes count 10x against the free 2,000 a month. Tests run on the
maintainer's Mac before tagging; CI tests come once the repo is public.

## One-time setup

1. Create the certificate:

   ```bash
   scripts/make-signing-cert.sh
   ```

   It opens no dialogs and does not touch the login keychain. It creates:

   | File | What it is |
   |---|---|
   | `~/Library/Keychains/macontrol-signing.keychain-db` | The identity, in its own keychain, added to your keychain search list. Never locks on a timer or on sleep; codesign may use the key without asking. |
   | `~/.config/macontrol/signing.env` | The keychain password and the .p12 password (0600). |
   | `~/.config/macontrol/macontrol-signing.p12` and `.p12.b64` | A password-protected copy of the identity, and the same in base64 for GitHub (0600). |

   Running it again keeps the existing certificate. It unlocks the keychain, puts it back on the
   search list and re-checks that `codesign` signs without a prompt. None of these files are in
   the repo. Back them up somewhere private: a new certificate means every user grants Full Disk
   Access once more.

2. Give the certificate to GitHub. Run these yourself, as `Ege-BULUT` (`gh auth status`):

   ```bash
   gh secret set MACONTROL_SIGNING_P12 --repo Ege-BULUT/macontrol < ~/.config/macontrol/macontrol-signing.p12.b64
   (. ~/.config/macontrol/signing.env && printf %s "$MACONTROL_SIGNING_PASSWORD" | gh secret set MACONTROL_SIGNING_PASSWORD --repo Ege-BULUT/macontrol)
   ```

   The workflow refuses to run without them. It never falls back to ad hoc signing.

## Local builds

`scripts/signing-identity.sh` prints `macontrol Self-Signed` when this Mac has the certificate
(it unlocks the keychain first, so codesign never asks), otherwise `-` for ad hoc. Until
`bundle-app.sh` uses it by default:

```bash
SIGN_IDENTITY="$(scripts/signing-identity.sh)" scripts/bundle-app.sh
codesign -d -r- build/Macontrol.app     # designated => identifier "dev.macontrol.Macontrol" and certificate leaf = H"…"
```

## Cutting a release

1. On main: set `VERSION` in `scripts/bundle-app.sh`, and add a `## 0.2.0, <date>, preview`
   section to `CHANGELOG.md`. The workflow fails if the tag and `VERSION` differ, and uses that
   section as the release notes.
2. Run `swift test` and commit.
3. Tag and push the tag:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   gh run watch --repo Ege-BULUT/macontrol
   ```

   A tag with a suffix (`v0.2.0-beta.1`) becomes a pre-release. The tagged commit must contain
   `.github/workflows/release.yml`.

`.github/workflows/release.yml` then, on a `macos-26` runner with Xcode 26.6 (the maintainer's Xcode,
Swift 6.3):

- imports the two secrets into a temporary keychain, deleted at the end;
- runs `scripts/bundle-app.sh release` with `SIGN_IDENTITY="macontrol Self-Signed"`, checks the
  version and the certificate-based requirement;
- zips the app with `ditto` to `Macontrol-<version>.zip`, writes `Macontrol-<version>.zip.sha256`;
- creates the GitHub Release with both files, or replaces the files if the release already exists.

The build cache is restored only for the same tag, so it speeds up "Re-run failed jobs", not the
next release. The cost of one run is not measured yet; check it on the first run's summary page.

## Publishing the download

The repo is private, so users download from the site, not from GitHub. After the release exists:

```bash
scripts/deploy-site.sh
```

It downloads the newest release zip (pre-releases included), writes `version.json` with its size
and SHA-256, and deploys macontrol.vercel.app.

## What users see

- **First launch:** macOS still says it cannot verify the app, because it is not notarized. They
  allow it once in System Settings > Privacy & Security > Open Anyway (macOS 15 and later), or
  Control-click > Open (macOS 14). The site's install page walks through this.
- **Full Disk Access:** granted once. An update signed with the same certificate satisfies the
  requirement macOS stored, so the grant stays. The first certificate-signed release after the ad
  hoc v0.1.x builds needs one more grant. (Checked with `codesign --verify -R` on a changed build;
  not yet tested with a real grant through an update.)
- **Unzipping:** with Finder or `ditto -x -k`. `unzip` leaves `._` files in the bundle and breaks the
  signature.

## If the certificate is lost or leaks

Anyone with the .p12 and its password can sign an app that macOS treats as macontrol, including
its Full Disk Access. Keep the files private, and rotate if they leak:

```bash
security delete-keychain ~/Library/Keychains/macontrol-signing.keychain-db
/bin/rm -f ~/.config/macontrol/signing.env ~/.config/macontrol/macontrol-signing.p12 ~/.config/macontrol/macontrol-signing.p12.b64
scripts/make-signing-cert.sh
```

Then set both secrets again and release. Users grant Full Disk Access once more.
