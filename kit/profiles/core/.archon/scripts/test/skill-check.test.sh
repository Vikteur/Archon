#!/usr/bin/env bash
# Tests for .archon/scripts/skill-check.js against fixture plans, audit trails, step markers and a run log under a
# throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/skill-check.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/skill-check.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
run=0123456789abcdef0123456789abcdef
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
mkdir -p "$logs"
art="$root/artifacts"
tree="$root/tree"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$art/skill-check.md" 2>/dev/null; fi
}
has() { grep -qF -- "$1" "$art/skill-check.md"; }
gate() { (cd "$tree" && node "$script" "$art" "$@" >/dev/null 2>&1); }
fresh() { rm -rf "$art" "$tree"; mkdir -p "$art" "$tree/.apm-audit/sessions"; }
load() { # load <utc time> <skill>
  echo "{\"type\":\"TOOL\",\"event\":\"postToolUse\",\"agent\":\"main\",\"loggedAt\":\"$1\",\"tool\":\"Skill\",\"arg\":\"{\\\"skill\\\":\\\"$2\\\"}\",\"ok\":true}" \
    >> "$tree/.apm-audit/sessions/s.jsonl"
}
mark() { # mark <utc time> <n> <phase>
  mkdir -p "$art/steps"
  printf '%s\t{"n":%s,"kind":"build","phase":"%s","feedback":""}\n' "$1" "$2" "$3" >> "$art/steps/next.log"
}
plan() {
  cat > "$art/plan.md" <<'EOF'
## Steps
- [x] (verify only) **Step 0 — bundle.**
  Test skills: jvm-testing
- [x] **Step 1 — the use case.**
  Test skills: `jvm-testing`, tdd-loop
  Build skills: hexagonal-usecase
- [x] (pin only) **Step 2 — pin the guard.**
  Test skills: jvm-testing
  Build skills: hexagonal-usecase
- [x] **Step 3 — docs.**
  Test skills: none
  Build skills:
EOF
}

# Step markers (agent-feature wrote them until D19) decide the window; checkbox 2 is plan Step 1.
fresh; plan
mark 2026-10-18T10:00:00Z 2 tests; load 2026-10-18T10:00:05Z jvm-testing; load 2026-10-18T10:00:06Z tdd-loop
mark 2026-10-18T10:05:00Z 2 code; load 2026-10-18T10:05:03Z hexagonal-usecase
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing
gate; check "markers: every skill loaded exits 0" $?
has "Every named skill was loaded."; check "markers: the report says so" $?
has "| step 2 | test | jvm-testing, tdd-loop | — |"; check "markers: step 2 test row" $?
! has "| step 3 | build |"; check "markers: a pin-only step needs no build skills" $?
! has "| step 1 |"; check "markers: a verify-only step needs nothing" $?
! has "| step 4 |"; check "markers: none and an empty line need nothing" $?
! has "| plan |"; check "markers: the plan is not checked (agent-feature preloads it)" $?

fresh; plan
mark 2026-10-18T10:00:00Z 2 tests; load 2026-10-18T10:00:05Z jvm-testing; load 2026-10-18T10:00:06Z tdd-loop
mark 2026-10-18T10:05:00Z 2 code
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing; load 2026-10-18T10:10:03Z hexagonal-usecase
gate; [ $? -eq 1 ]; check "markers: a load in another step's window does not count" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "markers: names the step, agent and skill" $?

fresh; plan
mark 2026-10-18T10:00:00Z 2 tests; load 2026-10-18T10:00:05Z jvm-testing
gate; [ $? -eq 1 ]; check "markers: a step without its window fails" $?
has "step 2: the test agent never loaded tdd-loop"; check "markers: a missing test skill is named" $?
has "step 2: no build agent window found"; check "markers: a missing window is named" $?

fresh; plan; rm -rf "$tree/.apm-audit"
gate; [ $? -eq 1 ]; check "no audit trail fails" $?
has "no audit trail"; check "no audit trail is named" $?

fresh; rm -f "$art/plan.md"
gate; [ $? -eq 1 ]; check "no plan fails" $?

fresh; plan
gate; [ $? -eq 1 ]; check "no markers and no run id fails" $?
has "no step markers"; check "no markers and no log is named" $?

