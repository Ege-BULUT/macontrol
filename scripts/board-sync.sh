#!/bin/zsh
# Commits and pushes the OpenLead board (board branch, .board worktree) when it changed, then redeploys
# the whole site with scripts/deploy-site.sh, which serves the board under /board.
SCRIPTS="${0:A:h}"
cd "$SCRIPTS/../.board" || exit 1
[[ -z "$(git status --porcelain)" ]] && { echo "$(date +%T) no change"; exit 0; }
git add -A && git commit -qm "Board sync $(date '+%Y-%m-%d %H:%M')" && git push -q 2>&1 | tail -1
"$SCRIPTS/deploy-site.sh" >/dev/null 2>&1 && echo "$(date +%T) synced + deployed" || echo "$(date +%T) deploy FAILED"
