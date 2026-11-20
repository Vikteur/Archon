#!/usr/bin/env bash
# Tests for .claude/scripts/ci-status-grammar.sh: every form it writes parses back to what was written, the forms posted
# before it parse as legacy, and anything else is unknown.
# Usage: bash scripts/test/ci-status-grammar.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-status-grammar.sh"
# shellcheck source=../../.claude/scripts/ci-status-grammar.sh
. "$script"
pass=0; fail=0
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}
is() { # is <state> <description> <key=value>...: the parse has every pair
  local state=$1 desc=$2 p parsed
  shift 2
  parsed=$(ci_status_parse "$state" "$desc")
  for p in "$@"; do grep -qxF "$p" <<<"$parsed" || { echo "    $desc -> missing $p"; return 1; }; done
}
fp=0123456789abcdef sha=89abcdef0123456789abcdef0123456789abcdef

# 1. A run: seconds, host, and only the tokens that apply.
d=$(ci_status_ran success 21 box)
check "1 a plain pass" $([ "$d" = "success in 21s on box" ] && is success "$d" kind=ran secs=21 host=box fp= narrowed=0 skipped=0 legacy=0; echo $?)
d=$(ci_status_ran success 245 box "$fp" 1 2)
check "1 fp, narrowed and skipped-locally, in that order" $([ "$d" = "success in 245s on box; fp=0123456789; narrowed: archon-suites; skipped-locally 2" ] \
  && is success "$d" kind=ran fp=0123456789 narrowed=1 skipped=2; echo $?)
d=$(ci_status_ran failure 9 box "" 0 0)
check "1 a red run" $([ "$d" = "failure in 9s on box" ] && is failure "$d" kind=ran state=failure secs=9; echo $?)
check "1 a description whose first word is not the state is unknown" $(is success "failure in 9s on box" kind=unknown; echo $?)
check "1 an unknown token is unknown" $(is success "success in 9s on box; trust me" kind=unknown; echo $?)

# 1b. A job green on a --rerun-failed after an infra signature (red-triage.sh, D5) is a pass that names the signature.
d=$(ci_status_ran success 30 box "$fp" 0 0 "gradle-daemon-oom")
check "1b green on rerun: the token comes last" $([ "$d" = "success in 30s on box; fp=0123456789; green on rerun after gradle-daemon-oom" ] \
  && is success "$d" kind=ran state=success fp=0123456789 rerun=gradle-daemon-oom; echo $?)
check "1b a plain pass has no rerun sig" $(is success "success in 9s on box" rerun=; echo $?)
check "1b a red run never says green on rerun" $([ "$(ci_status_ran failure 9 box "" 0 0 sig)" = "failure in 9s on box" ] \
  && is failure "failure in 9s on box; green on rerun after sig" kind=unknown; echo $?)
check "1b a ; in the sig cannot add a token" $([ "$(ci_status_ran success 9 box "" 0 0 "a; narrowed: archon-suites")" = "success in 9s on box; green on rerun after a, narrowed: archon-suites" ] \
  && is success "success in 9s on box; green on rerun after a, narrowed: archon-suites" kind=ran narrowed=0; echo $?)
check "1b a token after the rerun is unknown" $(is success "success in 9s on box; green on rerun after x; fp=0123456789" kind=unknown; echo $?)
check "1b the CLI formats it" $([ "$(bash "$script" format ran success 9 box "" 0 0 sig)" = "success in 9s on box; green on rerun after sig" ]; echo $?)

# 1c. The test count of the JUnit XML the job left comes right after the host; no count, no token.
d=$(ci_status_ran success 245 box "$fp" 1 2 "" 412)
check "1c the count comes before fp, narrowed and skipped-locally" $([ "$d" = "success in 245s on box; 412 tests; fp=0123456789; narrowed: archon-suites; skipped-locally 2" ] \
  && is success "$d" kind=ran tests=412 fp=0123456789 narrowed=1 skipped=2 legacy=0; echo $?)
check "1c one test is singular" $([ "$(ci_status_ran success 9 box "" 0 0 "" 1)" = "success in 9s on box; 1 test" ] \
  && is success "success in 9s on box; 1 test" kind=ran tests=1; echo $?)
check "1c a red run carries its count" $([ "$(ci_status_ran failure 9 box "" 0 0 "" 30)" = "failure in 9s on box; 30 tests" ] \
  && is failure "failure in 9s on box; 30 tests" kind=ran state=failure tests=30; echo $?)
check "1c no count, 0 or not a number: no token" $([ "$(ci_status_ran success 9 box "" 0 0 "" "")" = "success in 9s on box" ] \
  && [ "$(ci_status_ran success 9 box "" 0 0 "" 0)" = "success in 9s on box" ] \
  && [ "$(ci_status_ran success 9 box "" 0 0 "" "12; narrowed: archon-suites")" = "success in 9s on box" ] \
  && is success "success in 9s on box" kind=ran tests=; echo $?)