# A BLOCKED: line ended the loop: the steps nobody built are named once, with the line, not as missing windows.
fresh; plan; echo 'BLOCKED: step 2: may the guard move to step 3?' >> "$art/plan.md"
mark 2026-10-18T10:00:00Z 2 tests; load 2026-10-18T10:00:05Z jvm-testing; load 2026-10-18T10:00:06Z tdd-loop
mark 2026-10-18T10:05:00Z 2 code
gate; [ $? -eq 1 ]; check "blocked: a blocked run fails" $?
has 'the run is blocked, so step(s) 3 were never built: BLOCKED: step 2: may the guard move to step 3?'
check "blocked: names the unbuilt steps and quotes the BLOCKED line" $?
! has "no test agent window found"; check "blocked: an unbuilt step is not reported as a missing window" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "blocked: a built step's missing skill is still named" $?

# A subagent's frontmatter `skills:` are preloaded at its start with no Skill call: its AGENT_START record counts as
# a load of each, inside the window it starts in.
agent_start() { # agent_start <utc time> <agent name>
  echo "{\"type\":\"AGENT_START\",\"event\":\"subagentStart\",\"agent\":\"$2\",\"loggedAt\":\"$1\",\"agentName\":\"$2\"}" \
    >> "$tree/.apm-audit/sessions/s.jsonl"
}
agent_file() { # agent_file <name> <frontmatter lines...>
  local name=$1; shift
  mkdir -p "$tree/.claude/agents"
  { echo '---'; echo "name: $name"; printf '%s\n' "$@"; echo '---'; echo 'skills: [in-the-body]'; } \
    > "$tree/.claude/agents/$name.md"
}
fresh; plan
agent_file test-writer 'tools:' '  - Skill' 'skills:' '  - tdd-loop' '  - "jvm-testing"' 'model: sonnet'
agent_file developer 'skills: [hexagonal-usecase]'
mark 2026-10-18T10:00:00Z 2 tests; agent_start 2026-10-18T10:00:04Z test-writer
mark 2026-10-18T10:05:00Z 2 code; agent_start 2026-10-18T10:05:01Z developer
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing
gate; check "preload: frontmatter preloads count as loads" $?
has "| step 2 | test | jvm-testing, tdd-loop | — |"; check "preload: a block-list preload counts" $?
has "| step 2 | build | hexagonal-usecase | — |"; check "preload: an inline-list preload counts" $?

fresh; plan
agent_file test-writer 'skills:' '  - tdd-loop'
mark 2026-10-18T10:00:00Z 2 tests; agent_start 2026-10-18T10:00:04Z test-writer; load 2026-10-18T10:00:05Z jvm-testing
mark 2026-10-18T10:05:00Z 2 code; agent_start 2026-10-18T10:05:01Z test-writer
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing
gate; [ $? -eq 1 ]; check "preload: a skill no started agent preloads is still missing" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "preload: the missing build skill is named" $?

fresh; plan
agent_file developer 'skills: [hexagonal-usecase]'
mark 2026-10-18T10:00:00Z 2 tests; agent_start 2026-10-18T10:00:04Z general-purpose; load 2026-10-18T10:00:05Z jvm-testing
mark 2026-10-18T10:05:00Z 2 code; load 2026-10-18T10:05:03Z clean-code
mark 2026-10-18T10:10:00Z 3 tests; agent_start 2026-10-18T10:10:05Z developer; load 2026-10-18T10:10:06Z jvm-testing
gate; [ $? -eq 1 ]; check "preload: an agent with no agent file preloads nothing" $?
has "step 2: the test agent never loaded tdd-loop"; check "preload: the unloaded test skill is named" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "preload: a preload in another step's window does not count" $?
! grep -q 'in-the-body' "$art/skill-check.md"; check "preload: only the frontmatter is read" $?

# The hook records each preload (SKILL_PRELOAD) at the agent's start: a session file with those records is read for
# them, not the frontmatter as it is now; one without falls back to the frontmatter.
preload() { # preload <utc time> <agent name> <skill> [found]
  echo "{\"type\":\"SKILL_PRELOAD\",\"event\":\"subagentStart\",\"agent\":\"$2\",\"loggedAt\":\"$1\",\"agentName\":\"$2\",\"skill\":\"$3\",\"found\":${4:-true}}" \
    >> "$tree/.apm-audit/sessions/s.jsonl"
}
fresh; plan
agent_file test-writer 'skills: [clean-code]'
agent_file developer 'skills: [clean-code]'
mark 2026-10-18T10:00:00Z 2 tests; agent_start 2026-10-18T10:00:04Z test-writer
preload 2026-10-18T10:00:04Z test-writer tdd-loop; preload 2026-10-18T10:00:04Z test-writer jvm-testing
mark 2026-10-18T10:05:00Z 2 code; agent_start 2026-10-18T10:05:01Z developer
preload 2026-10-18T10:05:01Z developer hexagonal-usecase
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing
gate; check "recorded preload: the records count as loads" $?
has "| step 2 | build | hexagonal-usecase | — |"; check "recorded preload: a recorded preload counts" $?

