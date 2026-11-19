#!/usr/bin/env bash
# Tests for .archon/scripts/recovery-state.js: the run history, parking, the circuit breaker (2 runs of one signature
# in 60 min, immediate, main red, half-open and its canary), the lock (concurrent writers, a stale lock), a corrupt
# file, and prune.
# Usage: bash .archon/scripts/test/recovery-state.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../recovery-state.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out=""

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
rs() { node "$script" "$@"; }
fresh() { export RECOVERY_DIR="$root/$1"; mkdir -p "$RECOVERY_DIR"; }
decision() { # decision <run> <signature> <action> <breaker> <at> [main_red]
  printf '{"run":"%s","signature":"%s","action":"%s","step":"x","attempt":1,"change_token":"t","breaker":"%s","at":"%s","main_red":%s}\n' \
    "$1" "$2" "$3" "$4" "$5" "${6:-false}"
}
state() { rs show | jq -r .state; }

# History, result and park.
fresh hist
out=$(decision r1 S04 resume counts 2026-10-20T10:00:00Z | rs record - 2>&1); rc=$?
check "record exits 0" $([ "$rc" -eq 0 ]; echo $?)
out=$(rs show r1)
check "record appends to the run history" $([ "$(echo "$out" | jq -r '.history | length')" = 1 ] && [ "$(echo "$out" | jq -r '.history[0].signature')" = S04 ]; echo $?)
rs result r1 resumed ok >/dev/null
out=$(rs show r1)
check "result sets the last entry's result" $([ "$(echo "$out" | jq -r '.history[0].result')" = "resumed ok" ]; echo $?)
rs park r1 tdd step missing >/dev/null
out=$(rs show r1)
check "park marks the run parked with its reason" $([ "$(echo "$out" | jq -r .parked)" = true ] && [ "$(echo "$out" | jq -r .parked_reason)" = "tdd step missing" ]; echo $?)
out=$(rs result nohistory x 2>&1); rc=$?
check "result on a run with no history: exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "one failure keeps the breaker closed" $([ "$(state)" = closed ]; echo $?)

# Breaker: one signature in 2 runs within 60 min opens it; the same run twice does not; outside 60 min does not.
fresh two
decision r1 S04 resume counts 2026-10-20T10:00:00Z | rs record - >/dev/null
decision r1 S04 resume counts 2026-10-20T10:10:00Z | rs record - >/dev/null
out=$(rs show); check "the same run twice keeps it closed" $([ "$(state)" = closed ]; echo $?)
decision r2 S04 resume counts 2026-10-20T10:50:00Z | rs record - >/dev/null
out=$(rs show); check "a second run within 60 min opens it" $([ "$(state)" = open ] && [ "$(echo "$out" | jq -r .signature)" = S04 ]; echo $?)
fresh apart
decision r1 S04 resume counts 2026-10-20T10:00:00Z | rs record - >/dev/null
decision r2 S04 resume counts 2026-10-20T11:01:00Z | rs record - >/dev/null
out=$(rs show); check "a second run after 60 min keeps it closed" $([ "$(state)" = closed ]; echo $?)
fresh othersig
decision r1 S04 resume counts 2026-10-20T10:00:00Z | rs record - >/dev/null
decision r2 S12 repair counts 2026-10-20T10:05:00Z | rs record - >/dev/null
out=$(rs show); check "two signatures in two runs keep it closed" $([ "$(state)" = closed ]; echo $?)
fresh exempt
decision r1 S16 repair exempt 2026-10-20T10:00:00Z | rs record - >/dev/null
decision r2 S16 repair exempt 2026-10-20T10:05:00Z | rs record - >/dev/null
out=$(rs show); check "an exempt signature never opens it" $([ "$(state)" = closed ]; echo $?)

# Immediate, and main red.
fresh immediate
decision r1 S02 ask immediate 2026-10-20T10:00:00Z | rs record - >/dev/null
out=$(rs show); check "an immediate signature opens it at once" $([ "$(state)" = open ]; echo $?)
fresh mainred
decision r1 S18 repair exempt 2026-10-20T10:00:00Z true | rs record - >/dev/null
out=$(rs show); check "main red opens it" $([ "$(state)" = open ] && echo "$out" | jq -r .reason | grep -q 'main is red'; echo $?)

