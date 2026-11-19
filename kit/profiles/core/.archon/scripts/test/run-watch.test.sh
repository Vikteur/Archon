#!/usr/bin/env bash
# Tests for .archon/scripts/run-watch.js (R19, T14) against fixture runs under throwaway ARCHON_HOMEs.
# Usage: bash .archon/scripts/test/run-watch.test.sh   (exit 0 = all pass)
set -uo pipefail
# The scripts' defaults, not the checkout's .archon/kit.yaml (an install's build_workflow differs).
export KIT_CONFIG=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/run-watch.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export RUN_LOG_OFFLINE=1            # archon is never asked
export TZ=Europe/Brussels           # the 37e12149 replay is in CEST
export READY_RUNS_DIR="$root/ready"; mkdir -p "$READY_RUNS_DIR"
for k in MERGED_WAIT FAILED_NOT_RESUMED MAIN_CI_SLOW GATE_WAIT CLOSE_FALSE NO_PROGRESS; do unset "RUN_WATCH_${k}_MIN"; done
out="$root/out.txt"; err="$root/err.txt"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$err" 2>/dev/null; fi
}
home() { export ARCHON_HOME="$root/$1"; logs="$ARCHON_HOME/workspaces/owner/repo/logs"; mkdir -p "$logs"; }
ws() { echo "{\"type\":\"workflow_start\",\"workflow_name\":\"build-feature\",\"content\":\"Build $1\",\"ts\":\"$2\"}"; }
ev() { # ev <type> <node> <ts> [kind] [extra json]
  echo "{\"type\":\"$1\",\"step\":\"$2\",\"ts\":\"$3\",\"execution\":{\"path\":\"$2\",\"node\":{\"kind\":\"${4:-exec}\"},\"attempt\":{\"id\":\"$2-1\"}}${5:+,$5}}"
}
ex() { echo "{\"type\":\"exec_output\",\"step\":\"$1\",\"ts\":\"$2\",\"exit_code\":0,\"stdout_tail\":$3}"; }
stalls() { node "$script" stalls --json "$@" > "$out" 2> "$err"; }
kind_at() { # kind_at <kind> <iso>: exit 1 with that kind printed
  stalls --at "$2"; local code=$?; [ $code -eq 1 ] && grep -q "\"kind\":\"$1\"" "$out"
}
none_at() { stalls --at "$1"; [ $? -eq 0 ] && [ ! -s "$out" ]; }

# The 37e12149 replay: the run reached merged at 2026-10-18T21:47:37.075Z (23:47 CEST) and nobody merged it.
home replay
m=37e12149a273706431e3cd80eb39e39f
{
  ws TASK-5.2 2026-10-18T21:12:14.574Z
  ev node_start ticket 2026-10-18T21:12:14.858Z
  ex ticket 2026-10-18T21:12:16Z '"{\"task\":\"TASK-5.2\",\"stop\":\"\"}"'
  ev node_complete ticket 2026-10-18T21:12:16.962Z
  ev node_start open-pr 2026-10-18T21:40:00Z
  ex open-pr 2026-10-18T21:41:00Z '"{\"pr\": \"https://github.com/o/r/pull/150\", \"sha\": \"9f7f760\"}"'
  ev node_complete open-pr 2026-10-18T21:41:00Z
  ev node_start auto-merge 2026-10-18T21:41:00Z loop_group
  ev node_complete auto-merge 2026-10-18T21:47:37Z loop_group
  ev node_start merged 2026-10-18T21:47:37.075Z
} > "$logs/$m.jsonl"
none_at 2026-10-18T21:57:00Z; check "replay: not yet a stall at 23:57:00" $?
kind_at merged-wait 2026-10-18T21:57:40Z; check "replay (a): merged-wait flagged at 23:57 with the 10 min threshold" $?
grep -q '"since":"2026-10-18T21:47:37.075Z"' "$out" && grep -q '"threshold_min":10' "$out"; check "the stall names its since and threshold" $?
export RUN_WATCH_MERGED_WAIT_MIN=30
none_at 2026-10-18T22:17:00Z; check "replay (b): not yet at 00:17:00 with 30 min" $?
kind_at merged-wait 2026-10-18T22:17:40Z; check "replay (b): flagged at 00:17 with RUN_WATCH_MERGED_WAIT_MIN=30" $?
unset RUN_WATCH_MERGED_WAIT_MIN

node "$script" snapshot --at 2026-10-19T05:57:40Z > "$out" 2> "$err"
grep -qx 'TASK-5.2 37e12149 waiting-for-merge since 23:47 (8h10m) PR #150, as of 07:57' "$out"; check "snapshot line with phase, local since, PR and as of" $?
node "$script" snapshot --at 2026-10-18T21:45:00Z --json > "$root/prev.json" 2> "$err"
node "$script" snapshot --at 2026-10-18T21:50:00Z --json > "$root/now.json" 2> "$err"
grep -q '"phase":"gate"' "$root/prev.json" && grep -q '"phase":"waiting-for-merge"' "$root/now.json"; check "snapshot --json gives the phase" $?
node "$script" events "$root/prev.json" "$root/now.json" > "$out" 2> "$err"
grep -q "\"key\":\"$m:waiting-for-merge:2026-10-18T21:47:37.075Z\",\"event\":\"phase\",\"from\":\"gate\",\"to\":\"waiting-for-merge\"" "$out"
check "events: a phase change with a stable key" $?
echo '{"as_of":"2026-10-18T21:40:00.000Z","runs":[{"run":"gone1","phase":"ci"}]}' > "$root/old.json"
node "$script" events "$root/old.json" "$root/now.json" > "$out" 2> "$err"
grep -q "\"key\":\"$m:new\"" "$out" && grep -q '"key":"gone1:gone"' "$out"; check "events: a new and a gone run" $?
node "$script" events "$root/nope.json" "$root/now.json" > "$out" 2> "$err"; [ $? -eq 2 ]; check "events: an unreadable file exits 2" $?

