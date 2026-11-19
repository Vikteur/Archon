#!/usr/bin/env bash
# Recover one ended build-feature run: classify how it ended, record the decision, do the mechanical step, and ping the
# owner when a person is needed (P2: a script, not a model; owner decision 2026-10-20, D13: self-repair is allowed,
# with a breaker of 2 failures of one signature in 60 min, and recover-run may start local CI).
#   recover-run.sh <run id> [--dry-run] [--json-file <file>] [--facts-file <file>] [--now <ISO time>]
# Call it on every run end, completed ones too (S17, S18). It never sleeps and never waits: a step that must wait
# (a resume before its not_before, local CI still running, a red main) returns at once with result "wait", and the
# caller calls again later. A wait is not recorded, so polling spends no budget.
# Steps (classify-failure.js names them; see classify-failure.signatures.json):
#   resume              archon workflow resume --detach <run> (once not_before has passed)
#   sync-relaunch       sync-main.sh in the main checkout, then a new launch: launch-run.sh <ticket> when it exists,
#                       else `archon workflow run build-feature --detach "Build <ticket>"` (the run started no node)
#   ci-local-post       start .claude/scripts/ci-local.sh --post <pr number> in the background; result "wait"
#   ci-local-post-main  start ci-local.sh --post <merge sha> (main-ci's sha) in the background; result "wait"; not
#                       when local-ci-status.sh already shows a result for it (pending waits, red pings)
#   wait-local-ci, wait-main-green   nothing; result "wait"
#   red-triage          start red-triage.sh --pr <pr number> <head> in the background (a listed flake gets its one
#                       rerun); result "wait", and the next call resumes a green head or parks a red one (S22)
#   rebase-and-resume   rebase-and-resume.sh <run> --signature <S>; its exit 3 (conflict) or 1 asks. Its exit 4 (YAML
#                       drift) is tried once a run with --keep-launch-yaml (owner decision 2026-10-23, TASK-7.3: nodes
#                       that only changed keep the launch YAML); a drift it does not cover, or a second one, asks
#   cleanup-merged      cleanup-merged.sh <branch> <worktree>; ticket edits left behind are named in `next`
#                       (commit-tickets.sh pushes to main, which this script never does: D14)
#   tdd-shape-fix       tdd-shape-fix.sh <run> when it exists, else the run is parked
#   park                park-ticket.sh <ticket> -m <why> --run <run> [--pr <pr>] --no-commit, then recovery-state.js
#                       park; no ticket or no park-ticket.sh asks instead (`next` names the commit-tickets.sh call)
#   ask (any step)      nothing runs; the owner is pinged (act)
# Pings go through notify-owner.sh <info|warn|act> <key> <subject> [--about pr:<n>], once per run, signature and step
# (--about when the pull request is known, so notify-owner.sh holds it open until that pull request is resolved); the subject
# holds only the run id, ticket id, signature, step name and a fixed phrase (free text stays in the log); a missing
# notifier or a failed ping is logged ("ping not delivered") and never fails this script. A `digest` ping is only
# reported in the output, for the digest.
# --dry-run classifies and says what it would do: nothing is recorded, run or pinged. Use it for the first week (D13).
# Prints one JSON line {run, signature, action, step, done, result, ping, ping_text, not_before, next, decision}.
# Exit 0: handled, waiting, parked or nothing to do. Exit 1: the run cannot be read, or a step failed (it says which).
# Exit 2: usage. Exit 3: a person is needed (ask; the owner was pinged).
# Overrides for the tests: ARCHON, RECOVERY_DIR, RECOVER_SCRIPTS_DIR (the folder of sync-main.sh, launch-run.sh,
# rebase-and-resume.sh, cleanup-merged.sh, tdd-shape-fix.sh, park-ticket.sh, red-triage.sh, local-ci-status.sh and
# notify-owner.sh;
# default: beside this script), CI_LOCAL (ci-local.sh), RECOVER_MAIN (the main checkout), RECOVER_REPO (owner/repo).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$here/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
BUILD_WORKFLOW="$(kit_get build_workflow build-feature BUILD_WORKFLOW)"
scripts=${RECOVER_SCRIPTS_DIR:-$here}
archon=${ARCHON:-archon}
run="" dry=false json_file="" pass=()
usage() { echo "recover-run: $1" >&2; echo "usage: recover-run.sh <run id> [--dry-run] [--json-file <file>] [--facts-file <file>] [--now <ISO time>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true ;;
    --json-file) [ $# -ge 2 ] || usage "$1 needs a value"; json_file=$2; shift ;;
    --facts-file|--now) [ $# -ge 2 ] || usage "$1 needs a value"; pass+=("$1" "$2"); shift ;;
    -*) usage "unknown option $1" ;;
    *) [ -z "$run" ] || usage "one run id only"; run=$1 ;;
  esac
  shift
