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
