#!/usr/bin/env bash
# Tests for .claude/scripts/ci-local.sh against a throwaway repo, its own ci.yml and a stubbed gh: the queue, the ledger, run or reuse, --rerun-failed, --audit and finished commits (sections 11-14, 17, 20).
# Usage: bash scripts/test/ci-local-queue.test.sh   (exit 0 = all pass)
# One of three suites that split the one 89 s ci-local suite, so that a render waits for the longest part (about 30 s);
# the shared setup is in ci-local-lib.sh, the section numbers are the old ones.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/ci-local-lib.sh"

# Section 10 leaves the quick job and the one-at-a-time lock behind; sections 11-13 of the old suite ran on both.
export CI_LOCAL_SLOTS=1
commit_quick_job

# 11. The queue: --post calls of one commit share one run; callers start in the order they asked; a queued status is
# posted before the run's turn; a queue entry whose process is gone is reaped as stale.
: > "$root/gh.log"; : > "$marks/order"; rm -f "$root"/dup*.rc; rm -rf "$root/st"
bg dup1 SLEEP=3 -- --post "$sha"
waitfor '[ "$(entries)" -ge 1 ]'
bg dup2 -- --post "$sha"
waitfor '[ -e "$root/dup2.rc" ]'
dup1_still_running=$([ ! -e "$root/dup1.rc" ]; echo $?)
waitfor '[ -e "$root/dup1.rc" ]'
check "11 two --post calls of one commit give one run" $([ "$(wc -l < "$marks/order")" -eq 1 ] \
  && [ "$(grep -c 'description=running since' "$root/gh.log")" -eq 1 ]; echo $?)
check "11 the second exits 0 at once, naming the live run and its folder" $([ "$dup1_still_running" -eq 0 ] \
  && [ "$(cat "$root/dup1.rc")" = 0 ] && [ "$(cat "$root/dup2.rc")" = 0 ] \
  && grep -qE "is pending, its run alive: #[0-9]+ (queued|running), pid [0-9]+; not run again; its folder is $root/out/${sha:0:7} \(--force runs it anyway\)" "$root/dup2.out"; echo $?)
check "11 nothing is left in the queue" $([ "$(entries)" -eq 0 ] && [ ! -e "$root/out/.running" ]; echo $?)
shas=()
for n in 1 2 3; do echo "$n" > "$root/repo/q$n"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "q$n"; shas+=("$(git -C "$root/repo" rev-parse HEAD)"); done
: > "$marks/order"; rm -f "$root"/fifo*.rc
bg fifo1 SLEEP=2 -- "${shas[0]}"; waitfor '[ "$(entries)" -ge 1 ]'
bg fifo2 -- "${shas[1]}"; waitfor '[ "$(entries)" -ge 2 ]'
bg fifo3 -- "${shas[2]}"
waitfor '[ -e "$root/fifo1.rc" ] && [ -e "$root/fifo2.rc" ] && [ -e "$root/fifo3.rc" ]'
check "11 callers run in the order they asked" $([ "$(tr '\n' ' ' < "$marks/order")" = "${shas[0]:0:7} ${shas[1]:0:7} ${shas[2]:0:7} " ]; echo $?)
check "11 a waiting caller says where it is in the queue" $(grep -q "queued as #[0-9]* at position 2: waiting for #" "$root/fifo2.out"; echo $?)
sleep 60 & holder=$!
mkdir -p "$root/out/.running"; echo "$holder" > "$root/out/.running/pid"; echo other > "$root/out/.running/what"
: > "$root/gh.log"; rm -f "$root/held.rc"
bg held -- --post "${shas[2]}"
waitfor 'grep -q "waiting for the local CI of other" "$root/held.out"'
check "11 queued is posted before the run's turn, running only once it comes" $(grep -q 'context=local-ci/quick -f description=queued #[0-9]* pos 1 since' "$root/gh.log" \
  && ! grep -q 'description=running since' "$root/gh.log"; echo $?)
check "11 the queue shows the waiting entry" $(CI_LOCAL_ROOT="$root/out" bash "$qs" list | grep -qE "^#[0-9]+ queued ${shas[2]:0:7} [0-9]+@" \
  && CI_LOCAL_ROOT="$root/out" bash "$qs" state "${shas[2]}" | grep -q '^queued #[0-9]* pos 1 pid'; echo $?)