done
[ -n "$run" ] || usage "a run id is required"
[[ "$run" =~ ^[A-Za-z0-9-]+$ ]] || usage "not a run id: $run"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
main=${RECOVER_MAIN:-$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')}

# One read of the run, shared with the classifier.
if [ -n "$json_file" ]; then
  cp "$json_file" "$tmp/run.json" 2>/dev/null || { echo "recover-run: cannot read $json_file" >&2; exit 1; }
else
  "$archon" workflow get "$run" --json --verbose > "$tmp/run.json" 2>/dev/null || { echo "recover-run: cannot read run $run from archon" >&2; exit 1; }
fi
jq -e . "$tmp/run.json" >/dev/null 2>&1 || { echo "recover-run: run $run is not readable JSON" >&2; exit 1; }
jq -c '.run // .' "$tmp/run.json" > "$tmp/r.json"

decision=$(node "$here/classify-failure.js" "$run" --json-file "$tmp/r.json" "${pass[@]}" 2>"$tmp/classify.err"); crc=$?
case "$crc" in 0|3|4|5) ;; *) echo "recover-run: classify-failure.js failed (exit $crc): $(head -1 "$tmp/classify.err")" >&2; exit 1 ;; esac
d() { jq -r ".$1 // empty" <<< "$decision"; }
sig=$(d signature) action=$(d action) step=$(d step) ping=$(d ping) ticket=$(d ticket) pr=$(d pr) head=$(d head)
not_before=$(d not_before) now=$(d at)
wt=$(jq -r '.working_path // empty' "$tmp/r.json")
branch=""; [ -n "$wt" ] && [ -d "$wt" ] && branch=$(git -C "$wt" symbolic-ref --short -q HEAD || true)

done_=false result="" next="" ping_text=""
finish() { # finish <exit>
  jq -cn --arg run "$run" --arg sig "$sig" --arg action "$action" --arg step "$step" --argjson done "$done_" \
    --arg result "$result" --arg ping "$ping" --arg ping_text "$ping_text" --arg nb "$not_before" --arg next "$next" \
    --argjson decision "$decision" \
    '{run: $run, signature: $sig, action: $action, step: (if $step == "" then null else $step end), done: $done,
      result: $result, ping: $ping, ping_text: (if $ping_text == "" then null else $ping_text end),
      not_before: (if $nb == "" then null else $nb end), next: (if $next == "" then null else $next end), decision: $decision}'
  exit "$1"
}

keyname() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
ping_owner() { # ping_owner <info|warn|act> <fixed phrase> [free text]: once per run, signature and step; never fails
  # The subject carries only ids and fixed words (the run id, the ticket id, the signature, the step name, a fixed
  # phrase); free text (reasons, script output) stays in this script's stderr and output, never in the ping.
  local tk="" sg="" st
  [[ "$ticket" =~ ^TASK-[0-9]+(\.[0-9]+)*$ ]] && tk=$ticket
  [[ "$sig" =~ ^S[0-9]{2}$ ]] && sg=$sig
  st=$(keyname "${step:-none}")
  local subject="Run ${run:0:8}${tk:+ $tk}${sg:+ $sg} $st: $2"
  ping_text=$subject
  [ -n "${3:-}" ] && echo "recover-run: $subject: $3" >&2
  $dry && return 0
  local key base mark
  key=$(keyname "recover-${run:0:8}-${sg:-S00}-$st")
  base=${RECOVERY_DIR:-$(dirname "${main:-.}")/recovery}
  mark="$base/pinged/$key"
  [ -e "$mark" ] && { ping_text="$ping_text (already pinged)"; return 0; }
  local about=()
  [[ "${pr##*/}" =~ ^[0-9]+$ ]] && about=(--about "pr:${pr##*/}")
  if [ -f "$scripts/notify-owner.sh" ] && bash "$scripts/notify-owner.sh" "$1" "$key" "$subject" "${about[@]}" >/dev/null 2>&1; then
    mkdir -p "$base/pinged" && : > "$mark"
  else
    echo "recover-run: ping not delivered: $subject" >&2
    ping_text="$ping_text (ping not delivered)"
  fi
}
record() { $dry || node "$here/recovery-state.js" record - <<< "$decision" >/dev/null 2>"$tmp/state.err" \
  || echo "recover-run: the recovery state was not written: $(head -1 "$tmp/state.err")" >&2; }
set_result() { $dry || node "$here/recovery-state.js" result "$run" "$1" >/dev/null 2>&1 || true; }
ask() { # ask <why>: a person is needed
  action=ask result="ask: $1"
  ping_owner act "needs you" "$1"
  finish 3
}
would() { result="dry run: would $1"; finish 0; }
waiting() { result="wait: $1"; finish 0; }

