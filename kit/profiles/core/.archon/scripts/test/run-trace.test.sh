#!/usr/bin/env bash
# Tests for .archon/scripts/run-trace.js against a fixture run log under a throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/run-trace.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/run-trace.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon" COPILOT_HOME="$root/copilot"   # the real ~/.archon and ~/.copilot are never read
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

has "## Warnings" && grep -A2 '^## Warnings' "$art/trace.md" | grep -qF '_None._'; check "a run without warnings says so" $?
! has "Copilot usage per node"; check "no Copilot node, no usage table" $?

# A Copilot run: its tool names count as the Claude tools; a fallback's stderr line, a non-zero exit and the provider's
# warning codes are named warnings, home paths, URLs and e-mail addresses cut; the usage and trail tables are appended.
crun=fedcba9876543210fedcba9876543210
clog="$logs/$crun.jsonl"; cart="$root/copilot-art"; tree="$root/tree"
sid=abcdef12-1111-4111-8111-111111111111
mkdir -p "$COPILOT_HOME/session-state/$sid" "$tree/.apm-audit/sessions"
printf '{"type":"user.message","data":{"content":"PROMPT TEXT"}}\n{"type":"session.usage_record","data":{"usage":{"model":"claude-haiku-5.5","inputTokens":1000,"cacheReadTokens":600,"cacheWriteTokens":300,"outputTokens":50,"cost":1,"duration":900,"accounting":{"sourceSessionId":"%s"}}}}\n' "$sid" \
  > "$COPILOT_HOME/session-state/$sid/events.jsonl"
printf '{"type":"TOOL","session":"%s","agent":"main","tool":"Skill"}\n' "$sid" > "$tree/.apm-audit/sessions/$sid.jsonl"
cat > "$clog" <<LOG
{"type":"workflow_start","workflow_name":"build-feature-copilot","ts":"2026-11-20T10:00:00Z"}
{"type":"node_start","step":"ticket","ts":"2026-11-20T10:00:00Z","execution":{"node":{"kind":"exec"}}}
{"type":"exec_output","step":"ticket","exit_code":0,"stderr_tail":"codegraph: index built\nmcp: contract-api down, codegraph up\nplan-context.sh failed; the plan reads the files itself\nerror: cannot open $HOME/x and /home/alice/y, see https://github.com/someone/repo/pull/1 or ask a@b.example"}
{"type":"node_start","step":"explore","ts":"2026-11-20T10:01:00Z"}
{"type":"provider_event","step":"explore","event":{"type":"warning","code":"copilot.skills_missing","message":"skills x and y are missing"}}
{"type":"provider_event","step":"explore","event":{"type":"warning","code":"copilot.skills_missing","message":"again"}}
{"type":"provider_event","step":"explore","event":{"type":"tool_call","name":"skill","rawInput":{"skill":"jvm-testing"}}}
{"type":"provider_event","step":"explore","event":{"type":"tool_call","name":"bash","rawInput":{"command":"bash .archon/scripts/step-gate.sh 1"}}}
{"type":"provider_event","step":"explore","event":{"type":"tool_call","name":"create","rawInput":{"path":"/x/worktrees/run1/src/B.java","file_text":"run scripts/x.sh"}}}
{"type":"node_complete","step":"explore","duration_ms":60000,"execution":{"node":{"kind":"agent"},"binding":{"provider":"copilot","sessionPreview":"abcdef12","sessionOrigin":"fresh"}}}
{"type":"exec_output","step":"fix-made","exit_code":1,"stderr_tail":"CI_FIX_NO_COMMIT: the fix agent made no commit"}
LOG
node "$script" "$crun" "$cart" "$tree"; check "Copilot run exits 0" $?
ctrace() { grep -qF -- "$1" "$cart/trace.md"; }
ctrace "skill                jvm-testing" && ctrace "archon script        step-gate.sh" && ctrace "wrote                src/B.java" \
  && ! ctrace "x.sh"; check "Copilot tool names count as the Claude tools" $?
ctrace "- ticket: plan-context.sh failed; the plan reads the files itself"; check "a fallback's stderr line is a named warning" $?
ctrace "- ticket: error: cannot open ~/x and ~/y, see <url> or ask <email>"; check "a copied line has home paths, URLs and e-mail cut" $?
! ctrace "codegraph: index built" && ! ctrace "mcp: contract-api down"; check "stderr lines that are no failure are left out" $?
ctrace "- fix-made: exit 1"; check "a non-zero exit is a warning" $?
ctrace "- explore: provider warning copilot.skills_missing ×2" && ! ctrace "are missing"; check "provider warning codes, not their message" $?
ctrace "| explore | abcdef12 | claude-haiku-5.5 | 1 | 100 | 600 | 300 | 50 | 1 | 60 s |"; check "the Copilot usage row" $?
ctrace "| explore | 1 | 1 | 1 |"; check "the hook trail joined by session id" $?
! ctrace "PROMPT TEXT" && ! ctrace "alice" && ! ctrace "$HOME" && ! ctrace "someone"; check "no prompt, home path or account name in the trace" $?
node "$script" "$crun" "$cart"; ! ctrace "Hook audit trail"; check "no checkout, no trail section" $?

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