kill "$holder"; wait "$holder" 2>/dev/null
waitfor '[ -e "$root/held.rc" ]'
check "11 it runs once the lock is free" $([ "$(cat "$root/held.rc")" = 0 ] && grep -q 'description=running since' "$root/gh.log"; echo $?)
sleep 0.1 & dead=$!; wait "$dead"
printf 'n=900\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=queued\n' "$sha" "$dead" "$(hostname)" > "$root/out/.queue/900"
check "11 a queued entry whose process is gone reads stale" $(CI_LOCAL_ROOT="$root/out" bash "$qs" state "$sha" 2>/dev/null | grep -q "^stale #900 pid $dead"; echo $?)
printf 'n=901\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=queued\n' "$sha" "$dead" "$(hostname)" > "$root/out/.queue/901"
rm -rf "$root/st"
CI_LOCAL_LOCK_POLL=1 run --post "$sha"
check "11 and is reaped: the run does not wait for it or attach to it" $([ "$rc" -eq 0 ] && grep -q "entry #901 .* is stale" <<<"$out" \
  && ! grep -q "already queued" <<<"$out" && [ ! -e "$root/out/.queue/901" ]; echo $?)
check "11 none-check answers none when no entry comes" $(CI_LOCAL_ROOT="$root/out" CI_NONE_GRACE=1 CI_QUEUE_POLL=1 bash "$qs" none-check 0123456789012345678901234567890123456789 | grep -qx none; echo $?)

unset CI_LOCAL_SLOTS

# 12. The ledger: one line per event, start and end with the same run id; with a ledger that cannot be written, the
# statuses and the exit code are the same.
: > "$ledger"
: > "$root/gh.log"; rm -rf "$root/st"
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_CALLER=delegator CI_LOCAL_TICKET=TASK-9 \
  bash "$script" --post "$sha") 2>&1 ); rc=$?
id=$(cat "$out_dir/run-id")
check "12 request, start, verdict and end are recorded" $(jq -se --arg id "$id" --arg sha "$sha" '
  (map(.ev) | index("request") < index("start") and index("start") < index("end"))
  and all(.[]; .v == 1 and .sha == $sha and .caller == "delegator" and .ticket == "TASK-9" and (.t | type) == "number")
  and (map(select(.ev == "start" or .ev == "end" or .ev == "verdict") | .run) | unique == [$id])
  and any(.[]; .ev == "verdict" and .job == "quick" and .state == "success" and (.description | startswith("success in ")))
  and any(.[]; .ev == "end" and .rc == 0 and .aborted == false and .jobs.quick.res == "success")' "$ledger" > /dev/null; echo $?)
good_gh=$(sed -E 's/[0-9]+s on/Ns on/; s/(since|pid) [0-9:@A-Za-z.-]+/\1 X/g; s/#[0-9]+/#N/' "$root/gh.log"); good_rc=$rc
mkdir -p "$root/noledger"
: > "$root/gh.log"; rm -rf "$root/st"
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LEDGER="$root/noledger" \
  bash "$script" --post "$sha") 2>&1 ); rc=$?
check "12 an unwritable ledger changes no status and no exit code" $([ "$rc" = "$good_rc" ] && grep -q "ci-ledger: could not append" <<<"$out" \
  && [ "$(sed -E 's/[0-9]+s on/Ns on/; s/(since|pid) [0-9:@A-Za-z.-]+/\1 X/g; s/#[0-9]+/#N/' "$root/gh.log")" = "$good_gh" ]; echo $?)

# 13. Run or reuse (CI plan C12): the base's planner (ci-plan.sh --self-from) plans each job. A ran status carries
# fp=<fp10> and the ledger verdict the fields a later plan reads; shadow (the default) runs a job it would reuse and logs
# a decision; CI_REUSE=live posts `reused from` (the latest green source: the shadow twin) and runs nothing; --all and
# the kill switch reuse nothing.
setup_planner
echo b > "$root/repo/b.txt"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "b"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
: > "$marks/order"; : > "$ledger"
run --post "$sha"
fp=$(sed -nE 's/^quick run fp=([0-9a-f]{64})$/\1/p' "$out_dir/plan.txt")
check "13 the base's planner plans the job" $([ "$rc" -eq 0 ] && [ -n "$fp" ] && head -n 1 "$out_dir/plan.txt" | grep -q "^# ci-plan sha=$sha .* from=$p_base"; echo $?)
check "13 a ran status carries fp=<fp10>" $(grep -qE "state=success -f context=local-ci/quick -f description=success in [0-9]+s on [^ ;]+; fp=${fp:0:10}\$" "$root/gh.log"; echo $?)
runner=$(head -n 1 "$out_dir/plan.txt" | sed -nE 's/.* runner=([^ ]+).*/\1/p')
check "13 the verdict carries status, the full fp, the plan's runner class and narrowed" $([ -n "$runner" ] && jq -se --arg fp "$fp" --arg r "$runner" 'any(.[]; .ev == "verdict"
  and .job == "quick" and .state == "success" and .fp == $fp and .scope == $b and .runner == $r and .narrowed == false and .decision == "ran")' --arg b "$(git -C "$root/repo" rev-parse --short=7 "$p_base:.claude/scripts/ci-plan.sh")" "$ledger" > /dev/null; echo $?)
