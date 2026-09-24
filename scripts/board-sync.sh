#!/bin/zsh
# Commits, pushes and deploys the OpenLead board (board branch, .board worktree) when it changed.
cd "$(dirname "$0")/../.board" || exit 1
[[ -z "$(git status --porcelain)" ]] && { echo "$(date +%T) no change"; exit 0; }
git add -A && git commit -qm "Board sync $(date '+%Y-%m-%d %H:%M')" && git push -q 2>&1 | tail -1
vercel deploy --prod --yes >/dev/null 2>&1 && echo "$(date +%T) synced + deployed" || echo "$(date +%T) deploy FAILED"
