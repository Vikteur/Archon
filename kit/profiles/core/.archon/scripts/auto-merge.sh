#!/usr/bin/env bash
# The merge gate (P2: a script, not a model): merge a run's pull request once every review is done and CI on its head
# commit is green by SHA (P5). Only the delegator or the owner merges; a build-feature run calls it with --no-merge
# (owner decision 2026-10-18, TASK-58).
#   auto-merge.sh <pull request url> [--pre <command>] [--no-merge] [--head <sha>]
# Polls the pull request and prints one JSON line {"state": "...", "sha": "...", "detail": "..."} once it needs no more
# waiting:
#   merged   it is merged (by this script or by someone else); sha is the merge commit
#   ready    --no-merge only: all is clear and the last gates passed; sha is the head, which waits for a merge
#   closed   it was closed without a merge
#   conflict it conflicts with its base: the GitHub agent merges the base in and pushes, then this runs again
#   red      CI on its head is red: the GitHub agent fixes it tests first and pushes, then this runs again
#   moved    --head only: the head is no longer <sha> (a push came after the caller checked it); nothing is merged
#   main-red the tip of its base (main) is red: nothing merges onto a red main (CI plan C14, owner decision D9). Exit 1;
#            main is fixed first, and a pull request that is that fix is merged by the owner.
# Exit 0 for those but main-red. Exit 1 when CI registered no run for the head ("none": no merge without CI) and when
# --pre fails.
# It keeps waiting while GitHub computes whether the pull request can merge, while CI on the head runs, while a
# requested review is not given, while any reviewer's latest review requests changes, and while a review thread is
# unresolved. When all is clear it runs --pre once per head (the run's last gates; bash -c), marks a draft ready, and
# merges with a merge commit pinned to the checked head (--match-head-commit), so a later push is never merged unchecked.
# With --no-merge it reports ready there instead and never merges. With --head it merges only that head: merge-ready.sh
# passes the head its STOP verdict was given for (owner decision 2026-10-20, D7).
# Before it merges, the base's tip must be green by local CI (D9; read with local-ci-status.sh, every poll, as the tip
# moves): a tip with no verdict (none, or stale: its run died) gets local CI started on it in the background
# (local-ci-run.sh --no-wait) and is waited for, like a tip whose run is still going; a red tip answers main-red.
# Overrides: AUTO_MERGE_POLL_SECONDS (60), CI_BY_SHA (the ci-by-sha.sh to ask), LOCAL_CI_STATUS, LOCAL_CI_RUN.
set -euo pipefail

usage="usage: auto-merge.sh <pull request url> [--pre <command>] [--no-merge] [--head <sha>]"
pr=${1:?$usage}
shift
pre=""; merge_it=true; expect=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pre) pre=${2:?--pre needs a command}; shift 2 ;;
    --no-merge) merge_it=false; shift ;;
    --head) expect=${2:?--head needs a sha}; shift 2 ;;
    *) echo "auto-merge.sh: unknown argument: $1 ($usage)" >&2; exit 2 ;;
  esac
done
POLL=${AUTO_MERGE_POLL_SECONDS:-60}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ci_by_sha=${CI_BY_SHA:-$here/ci-by-sha.sh}
status=${LOCAL_CI_STATUS:-$here/local-ci-status.sh}
run_ci=${LOCAL_CI_RUN:-$here/local-ci-run.sh}

if [[ ! "$pr" =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
  echo "auto-merge.sh: not a pull request url: $pr" >&2; exit 2
fi
owner=${BASH_REMATCH[1]}; name=${BASH_REMATCH[2]}; number=${BASH_REMATCH[3]}

say() { # say <state> <sha> <detail>: the one JSON line
  node -e 'console.log(JSON.stringify({ state: process.argv[1], sha: process.argv[2], detail: process.argv[3] }))' "$@"
}

# One line of shell-safe fields from the pull request JSON: state mergeable draft head merge requests changes base.
facts() {
  gh pr view "$pr" --json state,mergeable,isDraft,headRefOid,mergeCommit,reviewRequests,reviews,baseRefName | node -e '
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const latest = {};
    for (const r of p.reviews || []) {
      const who = (r.author && r.author.login) || "";
      if (["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(r.state)) latest[who] = r.state;
    }
    const changes = Object.keys(latest).filter(w => latest[w] === "CHANGES_REQUESTED");
    console.log([p.state, p.mergeable, p.isDraft, p.headRefOid, (p.mergeCommit && p.mergeCommit.oid) || "-",
      (p.reviewRequests || []).length, changes.join(",") || "-", p.baseRefName || "main"].join(" "));'
}

unresolved() { # the number of unresolved review threads
  gh api graphql -F owner="$owner" -F name="$name" -F number="$number" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100) { nodes { isResolved } } } } }' | node -e '
    const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
    console.log(d.data.repository.pullRequest.reviewThreads.nodes.filter(t => !t.isResolved).length);'
}

