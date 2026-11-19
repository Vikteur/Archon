#!/usr/bin/env bash
# Rebase the current branch onto the latest base branch, so a pull request does not turn CONFLICTING while it waits.
#   rebase-main.sh [--no-push] [base]
#     base defaults to main. Fetches origin, rebases onto origin/<base> (never a merge of the base into the branch).
#     print one JSON line {"rebased": true|false, "pushed": true|false}; exit 0
#     rebased false: the branch already contains origin/<base>, nothing was done.
#     pushed true: the rebase changed the branch and it has an upstream, so it was pushed with --force-with-lease
#     (the build-feature run's own branch, owner decision 2026-10-17; never the base or a protected branch).
#     --no-push: rebase only, never push (pushed is false); the caller pushes, e.g. with
#     force-push.sh.
# The fetch is tried 3 times, REBASE_FETCH_WAIT seconds apart (default 5): a lost connection or a ref lock held by a
# concurrent fetch in the same clone passes. Exit 3, with git's error on stderr, when all 3 fail: nothing was rebased,
# and it is not a conflict.
# Exit 1, with the reason on stderr, when:
#   - the rebase stops on conflicts: it is aborted, the branch is left as it was, and the conflicted files are named;
#   - the rebase went through but brought conflict markers into the tree: nothing is pushed, the rebased branch stays
#     local;
#   - the current branch is the base, main or master.
# Files with a merge=union attribute (docs/memory.md) are combined without conflict by git itself; this script adds no
# merge logic.
set -euo pipefail

no_push=""
if [ "${1:-}" = --no-push ]; then no_push=1; shift; fi
base=${1:-main}
branch=$(git symbolic-ref --short -q HEAD || true)
case "$branch" in
  ''|"$base"|main|master) echo "Refusing to rebase '${branch:-detached HEAD}': only a feature branch is rebased." >&2; exit 1 ;;
esac
for try in 1 2 3; do
  git fetch -q origin "$base" && break
  if [ "$try" -eq 3 ]; then
    echo "Fetching origin/$base failed 3 times: nothing was rebased (this is no conflict)." >&2
    exit 3
  fi
  echo "Fetching origin/$base failed (try $try of 3); trying again in ${REBASE_FETCH_WAIT:-5}s." >&2
  sleep "${REBASE_FETCH_WAIT:-5}"
done
target="origin/$base"

if git merge-base --is-ancestor "$target" HEAD; then
  echo '{"rebased": false, "pushed": false}'
  exit 0
fi

before=$(git rev-parse HEAD)
if ! git rebase -q "$target" > /dev/null 2>&1; then
  files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
  git rebase --abort
  echo "Rebasing onto $target conflicts in: ${files% }. Rebase aborted; resolve by hand." >&2
  exit 1
fi

# Added lines of the rebase only, so a marker that was already in the tree before is not blamed on it.
markers=$(git diff "$before" HEAD | grep -E '^\+(<<<<<<< |>>>>>>> |=======$)' || true)
if [ -n "$markers" ]; then
  echo "Rebasing onto $target left conflict markers in the tree (not pushed):" >&2
  echo "$markers" >&2
  exit 1
fi

pushed=false
if [ -z "$no_push" ] && upstream=$(git rev-parse -q --verify '@{upstream}'); then
  git push -q --force-with-lease="$branch:$upstream" origin "HEAD:$branch"
  pushed=true
fi
echo "{\"rebased\": true, \"pushed\": $pushed}"
