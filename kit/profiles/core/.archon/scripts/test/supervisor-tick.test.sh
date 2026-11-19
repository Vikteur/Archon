#!/usr/bin/env bash
# Tests for .archon/scripts/supervisor-tick.sh (owner decision 2026-10-20, D15: shadow mode first; ROADMAP R20, T15)
# and the systemd units in .archon/systemd/. A throwaway main checkout holds stubs of the scripts the tick calls (each
# logs its call to $C/log), the real scope guard with a fixture policy, and a night list; archon and claude are stubs on
# PATH. The tick under test is a copy whose LIVE_FLAG and OWNER_UID lines are patched, as push-guard.test.sh does: the
# script has no environment override for them.
# T15: a quiet tick makes no model call; shadow runs no mutating command; two ticks never overlap; every command passes
# the scope guard as the delegator (a denied one is never run).
# Usage: bash .archon/scripts/test/supervisor-tick.test.sh   (exit 0 = all pass)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script=$repo/.archon/scripts/supervisor-tick.sh
pass=0; fail=0
root="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$root"' EXIT   # KEEP=1 keeps the temp root to read after a failure
check() { # check <name> <condition exit code> [<detail>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "${3:-}" ] && sed 's/^/    /' <<< "$3"; fi
}

export C=$root/c
M=$root/main
mkdir -p "$C" "$M/.archon/scripts" "$M/.claude/hooks/scripts" "$M/docs/rewrite" "$root/bin" "$root/flagdir"
cp "$repo/.claude/hooks/scripts/scope-guard.sh" "$M/.claude/hooks/scripts/"
cp "$repo/.archon/scripts/supervisor-jobs.sh" "$M/.archon/scripts/"
echo TASK-1 > "$M/docs/rewrite/night-list.txt"
POLICY_ALL='["node .archon/scripts/run-watch.js","node .archon/scripts/pick-tickets.js","node .archon/scripts/recovery-state.js",
 "bash .archon/scripts/merge-ready.sh","bash .archon/scripts/recover-run.sh","bash .archon/scripts/notify-owner.sh",
 "bash .archon/scripts/sync-main.sh","bash .archon/scripts/launch-run.sh","bash .archon/scripts/stop-check.sh",
 "bash .archon/scripts/cleanup-merged.sh"]'
policy() { jq -n --argjson a "$1" '{agents: {delegator: {allowedFilePaths: [], commandAllowlist: $a}}}' > "$M/.claude/hooks/agent-scopes.json"; }
policy "$POLICY_ALL"

stub() { # stub <file> <body>: a script that logs "<name> <args> [STOP_NO_FETCH=..]" and then runs <body>
  { echo '#!/usr/bin/env bash'; echo "echo \"$(basename "$1") \$* \${STOP_NO_FETCH:+STOP_NO_FETCH=\$STOP_NO_FETCH}\" >> \"\$C/log\""; echo "$2"; } > "$1"
}
S=$M/.archon/scripts
# run-watch.js: snapshot prints $C/snapshot ({runs: []} when missing; exits $C/snap_rc); stalls prints $C/stalls and
# exits 1 when it holds a line. Node scripts are bash here: the tick calls them as `node <file>`, so `node` on PATH is
# a stub that runs the file with bash.
stub "$S/run-watch.js" 'case "$1" in
  snapshot) [ -f "$C/snap_rc" ] && exit "$(cat "$C/snap_rc")"; cat "$C/snapshot" 2>/dev/null || echo "{\"source\":\"archon\",\"runs\":[]}" ;;
  stalls) [ -s "$C/stalls" ] && { cat "$C/stalls"; exit 1; }; exit 0 ;;
