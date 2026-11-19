#!/usr/bin/env bash
# CI on a merge commit, for build-feature's main-ci node (P5: by SHA; TASK-72).
#   main-ci.sh <merge commit> [<pull request head>]
# Every merge commit gets its own local-ci statuses (CI plan C13): it runs local CI on the merge commit
# (local-ci-run.sh) and answers that. It never answers green from the head's statuses, even when the trees match:
# a SHA without its own statuses has no verdict on main. Reusing a green job of the same inputs is ci-local.sh's call
# (its planner, D2: shadow until the owner turns reuse live), and then shows as a "reused from <sha>" status of its own;
# a merge commit whose tree is exactly the tree the head's last green run tested posts "reused from <head sha12>; same
# tree" on every job and runs nothing (owner decision 2026-10-23, in ci-local.sh).
# A red verdict is triaged first, as the ci node does (red-triage.sh --base main, owner decision 2026-10-23,
# docs/memory.md; TASK-6.6 went red on its merge commit and green on a rerun): a red that is only infra or a known
# flaky signature gets its one rerun of the red jobs, and the merge commit's CI is asked again. Any other red stays red.
# The pull request head is only named in the log.
# Prints the ci-by-sha.sh JSON line {"state": "...", "sha": "<merge>", "detail": "..."}. When local CI cannot run on
# the merge commit (local-ci-run.sh exits non-zero: the commit cannot be found, or nothing was posted on it), it answers
# none at once, naming that, instead of waiting for a status that will not come.
#   --check   exit 0 only when green (the build-feature main-ci node stops on anything else); without it, exit 0.
# Overrides: LOCAL_CI_RUN, CI_BY_SHA, RED_TRIAGE (the scripts to call).
set -uo pipefail
check=""
if [ "${1:-}" = --check ]; then check=1; shift; fi
merge=${1:?usage: main-ci.sh [--check] <merge commit> [<pull request head>]}
head=${2:-}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run=${LOCAL_CI_RUN:-$here/local-ci-run.sh}
ci_by_sha=${CI_BY_SHA:-$here/ci-by-sha.sh}
triage=${RED_TRIAGE:-$here/red-triage.sh}

[ -n "$head" ] && echo "main-ci: running local CI on the merge commit ${merge:0:7} (pull request head ${head:0:7})" >&2
bash "$run" "$merge"; rc=$?
if [ "$rc" -eq 0 ]; then
  answer=$(bash "$ci_by_sha" "$merge")
  if grep -q '"state": *"red"' <<< "$answer"; then
    t=$(bash "$triage" --base main "$merge") && grep -q '"class": *"green"' <<< "$t" && answer=$(bash "$ci_by_sha" "$merge")
    echo "main-ci: red-triage on ${merge:0:7}: ${t:-no answer}" >&2
  fi
  printf '%s\n' "$answer"
  [ -z "$check" ] || grep -q '"state": *"green"' <<< "$answer"
  exit $?
fi
node -e 'console.log(JSON.stringify({ state: "none", sha: process.argv[1], detail: process.argv[2] }))' \
  "$merge" "local CI could not run on the merge commit ${merge:0:7} (local-ci-run.sh exit $rc): no verdict, see its stderr"
[ -z "$check" ]
