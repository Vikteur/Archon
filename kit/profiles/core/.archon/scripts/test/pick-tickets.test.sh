#!/usr/bin/env bash
# Tests for .archon/scripts/pick-tickets.js against fixture backlog lists (PICK_TODO_JSON, PICK_ACTIVE_JSON).
# Usage: bash .archon/scripts/test/pick-tickets.test.sh   (exit 0 = all pass)
set -uo pipefail
# The scripts' defaults, not the checkout's .archon/kit.yaml (an install's build_workflow differs).
export KIT_CONFIG=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/pick-tickets.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out="$root/out.json"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" 2>/dev/null; fi
}
run() { PICK_TODO_JSON="$root/todo.json" PICK_ACTIVE_JSON="$root/active.json" node "$script" "$@" > "$out" 2>"$root/err"; }
picked() { jq -r '[.picked[].id] | join(" ")' "$out"; }
reason() { jq -r --arg id "$1" '.skipped[] | select(.id == $id) | .reason' "$out"; }

t() { # t <id> <priority> <ordinal> <labels csv> <refs csv> [title]
  jq -n --arg id "$1" --arg p "$2" --argjson o "$3" --arg l "$4" --arg r "$5" --arg title "${6:-ticket $1}" \
    '{id: $id, title: $title, priority: (if $p == "" then null else $p end), ordinal: $o,
      labels: ($l | split(",") | map(select(. != ""))), references: ($r | split(",") | map(select(. != ""))), isReady: true}'
}
list() { jq -s '{version: 1, tasks: .}'; }   # the versioned shape; a bare array is read too

# A: three tickets on different components, by priority then ordinal; a path reference is not a component.
{ t TASK-3 low 1 "" "project"; t TASK-1 high 9 "technical" "docs/x.md:1-2,orders-backend"; t TASK-2 high 2 "" "shared-kernel"; } | list > "$root/todo.json"
echo '[]' > "$root/active.json"
run; rc=$?
check "A exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "A default 2, highest priority first, then ordinal" $([ "$(picked)" = "TASK-2 TASK-1" ]; echo $?)
check "A third waits" $([ "$(reason TASK-3)" = "enough runs picked" ]; echo $?)
check "A a path reference is not a component" $(jq -e '.picked[] | select(.id == "TASK-1") | .components == ["orders-backend"]' "$out" >/dev/null; echo $?)
run --max 3
check "A --max 3 picks three" $([ "$(picked)" = "TASK-2 TASK-1 TASK-3" ]; echo $?)

# B: a shared component, and one In Progress.
{ t TASK-1 high 1 "" "orders-backend"; t TASK-2 high 2 "" "orders-backend,project"; t TASK-3 high 3 "" "shared-kernel"; t TASK-4 high 4 "" "pdf-gateway"; } > "$root/l"
jq -s . "$root/l" > "$root/todo.json"   # a bare array
t TASK-9 high 1 "" "pdf-gateway" | jq -s . > "$root/active.json"
run --max 3
check "B bare array read" $([ -s "$out" ]; echo $?)
check "B shared component skipped" $([ "$(reason TASK-2)" = "component taken: orders-backend" ]; echo $?)
check "B In Progress component is busy" $([ "$(reason TASK-4)" = "component taken: pdf-gateway" ]; echo $?)
check "B the rest picked" $([ "$(picked)" = "TASK-1 TASK-3" ]; echo $?)
check "B busy listed" $(jq -e '.busy == ["pdf-gateway"]' "$out" >/dev/null; echo $?)

# C: epics and contract pushes are skipped; other stop labels are passed on.
{ t TASK-1 high 1 "epic,P0" "project"; t TASK-2 high 2 "P0" "project" "[P0] Epic: things"; t TASK-3 high 3 "stop-contract-push" "shared-kernel";
  t TASK-4 high 4 "stop-migration,technical" "orders-backend"; } | list > "$root/todo.json"