esac'
stub "$S/stop-check.sh" 'cat "$C/verdict" 2>/dev/null || echo none'
stub "$S/recover-run.sh" 'cat "$C/recover" 2>/dev/null || echo "{\"action\":\"none\"}"; exit "$(cat "$C/recover_rc" 2>/dev/null || echo 0)"'
stub "$S/recovery-state.js" 'cat "$C/breaker" 2>/dev/null || echo "{\"state\":\"closed\"}"'
stub "$S/pick-tickets.js" 'cat "$C/picks" 2>/dev/null || echo "{\"picked\":[]}"'
stub "$S/merge-ready.sh" '[ -f "$C/merge_sleep" ] && sleep "$(cat "$C/merge_sleep")"; exit 0'
stub "$S/sync-main.sh" 'exit 0'
stub "$S/launch-run.sh" 'exit 0'
stub "$S/cleanup-merged.sh" 'exit 0'
stub "$S/notify-owner.sh" 'exit "$(cat "$C/notify_rc" 2>/dev/null || echo 0)"'
stub "$root/bin/archon" 'exit 0'
stub "$root/bin/claude" 'exit 0'
cat > "$root/bin/node" <<'EOF'
#!/usr/bin/env bash
exec bash "$@"
EOF
chmod +x "$root/bin/"*
export PATH=$root/bin:$PATH

# The tick copies: one whose live flag never holds (owner uid 0, a file this user owns), one that trusts this user.
patched() { sed -e "s#^LIVE_FLAG=.*#LIVE_FLAG=$root/flagdir/live#" -e "s#^RECOVER_FLAG=.*#RECOVER_FLAG=$root/flagdir/recover#" \
  -e "s#^OWNER_UID=.*#OWNER_UID=$2#" "$script" > "$1"; }
patched "$root/tick-root.sh" 0
patched "$root/tick-me.sh" "$(id -u)"
export SUPERVISOR_MAIN=$M SUPERVISOR_STATE_DIR=$root/state READY_RUNS_DIR=$root/mq/ready MERGE_QUEUE_DIR=$root/mq
export SUPERVISOR_NIGHT_WINDOW=never
TL=$root/state/tick.log
reset() { rm -rf "$root/state" "$C" "$root/mq"; mkdir -p "$C" "$root/mq/ready/.state/held" "$root/mq/holds"; rm -f "$root/flagdir/live" "$root/flagdir/recover"; }
# A tick is bounded (stdin closed, TICK_TIMEOUT s): a stuck one fails its case by name instead of hanging the suite.
tick() {
  local rc; timeout "${TICK_TIMEOUT:-60}" bash "${TICK:-$root/tick-root.sh}" "$@" < /dev/null; rc=$?
  [ "$rc" -eq 124 ] && { fail=$((fail+1)); echo "FAIL: a tick $* did not end within ${TICK_TIMEOUT:-60} s" >&2; }
  return "$rc"
}
decisions() { grep -c '"key":' "$TL" 2>/dev/null || true; }
has() { grep -q -- "$1" "$TL" 2>/dev/null; }
mutated() { grep -E '^(merge-ready\.sh|notify-owner\.sh|sync-main\.sh|archon workflow run)|^recover-run\.sh [^ ]+ $' "$C/log" 2>/dev/null; }
until_deadline() { # until_deadline <seconds> <command...>: poll the command until it succeeds or the deadline passes
  local end=$(( $(date +%s) + $1 )); shift
  until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 0.1; done
}
waitfor() { until_deadline 20 grep -q -- "$1" "$C/log"; }   # waitfor <pattern>: until the stub log holds it

RUN_A=aaaaaaaa00000000000000000000000a RUN_B=bbbbbbbb00000000000000000000000b RUN_P=cccccccc00000000000000000000000c
PR=https://github.com/o/repo/pull/7
busy_snapshot() {
  jq -n --arg a "$RUN_A" --arg b "$RUN_B" --arg p "$RUN_P" --arg pr "$PR" '{source: "archon", runs: [
    {run: $a, ticket: "TASK-1", phase: "waiting-for-merge", pr_url: $pr},
    {run: $b, ticket: "TASK-2", phase: "failed", pr_url: null},
    {run: $p, ticket: "TASK-3", phase: "building", paused: true}]}' > "$C/snapshot"
  echo '{"run":"bbbbbbbb","signature":"S03","action":"resume","step":"resume","result":"dry run: would resume"}' > "$C/recover"
  echo "{\"run\":\"$RUN_A\",\"kind\":\"merged-wait\",\"over_min\":12.5,\"hint\":\"merge it\"}" > "$C/stalls"
  echo '{"picked":[{"id":"TASK-4"},{"id":"TASK-5"}]}' > "$C/picks"
}

