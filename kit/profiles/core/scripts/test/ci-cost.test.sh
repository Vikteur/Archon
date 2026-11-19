#!/usr/bin/env bash
# Tests .claude/scripts/ci-cost.sh (CI plan C20): the cost report from the CI ledger, per day and per ticket, with the
# reuse share, the avoidable classes (same tree, rebase-only, bookkeeping-only, red tail; each run credited once) and the
# Gradle growth guard. Each case writes a small ledger by hand and reads it against a throwaway repo; nothing reads
# GitHub or the real ledger.
# Usage: bash scripts/test/ci-cost.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-cost.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
out=""; rc=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset CI_LEDGER CI_COST_GROWTH CI_COST_GUARD_MIN CI_COST_GRADLE_JOBS

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }
is() { [ "$(jq -c "$1" <<< "$out")" = "$2" ]; }   # is <jq path> <compact JSON>

# The repo: main with a base commit; a feature commit; the same tree under another sha; the same patch on a later
# main (a rebase); a bookkeeping-only commit; a code commit for the red run.
repo="$tmp/repo"
git init -q -b main "$repo" && cd "$repo" || exit 1
echo a > app.txt && mkdir -p backlog docs/retro && echo t > backlog/t.md && git add -A && git commit -qm base
base1=$(git rev-parse HEAD)
git checkout -q -b feat && echo b > app.txt && git commit -qam feature
feat=$(git rev-parse HEAD)
git commit -q --amend -m "feature, reworded"
same_tree=$(git rev-parse HEAD)
git checkout -q main && echo other > other.txt && git add -A && git commit -qm main-moves
base2=$(git rev-parse HEAD)
git checkout -q -b feat2 && git cherry-pick "$feat" > /dev/null
rebased=$(git rev-parse HEAD)
git checkout -q main && git checkout -q -b books && echo u > backlog/t.md && echo r > docs/retro/r.md && git add -A \
  && git commit -qm books
books=$(git rev-parse HEAD)
git checkout -q main && git checkout -q -b red && echo c > app.txt && git commit -qam red
red=$(git rev-parse HEAD)
cd "$tmp" || exit 1

day=86400
d1=$((20000 * day))            # 2024-10-04
d2=$((d1 + day))
L="$tmp/ledger.jsonl"
# run <sha> <run> <base> <pr> <ticket> <t_lock> <t_end> <rc> [<jobs json>]: a start and an end line.
run_lines() {
  local jobs=${9:-'{}'}
  printf '{"v":1,"ev":"start","t":%s,"sha":"%s","run":"%s","pr":%s,"ticket":%s,"base":"%s","t_lock":%s,"t_start":%s}\n' \
    "$6" "$1" "$2" "$4" "$5" "$3" "$6" "$6"
  printf '{"v":1,"ev":"end","t":%s,"sha":"%s","run":"%s","pr":%s,"ticket":%s,"rc":%s,"aborted":false,"t_req":%s,"t_lock":%s,"t_start":%s,"t_end":%s,"jobs":%s}\n' \
    "$7" "$1" "$2" "$4" "$5" "$8" "$6" "$6" "$6" "$7" "$jobs"
}
verdict() { # verdict <sha> <run> <t> <job> <state> <description>
  printf '{"v":1,"ev":"verdict","t":%s,"sha":"%s","run":"%s","job":"%s","state":"%s","description":"%s"}\n' "$3" "$1" "$2" "$4" "$5" "$6"
}
{
  # Day 1, TASK-1: a green feature run (10 min), the same tree again under another sha (5 min: same-tree), and the same
  # patch rebased onto a later main in the same PR (6 min: rebase-only).
  run_lines "$feat" f.r1 "$base1" 7 '"TASK-1"' "$d1" $((d1 + 600)) 0
  verdict "$feat" f.r1 $((d1 + 500)) test success "success in 480s on h"
  verdict "$feat" f.r1 $((d1 + 590)) groma success "reused from 0123456789ab; fp=abc; scope=def"
  run_lines "$same_tree" s.r1 "$base1" 7 '"TASK-1"' $((d1 + 1000)) $((d1 + 1300)) 0
  # Since reuse went live a reused job writes a reuse or same-tree line, not a verdict.
  printf '{"v":1,"ev":"reuse","t":%s,"sha":"%s","run":"s.r1","job":"test","state":"success","description":"reused from 0123456789ab; fp=abc; scope=def"}\n' \
    $((d1 + 1001)) "$same_tree"
  printf '{"v":1,"ev":"same-tree","t":%s,"sha":"%s","run":"s.r1","job":"groma","state":"success","description":"reused from 0123456789ab; same tree"}\n' \
    $((d1 + 1002)) "$same_tree"
  run_lines "$rebased" b.r1 "$base2" 7 '"TASK-1"' $((d1 + 2000)) $((d1 + 2360)) 0
  printf '{"v":1,"ev":"decision","t":%s,"sha":"%s","run":"b.r1","job":"test","decision":"would reuse","source":"0123456789ab","fp":"fp","scope":"blob","taken":"run"}\n' \
    $((d1 + 2001)) "$rebased"
  # Day 2, no ticket: a bookkeeping-only run (3 min) and a red run whose first failure comes 2 of its 8 minutes in.
  run_lines "$books" k.r1 "$base2" 8 null "$d2" $((d2 + 180)) 0
  run_lines "$red" r.r1 "$base2" 9 '"TASK-2"' $((d2 + 1000)) $((d2 + 1480)) 1
  verdict "$red" r.r1 $((d2 + 1120)) test failure "failure in 100s on h"
  verdict "$red" r.r1 $((d2 + 1400)) image success "success in 200s on h"
  # A commit the repo does not have, green: its class is unknown.
  run_lines 0000000000000000000000000000000000000001 u.r1 "$base2" 9 '"TASK-2"' $((d2 + 2000)) $((d2 + 2060)) 0
  echo '{"v":1,"ev":"end","t":'
} > "$L"

