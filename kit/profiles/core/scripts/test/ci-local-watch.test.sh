#!/usr/bin/env bash
# Tests for .claude/scripts/ci-local.sh against a throwaway repo, its own ci.yml and a stubbed gh: the watcher and its fail-fast, and the same-tree reuse of a merge commit (sections 15, 19).
# Usage: bash scripts/test/ci-local-watch.test.sh   (exit 0 = all pass)
# One of three suites that split the one 89 s ci-local suite, so that a render waits for the longest part (about 30 s);
# the shared setup is in ci-local-lib.sh, the section numbers are the old ones.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/ci-local-lib.sh"

# The old suite ran section 15 after the queue sections; the queue entry it plants names the commit before the run.
qsha=$(git -C "$root/repo" rev-parse HEAD)
unset CI_LOCAL_SLOTS
# 15. The watcher (C16): timeout-minutes stops a job; the first red is reported at once; CI_LOCAL_FAIL_FAST stops the
# other jobs of a red run always, never, or (default) only while another run is queued.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  red:
    runs-on: ubuntu-latest
    steps:
      - run: sleep 1; exit 1
  slow:
    runs-on: ubuntu-latest
    timeout-minutes: \${SLOW_LIMIT}
    steps:
      - run: sleep \${SLOW:-4} && touch $marks/slow.done
YML
sed -i 's/\${SLOW_LIMIT}/1/' "$root/repo/.github/workflows/ci.yml"
git -C "$root/repo" commit -qam "watcher jobs"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
rm -f "$marks/slow.done"
CI_LOCAL_FAIL_FAST=always run --post "$sha"
check "15 always: the other job is cancelled, not run to its end" $([ "$rc" -eq 1 ] && [ ! -e "$marks/slow.done" ] && grep -qE '^slow +cancelled' "$out_dir/summary.txt"; echo $?)
check "15 a cancelled job posts error cancelled: ..., not a pass" $(grep -q 'state=error -f context=local-ci/slow -f description=cancelled: red failed (CI_LOCAL_FAIL_FAST=always), not a pass$' "$root/gh.log"; echo $?)
check "15 the cancelled status parses as kind cancelled" $(desc=$(grep -m1 'state=error -f context=local-ci/slow -f description=cancelled:' "$root/gh.log" | sed 's/.*description=//'); \
  grep -qx kind=cancelled <<<"$(bash "$here_repo/.claude/scripts/ci-status-grammar.sh" parse error "$desc")" || { sed 's/^/    gh.log: /' "$root/gh.log" >&2; false; }; echo $?)
check "15 the first red is reported at once and logged" $(grep -q '^first red: red (failure)' <<<"$out" \
  && tail -n 20 "$ledger" | jq -se 'any(.[]; .ev == "first-red" and .job == "red")' > /dev/null; echo $?)
sleep 5
check "15 the cancelled job's processes are gone" $([ ! -e "$marks/slow.done" ]; echo $?)
CI_LOCAL_FAIL_FAST=never run "$sha"
check "15 never: the other job runs to its end" $([ -e "$marks/slow.done" ] && grep -qE '^slow +success' "$out_dir/summary.txt"; echo $?)
rm -f "$marks/slow.done"
run "$sha"
check "15 when-queued, nothing queued: the other job runs to its end" $([ -e "$marks/slow.done" ] && grep -qE '^slow +success' "$out_dir/summary.txt"; echo $?)
rm -f "$marks/slow.done"; : > "$root/gh.log"; rm -rf "$root/st"
( cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" SLOW=8 bash "$script" --post "$sha" > "$root/wq.out" 2>&1; echo $? > "$root/wq.rc" ) &
waitfor '[ -s "$out_dir/slow.started" ] 2>/dev/null'
sleep 300 & qholder=$!
printf 'n=9990\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=queued\n' "$qsha" "$qholder" "$(hostname)" > "$root/out/.queue/9990"
waitfor '[ -e "$root/wq.rc" ]'
check "15 when-queued, another run queued: the other job is cancelled" $([ "$(cat "$root/wq.rc")" = 1 ] && [ ! -e "$marks/slow.done" ] \
  && grep -q 'state=error -f context=local-ci/slow -f description=cancelled: red failed and run #9990 is queued, not a pass$' "$root/gh.log"; echo $?)
kill "$qholder"; wait "$qholder" 2>/dev/null; rm -f "$root/out/.queue/9990"
sed -i 's/timeout-minutes: 1$/timeout-minutes: 0.05/' "$root/repo/.github/workflows/ci.yml"
git -C "$root/repo" commit -qam "a short timeout"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
t0=$(date +%s)
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_FAIL_FAST=never SLOW=40 \
  bash "$script" --post "$sha") 2>&1 ); rc=$?
check "15 a job over its timeout-minutes is stopped" $([ "$rc" -eq 1 ] && [ $(( $(date +%s) - t0 )) -lt 30 ] && grep -qE '^slow +failure' "$out_dir/summary.txt"; echo $?)
check "15 and posts timed out after <m> min" $(grep -q 'state=failure -f context=local-ci/slow -f description=timed out after 0.05 min (ci.yml timeout-minutes)$' "$root/gh.log"; echo $?)
check "15 its step process is gone" $(! pgrep -f 'sleep 40' > /dev/null; echo $?)

