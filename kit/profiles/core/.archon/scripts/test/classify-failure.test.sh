#!/usr/bin/env bash
# Tests for .archon/scripts/classify-failure.js: replays the corpus in fixtures/classify/cases.txt (every signature S01
# to S20 with its expected action, plus budgets, the change token and the breaker), then the usage and read errors.
# Usage: bash .archon/scripts/test/classify-failure.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../classify-failure.js"
fx="$here/fixtures/classify"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
NOW=2026-10-20T12:00:00Z

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
field() { printf '%s' "$out" | jq -r ".$1 // \"-\"" 2>/dev/null; }

# Each case gets its own recovery state: a copy of the named state dir, or an empty one.
n=0
seen=""
while read -r run facts st sig action step code nb; do
  case "$run" in ''|'#'*) continue ;; esac
  n=$((n+1)); name="case $n ($run, $facts, $st)"
  export RECOVERY_DIR="$root/state-$n"
  mkdir -p "$RECOVERY_DIR"
  [ "$st" = - ] || cp -r "$fx/$st/." "$RECOVERY_DIR/"
  out=$(node "$script" --json-file "$fx/$run" --facts-file "$fx/$facts" --now "$NOW" 2>&1); rc=$?
  check "$name: exit $code" $([ "$rc" -eq "$code" ]; echo $?)
  check "$name: one JSON line" $([ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && printf '%s' "$out" | jq -e . >/dev/null; echo $?)
  check "$name: signature $sig" $([ "$(field signature)" = "$sig" ]; echo $?)
  check "$name: action $action" $([ "$(field action)" = "$action" ]; echo $?)
  check "$name: step $step" $([ "$(field step)" = "$step" ]; echo $?)
  [ -z "$nb" ] || check "$name: not_before $nb" $([ "$(field not_before)" = "$nb" ]; echo $?)
  check "$name: no home path or user folder" $(! printf '%s' "$out" | grep -qE '/home/|Users'; echo $?)
  check "$name: the state is not written" $([ "$st" != - ] || [ -z "$(ls -A "$RECOVERY_DIR")" ]; echo $?)
  seen="$seen $sig"
done < "$fx/cases.txt"

# Every signature has at least one case.
for i in $(seq -w 1 24); do
  out="signatures seen:$seen"
  check "S$i has a fixture" $(printf '%s' "$seen" | grep -qw "S$i"; echo $?)
done

# Every signature in the table is unique, and S20 is the catch-all at the end.
out=$(jq -r '.signatures[].id' "$here/../classify-failure.signatures.json")
check "24 unique signatures" $([ "$(printf '%s\n' "$out" | sort -u | wc -l)" -eq 24 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 24 ]; echo $?)
check "S20 is last" $([ "$(printf '%s\n' "$out" | tail -1)" = S20 ]; echo $?)

# A truncated error that starts mid-text is still matched, over the failed node's own error (1341a8c0 starts mid-table).
export RECOVERY_DIR="$root/state-trunc"; mkdir -p "$RECOVERY_DIR"
jq '.metadata.error = "…table" | .terminal_record.error = "…table"' "$fx/run-1341a8c0.json" > "$root/trunc.json"
out=$(node "$script" --json-file "$root/trunc.json" --facts-file "$fx/facts-head-none.json" --now "$NOW" 2>&1)
check "truncated error matched over the node's own error" $([ "$(field signature)" = S05 ]; echo $?)

# The ticket comes from the ticket node's output, and the pull request from the facts.
out=$(node "$script" --json-file "$fx/syn-s12-nonff.json" --facts-file "$fx/facts-head-green.json" --now "$NOW" 2>&1)
check "ticket from the ticket node" $([ "$(field ticket)" = TASK-99.1 ]; echo $?)
check "pr from the facts" $([ "$(field pr)" = https://github.com/o/r/pull/7 ]; echo $?)

# S13 waiting on a red main pings once main has stayed red over 30 min.
out=$(node "$script" --json-file "$fx/syn-s13-red-from-main.json" --facts-file "$fx/facts-main-red-overlap.json" --now 2026-10-20T12:40:00Z 2>&1)
check "S13 waits for a green main" $([ "$(field wait_for)" = main-green ]; echo $?)
check "S13 red over 30 min pings now" $([ "$(field ping)" = now ]; echo $?)

# S24 waits on a red main without a ping of its own: merge-ready.sh pings a red main once per SHA.
out=$(node "$script" --json-file "$fx/syn-s24-main-ci.json" --facts-file "$fx/facts-merged-main-red.json" --now 2026-10-20T12:40:00Z 2>&1)
check "S24 red over 30 min stays a digest" $([ "$(field wait_for)" = main-green ] && [ "$(field ping)" = digest ]; echo $?)

# Usage and read errors.
out=$(node "$script" 2>&1); rc=$?
check "no run id: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(node "$script" x --bogus 2>&1); rc=$?
check "unknown option: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(node "$script" --json-file "$root/missing.json" --facts-file "$fx/facts-none.json" 2>&1); rc=$?
check "unreadable run: exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "unreadable run: no home path" $(! printf '%s' "$out" | grep -qE '/home/|Users'; echo $?)

echo "classify-failure: $pass passed, $fail failed ($n corpus cases)"
[ "$fail" -eq 0 ]
