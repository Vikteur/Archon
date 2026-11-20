#!/usr/bin/env bash
# The CI verdict of a commit, read from the statuses the local runner posts (.claude/scripts/ci-local.sh --post): one
# commit status per job of .github/workflows/ci.yml, context local-ci/<job>. Local CI is the verdict for good (owner
# decisions D14, D21 of 2026-10-20): GitHub Actions runs nothing, so there is no Actions fallback and no date switch.
# ci-by-sha.sh reads the verdict through this script.
#   local-ci-status.sh <owner/repo> <sha>
# Prints one line "<state> <detail>"; exit 0. State:
#   none        no local-ci/* status on the commit, and no live local CI run of it in the queue (ci-queue.sh state).
#   pending     a job has no final local-ci/<job> status yet while a run of the commit is queued or running, or GitHub
#               did not answer (for the commit, or for the source of a reuse): ask again.
#   stale       a job has no final status and no live run will post one: the run's queue entry went stale (its process
#               died) or ended. Not a verdict: run local CI on the commit again (local-ci-run.sh does).
#   superseded  a job's status is "superseded: PR #<n> head is now <sha7>, not run": the commit is no longer the pull
#               request's head, so it gets no verdict; ask about the new head.
#   green       every job of the workflow has a local-ci/<job> status, and each is an accepted success (see accept()).
#   red         a job's status is failure or error (other than superseded), or a success that is not accepted.
# Only the newest status of each context counts. Every description is read through the one status grammar,
# .claude/scripts/ci-status-grammar.sh (ci_status_parse). A success is accepted only as a real run (kind ran; the
# legacy form of before the grammar too, which was a real run, though it can never be a reuse source) or as a verified
# reuse (kind reused: the source commit's newest status in the same context is a real run, success, not legacy, with the
# same fp, posted at most CI_PLAN_MAX_AGE seconds, default 86400 = 24 h (owner decision D2), before the reuse), or a
# verified same-tree reuse (kind same-tree, owner decision 2026-10-23: the source is the commit's second parent, when this
# clone has the commit, and its newest status in the context is a real green run within that age, fp not compared). Any other
# success, kind unknown included, is red ("unrecognised success"): a skip must never read as a pass, and a reader fails
# closed on what it cannot parse. Red beats superseded, superseded beats stale and pending, those beat green.
# A pending status counts as stale only when it names this host (`pid N@<host>`, or the legacy `running on <host>`) and
# the queue has no live entry of the commit; the statuses are read once more first, so a run that ended between the two
# reads is not taken for a dead one. When the queue cannot be asked, pending stays pending.
# A main commit that changes only backlog/, docs/retro/ or docs/tokenomics/ (ci-skip.sh; backlog/ only with
# backlog: true in .archon/kit.yaml) answers the verdict of the newest commit under it that changes anything else, with
# that commit named in the detail.
# Overrides: LOCAL_CI_WORKFLOW (the workflow whose jobs are required; default .github/workflows/ci.yml of <sha> itself),
# CI_STATUS_GRAMMAR, CI_QUEUE (the grammar and queue scripts), CI_PLAN_MAX_AGE.
# With local CI off (local_ci: false in .archon/kit.yaml, kit/SPEC.md Local CI switch) the project's own CI (GitHub
# Actions) gives the verdict, and this reads GitHub's check runs and commit statuses on <sha> instead, in the same
# "<state> <detail>" line: none (no check yet), pending (a check still runs, or GitHub did not answer), red (a check
# failed, timed out, was cancelled or needs action; detail "<check>=<conclusion> ..."), green (every check passed,
# neutral or skipped).
set -uo pipefail
repo=$1 sha=$2
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if . "$here/kit-config.sh" 2>/dev/null && [ "$(kit_get local_ci true)" = false ]; then
  runs=$(gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
      --jq '.check_runs[] | [.name, (if .status == "completed" then (.conclusion // "unknown") else "pending" end)] | @tsv' \
      2>/dev/null) || { echo "pending GitHub did not answer for the check runs of ${sha:0:7}"; exit 0; }
  sts=$(gh api "repos/$repo/commits/$sha/status" --jq '.statuses[] | [.context, .state] | @tsv' 2>/dev/null) \
    || { echo "pending GitHub did not answer for the statuses of ${sha:0:7}"; exit 0; }
  all=$(printf '%s\n%s\n' "$runs" "$sts" | sed '/^$/d')
  [ -n "$all" ] || { echo "none no GitHub check on ${sha:0:7}"; exit 0; }
  red=$(awk -F'\t' '$2 !~ /^(success|neutral|skipped|pending|queued|in_progress)$/ {printf "%s=%s ", $1, $2}' <<< "$all")
  wait=$(awk -F'\t' '$2 ~ /^(pending|queued|in_progress)$/ {printf "%s ", $1}' <<< "$all")
  if [ -n "$red" ]; then echo "red ${red% }"
  elif [ -n "$wait" ]; then echo "pending still running: ${wait% }"
  else echo "green every GitHub check passed ($(wc -l <<< "$all" | tr -d ' '))"; fi
  exit 0
