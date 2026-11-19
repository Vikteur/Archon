#!/usr/bin/env bash
# Update the token and cost reports and commit them on the docs home's main (P2: a script, not a model).
#   commit-reports.sh <repo dir: wedding-portal's main checkout>
# Runs tokenomics.js update --incremental for the repo (only what changed since the ledger's latest day; owner decision
# 2026-10-23: a full rebuild took close-out minutes; run tokenomics.js update without it for one), then commits only docs/tokenomics and pushes. Anything else changed in the
# repo is left alone. A push rejected because main moved on is rebased once and pushed again. Off main it does nothing:
# it refuses before any file is written. The update summary goes to stderr, so the last line of stdout is the result:
# {"commit": "<full sha, or empty when the reports did not change>"}.
set -euo pipefail
home=$1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=docs/tokenomics

if [ "$(git -C "$home" symbolic-ref --short HEAD 2>/dev/null || true)" != main ]; then
  echo "The checkout $home is not on main, so the token reports are not committed." >&2
  exit 1
fi

summary=$(node "$here/tokenomics.js" update --incremental --repo "$home" --out "$home/$out")
printf '%s\n' "$summary" >&2
latest=$(node -e 'try { console.log(JSON.parse(process.argv[1]).latestDay || "n/a"); } catch { console.log("n/a"); }' "$summary")

git -C "$home" add -- "$out"
commit=""
if git -C "$home" diff --cached --quiet -- "$out"; then
  echo "No token report change to commit in $out." >&2
else
  git -C "$home" commit -q -m "chore(tokenomics): reports up to $latest" -- "$out"
  if ! git -C "$home" push -q origin main 2>/dev/null; then
    if ! git -C "$home" pull -q --rebase --autostash origin main; then
      git -C "$home" rebase --abort 2>/dev/null || true
      echo "The token report commit could not be rebased onto origin/main; it is committed locally, not pushed." >&2
      exit 1
    fi
    git -C "$home" push -q origin main
  fi
  commit=$(git -C "$home" rev-parse HEAD)
fi
node -e 'console.log(JSON.stringify({commit: process.argv[1]}))' "$commit"