fresh; plan
agent_file developer 'skills: [hexagonal-usecase]'
mark 2026-10-18T10:00:00Z 2 tests; agent_start 2026-10-18T10:00:04Z test-writer
preload 2026-10-18T10:00:04Z test-writer tdd-loop; preload 2026-10-18T10:00:04Z test-writer jvm-testing
mark 2026-10-18T10:05:00Z 2 code; agent_start 2026-10-18T10:05:01Z developer
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing
gate; [ $? -eq 1 ]; check "recorded preload: a file with records does not read the frontmatter" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "recorded preload: a skill only the frontmatter names is missing" $?

fresh; plan
mark 2026-10-18T10:00:00Z 2 tests; agent_start 2026-10-18T10:00:04Z test-writer
preload 2026-10-18T10:00:04Z test-writer tdd-loop; preload 2026-10-18T10:00:04Z test-writer jvm-testing
mark 2026-10-18T10:05:00Z 2 code; agent_start 2026-10-18T10:05:01Z developer
preload 2026-10-18T10:05:01Z developer hexagonal-usecase false
mark 2026-10-18T10:10:00Z 3 tests; load 2026-10-18T10:10:02Z jvm-testing
gate; [ $? -eq 1 ]; check "recorded preload: a preload the checkout lacked loads nothing" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "recorded preload: the not-found skill is named" $?

# build-feature: the Archon log gives the windows; red/step-<n>.log's time picks the step.
node_ev() { # node_ev <type> <path> <invocation id> <iteration> <utc time>
  echo "{\"type\":\"$1\",\"ts\":\"$5\",\"execution\":{\"path\":\"$2\",\"invocation\":{\"id\":\"$3\",\"loopPath\":[{\"groupId\":\"implement\",\"iteration\":$4}]}}}" \
    >> "$logs/$run.jsonl"
}
red() { mkdir -p "$art/red"; touch -d "$2" "$art/red/step-$1.log"; }
fixture() {
  rm -f "$logs/$run.jsonl"
  echo '{"type":"node_start","ts":"2026-10-18T09:00:00Z","execution":{"path":"plan","invocation":{"id":"p"}}}' >> "$logs/$run.jsonl"
  echo '{"type":"node_complete","ts":"2026-10-18T09:10:00Z","execution":{"path":"plan","invocation":{"id":"p"}}}' >> "$logs/$run.jsonl"
  node_ev node_start implement.write-tests w1 1 2026-10-18T10:00:00Z; node_ev node_complete implement.write-tests w1 1 2026-10-18T10:01:00Z
  node_ev node_start implement.build-step b1 1 2026-10-18T10:01:01Z; node_ev node_complete implement.build-step b1 1 2026-10-18T10:02:00Z
  node_ev node_start implement.write-tests w2 2 2026-10-18T10:02:01Z; node_ev node_complete implement.write-tests w2 2 2026-10-18T10:05:00Z
  node_ev node_start implement.build-step b2 2 2026-10-18T10:05:01Z; node_ev node_complete implement.build-step b2 2 2026-10-18T10:09:00Z
  node_ev node_start implement.write-tests w3 3 2026-10-18T10:09:01Z; node_ev node_complete implement.write-tests w3 3 2026-10-18T10:12:00Z
  node_ev node_start implement.build-step b3 3 2026-10-18T10:12:01Z; node_ev node_complete implement.build-step b3 3 2026-10-18T10:15:00Z
  red 2 2026-10-18T10:04:00Z; red 3 2026-10-18T10:11:00Z
}
fresh; plan; fixture
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
load 2026-10-18T10:10:00Z jvm-testing
gate "$run"; check "log: every skill loaded exits 0" $?
has "| plan | plan | clean-architecture | — |"; check "log: the plan row" $?
has "| step 2 | build | hexagonal-usecase | — |"; check "log: the build-step of the red log's iteration is that step" $?

