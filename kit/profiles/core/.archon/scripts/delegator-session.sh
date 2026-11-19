#!/usr/bin/env bash
# delegator-session.sh — the delegator session's Stop guard and session start (P2: a hook, not a nudge; R5).
#
# The delegator ends a turn while its runs build, and wakes only when a background waiter returns. On 10-18 a turn ended
# with a waiter that could not see a run at `merged`, and the owner sent five "continue" nudges. This hook keeps a turn
# from ending blind, and gives a new session the state it needs in a few lines.
#
# Usage (Claude Code hooks, wired in .claude/settings.json; JSON payload on stdin):
#   delegator-session.sh stop           Stop: block the delegator's turn end while a build-feature run is live and no
#                                       `ready-runs.sh wait --all` runs; the block reason is the arm command. After 3
#                                       blocks in a row it lets the turn end and logs a `stop-unguarded` line.
#   delegator-session.sh sessionStart   SessionStart: print at most 25 lines (live runs, ready runs, held runs, a
#                                       changed delegator.md, the arm instruction) and take the session lock.
#   delegator-session.sh sessionEnd     SessionEnd: release the session lock when this session holds it.
#
# Who: only a session whose `agent_type` is `delegator` (`claude --agent delegator`); every other agent passes with no
# output. Exit 0 ALWAYS. A block is {"decision":"block","reason":...} on stdout. Any error (archon down, no jq, an
# unreadable payload) fails open: no output, and the turn ends as it would without the hook.
# Fallback: a payload with no `agent_type` (a harness that does not send it) passes too, so guard and summary are off
# for that session; delegator.md tells the agent to notice the missing summary and arm the waiter by itself, and canary
# step 3 checks that the field arrives.
# Off switch: the file `guard-off` in the state folder turns the Stop guard off (session start still prints).
# State folder: $DELEGATOR_STATE_DIR, default merge-queue/delegator/ beside the main checkout. It holds `session.lock`
# ("<session> <pid> <since>", the one live delegator session, also read by delegator-start.sh), `blocks.<session>`
# (blocks in a row), `delegator.md.sha` (the text the last session started with) and `guard.log`.
# Overrides: DELEGATOR_STATE_DIR, DELEGATOR_MAX_BLOCKS (3), DELEGATOR_START_LINES (25).
# Keep this file bash-3.2-clean (see .claude/hooks/README.md).
set -uo pipefail

trap 'exit 0' EXIT                      # fail open: whatever happens, the hook exits 0
event=${1:-}
MAX_BLOCKS=${DELEGATOR_MAX_BLOCKS:-3}
MAX_LINES=${DELEGATOR_START_LINES:-25}
ARM='bash .archon/scripts/ready-runs.sh wait --all --timeout 3600'

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat 2>/dev/null) || exit 0
agent=$(printf '%s' "$payload" | jq -r '.agent_type // empty' 2>/dev/null) || exit 0
[ "$agent" = delegator ] || exit 0
session=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=$(printf '%s' "$session" | tr -cd 'A-Za-z0-9_-')
[ -n "$session" ] || session=unknown
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
root=${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}
cd "$root" 2>/dev/null || exit 0

if [ -z "${DELEGATOR_STATE_DIR:-}" ]; then
  main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$main" ] || exit 0
  DELEGATOR_STATE_DIR=$(dirname "$main")/merge-queue/delegator
fi
state=$DELEGATOR_STATE_DIR
mkdir -p "$state" 2>/dev/null || exit 0
now() { date '+%Y-%m-%d %H:%M:%S'; }

# live_runs: one "<full id> <status> <message>" line per build-feature run still running; exit 1 when archon cannot tell.
live_runs() {
  local json
  json=$(archon workflow runs --status running --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '.runs[] | select(.workflow_name == "build-feature")
    | "\(.id) \(.status) \(.user_message // "")"' 2>/dev/null
}
# waiter_armed: a `ready-runs.sh wait --all` process runs on this machine.
waiter_armed() { pgrep -f 'ready-runs\.sh wait( .*)? --all' >/dev/null 2>&1; }

guard_stop() {
  local runs n blocks f=$state/blocks.$session
  [ -f "$state/guard-off" ] && exit 0
  runs=$(live_runs) || exit 0
  if [ -z "$runs" ] || waiter_armed; then rm -f "$f"; exit 0; fi
  n=$(printf '%s\n' "$runs" | grep -c .)
  blocks=$(cat "$f" 2>/dev/null || echo 0)
  case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
  if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
    rm -f "$f"
    echo "$(now) stop-unguarded session=$session live=$n blocks=$blocks" >> "$state/guard.log"
    jq -cn --arg m "stop-unguarded: $n build-feature run(s) live and no ready-runs.sh wait --all after $blocks blocks; the turn ends unguarded." \
      '{systemMessage:$m}'
    exit 0
  fi
  echo $((blocks + 1)) > "$f"
  echo "$(now) block session=$session live=$n block=$((blocks + 1))" >> "$state/guard.log"
  jq -cn --arg r "Stop guard (block $((blocks + 1)) of $MAX_BLOCKS): $n build-feature run(s) are live and no waiter is armed, so nothing would wake you. Arm it now in the background (run_in_background), then end the turn: $ARM
Live runs (as of $(now), source: archon workflow runs):
$runs" '{decision:"block",reason:$r}'
}

# owner_pid: the Claude Code process this hook runs under (the first `claude` or `node` ancestor, a shell may sit in
# between); the parent when none is found. The lock names it, so delegator-start.sh can tell a live session.
owner_pid() {
  local p=$PPID c i
  for i in 1 2 3 4 5; do
    c=$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')
    case "$c" in claude|node) echo "$p"; return ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    case "$p" in ''|0|1) break ;; esac
  done
  echo "$PPID"
}

