#!/usr/bin/env bash
# Tests for .archon/scripts/copilot-audit.js: a fixture Archon log of a Copilot run becomes the audit trail the gates read
# (expected.jsonl), skill-check.js passes on it, a rewrite changes nothing, and a log without tool calls fails closed.
# Usage: bash .archon/scripts/test/copilot-audit.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$here/test/fixtures/copilot-audit"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
run=0123456789abcdef0123456789abcdef
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
mkdir -p "$logs" "$root/tree"
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi; }
tree="$root/tree"
audit() { out=$(cd "$tree" && node "$here/copilot-audit.js" "$@" 2>&1); rc=$?; }
trail() { echo "$tree/.apm-audit/sessions/copilot-$run.jsonl"; }

# 1. The fixture run: exact records, nothing on stdout.
cp "$fx/run.jsonl" "$logs/$run.jsonl"
audit "$run"
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 stdout empty (the gate after it prints JSON)" $([ -z "$out" ]; echo $?)
out=$(diff "$fx/expected.jsonl" "$(trail)" 2>&1); check "1 records equal expected.jsonl (unmapped report_intent left out, failed bash ok:false)" $?

# 2. A second call rewrites the same file.
cp "$(trail)" "$root/first"; audit "$run"
out=$(cmp "$root/first" "$(trail)" 2>&1); check "2 idempotent" $?
check "2 one file only" $([ "$(ls "$tree/.apm-audit/sessions" | wc -l)" -eq 1 ]; echo $?)

# 3. skill-check.js passes on the trail: step 1 test skill in the tests window, build skill in the code window.
art="$root/art"; mkdir -p "$art/steps"
cat > "$art/plan.md" <<'PLAN'
## Steps
- [x] **Step 1 — the use case.**
  Test skills: jvm-testing
  Build skills: clean-code
PLAN
printf '2026-11-19T10:00:00Z\t{"n":1,"kind":"build","phase":"tests","feedback":""}\n2026-11-19T10:05:00Z\t{"n":1,"kind":"build","phase":"code","feedback":""}\n' > "$art/steps/next.log"
out=$(cd "$tree" && node "$here/skill-check.js" "$art" 2>&1); rc=$?
check "3 skill-check passes on the adapter's trail" $([ "$rc" -eq 0 ]; echo $?)
sed -i 's/clean-code/hexagonal-usecase/' "$art/plan.md"
out=$(cd "$tree" && node "$here/skill-check.js" "$art" 2>&1); rc=$?
check "3 skill-check still fails on a skill never loaded" $([ "$rc" -eq 1 ]; echo $?)

# 4. --names lists the tool names with their mapping.
audit --names "$run"
echo "$out" | grep -qF -- $'report_intent\t1\tunmapped' && echo "$out" | grep -qF -- $'skill\t2\t-> Skill'; check "4 --names" $?

# 5. A log without tool calls fails closed (exit 3) and writes no trail (a fresh tree).
tree="$root/tree5"; mkdir -p "$tree"; cp "$fx/empty.jsonl" "$logs/$run.jsonl"
audit "$run"
check "5 no tool calls: exit 3" $([ "$rc" -eq 3 ]; echo $?)
echo "$out" | grep -q 'no tool calls'; check "5 says why" $?
check "5 no trail written" $([ ! -e "$tree/.apm-audit" ]; echo $?)

# 6. Tool calls none of which tools.json maps: exit 3 naming them.
sed 's/"name":"[a-z_]*"/"name":"mystery"/' "$fx/run.jsonl" > "$logs/$run.jsonl"
audit "$run"
check "6 nothing maps: exit 3" $([ "$rc" -eq 3 ]; echo $?)
echo "$out" | grep -q 'mystery'; check "6 names the tools seen" $?

# 7. No log at all, and no run id.
rm -f "$logs/$run.jsonl"; audit "$run"
check "7 no log: exit 3" $([ "$rc" -eq 3 ]; echo $?)
audit; check "7 no run id: exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 8. Hooks already wrote the trail (a session file that is not copilot-*): the adapter writes nothing and removes its own
# stale file; a hook record from before the run does not count.
cp "$fx/run.jsonl" "$logs/$run.jsonl"
tree="$root/tree8"; mkdir -p "$tree/.apm-audit/sessions"
echo '{"type":"TOOL","event":"postToolUse","session":"old","agent":"main","loggedAt":"2026-01-01T00:00:00Z","tool":"Read","arg":"x","ok":true}' > "$tree/.apm-audit/sessions/old.jsonl"
audit "$run"
check "8 an old hook record does not cover the run: synthesised" $([ "$rc" -eq 0 ] && [ -e "$(trail)" ]; echo $?)
echo '{"type":"TOOL","event":"postToolUse","session":"s","agent":"main","loggedAt":"2026-11-19T10:00:05Z","tool":"Bash","arg":"{}","ok":true}' > "$tree/.apm-audit/sessions/s.jsonl"
audit "$run"
check "8 Bash-only hook records in the window do not cover the run: the adapter writes its file" $([ "$rc" -eq 0 ] && [ -e "$(trail)" ]; echo $?)
echo '{"type":"TOOL","event":"postToolUse","session":"s","agent":"main","loggedAt":"2026-11-19T10:00:05Z","tool":"Skill","arg":"{\"skill\":\"jvm-testing\"}","ok":true}' > "$tree/.apm-audit/sessions/s.jsonl"
audit "$run"
check "8 hook records cover the run: exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "8 the stale copilot file is removed" $([ ! -e "$(trail)" ]; echo $?)
check "8 the hook files are untouched" $([ "$(ls "$tree/.apm-audit/sessions" | wc -l)" -eq 2 ]; echo $?)
cp "$fx/empty.jsonl" "$logs/$run.jsonl"; audit "$run"
check "8 hooks cover an empty-log run too: exit 0, no failure" $([ "$rc" -eq 0 ]; echo $?)

# 9. claudeCall: grep's `paths` as a string or a list of one string fills `path`; a longer list or a non-string fills
# nothing, so a reader sees no path rather than a guessed one.
cc() { out=$(COPILOT_TOOLS="$here/../copilot/tools.json" node -e '
  const { claudeCall, loadMap } = require(process.argv[1]);
  const c = claudeCall({ name: "grep", rawInput: JSON.parse(process.argv[2]) }, loadMap());
  console.log(c.name + " " + (c.input.path === undefined ? "-" : JSON.stringify(c.input.path)));' "$here/copilot-audit.js" "$1" 2>&1); }
cc '{"pattern":"X","paths":"src/main"}';   check "9 paths as a string" $([ "$out" = 'Grep "src/main"' ]; echo $?)
cc '{"pattern":"X","paths":["src/main"]}'; check "9 paths as a list of one string" $([ "$out" = 'Grep "src/main"' ]; echo $?)
cc '{"pattern":"X","paths":["a","b"]}';    check "9 a list of two fills no path" $([ "$out" = 'Grep -' ]; echo $?)
cc '{"pattern":"X","paths":[7]}';          check "9 a list of a number fills no path" $([ "$out" = 'Grep -' ]; echo $?)

echo "copilot-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
