#!/bin/bash
# Builds the product site (landing, docs, board, download) into dist/site and deploys it to
# macontrol.vercel.app.
#
#   scripts/deploy-site.sh [--dry-run] [--zip PATH]
#
#   --dry-run   assemble dist/site and print what would be deployed; no `vercel deploy`
#   --zip PATH  serve this local release zip (Macontrol-<version>.zip) instead of downloading the newest
#               GitHub release; skips every network call except the deploy itself
#
# dist/site holds: site/* (with the link-preview image, site/assets/og.jpg), images from the release tag's
# docs/assets (WebP screenshots, landing-page crops, a 256 px icon, favicon.ico), the OpenLead board under
# board/ (pages, data, attachments) and downloads/<release>.zip. The release's version, size, date and
# SHA-256 are written into the HTML, every download link points at the versioned file, and vercel.json gets
# a 307 from /downloads/latest.zip to it.
# The repo is private, so the zip is served from Vercel, never linked from GitHub. dist/ also holds release
# archives, so only dist/site is rebuilt.
#
# The page copy describes one release line, SITE_RELEASE. Only a release from that line is served: bump
# SITE_RELEASE in the same commit that updates the copy for the next minor version. A tag with a suffix
# (v0.1.2-rc.1) is never served. v0.1.0 is marked as a pre-release on GitHub because the app is a preview, so
# the tag, not that flag, separates a candidate from a release. The screenshots and the changelog come from the served release's tag,
# not from the working tree, so a merge to main can't reach the live page before its release does.
# Needs: cwebp (brew install webp); without --zip, gh logged in as Ege-BULUT with read access to the repo and
# jq (in macOS 15 and later); without --dry-run, vercel.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
REPO="Ege-BULUT/macontrol"
SITE_RELEASE="0.1"
BOARD="${BOARD:-$(git rev-parse --path-format=absolute --git-common-dir)/../.board}"
OUT="$ROOT/dist/site"

DRY=0
ZIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --zip) ZIP="${2:?--zip needs a path}"; shift ;;
        *) echo "usage: $0 [--dry-run] [--zip PATH]" >&2; exit 2 ;;
    esac
    shift
done

command -v cwebp >/dev/null || { echo "cwebp not found (brew install webp)" >&2; exit 1; }
[ -d "$BOARD/data" ] || { echo "board not found at $BOARD" >&2; exit 1; }
[ -f "$BOARD/.vercel/project.json" ] || { echo "no Vercel link at $BOARD/.vercel" >&2; exit 1; }

/bin/rm -rf "$OUT"
mkdir -p "$OUT/assets/shots" "$OUT/assets/crops" "$OUT/board" "$OUT/downloads"

# Release zip: the newest release of the SITE_RELEASE line whose tag has no suffix
if [ -n "$ZIP" ]; then
    FILE="$(basename "$ZIP")"
    VERSION="${FILE#Macontrol-}"; VERSION="${VERSION%.zip}"
    cp "$ZIP" "$OUT/downloads/$FILE"