echo '[]' > "$root/active.json"
run
check "C epic by label" $([ "$(reason TASK-1)" = "an epic: build its tickets" ]; echo $?)
check "C epic by title" $([ "$(reason TASK-2)" = "an epic: build its tickets" ]; echo $?)
check "C contract push skipped" $([ "$(reason TASK-3)" = "changes the contract: build-feature does not push the contract" ]; echo $?)
check "C stop labels passed on" $(jq -e '.picked == [{"id":"TASK-4","title":"ticket TASK-4","components":["orders-backend"],"stop":["stop-migration"]}]' "$out" >/dev/null; echo $?)

# D: a ticket with no component runs only alone.
{ t TASK-1 high 1 "" ""; t TASK-2 high 2 "" "project"; } | list > "$root/todo.json"
run --max 3
check "D no component first: alone" $([ "$(picked)" = "TASK-1" ] && [ "$(reason TASK-2)" = "enough runs picked" ]; echo $?)
{ t TASK-1 high 1 "" "project"; t TASK-2 high 2 "" ""; t TASK-3 high 3 "" "shared-kernel"; } | list > "$root/todo.json"
run --max 3
check "D no component after a pick: skipped" $([ "$(reason TASK-2)" = "no component reference: runs only alone" ] && [ "$(picked)" = "TASK-1 TASK-3" ]; echo $?)

# F: an In Progress ticket that waits for a To Do ticket (a dependency on it) does not hold that ticket's components,
# and still holds them for every other ticket (TASK-63).
{ t TASK-2 high 1 "" "orders-backend"; t TASK-1 high 2 "" "orders-backend,matching"; t TASK-3 high 3 "" "shared-kernel"; } | list > "$root/todo.json"
{ t TASK-9 high 1 "" "orders-backend,matching" | jq '.dependencies = ["task-1"]'; t TASK-8 high 2 "" "pdf-gateway" | jq '.dependencies = ["TASK-77"]'; } | jq -s . > "$root/active.json"
run --max 3
check "F the ticket waited for is picked" $([ "$(picked)" = "TASK-1 TASK-3" ]; echo $?)
check "F the waiting ticket still holds its components for another" $([ "$(reason TASK-2)" = "component taken: orders-backend" ]; echo $?)
check "F busy still lists the waiting ticket's components" $(jq -e '.busy | index("matching") != null' "$out" >/dev/null; echo $?)
t TASK-4 high 4 "" "pdf-gateway" | list > "$root/todo.json"
run
check "F a dependency on no To Do ticket keeps the components busy" $([ "$(reason TASK-4)" = "component taken: pdf-gateway" ]; echo $?)

# G: without fixtures the dependencies come from `backlog task view <id> --json`, which the list leaves out; a view
# that fails fails closed.
mkdir -p "$root/bin"
cat > "$root/bin/backlog" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "task list -s In Progress --json") echo '{"version":1,"tasks":[{"id":"TASK-9","title":"w","references":["orders-backend"]}]}' ;;
  "task view TASK-9 --json") [ -n "${VIEW_FAILS:-}" ] && exit 1; echo '{"version":1,"task":{"id":"TASK-9","dependencies":["TASK-1"]}}' ;;
  *) exit 3 ;;
esac
STUB
chmod +x "$root/bin/backlog"
{ t TASK-1 high 1 "" "orders-backend"; } | list > "$root/todo.json"
PATH="$root/bin:$PATH" PICK_TODO_JSON="$root/todo.json" node "$script" > "$out" 2>"$root/err"; rc=$?
check "G dependencies read with task view" $([ "$rc" -eq 0 ] && [ "$(picked)" = "TASK-1" ]; echo $?)
VIEW_FAILS=1 PATH="$root/bin:$PATH" PICK_TODO_JSON="$root/todo.json" node "$script" > "$out" 2>"$root/err"; rc=$?
check "G a failing task view exits 1" $([ "$rc" -eq 1 ]; echo $?)