# 1. Usage.
tick bogus 2> /dev/null; check "1 an unknown command exits 2" $([ $? -eq 2 ]; echo $?)

# 2. A quiet tick: no decision, no model call, a heartbeat, exit 0, in seconds.
reset
start=$(date +%s); tick; rc=$?; took=$(( $(date +%s) - start ))
check "2 a quiet tick exits 0" "$rc"
check "2 a quiet tick decides nothing" $([ "$(decisions)" = 0 ]; echo $?) "$(cat "$TL")"
check "2 a quiet tick makes no model call" $(! grep -q '^claude' "$C/log" 2>/dev/null; echo $?)
check "2 the heartbeat says shadow and 0 decided" $(jq -e '.mode == "shadow" and .decided == 0 and .errors == 0' "$root/state/heartbeat" > /dev/null; echo $?) "$(cat "$root/state/heartbeat" 2>&1)"
check "2 a quiet tick takes under 10 s" $([ "$took" -lt 10 ]; echo $?) "$took s"
check "2 outside the night window nothing is picked" $(! grep -q '^pick-tickets' "$C/log"; echo $?)

# 3. Shadow with work to do: every kind is decided and logged, nothing mutating runs.
reset; busy_snapshot
SUPERVISOR_NIGHT_WINDOW=always tick; rc=$?
check "3 exit 0" "$rc"
check "3 merge decided for the ready run" $(has '"key":"merge:7".*"cmd":"bash .archon/scripts/merge-ready.sh https://github.com/o/repo/pull/7"'; echo $?) "$(cat "$TL")"
check "3 recover decided for the failed run" $(has "\"key\":\"recover:bbbbbbbb:S03:resume\".*recover-run.sh $RUN_B\""; echo $?)
check "3 a ping for the paused run" $(has '"key":"ping:attention-cccccccc"'; echo $?)
check "3 a ping for the stall" $(has '"key":"ping:stall-aaaaaaaa-merged-wait"'; echo $?)
check "3 a launch per picked ticket" $(has '"key":"launch:TASK-4"' && has '"key":"launch:TASK-5"' && has 'bash .archon/scripts/launch-run.sh TASK-4"'; echo $?)
check "3 every decision is new and not run" $([ "$(grep '"key":' "$TL" | jq -s 'all(.new == true and .result == "shadow: not run")')" = true ]; echo $?)
check "3 every decision passes the fence" $([ "$(grep '"key":' "$TL" | jq -s 'all(.fence == "allowed")')" = true ]; echo $?) "$(grep '"key":' "$TL" | jq -r .fence)"
check "3 shadow runs no mutating command" $([ -z "$(mutated)" ]; echo $?) "$(mutated)"
check "3 recover-run ran with --dry-run" $(grep -q "^recover-run.sh $RUN_B --dry-run" "$C/log"; echo $?)
check "3 stop-check ran without its fetch" $(grep -q "^stop-check.sh $PR STOP_NO_FETCH=1" "$C/log"; echo $?) "$(cat "$C/log")"
check "3 the summary counts 6 decisions, 6 new" $(jq -e '.decided == 6 and .new == 6 and .runs == 3' "$root/state/heartbeat" > /dev/null; echo $?) "$(cat "$root/state/heartbeat")"

