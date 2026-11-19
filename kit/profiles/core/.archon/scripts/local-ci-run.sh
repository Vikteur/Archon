#!/usr/bin/env bash
# Run local CI on a commit and leave its verdict on it. Local CI is the verdict for good (owner decisions D14, D21 of
# 2026-10-20): GitHub Actions runs nothing, so the build-feature workflow runs CI itself, here, before it asks
# ci-by-sha.sh for the answer.
#   local-ci-run.sh [<pr-number>|<pr-url>|<sha>]        (default: the pull request of the current branch, else HEAD)
#   local-ci-run.sh --logs [<pr-number>|<pr-url>|<sha>] prints the folder with the run's <job>.log and summary.txt
#   --head <sha>   for a pull request: the head just pushed (TASK-59). Seconds after a push GitHub still reports the old
#                  head, which may already have a green run, so nothing would run on the new one. With --head this waits
#                  until GitHub reports <sha> as the head (LOCAL_CI_HEAD_WAIT seconds, default 300, a look every
#                  LOCAL_CI_HEAD_POLL, default 5) and exits 1, naming both commits, when it does not.
#   --no-wait      start the run in the background and return at once (exit 0), its output in
#                  $CI_LOCAL_ROOT/no-wait/<sha7>.log: for a push to main, so every main commit gets a verdict (CI plan
#                  C13) without the pusher waiting for it. The check below (already a run?) still happens first.
# Runs .claude/scripts/ci-local.sh --post on the commit (a pull request is tested merged into its base branch; the
# statuses go on its head) when no local run reported on it yet: a commit that already has a local-ci status (green,
# red, or a run still going) is left alone, so calling this twice costs nothing. A commit whose run died (the status
# reader says stale: pending statuses no live run will finish) is run again; a superseded one (no longer its pull
# request's head) is not run: its pull request's new head is the one to run. A commit the clone does not have is
# fetched once, under a lock (concurrent fetches in one clone collide on ref locks). When the runner returns and the
# commit still has no local-ci status, it runs once more; still none, and it fails loudly. Everything it prints goes to
# stderr, so a workflow node's JSON answer on stdout stays clean. Exit 0 whatever CI says: ci-by-sha.sh reads the
# result by SHA. Exit 1 when it cannot tell which commit to run, or when local CI posted nothing on it after the retry;
# 2 on bad usage.
# Overrides: CI_LOCAL (the runner), LOCAL_CI_STATUS (the status reader), CI_LOCAL_ROOT (the runner's output folder, which
# also holds the fetch lock .fetch.lock), LOCAL_CI_FETCH_WAIT (seconds to wait for that lock, default 120).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
top="$(cd "$here/../.." && pwd)"
runner=${CI_LOCAL:-$top/.claude/scripts/ci-local.sh}
status=${LOCAL_CI_STATUS:-$here/local-ci-status.sh}
logs="" want="" arg="" nowait=""
while [ $# -gt 0 ]; do
  case "$1" in
    --logs) logs=1 ;;
    --head) [ -n "${2:-}" ] || { echo "local-ci-run: --head needs the commit just pushed" >&2; exit 2; }; want=$2; shift ;;
    --no-wait) nowait=1 ;;
    *) arg=$1 ;;
  esac
  shift
done

