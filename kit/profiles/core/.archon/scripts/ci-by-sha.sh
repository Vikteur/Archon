#!/usr/bin/env bash
# Wait for the local CI verdict of the pushed HEAD commit and report it by SHA (P5: CI is the source of truth).
#   ci-by-sha.sh [--check] [<sha>|<pr-number>]
#     print one JSON line {"state": "green|red|none|conflict", "sha": "...", "detail": "..."}; exit 0
#     --check: print the same line; exit 0 only when green (for until_bash)
#     <sha> (7-40 hex) is used as given; a plain number is a pull request, resolved to its head commit; with neither,
#     HEAD is used, but not on the default branch (main/master): a main checkout would answer for main, so exit 2.
# The verdict is local CI's for good (owner decisions D14, D21 of 2026-10-20): the local-ci/<job> statuses that
# .claude/scripts/ci-local.sh --post leaves on the commit, read through local-ci-status.sh. GitHub Actions is never
# asked and never waited for.
# "none" means no verdict, and the detail says which: no local CI status on the commit and no run of it in the local CI
# queue (ci-queue.sh none-check waits CI_NONE_GRACE, 60, seconds for one to appear, so nothing queued is answered in a
# minute, not after ten); a run still pending after the wait; a run that died (local-ci-status.sh says stale: run
# local-ci-run.sh again); a commit that is no longer its pull request's head (superseded: ask about the new head); or
# the status reader missing. It is never green. When the queue cannot be asked it falls back to polling the statuses
# for the grace period.
# "conflict" means the pull request cannot merge cleanly into its base: a pull request is tested merged into its base,
# so no CI can run on it, and the script answers at once instead of waiting. Rebase the branch onto the base
# (rebase-main.sh), push, ask again. Expect it when the branch and the base both appended to docs/memory.md: GitHub
# ignores its merge=union (TASK-45), a local rebase applies it. GitHub's answer counts only for the commit asked about:
# seconds after a push it still answers for the old head (TASK-60), and that is read as not computed yet.
# Failing jobs are named in detail; `bash .archon/scripts/local-ci-run.sh --logs <sha>` prints the folder of their logs.
# Overrides: LOCAL_CI_STATUS (the status reader), CI_QUEUE (the queue script), CI_GRACE_POLLS, LOCAL_CI_POLLS,
# LOCAL_CI_WAIT (below).
set -euo pipefail
GRACE_POLLS=${CI_GRACE_POLLS:-20}       # x LOCAL_CI_WAIT s = 10 minutes for a queued local run to post its first status
LOCAL_CI_POLLS=${LOCAL_CI_POLLS:-120}   # x LOCAL_CI_WAIT s = 1 hour for a started local run to finish
LOCAL_CI_WAIT=${LOCAL_CI_WAIT:-30}
MERGE_POLLS=${MERGE_POLLS:-5}           # x MERGE_WAIT s for GitHub to compute "mergeable" (it does so lazily)
MERGE_WAIT=${MERGE_WAIT:-3}

