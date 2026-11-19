#!/usr/bin/env bash
# Tests for .archon/scripts/run-trace.js against a fixture run log under a throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/run-trace.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/run-trace.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
run=0123456789abcdef0123456789abcdef
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
mkdir -p "$logs"
log="$logs/$run.jsonl"
art="$root/artifacts"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$art/trace.md" 2>/dev/null; fi
}
has() { grep -qF -- "$1" "$art/trace.md"; }
tool() { # tool <step> <name> <rawInput json>
  echo "{\"type\":\"provider_event\",\"step\":\"$1\",\"event\":{\"type\":\"tool_call\",\"name\":\"$2\",\"rawInput\":$3}}" >> "$log"
}

cat > "$log" <<EOF
{"type":"workflow_start","workflow_name":"build-feature","ts":"2026-10-18T10:00:00Z"}
{"type":"node_start","step":"ticket","ts":"2026-10-18T10:00:00Z","execution":{"node":{"kind":"exec"}}}
{"type":"node_start","step":"implement","ts":"2026-10-18T10:05:00Z"}
EOF
tool implement Skill '{"skill":"jvm-testing"}'
tool implement Bash '{"command":"bash scripts/scaffold.sh --test usecase/create-usecase x.json out && bash .github/skills/tdd-loop/scripts/red.sh"}'
tool implement Bash '{"command":"cat .archon/scripts/step-gate.sh; ./gradlew :application:test 2>&1 | tail"}'
tool implement Read '{"file_path":"docs/code-maps/jvm-testing.md"}'
tool implement Write '{"file_path":"C:/x/worktrees/build-feature-1/src/A.java"}'
tool plan Write '{"file_path":"C:\\x\\artifacts\\runs\\abc\\plan.md","content":"run .claude/scripts/contract-pin.sh then ./gradlew :app:build; read docs/code-maps/java.md"}'
tool plan Edit '{"file_path":"C:\\x\\artifacts\\runs\\abc\\plan.md","old_string":"a","new_string":"bash scripts/test/codegen.test.sh"}'

# One-off write: every kind lands under its node, with run versus read told apart.
node "$script" "$run" "$art"; check "one-off exits 0" $?
has "_build-feature · running"; check "header names the workflow and its state" $?
has "== ticket (script node) +0m"; check "script node is marked" $?
has "== implement +5m"; check "node start offset" $?
has "skill                jvm-testing"; check "skill load" $?
has "template             usecase/create-usecase"; check "scaffold template" $?
has "skill script         tdd-loop/red.sh"; check "skill script run" $?
has "archon script (read) step-gate.sh"; check "script only read" $?
has "gradle               :application:test"; check "gradle task" $?
has "code-map             jvm-testing"; check "code-map read" $?
has "wrote                src/A.java"; check "written file, worktree prefix dropped" $?
has "wrote                plan.md  ×2"; check "written file with backslashes, run prefix dropped" $?
! has "contract-pin.sh" && ! has ":app:build" && ! has "code-map             java" && ! has "codegen.test.sh"
check "a write's content counts as no script, task or code-map" $?

# An unknown run is an error, not an empty trace.
node "$script" ffffffffffffffffffffffffffffffff "$root/none" 2>/dev/null; [ $? -eq 1 ] && [ ! -e "$root/none/trace.md" ]; check "unknown run fails" $?

# The follower rewrites the trace as the log grows and exits on workflow_complete.
export TRACE_POLL_MS=100
rm -f "$art/trace.md"
node "$script" --follow "$run" "$art" & pid=$!
poll() { for _ in $(seq 1 50); do "$@" && return 0; sleep 0.1; done; return 1; }   # poll <command>: up to 5 s
poll has "_build-feature · running"; check "follower writes while running" $?
echo '{"type":"workflow_error","ts":"2026-10-18T10:20:00Z"}' >> "$log"
poll has "· failed ·"; check "follower shows a failed run" $?
kill -0 "$pid" 2>/dev/null; check "follower waits for a resume after an error" $?
echo '{"type":"workflow_resume","ts":"2026-10-18T10:21:00Z"}' >> "$log"
echo '{"type":"workflow_complete","ts":"2026-10-18T10:30:00Z"}' >> "$log"
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
! kill -0 "$pid" 2>/dev/null; check "follower exits when the run completes" $?
has "· finished ·"; check "final trace says finished" $?

# The follower gives up when the log stays silent, so a killed run leaves no process behind.
TRACE_IDLE_MS=300 node "$script" --follow "$run" "$art" & pid=$!
sed -i '$d' "$log"   # drop workflow_complete: the run looks unfinished
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
! kill -0 "$pid" 2>/dev/null; check "follower exits on an idle log" $?

# --start returns at once and leaves a detached follower behind.
rm -f "$art/trace.md"
TRACE_IDLE_MS=600 node "$script" --start "$run" "$art"; check "--start exits 0" $?
for _ in 1 2 3 4 5 6; do [ -e "$art/trace.md" ] && break; sleep 0.5; done
[ -e "$art/trace.md" ]; check "--start's follower writes the trace" $?
# Let the detached follower time out before the fixture is removed.
poll bash -c '! pgrep -f -- "--follow $1 $2" > /dev/null' _ "$run" "$art"

echo "run-trace: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