fresh; plan; fixture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:10:00Z jvm-testing
load 2026-10-18T10:13:00Z hexagonal-usecase
gate "$run"; [ $? -eq 1 ]; check "log: missing loads fail" $?
has "the plan node never loaded clean-architecture"; check "log: a plan without clean-architecture is named" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "log: a load in a later build-step does not count" $?

# An included plan block (build-feature's plan node in the 2026-10-23 trial) logs its own nodes as plan__<node>, as
# run 24c3389b's log shows; a load in plan__<node> is the plan's, and none there still fails.
incl_plan() { # the fixture with the plan as an include: plan__policy then plan__plan, and no plan node
  fixture
  grep -v '"path":"plan"' "$logs/$run.jsonl" > "$logs/x" && mv "$logs/x" "$logs/$run.jsonl"
  echo '{"type":"node_start","ts":"2026-10-18T09:00:00Z","execution":{"path":"plan__policy","invocation":{"id":"pp"}}}' >> "$logs/$run.jsonl"
  echo '{"type":"node_complete","ts":"2026-10-18T09:00:05Z","execution":{"path":"plan__policy","invocation":{"id":"pp"}}}' >> "$logs/$run.jsonl"
  echo '{"type":"node_start","ts":"2026-10-18T09:00:06Z","execution":{"path":"plan__plan","invocation":{"id":"pl"}}}' >> "$logs/$run.jsonl"
  echo '{"type":"node_complete","ts":"2026-10-18T09:10:00Z","execution":{"path":"plan__plan","invocation":{"id":"pl"}}}' >> "$logs/$run.jsonl"
}
fresh; plan; incl_plan
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
load 2026-10-18T10:10:00Z jvm-testing
gate "$run"; check "log: a load in an included plan block's node counts for the plan" $?
fresh; plan; incl_plan
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
load 2026-10-18T10:10:00Z jvm-testing
gate "$run"; [ $? -eq 1 ]; check "log: an included plan block that never loaded clean-architecture fails" $?
has "the plan node never loaded clean-architecture"; check "log: the included plan's missing load is named" $?

# The loop keeps each node's conversation: step 3's agents still hold what they loaded in iterations 1 and 2.
fresh; plan; fixture
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:00:30Z tdd-loop; load 2026-10-18T10:01:30Z hexagonal-usecase; load 2026-10-18T10:03:00Z jvm-testing
gate "$run"; check "log: a load by the same node in an earlier iteration counts" $?
has "| step 2 | test | jvm-testing, tdd-loop | — |"; check "log: step 2 counts iteration 1's test load" $?
has "| step 3 | test | jvm-testing | — |"; check "log: step 3 counts iteration 2's test load" $?

fresh; plan; fixture
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:00:30Z jvm-testing; load 2026-10-18T10:00:31Z tdd-loop; load 2026-10-18T10:00:40Z hexagonal-usecase
gate "$run"; [ $? -eq 1 ]; check "log: a load by the test agent does not count for the build agent" $?
has "step 2: the build agent never loaded hexagonal-usecase"; check "log: the build agent's missing skill is named" $?

# --live: the check right after one agent inside the loop. It never fails; it says what is missing for the loop's
# `when:` and tells the next agent in skills-missing.md.
live() { out=$(cd "$tree" && node "$script" "$art" "$run" --live "$1" 2>/dev/null); rc=$?; }
lcheck() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "    $out"; fi; }
open2() { sed -i 's/^- \[x\] \*\*Step 1/- [ ] **Step 1/; s/^- \[x\] (pin only)/- [ ] (pin only)/' "$art/plan.md"; }
fresh; plan; open2; fixture
load 2026-10-18T10:03:00Z jvm-testing
live test
lcheck "live: a test-side miss exits 0" $rc
lcheck "live: a test-side miss says ok false for step 2" $(grep -q '"ok":false,"n":2,"side":"test","missing":\["tdd-loop"\]' <<< "$out"; echo $?)
lcheck "live: skills-missing.md names the test skill" $(grep -qx 'Test skills: tdd-loop' "$art/skills-missing.md"; echo $?)
lcheck "live: a test-side miss leaves the plan alone" $(grep -q '^- \[ \] \*\*Step 1' "$art/plan.md"; echo $?)