echo "{\"run\":\"$m\",\"pr\":\"https://github.com/o/r/pull/150\",\"since\":\"2026-10-18T21:48:00Z\"}" > "$READY_RUNS_DIR/$m.json"
node "$script" snapshot --at 2026-10-18T22:00:00Z > "$out" 2> "$err"; grep -q 'waiting-for-merge since 23:48' "$out"
check "a waiting run's since is its ready record's" $?
rm "$READY_RUNS_DIR/$m.json"

node "$script" snapshot > "$out" 2> "$err"; grep -q 'archon cannot be asked' "$err" && grep -q '37e12149 waiting-for-merge' "$out"
check "live without archon: falls back to the log with a warning" $?

# --state: printed once, a repeat within 30 min suppressed, printed again after 30 min, forgotten when it clears.
st="$root/state.json"
stalls --state "$st" --at 2026-10-18T22:00:00Z; [ $? -eq 1 ] && [ -s "$out" ]; check "--state prints a new stall" $?
stalls --state "$st" --at 2026-10-18T22:20:00Z; [ $? -eq 0 ] && [ ! -s "$out" ]; check "--state suppresses a repeat within 30 min" $?
stalls --state "$st" --at 2026-10-18T22:30:00Z; [ $? -eq 1 ] && [ -s "$out" ]; check "--state repeats after 30 min" $?
stalls --state "$st" --at 2026-10-18T21:50:00Z; [ $? -eq 0 ] && [ "$(cat "$st")" = '{}' ]; check "--state forgets a cleared stall" $?

# Every other kind, at its threshold and not before.
home failed
{
  ws TASK-9 2026-10-19T10:00:00Z
  ev node_start ci 2026-10-19T10:00:00Z
  ev node_error ci 2026-10-19T10:05:00Z
  echo '{"type":"workflow_error","error":"ci: Bash node ci failed [exit 1]","ts":"2026-10-19T10:05:00Z"}'
} > "$logs/ffff0000ffff0000ffff0000ffff0000.jsonl"
none_at 2026-10-19T10:14:00Z && kind_at failed-not-resumed 2026-10-19T10:15:00Z; check "failed-not-resumed at 10 min" $?
node "$script" snapshot --at 2026-10-19T10:15:00Z > "$out" 2> "$err"; grep -q 'TASK-9 ffff0000 failed since 12:05 (10m) at ci: ci: Bash node ci failed' "$out"
check "a failed run names its node and an excerpt" $?
node "$script" snapshot --at 2026-10-19T12:06:00Z > "$out" 2> "$err"; grep -q 'no build-feature run' "$out"; check "a run ended over 2 h ago leaves the snapshot" $?

home mainci
{ ws TASK-9 2026-10-19T09:00:00Z; ev node_start main-ci 2026-10-19T10:00:00Z; } > "$logs/cccc0000cccc0000cccc0000cccc0000.jsonl"
none_at 2026-10-19T10:09:00Z && kind_at main-ci-slow 2026-10-19T10:10:00Z; check "main-ci-slow at 10 min" $?

home gate
{ ws TASK-9 2026-10-19T09:00:00Z; ev node_start auto-merge 2026-10-19T10:00:00Z loop_group; ev node_start auto-merge.gate 2026-10-19T10:00:01Z; } > "$logs/aaaa0000aaaa0000aaaa0000aaaa0000.jsonl"
none_at 2026-10-19T10:19:00Z && kind_at gate-wait 2026-10-19T10:20:00Z; check "gate-wait at 20 min" $?

home close
{
  ws TASK-9 2026-10-19T09:00:00Z
  ev node_start finalize 2026-10-19T09:50:00Z
  ev node_complete finalize 2026-10-19T09:59:00Z
  ev node_skipped close-out 2026-10-19T09:59:30Z exec '"cause":{"kind":"when","expr":"$finalize.output.close == '"'true'"'"}'
  echo '{"type":"workflow_complete","ts":"2026-10-19T10:00:00Z"}'
} > "$logs/eeee0000eeee0000eeee0000eeee0000.jsonl"
none_at 2026-10-19T09:59:45Z && kind_at close-false 2026-10-19T10:00:00Z; check "close-false at once" $?
node "$script" snapshot --at 2026-10-19T10:01:00Z > "$out" 2> "$err"; grep -q 'completed since 12:00 (1m) close=false' "$out"; check "a completed run shows close=false" $?

home agent
{
  ws TASK-9 2026-10-19T09:00:00Z
  ev node_start plan 2026-10-19T10:00:00Z agent
  echo '{"type":"provider_event","step":"plan","event":{"type":"tool_call","observedAt":"2026-10-19T10:01:00Z"}}'
} > "$logs/dddd0000dddd0000dddd0000dddd0000.jsonl"
none_at 2026-10-19T10:20:00Z && kind_at no-progress 2026-10-19T10:21:00Z; check "no-progress at 20 min after the last event" $?
RUN_WATCH_NO_PROGRESS_MIN=5 kind_at no-progress 2026-10-19T10:06:00Z; check "RUN_WATCH_<KIND>_MIN overrides any kind" $?

# Errors.
node "$script" > "$out" 2> "$err"; [ $? -eq 2 ]; check "no command exits 2" $?
node "$script" stalls --at nonsense > "$out" 2> "$err"; [ $? -eq 2 ]; check "a bad --at exits 2" $?

echo "run-watch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
