#!/usr/bin/env bash
# The commits that get no local CI (owner decisions 2026-10-22 and 2026-10-23, docs/memory.md): a ticket commit, a retro
# or the token reports is pushed to main when it is ready and runs nothing. A commit is such a commit when every file it
# changes against its first parent is under backlog/, docs/retro/ or docs/tokenomics/ (an empty change, or a root
# commit, is not); backlog/ only with backlog: true in .archon/kit.yaml (env KIT_BACKLOG, default true): without
# Backlog.md it is the project's own folder and runs CI. One that also changes
# anything else runs CI as before. Its verdict is the one of the newest commit under it, along the first parents, that
# changes anything else.
#   ci-skip.sh paths              the paths, one a line
#   ci-skip.sh check <sha>        exit 0 when <sha> is such a commit, 1 when it is not or cannot be read
#   ci-skip.sh verdict <sha>      the commit whose verdict counts for <sha>: <sha> itself, or, for such a commit on
#                                 origin/main (fetched once when the clone does not have it there), the newest commit
#                                 under it that changes anything else. Exit 1 when <sha> cannot be read.
# Run in the checkout (git reads the current directory). ci-local.sh and local-ci-run.sh refuse such a commit;
# local-ci-status.sh and ci-audit.sh read past it.
set -uo pipefail
# shellcheck source=kit-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/kit-config.sh"
PATHS=(docs/retro/ docs/tokenomics/)
[ "$(kit_get backlog true)" = false ] || PATHS=(backlog/ "${PATHS[@]}")

exempt() { # exempt <sha>: every file the commit changes against its first parent is under PATHS
  local files f p ok
  git rev-parse -q --verify "$1^1^{commit}" > /dev/null 2>&1 || return 1
  files=$(git diff --name-only --no-renames "$1^1" "$1" 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    ok=""
    for p in "${PATHS[@]}"; do case "$f" in "$p"*) ok=1; break ;; esac; done
    [ -n "$ok" ] || return 1
  done <<< "$files"
}

case "${1:-} $#" in
  "paths 1") printf '%s\n' "${PATHS[@]}" ;;
  "check 2") exempt "$2" ;;
  "verdict 2")
    sha=$(git rev-parse -q --verify "$2^{commit}" 2>/dev/null) || exit 1
    exempt "$sha" || { echo "$sha"; exit 0; }
    if ! git merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
      git fetch -q origin main 2>/dev/null
      git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || { echo "$sha"; exit 0; }
    fi
    for _ in $(seq 1 500); do
      exempt "$sha" || break
      sha=$(git rev-parse -q --verify "$sha^1") || break
    done
    echo "$sha" ;;
  *) echo "usage: ci-skip.sh paths | check <sha> | verdict <sha>" >&2; exit 2 ;;
esac