run() { out="$(bash "$script" "$@" 2>&1)"; rc=$?; }

# 1. The report.
run --ledger "$L" --repo "$repo" --json
check "1 the JSON report builds" "$([ "$rc" -eq 0 ] && jq -e . <<< "$out" > /dev/null; echo $?)"
check "1 a torn line is skipped and counted" "$(is .skipped_lines 1; echo $?)"
check "1 runs and lock minutes in total" "$(is '[.total.runs, .total.lock_min]' '[6,33]'; echo $?)"
check "1 per day" "$(is '[.by_day["2024-10-04"].runs, .by_day["2024-10-04"].lock_min, .by_day["2024-10-05"].lock_min]' '[3,21,12]'; echo $?)"
check "1 per ticket, (none) without one" "$(is '[.by_ticket["TASK-1"].runs, .by_ticket["(none)"].runs, .by_ticket["TASK-2"].runs]' '[3,1,2]'; echo $?)"
check "1 the reuse share counts the reused verdicts, reuse and same-tree lines" "$(is '[.total.reused, .total.verdicts, .total.reuse_share]' '[3,6,50]'; echo $?)"
check "1 a reuse the planner would have taken in shadow mode" "$(is .total.shadow_reusable 1; echo $?)"
check "1 same-tree: the same tree on the same base after a green run" "$(is '.total.avoidable_min["same-tree"]' 5; echo $?)"
check "1 rebase-only: the same patch of the same PR on another base" "$(is '.total.avoidable_min["rebase-only"]' 6; echo $?)"
check "1 bookkeeping: a change to backlog/ and docs/retro/ only" "$(is '.total.avoidable_min.bookkeeping' 3; echo $?)"
check "1 red tail: the minutes after the first failure" "$(is '.total.avoidable_min["red-tail"]' 6; echo $?)"
check "1 each run is credited once" "$(is .total.avoidable_total_min 20; echo $?)"
check "1 a commit the repo lacks is unknown, not avoidable" "$(is .total.unknown_runs 1; echo $?)"
check "1 the first green run is not avoidable" "$(is '.by_ticket["TASK-1"].avoidable_total_min' 11; echo $?)"

run --ledger "$L" --repo "$repo"
check "1 the table names every class" "$([ "$rc" -eq 0 ] && said 'same-tree' && said 'rebase-only' && said 'bookkeeping' \
  && said 'red-tail' && grep -qE '^TASK-1 +3 +21 ' <<< "$out" && grep -qE '^2024-10-05 +3 +12 ' <<< "$out"; echo $?)"
# Without column(1) (Git Bash, slim images) the table lines up the same way: a PATH that holds every tool but column.
nocol="$tmp/nocol"; mkdir -p "$nocol"
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  for f in "$d"/*; do n=${f##*/}; [ "$n" = column ] || [ -e "$nocol/$n" ] || ln -s "$f" "$nocol/$n" 2> /dev/null; done
done
out=$(PATH="$nocol" bash "$script" --ledger "$L" --repo "$repo" 2>&1); rc=$?
check "1 ... and without column(1) installed" "$([ "$rc" -eq 0 ] && ! PATH="$nocol" command -v column > /dev/null \
  && said 'red-tail' && grep -qE '^TASK-1 +3 +21 ' <<< "$out" && grep -qE '^2024-10-05 +3 +12 ' <<< "$out"; echo $?)"
