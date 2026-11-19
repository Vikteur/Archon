#!/usr/bin/env bash
# One tick of the delegator supervisor (P2: a timer and a script are the wake source, not the owner or a model; owner
# decision 2026-10-20, D15: a supervisor timer, shadow mode first; ROADMAP R20, T15). A systemd user timer runs it every
# 3 minutes (.archon/systemd/delegator-supervisor.timer); docs/archon/supervisor.md says how to install, watch and
# switch it.
#   supervisor-tick.sh [tick]     one tick: read every build-feature run, decide what the delegator should do now, and
#                                 log it (shadow) or do it (live)
#   supervisor-tick.sh status     the mode, the age of the heartbeat and the last tick's summary line
# What a tick decides, from the scripts the delegator uses (each read-only in the way the tick calls it):
#   merge    a run waiting at `merged` with a pull request, no hold marker (merge-ready.sh --hold) and no run hold
#            (ready-runs.sh hold): `bash .archon/scripts/merge-ready.sh <pr url>`; a STOP verdict `owner` from
#            stop-check.sh gives a ping instead (merge-ready.sh would hold it)
#   recover  a failed run, or a completed one, for which `recover-run.sh <run> --dry-run` names an action:
#            `bash .archon/scripts/recover-run.sh <run>`; "ask" gives a ping instead
#   launch   inside the night window, with a night list and the recovery breaker not open: each ticket
#            `pick-tickets.js --list <night list> --cap <cap>` picks (one only while the breaker is half open):
#            `bash .archon/scripts/sync-main.sh && bash .archon/scripts/launch-run.sh <TASK-id>`
#   cleanup  a completed run that closed: `bash .archon/scripts/cleanup-merged.sh --sweep` (once per run; the sweep
#            deletes only what is fully merged)
#   ping     every stall `run-watch.js stalls` names, a paused run, archon not answering, an open breaker, and the tick
#            itself failing 3 times in a row: `bash .archon/scripts/notify-owner.sh <level> <key> "<subject>"`
#   judge    a case no script can decide (recovery asks, a run paused at a gate): besides its ping, the case goes to
#            supervisor-judge.sh (`claude -p --agent delegator`, read-only, budget cap), started detached, once per case
#            key, one at a time, at most SUPERVISOR_JUDGE_PER_DAY (10) a day. A later tick logs its answer (`kind:
#            judge`). Shadow only logs it. Live acts on a judged hold or ping only; a judged merge, recover, launch or
#            cleanup becomes a ping to the owner. SUPERVISOR_JUDGE=off turns the judge off.
# Every command is built by supervisor-jobs.sh, which checks its arguments first.
# Every decision is one JSON line in the tick log {time, mode, kind, key, cmd, detail, new, fence, result}: `new` is
# true the first tick a key is decided (a key decided again on the next tick is the same pending action, never a second
# one); `fence` is what the scope guard says of `cmd` for the delegator (allowed, or denied with its reason), so a tick
# never runs a command the delegator itself could not run (T15). A summary line per tick and the heartbeat file follow.
# A quiet tick decides nothing and makes no model call; the tick itself never calls a model (only the judge does).
# Modes:
#   shadow   (the default) decide and log, never act: no merge, recovery, launch or ping. The tick runs only read-only
#            commands; stop-check runs without its fetch (STOP_NO_FETCH=1).
#   live     decide and act: each action starts detached under its own lock, so the tick still ends in seconds; an
#            action with the same key does not start again while it runs or within SUPERVISOR_REPEAT_MIN after it
#            started. A command the fence denies is not run; the owner is pinged. Live holds only when $LIVE_FLAG is a
#            regular file (no symlink) owned by root and writable by root only, in a folder owned by root: only the
#            owner can create it, with sudo (agents have no sudo password; push-guard.sh uses the same trust). There is
#            no environment override for the flag or its owner. Two limits hold in live mode:
#            - recover-run.sh without --dry-run runs only when $RECOVER_FLAG holds too (the same trust: the owner
#              creates it when the D13 dry-run week is over); before that a recovery is logged, not run;
#            - no launch while a delegator session holds its lock ($DELEGATOR_STATE_DIR/session.lock, default
#              merge-queue/delegator/session.lock, with a live pid): "delegator session owns launches".
#   paused   $SUPERVISOR_STATE_DIR/paused exists: the tick writes the heartbeat and does nothing else. Anyone may pause.
# A tick takes a lock (flock): a second tick while one runs logs "overlap" and exits 0. Each command it calls has
# SUPERVISOR_STEP_TIMEOUT seconds. It fails open: an error is logged, the tick goes on with the next step and exits 0,
# so the timer never crash-loops; 3 failing ticks in a row ping the owner (warn).
# Exit codes: 0 tick done (also: overlap, paused, errors logged), 2 usage or no main checkout.
# Overrides: SUPERVISOR_STATE_DIR (~/.local/state/delegator-supervisor), SUPERVISOR_MAIN (the main checkout; default the
# first `git worktree list` entry), SUPERVISOR_STEP_TIMEOUT (30), SUPERVISOR_REPEAT_MIN (30), SUPERVISOR_CAP (2, D1),
# SUPERVISOR_NIGHT_WINDOW (22:00-07:00, local time; `always` or `never`), SUPERVISOR_NIGHT_LIST
# (docs/rewrite/night-list.txt in the main checkout), READY_RUNS_DIR and MERGE_QUEUE_DIR (as ready-runs.sh and
# merge-ready.sh), DELEGATOR_STATE_DIR (as delegator-session.sh), SUPERVISOR_JUDGE (on; off), SUPERVISOR_JUDGE_PER_DAY
# (10). The scripts, the scope guard and notify-owner.sh are always the main checkout's own.
set -uo pipefail