# 4. The next tick decides the same actions again, but none is new; a key no longer decided is forgotten.
: > "$TL"
SUPERVISOR_NIGHT_WINDOW=always tick
check "4 a repeat is not new" $([ "$(grep '"key":' "$TL" | jq -s 'length > 0 and all(.new == false)')" = true ]; echo $?) "$(cat "$TL")"
: > "$TL"; tick   # window closed: no launch decided, so the launch keys are forgotten
SUPERVISOR_NIGHT_WINDOW=always tick
check "4 a key decided again after a gap is new again" $(grep '"key":"launch:TASK-4"' "$TL" | tail -n 1 | jq -e '.new == true' > /dev/null; echo $?)

# 5. A held run, a hold marker, an owner verdict: no merge decided.
reset; busy_snapshot; rm "$C/stalls"
touch "$root/mq/ready/.state/held/$RUN_A"; tick
check "5 a held run is not merged" $(! has '"key":"merge:7"' && has '"kind":"skip".*is held'; echo $?) "$(cat "$TL")"
reset; busy_snapshot; touch "$root/mq/holds/o_repo_7"; tick
check "5 a hold marker is not merged" $(! has '"key":"merge:7"'; echo $?)
reset; busy_snapshot; printf 'owner\nauth-access: not approved\n' > "$C/verdict"; tick
check "5 an owner verdict pings instead of merging" $(! has '"key":"merge:7"' && has '"key":"ping:merge-held-7"'; echo $?) "$(cat "$TL")"

# 6. A run whose pull request url is not a plain url is skipped, never put in a command.
reset
jq -n --arg a "$RUN_A" '{source: "archon", runs: [{run: $a, phase: "waiting-for-merge", pr_url: "https://github.com/o/r/pull/7; touch /tmp/x"}]}' > "$C/snapshot"
tick
check "6 a bad pr url is skipped" $(! has '"key":"merge' && has '"kind":"skip"'; echo $?) "$(cat "$TL")"

# 7. Recovery asks: a ping, no recover decision. A completed run with nothing to do decides nothing.
reset
jq -n --arg b "$RUN_B" '{source: "archon", runs: [{run: $b, ticket: "TASK-2", phase: "failed"}]}' > "$C/snapshot"
echo '{"signature":"S20","action":"ask","step":"ask","result":"unknown failure"}' > "$C/recover"; echo 3 > "$C/recover_rc"
tick
check "7 ask gives a ping" $(has '"key":"ping:recover-bbbbbbbb-S20"' && ! has '"key":"recover:'; echo $?) "$(cat "$TL")"
reset
jq -n --arg b "$RUN_B" '{source: "archon", runs: [{run: $b, phase: "completed", close: false}]}' > "$C/snapshot"
tick
check "7 a completed run with action none decides nothing" $([ "$(decisions)" = 0 ]; echo $?) "$(cat "$TL")"
reset
jq -n --arg b "$RUN_B" '{source: "archon", runs: [{run: $b, ticket: "TASK-2", phase: "completed", close: true}]}' > "$C/snapshot"
tick
check "7 a completed run that closed decides the cleanup sweep" $(has '"key":"cleanup:bbbbbbbb".*"cmd":"bash .archon/scripts/cleanup-merged.sh --sweep"' && [ "$(decisions)" = 1 ]; echo $?) "$(cat "$TL")"
check "7 shadow does not sweep" $(! grep -q '^cleanup-merged.sh' "$C/log"; echo $?)

# 8. The breaker: open → no launch and a ping; half open → one launch only.
reset; busy_snapshot
echo '{"state":"open","tripped_at":"2026-10-20T01:00:00Z","reason":"S13 twice"}' > "$C/breaker"
SUPERVISOR_NIGHT_WINDOW=always tick
check "8 an open breaker launches nothing" $(! has '"kind":"launch"' && has '"key":"ping:breaker-open-2026-10-20T01:00:00Z"'; echo $?)
reset; busy_snapshot; echo '{"state":"half_open"}' > "$C/breaker"
SUPERVISOR_NIGHT_WINDOW=always tick
check "8 a half open breaker launches one" $([ "$(grep -c '"kind":"launch"' "$TL")" = 1 ]; echo $?)
reset; busy_snapshot; rm "$M/docs/rewrite/night-list.txt"
SUPERVISOR_NIGHT_WINDOW=always tick
check "8 no night list, no launch" $(! has '"kind":"launch"'; echo $?)
echo TASK-1 > "$M/docs/rewrite/night-list.txt"