check "1c the count and the rerun sig together" $([ "$(ci_status_ran success 30 box "" 0 0 sig 7)" = "success in 30s on box; 7 tests; green on rerun after sig" ] \
  && is success "success in 30s on box; 7 tests; green on rerun after sig" kind=ran tests=7 rerun=sig; echo $?)
check "1c 0 tests, a second count or a count on the legacy form is unknown" $(is success "success in 9s on box; 0 tests" kind=unknown \
  && is success "success in 9s on box; 4 tests; 5 tests" kind=unknown \
  && is success "success in 9s on box, 2 step(s) skipped locally; 4 tests" kind=unknown; echo $?)
check "1c the CLI formats it" $([ "$(bash "$script" format ran success 9 box "" 0 0 "" 12)" = "success in 9s on box; 12 tests" ]; echo $?)

# 2. Reuse, infrastructure, not run, timed out.
d=$(ci_status_reused "$sha" "$fp" abcdef0123)
check "2 reused" $([ "$d" = "reused from 89abcdef0123; fp=0123456789; scope=abcdef0" ] \
  && is success "$d" kind=reused from=89abcdef0123 fp=0123456789 scope=abcdef0; echo $?)
check "2 a reuse is only ever a success" $(is failure "$d" kind=unknown; echo $?)
d=$(ci_status_same_tree "$sha")
check "2 same tree" $([ "$d" = "reused from 89abcdef0123; same tree" ] && is success "$d" kind=same-tree from=89abcdef0123; echo $?)
check "2 same tree is only ever a success" $(is failure "$d" kind=unknown; echo $?)
check "2 same tree: the CLI formats it" $([ "$(bash "$script" format same-tree "$sha")" = "$d" ]; echo $?)
d=$(ci_status_infra worktree box)
check "2 infra" $([ "$d" = "failure (infra: worktree) on box" ] && is failure "$d" kind=infra reason=worktree host=box; echo $?)
d=$(ci_status_notrun "not run: needed job bad failed" box)
check "2 not run" $(is failure "$d" kind=notrun "reason=not run: needed job bad failed" host=box; echo $?)
d=$(ci_status_timedout 30)
check "2 timed out" $(is failure "$d" kind=timedout minutes=30; echo $?)
check "2 a fractional timeout-minutes parses" $(is failure "$(ci_status_timedout 0.05)" kind=timedout minutes=0.05; echo $?)

# 3. Not a pass: cancelled and superseded are errors.
d=$(ci_status_cancelled "test failed first")
check "3 cancelled" $([ "$d" = "cancelled: test failed first, not a pass" ] && is error "$d" kind=cancelled "reason=test failed first"; echo $?)
check "3 cancelled is never a success" $(is success "$d" kind=unknown; echo $?)
d=$(ci_status_superseded 145 "$sha")
check "3 superseded" $(is error "$d" kind=superseded n=145 from=89abcde; echo $?)

# 4. The queue's pending forms.
d=$(ci_status_queued 12 3 4242 box 19:05)
check "4 queued" $([ "$d" = "queued #12 pos 3 since 19:05, pid 4242@box" ] && is pending "$d" kind=queued n=12 pos=3 since=19:05 pid=4242 host=box; echo $?)
d=$(ci_status_running 4242 box 19:07)
check "4 running" $([ "$d" = "running since 19:07, pid 4242@box" ] && is pending "$d" kind=running pid=4242 host=box; echo $?)

# 5. The forms posted before the grammar.
check "5 the old skipped suffix is legacy" $(is success "success in 21s on box, 2 step(s) skipped locally" kind=ran skipped=2 legacy=1; echo $?)
check "5 the old pending is legacy" $(is pending "running on box" kind=running host=box legacy=1; echo $?)
check "5 anything else is unknown" $(is success "passed" kind=unknown && is success "" kind=unknown; echo $?)

# 6. The longest realistic forms fit GitHub's 140 characters; the command line formats and parses too.
d=$(ci_status_ran success 99999 a-rather-long-host-name.example "$fp" 1 99)
check "6 the longest ran form fits 140 characters" $([ ${#d} -le 140 ]; echo $?)
d=$(ci_status_ran success 99999 a-rather-long-host-name.example "$fp" 1 99 "" 999999)
check "6 the longest ran form with a test count fits 140 characters" $([ ${#d} -le 140 ] && is success "$d" kind=ran tests=999999; echo $?)
check "6 the command line formats" $([ "$(bash "$script" format infra worktree box)" = "failure (infra: worktree) on box" ]; echo $?)
# A here-string, not | grep -q: under pipefail grep -q quitting at the first match can SIGPIPE the parser.
check "6 the command line parses" $(grep -qx kind=ran <<<"$(bash "$script" parse success "success in 3s on box")"; echo $?)
check "6 an unknown form is refused" $(bash "$script" format nope 2>/dev/null; [ $? -eq 2 ]; echo $?)
check "6 ci_status_get reads one field" $([ "$(ci_status_get secs success "success in 3s on box")" = 3 ]; echo $?)

echo "ci-status-grammar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