# H: park (owner decision D10). A parked In Progress ticket holds no component; a parked To Do ticket is skipped.
{ t TASK-1 high 1 "" "identity"; t TASK-2 high 2 "parked" "project"; t TASK-3 high 3 "" "project"; } | list > "$root/todo.json"
{ t TASK-9 high 1 "parked" "identity" | jq '.dependencies = []'; } | jq -s . > "$root/active.json"
run --max 3
check "H a parked In Progress ticket frees its component" $([ "$(picked)" = "TASK-1 TASK-3" ]; echo $?)
check "H a parked To Do ticket is skipped" $([ "$(reason TASK-2)" = "parked" ]; echo $?)
check "H busy leaves the parked ticket out" $(jq -e '.busy == []' "$out" >/dev/null; echo $?)

# J: the night list and night mode (owner decision D11).
{ t TASK-1 high 5 "" "a"; t TASK-2 high 2 "" "b"; t TASK-3 high 1 "" "c"; t TASK-4 high 3 "P4" "d"; t TASK-5 high 4 "manual" "e";
  t TASK-6 high 6 "stop-auth-access" "f"; t TASK-7 high 7 "stop-auth-access,stop-crypto-logging" "g"; } | list > "$root/todo.json"
t TASK-9 high 1 "" "z" | jq '.dependencies = []' | jq -s . > "$root/active.json"
printf '# tonight\nTASK-1\n\ntask-2   # lower case and a comment\nTASK-4\nTASK-5\nTASK-6\nTASK-7\nTASK-9\nTASK-77\n' > "$root/night.txt"
mkdir -p "$root/appr"
nightrun() { PICK_APPROVALS_DIR="$root/appr" PICK_NOW=2026-10-20T23:00:00Z run "$@"; }
nightrun --max 3 --list "$root/night.txt"; rc=$?
check "J1 --list picks only listed tickets, in ordinal order" $([ "$rc" -eq 0 ] && [ "$(picked)" = "TASK-2 TASK-1" ]; echo $?)
check "J1 an unlisted ticket is not considered" $([ -z "$(reason TASK-3)" ]; echo $?)
check "J2 P4 skipped in night mode" $([ "$(reason TASK-4)" = "P4: not for an unattended night" ]; echo $?)
check "J2 manual skipped in night mode" $([ "$(reason TASK-5)" = "manual: needs a person" ]; echo $?)
check "J3 an unapproved stop label skipped" $([ "$(reason TASK-6)" = "stop-unapproved: stop-auth-access has no current owner approval" ]; echo $?)
check "J3 each skip printed to stderr" $(grep -qF "skipped TASK-6: stop-unapproved" "$root/err" && grep -qF "skipped TASK-4: P4" "$root/err"; echo $?)
check "J5 an In Progress id is skipped with its reason" $([ "$(reason TASK-9)" = "In Progress" ]; echo $?)
check "J5 an unknown id is skipped, the rest still picked" $(reason TASK-77 | grep -q '^not ready: a dependency'; echo $?)
check "J night flag in the output" $(jq -e '.night == true' "$out" >/dev/null; echo $?)
run --max 3
check "J without a list or --night nothing extra is skipped" $([ "$(picked)" = "TASK-3 TASK-2 TASK-4" ] && jq -e '.night == false' "$out" >/dev/null; echo $?)
nightrun --max 3 --night
check "J --night alone applies the skips to every ticket" $([ "$(picked)" = "TASK-3 TASK-2 TASK-1" ] && [ "$(reason TASK-5)" = "manual: needs a person" ]; echo $?)