# 19 needs the planner (section 13 of the old suite left it in the repo).
setup_planner
# 19. Same tree (owner decision 2026-10-23): a merge commit on main whose tree is exactly the tree its pull request
# head's last --post run tested, green on every job with the same ci.yml and runner class, posts `reused from <head
# sha12>; same tree` on every job and runs nothing. Anything else runs in full.
unset CI_LOCAL_SLOTS
git -C "$root/repo" switch -q main 2>/dev/null; git -C "$root/repo" reset -q --hard
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - run: echo one >> $marks/same
  two:
    runs-on: ubuntu-latest
    steps:
      - run: echo two >> $marks/same && test ! -e $marks/two.red
YML
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "same tree jobs"; git -C "$root/repo" push -q origin HEAD:main 2>/dev/null
pr_head() { # pr_head <name>: a pull request head off main and its --post run (PR 7); sets H
  git -C "$root/repo" switch -qc "pr-$1" main; echo "$1" > "$root/repo/pr-$1"
  git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "pr $1"; H=$(git -C "$root/repo" rev-parse HEAD)
  git -C "$root/repo" switch -q main; run --post "7:$H"
}
merge_it() { # merge_it <name> [--no-commit]: the merge commit of that head on main, pushed; sets M
  git -C "$root/repo" merge -q --no-ff --no-edit "${@:2}" "pr-$1" > /dev/null
  M=$(git -C "$root/repo" rev-parse HEAD); git -C "$root/repo" push -q origin main 2>/dev/null
}
ran_jobs() { wc -l < "$marks/same"; }
pr_head a; merge_it a
check "19 the head's run is green and keeps its runner class" $([ "$rc" -eq 0 ] && [ -n "$(cat "$root/out/${H:0:7}/runner")" ]; echo $?)
: > "$marks/same"; : > "$ledger"
run --post "$M"
check "19 same tree: nothing runs, exit 0" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 0 ]; echo $?)
check "19 same tree: every job posts reused from <head sha12>; same tree" \
  $(grep -qF "state=success -f context=local-ci/one -f description=reused from ${H:0:12}; same tree" "$root/gh.log" \
  && grep -qF "state=success -f context=local-ci/two -f description=reused from ${H:0:12}; same tree" "$root/gh.log"; echo $?)
check "19 same tree: a same-tree ledger event per job, naming the head and the tree" $(jq -se --arg m "$M" --arg h "$H" --arg t "$(git -C "$root/repo" rev-parse "$M^{tree}")" \
  '[.[] | select(.ev == "same-tree" and .sha == $m and .source == $h and .tree == $t and .state == "success") | .job] | sort == ["one", "two"]' "$ledger" > /dev/null; echo $?)
check "19 the start line carries the tested tree" $(jq -se --arg m "$M" 'any(.[]; .ev == "start" and .sha == $m and (.tree | length) == 40)' "$ledger" > /dev/null; echo $?)
check "19 the status parses as kind same-tree" $([ "$(bash "$here_repo/.claude/scripts/ci-status-grammar.sh" parse success "reused from ${H:0:12}; same tree" | head -n 1)" = kind=same-tree ]; echo $?)

pr_head b; echo moved > "$root/repo/moved"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm moved; merge_it b
: > "$marks/same"; run --post "$M"
check "19 main moved between the head's run and the merge: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

touch "$marks/two.red"; pr_head c; rm -f "$marks/two.red"; merge_it c
: > "$marks/same"; run --post "$M"
check "19 a red job in the head's run: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

pr_head d; sed -i '/local-ci\/two/d' "$root/st/$H"; merge_it d
: > "$marks/same"; run --post "$M"
check "19 a job missing in the head's run: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

pr_head e; merge_it e; touch "$root/out/scope-all"
: > "$marks/same"; run --post "$M"
check "19 the kill switch on: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)
rm -f "$root/out/scope-all"
: > "$marks/same"; run --post --all "$M"
check "19 --all: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

pr_head f; merge_it f --no-commit; echo "# changed in the merge" >> "$root/repo/.github/workflows/ci.yml"
git -C "$root/repo" commit -qam "Merge pr-f, ci.yml changed"; M=$(git -C "$root/repo" rev-parse HEAD); git -C "$root/repo" push -q origin main 2>/dev/null
: > "$marks/same"; run --post "$M"
check "19 ci.yml changed in the merge commit: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)
check "19 ci.yml changed: the run says why" $(grep -qF "same tree: not used, the head's run tested another tree" <<< "$out"; echo $?)

pr_head g; merge_it g
: > "$marks/same"; CI_PLAN_RUNNER=another-runner run --post "$M"
check "19 another runner class: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)
check "19 another runner class: the run says why, also in its folder" $(grep -qF "same tree: not used, another runner class" <<< "$out" \
  && [ "$(cat "$root/out/${M:0:7}/same-tree.why")" = "another runner class" ]; echo $?)

echo "ci-local watch tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
