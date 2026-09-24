#!/bin/zsh
# Commits and pushes the OpenLead board (board branch, .board worktree) when it changed, then redeploys
# the whole site with scripts/deploy-site.sh, which serves the board under /board. The deploy needs gh
# logged in as Ege-BULUT (it reads the newest release), cwebp and vercel; when it fails, the last lines
# of its output go to this script's output, and so does a note that a newer release is held back.
SCRIPTS="${0:A:h}"
cd "$SCRIPTS/../.board" || exit 1
[[ -z "$(git status --porcelain)" ]] && { echo "$(date +%T) no change"; exit 0; }
git add -A && git commit -qm "Board sync $(date '+%Y-%m-%d %H:%M')" && git push -q 2>&1 | tail -1
if out="$("$SCRIPTS/deploy-site.sh" 2>&1)"; then
    echo "$(date +%T) synced + deployed"
    print -r -- "$out" | grep '^note:' | sed 's/^/  /'
else
    echo "$(date +%T) deploy FAILED:"
    print -r -- "$out" | tail -n 8 | sed 's/^/  /'
fi