# J4: approvals, judged by stop-lib.js against the real policy file. A signed, current entry covers exactly its ticket
# and category; an expired, revoked (file or entry), over 7 days, edited (digest), not the owner's or bad JSON file covers
# nothing; a standing rule covers its category; a never-coverable category and no policy are never approved.
lib="$here/stop-lib.js"
export PICK_POLICY_FILE="$here/../stop/policy.json"
owner_name=$(jq -r .owner "$PICK_POLICY_FILE")
# sign <out> <granted> <expires> <entries json>: writes an approvals file with a correct digest per entry.
sign() {
  node -e '
    const lib = require(process.argv[1]); const [, , out, g, x, owner, entries] = process.argv;
    const f = { schema: 1, id: "2026-10-20-2130", granted_at: g, expires_at: x, revoked_at: null, signed_by: owner,
      entries: JSON.parse(entries).map((e, i) => ({ n: i + 1, detail: "approved in the round", revoked_at: null, ...e })) };
    f.entries.forEach(e => { e.digest = lib.digest(f, e); });
    require("fs").writeFileSync(out, JSON.stringify(f));' "$lib" "$1" "$2" "$3" "$owner_name" "$4"
}
edit() { jq "$1" "$root/appr/a.json" > "$root/appr/b" && mv "$root/appr/b" "$root/appr/a.json"; }
sign "$root/appr/a.json" 2026-10-20T19:30:00.000Z 2026-10-21T15:30:00.000Z '[{"ticket":"TASK-6","category":"auth-access"},{"ticket":"TASK-7","category":"auth-access"}]'
echo '{"schema":1,"note":"a template grants nothing"}' > "$root/appr/_template.json"
nightrun --max 3 --list "$root/night.txt"
check "J4 an approved stop item is picked" $([ "$(picked)" = "TASK-2 TASK-1 TASK-6" ]; echo $?)
check "J4 a second, unapproved category still skips" $([ "$(reason TASK-7)" = "stop-unapproved: stop-crypto-logging has no current owner approval" ]; echo $?)
check "J4 the picked ticket still names its stop labels" $(jq -e '.picked[] | select(.id == "TASK-6") | .stop == ["stop-auth-access"]' "$out" >/dev/null; echo $?)
PICK_APPROVALS_DIR="$root/appr" PICK_NOW=2026-10-21T15:30:01Z run --max 3 --list "$root/night.txt"
check "J4 an expired file covers nothing" $(reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
cp "$root/appr/a.json" "$root/a.good"
edit '.revoked_at = "2026-10-20T22:00:00Z"'; nightrun --max 3 --list "$root/night.txt"
check "J4 a revoked file covers nothing" $(reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
cp "$root/a.good" "$root/appr/a.json"; edit '.entries[0].revoked_at = "2026-10-20T22:00:00Z"'; nightrun --max 3 --list "$root/night.txt"
check "J4 a revoked entry covers nothing" $(reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
cp "$root/a.good" "$root/appr/a.json"; edit '.entries[0].ticket = "TASK-1" | .entries[1].ticket = "TASK-6"'; nightrun --max 3 --list "$root/night.txt"
check "J4 an entry edited after signing (digest) covers nothing" $(reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
cp "$root/a.good" "$root/appr/a.json"; edit '.signed_by = "someone else"'; nightrun --max 3 --list "$root/night.txt"
check "J4 a file not signed by the owner covers nothing" $(reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
sign "$root/appr/a.json" 2026-10-13T19:00:00.000Z 2026-10-21T15:30:00.000Z '[{"ticket":"TASK-6","category":"auth-access"}]'
nightrun --max 3 --list "$root/night.txt"
check "J4 a file granted over 7 days before its expiry covers nothing" $(reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
echo '{not json' > "$root/appr/a.json"
nightrun --max 3 --list "$root/night.txt"; rc=$?
check "J4 a bad approvals file covers nothing and fails nothing" $([ "$rc" -eq 0 ] && reason TASK-6 | grep -q '^stop-unapproved'; echo $?)
# Standing rules and never-coverable categories, with no approvals file at all.
rm -f "$root/appr/a.json"
cp "$root/todo.json" "$root/todo.keep"
{ t TASK-1 high 1 "stop-db-migration" "a"; t TASK-2 high 2 "stop-secret-value" "b"; t TASK-3 high 3 "stop-made-up" "c"; } | list > "$root/todo.json"
nightrun --max 3 --night
check "J4 a standing rule (no production db) covers stop-db-migration" $(jq -e '[.picked[].id] == ["TASK-1"]' "$out" >/dev/null; echo $?)
check "J4 a never-coverable category is never approved" $(reason TASK-2 | grep -q '^stop-unapproved: stop-secret-value'; echo $?)
check "J4 an unknown stop label is never approved" $(reason TASK-3 | grep -q '^stop-unapproved: stop-made-up'; echo $?)
PICK_POLICY_FILE="$root/nosuch.json" nightrun --max 3 --night; rc=$?
check "J4 no policy: every stop label is unapproved, nothing fails" $([ "$rc" -eq 0 ] && reason TASK-1 | grep -q '^stop-unapproved'; echo $?)
mv "$root/todo.keep" "$root/todo.json"
unset PICK_POLICY_FILE

# J6: a bad list.
nightrun --list "$root/nosuch.txt"; rc=$?
check "J6 an unreadable list exits 2" $([ "$rc" -eq 2 ] && grep -q 'cannot read the list' "$root/err"; echo $?)
printf 'TASK-1\nnonsense\n' > "$root/bad.txt"
nightrun --list "$root/bad.txt"; rc=$?
check "J6 a line that is no ticket id exits 2" $([ "$rc" -eq 2 ] && grep -q 'nonsense' "$root/err"; echo $?)
run --list; rc=$?
check "J6 --list without a file exits 2" $([ "$rc" -eq 2 ]; echo $?)

# K-M: --cap (owner decision D1): a run past `merged` frees its slot and its ticket's components; the ceiling of 4 holds.
# r <run id> <task> <status> <merged node state>: an archon run of build-feature.
r() { jq -n --arg id "$1" --arg task "$2" --arg s "$3" --arg m "$4" \
  '{id: $id, workflow_name: "build-feature", status: $s, user_message: "Build \($task)",
    nodes: [{nodeId: "ticket", state: "completed", outputPreview: ({task: $task, stop: ""} | tojson)}, {nodeId: "merged", state: $m}]}'; }
runs() { jq -s '{runs: .}' > "$root/runs.json"; }
caprun() { PICK_RUNS_JSON="$root/runs.json" run "$@"; }
{ t TASK-1 high 1 "" "identity"; t TASK-2 high 2 "" "project"; t TASK-3 high 3 "" "matching"; } | list > "$root/todo.json"
{ t TASK-8 high 1 "" "identity" | jq '.dependencies = []'; t TASK-9 high 2 "" "pdf-gateway" | jq '.dependencies = []'; } | jq -s . > "$root/active.json"
{ r run-8 TASK-8 running completed; r run-9 TASK-9 running running; } | runs
caprun --cap 2; rc=$?
check "K exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "K a run past merged frees its slot: room 1" $(jq -e '.room == 1 and .cap == 2 and .ceiling == 4' "$out" >/dev/null; echo $?)
check "K and its ticket's components" $([ "$(picked)" = "TASK-1" ]; echo $?)
check "K the phases are listed" $(jq -e '.runs == [{"run":"run-8","task":"TASK-8","phase":"post-merge"},{"run":"run-9","task":"TASK-9","phase":"pre-merge"}]' "$out" >/dev/null; echo $?)
check "K busy keeps the pre-merge ticket only" $(jq -e '.busy == ["pdf-gateway"]' "$out" >/dev/null; echo $?)
{ r run-8 TASK-8 failed completed; r run-9 TASK-9 running running; } | runs
caprun --cap 2
check "L a failed post-merge run makes its ticket busy again" $([ "$(reason TASK-1)" = "component taken: identity" ] && jq -e '.room == 1' "$out" >/dev/null; echo $?)
{ r run-8 TASK-8 running completed; r run-9 TASK-9 paused running; } | runs
caprun --cap 2
check "L a paused run still holds its slot" $(jq -e '.room == 1' "$out" >/dev/null; echo $?)
{ t TASK-8 high 1 "parked" "identity" | jq '.dependencies = []'; t TASK-9 high 2 "" "pdf-gateway" | jq '.dependencies = []'; } | jq -s . > "$root/active.json"
{ r run-8 TASK-8 running running; r run-9 TASK-9 running running; } | runs
caprun --cap 2
check "K a parked run takes no slot" $(jq -e '.room == 1 and (.runs[0].phase == "parked")' "$out" >/dev/null && [ "$(picked)" = "TASK-1" ]; echo $?)
{ t TASK-5 high 1 "" "a" | jq '.dependencies = []'; t TASK-6 high 1 "" "b" | jq '.dependencies = []'; t TASK-7 high 1 "" "c" | jq '.dependencies = []'; } | jq -s . > "$root/active.json"
{ r run-5 TASK-5 running completed; r run-6 TASK-6 running completed; r run-7 TASK-7 running completed; } | runs
caprun --cap 2
check "M three tail runs: the ceiling leaves room 1" $(jq -e '.room == 1' "$out" >/dev/null && [ "$(picked)" = "TASK-1" ]; echo $?)
{ r run-5 TASK-5 running completed; r run-6 TASK-6 running completed; r run-7 TASK-7 running completed; r run-4 TASK-4 running completed; } | runs
caprun --cap 3
check "M four live runs: the ceiling of 4 holds" $(jq -e '.room == 0' "$out" >/dev/null && [ "$(picked)" = "" ] && [ "$(reason TASK-1)" = "enough runs picked" ]; echo $?)
{ r run-5 TASK-5 running running; r run-6 TASK-6 running running; } | runs
caprun --cap 2
check "M two runs before their merge: no room" $(jq -e '.room == 0' "$out" >/dev/null && [ "$(picked)" = "" ]; echo $?)
jq -n '{runs: [{id: "x", workflow_name: "build-feature", status: "running", user_message: "Build TASK-5", nodes: []},
  {id: "y", workflow_name: "other", status: "running", nodes: []}]}' > "$root/runs.json"
caprun --cap 2
check "M the ticket falls back to the user message; other workflows do not count" $(jq -e '.runs == [{"run":"x","task":"TASK-5","phase":"pre-merge"}] and .room == 1' "$out" >/dev/null; echo $?)
echo 'oops' > "$root/runs.json"
caprun --cap 2; rc=$?
check "M an unreadable archon read exits 1" $([ "$rc" -eq 1 ] && grep -q 'cannot read the archon runs' "$root/err" && [ ! -s "$out" ]; echo $?)
caprun --cap 2 --max 2; rc=$?
check "M --cap with --max exits 2" $([ "$rc" -eq 2 ]; echo $?)
for m in 0 4; do caprun --cap "$m"; rc=$?; check "M --cap $m refused" $([ "$rc" -eq 2 ]; echo $?); done

# E: fails closed and refuses a bad --max.
echo 'not json' > "$root/todo.json"
run; rc=$?
check "E unreadable backlog: exit 1" $([ "$rc" -eq 1 ] && grep -q 'cannot read the backlog' "$root/err"; echo $?)
echo '{"version":1}' > "$root/todo.json"
run; rc=$?
check "E no task list: exit 1" $([ "$rc" -eq 1 ]; echo $?)
echo '[]' > "$root/todo.json"
for m in 0 4 x; do run --max "$m"; rc=$?; check "E --max $m refused" $([ "$rc" -eq 2 ]; echo $?); done
run --bogus; rc=$?
check "E unknown argument" $([ "$rc" -eq 2 ]; echo $?)
run; rc=$?
check "E nothing ready: empty pick" $([ "$rc" -eq 0 ] && [ "$(picked)" = "" ]; echo $?)

echo "pick-tickets: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