else
    # "<tag> <published> <newest tag overall>", or an empty line when the line has no release yet
    LINE="$(gh release list --repo "$REPO" --limit 50 --exclude-drafts --json tagName,publishedAt |
        jq -r --arg line "v$SITE_RELEASE." '.[0].tagName as $newest
            | map(select(.tagName | startswith($line) and (contains("-") | not)))[0] // empty
            | "\(.tagName) \(.publishedAt) \($newest)"')"
    read -r TAG PUBLISHED NEWEST <<<"$LINE"
    [ -n "$TAG" ] || { echo "no v$SITE_RELEASE.x release in $REPO" >&2; exit 1; }
    [ "$TAG" = "$NEWEST" ] || echo "note: serving $TAG, not the newer $NEWEST: only v$SITE_RELEASE.x tags" \
        "without a suffix are served. For the next line, update the copy and SITE_RELEASE together." >&2
    gh release download "$TAG" --repo "$REPO" --pattern '*.zip' --dir "$OUT/downloads" --clobber
    ZIPS=("$OUT"/downloads/*.zip)
    [ ${#ZIPS[@]} -eq 1 ] || { echo "expected one zip in $TAG, got ${#ZIPS[@]}" >&2; exit 1; }
    FILE="$(basename "${ZIPS[0]}")"
    VERSION="${TAG#v}"
fi
case "$VERSION" in
    *-*) echo "release $VERSION has a suffix: candidates are never served" >&2; exit 1 ;;
    "$SITE_RELEASE".*) ;;
    *) echo "release $VERSION is not a $SITE_RELEASE.x release, and the page describes $SITE_RELEASE." \
        "Update the copy and SITE_RELEASE together." >&2; exit 1 ;;
esac
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null ||
    { echo "tag v$VERSION is not in this clone (git fetch --tags), and the images come from it" >&2; exit 1; }
: "${PUBLISHED:=$(git log -1 --format=%cI "v$VERSION")}"
TAGGED="$(mktemp -d)"
trap '/bin/rm -rf "$TAGGED"' EXIT
git archive "v$VERSION" CHANGELOG.md docs/assets | tar -x -C "$TAGGED"

# Landing-page crops: the part of the window each section talks about, as "x y width height" in
# screenshot pixels. The screenshots are 2x, so the <img> width/height in site/index.html are half of these:
# a crop then never shows above 1x on a Retina screen.
crop_box() {
    case "$1" in
        disk-map-treemap) echo 330 88 1010 1140 ;;
        clean) echo 325 88 1464 1052 ;;
        uninstall) echo 748 82 1036 1144 ;;
        overview) echo 450 150 1330 720 ;;
        history) echo 440 150 1330 720 ;;
    esac
}

# Site and images
cp -R site/. "$OUT/"
sips -Z 256 "$TAGGED/docs/assets/icon.png" --out "$OUT/assets/icon.png" >/dev/null
sips -Z 32 -s format ico "$TAGGED/docs/assets/icon.png" --out "$OUT/favicon.ico" >/dev/null
for png in "$TAGGED"/docs/assets/screenshots/*.png; do
    name="$(basename "${png%.png}")"
    cwebp -quiet -q 82 "$png" -o "$OUT/assets/shots/$name.webp"
    box="$(crop_box "${name%-*}")"
    [ -z "$box" ] || cwebp -quiet -q 82 -crop $box "$png" -o "$OUT/assets/crops/$name.webp"
done

# Changelog: rendered from the tag's CHANGELOG.md into the markers in docs/changelog.html.
python3 - "$TAGGED/CHANGELOG.md" "$OUT/docs/changelog.html" <<'PY'
import html, re, sys
# ponytail: headings, lists, paragraphs, **bold**, `code`, [links]; add fences/tables if CHANGELOG.md uses them
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)\s"]+)\)', r'<a href="\2">\1</a>', t)
    # CHANGELOG.md can only name the Gatekeeper step; the site links it to the install guide.
    return t.replace('Open Anyway', '<a href="install.html#first-launch">Open Anyway</a>')
out, para, items, releases = [], [], [], []
def flush():
    if para: out.append('<p>' + inline(' '.join(para)) + '</p>'); para.clear()
    if items: out.append('<ul>' + ''.join('<li>' + inline(i) + '</li>' for i in items) + '</ul>'); items.clear()
for line in open(sys.argv[1], encoding='utf-8').read().splitlines():
    s = line.strip()
    m = re.match(r'(#{1,3})\s+(.*)', s)
    if m:
        flush()
        level, text = len(m.group(1)), m.group(2)
        if level == 2:
            # One section per "## <version>, <date>" heading. site.js collapses all but the newest (data-open).
            version, _, date = text.partition(', ')
            if releases: out.append('</div></div>')
            releases.append(version)
            small = f' <small>{inline(date)}</small>' if date else ''
            out.append(f'<div class="acc release" id="v{html.escape(version)}"{" data-open" if len(releases) == 1 else ""}>'
                       f'<h2>{inline(version)}{small}</h2><div class="acc-body">')
        elif level == 3: out.append(f'<h3>{inline(text)}</h3>')
    elif re.match(r'[-*]\s+', s): (para and flush()); items.append(s[2:].strip())
    elif not s: flush()
    elif items and line.startswith(' '): items[-1] += ' ' + s
    else: (items and flush()); para.append(s)
flush()
if releases: out.append('</div></div>')
# The page has its own intro, so drop CHANGELOG.md's text before the first release.
out = out[next((i for i, o in enumerate(out) if o.startswith('<div class="acc')), 0):]
page = open(sys.argv[2], encoding='utf-8').read()
start, end = page.index('<!-- CHANGELOG:START'), page.index('<!-- CHANGELOG:END -->')
open(sys.argv[2], 'w', encoding='utf-8').write(page[:start] + '\n'.join(out) + '\n' + page[end:])
PY

# Board: pages, data and attachments only (no .git, .vercel or scripts)
cp "$BOARD"/*.html "$OUT/board/"
cp -R "$BOARD/data" "$BOARD/attachments" "$OUT/board/"
cp -R "$BOARD/.vercel" "$OUT/.vercel"

# The release goes into the HTML, so the page names, sizes and checks the download without JavaScript.
SIZE="$(stat -f %z "$OUT/downloads/$FILE")"
SHA="$(shasum -a 256 "$OUT/downloads/$FILE" | cut -d' ' -f1)"
MB="$(awk -v b="$SIZE" 'BEGIN { printf "%.1f MB", b / 1e6 }')"
DAY="$(LC_ALL=C date -j -f %Y-%m-%d "${PUBLISHED%%T*}" '+%-d %B %Y')"
find "$OUT" -name '*.html' -not -path "$OUT/board/*" -exec sed -i '' -e "s|/downloads/latest\.zip|/downloads/$FILE|g" \
    -e "s|{{version}}|$VERSION|g" -e "s|{{file}}|$FILE|g" -e "s|{{size}}|$MB|g" -e "s|{{sha256}}|$SHA|g" \
    -e "s|{{published}}|$DAY|g" {} +
if grep -rlE '\{\{[a-z0-9]+\}\}' --include='*.html' --exclude-dir=board "$OUT"; then
    echo "unfilled placeholders in the files above" >&2; exit 1
fi
# Old and shared links to /downloads/latest.zip get a temporary redirect to the current file.
python3 - "$OUT/vercel.json" "$FILE" <<'PY'
import json, sys
path, file = sys.argv[1:]
config = json.load(open(path))
config['redirects'].append({'source': '/downloads/latest.zip', 'destination': '/downloads/' + file, 'permanent': False})
json.dump(config, open(path, 'w'), indent=2)
PY

echo "dist/site: $(find "$OUT" -type f -not -path '*/.vercel/*' | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1)"
echo "release: $FILE, $MB, published $DAY, sha256 $SHA"
if [ "$DRY" = 1 ]; then
    echo "dry run: would run 'vercel deploy --prod --yes' in dist/site (project $(sed -E 's/.*"projectName":"([^"]+)".*/\1/' "$OUT/.vercel/project.json"))"
    exit 0
fi
cd "$OUT" && vercel deploy --prod --yes
