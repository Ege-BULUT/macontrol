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
   | `~/.config/macontrol/macontrol-signing.p12` and `.p12.b64` | The identity as a .p12, and the same in base64 for GitHub (0600). Removed in step 3. |

   Running it again keeps the existing certificate. It unlocks the keychain, puts it back on the
   search list and re-checks that `codesign` signs without a prompt. None of these files are in
   the repo.

2. Give the certificate to GitHub. Run these yourself, as `Ege-BULUT` (`gh auth status`):

   ```bash
   gh secret set MACONTROL_SIGNING_P12 --repo Ege-BULUT/macontrol < ~/.config/macontrol/macontrol-signing.p12.b64
   (. ~/.config/macontrol/signing.env && printf %s "$MACONTROL_SIGNING_PASSWORD" | gh secret set MACONTROL_SIGNING_PASSWORD --repo Ege-BULUT/macontrol)
   ```

   The workflow refuses to run without them. It never falls back to ad hoc signing.

3. Back up `macontrol-signing.p12` and `MACONTROL_SIGNING_PASSWORD` (in `signing.env`) offline,
   for example in a password manager. A lost certificate means every user grants Full Disk Access
   once more. Then remove both from this Mac:

   ```bash
   scripts/make-signing-cert.sh --remove-export
   ```

   It first checks that the keychain still opens with the password left in `signing.env` and
   still holds the identity; if not, it removes nothing. Then it deletes the .p12, the .p12.b64
   and the .p12 password. The keychain and its password stay, so local builds still sign.

   This removes the plain copies, not the key. The keychain file plus the password in
   `signing.env` are still a full copy, readable by anything running as you, and the keychain can
   be decrypted offline with that password (see "Who can sign as macontrol"). The script imports
   the key with `security import -x`, which blocks `security export`, not that offline read. The
   key made on 2026-09-24 was imported before `-x` and is extractable.
   `scripts/test-signing.sh` checks the scripts and the workflow's certificate check without
   touching a real keychain.

## Local builds

`scripts/signing-identity.sh` prints `macontrol Self-Signed` when this Mac has the certificate
(it unlocks the keychain first, so codesign never asks), otherwise `-` for ad hoc.
`bundle-app.sh` uses it when `SIGN_IDENTITY` is unset, and stops if the lookup fails:

```bash
scripts/bundle-app.sh                   # SIGN_IDENTITY=- scripts/bundle-app.sh signs ad hoc
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

   A tag with a suffix (`v0.2.0-beta.1`) becomes a pre-release, and the site never serves it. The
   tagged commit must contain `.github/workflows/release.yml`.

`.github/workflows/release.yml` then, on a `macos-26` runner with Xcode 26.6 (the maintainer's Xcode,
Swift 6.3):

- imports the two secrets into a temporary keychain, deleted at the end;
- runs `scripts/bundle-app.sh release` with `SIGN_IDENTITY="macontrol Self-Signed"`, checks the
  version, and checks the app with `codesign --verify --strict` against `RELEASE_REQUIREMENT`, the
  designated requirement pinned in the workflow. A build signed with any other certificate fails;
- zips the app with `ditto --norsrc --noextattr` (no `._` entries, so `unzip` keeps the signature
  intact) to `Macontrol-<version>.zip`, writes `Macontrol-<version>.zip.sha256`;
- creates the GitHub Release with both files, or replaces the files if the release already exists.

There is no build cache: GitHub restores one only for the same tag, and it would put old build
output into the build the release key signs. The cost of one run is not measured yet; check it on
the first run's summary page. The job stops after 15 minutes.

## Publishing the download

The repo is private, so users download from the site, not from GitHub. After the release exists:

```bash
scripts/deploy-site.sh
```

`scripts/board-sync.sh` runs it too, after every board change. It serves the newest release of
one line, `SITE_RELEASE` in the script (`0.2` now), whose tag has no suffix. A tag with a suffix
(`v0.2.0-beta.1`) is a candidate and is never served. It writes the version, size, date and SHA-256
into the pages, redirects `/downloads/latest.zip` to the versioned file, and deploys
macontrol.vercel.app. The screenshots and the changelog come from the served tag (`git archive`),
so fetch the tag into your clone first (`git fetch --tags`), or the deploy stops.

The page copy describes one line, and the copy and `SITE_RELEASE` change in one commit. The 0.2 copy
landed on main before v0.2.0 was tagged, so until the v0.2.0 release exists every deploy stops with
"no v0.2.x release in Ege-BULUT/macontrol", the one `board-sync.sh` runs included: the board is still
pushed, and the live site keeps its last 0.1.1 deploy. To preview the copy before the tag, run
`scripts/deploy-site.sh --dry-run --zip <a local Macontrol-0.2.0.zip>`: without the tag, a dry run takes
the screenshots and the changelog from HEAD instead. A real deploy still needs the tag.

## What users see

- **First launch (expected, not yet tested with a downloaded self-signed build):** macOS says it
  cannot verify the app, because it is not notarized. They allow it once in System Settings >
  Privacy & Security > Open Anyway (macOS 15 and later), or Control-click > Open (macOS 14). Only
  the `spctl --assess` rejection of the self-signed app has been checked, not a quarantined
  download. The site's install page walks through this.
- **Full Disk Access:** granted once. An update signed with the same certificate satisfies the
  requirement macOS stored, so the grant stays. The first certificate-signed release after the ad
  hoc v0.1.x builds needs one more grant. (Checked with `codesign --verify -R` on a changed build;
  not yet tested with a real grant through an update.)

## Who can sign as macontrol

A Full Disk Access grant trusts the certificate, not a build. Any binary signed with the key and
the identifier `dev.macontrol.Macontrol` gets the grant on every user's Mac that granted it (checked:
a re-signed copy of `/bin/ls` satisfies the requirement).

- **On the maintainer's Mac,** the keychain never locks, its password is in `signing.env`, and
  codesign may use the key without a prompt. So any program you run can sign as macontrol, and can
  copy the key: the keychain file and `signing.env` are both readable by anything running as you.
  Step 3 removes only the .p12 and its password, not this. A separate local certificate for dev
  builds, with the release key only in the GitHub secrets and the offline backup, would close it:
  open decision (T-0081).
- **On GitHub,** the key is in the two secrets and in a temporary keychain for one job.

## If the key leaks

A self-signed certificate cannot be revoked, and a new certificate does not remove the grants that
name the old one. Users must remove Macontrol from System Settings > Privacy & Security > Full Disk
Access themselves, so say so in the release notes and on the site. Then rotate:

```bash
security delete-keychain ~/Library/Keychains/macontrol-signing.keychain-db
/bin/rm -f ~/.config/macontrol/signing.env ~/.config/macontrol/macontrol-signing.p12 ~/.config/macontrol/macontrol-signing.p12.b64
scripts/make-signing-cert.sh
codesign -d -r- build/Macontrol.app     # after a local signed build: the new requirement
```

Put the new `designated =>` text in `RELEASE_REQUIREMENT` in `.github/workflows/release.yml` and
commit it, set both secrets again, and release. Users grant Full Disk Access once more. The same
steps apply if the certificate is lost.