load 2026-10-18T10:03:01Z tdd-loop
live test
lcheck "live: every test skill loaded says ok" $(grep -q '"ok":true' <<< "$out"; echo $?)
lcheck "live: an ok check removes skills-missing.md" $([ ! -e "$art/skills-missing.md" ]; echo $?)

fresh; plan; fixture; rm "$art/red/step-3.log"
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop
live build
lcheck "live: a build-side miss says ok false for the newest red log's step" $(grep -q '"ok":false,"n":2,"side":"build","missing":\["hexagonal-usecase"\]' <<< "$out"; echo $?)
lcheck "live: a build-side miss opens that step again" $(grep -q '^- \[ \] \*\*Step 1' "$art/plan.md" && grep -q '^- \[x\] (verify only)' "$art/plan.md" && grep -q '^- \[x\] (pin only)' "$art/plan.md"; echo $?)
lcheck "live: skills-missing.md names the build skill" $(grep -qx 'Build skills: hexagonal-usecase' "$art/skills-missing.md"; echo $?)

fresh; plan; fixture; rm "$art/red/step-3.log"
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:06:00Z hexagonal-usecase
live build
lcheck "live: every build skill loaded says ok and keeps the step" $(grep -q '"ok":true' <<< "$out" && grep -q '^- \[x\] \*\*Step 1' "$art/plan.md"; echo $?)

fresh; plan; fixture
live build
lcheck "live: a pin-only step needs no build skill" $(grep -q '"ok":true,"n":3' <<< "$out"; echo $?)

fresh; plan; open2; fixture; echo 'BLOCKED: step 2: which port?' >> "$art/plan.md"
live test
lcheck "live: a blocked plan is left to blocked-stop" $(grep -q '"ok":true' <<< "$out" && [ ! -e "$art/skills-missing.md" ]; echo $?)

# False "no window" paths (run 4c92a55f): each window a step's agents worked in must be found.
# A red log the build-step wrote again (it reran the tests into it) belongs to the write-tests window before it.
fresh; plan; fixture
red 2 2026-10-18T10:07:00Z
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
gate "$run"; check "window: a red log written in the build-step window still names its step" $?
has "| step 2 | build | hexagonal-usecase | — |"; check "window: that step's build load counts" $?

# A step its build-step did not finish is built again in the next iteration, before the next step's tests.
fresh; plan; fixture
node_ev node_start implement.write-tests w4 4 2026-10-18T10:15:01Z; node_ev node_complete implement.write-tests w4 4 2026-10-18T10:18:00Z
red 2 2026-10-18T10:04:00Z; red 3 2026-10-18T10:16:00Z
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:13:00Z hexagonal-usecase
gate "$run"; check "window: a step built again in a later iteration counts that build-step" $?

# A resumed run numbers its iterations from 1 again: windows go by time, not by iteration.
fresh; plan; fixture
sed -i 's/"id":"w3","loopPath":\[{"groupId":"implement","iteration":3}/"id":"w3","loopPath":[{"groupId":"implement","iteration":1}/; s/"id":"b3","loopPath":\[{"groupId":"implement","iteration":3}/"id":"b3","loopPath":[{"groupId":"implement","iteration":1}/' "$logs/$run.jsonl"
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
gate "$run"; check "window: a resumed run's renumbered iterations keep the earlier loads" $?
has "| step 3 | test | jvm-testing | — |"; check "window: step 3 counts the test load before the resume" $?

# No red log at all for a step: the message says why there is no window.
fresh; plan; fixture
rm "$art/red/step-3.log"
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
gate "$run"; [ $? -eq 1 ]; check "window: a step with no red log fails" $?
has "step 3: no test agent window found to check its Test skills against (there is no red/step-3.log"; check "window: the missing red log is named" $?

