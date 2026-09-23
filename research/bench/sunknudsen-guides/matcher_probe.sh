#!/bin/bash
# Runs app-cleaner.sh's leftover discovery VERBATIM, minus its side effects.
# Source: sunknudsen/guides@da98691 (MIT)
#   archive/how-to-clean-uninstall-macos-apps-using-appcleaner-open-source-alternative/app-cleaner.sh
# Lines copied at run time: 8 (IFS), 13-23 (plist + bundle id), 28 (app_name), 62-110 (roots + find).
# Left out: 25-43 (pgrep + sudo kill), 45-57 (lsbom logs to ~/Desktop), 112-122 (prompt + Finder delete).
# Read-only: every command left is `find <root> -maxdepth 1 -iname`. Honours $HOME, so a fixture home works.
# Usage: matcher_probe.sh /path/App.app            -> the candidate list the script would offer to trash
#        PRINT=locations matcher_probe.sh App.app  -> the script's search roots, one per line
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
SRC=${SRC:-$here/../../sources/sunknudsen-guides/archive/how-to-clean-uninstall-macos-apps-using-appcleaner-open-source-alternative/app-cleaner.sh}
[ -f "$SRC" ] || { echo "missing $SRC (git clone --depth 1 https://github.com/sunknudsen/guides)" >&2; exit 2; }
tmp=$(mktemp -t acprobe); trap '/bin/rm -f "$tmp"' EXIT
{
  echo '#!/bin/bash'
  sed -n '8p;13,23p;28p;62,110p' "$SRC"
  if [ "${PRINT:-}" = locations ]; then echo 'printf "%s\n" "${locations[@]}"'
  else echo 'printf "%s\n" "${paths[@]}"'; fi
} > "$tmp"
bash "$tmp" "$1"
