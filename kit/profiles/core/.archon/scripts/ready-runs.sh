#!/usr/bin/env bash
# The runs waiting at their merged node for the delegator or the owner to merge (P2: a script; TASK-69). Such a run is
# still running, so `archon workflow wait` does not return and `archon workflow attention` does not list it: while
# wait-merge.sh waits it keeps a ready record here, and the delegator watches these instead.
#   ready-runs.sh mark <run id> <pr url>    record the run as ready (wait-merge.sh does, with RUN_ID set)
#   ready-runs.sh clear <run id>            remove the record (wait-merge.sh does, when it stops waiting)
#   ready-runs.sh list                      one JSON line {"run", "pr", "since"} per ready run, oldest first ("held":
#                                           true when held). A record whose run is no longer running (cancelled,
#                                           killed) is dropped and removed.
#   ready-runs.sh resolve <run id>          print the full run id. A prefix matches one ready record, else archon
#                                           resolves it; an ambiguous or unknown id exits 2. Every command that takes
#                                           a run id (but mark and clear, which wait-merge.sh calls with the full id)
#                                           resolves it this way, so an 8-character id works everywhere.
#   ready-runs.sh wait <run id>... [--timeout <seconds>]
#                                           return once one of these runs is ready or has ended: print
#                                           {"state": "ready", "run", "pr", "since"} or {"state": "ended", "run",
#                                           "status"} and exit 0. A timeout prints {"state": "timeout"} and exits 1.
#   ready-runs.sh wait --all [--timeout <seconds>]
#                                           watch every live build-feature run, also ones nobody named (R4, T1). Prints
#                                           the first event and exits 0:
#                                             {"state": "ready", "run", "pr", "since", "source": "mark"|"node"}: a ready
#                                               record, or a run whose active nodes include merged without one (pr and
#                                               since then come from its nodes, null when archon does not say);
#                                             {"state": "attention", "run", "status": "paused", "since"}: a paused run;
#                                             {"state": "ended", "run", "status"}: a run an earlier or this wait --all
#                                               saw live has ended;
#                                             {"state": "idle"}: no build-feature run is live and nothing is left to say.
#                                           Ready before attention before ended, oldest run first. A held run is
#                                           skipped for ready and attention; an acknowledged event is not printed
#                                           again. A timeout prints {"state": "timeout"} and exits 1; four failed archon
#                                           polls in a row print {"state": "error", ...} and exit 4.
#   ready-runs.sh ack <run id>              acknowledge the last event wait --all printed for the run, so the next
#                                           wait --all looks past it. Acknowledging an ended run forgets the run.
#   ready-runs.sh hold <run id> [reason]    skip the run for ready and attention (the owner holds its merge)
#   ready-runs.sh unhold <run id>           stop skipping it
# Exit codes: 0 done or an event, 1 timeout, 2 usage or an ambiguous or unknown run id, 4 archon unreachable.
# The records are <run id>.json in $READY_RUNS_DIR (default: merge-queue/ready/ beside the main checkout); holds,
# acknowledgements and the runs wait --all saw live are kept in its .state/ folder.
# Overrides: READY_RUNS_DIR, READY_POLL_SECONDS (15).
set -uo pipefail
# shellcheck source=kit-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
BUILD_WORKFLOW="$(kit_get build_workflow build-feature BUILD_WORKFLOW)"   # the workflow whose runs are watched

usage() {
  echo "ready-runs: $*" >&2
  echo "usage: ready-runs.sh mark <run id> <pr url> | clear <run id> | list | resolve <run id>" >&2
  echo "       | wait (<run id>... | --all) [--timeout <s>] | ack <run id> | hold <run id> [reason] | unhold <run id>" >&2
  exit 2
}
POLL=${READY_POLL_SECONDS:-15}
if [ -z "${READY_RUNS_DIR:-}" ]; then
  main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$main" ] || { echo "ready-runs: not in a git checkout; set READY_RUNS_DIR" >&2; exit 2; }
  READY_RUNS_DIR=$(dirname "$main")/merge-queue/ready
fi
state=$READY_RUNS_DIR/.state
mkdir -p "$READY_RUNS_DIR" "$state/held" "$state/acked" "$state/seen" "$state/last"

status() { # status <run id>: archon's status of the run, "unknown" when archon cannot tell
  archon workflow get "$1" --json 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo unknown
}
ended() { case "$1" in completed|failed|cancelled|rejected) return 0 ;; *) return 1 ;; esac; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# record <run id>: the record of a ready run, after checking its run still runs; nothing (and the record removed) when
# it ended.
record() {
  local f=$READY_RUNS_DIR/$1.json
  [ -f "$f" ] || return 1
  if ended "$(status "$1")"; then rm -f "$f"; return 1; fi
  cat "$f"
}

