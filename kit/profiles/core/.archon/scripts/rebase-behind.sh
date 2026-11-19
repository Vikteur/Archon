#!/usr/bin/env bash
# Bring a run's pull request that is only behind its base up to date, by script (CI plan C15; owner decisions D7, D8
# of 2026-10-20): rebase its branch onto origin/<base>, force-push it with --force-with-lease through gh-git-ops'
# force-push.sh, and ask local CI for the new head. A model is needed only when that does not go through: a real
# conflict, or a red run on the new head, goes to the GitHub agent.
#   rebase-behind.sh <pull request url>
#   rebase-behind.sh --policy     print the behind policy in force (below) and exit 0
# Prints one JSON line {"state": "...", "sha": "...", "detail": "..."} on stdout; everything else goes to stderr.
#   green       rebased, pushed, and CI on the new head is green                                       exit 0
#   up-to-date  the branch already contains origin/<base>; nothing done                                exit 0
#   not-behind  policy task-73: base commits it lacks change only backlog/ files it does not touch      exit 0
#   conflict    the rebase stops on a conflict, or brings conflict markers in: aborted, nothing pushed  exit 1
#   refused     not done, nothing changed on origin: not an open same-repo pull request, the branch is the base,
#               main or master, no worktree has it checked out (or only the main checkout), the worktree is not
#               clean, its HEAD is not the pull request's head, the fetch failed 3 times, or the lease refused
#               the push (someone pushed meanwhile)                                                   exit 3
#   red         rebased and pushed, but CI on the new head is red or has no verdict                    exit 4
# Exit 2 on bad usage. On exit 1, 3 or 4 hand the pull request to the GitHub agent (conflict, refused) or to the run's
# own red handling (red); never retry this script in a loop.
# Only the run's own branch: the one the pull request names, checked out in its own worktree, never main, master or the
# base, never a fork's branch, and never a branch whose local HEAD differs from what GitHub has as the head (unpushed
# work, or someone else's push). The rebase is rebase-main.sh --no-push (never a merge of the base in); the push is
# force-push.sh (--force-with-lease); CI is local-ci-run.sh --head <new sha>, then ci-by-sha.sh <new sha>.
# The behind policy (D7, staged): until reuse is live it is "task-73": a pull request behind its base only by commits
# that change backlog/ files it does not change itself is not behind (TASK-73, 2026-10-19), because a rebase would buy
# a full CI run for a code-identical tree. Once reuse is live it is "behind-means-rebase": every behind pull request is
# rebased, since the planner reuses the jobs whose inputs did not change. Reuse is live when CI_REUSE=live (or CI_REUSE
# is unset and $CI_LOCAL_ROOT/reuse-live exists, the owner's switch of 2026-10-23) and the kill switch scope-all is off
# (CI_SCOPE is not "all" and $CI_LOCAL_ROOT/scope-all does not exist), the same reading as .claude/scripts/ci-plan.sh. merge-turn.sh asks `rebase-behind.sh --policy` for the same answer.
# Overrides: CI_LOCAL_ROOT, FORCE_PUSH (the force-push script), REBASE_MAIN, LOCAL_CI_RUN, CI_BY_SHA (the scripts it
# calls), and REBASE_FETCH_WAIT (passed on to rebase-main.sh).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
top="$(cd "$here/../.." && pwd)"
force_push=${FORCE_PUSH:-$top/.github/skills/gh-git-ops/scripts/force-push.sh}
rebase_main=${REBASE_MAIN:-$here/rebase-main.sh}
local_ci_run=${LOCAL_CI_RUN:-$here/local-ci-run.sh}
ci_by_sha=${CI_BY_SHA:-$here/ci-by-sha.sh}
usage="usage: rebase-behind.sh <pull request url> | --policy"

main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
ci_root=${CI_LOCAL_ROOT:-$(dirname "${main:-.}")/ci-local}

policy() { # the behind policy in force: behind-means-rebase once reuse is live, task-73 until then
  local reuse=${CI_REUSE:-}
  [ -z "$reuse" ] && [ -e "$ci_root/reuse-live" ] && reuse=live
  if [ "$reuse" = live ] && [ "${CI_SCOPE:-}" != all ] && [ ! -e "$ci_root/scope-all" ]; then
    echo behind-means-rebase
  else
    echo task-73
  fi
}

say() { # say <state> <sha> <detail>: the one JSON line on stdout
  node -e 'console.log(JSON.stringify({ state: process.argv[1], sha: process.argv[2], detail: process.argv[3] }))' "$@"
}
refuse() { echo "rebase-behind: $2" >&2; say refused "$1" "$2"; exit 3; }