LIVE_FLAG=/etc/delegator-supervisor/live
RECOVER_FLAG=/etc/delegator-supervisor/recover
OWNER_UID=0

usage() { echo "supervisor-tick: $*" >&2; echo "usage: supervisor-tick.sh [tick | status]" >&2; exit 2; }
sub=${1:-tick}
case "$sub" in tick|status) ;; -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; *) usage "unknown command: $sub" ;; esac
[ $# -le 1 ] || usage "too many arguments"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main=${SUPERVISOR_MAIN:-$(git -C "$here" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')}
[ -n "$main" ] && [ -d "$main" ] || usage "no main checkout; set SUPERVISOR_MAIN"
state=${SUPERVISOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/delegator-supervisor}
T=${SUPERVISOR_STEP_TIMEOUT:-30}
repeat_s=$(( ${SUPERVISOR_REPEAT_MIN:-30} * 60 ))
cap=${SUPERVISOR_CAP:-2}
window=${SUPERVISOR_NIGHT_WINDOW:-22:00-07:00}
night_list=${SUPERVISOR_NIGHT_LIST:-docs/rewrite/night-list.txt}
ready_dir=${READY_RUNS_DIR:-$(dirname "$main")/merge-queue/ready}
queue_dir=${MERGE_QUEUE_DIR:-$(dirname "$main")/merge-queue}
guard="$main/.claude/hooks/scripts/scope-guard.sh"
jobs="$main/.archon/scripts/supervisor-jobs.sh"
judge="$main/.archon/scripts/supervisor-judge.sh"
session_lock=${DELEGATOR_STATE_DIR:-$queue_dir/delegator}/session.lock
log=$state/tick.log
mkdir -p "$state/seen" "$state/acted" "$state/inflight" "$state/jobs" "$state/judge" || { echo "supervisor-tick: cannot create $state" >&2; exit 0; }

trusted() { # trusted <flag>: a regular file (no symlink) owned by OWNER_UID and writable by it only, in such a folder
  local f=$1 dir; dir=$(dirname "$1")
  [ -f "$f" ] && [ ! -L "$f" ] && [ ! -L "$dir" ] \
    && [ "$(stat -c %u "$f" 2>/dev/null)" = "$OWNER_UID" ] && [ "$(stat -c %u "$dir" 2>/dev/null)" = "$OWNER_UID" ] \
    && [ $(( 0$(stat -c %a "$f" 2>/dev/null) & 022 )) -eq 0 ] && [ $(( 0$(stat -c %a "$dir" 2>/dev/null) & 022 )) -eq 0 ]
}
mode() { # shadow, live or paused (see the header)
  if [ -e "$state/paused" ]; then echo paused
  elif trusted "$LIVE_FLAG"; then echo live
  else echo shadow; fi
}
session_live() { # a delegator session holds its lock with a live pid ("<session> <pid> <since>")
  local _s pid
  [ -r "$session_lock" ] || return 1
  read -r _s pid _ < "$session_lock" || return 1
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

if [ "$sub" = status ]; then
  echo "mode: $(mode)"
  if trusted "$RECOVER_FLAG"; then echo "live recovery: on ($RECOVER_FLAG)"; else echo "live recovery: off (no trusted $RECOVER_FLAG: dry runs only, D13)"; fi
  if session_live; then echo "delegator session: live (it owns launches)"; else echo "delegator session: none"; fi
  if [ -f "$state/heartbeat" ]; then
    echo "heartbeat: $(( $(date +%s) - $(stat -c %Y "$state/heartbeat") )) s old"
    cat "$state/heartbeat"
  else
    echo "heartbeat: none yet"
  fi
  exit 0
fi

now=$(date +%s)
MODE=$(mode)
jlog() { # jlog <json>: one line in the tick log, never fatal
  printf '%s\n' "$1" >> "$log" 2>/dev/null || echo "supervisor-tick: could not write $log" >&2
}
note() { # note <kind> <detail>: a line that is no decision (overlap, error, paused, a skipped run)
  jlog "$(jq -cn --arg t "$(date -u +%FT%TZ)" --arg m "$MODE" --arg k "$1" --arg d "$2" '{time: $t, mode: $m, kind: $k, detail: $d}')"
}

# One tick at a time. A tick that finds the lock taken ends at once; the next timer tick tries again.
exec 9> "$state/tick.lock" || { echo "supervisor-tick: cannot open the lock" >&2; exit 0; }
if ! flock -n 9; then note overlap "a tick is still running: this one ends"; exit 0; fi

# Keep the log bounded: one rotation at 5 MB.
[ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 5242880 ] && mv -f "$log" "$log.1"

heartbeat() { # heartbeat <json summary>: the summary line in the log and the heartbeat file (S6)
  jlog "$1"
  printf '%s\n' "$1" > "$state/heartbeat.tmp" && mv -f "$state/heartbeat.tmp" "$state/heartbeat"
}

if [ "$MODE" = paused ]; then
  heartbeat "$(jq -cn --arg t "$(date -u +%FT%TZ)" '{time: $t, mode: "paused", kind: "tick", detail: "paused: remove the paused file to resume"}')"
  exit 0
fi

errors=0 decided=0 fresh=0
errf=$(mktemp); trap 'rm -f "$errf"' EXIT
fail() { errors=$((errors+1)); note error "$1: $(tail -n 3 "$errf" 2>/dev/null | tr '\n' ' ')"; }
in_main() { (cd "$main" && timeout "$T" "$@") 2> "$errf"; }
keyname() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
pr_ok() { [[ $1 =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]]; }
run_ok() { [[ $1 =~ ^[0-9a-f]{8,64}$ ]]; }
task_ok() { [[ $1 =~ ^TASK-[0-9]+(\.[0-9]+)*$ ]]; }
: > "$state/decided.now"

fence() { # fence <command>: "allowed", or "denied: <reason>", as the scope guard judges it for the delegator
  local out
  [ -f "$guard" ] || { echo "denied: no scope guard at $guard"; return; }
  out=$(jq -cn --arg c "$1" '{agent_type: "delegator", tool_name: "Bash", tool_input: {command: $c}}' \
    | (cd "$main" && timeout 10 bash "$guard") 2>/dev/null)
  if [ -z "$out" ]; then echo allowed
  else echo "denied: $(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // "no reason"' 2>/dev/null)"; fi
}

act() { # act <kind> <key> <cmd> <fence>: start the action (live only); prints its result
  local k=$2 lockf="$state/inflight/$2.lock" at
  case "$4" in denied*) echo "not run: the fence denies it"; return ;; esac
  if [ "$1" = ping ]; then shift 4; ping_now "$@"; return; fi
  if [ "$1" = launch ] && session_live; then echo "not run: delegator session owns launches"; return; fi
  if [ "$1" = recover ] && ! trusted "$RECOVER_FLAG"; then echo "not run: the D13 dry-run week is not over (no trusted $RECOVER_FLAG)"; return; fi
  if [ "$1" = cleanup ] && [ -f "$state/acted/$k" ]; then echo "not run: done before"; return; fi
  at=$(cat "$state/acted/$k" 2>/dev/null || echo 0)
  if [ $((now - at)) -lt "$repeat_s" ]; then echo "not run: started $(( (now - at) / 60 )) min ago"; return; fi
  if ! flock -n "$lockf" true; then echo "not run: still running"; return; fi
  # The job holds its own lock while it runs, never the tick lock (fd 9 is closed for it); launches also queue behind
  # each other (sync-main.sh, then the run).
  if [ "$1" = launch ]; then
    setsid -f flock -n "$lockf" flock "$state/inflight/launch.serial" bash -c "cd \"\$1\" && $3" _ "$main" > "$state/jobs/$k.log" 2>&1 < /dev/null 9>&-
  else
    setsid -f flock -n "$lockf" bash -c "cd \"\$1\" && $3" _ "$main" > "$state/jobs/$k.log" 2>&1 < /dev/null 9>&-
  fi
  echo "$now" > "$state/acted/$k"
  echo "started (log: jobs/$k.log)"
}

ping_now() { # ping_now <level> <key> <subject>: the ping job, fenced; a missing notifier or a failed ping is logged only (D9)
  local k at c; k=$(keyname "ping-$2")
  at=$(cat "$state/acted/$k" 2>/dev/null || echo 0)
  if [ $((now - at)) -lt "$repeat_s" ]; then echo "not sent: sent $(( (now - at) / 60 )) min ago"; return; fi
  c=$(bash "$jobs" cmd ping "$1" "$2" "$(printf '%s' "$3" | tr '\n\r' '  ' | cut -c1-300)" 2>/dev/null) || { echo "ping not delivered: supervisor-jobs refused it"; return; }
  case "$(fence "$c")" in denied*) echo "ping not delivered: the fence denies it"; return ;; esac
  if [ -f "$main/.archon/scripts/notify-owner.sh" ] && (cd "$main" && timeout 20 bash -c "$c") > /dev/null 2>&1; then
    echo "$now" > "$state/acted/$k"; echo sent
  else
    echo "ping not delivered"
  fi
}

