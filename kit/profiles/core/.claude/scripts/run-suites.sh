#!/usr/bin/env bash
# Runs test suites side by side, SUITE_JOBS at a time (default 4, owner decision 2026-10-22: 67 of the .archon suites one
# by one took 626s of archon-scripts' 900 on 2d1461f). Each suite's output is kept apart and printed whole, in the order
# given, as soon as it and every suite before it ended: the log reads as if they ran one by one.
#   run-suites.sh <suite.test.sh>...   exit 0 when every suite passed, 1 when one failed (each named in an ::error::)
# SUITE_JOBS is this runner's own: the suites do not see it, so one that tests a runner gets that runner's default.
set -uo pipefail
max=${SUITE_JOBS:-4}
[[ "$max" =~ ^[1-9][0-9]*$ ]] || { echo "SUITE_JOBS must be a whole number of 1 or more, not $max" >&2; exit 2; }
unset SUITE_JOBS
suites=("$@")
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
failed=0 shown=0
flush() { # prints every suite, in order, up to the first that has not ended
  while [ "$shown" -lt "${#suites[@]}" ] && [ -e "$out/$shown.rc" ]; do
    local t=${suites[$shown]}
    echo "::group::$t ($(cat "$out/$shown.secs")s)"
    cat "$out/$shown.log"
    [ "$(cat "$out/$shown.rc")" = 0 ] || { echo "::error::$t failed"; failed=1; }
    echo "::endgroup::"
    shown=$((shown + 1))
  done
}
for i in "${!suites[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$max" ]; do wait -n; flush; done
  ( s=$SECONDS; bash "${suites[$i]}" > "$out/$i.log" 2>&1 < /dev/null; rc=$?
    echo $((SECONDS - s)) > "$out/$i.secs"; echo "$rc" > "$out/$i.rc.tmp"; mv "$out/$i.rc.tmp" "$out/$i.rc" ) &
done
wait
flush
exit "$failed"
