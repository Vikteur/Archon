#!/usr/bin/env bash
# Triage a red local CI run before an agent works on it (CI plan C17; owner decision D5 of 2026-10-20). A script, not
# a model (P2): it reads the commit's local-ci/<job> statuses and the red jobs' logs in $CI_LOCAL_ROOT/<sha7>/, and
# gives each red job one class:
#   conflict    the job did not run: the pull request does not merge into its base ("merge conflict …" status)
#   infra       the runner could not run it (`failure (infra: …)`), or its log matches a signature in
#               .archon/red-triage/infra.tsv (Docker, ports, network, disk, Gradle daemon, WSL)
#   flaky       its log matches a signature for that job in .archon/red-triage/flaky.tsv that is less than 14 days old
#   main-state  the same job is red (a real run, or timed out) on the base's tip too
#   own         anything else: unknown is own
# Jobs red only because another one is (`not run: needed job … failed`, cancelled, superseded) follow it and get no
# class of their own. The run's class: conflict if any job is, else own, else main-state, else infra or flaky.
# A run that is only infra or flaky gets one rerun, decided here (D5): ci-local.sh --post --rerun-failed on the same
# commit (and pull request, with --pr), which runs only its red jobs again, never the green ones, with
# CI_LOCAL_RERUN_AFTER=<signature> so a green rerun's status reads `…; green on rerun after <signature>`. Once per
# commit: the marker $CI_LOCAL_ROOT/<sha7>.triage says the rerun is spent. After it the run is triaged again, without
# a rerun: a flaky job still red is own (its signature did not explain it), an infra job still red stays infra.
#   red-triage.sh [--pr <number|url>] [--base <branch>] [--no-rerun] [--report <file>] <sha>
# Prints one JSON line {"class": "...", "sha": "...", "rerun": "...", "jobs": "...", "detail": "..."} on stdout (and
# into --report <file>); everything else goes to stderr. class green|own|main-state|conflict|infra; rerun none (no
# rerun was due), green-after:<sig> (the rerun turned it green), red-after:<sig> (it did not), spent (an earlier one
# was used), or off (--no-rerun); jobs "<job>=<class>[:<signature>] …" for the red jobs.
# Exit 0 when triaged: green (nothing for an agent), own or main-state (an agent works on it), conflict (the GitHub
# agent rebases). Exit 3: infra, still red after its one rerun, or with the rerun spent or off: not a code problem, so
# no agent works on it; a person looks at the machine. Exit 1 when it cannot triage (no status on the
# commit, a job still pending, GitHub did not answer); exit 2 on bad usage.
# Every triage is recorded in the CI ledger (event triage); a ledger that cannot be written changes nothing.
# Overrides: CI_LOCAL_ROOT, CI_LOCAL (the runner), RED_TRIAGE_INFRA, RED_TRIAGE_FLAKY (the signature files),
# RED_TRIAGE_TODAY (YYYY-MM-DD, for the expiry), RED_TRIAGE_REPO (owner/repo; default from the origin url).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
top="$(cd "$here/../.." && pwd)"
# Local CI off (local_ci: false in .archon/kit.yaml, kit/SPEC.md Local CI switch): there are no local job logs or
# statuses to classify and no local rerun, so it cannot triage (exit 1): the workflow counts the red as the branch's own.
if . "$here/kit-config.sh" 2>/dev/null && [ "$(kit_get local_ci true)" = false ]; then
  echo "red-triage: local CI is off (local_ci: false in .archon/kit.yaml): nothing local to triage; read the failing GitHub check" >&2
  exit 1
fi
# shellcheck source=../../.claude/scripts/ci-status-grammar.sh
. "$top/.claude/scripts/ci-status-grammar.sh"
# shellcheck source=../../.claude/scripts/ci-ledger.sh
. "$top/.claude/scripts/ci-ledger.sh"
runner=${CI_LOCAL:-$top/.claude/scripts/ci-local.sh}
infra_file=${RED_TRIAGE_INFRA:-$top/.archon/red-triage/infra.tsv}
flaky_file=${RED_TRIAGE_FLAKY:-$top/.archon/red-triage/flaky.tsv}
usage="usage: red-triage.sh [--pr <number|url>] [--base <branch>] [--no-rerun] [--report <file>] <sha>"

pr="" base=main rerun_ok=1 report="" sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr=${2:-}; shift ;;
    --base) base=${2:-}; shift ;;
    --no-rerun) rerun_ok="" ;;
    --report) report=${2:-}; shift ;;
    -*) echo "red-triage: unknown option $1 ($usage)" >&2; exit 2 ;;
    *) sha=$1 ;;
  esac
  shift