# TASK-77 (run 3bb0bc20): a test-side remedy loads the test skills in a later write-tests window without rewriting
# the red log. The build-step between the windows was skipped, so the later window still belongs to the same step.
remedy() {
  rm -f "$logs/$run.jsonl"
  echo '{"type":"node_start","ts":"2026-11-19T06:00:00Z","execution":{"path":"plan","invocation":{"id":"p"}}}' >> "$logs/$run.jsonl"
  echo '{"type":"node_complete","ts":"2026-11-19T06:10:00Z","execution":{"path":"plan","invocation":{"id":"p"}}}' >> "$logs/$run.jsonl"
  node_ev node_start implement.write-tests r1 1 2026-11-19T06:27:17.290Z
  node_ev node_complete implement.write-tests r1 1 2026-11-19T06:27:28.266Z
  node_ev node_skipped implement.build-step s1 1 2026-11-19T06:27:28.396Z
  node_ev node_start implement.write-tests r2 2 2026-11-19T06:27:28.523Z
  node_ev node_complete implement.write-tests r2 2 2026-11-19T06:27:39.089Z
  node_ev node_skipped implement.build-step s2 2 2026-11-19T06:27:39.196Z
  red 2 2026-11-19T06:27:25Z
}
fresh; plan; open2; remedy
load 2026-11-19T06:27:33Z tdd-loop; load 2026-11-19T06:27:33Z jvm-testing
printf 'Test skills: tdd-loop, jvm-testing\n' > "$art/skills-missing.md"
live test
lcheck "AC2: red log in window 1, loads only in window 2: the live check answers ok" $(grep -q '"ok":true,"n":2,"side":"test","missing":\[\]' <<< "$out"; echo $?)
lcheck "AC2: the ok answer removes skills-missing.md" $([ ! -e "$art/skills-missing.md" ]; echo $?)

fresh; plan; remedy
load 2026-11-19T06:27:33Z tdd-loop; load 2026-11-19T06:27:33Z jvm-testing
load 2026-11-19T06:01:00Z clean-architecture
gate "$run"
has "| step 2 | test | jvm-testing, tdd-loop | — |"; check "AC1: the gate counts a later write-tests window of the same step" $?
! has "step 2: the test agent never loaded"; check "AC1: the gate names no test-side miss for step 2" $?

# AC3: a later step's write-tests window never counts for the step before.
fresh; plan; fixture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:10:00Z tdd-loop
gate "$run"; [ $? -eq 1 ]; check "AC3 exit: a load in the next step's window fails the gate" $?
has "step 2: the test agent never loaded tdd-loop"; check "AC3: a load in the next step's write-tests window does not count for the step before" $?

fresh; plan; fixture; rm "$art/red/step-3.log"
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:10:00Z tdd-loop
gate "$run"
has "step 2: the test agent never loaded tdd-loop"; check "AC3: without the next step's red log, a write-tests window after a build-step that ran is not the step before's" $?

fresh; plan; remedy
node_ev node_start implement.build-step b3 3 2026-11-19T06:27:39.300Z
node_ev node_complete implement.build-step b3 3 2026-11-19T06:28:00Z
node_ev node_start implement.write-tests r3 4 2026-11-19T06:28:01Z
node_ev node_complete implement.write-tests r3 4 2026-11-19T06:29:00Z
load 2026-11-19T06:27:33Z jvm-testing; load 2026-11-19T06:28:30Z tdd-loop
gate "$run"
has "step 2: the test agent never loaded tdd-loop"; check "AC3: after the remedy and a build-step that ran, the next write-tests window is not the remedy's step" $?

# No build-step ran between them, so only the next step's red log ends the remedy step's write-tests windows.
fresh; plan; remedy
node_ev node_start implement.write-tests r3 3 2026-11-19T06:27:40Z
node_ev node_complete implement.write-tests r3 3 2026-11-19T06:29:00Z
red 3 2026-11-19T06:28:00Z
load 2026-11-19T06:27:33Z jvm-testing; load 2026-11-19T06:28:30Z tdd-loop
gate "$run"
has "step 2: the test agent never loaded tdd-loop"; check "AC3: with no build-step that ran, the next step's write-tests window with its red log is not the step before's" $?

# A step an answer folded into an earlier step (`(folded into step <k>)`) has no window of its own: step k's count.
foldplan() {
  cat > "$art/plan.md" <<EOF
## Steps
- [x] (verify only) **Step 0 — bundle.**
- [x] **Step 1 — the use case.**
  Test skills: jvm-testing
  Build skills: hexagonal-usecase
- [x] ${1:-} **Step 2 — the adapter.**
  Test skills: testcontainers
  Build skills: persistence-repository
EOF
}
foldloads() {
  load 2026-10-18T09:01:00Z clean-architecture
  load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:06:00Z hexagonal-usecase
  load 2026-10-18T10:13:00Z persistence-repository
}
fresh; foldplan '(folded into step 2)'; fixture; rm "$art/red/step-3.log"; foldloads
load 2026-10-18T10:03:02Z testcontainers
gate "$run"; check "fold: a folded step's skills count in the windows of the step it was folded into" $?
has "| step 3 (folded into 2) | test | testcontainers | — |"; check "fold: the row names the fold" $?

