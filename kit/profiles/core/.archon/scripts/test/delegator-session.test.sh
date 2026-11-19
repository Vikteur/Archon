#!/usr/bin/env bash
# Tests for .archon/scripts/delegator-session.sh (R5): the delegator's Stop guard and session start, against a stubbed
# archon, a stubbed pgrep and a throwaway project. Run it by name: affected-check maps no hook to it.
# Usage: bash .archon/scripts/test/delegator-session.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/delegator-session.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# archon answers `workflow runs --status running --json` with $ROOT/runs.json, and fails when $ROOT/archon-down exists.
# pgrep finds the waiter when $ROOT/waiter exists. The project has a ready-runs.sh that prints $ROOT/ready.
mkdir -p "$root/bin"
cat > "$root/bin/archon" <<'STUB'
#!/usr/bin/env bash
[ -f "$ROOT/archon-down" ] && exit 1
[ "$1 $2" = "workflow runs" ] || exit 1
cat "$ROOT/runs.json" 2>/dev/null || echo '{"runs": []}'
STUB
cat > "$root/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$ROOT/pgrep.args"
[ -f "$ROOT/waiter" ]
STUB
chmod +x "$root/bin/archon" "$root/bin/pgrep"
proj=$root/proj
mkdir -p "$proj/.archon/scripts" "$proj/.github/agents"
cat > "$proj/.archon/scripts/ready-runs.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] && cat "$ROOT/ready" 2>/dev/null
exit 0
STUB
echo "# Delegator v1" > "$proj/.github/agents/delegator.agent.md"
git init -q -b main "$proj"; git -C "$proj" add -A
git -C "$proj" -c user.email=t@t -c user.name=t commit -qm "delegator v1"
state=$root/state

runs() { # runs <n>: n live build-feature runs, and one run of another workflow
  local i; { echo '{"runs": ['
    for ((i = 1; i <= $1; i++)); do printf '{"id": "%032d", "workflow_name": "build-feature", "status": "running", "user_message": "Build TASK-%d"},\n' "$i" "$i"; done
    echo '{"id": "ffff", "workflow_name": "notify-owner", "status": "running"}]}'; } > "$root/runs.json"
}
hook() { # hook <event> <agent> [session]: sets out, rc
  local p
  p=$(jq -cn --arg a "$2" --arg s "${3:-s1}" --arg c "$proj" '{session_id:$s, cwd:$c, hook_event_name:"x"} + (if $a == "" then {} else {agent_type:$a} end)')
  out=$(printf '%s' "$p" | PATH="$root/bin:$PATH" ROOT="$root" CLAUDE_PROJECT_DIR="$proj" DELEGATOR_STATE_DIR="$state" \
    bash "$script" "$1" 2>/dev/null); rc=$?
}
reset() { rm -rf "$state" "$root/runs.json" "$root/archon-down" "$root/waiter" "$root/ready" "$root/pgrep.args"; }
decision() { printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null; }
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (rc=$rc)"; echo "$out" | sed 's/^/    /'; fi
}

# 1. Another agent, or the main session, passes with no output, also with live runs and no waiter.
reset; runs 2
hook stop developer
check "1 another agent passes silently" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)
hook stop ""
check "1 a session without an agent passes silently" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)

# 2. The delegator with live runs and no waiter: blocked, the reason is the arm command and names the full run ids.
hook stop delegator
check "2 a turn end with live runs and no waiter is blocked" $([ "$(decision)" = block ]; echo $?)
check "2 the reason is the arm command" $(printf '%s' "$out" | jq -r .reason | grep -qF 'bash .archon/scripts/ready-runs.sh wait --all'; echo $?)
check "2 the reason lists the live build-feature runs only" \
  $(r=$(printf '%s' "$out" | jq -r .reason); grep -q "$(printf '%032d' 2)" <<< "$r" && ! grep -q ffff <<< "$r"; echo $?)
check "2 the reason says as of and its source" $(printf '%s' "$out" | jq -r .reason | grep -q 'as of .*source: archon workflow runs'; echo $?)
check "2 it looks for a wait --all" $(grep -q 'ready-runs.*wait.*--all' "$root/pgrep.args"; echo $?)