# 9. Two ticks never overlap: a tick that finds the lock taken logs it and ends at once.
reset; mkdir -p "$root/state"
flock "$root/state/tick.lock" sleep 3 & holder=$!
until_deadline 10 bash -c '! flock -n "$1" true' _ "$root/state/tick.lock"   # the holder has the lock
start=$(date +%s); tick; rc=$?; took=$(( $(date +%s) - start ))
check "9 an overlapping tick exits 0 at once" $([ "$rc" -eq 0 ] && [ "$took" -lt 2 ]; echo $?)
check "9 it logs the overlap and calls nothing" $(has '"kind":"overlap"' && [ ! -s "$C/log" ]; echo $?) "$(cat "$TL")"
wait "$holder"

# 10. Fail open: a failing snapshot is logged, the tick exits 0; the third failing tick in a row pings the owner.
reset; echo 2 > "$C/snap_rc"
tick; rc=$?
check "10 a failing step exits 0" "$rc"
check "10 the error is logged" $(has '"kind":"error".*run-watch snapshot'; echo $?) "$(cat "$TL")"
tick; tick
check "10 three failing ticks ping the owner" $(has '"key":"ping:supervisor-failing"'; echo $?)
rm "$C/snap_rc"; tick
check "10 a clean tick resets the count" $([ ! -f "$root/state/fails" ]; echo $?)
reset; echo 'not json' > "$C/snapshot"; tick; rc=$?
check "10 a snapshot that is no JSON exits 0 and is logged" $([ "$rc" -eq 0 ] && has 'is no JSON'; echo $?)

# 11. Paused: a heartbeat and nothing else.
reset; busy_snapshot; mkdir -p "$root/state"; touch "$root/state/paused"
tick
check "11 paused calls nothing" $([ ! -s "$C/log" ] && jq -e '.mode == "paused"' "$root/state/heartbeat" > /dev/null; echo $?)

# 12. The live flag: only a file owned by the owner uid, not a symlink, not group or world writable, in such a folder.
reset; touch "$root/flagdir/live"; chmod 644 "$root/flagdir/live"; chmod 755 "$root/flagdir"
check "12 a flag this user owns is no live flag when root must own it" $(tick status | grep -xe 'mode: shadow' > /dev/null; echo $?)
check "12 a flag the owner uid owns is live" $(TICK=$root/tick-me.sh tick status | grep -xe 'mode: live' > /dev/null; echo $?)
chmod 664 "$root/flagdir/live"
check "12 a group-writable flag is no live flag" $(TICK=$root/tick-me.sh tick status | grep -xe 'mode: shadow' > /dev/null; echo $?)
chmod 644 "$root/flagdir/live"; chmod 775 "$root/flagdir"
check "12 a flag in a group-writable folder is no live flag" $(TICK=$root/tick-me.sh tick status | grep -xe 'mode: shadow' > /dev/null; echo $?)
chmod 755 "$root/flagdir"; rm "$root/flagdir/live"; touch "$root/real"; ln -s "$root/real" "$root/flagdir/live"
check "12 a symlinked flag is no live flag" $(TICK=$root/tick-me.sh tick status | grep -xe 'mode: shadow' > /dev/null; echo $?)
check "12 the real script has no override for the flag" $(grep -q '^LIVE_FLAG=/etc/delegator-supervisor/live$' "$script" \
  && grep -q '^OWNER_UID=0$' "$script" && ! grep -qE 'LIVE_FLAG=\$\{|OWNER_UID=\$\{' "$script"; echo $?)

