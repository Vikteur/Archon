#!/usr/bin/env bash
# Tests for .archon/scripts/answer-blocked.sh against throwaway plan files.
# Usage: bash .archon/scripts/test/answer-blocked.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/answer-blocked.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
plan="$root/plan.md"
out="$root/out"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$plan" 2>/dev/null; fi
}
answer() { bash "$script" "$@" >"$out" 2>&1; }

printf '# Plan\n- [x] step 1\nBLOCKED: keep the old column?\n- [ ] step 2\nBLOCKED: which port?\n' > "$plan"

# 1. The first BLOCKED line becomes an ANSWER line that keeps the question; the rest of the plan is untouched.
answer "$plan" "yes, keep it"; rc=$?
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 first line answered" $(grep -qxF 'ANSWER: yes, keep it (to: keep the old column?)' "$plan"; echo $?)
check "1 second question left" $(grep -qxF 'BLOCKED: which port?' "$plan"; echo $?)
check "1 says one is left" $(grep -qF '1 BLOCKED line left' "$out"; echo $?)
check "1 rest untouched" $([ "$(sed -n '1,2p;4p' "$plan")" = "$(printf '# Plan\n- [x] step 1\n- [ ] step 2')" ]; echo $?)

# 2. The second; then none left, and it says to resume.
answer "$plan" 8080; rc=$?
check "2 second answered" $([ "$rc" -eq 0 ] && grep -qxF 'ANSWER: 8080 (to: which port?)' "$plan"; echo $?)
check "2 none left: resume" $(grep -qF 'no BLOCKED line left' "$out"; echo $?)

# 3. Refusals: nothing to answer, an empty answer, a multi-line answer, a file that is not a plan.md, usage.
cp "$plan" "$root/before"
answer "$plan" "again"; rc=$?
check "3 no BLOCKED line refused" $([ "$rc" -eq 1 ] && cmp -s "$plan" "$root/before"; echo $?)
printf 'BLOCKED: q\n' > "$plan"
answer "$plan" "   "; rc=$?
check "3 empty answer refused" $([ "$rc" -eq 2 ] && grep -qxF 'BLOCKED: q' "$plan"; echo $?)
answer "$plan" "$(printf 'a\nBLOCKED: injected')"; rc=$?
check "3 multi-line answer refused" $([ "$rc" -eq 2 ] && grep -qxF 'BLOCKED: q' "$plan"; echo $?)
printf 'BLOCKED: q\n' > "$root/notes.md"
answer "$root/notes.md" "x"; rc=$?
check "3 not a plan.md refused" $([ "$rc" -eq 2 ]; echo $?)
answer "$root/none/plan.md" "x"; rc=$?
check "3 missing plan refused" $([ "$rc" -eq 2 ]; echo $?)
answer; rc=$?
check "3 usage exit 2" $([ "$rc" -eq 2 ]; echo $?)

echo "answer-blocked: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