# 3. After 3 blocks in a row the turn ends, with a stop-unguarded line; the count starts again after.
hook stop delegator; hook stop delegator
check "3 the third block still blocks" $([ "$(decision)" = block ] && printf '%s' "$out" | jq -r .reason | grep -q 'block 3 of 3'; echo $?)
hook stop delegator
check "3 the fourth turn end passes" $([ -z "$(decision)" ]; echo $?)
check "3 with a stop-unguarded line" $(printf '%s' "$out" | jq -r .systemMessage | grep -q '^stop-unguarded'; echo $?)
check "3 logged in guard.log" $(grep -q 'stop-unguarded session=s1' "$state/guard.log"; echo $?)
hook stop delegator
check "3 the next turn end is blocked again" $([ "$(decision)" = block ]; echo $?)

# 4. A wait --all is running: the turn ends, and the block count is cleared.
touch "$root/waiter"; hook stop delegator
check "4 an armed waiter lets the turn end" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)
check "4 the block count is cleared" $([ ! -f "$state/blocks.s1" ]; echo $?)

# 5. No live run: the turn ends.
reset; echo '{"runs": []}' > "$root/runs.json"; hook stop delegator
check "5 no live run lets the turn end" $([ -z "$out" ]; echo $?)

# 6. Any error fails open: archon down, an unreadable payload.
reset; runs 1; touch "$root/archon-down"; hook stop delegator
check "6 archon down fails open" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)
out=$(printf 'not json' | PATH="$root/bin:$PATH" ROOT="$root" CLAUDE_PROJECT_DIR="$proj" DELEGATOR_STATE_DIR="$state" \
  bash "$script" stop 2>/dev/null); rc=$?
check "6 an unreadable payload fails open" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)

# 7. The guard-off file turns the guard off.
reset; runs 1; mkdir -p "$state"; touch "$state/guard-off"; hook stop delegator
check "7 guard-off lets the turn end" $([ -z "$out" ]; echo $?)

# 8. Session start: at most 25 lines, live runs with full ids, ready runs, the arm instruction, and the lock.
reset; runs 30; echo '{"run": "r1", "pr": "https://github.com/o/r/pull/1", "since": "x"}' > "$root/ready"
hook sessionStart delegator s8
check "8 prints at most 25 lines" $([ "$(printf '%s\n' "$out" | wc -l)" -le 25 ]; echo $?)
check "8 names a live run by its full id" $(grep -q "$(printf '%032d' 1) running Build TASK-1" <<< "$out"; echo $?)
check "8 says how many lines it left out" $(grep -q 'more lines' <<< "$out"; echo $?)
check "8 ends with the arm instruction" $(printf '%s\n' "$out" | tail -1 | grep -qF 'ready-runs.sh wait --all'; echo $?)
check "8 says as of and its sources" $(head -1 <<< "$out" | grep -q 'as of .*sources'; echo $?)
check "8 takes the session lock" $(grep -q '^s8 ' "$state/session.lock"; echo $?)
runs 1; hook sessionStart delegator s8
check "8 lists the ready runs" $(grep -q 'pull/1' <<< "$out"; echo $?)
check "8 no held runs, no held line" $(! grep -q 'Held runs' <<< "$out"; echo $?)
echo '{"run": "r2", "pr": "https://github.com/o/r/pull/2", "since": "x", "held": true}' >> "$root/ready"
hook sessionStart delegator s8
check "8 names a held run" $(grep -A1 'Held runs' <<< "$out" | grep -q 'pull/2'; echo $?)
check "8 a first start says nothing about delegator.md" $(! grep -q 'delegator.md changed' <<< "$out"; echo $?)

# 9. delegator.md changed since the last delegator session: the next session start says so, once.
echo "# Delegator v2" > "$proj/.github/agents/delegator.agent.md"
git -C "$proj" -c user.email=t@t -c user.name=t commit -qam "delegator v2"
hook sessionStart delegator s9
check "9 a changed delegator.md is noted" $(grep -q 'delegator.md changed.*delegator v2' <<< "$out"; echo $?)
hook sessionStart delegator s9
check "9 only once" $(! grep -q 'delegator.md changed' <<< "$out"; echo $?)

# 10. Session end releases this session's lock only; another agent's session start takes none.
hook sessionEnd delegator other
check "10 another session's end keeps the lock" $([ -f "$state/session.lock" ]; echo $?)
hook sessionEnd delegator s9
check "10 its own session end releases the lock" $([ ! -f "$state/session.lock" ]; echo $?)
hook sessionStart developer s10
check "10 another agent's session start prints nothing and takes no lock" $([ -z "$out" ] && [ ! -f "$state/session.lock" ]; echo $?)

echo "delegator-session: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
