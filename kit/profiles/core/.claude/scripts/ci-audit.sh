#!/usr/bin/env bash
# The reuse audit and the daily full run of main (CI plan C14, owner decision D2 as tightened 2026-10-20): the safety net
# under run-or-reuse. A reused status is only as good as the run it points at, so this checks every one against the CI
# ledger, independently of the reader that accepted it, and runs main once a day with no reuse at all.
#   ci-audit.sh check [--no-wait] <sha>...   audit the reused local-ci/<job> statuses on these commits
#   ci-audit.sh daily [--no-wait]            audit main's commits of the last CI_AUDIT_HOURS (48) hours, then start the
#                                            full run of main's tip when the last one is over 24 h old
#   ci-audit.sh last                         when the last full run started, and whether the kill switch is on
# check: for each commit, the newest status of each local-ci/* context is read; a success of kind reused (the status
# grammar, ci-status-grammar.sh) must have, in the ledger, a verdict of the same job on the source commit (its sha
# starts with the status's <sha12>) that is a success of kind ran (a real run, never a reuse: no chains; never the
# legacy form), with the same fp, at most CI_PLAN_MAX_AGE seconds (86400 = 24 h) before the reuse was posted. A reuse
# that fails this, a ledger that cannot be read, or a reused description that does not parse is a miss. A same-tree
# reuse (`reused from <sha12>; same tree`, owner decision 2026-10-23) is checked the same way, with no fp: instead, the
# source run's tested tree (its ledger start line) must be the commit's own tree. On a miss:
#   1. the kill switch goes on: the file $CI_PLAN_SCOPE_FILE (default $CI_LOCAL_ROOT/scope-all, the one ci-plan.sh reads)
#      is written with the reason, so no run reuses anything any more. Only the owner removes it; nothing here does;
#   2. the commit is run again in full: CI_SCOPE=all ci-local.sh --post --all <sha> (in the background with --no-wait),
#      so its statuses become real runs.
# The switch goes on before the rerun starts, so the rerun cannot reuse either. Every audited reuse is written to the
# ledger as an "audit" event (sha, job, from, result ok|miss, why). A status that is not a reuse is not audited.
# daily: the audit above over main's recent commits, then the daily full run (D2): when the stamp file
# $CI_LOCAL_ROOT/full-run.last ("<epoch> <sha>") is missing or over CI_AUDIT_FULL_AGE seconds (86400) old, main's tip
# (or, when the tip changes only backlog/, docs/retro/ or docs/tokenomics/, the newest commit under it that changes
# anything else: ci-skip.sh, which counts backlog/ only with backlog: true in .archon/kit.yaml) is run with no reuse
# (CI_SCOPE=all ci-local.sh --post --all <tip>), whether or not anything was reused; the stamp is written when it
# starts, and the ledger gets a "full-run" event. There is no cron here: a person calls it, after a merge or at the
# start of a day; a second call within the 24 h starts nothing.
# Exit: 0 nothing missed, 1 a miss (the switch is on), 2 usage, 3 cannot audit (GitHub or git did not answer; nothing
# is decided and no switch is set). Everything goes to stderr but the `last` answer.
# Overrides: CI_LOCAL (the runner), CI_LOCAL_ROOT, CI_LEDGER, CI_PLAN_SCOPE_FILE, CI_PLAN_MAX_AGE, CI_AUDIT_FULL_AGE,
# CI_AUDIT_HOURS, CI_AUDIT_REPO (<owner>/<name>; default from origin's url), CI_STATUS_GRAMMAR, CI_AUDIT_NOW (epoch).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner=${CI_LOCAL:-$here/ci-local.sh}
grammar=${CI_STATUS_GRAMMAR:-$here/ci-status-grammar.sh}
usage() { echo "usage: ci-audit.sh check [--no-wait] <sha>... | daily [--no-wait] | last" >&2; exit 2; }