decide() { # decide <kind> <key> <cmd> <detail> [<ping level> <ping key> <ping subject>]
  local kind=$1 key k new=false f result fz
  key=$2; k=$(keyname "$key")
  echo "$k" >> "$state/decided.now"
  if [ ! -f "$state/seen/$k" ]; then echo "$now" > "$state/seen/$k"; new=true; fresh=$((fresh+1)); fi
  decided=$((decided+1))
  fz=$(fence "$3")
  if [ "$MODE" = live ]; then
    if [ "$kind" = ping ]; then result=$(act ping "$k" "$3" "$fz" "$5" "$6" "$7")
    else
      result=$(act "$kind" "$k" "$3" "$fz")
      case "$fz" in denied*) ping_now warn "fence-$k" "supervisor: the fence denies \"$3\" for the delegator" > /dev/null ;; esac
    fi
  else
    result="shadow: not run"
  fi
  jlog "$(jq -cn --arg t "$(date -u +%FT%TZ)" --arg m "$MODE" --arg kind "$kind" --arg key "$key" --arg c "$3" \
    --arg d "$4" --argjson n "$new" --arg f "$fz" --arg r "$result" \
    '{time: $t, mode: $m, kind: $kind, key: $key, cmd: $c, detail: $d, new: $n, fence: $f, result: $r}')"
}