waiting=""
wait_for() { # wait_for <reason>: say it once, then sleep a poll
  if [ "$1" != "$waiting" ]; then echo "auto-merge: waiting: $1" >&2; waiting=$1; fi
  sleep "$POLL"
}

pre_done="" tip_started=""
# A failing gh call (network, rate limit) is retried at the next poll instead of ending a wait that can last days.
while :; do
  if ! line=$(facts 2>/dev/null); then wait_for "GitHub did not answer"; continue; fi
  read -r state mergeable draft head merge requests changes base <<< "$line"
  case "$state" in
    MERGED) say merged "$merge" "pull request $pr is merged"; exit 0 ;;
    CLOSED) say closed "$head" "pull request $pr was closed without a merge"; exit 0 ;;
  esac
  if [ -n "$expect" ] && [ "$head" != "$expect" ]; then
    say moved "$head" "the head of $pr moved from $expect to $head: nothing merged; check the new head first"; exit 0
  fi
  case "$mergeable" in
    CONFLICTING) say conflict "$head" "pull request $pr conflicts with its base: merge the base in, resolve, push"; exit 0 ;;
    MERGEABLE) ;;
    *) wait_for "GitHub is computing whether $pr can merge"; continue ;;
  esac

  ci=$(bash "$ci_by_sha" "$head")
  case "$ci" in
    *'"state": "green"'*) ;;
    *'"state": "red"'*) say red "$head" "$(printf '%s' "$ci" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).detail)')"; exit 0 ;;
    *'"state": "conflict"'*) say conflict "$head" "pull request $pr conflicts with its base: merge the base in, resolve, push"; exit 0 ;;
    *) say none "$head" "no CI run for $head: no merge without a green CI run (P5)"; exit 1 ;;
  esac

  if [ "$requests" != 0 ]; then wait_for "$requests requested review(s) not given yet"; continue; fi
  if [ "$changes" != - ]; then wait_for "changes requested by $changes"; continue; fi
  if ! open=$(unresolved 2>/dev/null); then wait_for "GitHub did not answer"; continue; fi
  if [ "$open" != 0 ]; then wait_for "$open unresolved review thread(s)"; continue; fi

  if [ -n "$pre" ] && [ "$pre_done" != "$head" ]; then
    if ! bash -c "$pre" >&2; then say blocked "$head" "the last gates before the merge failed: $pre"; exit 1; fi
    pre_done=$head
  fi
  if [ "$draft" = true ]; then gh pr ready "$pr" >&2; fi
  if [ "$merge_it" = false ]; then
    say ready "$head" "every review done, CI green on $head: ready for the delegator or the owner to merge"; exit 0
  fi
  # Only onto a green main tip (D9).
  if ! tip=$(gh api "repos/$owner/$name/commits/$base" --jq .sha 2>/dev/null) || [ -z "$tip" ]; then
    wait_for "GitHub did not answer"; continue
  fi
  tip_line=$(bash "$status" "$owner/$name" "$tip" 2>/dev/null) || tip_line=""
  case "${tip_line%% *}" in
    green) ;;
    red) say main-red "$tip" "the tip ${tip:0:7} of $base is red (${tip_line#red }): nothing merges onto a red $base (D9); fix $base first, see local-ci-run.sh --logs $tip"; exit 1 ;;
    none|stale|superseded)
      if [ "$tip_started" != "$tip" ]; then
        tip_started=$tip
        bash "$run_ci" "$tip" --no-wait >&2 || echo "auto-merge: local CI did not start on $base's tip ${tip:0:7}" >&2
      fi
      wait_for "the tip ${tip:0:7} of $base has no CI verdict; local CI was started on it (D9)"; continue ;;
    *) wait_for "local CI on the tip ${tip:0:7} of $base is still going (D9)"; continue ;;
  esac
  if gh pr merge "$pr" --merge --match-head-commit "$head" >&2; then
    waiting=""
    continue   # the next poll reports the merge commit
  fi
  wait_for "the merge of $head was refused (the head moved, or GitHub is busy); checking again"
done