done
[[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || { echo "red-triage: $usage" >&2; exit 2; }
[[ "$pr" =~ ^(https://github.com/[^/]+/[^/]+/pull/)?([0-9]+)$ || -z "$pr" ]] || { echo "red-triage: --pr is a number or a pull request url" >&2; exit 2; }
pr=${pr##*/}
[ -n "$base" ] || { echo "red-triage: --base needs a branch" >&2; exit 2; }
sha=$(git rev-parse -q --verify "$sha^{commit}" 2>/dev/null || echo "$sha")
short=${sha:0:7}

repo=${RED_TRIAGE_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')}
main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
ci_root=${CI_LOCAL_ROOT:-$(dirname "${main:-.}")/ci-local}
marker=$ci_root/$short.triage

# statuses <sha>: "<job>\t<state>\t<description>", the newest status of each local-ci/* context; exit 1 when GitHub does
# not answer. Newest by time, then id, as local-ci-status.sh picks it.
statuses() {
  local all
  all=$(gh api --paginate "repos/$repo/commits/$1/statuses?per_page=100" \
    -q '.[] | select(.context | startswith("local-ci/")) | [.updated_at, (.id | tostring), .context, .state, (.description // "")] | @tsv' \
    2>/dev/null) || return 1
  printf '%s\n' "$all" | tr -d '\r' | sed '/^$/d' | sort -t$'\t' -k1,1r -k2,2nr \
    | awk -F'\t' '!seen[$3]++ { sub(/^local-ci\//, "", $3); print $3 "\t" $4 "\t" $5 }'
}

# signature <job>: the id of the first signature its log matches, as infra:<id> or flaky:<id>; nothing when none does.
signature() {
  local log=$ci_root/$short/$1.log id added job re today
  [ -s "$log" ] || return 0
  while IFS=$'\t' read -r id re; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -n "$re" ] && grep -qE -- "$re" "$log" && { echo "infra:$id"; return 0; }
  done < <(cat "$infra_file" 2>/dev/null)
  today=${RED_TRIAGE_TODAY:-$(date +%F)}
  while IFS=$'\t' read -r id added job re; do
    case "$id" in ''|'#'*) continue ;; esac
    [ "$job" = "$1" ] && [ -n "$re" ] || continue
    expires=$(date -d "$added + 14 days" +%F 2>/dev/null) || { echo "red-triage: flaky signature $id has no valid date ($added); ignored" >&2; continue; }
    [[ "$today" < "$expires" ]] || { echo "red-triage: flaky signature $id expired on $expires; ignored" >&2; continue; }
    grep -qE -- "$re" "$log" && { echo "flaky:$id"; return 0; }
  done < <(cat "$flaky_file" 2>/dev/null)
}

# red_on_base <job>: is the job red, by a real run or a timeout, on the base's tip?
base_tip="" base_statuses=""
red_on_base() {
  if [ -z "$base_tip" ]; then
    git fetch -q origin "$base" 2>/dev/null || echo "red-triage: fetching origin/$base failed; using the last fetched tip" >&2
    base_tip=$(git rev-parse -q --verify "origin/$base" 2>/dev/null) || base_tip=-
    if [ "$base_tip" != - ] && [ "$base_tip" != "$sha" ]; then
      base_statuses=$(statuses "$base_tip") || { echo "red-triage: cannot read the statuses of $base's tip" >&2; base_statuses=""; }
    fi
  fi
  local line state desc kind
  line=$(printf '%s\n' "$base_statuses" | awk -F'\t' -v j="$1" '$1 == j { print; exit }')
  [ -n "$line" ] || return 1
  IFS=$'\t' read -r _ state desc <<< "$line"
  [ "$state" = failure ] || return 1
  kind=$(ci_status_get kind "$state" "$desc")
  [ "$kind" = ran ] || [ "$kind" = timedout ]
}

# triage: classify the commit's statuses; sets class, jobs, sig (the first rerun signature), detail. Return 1 when it
# cannot (no status, a job pending, GitHub did not answer).
triage() {
  local all job state desc kind reason c any=""
  class="" jobs="" sig="" detail=""
  all=$(statuses "$sha") || { detail="GitHub did not answer for the statuses of $short"; return 1; }
  [ -n "$all" ] || { detail="no local-ci status on $short"; return 1; }
  local conflict="" own="" mainstate="" rerun="" follow=""
  while IFS=$'\t' read -r job state desc; do
    case "$state" in
      success) continue ;;
      pending) detail="local-ci/$job is still pending on $short"; return 1 ;;
    esac
    kind=$(ci_status_get kind "$state" "$desc"); reason=$(ci_status_get reason "$state" "$desc")
    case "$kind" in
      notrun)
        case "$reason" in
          "merge conflict"*) c=conflict ;;
          "not run: needed job"*) c=follow ;;
          *) c=own ;;
        esac ;;
      cancelled|superseded) c=follow ;;
      infra) c="infra:runner-${reason// /-}" ;;
      *)
        c=$(signature "$job")
        if [ -z "$c" ]; then
          if red_on_base "$job"; then c=main-state; else c=own; fi
        fi ;;
    esac
    jobs+="${jobs:+ }$job=$c"
    case "$c" in
      conflict) conflict=1 ;;
      own) own=1 ;;
      main-state) mainstate=1 ;;
      follow) follow=1 ;;
      infra:*|flaky:*) rerun=1; [ -n "$sig" ] || sig=$c ;;
    esac
  done <<< "$all"
  if [ -z "$jobs" ]; then class=green; detail="every local-ci status on $short is a success"
  elif [ -n "$conflict" ]; then class=conflict; detail="$short does not merge into its base: rebase it, then CI runs again"
  elif [ -n "$own" ]; then class=own; detail="a red the triage cannot explain: an agent works on it"
  elif [ -n "$mainstate" ]; then class=main-state; detail="the same job is red on $base's tip ${base_tip:0:7}: inherited from $base"
  elif [ -n "$rerun" ]; then class=${sig%%:*}; detail="explained by $sig"
  else class=own; detail="only jobs that follow another red one, and no red one: unknown is own"
  fi
  return 0
}