twin=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin)
run --post "$twin"
check "13 shadow (default): the job runs" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 2 ]; echo $?)
check "13 shadow logs a decision would reuse, naming the source" $(jq -se --arg s "$sha" --arg t "$twin" 'any(.[]; .ev == "decision" and .sha == $t
  and .job == "quick" and .decision == "would reuse" and .source == $s and .taken == "run")' "$ledger" > /dev/null; echo $?)
twin2=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin2)
CI_REUSE=live run --post "$twin2"
blob=$(git -C "$root/repo" rev-parse "$p_base:.claude/scripts/ci-plan.sh")
check "13 live: the job runs nothing" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 2 ]; echo $?)
check "13 live: it posts reused from <sha12>; fp; scope=<planner blob7>" \
  $(grep -qE "state=success -f context=local-ci/quick -f description=reused from (${sha:0:12}|${twin:0:12}); fp=${fp:0:10}; scope=${blob:0:7}\$" "$root/gh.log" \
  && ! grep -q 'context=local-ci/quick -f description=running since' "$root/gh.log"; echo $?)
check "13 live: a reuse event, never a source" $(jq -se --arg s "$sha" --arg w "$twin" --arg t "$twin2" --arg fp "$fp" 'any(.[]; .ev == "reuse" and .sha == $t
  and .job == "quick" and (.source == $s or .source == $w) and .decision == "reused" and .fp == $fp and .scope == $b and .state == "success")' --arg b "${blob:0:7}" "$ledger" > /dev/null; echo $?)
twin3=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin3)
CI_REUSE=live run --post --all "$twin3"
check "13 --all reuses nothing" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 3 ]; echo $?)
check "13 --all: the ran status still carries fp=" $(grep -qE "state=success -f context=local-ci/quick -f description=success in [0-9]+s on [^ ;]+; fp=${fp:0:10}\$" "$root/gh.log"; echo $?)
touch "$root/out/scope-all"
twin4=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin4)
CI_REUSE=live run --jobs quick "$twin4"
check "13 the scope-all kill switch reuses nothing" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 4 ]; echo $?)
rm -f "$root/out/scope-all"
nobase=$(git -C "$root/repo" commit-tree "$sha^{tree}" -m orphan)
run --jobs quick "$nobase"
check "13 no base for the planner: the job runs, without an fp" $([ "$rc" -eq 0 ] && [ ! -s "$root/out/${nobase:0:7}/plan.txt" ] \
  && read -r _ f _ < "$root/out/${nobase:0:7}/quick.plan" && [ -z "$f" ]; echo $?)

# 14. --rerun-failed (D4): on the same commit and tested tree, the latest run's green jobs are kept (posted again, a
# kept event, not run) and only the red ones run.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  steady:
    runs-on: ubuntu-latest
    steps:
      - run: echo steady >> $marks/rerun
  flaky:
    runs-on: ubuntu-latest
    steps:
      - run: echo flaky >> $marks/rerun && test -e $marks/flaky.ok
YML
git -C "$root/repo" commit -qam "rerun jobs"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
: > "$marks/rerun"; rm -f "$marks/flaky.ok"
run --post "$sha"
first_status=$(grep 'state=success -f context=local-ci/steady' "$root/gh.log" | sed 's/.*description=//')
touch "$marks/flaky.ok"
run --post --rerun-failed "$sha"
check "14 the red job runs again and passes" $([ "$rc" -eq 0 ] && [ "$(grep -c flaky "$marks/rerun")" -eq 2 ]; echo $?)
check "14 the green job is kept, not run" $([ "$(grep -c steady "$marks/rerun")" -eq 1 ] && grep -qE '^steady +success .*\(kept from run' "$out_dir/summary.txt"; echo $?)
check "14 its earlier status is posted again" $([ -n "$first_status" ] && grep -qF "state=success -f context=local-ci/steady -f description=$first_status" "$root/gh.log" \
  && ! grep -q 'context=local-ci/steady -f description=running since' "$root/gh.log"; echo $?)
check "14 a kept event names the run" $(tail -n 30 "$ledger" | jq -se --arg s "$sha" 'any(.[]; .ev == "kept" and .sha == $s and .job == "steady"
  and (.from | endswith(".r1")))' > /dev/null; echo $?)