# 13. Live: each action starts once, detached; a repeat within the cooldown does not start it again.
reset; busy_snapshot; touch "$root/flagdir/live"; chmod 644 "$root/flagdir/live"
export TICK=$root/tick-me.sh
SUPERVISOR_NIGHT_WINDOW=always tick; rc=$?
check "13 a live tick exits 0" "$rc"
check "13 the merge runs" $(waitfor "^merge-ready.sh $PR"; echo $?) "$(cat "$C/log")"
sleep 0.3
check "13 without the recover flag no recovery runs (D13 dry-run week)" $(! grep -q "^recover-run.sh $RUN_B \$" "$C/log" \
  && has '"key":"recover:bbbbbbbb:S03:resume".*"result":"not run: the D13 dry-run week is not over'; echo $?) "$(cat "$TL")"
check "13 the launch syncs main and runs launch-run.sh" $(waitfor '^launch-run.sh TASK-4' && grep -q '^sync-main.sh' "$C/log"; echo $?) "$(cat "$C/log")"
check "13 the pings go through notify-owner" $(grep -q '^notify-owner.sh act attention-cccccccc' "$C/log" && grep -q '^notify-owner.sh warn stall-aaaaaaaa-merged-wait' "$C/log"; echo $?) "$(cat "$C/log")"
check "13 the results say started and sent" $(has '"key":"merge:7".*"result":"started' && has '"key":"ping:attention-cccccccc".*"result":"sent"'; echo $?) "$(cat "$TL")"
sleep 0.5
SUPERVISOR_NIGHT_WINDOW=always tick
check "13 a second tick starts nothing again" $([ "$(grep -c '^merge-ready.sh' "$C/log")" = 1 ] && [ "$(grep -c '^notify-owner.sh act attention' "$C/log")" = 1 ] \
  && [ "$(grep -c '^launch-run.sh TASK-4' "$C/log")" = 1 ]; echo $?) "$(cat "$C/log")"
check "13 it says why" $(grep '"key":"merge:7"' "$TL" | tail -n 1 | grep -q 'not run: started 0 min ago'; echo $?)

# 13b. Live with the recover flag: the recovery runs without --dry-run, once.
reset; busy_snapshot; rm "$C/stalls" "$C/picks"; touch "$root/flagdir/live" "$root/flagdir/recover"; chmod 644 "$root/flagdir/live" "$root/flagdir/recover"
tick
check "13b with the recover flag the recovery runs without --dry-run" $(waitfor "^recover-run.sh $RUN_B \$"; echo $?) "$(cat "$C/log")"
check "13b status says live recovery is on" $(tick status | grep -e '^live recovery: on' > /dev/null; echo $?)
chmod 664 "$root/flagdir/recover"
check "13b a group-writable recover flag does not count" $(tick status | grep -e '^live recovery: off' > /dev/null; echo $?)

# 13c. Live while a delegator session holds its lock with a live pid: no launch; a dead pid does not count.
reset; busy_snapshot; rm "$C/stalls"; touch "$root/flagdir/live"; chmod 644 "$root/flagdir/live"
mkdir -p "$root/mq/delegator"; sleep 30 & sess=$!
echo "sess-1 $sess 2026-10-20T22:00:00Z" > "$root/mq/delegator/session.lock"
SUPERVISOR_NIGHT_WINDOW=always tick; sleep 0.3
check "13c a live session owns launches" $(! grep -q '^launch-run.sh' "$C/log" && has '"key":"launch:TASK-4".*"result":"not run: delegator session owns launches"'; echo $?) "$(cat "$TL")"
check "13c the merge still runs" $(waitfor "^merge-ready.sh $PR"; echo $?)
kill "$sess" 2>/dev/null; wait "$sess" 2>/dev/null
SUPERVISOR_NIGHT_WINDOW=always tick
check "13c a dead session pid does not stop the launch" $(waitfor '^launch-run.sh TASK-4'; echo $?) "$(cat "$C/log")"

