#!/bin/bash
# Probes behind research/reports/sources/sunknudsen-guides.md (T-0039).
# Nothing here kills, trashes or writes outside a mktemp dir. Real-disk reads are `find -maxdepth 1`,
# `pgrep`, `ps` and `pkgutil --files`. Real-home output prints counts and ~-relative app-data names only.
# Usage: run.sh [roots|sibling|obs|pgrep|receipts|inject|all]
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
M=$here/matcher_probe.sh
T=$(cd "$(mktemp -d)" && pwd -P); trap '/bin/rm -rf "$T"' EXIT
mkapp() { mkdir -p "$1/Contents"; /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" "$1/Contents/Info.plist" >/dev/null; }
tilde() { sed "s#^$HOME#~#"; }

# Case roots: R.app (CRAN R GUI, bundle id org.R-project.R). app_name = "R", so the pattern is *R*.
# find -maxdepth 1 tests depth 0 too (find(1) "-maxdepth 0 limits the whole search to the command
# line arguments"), so every search root whose own name contains an r is itself a candidate.
roots() {
  mkapp "$T/R.app" org.R-project.R
  PRINT=locations "$M" "$T/R.app" > "$T/loc.txt"
  "$M" "$T/R.app" > "$T/r.txt"
  echo "== roots: app R (org.R-project.R), real HOME, read-only"
  echo "search roots: $(wc -l < "$T/loc.txt" | tr -d ' ')"
  echo "candidates offered for trash: $(wc -l < "$T/r.txt" | tr -d ' ')"
  echo "candidates that ARE a search root (the whole folder would be trashed):"
  grep -Fxf "$T/loc.txt" "$T/r.txt" | tilde | sed 's/^/  /'
}

# Case sibling: bundle id is matched as *<id>*, so com.google.Chrome also matches com.google.Chrome.canary.
# Decoy paths are real Homebrew zap paths (formulae.brew.sh/api/cask/google-chrome@canary.json,
# visual-studio-code@insiders.json).
sibling() {
  local H=$T/home; mkdir -p "$H/Library/Preferences" "$H/Library/Caches" "$H/Library/HTTPStorages" "$H/Library/Saved Application State"
  touch "$H/Library/Preferences/com.google.Chrome.plist"                          # Chrome's own (control)
  touch "$H/Library/Preferences/com.google.Chrome.canary.plist"                   # Canary's
  touch "$H/Library/Preferences/com.microsoft.VSCode.plist"                       # VS Code's own (control)
  touch "$H/Library/Preferences/com.microsoft.VSCodeInsiders.plist"               # Insiders'
  mkdir -p "$H/Library/Caches/com.microsoft.VSCodeInsiders" "$H/Library/HTTPStorages/com.microsoft.VSCodeInsiders" \
           "$H/Library/Saved Application State/com.microsoft.VSCodeInsiders.savedState"
  mkapp "$T/Google Chrome.app" com.google.Chrome
  mkapp "$T/Visual Studio Code.app" com.microsoft.VSCode
  echo "== sibling: fixture HOME, only ~ entries shown"
  for a in "Google Chrome" "Visual Studio Code"; do
    echo "-- $a.app"
    HOME=$H "$M" "$T/$a.app" | grep "^$H" | sed "s#^$H#~#;s/^/  /"
  done
}

# Case obs: the real OBS.app (com.obsproject.obs-studio) on this Mac, real HOME. *OBS* matches Obsidian.
obs() {
  [ -d /Applications/OBS.app ] || { echo "== obs: OBS.app not installed, skipped"; return; }
  "$M" /Applications/OBS.app > "$T/obs.txt"
  echo "== obs: real /Applications/OBS.app, real HOME, read-only"
  echo "candidates: $(wc -l < "$T/obs.txt" | tr -d ' ')"
  echo "candidates that belong to Obsidian (md.obsidian), not OBS:"
  grep -i obsidian "$T/obs.txt" | tilde | sed 's/^/  /'
}

# Case pgrep: line 30 verbatim for every app in /Applications; a hit is "foreign" when its executable
# is not inside that app's bundle. Line 40 would `sudo kill` every hit after one y/n.
pgrep_case() {
  echo "== pgrep: app-cleaner.sh:30 for each /Applications app (only running processes count)"
  # pgrep -a keeps this probe's own ancestors in the match list; drop them so the probe's own argv
  # (which may name the app) cannot inflate the count. Dropped ancestors are reported per app.
  local anc=" " p=$$
  while [ "${p:-0}" -gt 1 ]; do anc="$anc$p "; p=$(ps -o ppid= -p "$p" | tr -d ' '); done
  IFS=$'\n'
  for app in /Applications/*.app; do
    app_name=$(basename "$app" .app)
    processes=($(pgrep -afil "$app_name" | grep -v "app-cleaner.sh"))
    [ ${#processes[@]} -gt 0 ] || continue
    local foreign=0 own=0 skipped=0 names=""
    for p in "${processes[@]}"; do
      pid=${p%% *}
      case "$anc" in *" $pid "*) skipped=$((skipped+1)); continue;; esac
      exe=$(ps -o comm= -p "$pid" 2>/dev/null)
      case "$exe" in "$app"/*) own=$((own+1));; *) foreign=$((foreign+1)); names="$names ${exe##*/}($(ps -o user= -p "$pid" | tr -d ' '))";; esac
    done
    [ $((own+foreign)) -gt 0 ] || continue
    printf '%-20s inside-bundle=%-3s outside-bundle=%-3s probe-ancestors-dropped=%s%s\n' "$app_name" "$own" "$foreign" "$skipped" "${names:+ |$names}"
  done
  unset IFS
}