rm -f "$marks/flaky.ok"; run "$sha"; touch "$marks/flaky.ok"
CI_LOCAL_RERUN_AFTER=gradle-oom run --post --rerun-failed "$sha"
check "14 CI_LOCAL_RERUN_AFTER: the job green on rerun names the signature" $([ "$rc" -eq 0 ] \
  && grep -qE "state=success -f context=local-ci/flaky -f description=success in [0-9]+s on [^ ;]+; green on rerun after gradle-oom\$" "$root/gh.log" \
  && tail -n 10 "$ledger" | jq -se 'any(.[]; .ev == "verdict" and .job == "flaky" and .rerun_after == "gradle-oom")' > /dev/null; echo $?)
check "14 a kept job does not claim a rerun" $(! grep -q 'context=local-ci/steady -f description=.*green on rerun' "$root/gh.log"; echo $?)
echo other > "$out_dir/tree"; n_steady=$(grep -c steady "$marks/rerun")
run --rerun-failed "$sha"
check "14 another tested tree keeps nothing" $([ "$(grep -c steady "$marks/rerun")" -eq $((n_steady + 1)) ]; echo $?)
run --rerun-failed --all "$sha"
check "14 --rerun-failed with --all is refused" $([ "$rc" -eq 2 ]; echo $?)

# 17. --audit: no reuse, and each step runs under ci-plan.sh --audit-run --record (a report per step).
git -C "$root/repo" checkout -q "$p_base" -- .github/workflows/ci.yml; git -C "$root/repo" commit -qam "quick again"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
CI_REUSE=live run --audit --jobs quick "$sha"
check "17 the planner plans with --audit" $([ "$rc" -eq 0 ] && grep -q 'quick run fp=' "$out_dir/plan.txt" && grep -q 'audit never reuses' "$out_dir/plan.log"; echo $?)
check "17 the worktree's git index is settled before the steps" $(grep -q -- '--audit: settled the worktree.s git index' "$out_dir/quick.log"; echo $?)
check "17 the step runs under --audit-run" $(grep -qE '^audit quick: [0-9]+ tracked files read|strace not found|already traced' "$out_dir/quick.log"; echo $?)

# 20. A plain --post call on a commit whose local CI is already running exits 0 at once and names the run and its folder
# (TASK-68); --force runs anyway, queued behind the live run, never attached; --force without --post is a usage error.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  quick:
    runs-on: ubuntu-latest
    steps:
      - name: Quick
        run: sleep \${SLEEP:-0} && git rev-parse --short HEAD >> $marks/order
YML
echo live > "$root/repo/t68-live"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "t68 live"
c=$(git -C "$root/repo" rev-parse HEAD)
: > "$marks/order"; rm -f "$root"/live1.rc "$root"/forced.rc; : > "$root/gh.log"
bg live1 SLEEP=5 -- --post "$c"
waitfor 'grep -q "description=running since" "$root/gh.log"'
run --post "$c"
check "20 a live pending commit is not run again and the call does not wait" $([ "$rc" -eq 0 ] && [ ! -e "$root/live1.rc" ] \
  && grep -qE "is pending, its run alive: #[0-9]+ (queued|running), pid [0-9]+; not run again; its folder is $root/out/${c:0:7} \(--force runs it anyway\)" <<<"$out"; echo $?)
check "20 the call that ran nothing records an attach with exit 0 in the ledger" $(jq -se --arg c "$c" \
  'any(.[]; .ev == "attach" and .sha == $c and .rc == 0)' "$ledger" > /dev/null; echo $?)
bg forced -- --post --force "$c"
waitfor '[ -e "$root/live1.rc" ] && [ -e "$root/forced.rc" ]'
check "20 --force runs anyway on a live commit, queued behind it" $([ "$(cat "$root/forced.rc")" = 0 ] \
  && ! grep -q "not run again" "$root/forced.out" && [ "$(grep -c "^${c:0:7}\$" "$marks/order")" -eq 2 ] \
  && [ "$(wc -l < "$marks/order")" -eq 2 ] && [ -s "$root/out/${c:0:7}.r1/summary.txt" ] \
  && grep -q "waiting for" "$root/forced.out"; echo $?)
run --force "$sha"
check "20 --force needs --post" $([ "$rc" -eq 2 ] && grep -q -- "--force applies to --post only" <<<"$out"; echo $?)

# 20 (TASK-68, continued). A plain --post call on a finished commit (green or red) runs nothing and exits 0; a pending
# commit whose run is gone (dead pid, or no queue entry) runs again; --force, --all and --rerun-failed run regardless.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  quick:
    runs-on: ubuntu-latest
    steps:
      - name: Quick
        run: sleep \${SLEEP:-0} && git rev-parse --short HEAD >> $marks/order
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: Fails
        run: exit 3