# Nothing to do, or a wait: no record, no budget spent.
if [ "$action" = none ]; then
  record; result="nothing to do ($sig)"; done_=true; finish 0
fi
case "$step" in
  wait-local-ci) waiting "local CI is still running on the head" ;;
  wait-main-green)
    [ "$ping" = now ] && ping_owner warn "main red over 30 min, waiting"
    waiting "main is red; rebase and resume once it is green" ;;
esac
if [ -n "$not_before" ] && [ "$action" = resume ] \
  && [ "$(date -u -d "$not_before" +%s 2>/dev/null || echo 0)" -gt "$(date -u -d "${now:-now}" +%s 2>/dev/null || date -u +%s)" ]; then
  waiting "resume not before $not_before"
fi

if [ "$action" = ask ]; then
  $dry && would "ask the owner: $(d reason)"
  record; ask "$(d reason)"
fi

if $dry; then
  case "$action" in
    park) would "park ${ticket:-the run}: $(d reason)" ;;
    *) would "$step ($(d reason))" ;;
  esac
fi
record

park() { # park <why>
  local why=$1
  if [ -z "$ticket" ]; then ask "park needed but the ticket is unknown: $why"; fi
  if [ ! -f "$scripts/park-ticket.sh" ]; then ask "park needed but park-ticket.sh is missing: $why"; fi
  local args=("$ticket" -m "$why" --run "$run" --no-commit)
  [ -n "$pr" ] && args+=(--pr "$pr")
  bash "$scripts/park-ticket.sh" "${args[@]}" >"$tmp/park.out" 2>&1; local rc=$?
  case "$rc" in
    0|3) ;;
    *) set_result "park failed (exit $rc)"; ask "park-ticket.sh failed (exit $rc): $(tail -1 "$tmp/park.out")" ;;
  esac
  node "$here/recovery-state.js" park "$run" "$why" >/dev/null 2>&1 || true
  set_result "parked"
  done_=true result="parked $ticket: $why"
  next="bash .archon/scripts/commit-tickets.sh $ticket"
  [ "$ping" = now ] && ping_owner warn "parked" "$why"
  finish 0
}

if [ "$action" = park ]; then park "$(d reason)"; fi

start_ci() { # start_ci <pr number or sha>: local CI in the background, never waited for
  local ci=${CI_LOCAL:-$main/.claude/scripts/ci-local.sh} base=${RECOVERY_DIR:-$(dirname "${main:-.}")/recovery}
  [ -f "$ci" ] || { set_result "ci-local.sh missing"; echo "recover-run: $ci is missing" >&2; result="failed: ci-local.sh missing"; finish 1; }
  mkdir -p "$base/ci-local"
  local log="$base/ci-local/${run:0:8}-$1.log"
  (cd "${main:-.}" && setsid nohup bash "$ci" --post "$1" > "$log" 2>&1 < /dev/null &) || { result="failed: could not start local CI"; finish 1; }
  set_result "local CI started on $1"
  done_=true; result="wait: local CI started on $1 (log $(basename "$log")); call again when it has posted"
  finish 0
}

start_triage() { # start_triage <pr number> <sha>: red-triage.sh in the background, never waited for
  local base=${RECOVERY_DIR:-$(dirname "${main:-.}")/recovery}
  [ -f "$scripts/red-triage.sh" ] || { set_result "red-triage.sh missing"; result="failed: red-triage.sh missing"; finish 1; }
  mkdir -p "$base/red-triage"
  local log="$base/red-triage/${run:0:8}-${2:0:12}.log"
  (cd "${main:-.}" && setsid nohup bash "$scripts/red-triage.sh" --pr "$1" "$2" > "$log" 2>&1 < /dev/null &) \
    || { result="failed: could not start red-triage"; finish 1; }
  set_result "red-triage started on ${2:0:12}"
  done_=true; result="wait: red-triage started on ${2:0:12} (log $(basename "$log")); call again when it has posted"
  finish 0
}