fi
grammar=${CI_STATUS_GRAMMAR:-$here/../../.claude/scripts/ci-status-grammar.sh}
queue=${CI_QUEUE:-$here/../../.claude/scripts/ci-queue.sh}
max_age=${CI_PLAN_MAX_AGE:-86400}
# shellcheck source=../../.claude/scripts/ci-status-grammar.sh
if ! . "$grammar" 2>/dev/null || ! declare -F ci_status_parse > /dev/null; then
  echo "red the status grammar $grammar cannot be read, so no status can be accepted"; exit 0
fi
full=$(git rev-parse -q --verify "$sha^{commit}" 2>/dev/null) || full=$sha

# A main commit that changes only backlog/, docs/retro/ or docs/tokenomics/ gets no local CI (owner decisions 2026-10-22,
# 2026-10-23, ci-skip.sh): its verdict is the one of the newest commit under it that changes anything else, so one on
# main's tip neither hides a red main (D9) nor leaves it without a verdict.
if [ -z "${LOCAL_CI_STATUS_FOR:-}" ] && via=$(bash "$here/ci-skip.sh" verdict "$full" 2>/dev/null) && [ -n "$via" ] \
    && [ "$via" != "$full" ]; then
  line=$(LOCAL_CI_STATUS_FOR=$full bash "$0" "$repo" "$via")
  echo "$line (the verdict of ${via:0:7}: ${full:0:7} changes only $(bash "$here/ci-skip.sh" paths | tr '\n' ' ' | sed 's/ $//') and runs no CI)"
  exit 0
fi

# statuses <sha>: "<context>\t<state>\t<description>\t<updated_at>", the newest status of each local-ci/* context; exit 1
# when GitHub does not answer. The list endpoint returns every status ever posted (a rerun posts again on the same
# context), so the newest is picked here, by time then id, instead of trusting the order of an answer.
statuses() {
  local all
  all=$(gh api --paginate "repos/$repo/commits/$1/statuses?per_page=100" \
    -q '.[] | select(.context | startswith("local-ci/")) | [.updated_at, (.id | tostring), .context, .state, (.description // "")] | @tsv' \
    2>/dev/null) || return 1
  printf '%s\n' "$all" | tr -d '\r' | sed '/^$/d' | sort -t$'\t' -k1,1r -k2,2nr \
    | awk -F'\t' '!seen[$3]++ { print $3 "\t" $4 "\t" $5 "\t" $1 }'
}

# parse <state> <description>: the grammar's fields of one status into the array P (P[kind] is unknown when it does
# not parse). The output is read as data, never evaluated: anyone with write access can post a status.
declare -A P=()
parse() {
  local k v
  P=()
  while IFS='=' read -r k v; do [ -n "$k" ] && P[$k]=$v; done < <(ci_status_parse "$1" "$2")
  [ -n "${P[kind]:-}" ] || P[kind]=unknown
}
epoch() { date -u -d "$1" +%s 2>/dev/null; }

