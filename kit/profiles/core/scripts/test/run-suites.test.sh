#!/usr/bin/env bash
# Tests for .claude/scripts/run-suites.sh with stub suites.
# Usage: bash scripts/test/run-suites.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/run-suites.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Stub suites: each sleeps, notes when it ran, says its name and exits as told.
suite() { # suite <name> <secs> <rc>
  printf '#!/usr/bin/env bash\ndate +%%s.%%N > %s/%s.t0; sleep %s; echo "out of %s"; date +%%s.%%N > %s/%s.t1; exit %s\n' \
    "$root" "$1" "$2" "$1" "$root" "$1" "$3" > "$root/$1.test.sh"
}
suite a 2 0; suite b 1 0; suite c 1 3; suite d 1 0
out=$(bash "$script" "$root"/a.test.sh "$root"/b.test.sh "$root"/c.test.sh "$root"/d.test.sh 2>&1); rc=$?
overlap() { awk -v a0="$(cat "$root/$1.t0")" -v a1="$(cat "$root/$1.t1")" -v b0="$(cat "$root/$2.t0")" -v b1="$(cat "$root/$2.t1")" \
  'BEGIN { exit !(a0 < b1 && b0 < a1) }'; }
check "suites run side by side" $(overlap a b; echo $?)
check "a failed suite fails the run, the others still run" $([ "$rc" -eq 1 ] && [ -e "$root/d.t1" ]; echo $?)
check "the failed suite is named in an ::error::, the passed ones are not" $(grep -qx "::error::$root/c.test.sh failed" <<<"$out" \
  && [ "$(grep -c '::error::' <<<"$out")" -eq 1 ]; echo $?)
check "each suite's output is printed whole in its group, in the order given" $([ "$(grep -E '^::group::|^out of|^::endgroup::' <<<"$out" \
  | sed -E 's#::group::.*/([a-d])\.test\.sh \([0-9]+s\)#group \1#' | tr '\n' ' ')" \
  = "group a out of a ::endgroup:: group b out of b ::endgroup:: group c out of c ::endgroup:: group d out of d ::endgroup:: " ]; echo $?)

rm -f "$root"/*.t[01]
out=$(SUITE_JOBS=1 bash "$script" "$root"/a.test.sh "$root"/b.test.sh 2>&1); rc=$?
check "SUITE_JOBS=1 runs one at a time" $([ "$rc" -eq 0 ] && ! overlap a b; echo $?)
printf '#!/usr/bin/env bash\necho "jobs=${SUITE_JOBS-unset}"\n' > "$root/e.test.sh"
out=$(SUITE_JOBS=8 bash "$script" "$root"/e.test.sh 2>&1); rc=$?
check "a suite does not see SUITE_JOBS" $([ "$rc" -eq 0 ] && grep -qx "jobs=unset" <<<"$out"; echo $?)
out=$(SUITE_JOBS=0 bash "$script" "$root"/a.test.sh 2>&1); rc=$?
check "SUITE_JOBS must be 1 or more" $([ "$rc" -eq 2 ] && grep -q "SUITE_JOBS must be a whole number" <<<"$out"; echo $?)
out=$(bash "$script" 2>&1); rc=$?
check "no suite is a pass" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)

echo "run-suites tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