repo=$(git remote get-url origin | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')
check=""
pr=""   # the pull request to ask about conflicts, when there is one
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
arg=${1:-}
if [[ "$arg" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  sha=$arg
elif [[ "$arg" =~ ^[0-9]+$ ]]; then
  pr=$arg
  sha=$(gh pr view "$arg" --json headRefOid -q .headRefOid)
elif [ -n "$arg" ]; then
  echo "usage: ci-by-sha.sh [--check] [<sha>|<pr-number>]" >&2; exit 2
else
  branch=$(git symbolic-ref --short -q HEAD || true)
  case "$branch" in
    main|master)
      echo "Refusing to answer for HEAD on the default branch '$branch': that is the CI of $branch, not of a pull request. Pass a <sha> or a <pr-number>, or run from the pull request worktree." >&2
      exit 2 ;;
  esac
  sha=$(git rev-parse HEAD)
  if [ "$(git rev-parse "@{upstream}" 2>/dev/null || true)" != "$sha" ]; then
    echo "HEAD $sha is not pushed; push before asking CI." >&2
  fi
  pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || true)
fi

# The answer: one JSON line, in the spacing the workflow's case patterns match; with --check, exit 1 unless green.
answer() { # answer <state> <detail>
  node -e 'const [state, sha, detail] = process.argv.slice(1).map(v => JSON.stringify(v));
    console.log(`{"state": ${state}, "sha": ${sha}, "detail": ${detail}}`)' "$1" "$sha" "$2"
  if [ -n "$check" ] && [ "$1" != green ]; then exit 1; fi
  exit 0
}

# A conflicting pull request cannot be tested merged into its base, so do not wait for a run. UNKNOWN, or an answer for
# another head: GitHub has not computed it for $sha yet, ask again.
if [ -n "$pr" ]; then
  mergeable=""
  for _ in $(seq 1 "$MERGE_POLLS"); do
    read -r mhead mergeable < <(gh pr view "$pr" --json headRefOid,mergeable -q '.headRefOid + " " + .mergeable' \
      --repo "$repo" 2>/dev/null || true) || true
    [ "${mhead:-}" = "$sha" ] || mergeable=UNKNOWN
    [ "$mergeable" != UNKNOWN ] && break
    sleep "$MERGE_WAIT"
  done
  if [ "$mergeable" = CONFLICTING ]; then
    answer conflict "pull request #$pr conflicts with its base, so no CI can run on it; rebase the branch onto the base (rebase-main.sh), push, ask again"
  fi
fi

# The verdict: local CI only (D14, D21).
local_ci=${LOCAL_CI_STATUS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-ci-status.sh}
[ -f "$local_ci" ] || answer none "local CI cannot be read: $local_ci is missing"
queue=${CI_QUEUE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/scripts" 2>/dev/null && pwd)/ci-queue.sh}
read -r lstate ldetail < <(bash "$local_ci" "$repo" "$sha") || true
if [ "$lstate" = none ]; then
  # No status: is a run of the commit queued (or about to be)? None within CI_NONE_GRACE seconds: no run is coming.
  qstate=""
  if [ -f "$queue" ]; then
    full=$(git rev-parse -q --verify "$sha^{commit}" 2>/dev/null) || full=$sha
    qstate=$(bash "$queue" none-check "$full" 2>/dev/null) || qstate=""
  fi
  if [ "$qstate" = none ]; then
    answer none "local CI: no local-ci status on ${sha:0:7} and no run of it queued after ${CI_NONE_GRACE:-60}s; run .archon/scripts/local-ci-run.sh on it"
  fi
  for i in $(seq 2 "$GRACE_POLLS"); do
    sleep "$LOCAL_CI_WAIT"
    read -r lstate ldetail < <(bash "$local_ci" "$repo" "$sha") || true
    [ "$lstate" = none ] || break
  done
fi
for _ in $(seq 1 "$LOCAL_CI_POLLS"); do
  [ "$lstate" = pending ] || break
  sleep "$LOCAL_CI_WAIT"
  read -r lstate ldetail < <(bash "$local_ci" "$repo" "$sha") || true
done
case "$lstate" in
  green|red) answer "$lstate" "local CI: $ldetail" ;;
  pending) answer none "local CI: still pending: $ldetail" ;;
  stale) answer none "local CI: the run of ${sha:0:7} died before it posted every result ($ldetail); run .archon/scripts/local-ci-run.sh on it again" ;;
  superseded) answer none "local CI: ${sha:0:7} is no longer its pull request's head, so it gets no verdict: $ldetail" ;;
  none) answer none "local CI: no local-ci status on ${sha:0:7} after $((GRACE_POLLS * LOCAL_CI_WAIT))s; run .archon/scripts/local-ci-run.sh on it" ;;
  *) answer none "local CI: unexpected answer '$lstate $ldetail' from $(basename "$local_ci")" ;;
esac