run --ledger "$L" --repo "$repo" --since 2024-10-05 --json
check "1 --since keeps the later days only" "$(is '[.total.runs, (.by_day | keys)]' '[3,["2024-10-05"]]'; echo $?)"
check "1 ... with the credits of those days" "$(is .total.avoidable_total_min 9; echo $?)"
run --ledger "$L" --repo "$tmp/none" --json
check "1 without the commits every git class is unknown" "$(is '[.total.avoidable_min["same-tree"], .total.avoidable_min["rebase-only"], .total.avoidable_min.bookkeeping, .total.avoidable_min["red-tail"]]' '[0,0,0,6]'; echo $?)"

# 2. The Gradle growth guard.
G="$tmp/guard.jsonl"
guard_ledger() { # guard_ledger <first secs> <last secs> [<n>]: n green test runs in the first and in the last week
  local n=${3:-5} i
  for i in $(seq 1 "$n"); do
    run_lines "$feat" "g.a$i" "$base1" 1 null $((d1 + i * 100)) $((d1 + i * 100 + 50)) 0 \
      "{\"test\":{\"res\":\"success\",\"own\":$1,\"kind\":\"ran\"},\"groma\":{\"res\":\"success\",\"own\":9999,\"kind\":\"ran\"}}"
    run_lines "$feat" "g.b$i" "$base1" 1 null $((d1 + 20 * day + i * 100)) $((d1 + 20 * day + i * 100 + 50)) 0 \
      "{\"test\":{\"res\":\"success\",\"own\":$2,\"kind\":\"ran\"}}"
  done
  # Neither a red nor an infra test job is a sample.
  run_lines "$feat" g.x "$base1" 1 null $((d1 + 20 * day + 900)) $((d1 + 20 * day + 950)) 1 \
    '{"test":{"res":"failure","own":99999,"kind":"ran"}}'
  run_lines "$feat" g.y "$base1" 1 null $((d1 + 20 * day + 990)) $((d1 + 20 * day + 999)) 1 \
    '{"test":{"res":"none","own":99999,"kind":"infra"}}'
}
guard_ledger 100 119 > "$G"; run --ledger "$G" --guard --json
check "2 +19% holds" "$([ "$rc" -eq 0 ] && is .guard.state '"holds"' && is '[.guard.first_median_s, .guard.last_median_s]' '[100,119]'; echo $?)"
guard_ledger 100 121 > "$G"; run --ledger "$G" --guard
check "2 +21% trips --guard" "$([ "$rc" -eq 1 ] && said 'gradle growth guard: tripped' && said 'FAIL: the Gradle jobs grew'; echo $?)"
run --ledger "$G"
check "2 without --guard it is reported, exit 0" "$([ "$rc" -eq 0 ] && said 'tripped'; echo $?)"
out="$(CI_COST_GROWTH=1.5 bash "$script" --ledger "$G" --guard 2>&1)"; rc=$?
check "2 CI_COST_GROWTH sets the limit" "$([ "$rc" -eq 0 ] && said 'holds'; echo $?)"
out="$(CI_COST_GRADLE_JOBS=groma bash "$script" --ledger "$G" --guard --json 2>&1)"; rc=$?
check "2 CI_COST_GRADLE_JOBS picks the jobs" "$([ "$rc" -eq 0 ] && is .guard.state '"too few samples"'; echo $?)"
guard_ledger 100 300 4 > "$G"; run --ledger "$G" --guard
check "2 too few samples never trips" "$([ "$rc" -eq 0 ] && said 'too few samples (4 and 4 of 5 needed'; echo $?)"
run --ledger "$L" --guard --json
check "2 no test samples at all" "$([ "$rc" -eq 0 ] && is .guard.state '"no samples"'; echo $?)"

# 3. Usage and edges.
run --ledger "$tmp/missing.jsonl"
check "3 no ledger yet is no error" "$([ "$rc" -eq 0 ] && said 'no ledger at'; echo $?)"
out="$(CI_LEDGER="$L" bash "$script" --repo "$repo" --json 2>&1)"; rc=$?
check "3 CI_LEDGER names the ledger" "$([ "$rc" -eq 0 ] && is .total.runs 6; echo $?)"
: > "$tmp/empty.jsonl"; run --ledger "$tmp/empty.jsonl" --json
check "3 an empty ledger reports zero" "$([ "$rc" -eq 0 ] && is .total.runs 0; echo $?)"
run --bogus
check "3 an unknown option is refused" "$([ "$rc" -eq 2 ]; echo $?)"
run --since yesterday
check "3 --since takes a date" "$([ "$rc" -eq 2 ]; echo $?)"
run --ledger
check "3 --ledger needs a file" "$([ "$rc" -eq 2 ]; echo $?)"
check "3 it never calls GitHub" "$(! grep -qE '(^|[^a-z])gh ' "$script"; echo $?)"

echo "ci-cost tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