case "$step" in
  resume)
    if "$archon" workflow resume --detach "$run" >"$tmp/step.out" 2>&1; then
      set_result "resumed"; done_=true result="resumed"
    else
      set_result "resume failed"; result="failed: archon workflow resume: $(tail -1 "$tmp/step.out")"; finish 1
    fi ;;
  sync-relaunch)
    [ -n "$ticket" ] || ask "the launch failed and the ticket is unknown"
    if ! (cd "${main:-.}" && bash "$scripts/sync-main.sh") >"$tmp/step.out" 2>&1; then
      set_result "sync-main refused"; ask "sync-main.sh refused: $(tail -1 "$tmp/step.out")"
    fi
    if [ -f "$scripts/launch-run.sh" ]; then launch=(bash "$scripts/launch-run.sh" "$ticket")
    else launch=("$archon" workflow run "$BUILD_WORKFLOW" --detach "Build $ticket"); fi
    if (cd "${main:-.}" && "${launch[@]}") >"$tmp/step.out" 2>&1; then
      set_result "synced main, launched $ticket again"; done_=true result="synced main, launched $ticket again"
    else
      set_result "relaunch failed"; result="failed: the launch: $(tail -1 "$tmp/step.out")"; finish 1
    fi ;;
  ci-local-post)
    num=${pr##*/}
    [[ "$num" =~ ^[0-9]+$ ]] || ask "local CI needed but the pull request is unknown"
    start_ci "$num" ;;
  red-triage)
    num=${pr##*/}
    [[ "$num" =~ ^[0-9]+$ ]] || ask "red-triage needed but the pull request is unknown"
    [[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || ask "red-triage needed but the run's head is unknown"
    start_triage "$num" "$head" ;;
  ci-local-post-main)
    sha=$(jq -r '(.nodes // [])[] | select(.nodeId == "main-ci") | .outputPreview // empty' "$tmp/r.json" | jq -r '.sha // empty' 2>/dev/null)
    [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || ask "local CI on main needed but main-ci names no sha"
    # The merge commit may have its local CI by now (an earlier call started it): never start a second one.
    repo=${RECOVER_REPO:-$(cd "${main:-.}" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
    st=$([ -n "$repo" ] && bash "$scripts/local-ci-status.sh" "$repo" "$sha" 2>/dev/null | awk '{print $1}')
    case "$st" in
      pending|green|red) set_result "local CI on $sha is $st"; done_=true result="local CI on main's $sha is already $st"
        [ "$st" = pending ] && result="wait: $result"
        [ "$st" = red ] && ping_owner warn "local CI red on main ${sha:0:12}"
        finish 0 ;;
    esac
    start_ci "$sha" ;;
  rebase-and-resume)
    bash "$scripts/rebase-and-resume.sh" "$run" --signature "$sig" >"$tmp/step.out" 2>&1; rc=$?
    case "$rc" in
      0) done_=true result="rebased and resumed" ;;
      3) ask "the rebase onto main conflicts (branch left as it was)" ;;
      4) # Once a run, the drift of nodes that only changed is accepted and the launch YAML kept (TASK-7.3).
         if ! node "$here/recovery-state.js" show "$run" 2>/dev/null | jq -e '[.history[]?.result // ""] | any(test("launch YAML kept"))' >/dev/null 2>&1 \
           && bash "$scripts/rebase-and-resume.sh" "$run" --signature "$sig" --keep-launch-yaml >"$tmp/keep.out" 2>&1; then
           set_result "rebased and resumed, launch YAML kept (YAML drift)"
           done_=true result="rebased and resumed, launch YAML kept (YAML drift)"
         else
           ask "the YAML changed where the resume would run; it needs a new run, never a resume: $(grep -o 'differs.*' "$tmp/step.out" | head -1)"
         fi ;;
      *) ask "rebase-and-resume.sh refused (exit $rc): $(grep 'rebase-and-resume:' "$tmp/step.out" | head -1)" ;;
    esac ;;
  cleanup-merged)
    [ -n "$branch" ] || ask "cleanup needed but the run's worktree or branch is gone"
    if bash "$scripts/cleanup-merged.sh" "$branch" "$wt" >"$tmp/step.out" 2>&1; then
      set_result "cleaned up"; done_=true result="cleaned up $branch"
      [ -n "$ticket" ] && next="bash .archon/scripts/commit-tickets.sh $ticket (when the ticket's edits are left in the main checkout; it pushes to main)"
    else
      set_result "cleanup refused"; ask "cleanup-merged.sh refused: $(tail -1 "$tmp/step.out")"
    fi ;;
  tdd-shape-fix)
    if [ -f "$scripts/tdd-shape-fix.sh" ]; then
      if bash "$scripts/tdd-shape-fix.sh" "$run" >"$tmp/step.out" 2>&1; then
        set_result "shape fixed"; done_=true result="commit shape fixed"
        next="bash .archon/scripts/recover-run.sh $run (resume after the shape fix)"
      else
        park "the TDD shape fix failed: $(tail -1 "$tmp/step.out")"
      fi
    else
      park "TDD commit shape only, and no tdd-shape-fix.sh to repair it"
    fi ;;
  *) ask "no mechanical step for $action/${step:-none}" ;;
esac
[ "$ping" = now ] && ping_owner info "handled" "$result"
finish 0