# Half-open: only from open; a failed canary opens it again; a clean run end closes it; reset closes it.
fresh half
out=$(rs half-open 2>&1); check "half-open on a closed breaker stays closed" $([ "$(state)" = closed ]; echo $?)
decision r1 S02 ask immediate 2026-10-20T10:00:00Z | rs record - >/dev/null
rs half-open >/dev/null
out=$(rs show); check "half-open from open" $([ "$(state)" = half_open ]; echo $?)
decision c1 S07 resume counts 2026-10-20T11:00:00Z | rs record - >/dev/null
out=$(rs show); check "a failed canary opens it again" $([ "$(state)" = open ] && echo "$out" | jq -r .reason | grep -q canary; echo $?)
rs half-open >/dev/null
decision c2 S19 none exempt 2026-10-20T12:00:00Z | rs record - >/dev/null
out=$(rs show); check "a clean canary closes it" $([ "$(state)" = closed ]; echo $?)
decision r1 S02 ask immediate 2026-10-20T12:10:00Z | rs record - >/dev/null
rs reset-breaker >/dev/null
out=$(rs show); check "reset-breaker closes it" $([ "$(state)" = closed ] && [ "$(echo "$out" | jq -r '.runs | length')" = 0 ]; echo $?)
fresh s19closed
decision c2 S19 none exempt 2026-10-20T12:00:00Z | rs record - >/dev/null
out=$(rs show); check "a clean run end on a closed breaker changes nothing" $([ "$(state)" = closed ]; echo $?)

# The pure check the classifier uses.
out=$(node -e '
const { afterFailure } = require(process.argv[1]);
const b = { state: "closed", runs: [{ run: "a", signature: "S04", at: "2026-10-20T10:00:00Z" }] };
const r = afterFailure(b, { run: "b", signature: "S04", mode: "counts", mainRed: false, now: "2026-10-20T10:30:00Z" });
console.log(r.reason ? "trip" : "no", JSON.stringify(b.runs.length));' "$script")
check "afterFailure trips and leaves its input alone" $([ "$out" = "trip 1" ]; echo $?)

# Concurrent writers: 10 records at once all land, and no lock or temp file is left behind.
fresh concurrent
for i in $(seq 1 10); do decision r1 S04 resume exempt "2026-10-20T10:00:0${i: -1}Z" | rs record - >/dev/null & done
wait
out=$(rs show r1)
check "10 concurrent records all land" $([ "$(echo "$out" | jq -r '.history | length')" = 10 ]; echo $?)
out=$(ls -A "$RECOVERY_DIR" "$RECOVERY_DIR/runs")
check "no lock or temp file is left" $(! echo "$out" | grep -qE '\.lock|\.tmp'; echo $?)

# A stale lock (its pid gone) is taken over.
fresh stale
mkdir "$RECOVERY_DIR/.lock"; echo 999999 > "$RECOVERY_DIR/.lock/pid"
out=$(decision r1 S04 resume counts 2026-10-20T10:00:00Z | timeout 10 node "$script" record - 2>&1); rc=$?
check "a stale lock is taken over" $([ "$rc" -eq 0 ] && [ ! -d "$RECOVERY_DIR/.lock" ]; echo $?)

# A corrupt file is read as empty with a warning, and a record repairs it.
fresh corrupt
mkdir -p "$RECOVERY_DIR/runs"; echo '{not json' > "$RECOVERY_DIR/breaker.json"; echo 'x' > "$RECOVERY_DIR/runs/r1.json"
out=$(rs show 2>&1 >/dev/null); rc=$?
check "a corrupt breaker warns" $(echo "$out" | grep -q 'not valid JSON'; echo $?)
out=$(rs show 2>/dev/null); check "a corrupt breaker reads as closed" $([ "$(echo "$out" | jq -r .state)" = closed ]; echo $?)
out=$(decision r1 S04 resume counts 2026-10-20T10:00:00Z | rs record - 2>/dev/null); rc=$?
check "a record over a corrupt run file works" $([ "$rc" -eq 0 ] && [ "$(rs show r1 | jq -r '.history | length')" = 1 ]; echo $?)

# Prune: a run with no entry in the last n days goes, a recent one stays.
fresh prune
decision old S04 resume exempt 2020-01-01T00:00:00Z | rs record - >/dev/null
decision new S04 resume exempt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | rs record - >/dev/null
out=$(rs prune --days 7)
check "prune removes the old run only" $([ "$(echo "$out" | jq -c .removed)" = '["old"]' ] && [ -f "$RECOVERY_DIR/runs/new.json" ]; echo $?)

# Usage.
out=$(rs 2>&1); rc=$?; check "no command: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(rs bogus 2>&1); rc=$?; check "unknown command: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(echo 'nope' | rs record - 2>&1); rc=$?; check "record of a non-JSON line: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(rs prune --days 0 2>&1); rc=$?; check "prune --days 0: exit 2" $([ "$rc" -eq 2 ]; echo $?)
touch "$root/afile"; out=$(RECOVERY_DIR="$root/afile" timeout 10 node "$script" park r1 why 2>&1); rc=$?; check "an unwritable state dir: exit 1" $([ "$rc" -eq 1 ]; echo $?)

echo "recovery-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