# verify <context> <sha12> <fp> <reuse time>: is the reuse source's newest status in the same context a real green run
# with the same fp, at most max_age seconds before the reuse? An empty fp (a same-tree reuse) checks no fp. Return 0 yes,
# 1 no, 2 GitHub did not answer; the reason goes in $why. Each source is fetched once.
declare -A source_cache=()
verify() {
  local context=$1 src=$2 fp=$3 at=$4 line state desc t t0 t1
  case "$full" in "$src"*) why="reused from itself"; return 1 ;; esac
  if [ -z "${source_cache[$src]+set}" ]; then
    line=$(statuses "$src") || { why="the source $src cannot be read"; return 2; }
    source_cache[$src]=$line
  fi
  line=$(printf '%s\n' "${source_cache[$src]}" | awk -F'\t' -v c="$context" '$1 == c { print; exit }')
  [ -n "$line" ] || { why="reuse not verified: $src has no $context status"; return 1; }
  IFS=$'\t' read -r _ state desc t <<< "$line"
  [ "$state" = success ] || { why="reuse not verified: $src is $state"; return 1; }
  parse "$state" "$desc"
  case "${P[kind]}" in
    reused) why="reuse not verified: $src is itself a reuse (no chains)"; return 1 ;;
    ran)
      if [ -z "$fp" ]; then
        [ "${P[legacy]}" = 1 ] && { why="reuse not verified: $src is a legacy status, never a source"; return 1; }
      elif [ "${P[legacy]}" = 1 ] || [ -z "${P[fp]}" ]; then
        why="reuse not verified: $src ran with fp=none, not $fp"; return 1
      else
        [ "${P[fp]}" = "$fp" ] || { why="reuse not verified: $src ran with fp=${P[fp]}, not $fp"; return 1; }
      fi ;;
    *) why="reuse not verified: $src has an unrecognised success"; return 1 ;;
  esac
  t0=$(epoch "$t") t1=$(epoch "$at")
  [ -n "$t0" ] && [ -n "$t1" ] || { why="reuse not verified: the time of $src or of the reuse cannot be read"; return 1; }
  if [ $((t1 - t0)) -gt "$max_age" ]; then
    why="reuse not verified: $src ran $(( (t1 - t0) / 3600 )) h before the reuse, over the $((max_age / 3600)) h limit (D2)"
    return 1
  fi
}

# accept <context> <description> <time>: may this success count? Return 0 yes, 1 red, 2 ask again; the reason goes in
# $why.
accept() {
  parse success "$2"
  case "${P[kind]}" in
    ran) return 0 ;;
    reused) verify "$1" "${P[from]}" "${P[fp]}" "$3" ;;
    same-tree) # owner decision 2026-10-23: the source is the merge commit's pull request head, its second parent
      local head
      if head=$(git rev-parse -q --verify "$full^2" 2>/dev/null) && [[ "$head" != "${P[from]}"* ]]; then
        why="same-tree reuse not verified: ${P[from]} is not the second parent of ${full:0:7}"; return 1
      fi
      git rev-parse -q --verify "$full^{commit}" > /dev/null 2>&1 && [ -z "$head" ] \
        && { why="same-tree reuse not verified: ${full:0:7} is not a merge commit"; return 1; }
      verify "$1" "${P[from]}" "" "$3" ;;
    *) why="unrecognised success"; return 1 ;;
  esac
}

# live_run: the queue's line for the commit when a run of it is queued or running; exit 1 when there is none (the
# entry went stale or ended), 2 when the queue cannot be asked.
live_run() {
  local s
  [ -f "$queue" ] || return 2
  s=$(bash "$queue" state "$full" 2>/dev/null) || return 2
  case "$s" in
    queued*|running*) echo "$s"; return 0 ;;
    none|stale*) echo "$s"; return 1 ;;
    *) return 2 ;;
  esac
}