fresh; foldplan '(folded into step 2)'; fixture; rm "$art/red/step-3.log"; foldloads
gate "$run"; [ $? -eq 1 ]; check "fold: a folded step's skill loaded in no window of its target fails" $?
has "step 3: the test agent never loaded testcontainers"; check "fold: the missing skill is named" $?

fresh; foldplan; fixture; rm "$art/red/step-3.log"; foldloads; load 2026-10-18T10:03:02Z testcontainers
gate "$run"; [ $? -eq 1 ]; check "fold: without the marker a step with no window still fails" $?

fresh; foldplan '(folded into step 1)'; fixture; rm "$art/red/step-3.log"; foldloads; load 2026-10-18T10:03:02Z testcontainers
gate "$run"; [ $? -eq 1 ]; check "fold: folded into a step with no window fails" $?
has "step 3: no test agent window found to check its Test skills against (it is folded into step 1, which has none either)"
check "fold: says the target has no window either" $?

fresh; foldplan '(folded into step 3)'; fixture; rm "$art/red/step-3.log"; foldloads; load 2026-10-18T10:03:02Z testcontainers
gate "$run"; [ $? -eq 1 ]; check "fold: a step folded into itself or a later step is no fold" $?

# TASK-48.8 / TASK-7.4: the run was resumed after a BLOCKED answer folded step 3 into step 2; the resumed write-tests
# wrote its red run as red/step-2-adapter.log and loaded the folded step's Test skills in its own window.
resumed() {
  node_ev node_start implement.write-tests w4 1 2026-10-18T10:20:00Z; node_ev node_complete implement.write-tests w4 1 2026-10-18T10:25:00Z
  node_ev node_start implement.build-step b4 1 2026-10-18T10:25:01Z; node_ev node_complete implement.build-step b4 1 2026-10-18T10:30:00Z
  touch -d 2026-10-18T10:22:00Z "$art/red/step-2-adapter.log"
}
fresh; foldplan '(folded into step 2)'; fixture; rm "$art/red/step-3.log"; resumed; foldloads
load 2026-10-18T10:22:30Z testcontainers
gate "$run"; check "resume: a resumed write-tests that writes red/step-2-adapter.log with step 3 folded into 2 counts its loads" $?
has "| step 3 (folded into 2) | test | testcontainers | — |"; check "resume: the folded step's test load in the resumed window counts" $?

fresh; foldplan '(folded into step 2)'; fixture; resumed; foldloads
load 2026-10-18T10:22:30Z testcontainers
live build
lcheck "live: a suffixed red log names its step" $(grep -q '"n":2' <<< "$out"; echo $?)

# The live check of step k also needs the skills of the steps folded into it: they are built in step k's windows.
fresh; foldplan '(folded into step 2)'; fixture; rm "$art/red/step-3.log"
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z testcontainers; load 2026-10-18T10:06:00Z hexagonal-usecase
live build
lcheck "live: a folded step's build skill not loaded says ok false for step 2" $(grep -q '"ok":false,"n":2,"side":"build","missing":\["persistence-repository"\]' <<< "$out"; echo $?)

fresh; foldplan '(folded into step 2)'; fixture; rm "$art/red/step-3.log"
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z testcontainers; load 2026-10-18T10:06:00Z hexagonal-usecase
load 2026-10-18T10:06:01Z persistence-repository
live build
lcheck "live: a folded step's build skill loaded says ok" $(grep -q '"ok":true,"n":2' <<< "$out"; echo $?)


# AC4: planSteps reads a skills line only at the start of a line (after indent and a - or * marker), outside a fence.
ps() { printf '%s\n' "$@" > "$root/ps.md"
  out=$(node -e 'const {planSteps}=require(process.argv[1]);console.log(JSON.stringify(planSteps(require("fs").readFileSync(process.argv[2],"utf8"))))' "$script" "$root/ps.md"); }