# 14. Live, an action still running is not started again even after the cooldown.
reset; busy_snapshot; rm "$C/stalls" "$C/picks"; echo 3 > "$C/merge_sleep"; touch "$root/flagdir/live"; chmod 644 "$root/flagdir/live"
SUPERVISOR_REPEAT_MIN=0 tick; waitfor "^merge-ready.sh"
check "14 a running action does not hold the tick lock" $(flock -n "$root/state/tick.lock" true; echo $?)
SUPERVISOR_REPEAT_MIN=0 tick
check "14 a running action is not started twice" $([ "$(grep -c '^merge-ready.sh' "$C/log")" = 1 ] && grep '"key":"merge:7"' "$TL" | tail -n 1 | grep -q 'still running'; echo $?) "$(cat "$TL")"
until_deadline 30 flock -n "$root/state/inflight/merge_7.lock" true   # the action ended: its merge does not reach case 15

# 15. Live, the fence denies a command: it is not run, and the owner is pinged.
reset; busy_snapshot; rm "$C/stalls" "$C/picks"; touch "$root/flagdir/live"; chmod 644 "$root/flagdir/live"
policy "$(jq -c 'map(select(. != "bash .archon/scripts/merge-ready.sh"))' <<< "$POLICY_ALL")"
tick; sleep 0.5
check "15 a denied command does not run" $(! grep -q '^merge-ready.sh' "$C/log" && has '"key":"merge:7".*"fence":"denied.*"result":"not run: the fence denies it"'; echo $?) "$(cat "$TL")"
check "15 the owner is pinged about it" $(grep -q '^notify-owner.sh warn ping-fence-merge_7' "$C/log" || grep -q '^notify-owner.sh warn fence-merge_7' "$C/log"; echo $?) "$(cat "$C/log")"
policy "$POLICY_ALL"

# 16. Live, no notify-owner.sh: "ping not delivered", the tick goes on and exits 0.
reset; busy_snapshot; rm "$C/picks"; touch "$root/flagdir/live"; chmod 644 "$root/flagdir/live"
mv "$S/notify-owner.sh" "$root/notify.bak"
tick; rc=$?
check "16 a missing notifier is logged, not fatal" $([ "$rc" -eq 0 ] && has '"key":"ping:attention-cccccccc".*"result":"ping not delivered"'; echo $?) "$(cat "$TL")"
mv "$root/notify.bak" "$S/notify-owner.sh"
unset TICK

# 17. The units: a timer every 3 minutes that starts a oneshot service running the tick; systemd accepts both.
U=$repo/.archon/systemd
check "17 the timer fires every 3 minutes" $(grep -qx 'OnCalendar=\*:0/3' "$U/delegator-supervisor.timer"; echo $?)
check "17 the timer starts the service and is wanted by timers.target" $(grep -qx 'Unit=delegator-supervisor.service' "$U/delegator-supervisor.timer" \
  && grep -qx 'WantedBy=timers.target' "$U/delegator-supervisor.timer"; echo $?)
check "17 the service is a oneshot running the tick" $(grep -qx 'Type=oneshot' "$U/delegator-supervisor.service" \
  && grep -q '^ExecStart=.*\.archon/scripts/supervisor-tick.sh tick$' "$U/delegator-supervisor.service"; echo $?)
check "17 the service is killed before the next tick is due" $(t=$(sed -n 's/^TimeoutStartSec=//p' "$U/delegator-supervisor.service"); [ -n "$t" ] && [ "$t" -lt 180 ]; echo $?)
if command -v systemd-analyze > /dev/null 2>&1; then
  out=$(systemd-analyze --user verify "$U/delegator-supervisor.service" "$U/delegator-supervisor.timer" 2>&1)
  check "17 systemd-analyze verifies the units" $([ -z "$out" ]; echo $?) "$out"
fi

echo "supervisor-tick: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