# A workflow that puts a node output inside double quotes passes Archon's own quotes along (TASK-65). A run started
# before that fix keeps its YAML on a resume, so one pair around the whole value is unwrapped (TASK-66); any other
# quote is refused.
for v in arg want; do
  [[ "${!v}" =~ ^\'([^\']*)\'$ ]] && printf -v "$v" '%s' "${BASH_REMATCH[1]}"
done
case "$arg$want" in *[\'\"]*) echo "local-ci-run: a quote in the argument ($arg${want:+ --head $want}); pass the pull request or commit unquoted" >&2; exit 2 ;; esac

main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
ci_root=${CI_LOCAL_ROOT:-$(dirname "$main")/ci-local}

# fetch_once <sha>: fetch origin under the lock, so the clone has the commit (and, for a full SHA origin's branches do
# not reach, that commit itself). At most one fetch per call.
fetched=""
fetch_once() {
  [ -z "$fetched" ] || return 0
  fetched=1
  mkdir -p "$ci_root"
  echo "local-ci-run: ${1:0:7} is not in this clone; fetching origin" >&2
  (
    flock -w "${LOCAL_CI_FETCH_WAIT:-120}" 9 || { echo "local-ci-run: no fetch lock after ${LOCAL_CI_FETCH_WAIT:-120}s" >&2; exit 1; }
    git fetch -q origin || exit 1
    git rev-parse -q --verify "$1^{commit}" > /dev/null || [[ ! "$1" =~ ^[0-9a-f]{40}$ ]] || git fetch -q origin "$1"
  ) 9> "$ci_root/.fetch.lock"
}
have() { git rev-parse -q --verify "$1^{commit}" 2>/dev/null; }

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || { echo "local-ci-run: no GitHub repo" >&2; exit 1; }
[ -n "$arg" ] || arg=$(gh pr view --json number -q .number 2>/dev/null) || arg=""
arg=${arg%/}; arg=${arg##*/pull/}
if [[ "$arg" =~ ^[0-9]+$ ]] && [ ${#arg} -lt 7 ]; then
  target=$arg
  sha=$(gh pr view "$arg" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null) || sha=""
  if [ -n "$want" ] && [ "$sha" != "$want" ]; then
    waited=0
    echo "local-ci-run: GitHub still reports ${sha:0:7} as the head of #$arg; waiting for the pushed ${want:0:7}" >&2
    while [ "$sha" != "$want" ] && [ "$waited" -lt "${LOCAL_CI_HEAD_WAIT:-300}" ]; do
      sleep "${LOCAL_CI_HEAD_POLL:-5}"; waited=$((waited + ${LOCAL_CI_HEAD_POLL:-5}))
      sha=$(gh pr view "$arg" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null) || sha=""
    done
    if [ "$sha" != "$want" ]; then
      echo "local-ci-run: after ${waited}s GitHub reports ${sha:0:7} as the head of #$arg, not the pushed ${want:0:7}: was it pushed? No CI run." >&2
      exit 1
    fi
  fi
  # The runner tests the pull request itself; the fetch only helps the logs and a later main-ci on its merge.
  [ -n "$logs" ] || [ -z "$sha" ] || have "$sha" > /dev/null || fetch_once "$sha" || echo "local-ci-run: could not fetch ${sha:0:7}" >&2
else
  sha=$(have "${arg:-HEAD}") || sha=""
  if [ -z "$sha" ] && [[ "$arg" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    fetch_once "$arg" || echo "local-ci-run: fetching origin failed" >&2
    sha=$(have "$arg") || sha=""
  fi
  target=$sha
fi
[ -n "$sha" ] || { echo "local-ci-run: cannot tell which commit to run (${arg:-HEAD})" >&2; exit 1; }
# A commit that changes only exempt paths (ci-skip.sh paths) gets no local CI (owner decisions 2026-10-22, 2026-10-23).
# On main its verdict is the one of the newest commit under it that changes anything else, so that commit is the one
# run, when it has no run yet: a tip that is such a commit is never left without a verdict (D9).
if [ -z "$logs" ] && [ "$target" = "$sha" ] && bash "$here/ci-skip.sh" check "$sha"; then
  echo "local-ci-run: ${sha:0:7} changes only $(bash "$here/ci-skip.sh" paths | tr '\n' ' ')and gets no local CI (owner decisions 2026-10-22, 2026-10-23)" >&2
  via=$(bash "$here/ci-skip.sh" verdict "$sha" 2>/dev/null) || via=$sha
  [ -n "$via" ] && [ "$via" != "$sha" ] || exit 0
  echo "local-ci-run: its verdict is the one of ${via:0:7}, the newest commit under it that changes anything else" >&2
  sha=$via target=$via
fi

folder=$ci_root/${sha:0:7}
if [ -n "$logs" ]; then echo "$folder"; exit 0; fi

read -r state detail < <(bash "$status" "$repo" "$sha")
case "$state" in
  none) ;;
  stale) echo "local-ci-run: the last run of ${sha:0:7} died before it posted every result ($detail); running it again" >&2 ;;
  superseded) echo "local-ci-run: ${sha:0:7} is no longer its pull request's head ($detail); not run, run the new head" >&2; exit 0 ;;
  *) echo "local-ci-run: ${sha:0:7} already has a local run ($state); not started again" >&2; exit 0 ;;
esac
if [ -n "$nowait" ]; then
  mkdir -p "$ci_root/no-wait"
  bg_log=$ci_root/no-wait/${sha:0:7}.log
  # Detached (its own session where setsid exists), so the caller's exit or a closed terminal does not stop it.
  # It runs the main checkout's copy, from there: a run worktree that calls this may be deleted while the
  # background run still needs its scripts (1295db9.r1: ci-plan.sh missing).
  launcher=(); command -v setsid > /dev/null && launcher=(setsid)
  self=$main/.archon/scripts/local-ci-run.sh; [ -f "$self" ] || self=${BASH_SOURCE[0]}
  (cd "$main" && CI_LOCAL_CALLER=${CI_LOCAL_CALLER:-local-ci-run --no-wait} exec nohup "${launcher[@]}" bash "$self" "$target" \
    > "$bg_log" 2>&1 < /dev/null) &
  echo "local-ci-run: local CI of ${sha:0:7} started in the background (pid $!), log $bg_log" >&2
  exit 0
fi
for attempt in 1 2; do
  echo "local-ci-run: local CI of ${sha:0:7} (${target}), logs in $folder" >&2
  bash "$runner" --post "$target" >&2
  rc=$?
  echo "local-ci-run: done (exit $rc), the result is on ${sha:0:7} as local-ci/* statuses" >&2
  read -r state detail < <(bash "$status" "$repo" "$sha")
  case "$state" in none|stale) ;; *) exit 0 ;; esac
  [ "$attempt" = 1 ] && echo "local-ci-run: local CI posted nothing for ${sha:0:7} (runner exit $rc); running it once more" >&2
done
echo "local-ci-run: local CI posted nothing for ${sha:0:7} (runner exit $rc), twice: no verdict, see $folder" >&2
exit 1