answer() { # answer <exit code> <rerun>: the JSON line, the report, the ledger, exit
  local line
  line=$(node -e 'console.log(JSON.stringify({ class: process.argv[1], sha: process.argv[2], rerun: process.argv[3], jobs: process.argv[4], detail: process.argv[5] }))' \
    "$class" "$sha" "$2" "$jobs" "$detail")
  printf '%s\n' "$line"
  [ -z "$report" ] || printf '%s\n' "$line" > "$report"
  ci_ledger triage --arg sha "$sha" --arg class "$class" --arg rerun "$2" --arg jobs "$jobs" ${pr:+--arg pr "$pr"}
  exit "$1"
}

if ! triage; then
  echo "red-triage: cannot triage: $detail" >&2
  class=none; answer 1 none
fi
case "$class" in green|own|main-state|conflict) answer 0 none ;; esac

# Only infra or flaky reds: the one rerun (D5).
if [ -z "$rerun_ok" ]; then
  [ "$class" = flaky ] && { class=own; detail="flaky ($sig), but --no-rerun: an agent works on it"; answer 0 off; }
  detail="$detail; no rerun (--no-rerun)"; answer 3 off
fi
if [ -e "$marker" ]; then
  [ "$class" = flaky ] && { class=own; detail="flaky ($sig) again after its one rerun: an agent works on it"; answer 0 spent; }
  detail="$detail, and the one rerun of $short is spent ($(head -1 "$marker"))"; answer 3 spent
fi
mkdir -p "$ci_root"
printf '%s rerun after %s: %s\n' "$(date -u +%FT%TZ)" "$sig" "$jobs" > "$marker"
echo "red-triage: $short is red only by $jobs: one rerun of its red jobs, after $sig" >&2
target=$sha; [ -z "$pr" ] || target=$pr:$sha
CI_LOCAL_RERUN_AFTER=$sig CI_LOCAL_CALLER=red-triage bash "$runner" --post --rerun-failed "$target" >&2
first=$sig
if ! triage; then
  echo "red-triage: cannot triage after the rerun: $detail" >&2
  class=none; answer 1 "red-after:$first"
fi
case "$class" in
  green)
    all=$(statuses "$sha") || all=""
    grep -q "green on rerun after $first" <<< "$all" \
      || echo "red-triage: the rerun is green, but no status says 'green on rerun after $first' (ci-local does not mark it yet)" >&2
    detail="green on rerun after $first"; answer 0 "green-after:$first" ;;
  own|main-state|conflict) answer 0 "red-after:$first" ;;
  flaky) class=own; detail="flaky ($sig) still red after its one rerun: an agent works on it"; answer 0 "red-after:$first" ;;
  *) detail="$detail, still red after its one rerun"; answer 3 "red-after:$first" ;;
esac