session_start() {
  local runs rr held sha old pid="" lsess="" r
  local -a lines
  lines=()
  local me; me=$(owner_pid)
  # The session lock: one live delegator session at a time (two overlapped about 75 min on 10-18).
  if [ -f "$state/session.lock" ]; then
    read -r lsess pid _ < "$state/session.lock" 2>/dev/null || true
    if [ -n "$pid" ] && [ "$lsess" != "$session" ] && [ "$pid" != "$me" ] && kill -0 "$pid" 2>/dev/null; then
      lines+=("WARNING: another delegator session holds the lock (session ${lsess:-?}, pid $pid). Two delegators double every action: end one.")
    fi
  fi
  echo "$session $me $(now)" > "$state/session.lock"

  lines+=("Delegator session start (as of $(now); sources: archon workflow runs, ready-runs.sh list).")
  if runs=$(live_runs); then
    if [ -n "$runs" ]; then
      lines+=("Live build-feature runs:")
      while IFS= read -r r; do lines+=("  $r"); done <<< "$runs"
    else lines+=("Live build-feature runs: none."); fi
  else lines+=("Live build-feature runs: unknown (archon did not answer)."); fi
  rr=$(bash .archon/scripts/ready-runs.sh list 2>/dev/null)
  if [ -n "$rr" ]; then
    lines+=("Ready runs (waiting for the merge):")
    while IFS= read -r r; do lines+=("  $r"); done <<< "$rr"
  else lines+=("Ready runs: none."); fi
  # ready-runs.sh list marks a held run with "held": true.
  if held=$(printf '%s\n' "$rr" | jq -c 'select(.held == true)' 2>/dev/null) && [ -n "$held" ]; then
    lines+=("Held runs (skipped for ready and attention):")
    while IFS= read -r r; do lines+=("  $r"); done <<< "$held"
  fi
  # delegator.md changed since the last delegator session: say so, the rules this session follows are new.
  if [ -f .claude/agents/delegator.md ]; then
    sha=$(git hash-object .claude/agents/delegator.md 2>/dev/null)
    old=$(cat "$state/delegator.md.sha" 2>/dev/null || true)
    if [ -n "$sha" ] && [ -n "$old" ] && [ "$sha" != "$old" ]; then
      lines+=("delegator.md changed since the last delegator session (last commit: $(git log -1 --format='%h %s' -- .claude/agents/delegator.md 2>/dev/null)): follow the new text, not what an earlier session did.")
    fi
    [ -n "$sha" ] && echo "$sha" > "$state/delegator.md.sha"
  fi
  [ -f "$state/guard-off" ] && lines+=("The Stop guard is off ($state/guard-off).")
  lines+=("Arm the waiter whenever a run is live, in the background (run_in_background): $ARM")

  local total=${#lines[@]} i last
  last=$total
  [ "$total" -gt "$MAX_LINES" ] && last=$((MAX_LINES - 2))
  for ((i = 0; i < last; i++)); do printf '%s\n' "${lines[$i]}"; done
  if [ "$total" -gt "$MAX_LINES" ]; then
    echo "  ... $((total - last - 1)) more lines: see archon workflow status and ready-runs.sh list"
    printf '%s\n' "${lines[$((total - 1))]}"
  fi
}

session_end() {
  local lsess=""
  read -r lsess _ < "$state/session.lock" 2>/dev/null || exit 0
  [ "$lsess" = "$session" ] && rm -f "$state/session.lock" "$state/blocks.$session"
}

case "$event" in
  stop|Stop) guard_stop ;;
  sessionStart|SessionStart) session_start ;;
  sessionEnd|SessionEnd) session_end ;;
esac
exit 0
