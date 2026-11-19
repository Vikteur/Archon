#!/usr/bin/env bash
# Wait until the run's pull request is merged (by the delegator or the owner; the run never merges, TASK-58) or closed (P2: a script).
#   [RUN_ID=<run id>] wait-merge.sh <pull request url>
# With RUN_ID, the run is listed as ready (ready-runs.sh) for as long as this waits.
# Prints one JSON line {"state": "merged|closed", "merge": "...", "head": "...", "branch": "...", "ci": "...",
# "backlog": "..."}: the merge commit, the head SHA and branch of the pull request, the CI state of that head SHA, and
# the main checkout whose backlog/ the ticket is finalized in (BACKLOG_CWD overrides; without a backlog/, the run's main
# checkout).
# The merge is the approval for closing the ticket out (UD-21.c; since 2026-10-18 the delegator or the owner merges). A merge whose head SHA is not green by CI
# fails the node, so nothing is finalized, committed or deleted (P5). The CI state is local CI's (local-ci-status.sh;
# LOCAL_CI_STATUS overrides): green, red, or none for anything that is not a verdict.
# Once the pull request is merged or closed it leaves the merge queue (merge-turn.sh drop), so it never holds the turn.
# Still open after MERGE_PING_SECONDS (1800: 30 min) of waiting, the owner is pinged once through notify-owner.sh, about
# the pull request and only when it has no open ping yet (a merge-held ping says it already; owner decision
# 2026-10-23); a missing script or a failed ping is logged, never fatal (owner decision 2026-10-20, D9, R14).
# Overrides: MERGE_POLL_SECONDS (15; was 60 until 2026-10-23, a minute under every run), MERGE_PING_SECONDS, MERGE_TURN, NOTIFY_OWNER (the scripts to call).
set -euo pipefail
pr=$1
POLL=${MERGE_POLL_SECONDS:-15}
PING_AFTER=${MERGE_PING_SECONDS:-1800}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
merge_turn=${MERGE_TURN:-$here/merge-turn.sh}
notify_owner=${NOTIFY_OWNER:-$here/notify-owner.sh}

# The Backlog is finalized on a main checkout (this repo's), never in a run worktree: the run's branch is
# merged.
main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
if [ -z "${BACKLOG_CWD:-}" ]; then
  for dir in "$main" "$main"/../*; do
    if [ -f "$dir/backlog/config.yml" ]; then BACKLOG_CWD=$(cd "$dir" && pwd); break; fi
  done
fi
# A project without Backlog.md (backlog: false in .archon/kit.yaml) has no backlog/: the main checkout is the home, and
# a run without a TASK id finalizes and commits nothing there.
if [ -z "${BACKLOG_CWD:-}" ]; then
  BACKLOG_CWD=$main
  echo "No backlog/ beside $main: the main checkout is the close-out home (no ticket to finalize)." >&2
fi

# While it waits the run is still running, so `archon workflow wait` does not return and the run is not in the
# attention queue: it is listed as ready for the delegator instead (ready-runs.sh, TASK-69) until this stops waiting.
if [ -n "${RUN_ID:-}" ]; then
  ready="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ready-runs.sh"
  bash "$ready" mark "$RUN_ID" "$pr" || echo "wait-merge: could not list run $RUN_ID as ready" >&2
  trap 'bash "$ready" clear "$RUN_ID"' EXIT
fi

# A failing gh call (network, rate limit) is retried at the next poll instead of ending a wait that can last days.
start=$(date +%s) pinged=""
while :; do
  state=$(gh pr view "$pr" --json state -q .state 2>/dev/null || echo UNKNOWN)
  case "$state" in MERGED|CLOSED) break ;; esac
  waited=$(( $(date +%s) - start ))
  if [ -z "$pinged" ] && [ "$waited" -ge "$PING_AFTER" ]; then
    pinged=1
    subject="PR #${pr##*/} is ready and not merged after $((waited / 60)) min: bash .archon/scripts/merge-ready.sh $pr"
    if [ -f "$notify_owner" ] && bash "$notify_owner" act "merge-wait-${pr##*/}" "$subject" --about "pr:${pr##*/}" --if-none-open >&2; then :
    else echo "wait-merge: ping not delivered: $subject" >&2; fi
  fi
  sleep "$POLL"
done
bash "$merge_turn" drop "$pr" >/dev/null 2>&1 || true   # not queued (anymore) is fine

merge=$(gh pr view "$pr" --json mergeCommit -q '.mergeCommit.oid // ""')
head=$(gh pr view "$pr" --json headRefOid -q .headRefOid)
branch=$(gh pr view "$pr" --json headRefName -q .headRefName)
repo=$(printf '%s' "$pr" | sed -E 's#^https://github.com/([^/]+/[^/]+)/pull/.*#\1#')

# The CI state of the head: local CI's verdict (owner decisions D14, D21: GitHub Actions runs nothing and is never asked),
# read through local-ci-status.sh. Only green and red are verdicts; anything else (none, pending, stale, superseded, a
# reader that is missing or does not answer) is no CI, so nothing is finalized.
local_ci=${LOCAL_CI_STATUS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-ci-status.sh}
ci=none
if [ -f "$local_ci" ]; then
  lstate=$(bash "$local_ci" "$repo" "$head" 2>/dev/null | awk 'NR == 1 { print $1 }') || lstate=""
  case "$lstate" in green|red) ci=$lstate ;; esac
else
  echo "wait-merge: the status reader $local_ci is missing; CI on $head counts as none" >&2
fi

lower=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
node -e 'const [state, merge, head, branch, ci, backlog] = process.argv.slice(1);
  console.log(JSON.stringify({ state, merge, head, branch, ci, backlog }));' \
  "$lower" "$merge" "$head" "$branch" "$ci" "$BACKLOG_CWD"

if [ "$state" = MERGED ] && [ "$ci" != green ]; then
  echo "Merged, but CI on head $head is $ci: the ticket is not finalized and nothing is deleted (P5)." >&2
  exit 1
fi