base='[{"n":1,"kind":"build","fold":0,"test":["jvm-testing"],"build":[]}]'
refused() { # refused <name> <line>...: the lines follow step 1's own skills line
  ps '- [ ] **Step 1.**' '  Test skills: jvm-testing' "${@:2}"
  lcheck "$1" $([ "$out" = "$base" ]; echo $?)
}
ps '- [ ] **Step 1.**' 'Test skills: alpha'
lcheck "AC4 keeps: a label at the line start is read" $(grep -q '"test":\["alpha"\]' <<< "$out"; echo $?)
ps '- [ ] **Step 1.**' '  Build skills: `beta`, gamma'
lcheck "AC4 keeps: an indented label is read, backticks stripped" $(grep -q '"build":\["beta","gamma"\]' <<< "$out"; echo $?)
ps '- [ ] **Step 1.**' '  - Test skills: delta'
lcheck "AC4 keeps: a label after a - list marker is read" $(grep -q '"test":\["delta"\]' <<< "$out"; echo $?)
ps '- [ ] **Step 1.**' '  * Build skills: epsilon'
lcheck "AC4 keeps: a label after a * list marker is read" $(grep -q '"build":\["epsilon"\]' <<< "$out"; echo $?)
refused "AC4 refuses: prose quoting the label mid-line adds no skills (run b1d9506f)" \
  '  - Reword the bullet that quoted Test skills: first, as round 1 left'
refused "AC4 refuses: an ANSWER line quoting the label adds no skills" \
  'ANSWER: keep it (to: may the plan say Build skills: round, left?)'
refused "AC4 refuses: a BLOCKED line quoting the label adds no skills" \
  'BLOCKED: may step 2 drop Test skills: zeta'
refused "AC4 refuses: a label inside a backtick fence adds no skills" \
  '  ```' '  Test skills: sample-skill' '  ```'
refused "AC4 refuses: a label inside a tilde fence adds no skills" \
  '  ~~~' '  Build skills: sample-build' '  ~~~'
ps '- [ ] **Step 1.**' '  Test skills: jvm-testing' '  ```' '  Test skills: sample-skill' '  ```' '  Build skills: eta'
lcheck "AC4 keeps: a label after a closed fence is read again" \
  $([ "$out" = '[{"n":1,"kind":"build","fold":0,"test":["jvm-testing"],"build":["eta"]}]' ]; echo $?)
refused "AC4 refuses: a tilde line inside a backtick fence does not close it" \
  '  ```' '  ~~~' '  Test skills: sample-skill' '  ```'
refused "AC4 refuses: a label glued to a list marker, with no space after it, is not a skills line" \
  '-Test skills: zeta'
eta='[{"n":1,"kind":"build","fold":0,"test":["jvm-testing"],"build":["eta"]}]'
ps '- [ ] **Step 1.**' '  Test skills: jvm-testing' '  ``inline`` code' '  Build skills: eta'
lcheck "AC4 keeps: two backticks open no fence" $([ "$out" = "$eta" ]; echo $?)
ps '- [ ] **Step 1.**' '  Test skills: jvm-testing' '  ~~struck~~ text' '  Build skills: eta'
lcheck "AC4 keeps: two tildes open no fence" $([ "$out" = "$eta" ]; echo $?)

# Gate-level repro of run b1d9506f43c1ed8856dbffac5976e15c.
plan_prose() {
  cat > "$art/plan.md" <<'PLAN'
## Steps
- [x] (verify only) **Step 0 — bundle.**
  Test skills: jvm-testing
- [x] **Step 1 — the use case.**
  Test skills: `jvm-testing`, tdd-loop
  - Reword the bullet that quoted Test skills: first, as round 1 left
  ```
  Test skills: sample-skill
  ```
  Build skills: hexagonal-usecase
- [x] (pin only) **Step 2 — pin the guard.**
  Test skills: jvm-testing
  Build skills: hexagonal-usecase
- [x] **Step 3 — docs.**
  Test skills: none
  Build skills:
ANSWER: keep the guard (to: may the plan say Build skills: round, left?)
PLAN
}
fresh; plan_prose; fixture
load 2026-10-18T09:01:00Z clean-architecture
load 2026-10-18T10:03:00Z jvm-testing; load 2026-10-18T10:03:01Z tdd-loop; load 2026-10-18T10:06:00Z hexagonal-usecase
load 2026-10-18T10:10:00Z jvm-testing
gate "$run"; check "AC4 repro (run b1d9506f43c1ed8856dbffac5976e15c): prose quoting the label under a step adds no skills, the gate exits 0" $?
has "| step 2 | test | jvm-testing, tdd-loop | — |"; check "AC4 repro: the step 2 test row names only its own skills" $?
! has "first"; check "AC4 repro: no prose word is named as a skill" $?

echo "skill-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