jobcmd() { # jobcmd <kind> <args...>: the command from supervisor-jobs.sh; empty (and an error) when an argument fails
  local c
  c=$(bash "$jobs" cmd "$@" 2> "$errf") || { fail "supervisor-jobs cmd $1"; return 1; }
  printf '%s' "$c"
}
ping() { # ping <level> <key> <subject>: the subject is cut to one line of at most 300 characters
  local subj c; subj=$(printf '%s' "$3" | tr '\n\r' '  ' | cut -c1-300)
  c=$(jobcmd ping "$1" "$2" "$subj") || return 0
  decide ping "ping:$2" "$c" "$subj" "$1" "$2" "$subj"
}
judge_case() { # judge_case <key> <kind> <run> <ticket> <pr url> <detail> <context json>: start the judge for a new case
  local k jc today n
  [ "${SUPERVISOR_JUDGE:-on}" = on ] && [ -f "$judge" ] || return 0
  k=$(keyname "$1")
  [ -e "$state/judge/$k.case" ] && return 0                     # judged before: never twice
  [ "${judged_now:-0}" -ge 1 ] && return 0                      # one judge started per tick
  today=$(date +%F)
  n=$(find "$state/judge" -name '*.case' -newermt "$today" 2>/dev/null | wc -l)
  [ "$n" -lt "${SUPERVISOR_JUDGE_PER_DAY:-10}" ] || { note judge-skip "not judged: $1 (the daily limit of ${SUPERVISOR_JUDGE_PER_DAY:-10} is reached)"; return 0; }
  flock -n "$state/judge.lock" true || return 0                 # one running at a time; the next tick tries again
  jc=$(jq -cn --arg key "$1" --arg kind "$2" --arg run "$3" --arg t "$4" --arg pr "$5" --arg d "$6" --argjson c "${7:-null}" \
    '{key: $key, kind: $kind, run: $run, ticket: $t, pr_url: $pr, detail: $d, context: $c}') || return 0
  printf '%s\n' "$jc" > "$state/judge/$k.case"
  setsid -f flock -n "$state/judge.lock" bash "$judge" "$state/judge/$k.case" --out "$state/judge/$k.answer" \
    > "$state/judge/$k.err" 2>&1 < /dev/null 9>&-
  judged_now=$(( ${judged_now:-0} + 1 ))
  note judge-start "judge started: $1"
}

