#!/usr/bin/env bash
# Tests for .claude/scripts/ci-ledger.sh: one JSON line per event with the common fields, appends from many writers at
# once stay whole, a write that fails never fails the caller, and JUnit XML gives the seconds per test set.
# Usage: bash scripts/test/ci-ledger.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-ledger.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}
export CI_LEDGER="$root/ledger.jsonl"
unset CI_LOCAL_CALLER CI_LOCAL_TICKET

# 1. The sourced helper: common fields first, named fields after; caller and ticket from the environment, else null.
(
  # shellcheck source=../../.claude/scripts/ci-ledger.sh
  . "$script"
  CI_LOCAL_CALLER=delegator CI_LOCAL_TICKET=TASK-7 ci_ledger start --arg run abc1234.r1 --argjson pr 145 --arg ev forged
  ci_ledger end --argjson rc 1
)
check "1 one line per event" $([ "$(wc -l < "$CI_LEDGER")" -eq 2 ]; echo $?)
check "1 the common fields" $(sed -n 1p "$CI_LEDGER" | jq -e '.v == 1 and .ev == "start" and (.t | type) == "number" and (.host | length) > 0
  and .caller == "delegator" and .ticket == "TASK-7" and .run == "abc1234.r1" and .pr == 145' > /dev/null; echo $?)
check "1 the event name cannot be overridden" $(sed -n 1p "$CI_LEDGER" | jq -e '.ev == "start"' > /dev/null; echo $?)
check "1 no caller or ticket gives null" $(sed -n 2p "$CI_LEDGER" | jq -e '.caller == null and .ticket == null and .rc == 1' > /dev/null; echo $?)
check "1 v, ev and t come first" $(sed -n 1p "$CI_LEDGER" | grep -q '^{"v":1,"ev":"start","t":'; echo $?)

# 1b. One field style: event/ts are dropped, status becomes state unless a state is given.
( export CI_LEDGER="$root/style.jsonl"
  # shellcheck source=../../.claude/scripts/ci-ledger.sh
  . "$script"
  ci_ledger verdict --arg event reuse --arg ts 1 --arg status success
  ci_ledger verdict --arg state failure --arg status success )
check "1b event and ts are dropped, status becomes state" $(sed -n 1p "$root/style.jsonl" | jq -e '.ev == "verdict" and (.t | type) == "number"
  and .state == "success" and (has("event") or has("ts") or has("status") | not)' > /dev/null; echo $?)
check "1b a given state wins over status" $(sed -n 2p "$root/style.jsonl" | jq -e '.state == "failure" and (has("status") | not)' > /dev/null; echo $?)

# 2. The command line: k=v is a string, k:=json is JSON.
bash "$script" affected scope=archon-suites suites:='["a","b"]' n:=3
check "2 the command line writes a line" $(tail -n 1 "$CI_LEDGER" | jq -e '.ev == "affected" and .scope == "archon-suites" and .suites == ["a","b"] and .n == 3' > /dev/null; echo $?)
out=$(bash "$script" affected bad:=not-json 2>&1); rc=$?
check "2 bad JSON is not recorded and still exits 0" $([ "$rc" -eq 0 ] && grep -q "could not build" <<<"$out" && [ "$(wc -l < "$CI_LEDGER")" -eq 3 ]; echo $?)

# 3. Many writers at once: every line whole.
for i in $(seq 1 40); do bash "$script" request i:="$i" pad="$(printf 'x%.0s' $(seq 1 300))" & done; wait
check "3 40 concurrent appends give 40 whole lines" $([ "$(wc -l < "$CI_LEDGER")" -eq 43 ] && jq -se 'length == 43' "$CI_LEDGER" > /dev/null \
  && [ "$(jq -s '[.[] | select(.ev == "request") | .i] | unique | length' "$CI_LEDGER")" -eq 40 ]; echo $?)

# 4. A ledger that cannot be written: a warning, exit 0, and the caller goes on.
out=$(CI_LEDGER="$root" bash "$script" start 2>&1); rc=$?
check "4 an unwritable ledger warns and exits 0" $([ "$rc" -eq 0 ] && grep -q "could not append the start line" <<<"$out"; echo $?)
out=$( ( . "$script"; set -e; CI_LEDGER="$root/no/such/../../$(basename "$root")"; ci_ledger end; echo went-on ) 2>&1 )
check "4 the sourced helper never fails a set -e caller" $(grep -q went-on <<<"$out"; echo $?)

# 5. JUnit XML: seconds, tests, failures (errors included) and skipped per <module>:<task>, the root project as ".".
mkdir -p "$root/wt/application/build/test-results/test" "$root/wt/domain/build/test-results/integrationTest" \
  "$root/wt/build/test-results/test" "$root/wt/application/build/test-results/test/binary"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="A" tests="3" skipped="1" failures="1" errors="0"\n  timestamp="2026-10-20T10:00:00" hostname="h" time="1.5">\n<testcase name="x" time="1.5"/>\n</testsuite>\n' \
  > "$root/wt/application/build/test-results/test/TEST-A.xml"
printf '<testsuite name="B" tests="2" skipped="0" failures="0" errors="1" time="2.25"></testsuite>' > "$root/wt/application/build/test-results/test/TEST-B.xml"
printf '<testsuite name="C" tests="4" skipped="0" failures="0" errors="0" time="10.125"></testsuite>' > "$root/wt/domain/build/test-results/integrationTest/TEST-C.xml"
printf '<testsuite name="D" tests="1" time="0.5"></testsuite>' > "$root/wt/build/test-results/test/TEST-D.xml"
printf 'not xml' > "$root/wt/application/build/test-results/test/binary/results.bin"
j=$(bash "$script" junit "$root/wt")
check "5 one entry per test set" $(jq -e 'keys == [".:test", "application:test", "domain:integrationTest"]' <<<"$j" > /dev/null; echo $?)
check "5 summed per set" $(jq -e '.["application:test"] == {secs: 3.75, tests: 5, failures: 2, skipped: 1}
  and .["domain:integrationTest"].secs == 10.125 and .[".:test"].tests == 1' <<<"$j" > /dev/null; echo $?)
check "5 no XML gives {}" $([ "$(bash "$script" junit "$root/nowhere")" = "{}" ]; echo $?)

echo "ci-ledger tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