# resolve <run id>: the full run id on stdout, or a reason on stderr and exit 2. An id with its own record is used as
# given; a prefix of exactly one record's id gives that id; anything else is archon's to resolve (it resolves
# prefixes and refuses an ambiguous one).
resolve() {
  local id=$1 matches out full
  [ -n "$id" ] || { echo "ready-runs: empty run id" >&2; return 2; }
  case "$id" in */*|.*) echo "ready-runs: not a run id: $id" >&2; return 2 ;; esac
  [ -f "$READY_RUNS_DIR/$id.json" ] && { echo "$id"; return 0; }
  matches=$(cd "$READY_RUNS_DIR" && ls -1 -- "$id"*.json 2>/dev/null | sed 's/\.json$//')
  case $(printf '%s' "$matches" | grep -c .) in
    1) echo "$matches"; return 0 ;;
    0) ;;
    *) echo "ready-runs: ambiguous run id $id: $(echo $matches)" >&2; return 2 ;;
  esac
  out=$(archon workflow get "$id" --json 2>/dev/null)
  full=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$full" ]; then
    out=$(printf '%s' "$out" | jq -r '.error // "archon cannot resolve it"' 2>/dev/null | head -1)
    case "$out" in *"more than one"*) echo "ready-runs: ambiguous run id $id: $out" >&2 ;;
                   *) echo "ready-runs: unknown run id $id: ${out:-archon cannot resolve it}" >&2 ;; esac
    return 2
  fi
  echo "$full"
}

held() { [ -f "$state/held/$1" ]; }
acked() { [ "$(cat "$state/acked/$1" 2>/dev/null)" = "$2" ]; }
emit() { # emit <run> <key> <json line>: print an event of wait --all and remember it for ack
  printf '%s' "$2" > "$state/last/$1"; printf '%s\n' "$3"; exit 0
}

# node_detail <run id>: {"pr", "since"} of a run at its merged node, from its nodes (both null when archon does not say)
node_detail() {
  archon workflow runs --json --verbose --status running --limit 20 2>/dev/null | jq -c --arg id "$1" '
    [.runs[]? | select(.id == $id)][0] // {} | (.nodes // []) as $n
    | {pr: ([$n[] | select(.nodeId == "open-pr") | .outputPreview // "" | fromjson? | .pr][0] // null),
       since: ([$n[] | select(.nodeId == "merged") | .startedAt][0] // null)}' 2>/dev/null || echo '{"pr":null,"since":null}'
}

# poll_all: print and exit on the first event of wait --all; return 1 with no event, 4 when archon did not answer.
poll_all() {
  local runs rows id st node at live=0 rec ids=() sts=() nodes=() ats=() i
  runs=$(archon workflow runs --json --limit 50 2>/dev/null) || return 4
  printf '%s' "$runs" | jq -e '.runs | type == "array"' > /dev/null 2>&1 || return 4
  rows=$(printf '%s' "$runs" | jq -r --arg wf "$BUILD_WORKFLOW" '[.runs[] | select(.workflow_name == $wf)] | reverse | .[]
    | [.id, .status, (if ((.active_nodes // []) | index("merged")) then "merged" else "-" end),
       (.attention.at // .last_activity_at // "-")] | @tsv')
  while IFS=$'\t' read -r id st node at; do
    [ -n "$id" ] || continue
    ids+=("$id"); sts+=("$st"); nodes+=("$node"); ats+=("$at")
    case "$st" in running|paused|pending) live=1; : > "$state/seen/$id" ;; esac
  done <<< "$rows"
  for i in "${!ids[@]}"; do # ready, from a record
    id=${ids[$i]}
    case "${sts[$i]}" in running|paused|pending) ;; *) continue ;; esac
    held "$id" || acked "$id" ready || [ ! -f "$READY_RUNS_DIR/$id.json" ] && continue
    rec=$(jq -c '{state: "ready"} + . + {source: "mark"}' "$READY_RUNS_DIR/$id.json" 2>/dev/null) && emit "$id" ready "$rec"
  done
  for i in "${!ids[@]}"; do # ready, from the merged node of a run with no record (one launched without RUN_ID)
    id=${ids[$i]}
    [ "${sts[$i]}" = running ] && [ "${nodes[$i]}" = merged ] && [ ! -f "$READY_RUNS_DIR/$id.json" ] || continue
    held "$id" || acked "$id" ready && continue
    emit "$id" ready "$(node_detail "$id" | jq -c --arg run "$id" '{state: "ready", run: $run, pr, since, source: "node"}')"
  done
  for i in "${!ids[@]}"; do # attention: a paused run
    id=${ids[$i]}
    [ "${sts[$i]}" = paused ] || continue
    held "$id" || acked "$id" "attention:${ats[$i]}" && continue
    emit "$id" "attention:${ats[$i]}" "$(jq -cn --arg run "$id" --arg at "${ats[$i]}" '{state: "attention", run: $run, status: "paused", since: $at}')"
  done
  for i in "${!ids[@]}"; do # ended: a run seen live that is no longer running
    id=${ids[$i]}
    ended "${sts[$i]}" && [ -f "$state/seen/$id" ] || continue
    rm -f "$READY_RUNS_DIR/$id.json"
    acked "$id" ended && continue
    emit "$id" ended "$(jq -cn --arg run "$id" --arg status "${sts[$i]}" '{state: "ended", run: $run, status: $status}')"
  done
  [ "$live" -eq 1 ] && return 1
  echo '{"state":"idle"}'; exit 0
}

cmd=${1:-}; shift || true
case "$cmd" in
  mark)
    [ $# -eq 2 ] || usage "mark needs <run id> <pr url>"
    jq -cn --arg run "$1" --arg pr "$2" --arg since "$(now)" '{run: $run, pr: $pr, since: $since}' \
      > "$READY_RUNS_DIR/$1.json.tmp" && mv "$READY_RUNS_DIR/$1.json.tmp" "$READY_RUNS_DIR/$1.json"
    ;;
  clear)
    [ $# -eq 1 ] || usage "clear needs <run id>"
    rm -f "$READY_RUNS_DIR/$1.json"
    ;;
  list)
    [ $# -eq 0 ] || usage "list takes no arguments"
    for f in $(ls -tr "$READY_RUNS_DIR"/*.json 2>/dev/null); do
      run=$(basename "$f" .json)
      if held "$run"; then record "$run" | jq -c '. + {held: true}'; else record "$run"; fi
    done
    ;;
  resolve)
    [ $# -eq 1 ] || usage "resolve needs <run id>"
    resolve "$1" || exit 2
    ;;
  ack)
    [ $# -eq 1 ] || usage "ack needs <run id>"
    run=$(resolve "$1") || exit 2
    key=$(cat "$state/last/$run" 2>/dev/null) || { echo "ready-runs: wait --all printed nothing for $run to acknowledge" >&2; exit 2; }
    if [ "$key" = ended ]; then rm -f "$state"/{seen,last,acked,held}/"$run"; else printf '%s' "$key" > "$state/acked/$run"; fi
    ;;
  hold)
    [ $# -ge 1 ] && [ $# -le 2 ] || usage "hold needs <run id> [reason]"
    run=$(resolve "$1") || exit 2
    jq -cn --arg since "$(now)" --arg reason "${2:-}" '{since: $since, reason: $reason}' > "$state/held/$run"
    ;;
  unhold)
    [ $# -eq 1 ] || usage "unhold needs <run id>"
    run=$(resolve "$1") || exit 2
    rm -f "$state/held/$run"
    ;;
  wait)
    runs=() timeout="" all=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) timeout=${2:?--timeout needs seconds}; shift 2 ;;
        --all) all=1; shift ;;
        -*) usage "unknown option $1" ;;
        *) runs+=("$1"); shift ;;
      esac
    done
    start=$SECONDS
    if [ "$all" -eq 1 ]; then
      [ ${#runs[@]} -eq 0 ] || usage "wait --all takes no run ids"
      failed=0
      while :; do
        poll_all; rc=$?
        if [ "$rc" -eq 4 ]; then
          failed=$((failed + 1))
          if [ "$failed" -ge 4 ]; then echo '{"state":"error","reason":"archon did not answer 4 polls in a row"}'; exit 4; fi
        else
          failed=0
        fi
        if [ -n "$timeout" ] && [ $((SECONDS - start)) -ge "$timeout" ]; then echo '{"state":"timeout"}'; exit 1; fi
        sleep "$POLL"
      done
    fi
    [ ${#runs[@]} -gt 0 ] || usage "wait needs at least one run id, or --all"
    for i in "${!runs[@]}"; do runs[$i]=$(resolve "${runs[$i]}") || exit 2; done
    while :; do
      for run in "${runs[@]}"; do
        if [ -f "$READY_RUNS_DIR/$run.json" ] && ! held "$run" && rec=$(record "$run"); then
          printf '%s' "$rec" | jq -c '{state: "ready"} + .'; exit 0
        fi
        st=$(status "$run")
        if ended "$st"; then jq -cn --arg run "$run" --arg status "$st" '{state: "ended", run: $run, status: $status}'; exit 0; fi
      done
      if [ -n "$timeout" ] && [ $((SECONDS - start)) -ge "$timeout" ]; then echo '{"state":"timeout"}'; exit 1; fi
      sleep "$POLL"
    done
    ;;
  *) usage "unknown command '${cmd}'" ;;
esac