# 1. What every build-feature run is doing.
snap=$(in_main node .archon/scripts/run-watch.js snapshot --json) || { fail "run-watch snapshot"; snap=""; }
if [ -n "$snap" ] && ! printf '%s' "$snap" | jq -e '.runs' > /dev/null 2>&1; then echo "$snap" > "$errf"; fail "run-watch snapshot is no JSON"; snap=""; fi
[ "$(printf '%s' "$snap" | jq -r '.source // empty' 2>/dev/null)" = log ] \
  && ping warn archon-down "supervisor: archon does not answer; run states come from the logs"

# 2. Stalls: run-watch keeps the supervisor's own repeat state (a stall comes back after 30 min).
stalls=$(in_main node .archon/scripts/run-watch.js stalls --json --state "$state/stalls.json"); rc=$?
[ "$rc" -le 1 ] || { fail "run-watch stalls"; stalls=""; }
while IFS= read -r s; do
  [ -n "$s" ] || continue
  printf '%s' "$s" | jq -e . > /dev/null 2>&1 || continue
  IFS=$'\x1f' read -r srun skind sover shint < <(printf '%s' "$s" | jq -r '[.run, .kind, (.over_min // 0 | floor), (.hint // "")] | map(tostring) | join("\u001f")')
  ping warn "stall-${srun:0:8}-$skind" "run ${srun:0:8}: $skind for $sover min: $shint"
done <<< "$stalls"