case "${1:-}" in
  --policy) policy; exit 0 ;;
  ''|-*) echo "rebase-behind: $usage" >&2; exit 2 ;;
esac
pr=$1
[[ "$pr" =~ ^https://github.com/[^/]+/[^/]+/pull/[0-9]+$ ]] || { echo "rebase-behind: not a pull request url: $pr ($usage)" >&2; exit 2; }

facts=$(gh pr view "$pr" --json state,headRefName,headRefOid,baseRefName,isCrossRepository \
  -q '[.state, .headRefName, .headRefOid, .baseRefName, (.isCrossRepository | tostring)] | @tsv' 2>/dev/null) \
  || refuse "" "cannot read $pr from GitHub"
IFS=$'\t' read -r state branch head base cross <<< "$(printf '%s' "$facts" | tr -d '\r')"
[ "$state" = OPEN ] || refuse "$head" "$pr is ${state:-unknown}, not open"
[ "$cross" = false ] || refuse "$head" "$pr comes from a fork: only a run's own branch is rebased"
case "$branch" in
  ''|"$base"|main|master) refuse "$head" "refusing to rebase '${branch:-?}': only a run's own feature branch is rebased" ;;
esac

# The worktree that has the branch checked out (not the main checkout).
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0=="branch " b {print w; exit}')
[ -n "$wt" ] || refuse "$head" "no worktree has $branch checked out: hand it to the GitHub agent"
[ "$wt" != "$main" ] || refuse "$head" "$branch is checked out in the main checkout, not a run's worktree"
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || refuse "$head" "the worktree $wt is not clean"
local_head=$(git -C "$wt" rev-parse HEAD)
[ "$local_head" = "$head" ] || refuse "$head" "the worktree's HEAD ${local_head:0:7} is not the pull request's head ${head:0:7} (unpushed work, or a push from elsewhere)"

before=$head
out=$( (cd "$wt" && bash "$rebase_main" --no-push "$base") ); rc=$?
case "$rc" in
  0) ;;
  3) refuse "$head" "fetching origin/$base failed 3 times: nothing was rebased" ;;
  *)
    if [ "$(git -C "$wt" rev-parse HEAD)" != "$before" ]; then
      git -C "$wt" reset -q --hard "$before"   # markers came in: the rebased branch was never pushed, so drop it
    fi
    say conflict "$head" "rebasing $branch onto origin/$base does not go through (see stderr): hand it to the GitHub agent"
    exit 1 ;;
esac
if [[ "$out" == *'"rebased": false'* ]]; then
  say up-to-date "$head" "$branch already contains origin/$base"; exit 0
fi

# D7: until reuse is live, a branch behind only by backlog/ commits it does not touch stays as it is (TASK-73).
if [ "$(policy)" = task-73 ]; then
  mb=$(git -C "$wt" merge-base "$before" "origin/$base")
  theirs=$(git -C "$wt" diff --name-only --no-renames "$mb" "origin/$base")
  ours=$(git -C "$wt" diff --name-only --no-renames "$mb" "$before")
  if [ -n "$theirs" ] && ! grep -qv '^backlog/' <<< "$theirs" && ! grep -qxFf <(printf '%s\n' "$ours" | sed '/^$/d') <<< "$theirs"; then
    git -C "$wt" reset -q --hard "$before"
    say not-behind "$head" "origin/$base adds only backlog/ files $branch does not touch (TASK-73; policy task-73 until reuse is live)"
    exit 0
  fi
fi

new=$(git -C "$wt" rev-parse HEAD)
if ! (cd "$wt" && bash "$force_push") >&2; then
  git -C "$wt" reset -q --hard "$before"
  refuse "$head" "the force-push of $branch was refused (the lease: someone pushed meanwhile); the local branch is back at ${before:0:7}"
fi
echo "rebase-behind: rebased $branch onto origin/$base and force-pushed ${new:0:7}; asking local CI" >&2

if ! (cd "$wt" && bash "$local_ci_run" "$pr" --head "$new") >&2; then
  say red "$new" "rebased and pushed ${new:0:7}, but local CI posted no verdict on it"; exit 4
fi
verdict=$( (cd "$wt" && bash "$ci_by_sha" "$new") ) || verdict=""
if [[ "$verdict" == *'"state": "green"'* ]]; then
  say green "$new" "rebased $branch onto origin/$base, pushed ${new:0:7}, CI green"; exit 0
fi
detail=$(node -e 'try { console.log(JSON.parse(process.argv[1]).detail) } catch { console.log("no verdict") }' "$verdict")
say red "$new" "rebased and pushed ${new:0:7}, CI is not green: $detail"
exit 4
