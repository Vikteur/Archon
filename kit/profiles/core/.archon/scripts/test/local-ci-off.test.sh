#!/usr/bin/env bash
# Tests for the scripts the build workflows name when local CI is off (local_ci: false in .archon/kit.yaml, kit/SPEC.md
# Local CI switch): local-ci-run.sh runs nothing, local-ci-status.sh and ci-by-sha.sh read GitHub's checks, and
# red-triage.sh cannot triage. A stubbed gh on PATH answers the check runs and statuses; nothing reaches GitHub.
# Usage: bash .archon/scripts/test/local-ci-off.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# gh stub: check-runs answers $GH_RUNS, the combined status $GH_STATUSES (both "<name>\t<state>" lines, as the --jq
# filters would print them); GH_FAIL=1 makes every call fail. Each call is logged to $root/gh.log.
mkdir -p "$root/bin" "$root/repo"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
[ "${GH_FAIL:-}" = 1 ] && exit 1
case "$*" in
  *check-runs*) [ -n "${GH_RUNS:-}" ] && printf '%b\n' "$GH_RUNS" ;;
  *"/status "*|*"/status") [ -n "${GH_STATUSES:-}" ] && printf '%b\n' "$GH_STATUSES" ;;
esac
exit 0
STUB
chmod +x "$root/bin/gh"
# A runner that must never run: it marks its call.
printf '#!/usr/bin/env bash\ntouch "%s/runner-ran"\n' "$root" > "$root/runner.sh"
r="$root/repo"
git -C "$r" init -q -b feat
git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$r" remote add origin https://github.com/acme/app.git
sha=$(git -C "$r" rev-parse HEAD)
export PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL="$root/runner.sh"

off() { (cd "$r" && KIT_LOCAL_CI=false "$@"); }

# local-ci-run.sh: nothing runs, exit 0; --logs points at GitHub, exit 1
out=$(off bash "$here/local-ci-run.sh" 42 --head "$sha" 2>&1); rc=$?
check "1 local-ci-run: exit 0, says local CI is off" $([ "$rc" -eq 0 ] && grep -q 'local CI is off' <<< "$out"; echo $?)
check "1 local-ci-run: the runner never ran" $([ ! -e "$root/runner-ran" ]; echo $?)
out=$(off bash "$here/local-ci-run.sh" --logs 42 2>/dev/null); rc=$?
check "2 local-ci-run --logs: exit 1, names gh run view --log-failed" $([ "$rc" -eq 1 ] && grep -q 'gh run view <run-id> --log-failed' <<< "$out"; echo $?)

# The switch is read from kit.yaml too, not only from the environment (false is a value, not the default)
mkdir -p "$r/.archon"; printf 'local_ci: false\n' > "$r/.archon/kit.yaml"
out=$(cd "$r" && bash "$here/local-ci-run.sh" 42 --head "$sha" 2>&1); rc=$?
check "3 local_ci: false in kit.yaml switches it off" $([ "$rc" -eq 0 ] && [ ! -e "$root/runner-ran" ] && grep -q 'local CI is off' <<< "$out"; echo $?)
rm -f "$r/.archon/kit.yaml"

# red-triage.sh: cannot triage (exit 1, nothing on stdout), so the workflow counts the red as the branch's own
out=$(off bash "$here/red-triage.sh" --pr 42 --base main "$sha" 2>/dev/null); rc=$?
check "4 red-triage: exit 1, nothing on stdout" $([ "$rc" -eq 1 ] && [ -z "$out" ]; echo $?)

# local-ci-status.sh: the GitHub checks, one "<state> <detail>" line
status() { out=$(off bash "$here/local-ci-status.sh" acme/app "$sha" 2>&1); }
GH_RUNS='build\tsuccess\nlint\tskipped' GH_STATUSES='deploy/preview\tsuccess' status
check "5 status: every check passed is green" $([ "$out" = "green every GitHub check passed (3)" ]; echo $?)
GH_RUNS='build\tfailure\nlint\tsuccess' GH_STATUSES='' status
check "6 status: a failed check is red and named" $([ "$out" = "red build=failure" ]; echo $?)
GH_RUNS='build\tpending\nlint\tsuccess' GH_STATUSES='' status
check "7 status: a check still running is pending" $([ "$out" = "pending still running: build" ]; echo $?)
GH_RUNS='' GH_STATUSES='' status
check "8 status: no check yet is none" $([ "${out%% *}" = none ]; echo $?)
GH_FAIL=1 status
check "9 status: GitHub not answering is pending" $([ "${out%% *}" = pending ]; echo $?)
GH_RUNS='build\ttimed_out' GH_STATUSES='ci/legacy\terror' status
check "10 status: timed out and an error status are red" $([ "$out" = "red build=timed_out ci/legacy=error" ]; echo $?)
: > "$GH_LOG"
GH_RUNS='build\tsuccess' status
check "11 status: never reads local-ci statuses" $(! grep -q '/statuses' "$GH_LOG"; echo $?)

# ci-by-sha.sh: the verdict by SHA from GitHub's checks, in its usual JSON line
by() { out=$(off env CI_QUEUE=/nonexistent CI_GRACE_POLLS=2 LOCAL_CI_POLLS=2 LOCAL_CI_WAIT=0 bash "$here/ci-by-sha.sh" "$@" 2>/dev/null); rc=$?; }
GH_RUNS='build\tsuccess' by "$sha"
check "12 ci-by-sha: green from the GitHub checks" $([ "$rc" -eq 0 ] && grep -q '"state": "green".*"detail": "GitHub checks: every GitHub check passed' <<< "$out"; echo $?)
GH_RUNS='build\tfailure' by --check "$sha"
check "13 ci-by-sha --check: red names the check, exit 1" $([ "$rc" -eq 1 ] && grep -q '"state": "red".*GitHub checks: build=failure' <<< "$out"; echo $?)
GH_RUNS='' by "$sha"
check "14 ci-by-sha: no check after the wait is none, never green" $([ "$rc" -eq 0 ] && grep -q '"state": "none".*no GitHub check' <<< "$out"; echo $?)

echo "local-ci-off: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