# 3. Each run: merge, recover or ask.
held() { [ -e "$ready_dir/.state/held/$1" ]; }
marked() { [[ $1 =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]] && [ -e "$queue_dir/holds/${BASH_REMATCH[1]}_${BASH_REMATCH[2]}_${BASH_REMATCH[3]}" ]; }
while IFS= read -r r; do
  [ -n "$r" ] || continue
  IFS=$'\x1f' read -r run phase pr ticket paused < <(printf '%s' "$r" | jq -r '[.run, .phase, (.pr_url // ""), (.ticket // "?"), (.paused // false | tostring)] | map(tostring) | join("\u001f")')
  run_ok "$run" || { note skip "a run id that is no run id: $run"; continue; }
  r8=${run:0:8}
  if [ "$paused" = true ]; then
    ping act "attention-$r8" "$ticket run $r8 is paused at a gate: archon workflow attention"
    judge_case "attention:$r8" attention "$run" "$ticket" "$pr" "$ticket run $r8 is paused at a gate" "$r"
  fi
  case "$phase" in
    waiting-for-merge)
      if ! pr_ok "$pr"; then note skip "$ticket $r8 waits for its merge without a readable pull request url"; continue; fi
      n=${pr##*/}
      if held "$run" || marked "$pr"; then note skip "$ticket $r8 PR #$n is held"; continue; fi
      v=$(STOP_NO_FETCH=1 in_main bash .archon/scripts/stop-check.sh "$pr" | head -n 1)
      verdict=${v%% *}
      case "$verdict" in
        none|covered) c=$(jobcmd merge "$pr") && decide merge "merge:$n" "$c" "$ticket $r8 PR #$n, STOP verdict $verdict" ;;
        owner) ping act "merge-held-$n" "PR #$n waits for you: a STOP item is not approved (${v#owner})" ;;
        *) fail "stop-check $pr gave no verdict" ;;
      esac ;;
    failed|completed)
      c=$(jobcmd recover-dry "$run") || continue
      out=$(in_main bash -c "$c"); rc=$?
      line=$(printf '%s\n' "$out" | tail -n 1)
      if [ "$phase" = completed ] && [ "$(printf '%s' "$r" | jq -r '.close // empty')" = true ]; then
        c=$(jobcmd cleanup) && decide cleanup "cleanup:$r8" "$c" "$ticket $r8 completed and closed: sweep what is fully merged"
      fi
      printf '%s' "$line" | jq -e . > /dev/null 2>&1 || { [ "$rc" -eq 0 ] && [ "$phase" = completed ] && continue; fail "recover-run $r8 --dry-run"; continue; }
      IFS=$'\x1f' read -r sig action step result < <(printf '%s' "$line" | jq -r '[(.signature // "-"), (.action // "none"), (.step // "-"), (.result // "")] | map(tostring) | join("\u001f")')
      if [ "$action" = ask ] || [ "$rc" -eq 3 ]; then
        ping act "recover-$r8-$sig" "$ticket run $r8 needs you ($sig): $result"
        judge_case "recover:$r8:$sig" recover-ask "$run" "$ticket" "$pr" "$ticket run $r8 $phase ($sig): $result" \
          "$(jq -cn --argjson s "$r" --argjson d "$line" '{run_state: $s, recover_dry_run: $d}' 2>/dev/null || echo null)"
      elif [ "$action" != none ]; then
        c=$(jobcmd recover "$run") && decide recover "recover:$r8:$sig:$step" "$c" "$ticket $r8 $sig: $action $step ($result)"
      fi ;;
  esac
done < <(printf '%s' "$snap" | jq -c '.runs[]?' 2>/dev/null)

# 4. The recovery breaker, then launches inside the night window.
breaker=$(in_main node .archon/scripts/recovery-state.js show) || { fail "recovery-state show"; breaker='{"state":"unknown"}'; }
bstate=$(printf '%s' "$breaker" | jq -r '.state // "unknown"' 2>/dev/null || echo unknown)
[ "$bstate" = open ] && ping act "breaker-open-$(printf '%s' "$breaker" | jq -r '.tripped_at // "now"')" \
  "the recovery breaker is open ($(printf '%s' "$breaker" | jq -r '.reason // "no reason"')): no launch until it closes"
