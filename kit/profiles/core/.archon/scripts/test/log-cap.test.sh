#!/usr/bin/env bash
# Tests for .archon/scripts/log-cap.sh: a long test log is cut to its failure lines and its last lines before an agent
# reads it, a short one is copied whole, and the review-tests node caps review-tests.log with it, keeping the full log.
# Usage: bash .archon/scripts/test/log-cap.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/log-cap.sh"
wf="$here/../workflows/build-feature-copilot.yaml"
pass=0; fail=0; out=""
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# 1. Usage errors and a missing log: exit 2.
out=$(bash "$script" 2>&1); rc=$?
check "1 no arguments: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(bash "$script" "$d/none.log" "$d/cap.log" 2>&1); rc=$?
check "1 missing log: exit 2" $([ "$rc" -eq 2 ] && [ ! -e "$d/cap.log" ]; echo $?)
out=$(bash "$script" "$d/none.log" "$d/cap.log" x 2>&1); rc=$?
check "1 a last-lines that is no number: exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 2. A short log is copied whole.
printf 'one\nFAILED: a test\nthree\n' > "$d/short.log"
out=$(bash "$script" "$d/short.log" "$d/cap.log" 2>&1); rc=$?
check "2 short log: exit 0, copied whole" $([ "$rc" -eq 0 ] && cmp -s "$d/short.log" "$d/cap.log"; echo $?)

# 3. A long log keeps the failure lines (with their numbers) and the last lines, nothing else.
{ for i in $(seq 1 500); do echo "line $i"; done
  echo "FooTest > rejects a blank name FAILED"; echo "    org.opentest4j.AssertionFailedError: expected: 1"
  for i in $(seq 503 1000); do echo "line $i"; done
  echo "BUILD FAILED in 3s"; } > "$d/long.log"
out=$(bash "$script" "$d/long.log" "$d/cap.log" 2>&1); rc=$?
c=$(cat "$d/cap.log"); out="$out
$c"
check "3 long log: exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "3 names the full log" $(head -1 "$d/cap.log" | grep -qF "the whole log is $d/long.log"; echo $?)
check "3 the failing test, numbered" $(grep -qx '501:FooTest > rejects a blank name FAILED' <<< "$c"; echo $?)
check "3 the assertion, numbered" $(grep -q '^502: *org.opentest4j.AssertionFailedError' <<< "$c"; echo $?)
check "3 the last 200 lines" $(grep -qx 'line 802' <<< "$c" && ! grep -qx 'line 801' <<< "$c" && tail -1 <<< "$c" | grep -qx 'BUILD FAILED in 3s'; echo $?)
check "3 no early line" $(! grep -qx 'line 10' <<< "$c"; echo $?)
check "3 capped size" $([ "$(wc -l < "$d/cap.log")" -le 210 ]; echo $?)

# 4. The last-lines argument sets the cut: the last 10 lines are line 992 to line 1000 and BUILD FAILED.
out=$(bash "$script" "$d/long.log" "$d/cap.log" 10 2>&1); rc=$?
check "4 last 10 lines" $([ "$rc" -eq 0 ] && grep -qx '## Last 10 lines' "$d/cap.log" && ! grep -qx 'line 991' "$d/cap.log" && grep -qx 'line 992' "$d/cap.log"; echo $?)

# 5. The review-tests node keeps the full log and caps review-tests.log with this script.
out=$(yq '.nodes[] | select(.id == "review-tests") | .bash' "$wf")
check "5 review-tests writes the full log" $(grep -qF '> "$ARTIFACTS_DIR/review-tests-full.log" 2>&1' <<< "$out"; echo $?)
check "5 review-tests caps it into review-tests.log" \
  $(grep -qF 'bash .archon/scripts/log-cap.sh "$ARTIFACTS_DIR/review-tests-full.log" "$ARTIFACTS_DIR/review-tests.log"' <<< "$out"; echo $?)

echo "log-cap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
