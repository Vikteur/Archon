#!/usr/bin/env bash
# Tests for the test count on the local-ci/<job> status of .claude/scripts/ci-local.sh: a job that left JUnit XML posts
# `; <t> tests` (the sum over its TEST-*.xml files), a job that left none posts today's text, and every form parses
# as a ran status of ci-status-grammar.sh. A throwaway repo, its own ci.yml and a stubbed gh, as in ci-local.test.sh.
# Usage: bash scripts/test/ci-local-status.test.sh   (exit 0 = all pass)
set -uo pipefail
unset CI_LEDGER CI_REUSE CI_SCOPE CI_LOCAL_SLOTS CI_LOCAL_RUN CI_LOCAL_SLOT CI_LOCAL_XRUN CI_LOCAL_LOOKUP_TRIES
export CI_LOCAL_LOOKUP_PAUSE=0 CI_LOCAL_WATCH_POLL=0.1 CI_LOCAL_LOCK_POLL=0.1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$here/.claude/scripts/ci-local.sh"
# shellcheck source=../../.claude/scripts/ci-status-grammar.sh
. "$here/.claude/scripts/ci-status-grammar.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'git -C "$root/repo" worktree prune 2>/dev/null; rm -rf "$root"' EXIT

# gh only records its calls (the status post is `api -X POST`); `pr view` answers the base branch main.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") echo main ;;
esac
STUB
chmod +x "$root/bin/gh"

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/repo" 2>/dev/null
git -C "$root/repo" config user.name t; git -C "$root/repo" config user.email t@t
mkdir -p "$root/repo/.github/workflows"
cat > "$root/repo/.github/workflows/ci.yml" <<'YML'
jobs:
  counted:
    runs-on: ubuntu-latest
    steps:
      - name: Leaves JUnit XML in two modules and two test sets
        run: |
          mkdir -p build/test-results/test app/build/test-results/integrationTest app/build/test-results/test
          echo '<testsuite name="A" tests="3" failures="0" errors="0" skipped="0" time="0.1"></testsuite>' > build/test-results/test/TEST-A.xml
          echo '<testsuite name="B" tests="2" failures="0" errors="0" skipped="1" time="0.2"></testsuite>' > app/build/test-results/integrationTest/TEST-B.xml
          printf '<?xml version="1.0"?>\n<testsuite name="C"\n  tests="407" failures="0" errors="0" skipped="0" time="1">\n</testsuite>\n' > app/build/test-results/test/TEST-C.xml
  plain:
    runs-on: ubuntu-latest
    steps:
      - name: Leaves no JUnit XML
        run: echo nothing
  single:
    runs-on: ubuntu-latest
    steps:
      - name: Leaves one test
        run: |
          mkdir -p build/test-results/test
          echo '<testsuite name="S" tests="1" failures="0" errors="0" skipped="0" time="0.1"></testsuite>' > build/test-results/test/TEST-S.xml
  empty:
    runs-on: ubuntu-latest
    steps:
      - name: Leaves JUnit XML of no test
        run: |
          mkdir -p build/test-results/test
          echo '<testsuite name="E" tests="0" failures="0" errors="0" skipped="0" time="0"></testsuite>' > build/test-results/test/TEST-E.xml
  red:
    runs-on: ubuntu-latest
    steps:
      - name: Leaves a failed test, then fails
        run: |
          mkdir -p build/test-results/test
          echo '<testsuite name="R" tests="4" failures="1" errors="0" skipped="0" time="0.1"></testsuite>' > build/test-results/test/TEST-R.xml
          exit 1
YML
echo base > "$root/repo/README.md"
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm base; git -C "$root/repo" push -q origin main 2>/dev/null
sha=$(git -C "$root/repo" rev-parse HEAD)

: > "$root/gh.log"
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=.archon/githooks bash "$script" --post "$sha") 2>&1 ); rc=$?
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
desc() { # desc <job> <state>: the description of the job's last post in that state
  grep -E "state=$2 -f context=local-ci/$1 -f description=" "$root/gh.log" | tail -1 | sed 's/.* -f description=//'
}
ran() { # ran <state> <description> <tests>: the description parses as a ran status with that count
  local p; p=$(ci_status_parse "$1" "$2")
  grep -qx kind=ran <<<"$p" && grep -qx "tests=$3" <<<"$p"
}

check "the run ends red on the red job" $([ "$rc" -eq 1 ]; echo $?)
d=$(desc counted success)
check "a job's count is the sum over its modules and test sets" $([[ "$d" =~ ^success\ in\ [0-9]+s\ on\ [^\ \;]+\;\ 412\ tests$ ]] && ran success "$d" 412; echo $?)
d=$(desc plain success)
check "a job that left no JUnit XML posts today's text" $([[ "$d" =~ ^success\ in\ [0-9]+s\ on\ [^\ \;]+$ ]] && ran success "$d" ""; echo $?)
d=$(desc single success)
check "one test is singular" $([[ "$d" =~ ^success\ in\ [0-9]+s\ on\ [^\ \;]+\;\ 1\ test$ ]] && ran success "$d" 1; echo $?)
d=$(desc empty success)
check "JUnit XML of no test: no count" $([[ "$d" =~ ^success\ in\ [0-9]+s\ on\ [^\ \;]+$ ]] && ran success "$d" ""; echo $?)
d=$(desc red failure)
check "a red job carries its count" $([[ "$d" =~ ^failure\ in\ [0-9]+s\ on\ [^\ \;]+\;\ 4\ tests$ ]] && ran failure "$d" 4; echo $?)
check "the status file holds the posted description" $([ "$(cat "$root/out/${sha:0:7}/counted.status")" = "$(desc counted success)" ]; echo $?)

echo "ci-local-status tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
