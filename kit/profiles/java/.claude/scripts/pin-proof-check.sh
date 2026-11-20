#!/usr/bin/env bash
# The tests that prove the phase-0 framework pins ran and passed (TASK-6.6, AC #2, FW-P-04): reads the JUnit XML that
# Gradle wrote for each listed class and refuses a report that is missing (the set was skipped, the class renamed or never
# run), holds no test, or shows a failed, errored or skipped one. Run it after the Gradle build.
# Usage: bash .claude/scripts/pin-proof-check.sh [<repo-root>]   (default: this repository)
# Exit 0 = ok, 1 = refused (one FAIL line each), 2 = usage.
# The list is the project's file: kit key `pin_proofs` (env KIT_PIN_PROOFS, default
# .archon/pin-proofs.txt, relative to <repo-root>), one `<item>|<module>|<task>|<class>` line per proof, `#` comments and
# blank lines skipped. A project without the list file has no pins to prove: the check skips with a notice (exit 0).
# A list file that holds no proof is refused, so a build that keeps a list never passes with nothing proven.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }

if [ "$#" -gt 1 ] || [[ "${1:-}" == -* ]]; then
  echo "usage: pin-proof-check.sh [<repo-root>]" >&2
  exit 2
fi
repo="${1:-$(cd "$here/../.." && pwd)}"
cd "$repo" 2>/dev/null || { echo "FAIL: $repo is not a directory"; exit 1; }

failed=0
fail() { echo "FAIL: $1"; failed=1; }

list="$(kit_get pin_proofs .archon/pin-proofs.txt KIT_PIN_PROOFS)"
if [ ! -f "$list" ]; then
  echo "pin-proof: skipped, no $list (the project lists no framework pin proofs; add the file to check them)"
  exit 0
fi
proofs="$(tr -d '\r' <"$list" | grep -vE '^[[:space:]]*(#|$)')"
if [ -z "$proofs" ]; then
  echo "FAIL: no pin proofs in $list (list each <item>|<module>|<task>|<class> there)"
  exit 1
fi

if ! compgen -G "*/build/test-results" >/dev/null; then
  fail "no */build/test-results under $repo: run the Gradle build first"
fi

# attr <testsuite line> <name> -> the numeric value, or empty
attr() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\"\([0-9][0-9]*\)\".*/\1/p"; }

while IFS='|' read -r item module task class; do
  report="$module/build/test-results/$task/TEST-$class.xml"
  if [ ! -f "$report" ]; then
    fail "$item: no report $report (the set was skipped, the class renamed or never run)"
    continue
  fi
  suite="$(tr -d '\r' <"$report" | grep -m1 '<testsuite ')"
  tests="$(attr "$suite" tests)"; skipped="$(attr "$suite" skipped)"
  failures="$(attr "$suite" failures)"; errors="$(attr "$suite" errors)"
  if [ -z "$suite" ] || [ -z "$tests" ] || [ -z "$skipped" ] || [ -z "$failures" ] || [ -z "$errors" ]; then
    fail "$item: $report is unreadable (no <testsuite> element or its counts do not parse)"
  elif [ "$tests" -eq 0 ]; then
    fail "$item: $report holds no test"
  elif [ "$failures" -gt 0 ]; then
    fail "$item: $report has $failures failed test(s)"
  elif [ "$errors" -gt 0 ]; then
    fail "$item: $report has $errors errored test(s)"
  elif [ "$skipped" -gt 0 ]; then
    fail "$item: $report has $skipped skipped test(s)"
  fi
done <<<"$proofs"

[ "$failed" -eq 0 ] && echo "pin-proof: ok"
exit "$failed"