main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main" ] || { echo "ci-audit: not in a git checkout" >&2; exit 3; }
ci_root=${CI_LOCAL_ROOT:-$(dirname "$main")/ci-local}
export CI_LEDGER=${CI_LEDGER:-$ci_root/ledger.jsonl}
switch=${CI_PLAN_SCOPE_FILE:-$ci_root/scope-all}
stamp=$ci_root/full-run.last
max_age=${CI_PLAN_MAX_AGE:-86400}
full_age=${CI_AUDIT_FULL_AGE:-86400}
now=${CI_AUDIT_NOW:-$(date -u +%s)}
# shellcheck source=ci-status-grammar.sh
. "$grammar" 2>/dev/null && declare -F ci_status_parse > /dev/null \
  || { echo "ci-audit: the status grammar $grammar cannot be read" >&2; exit 3; }
# shellcheck source=ci-ledger.sh
. "$here/ci-ledger.sh"
export CI_LOCAL_CALLER=${CI_LOCAL_CALLER:-ci-audit}

repo=${CI_AUDIT_REPO:-}
if [ -z "$repo" ]; then
  repo=$(git -C "$main" remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
fi

# statuses <sha>: "<context>\t<state>\t<description>\t<updated_at>", the newest status of each local-ci/* context
# (the same pick as local-ci-status.sh); exit 1 when GitHub does not answer.
statuses() {
  local all
  all=$(gh api --paginate "repos/$repo/commits/$1/statuses?per_page=100" \
    -q '.[] | select(.context | startswith("local-ci/")) | [.updated_at, (.id | tostring), .context, .state, (.description // "")] | @tsv' \
    2>/dev/null) || return 1
  printf '%s\n' "$all" | tr -d '\r' | sed '/^$/d' | sort -t$'\t' -k1,1r -k2,2nr \
    | awk -F'\t' '!seen[$3]++ { print $3 "\t" $4 "\t" $5 "\t" $1 }'
}

declare -A P=()
parse() { # parse <state> <description>: the grammar's fields into P; read as data, never evaluated
  local k v
  P=()
  while IFS='=' read -r k v; do [ -n "$k" ] && P[$k]=$v; done < <(ci_status_parse "$1" "$2")
  [ -n "${P[kind]:-}" ] || P[kind]=unknown
}

# sources <job> <sha12>: "<t>\t<state>\t<description>" of every ledger verdict of that job on a commit starting with
# <sha12>. The field names of both ledger writers are read (ev/event, t/ts, state/status).
sources() {
  jq -r --arg job "$1" --arg from "$2" '
    select(((.ev // .event) == "verdict") and .job == $job and ((.sha // "") | startswith($from)))
    | [((.t // .ts) | tostring), (.state // .status // ""), (.description // "")] | @tsv' "$CI_LEDGER" 2>/dev/null
}

# verify <job> <from sha12> <fp10> <reuse epoch>: exit 0 when the ledger proves the reuse; else prints why.
verify() {
  local job=$1 from=$2 fp=$3 at=$4 t st desc found="" why
  why="no real run of $job on $from in the ledger"
  [ -r "$CI_LEDGER" ] || { echo "the ledger $CI_LEDGER cannot be read"; return 1; }
  while IFS=$'\t' read -r t st desc; do
    [ -n "$t" ] || continue
    st=${st,,}
    [ "$st" = success ] || { why="the source run of $job on $from is $st"; continue; }
    parse success "$desc"
    if [ "${P[kind]}" != ran ] || [ "${P[legacy]:-0}" = 1 ]; then why="the source of $job on $from is not a real run (${P[kind]}): never chained"; continue; fi
    if [ "${P[fp]:0:10}" != "$fp" ]; then why="the source run of $job on $from has fp=${P[fp]:-none}, the reuse fp=$fp"; continue; fi
    if [ "$t" -gt "$at" ] 2>/dev/null; then why="the source run of $job on $from is later than the reuse"; continue; fi
    if [ $((at - t)) -gt "$max_age" ] 2>/dev/null; then
      why="the source run of $job on $from ran $(( (at - t) / 3600 )) h before the reuse, over the $((max_age / 3600)) h limit (D2)"; continue
    fi
    found=1
  done < <(sources "$job" "$from")
  [ -n "$found" ] && return 0
  echo "$why"; return 1
}

# verify_same <job> <from sha12> <merge sha> <reuse epoch>: exit 0 when the ledger proves a same-tree reuse (owner
# decision 2026-10-23): a real green run of the job on the source, at most max_age seconds before the reuse, in a run
# whose tested tree (the tree of its start line) is the merge commit's tree; else prints why.
verify_same() {
  local job=$1 from=$2 at=$4 tree t st desc run tested found="" why
  [ -r "$CI_LEDGER" ] || { echo "the ledger $CI_LEDGER cannot be read"; return 1; }
  tree=$(git -C "$main" rev-parse -q --verify "$3^{tree}" 2>/dev/null) || { echo "the tree of ${3:0:7} cannot be read"; return 1; }
  why="no real run of $job on $from in the ledger"
  while IFS=$'\t' read -r t st desc run; do
    [ -n "$t" ] || continue
    st=${st,,}
    [ "$st" = success ] || { why="the source run of $job on $from is $st"; continue; }
    parse success "$desc"
    if [ "${P[kind]}" != ran ] || [ "${P[legacy]:-0}" = 1 ]; then why="the source of $job on $from is not a real run (${P[kind]}): never chained"; continue; fi
    if [ "$t" -gt "$at" ] 2>/dev/null; then why="the source run of $job on $from is later than the reuse"; continue; fi
    if [ $((at - t)) -gt "$max_age" ] 2>/dev/null; then
      why="the source run of $job on $from ran $(( (at - t) / 3600 )) h before the reuse, over the $((max_age / 3600)) h limit (D2)"; continue
    fi
    tested=$(jq -r --arg r "$run" 'select((.ev // .event) == "start" and .run == $r and $r != "") | .tree // ""' "$CI_LEDGER" 2>/dev/null | tail -n 1)
    [ -n "$tested" ] && [ "$tested" = "$tree" ] || { why="the source run ${run:-?} of $job on $from tested the tree ${tested:-unknown}, not ${tree:0:12}"; continue; }
    found=1
  done < <(jq -r --arg job "$job" --arg from "$from" '
    select(((.ev // .event) == "verdict") and .job == $job and ((.sha // "") | startswith($from)))
    | [((.t // .ts) | tostring), (.state // .status // ""), (.description // ""), (.run // "")] | @tsv' "$CI_LEDGER" 2>/dev/null)
  [ -n "$found" ] && return 0
  echo "$why"; return 1
}

# full <sha> <why> <log name>: run the commit with no reuse at all; in the background with --no-wait.
full() {
  local sha=$1 why=$2 name=$3
  if [ -n "$nowait" ]; then
    mkdir -p "$ci_root/no-wait"
    local launcher=(); command -v setsid > /dev/null && launcher=(setsid)
    CI_SCOPE=all CI_LOCAL_CALLER="ci-audit $why" nohup "${launcher[@]}" bash "$runner" --post --all "$sha" \
      > "$ci_root/no-wait/$name-${sha:0:7}.log" 2>&1 < /dev/null &
    echo "ci-audit: $why: a full run of ${sha:0:7} started in the background ($ci_root/no-wait/$name-${sha:0:7}.log)" >&2
  else
    echo "ci-audit: $why: a full run of ${sha:0:7}" >&2
    CI_SCOPE=all CI_LOCAL_CALLER="ci-audit $why" bash "$runner" --post --all "$sha" >&2
  fi
}

# check <sha>...: sets missed (the commits with a miss); exit 3 when a commit's statuses cannot be read.
missed=() audited=0
check() {
  local sha lines ctx state desc at job why rc=0
  for sha in "$@"; do
    if ! lines=$(statuses "$sha"); then echo "ci-audit: GitHub did not answer for the statuses of $sha" >&2; rc=3; continue; fi
    local miss=""
    while IFS=$'\t' read -r ctx state desc at; do
      [ -n "$ctx" ] && [ "$state" = success ] || continue
      [[ "$desc" == reused* ]] || continue
      job=${ctx#local-ci/} audited=$((audited + 1))
      parse "$state" "$desc"
      if [ "${P[kind]}" != reused ] && [ "${P[kind]}" != same-tree ]; then
        why="the reused status of $job does not parse: '$desc'"
      elif ! at=$(date -u -d "$at" +%s 2>/dev/null); then
        why="the reused status of $job has no readable time"
      elif why=$(if [ "${P[kind]}" = same-tree ]; then verify_same "$job" "${P[from]}" "$sha" "$at"
                 else verify "$job" "${P[from]}" "${P[fp]}" "$at"; fi); then
        ci_ledger audit --arg sha "$sha" --arg job "$job" --arg from "${P[from]}" --arg result ok
        echo "ci-audit: ${sha:0:7} $job: reused from ${P[from]:0:7}, proved by the ledger" >&2
        continue
      fi
      ci_ledger audit --arg sha "$sha" --arg job "$job" --arg from "${P[from]:-}" --arg result miss --arg why "$why"
      echo "ci-audit: MISS ${sha:0:7} $job: $why" >&2
      miss="$miss; $job: $why"
    done <<< "$lines"
    if [ -n "$miss" ]; then
      missed+=("$sha")
      if [ ! -e "$switch" ]; then
        mkdir -p "$(dirname "$switch")"
        printf 'kill switch set by ci-audit.sh at %s: a reused status of %s failed the audit%s\nOnly the owner removes this file (D2).\n' \
          "$(date -u -d "@$now" +%FT%TZ)" "$sha" "$miss" > "$switch"
      fi
      echo "ci-audit: the kill switch $switch is on: no run reuses until the owner removes it" >&2
      full "$sha" "audit miss" audit
    fi
  done
  return $rc
}

cmd=${1:-}; [ $# -gt 0 ] && shift
nowait=""
[ "${1:-}" = --no-wait ] && { nowait=1; shift; }
case "$cmd" in
  check)
    [ $# -gt 0 ] || usage
    check "$@"; rc=$?
    [ ${#missed[@]} -eq 0 ] || exit 1
    exit $rc ;;
  daily)
    [ $# -eq 0 ] || usage
    git -C "$main" fetch -q origin main 2>/dev/null || echo "ci-audit: cannot fetch origin; auditing the origin/main this clone has" >&2
    tip=$(git -C "$main" rev-parse -q --verify origin/main 2>/dev/null) || { echo "ci-audit: no origin/main" >&2; exit 3; }
    # A tip that changes only backlog/, docs/retro/ or docs/tokenomics/ runs no CI (owner decisions 2026-10-22,
    # 2026-10-23): the full run takes the newest commit under it that changes anything else.
    via=$(cd "$main" && bash "$here/../../.archon/scripts/ci-skip.sh" verdict "$tip" 2>/dev/null) && [ -n "$via" ] && tip=$via
    mapfile -t recent < <(git -C "$main" log --format=%H --since="@$((now - ${CI_AUDIT_HOURS:-48} * 3600))" -n 200 origin/main)
    [ ${#recent[@]} -gt 0 ] || recent=("$tip")
    check "${recent[@]}"; rc=$?
    echo "ci-audit: ${#recent[@]} main commit(s), $audited reused status(es) audited, ${#missed[@]} with a miss" >&2
    last=$(cut -d' ' -f1 "$stamp" 2>/dev/null)
    if [[ ! "$last" =~ ^[0-9]+$ ]] || [ $((now - last)) -gt "$full_age" ]; then
      # A commit just rerun after a miss is already a full run.
      if printf '%s\n' "${missed[@]}" | grep -qx "$tip"; then :
      else full "$tip" "daily full run" full; fi
      mkdir -p "$ci_root"; echo "$now $tip" > "$stamp"
      [[ "$last" =~ ^[0-9]+$ ]] || last=null
      ci_ledger full-run --arg sha "$tip" --arg why daily --argjson last "$last"
    else
      echo "ci-audit: the last full run started $(( (now - last) / 3600 )) h ago; the next is due after 24 h" >&2
    fi
    [ ${#missed[@]} -eq 0 ] || exit 1
    exit $rc ;;
  last)
    [ $# -eq 0 ] || usage
    if [ -f "$stamp" ]; then read -r t s < "$stamp"; echo "last full run: $(date -u -d "@$t" +%FT%TZ) on ${s:0:7}"
    else echo "last full run: never"; fi
    if [ -e "$switch" ]; then echo "kill switch: on ($switch)"; else echo "kill switch: off"; fi ;;
  *) usage ;;
esac