in_window() {
  case "$window" in always) return 0 ;; never) return 1 ;; esac
  [[ $window =~ ^([0-2][0-9]):([0-5][0-9])-([0-2][0-9]):([0-5][0-9])$ ]] || return 1
  local from=$((10#${BASH_REMATCH[1]}${BASH_REMATCH[2]})) to=$((10#${BASH_REMATCH[3]}${BASH_REMATCH[4]})) t=$((10#$(date +%H%M)))
  if [ "$from" -le "$to" ]; then [ "$t" -ge "$from" ] && [ "$t" -lt "$to" ]; else [ "$t" -ge "$from" ] || [ "$t" -lt "$to" ]; fi
}
if in_window && [ -s "$main/$night_list" ] && { [ "$bstate" = closed ] || [ "$bstate" = half_open ]; }; then
  picks=$(in_main node .archon/scripts/pick-tickets.js --list "$night_list" --cap "$cap") || { fail "pick-tickets"; picks=""; }
  max=99; [ "$bstate" = half_open ] && max=1
  for id in $(printf '%s' "$picks" | jq -r '.picked[]?.id' 2>/dev/null | head -n "$max"); do
    task_ok "$id" || { note skip "pick-tickets picked no TASK id: $id"; continue; }
    c=$(jobcmd launch "$id") && decide launch "launch:$id" "$c" "picked from $night_list (breaker $bstate)"
  done
fi

# 5. The judge's answers that came in since the last tick: each is logged once. Shadow logs only; live acts on a hold
# or a ping, and a proposed merge, recover, launch or cleanup goes to the owner as a ping.
for a in "$state/judge"/*.answer; do
  [ -f "$a" ] || continue
  jk=$(basename "$a" .answer)
  ans=$(head -n 1 "$a")
  if ! printf '%s' "$ans" | jq -e . > /dev/null 2>&1; then ans=$(jq -cn --arg k "$jk" '{key: $k, valid: false, error: "the answer file is no JSON"}'); fi
  IFS=$'\x1f' read -r jvalid jdec jtarget jlevel _jreason jcmd < <(printf '%s' "$ans" \
    | jq -r '[(.valid // false | tostring), (.decision // "-"), (.target // ""), (.level // "act"), (.reason // .error // ""), (.cmd // "")] | join("\u001f")')
  jf=""; [ -n "$jcmd" ] && jf=$(fence "$jcmd")
  if [ "$jvalid" != true ]; then jres="invalid: not acted on"
  elif [ "$MODE" != live ]; then jres="shadow: logged only"
  else
    case "$jdec" in
      hold) jres=$(act hold "$(keyname "judge-hold-$jk")" "$jcmd" "$jf") ;;
      # A ping carries ids, the action and fixed phrases only: the judge's free-text reason may name people, so it
      # stays in tick.log (detail) and never goes to the phone.
      ping) jres=$(ping_now "$jlevel" "judge-$jk" "the judge asks you to look at $jk (reason in tick.log)") ;;
      wait) jres="nothing to do" ;;
      *) jres="proposed to the owner: $(ping_now act "judge-$jk" "the judge proposes $jdec ${jtarget:-} for $jk (reason in tick.log)")" ;;
    esac
  fi
  jlog "$(jq -cn --arg t "$(date -u +%FT%TZ)" --arg m "$MODE" --arg key "judge:$jk" --argjson a "$ans" --arg f "$jf" --arg r "$jres" \
    '{time: $t, mode: $m, kind: "judge", key: $key, cmd: ($a.cmd // ""), detail: ($a.reason // $a.error // ""), answer: $a, fence: $f, result: $r}')"
  mv -f "$a" "$a.logged"
done

# 6. The tick itself: 3 failing ticks in a row ping the owner; then forget keys no longer decided, and the summary.
if [ "$errors" -gt 0 ]; then echo $(( $(cat "$state/fails" 2>/dev/null || echo 0) + 1 )) > "$state/fails"; else rm -f "$state/fails"; fi
[ "$(cat "$state/fails" 2>/dev/null || echo 0)" -ge 3 ] \
  && ping warn supervisor-failing "supervisor: $(cat "$state/fails") ticks in a row had errors; see $log"
for f in "$state/seen"/*; do
  [ -e "$f" ] || continue
  grep -qxF "${f##*/}" "$state/decided.now" || rm -f "$f"
done
nruns=$(printf '%s' "$snap" | jq '.runs | length' 2>/dev/null); [[ $nruns =~ ^[0-9]+$ ]] || nruns=null
heartbeat "$(jq -cn --arg t "$(date -u +%FT%TZ)" --arg m "$MODE" --argjson ms $(( ($(date +%s) - now) * 1000 )) \
  --argjson runs "$nruns" \
  --argjson d "$decided" --argjson n "$fresh" --argjson e "$errors" \
  '{time: $t, mode: $m, kind: "tick", tick_ms: $ms, runs: $runs, decided: $d, new: $n, errors: $e}')"
exit 0