YML
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "t68 jobs"
t68_commit() { # t68_commit <name>: a new commit; sets C
  echo "$1" > "$root/repo/t68-$1"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "t68 $1"
  C=$(git -C "$root/repo" rev-parse HEAD)
}
t68_status() { # t68_status <sha> <state> <description>: that status on every job, as the gh stub stores it
  local j n
  mkdir -p "$root/st"
  for j in quick bad; do
    n=$(( $(cat "$root/st/.id" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$root/st/.id"
    jq -nc --arg s "$2" --arg c "local-ci/$j" --arg d "$3" --argjson id "$n" --arg t "$(date -u +%FT%TZ)" \
      '{state: $s, context: $c, description: $d, id: $id, updated_at: $t}' >> "$root/st/$1"
  done
}
requests() { jq -s --arg c "$1" '[.[] | select(.ev == "request" and .sha == $c)] | length' "$ledger"; }
finished_msg() { grep -qE "ci-local: ${1:0:7} is finished: $2 .*; not run again; its folder is $root/out/${1:0:7} \(--force runs it anyway\)" <<<"$out"; }

t68_commit finished; c1=$C
run --post "$c1"
req_before=$(requests "$c1")
run --post "$c1"
check "20 a finished commit is not run again (red, exit 0)" $([ "$rc" -eq 0 ] && finished_msg "$c1" red \
  && ! grep -q 'state=pending' "$root/gh.log" && [ ! -e "$root/out/${c1:0:7}.r1" ] \
  && [ "$(requests "$c1")" -eq "$req_before" ]; echo $?)

t68_commit green; c2=$C
t68_status "$c2" success "success in 1s on $(hostname)"
run --post "$c2"
check "20 a green finished commit is not run again" $([ "$rc" -eq 0 ] && finished_msg "$c2" green \
  && ! grep -q 'description=running since' "$root/gh.log" && [ ! -e "$root/out/${c2:0:7}/summary.txt" ]; echo $?)

run --post --force "$c1"
check "20 --force runs a finished commit" $(grep -q 'description=running since' "$root/gh.log" \
  && [ -d "$root/out/${c1:0:7}.r1" ] && ! grep -q "not run again" <<<"$out"; echo $?)

run --post --all "$c1"
check "20 --post --all runs a finished commit" $(grep -q 'description=running since' "$root/gh.log" && ! grep -q "not run again" <<<"$out"; echo $?)

run --post --audit "$c1"
check "20 --post --audit runs a finished commit" $(grep -q 'description=running since' "$root/gh.log" && ! grep -q "not run again" <<<"$out"; echo $?)

t68_commit superseded; c5=$C
t68_status "$c5" error "superseded: PR #7 head is now abcdef1, not run"
run --post "$c5"
check "20 a superseded commit is run (a new --post starts a run on it)" $(grep -q 'description=running since' "$root/gh.log" \
  && ! grep -q "not run again" <<<"$out" && [ -s "$root/out/${c5:0:7}/summary.txt" ]; echo $?)

t68_commit dead; c3=$C
sleep 0.1 & dead=$!; wait "$dead"
t68_status "$c3" pending "running since 09:00, pid $dead@$(hostname)"
mkdir -p "$root/out/.queue" "$root/out/.running"
printf 'n=950\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=running\n' "$c3" "$dead" "$(hostname)" > "$root/out/.queue/950"
echo "$dead" > "$root/out/.running/pid"
run --post "$c3"
check "20 dead pending: its pid is gone, so it runs again" $(grep -q 'description=running since' "$root/gh.log" \
  && [ -s "$root/out/${c3:0:7}/summary.txt" ] && ! grep -q "not run again" <<<"$out" \
  && grep -qE "ci-local: ${c3:0:7} is pending, but its run is gone \(.*\); running it again" <<<"$out"; echo $?)

rm -rf "$root/out/.running"
t68_commit nolock; c4=$C
t68_status "$c4" pending "running since 09:00, pid $dead@$(hostname)"
run --post "$c4"
check "20 dead pending: no queue entry and no lock for that commit, so it runs again" $(grep -q 'description=running since' "$root/gh.log" \
  && [ -s "$root/out/${c4:0:7}/summary.txt" ] && ! grep -q "not run again" <<<"$out" \
  && grep -qE "ci-local: ${c4:0:7} is pending, but its run is gone \(.*\); running it again" <<<"$out"; echo $?)

echo "ci-local queue tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