if ! own=$(statuses "$sha"); then
  echo "pending GitHub did not answer for the statuses of $sha"; exit 0
fi
if [ -z "$own" ]; then
  # A run that is queued or running has not posted yet (a --post run posts at once; a check run never does): wait.
  if q=$(live_run); then echo "pending no local-ci status on $sha yet; local CI of it is $q"; exit 0; fi
  echo "none no local-ci status on $sha"; exit 0
fi

# The required jobs are those of the commit's own workflow (TASK-71): a pull request that renames, adds or removes a job
# is held to its own job list, not to the one of the checkout this runs in. The commit is read from the local clone, or
# from GitHub when the clone does not have it yet.
wfpath=.github/workflows/ci.yml
if [ -n "${LOCAL_CI_WORKFLOW:-}" ]; then
  wf=$LOCAL_CI_WORKFLOW
  yaml=$(cat "$wf" 2>/dev/null) || yaml=""
else
  wf="$wfpath at ${sha:0:7}"
  yaml=$(git show "$sha:$wfpath" 2>/dev/null) ||
    yaml=$(gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$wfpath?ref=$sha" 2>/dev/null) ||
    yaml=""
fi
jobs=$(printf '%s\n' "$yaml" | yq '.jobs | keys | .[]' 2>/dev/null | tr -d '\r')
if [ -z "$jobs" ]; then
  echo "pending cannot read the jobs of $wf"; exit 0
fi

red="" superseded="" waiting="" ask_again="" foreign=""
me=$(hostname 2>/dev/null)
for job in $jobs; do
  line=$(printf '%s\n' "$own" | awk -F'\t' -v c="local-ci/$job" '$1 == c { print; exit }')
  s="" desc="" t=""
  [ -n "$line" ] && IFS=$'\t' read -r _ s desc t <<< "$line"
  case "$s" in
    success)
      why=""; accept "local-ci/$job" "$desc" "$t"
      case $? in
        0) ;;
        2) waiting="$waiting local-ci/$job=pending ($why)"; ask_again=1 ;;
        *) desc=${desc//[\"\\]/}; red="$red local-ci/$job=$why ('${desc:0:60}')" ;;
      esac ;;
    error)
      parse error "$desc"
      if [ "${P[kind]}" = superseded ]; then superseded="$superseded local-ci/$job=PR #${P[n]} head is now ${P[from]}"
      else red="$red local-ci/$job=error"
      fi ;;
    failure) red="$red local-ci/$job=$s" ;;
    pending)
      parse pending "$desc"
      [ -n "${P[host]:-}" ] && [ "${P[host]}" = "$me" ] || foreign=1
      waiting="$waiting local-ci/$job=pending" ;;
    *) waiting="$waiting local-ci/$job=${s:-missing}" ;;
  esac
done
if [ -n "$red" ]; then echo "red${red}"; exit 0; fi
if [ -n "$superseded" ]; then echo "superseded${superseded}; ask about the new head"; exit 0; fi
if [ -z "$waiting" ]; then echo "green every job of $(basename "${wf%% at *}") passed locally"; exit 0; fi
# Waiting, on this host, with no live run in the queue: read once more (a run that ended between the reads posted its
# final statuses before it left the queue), then call it stale.
if [ -z "$ask_again" ] && [ -z "$foreign" ]; then
  q=$(live_run); qrc=$?
  if [ "$qrc" = 1 ]; then
    if [ -z "${LOCAL_CI_STATUS_RECHECKED:-}" ]; then
      LOCAL_CI_STATUS_RECHECKED=1 exec bash "$0" "$repo" "$sha"
    fi
    echo "stale${waiting}; no live local CI run of ${sha:0:7} (queue: $q): run it again"; exit 0
  fi
fi
echo "pending${waiting}"
