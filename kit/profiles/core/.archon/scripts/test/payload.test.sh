#!/usr/bin/env bash
# Tests for .claude/hooks/scripts/payload.sh (the sourced payload normalizer and both-shape deny helper) and for
# scope-guard.sh and tool-advice.sh fed a Copilot camelCase payload. Claude payloads must pass through byte for byte.
# Usage: bash .archon/scripts/test/payload.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }
eq() { if [ "$3" = "$2" ]; then ok; else bad "$1" "got [$3], want [$2]"; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- the helper
# shellcheck source=/dev/null
( . "$root/.claude/hooks/scripts/payload.sh"; echo "$CLAUDE_PROJECT_DIR" ) > "$tmp/pd1"
eq "CLAUDE_PROJECT_DIR falls back to the git top level" "$root" "$(cd "$root/.claude" && env -u CLAUDE_PROJECT_DIR bash -c '. "'"$root"'/.claude/hooks/scripts/payload.sh"; echo "$CLAUDE_PROJECT_DIR"')"
eq "CLAUDE_PROJECT_DIR falls back to PWD outside git" "$tmp" "$(cd "$tmp" && env -u CLAUDE_PROJECT_DIR bash -c '. "'"$root"'/.claude/hooks/scripts/payload.sh"; echo "$CLAUDE_PROJECT_DIR"')"
eq "an existing CLAUDE_PROJECT_DIR is kept" /keep "$(CLAUDE_PROJECT_DIR=/keep bash -c '. "'"$root"'/.claude/hooks/scripts/payload.sh"; echo "$CLAUDE_PROJECT_DIR"')"

export CLAUDE_PROJECT_DIR="$root"
# shellcheck source=/dev/null
. "$root/.claude/hooks/scripts/payload.sh"
norm() { hook_normalize_payload "$1"; }
claude='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls  -la"},"agent_type":"developer"}'
eq "a Claude payload passes through byte for byte" "$claude" "$(norm "$claude")"
eq "garbage passes through" 'not json' "$(norm 'not json')"
cp1='{"sessionId":"s1","agentName":"developer","cwd":"/w","toolName":"bash","toolArgs":"{\"command\":\"git status\"}"}'
n="$(norm "$cp1")"
eq "Copilot bash (toolArgs a JSON string): tool_name" Bash "$(jq -r .tool_name <<<"$n")"
eq "Copilot bash: tool_input.command" "git status" "$(jq -r .tool_input.command <<<"$n")"
eq "Copilot: agent_type from agentName" developer "$(jq -r .agent_type <<<"$n")"
eq "Copilot: session_id from sessionId" s1 "$(jq -r .session_id <<<"$n")"
n="$(norm '{"agentType":"reviewer","agentName":"x","agentId":"a7","toolName":"bash","toolArgs":"{}"}')"
eq "Copilot subagent tool hook: agent_type from agentType, before agentName" reviewer "$(jq -r .agent_type <<<"$n")"
eq "Copilot subagent tool hook: agent_id from agentId" a7 "$(jq -r .agent_id <<<"$n")"
n="$(KIT_AGENT=developer norm '{"toolName":"bash","toolArgs":"{}"}')"
eq "a root payload takes its agent from KIT_AGENT" developer "$(jq -r .agent_type <<<"$n")"
n="$(KIT_AGENT=developer norm '{"tool_name":"Bash","tool_input":{}}')"
eq "a root PascalCase payload takes its agent from KIT_AGENT too" developer "$(jq -r .agent_type <<<"$n")"
n="$(KIT_AGENT=delegator norm '{"agentType":"developer","agentId":"a1","toolName":"bash","toolArgs":"{}"}')"
eq "a subagent's agentType wins over KIT_AGENT" developer "$(jq -r .agent_type <<<"$n")"
n="$(KIT_AGENT=delegator norm '{"agentId":"a1","toolName":"bash","toolArgs":"{}"}')"
eq "KIT_AGENT never names a subagent's call" none "$(jq -r '.agent_type // "none"' <<<"$n")"
eq "KIT_AGENT leaves a Claude agent_type alone, byte for byte" "$claude" "$(KIT_AGENT=reviewer norm "$claude")"
n="$(norm '{"toolName":"view","toolArgs":{"path":"/a/b.txt"}}')"
eq "Copilot view (toolArgs an object): tool_name Read" Read "$(jq -r .tool_name <<<"$n")"
eq "Copilot view: path copied to file_path" /a/b.txt "$(jq -r .tool_input.file_path <<<"$n")"
n="$(norm '{"toolName":"create","toolArgs":"{\"path\":\"x.md\",\"file_text\":\"t\"}"}')"
eq "Copilot create maps to Write with file_path" "Write x.md" "$(jq -r '"\(.tool_name) \(.tool_input.file_path)"' <<<"$n")"
n="$(norm '{"toolName":"mystery","toolArgs":"{}"}')"
eq "an unknown Copilot tool keeps its name" mystery "$(jq -r .tool_name <<<"$n")"
n="$(norm '{"toolName":"bash","tool_name":"Edit","toolArgs":{"command":"x"}}')"
eq "a Claude field already present wins" Edit "$(jq -r .tool_name <<<"$n")"
n="$(COPILOT_TOOLS_JSON=/nonexistent norm '{"toolName":"view","toolArgs":{"path":"/p"}}')"
eq "without tools.json the built-in names still map" Read "$(jq -r .tool_name <<<"$n")"

d="$(hook_deny_json 'no "way"')"
eq "deny: Claude shape" deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$d")"
eq "deny: Copilot shape" deny "$(jq -r .permissionDecision <<<"$d")"
eq "deny: reasons agree and keep quotes" 'no "way"' "$(jq -r '.permissionDecisionReason, .hookSpecificOutput.permissionDecisionReason' <<<"$d" | sort -u)"

# --- scope-guard with a Copilot payload: the developer may not write agent-scopes.json, may write its module
sg="$root/.claude/hooks/scripts/scope-guard.sh"
run_sg() { env -u CLAUDE_SCOPE_POLICY CLAUDE_PROJECT_DIR="$root" bash "$sg" PreToolUse <<<"$1"; }
out="$(run_sg "{\"agentName\":\"developer\",\"cwd\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$root/.claude/hooks/agent-scopes.json\"}}")"
eq "scope-guard (Copilot create of the fence): Claude-shape deny" deny "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")"
eq "scope-guard (Copilot create of the fence): Copilot-shape deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "{\"agentName\":\"developer\",\"cwd\":\"$root\",\"toolName\":\"bash\",\"toolArgs\":\"{\\\"command\\\":\\\"./gradlew test\\\"}\"}")"
eq "scope-guard (Copilot bash, a root gradlew task): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "{\"agentName\":\"developer\",\"cwd\":\"$root\",\"toolName\":\"bash\",\"toolArgs\":\"{\\\"command\\\":\\\"./gradlew :app:test\\\"}\"}")"
eq "scope-guard (Copilot bash, a module task): no objection" "" "$out"
out="$(run_sg "{\"cwd\":\"$root\",\"toolName\":\"bash\",\"toolArgs\":\"{\\\"command\\\":\\\"rm -rf /\\\"}\"}")"
eq "scope-guard (Copilot, no agent): not its business" "" "$out"
# The three ways a Copilot agent reaches the guard; each must fence an out-of-scope write.
fence="$root/.claude/hooks/agent-scopes.json"
out="$(run_sg "{\"agentType\":\"developer\",\"agentId\":\"a1\",\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (camelCase preToolUse, subagent agentType): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "$(jq -cn --arg r "$root" --arg f "$fence" '{hook_event_name:"PreToolUse",agent_type:"developer",agent_id:"a1",cwd:$r,tool_name:"Write",tool_input:{file_path:$f}}')")"
eq "scope-guard (PascalCase PreToolUse, subagent agent_type): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(KIT_AGENT=developer run_sg "{\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (root session, agent from KIT_AGENT): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(SCOPE_GUARD_MAX_CMD=64 run_sg "$(jq -cn --arg r "$root" '{agentType:"developer",workingDirectory:$r,toolName:"bash",toolArgs:{command:("git status " + ("a" * 80))}}')")"
eq "scope-guard: a command too long to read in time is denied, not slow" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
cl="$(jq -cn --arg r "$root" '{agent_type:"developer",tool_name:"Bash",cwd:$r,tool_input:{command:"./gradlew test"}}')"
eq "scope-guard (Claude payload): still denies" deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$(run_sg "$cl")")"

# --- tool-advice with a Copilot payload: refuse mode denies a contract read for the developer
ta="$root/.claude/hooks/scripts/tool-advice.sh"
out="$(TOOL_ADVICE_CONTRACT=refuse CLAUDE_PROJECT_DIR=/work/wt bash "$ta" PreToolUse <<<'{"agentName":"developer","toolName":"view","toolArgs":{"path":"/work/wt/contract/dist/openapi.yaml"}}')"
eq "tool-advice (Copilot view of contract/, refuse): Copilot-shape deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
eq "tool-advice (Copilot view of contract/, refuse): Claude-shape deny" deny "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")"
out="$(CLAUDE_PROJECT_DIR=/work/wt bash "$ta" PreToolUse <<<'{"agentName":"developer","toolName":"bash","toolArgs":"{\"command\":\"grep -rn operationId contract/\"}"}')"
eq "tool-advice (Copilot bash grep of the contract, report): advice" advice "$(jq -r 'if .hookSpecificOutput.additionalContext then "advice" else "none" end' <<<"$out")"

echo "payload: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