# Case receipts: pkg payload the script leaves behind while it trashes the receipt (.bom/.plist).
receipts() {
  echo "== receipts: real pkg receipts vs the script's candidate list (read-only)"
  for pair in "/Applications/Karabiner-Elements.app|org.pqrs.Karabiner-Elements" "/Applications/Cloudflare WARP.app|com.cloudflare.1dot1dot1dot1.macos"; do
    app=${pair%%|*}; pkg=${pair##*|}
    [ -d "$app" ] && pkgutil --pkg-info "$pkg" >/dev/null 2>&1 || { echo "-- $pkg not installed, skipped"; continue; }
    "$M" "$app" > "$T/c.txt"
    loc=$(pkgutil --pkg-info "$pkg" | awk -F': ' '/^location:/{print $2}')
    pkgutil --files "$pkg" | sed "s#^#/${loc:+$loc/}#;s#//*#/#g" > "$T/payload.txt"
    covered=0; missed=0; : > "$T/missed.txt"
    while IFS= read -r f; do
      hit=0; while IFS= read -r c; do case "$f/" in "$c"/*) hit=1; break;; esac; done < "$T/c.txt"
      if [ $hit = 1 ]; then covered=$((covered+1)); else missed=$((missed+1)); echo "$f" >> "$T/missed.txt"; fi
    done < "$T/payload.txt"
    echo "-- $app (receipt $pkg)"
    echo "  receipt files offered for trash: $(grep -c "^/private/var/db/receipts/" "$T/c.txt")"
    echo "  payload paths in receipt: $(wc -l < "$T/payload.txt" | tr -d ' ')  covered by a candidate: $covered  left behind: $missed"
    echo "  left-behind payload, by top 3 path components:"
    cut -d/ -f1-4 "$T/missed.txt" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   /'
  done
}

# Case inject: line 119 verbatim builds AppleScript source from paths. Evaluate only that list literal with
# osascript (no Finder, no delete). A matched file name carrying AppleScript runs a shell command.
inject() {
  echo "== inject: app-cleaner.sh:119 list literal, evaluated without Finder"
  local d="$T/Caches"; mkdir -p "$d"
  local evil='R" & (do shell script "touch INJECTED") & ".cache'
  touch "$d/$evil"
  IFS=$'\n'
  paths=($(find "$d" -iname "*R*" -maxdepth 1 -prune))
  eval "$(sed -n '119p' "$here/../../sources/sunknudsen-guides/archive/how-to-clean-uninstall-macos-apps-using-appcleaner-open-source-alternative/app-cleaner.sh" | sed 's/^ *//')"
  unset IFS
  (cd "$T" && osascript -e "set l to { $posixFiles }" >/dev/null 2>&1; echo "  osascript exit=$?")
  if [ -e "$T/INJECTED" ]; then echo "  INJECTED marker created: shell command ran from a file name"; else echo "  no marker (not reproduced)"; fi
}

case "${1:-all}" in
  roots) roots;; sibling) sibling;; obs) obs;; pgrep) pgrep_case;; receipts) receipts;; inject) inject;;
  all) roots; sibling; obs; pgrep_case; receipts; inject;;
  *) echo "usage: $0 [roots|sibling|obs|pgrep|receipts|inject|all]"; exit 2;;
esac
