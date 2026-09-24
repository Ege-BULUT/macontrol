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
# dist/site holds: site/*, images from docs/assets (WebP screenshots, a 256 px icon), the OpenLead board
# under board/ (pages, data, attachments), downloads/<release>.zip plus a copy as downloads/latest.zip,
# and version.json {version, file, size, sha256, published}. The repo is private, so the zip is served
# from Vercel, never linked from GitHub. dist/ also holds release archives, so only dist/site is rebuilt.
# Needs: cwebp (brew install webp), gh (without --zip), vercel (without --dry-run).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
REPO="Ege-BULUT/macontrol"
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
mkdir -p "$OUT/assets/shots" "$OUT/board" "$OUT/downloads"

# Site and images
cp -R site/. "$OUT/"
sips -Z 256 docs/assets/icon.png --out "$OUT/assets/icon.png" >/dev/null
for png in docs/assets/screenshots/*.png; do
    cwebp -quiet -q 82 "$png" -o "$OUT/assets/shots/$(basename "${png%.png}").webp"
done

# Changelog: rendered from CHANGELOG.md when the repo has one, else the hand copy in site/docs stays.
if [ -f CHANGELOG.md ]; then
    python3 - CHANGELOG.md "$OUT/docs/changelog.html" <<'PY'
import html, re, sys
# ponytail: headings, lists, paragraphs, **bold**, `code`, [links]; add fences/tables if CHANGELOG.md uses them
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', t)
    return re.sub(r'\[([^\]]+)\]\(([^)\s"]+)\)', r'<a href="\2">\1</a>', t)
out, para, items = [], [], []
def flush():
    if para: out.append('<p>' + inline(' '.join(para)) + '</p>'); para.clear()
    if items: out.append('<ul>' + ''.join('<li>' + inline(i) + '</li>' for i in items) + '</ul>'); items.clear()
for line in open(sys.argv[1], encoding='utf-8').read().splitlines():
    s = line.strip()
    m = re.match(r'(#{1,3})\s+(.*)', s)
    if m:
        flush()
        if len(m.group(1)) > 1: out.append(f'<h{len(m.group(1))}>{inline(m.group(2))}</h{len(m.group(1))}>')
    elif re.match(r'[-*]\s+', s): (para and flush()); items.append(s[2:].strip())
    elif not s: flush()
    elif items and line.startswith(' '): items[-1] += ' ' + s
    else: (items and flush()); para.append(s)
flush()
page = open(sys.argv[2], encoding='utf-8').read()
start, end = page.index('<!-- CHANGELOG:START'), page.index('<!-- CHANGELOG:END -->')
open(sys.argv[2], 'w', encoding='utf-8').write(page[:start] + '<section class="release">\n' + '\n'.join(out) + '\n</section>\n' + page[end:])
PY
    echo "changelog: rendered from CHANGELOG.md"
else
    echo "changelog: hand copy (no CHANGELOG.md)"
fi

# Board: pages, data and attachments only (no .git, .vercel or scripts)
cp "$BOARD"/*.html "$OUT/board/"
cp -R "$BOARD/data" "$BOARD/attachments" "$OUT/board/"
cp -R "$BOARD/.vercel" "$OUT/.vercel"

# Release zip: the newest release, pre-releases included
if [ -n "$ZIP" ]; then
    FILE="$(basename "$ZIP")"
    VERSION="${FILE#Macontrol-}"; VERSION="${VERSION%.zip}"
    cp "$ZIP" "$OUT/downloads/$FILE"
    PUBLISHED="$(git log -1 --format=%cI "refs/tags/v$VERSION" 2>/dev/null || date -u +%FT%TZ)"
else
    read -r TAG PUBLISHED < <(gh release list --repo "$REPO" --limit 1 --exclude-drafts \
        --json tagName,publishedAt --jq '.[0] | "\(.tagName) \(.publishedAt)"')
    [ -n "${TAG:-}" ] || { echo "no release found in $REPO" >&2; exit 1; }
    gh release download "$TAG" --repo "$REPO" --pattern '*.zip' --dir "$OUT/downloads" --clobber
    ZIPS=("$OUT"/downloads/*.zip)
    [ ${#ZIPS[@]} -eq 1 ] || { echo "expected one zip in $TAG, got ${#ZIPS[@]}" >&2; exit 1; }
    FILE="$(basename "${ZIPS[0]}")"
    VERSION="${TAG#v}"
fi
cp "$OUT/downloads/$FILE" "$OUT/downloads/latest.zip"
SIZE="$(stat -f %z "$OUT/downloads/$FILE")"
SHA="$(shasum -a 256 "$OUT/downloads/$FILE" | cut -d' ' -f1)"
printf '{"version": "%s", "file": "%s", "size": %s, "sha256": "%s", "published": "%s"}\n' \
    "$VERSION" "$FILE" "$SIZE" "$SHA" "$PUBLISHED" > "$OUT/version.json"

echo "dist/site: $(find "$OUT" -type f -not -path '*/.vercel/*' | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1)"
echo "version.json: $(cat "$OUT/version.json")"
if [ "$DRY" = 1 ]; then
    echo "dry run: would run 'vercel deploy --prod --yes' in dist/site (project $(sed -E 's/.*"projectName":"([^"]+)".*/\1/' "$OUT/.vercel/project.json"))"
    exit 0
fi
cd "$OUT" && vercel deploy --prod --yes
