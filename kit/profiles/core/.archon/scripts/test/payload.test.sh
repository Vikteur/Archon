#!/usr/bin/env bash
# Tests for .claude/hooks/scripts/payload.sh (the sourced payload normalizer and both-shape deny helper) and for
# scope-guard.sh and tool-advice.sh fed a Copilot camelCase payload, the kit's tools.json map, and .github/hooks/dispatch.sh
# fed Copilot's batched preToolUse payload (toolCalls). Claude payloads must pass through byte for byte.
# Usage: bash .archon/scripts/test/payload.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }
eq() { if [ "$3" = "$2" ]; then ok; else bad "$1" "got [$3], want [$2]"; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; mkdir -p "$tmp/empty"

# --- the helper
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
eq "a subagent call with no type is fenced as the KIT_AGENT root" delegator "$(jq -r '.agent_type // "none"' <<<"$n")"
eq "a converted payload names its root (kit_root)" delegator "$(jq -r '.kit_root // "none"' <<<"$n")"
eq "a converted payload is marked kit_copilot" true "$(jq -r '.kit_copilot // "none"' <<<"$n")"
eq "a Claude payload gets no kit_copilot mark" none "$(jq -r '.kit_copilot // "none"' <<<"$(norm "$claude")")"
n="$(norm '{"tool_name":"bash","agent_type":"developer","tool_input":{"command":"x"}}')"
eq "a native Copilot name in tool_name is mapped (bash -> Bash)" Bash "$(jq -r .tool_name <<<"$n")"
n="$(norm '{"tool_name": "view", "agent_type": "developer", "tool_input": {"path": "/a"}}')"
eq "a native name in tool_name, spaced JSON: view -> Read with file_path" "Read /a" "$(jq -r '"\(.tool_name) \(.tool_input.file_path)"' <<<"$n")"
mcp='{"tool_name":"mcp__codegraph__codegraph_explore","agent_type":"developer","tool_input":{"query":"x"}}'
eq "a Claude MCP call passes through byte for byte" "$mcp" "$(norm "$mcp")"
printf '{bad' > "$tmp/bad-tools.json"
n="$(COPILOT_TOOLS_JSON="$tmp/bad-tools.json" norm '{"agentType":"developer","toolName":"view","toolArgs":{"path":"/p"}}')"
eq "a tools.json that is not JSON: the built-ins still map, the agent is kept" "Read developer" "$(jq -r '"\(.tool_name) \(.agent_type)"' <<<"$n")"
printf '{"tools":["bash"]}' > "$tmp/list-tools.json"
n="$(COPILOT_TOOLS_JSON="$tmp/list-tools.json" norm '{"agentType":"developer","toolName":"bash","toolArgs":"{}"}')"
eq "a tools.json whose .tools is a list: the built-ins still map" "Bash developer" "$(jq -r '"\(.tool_name) \(.agent_type)"' <<<"$n")"
rc=0; norm '["agentType"]' >/dev/null || rc=$?
eq "a Copilot-looking payload that is not an object: exit 3" 3 "$rc"
nojq="$(PATH="$tmp/empty" CLAUDE_PROJECT_DIR="$root" "$BASH" -c '. "'"$root"'/.claude/hooks/scripts/payload.sh"; hook_normalize_payload "{\"agentType\":\"developer\",\"toolName\":\"bash\"}" >/dev/null; echo "rc=$?"')"
eq "no jq, a call that names an agent: exit 3" rc=3 "$nojq"
nojq="$(PATH="$tmp/empty" CLAUDE_PROJECT_DIR="$root" "$BASH" -c '. "'"$root"'/.claude/hooks/scripts/payload.sh"; hook_normalize_payload "{\"toolName\":\"bash\"}" >/dev/null; echo "rc=$?"')"
eq "no jq, a root call with no agent and no KIT_AGENT: exit 0 (unfenced, as on Claude)" rc=0 "$nojq"
nojq="$(PATH="$tmp/empty" KIT_AGENT=developer CLAUDE_PROJECT_DIR="$root" "$BASH" -c '. "'"$root"'/.claude/hooks/scripts/payload.sh"; hook_normalize_payload "{\"toolName\":\"bash\"}" >/dev/null; echo "rc=$?"')"
eq "no jq, a root call under KIT_AGENT: exit 3" rc=3 "$nojq"
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
eq "scope-guard (Copilot root session, no KIT_AGENT): not fenced, as a Claude root session" "" "$out"
# The three ways a Copilot agent reaches the guard; each must fence an out-of-scope write.
fence="$root/.claude/hooks/agent-scopes.json"
out="$(run_sg "{\"agentType\":\"developer\",\"agentId\":\"a1\",\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (camelCase preToolUse, subagent agentType): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "$(jq -cn --arg r "$root" --arg f "$fence" '{hook_event_name:"PreToolUse",agent_type:"developer",agent_id:"a1",cwd:$r,tool_name:"Write",tool_input:{file_path:$f}}')")"
eq "scope-guard (PascalCase PreToolUse, subagent agent_type): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(KIT_AGENT=developer run_sg "{\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (root session, agent from KIT_AGENT): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(SCOPE_GUARD_MAX_CMD=64 run_sg "$(jq -cn --arg r "$root" '{agentType:"developer",workingDirectory:$r,toolName:"bash",toolArgs:{command:("git status " + ("a" * 80))}}')")"
eq "scope-guard: a command over SCOPE_GUARD_MAX_CMD (64 here) is denied" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "$(jq -cn --arg r "$root" '{agent_type:"developer",tool_name:"Bash",cwd:$r,tool_input:{command:("git status " + ("a" * 16380))}}')")"
eq "scope-guard (Claude payload): a command over the default cap of 16384 is denied" deny "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "$(jq -cn --arg r "$root" '{agent_type:"developer",tool_name:"Bash",cwd:$r,tool_input:{command:("git status " + ("a" * 4000))}}')")"
eq "scope-guard (Claude payload): an allowed 4 KB command is still read and allowed" "" "$out"
# The fail-open holes the review found; each must now deny.
out="$(COPILOT_TOOLS_JSON="$tmp/bad-tools.json" run_sg "{\"agentType\":\"developer\",\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (tools.json not JSON): a fenced write is still denied" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg '["agentType","developer"]')"
eq "scope-guard (unreadable Copilot payload naming an agent): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "$(jq -cn --arg r "$root" '{agent_type:"developer",cwd:$r,tool_name:"bash",tool_input:{command:"./gradlew test"}}')")"
eq "scope-guard (native bash in tool_name): the allowlist applies" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(KIT_AGENT=developer run_sg "{\"agentId\":\"s1\",\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (untyped subagent of a fenced root): fenced as the root" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(KIT_AGENT=developer run_sg "{\"agentType\":\"explore\",\"agentId\":\"s1\",\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$fence\"}}")"
eq "scope-guard (built-in subagent with no policy, fenced root): fenced as the root" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "{\"agentType\":\"explore\",\"agentId\":\"s1\",\"workingDirectory\":\"$root\",\"toolName\":\"create\",\"toolArgs\":{\"path\":\"$tmp/x\"}}")"
eq "scope-guard (subagent with no policy, no fenced root): not fenced" "" "$out"
for t in apply_patch write_bash some_new_tool; do
  out="$(run_sg "{\"agentType\":\"developer\",\"workingDirectory\":\"$root\",\"toolName\":\"$t\",\"toolArgs\":{}}")"
  eq "scope-guard (fenced agent, Copilot tool $t the guard cannot read): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
done
for t in report_intent read_bash task; do
  out="$(run_sg "{\"agentType\":\"developer\",\"workingDirectory\":\"$root\",\"toolName\":\"$t\",\"toolArgs\":{}}")"
  eq "scope-guard (fenced agent, harmless Copilot tool $t): no objection" "" "$out"
done
mkdir -p "$tmp/proj/.github"; printf '{"mcpServers":{"codegraph":{},"contract-api":{}}}' > "$tmp/proj/.github/mcp.json"
for t in codegraph-codegraph_explore contract-api/search; do
  out="$(env -u CLAUDE_SCOPE_POLICY CLAUDE_PROJECT_DIR="$tmp/proj" bash "$sg" PreToolUse <<<"{\"agentType\":\"developer\",\"toolName\":\"$t\",\"toolArgs\":{}}")"
  eq "scope-guard (fenced agent, tool $t of a configured MCP server): no objection" "" "$out"
done
out="$(env -u CLAUDE_SCOPE_POLICY CLAUDE_PROJECT_DIR="$tmp/proj" bash "$sg" PreToolUse <<<'{"agentType":"developer","toolName":"evil-server-x","toolArgs":{}}')"
eq "scope-guard (fenced agent, tool of an unconfigured server): deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
out="$(run_sg "$(jq -cn --arg r "$root" '{agent_type:"developer",cwd:$r,tool_name:"SomeFutureTool",tool_input:{}}')")"
eq "scope-guard (Claude payload, an unknown tool): still no objection (Claude unchanged)" "" "$out"
cl="$(jq -cn --arg r "$root" '{agent_type:"developer",tool_name:"Bash",cwd:$r,tool_input:{command:"./gradlew test"}}')"
eq "scope-guard (Claude payload): still denies" deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$(run_sg "$cl")")"

# --- rtk prefix: the fence judges the command rtk rewrote (one leading `rtk ` / `rtk proxy `, nothing else)
rtkcmd() { jq -r .tool_input.command <<<"$(norm "$1")"; }
cc() { jq -cn --arg c "$1" '{agent_type:"developer",tool_name:"Bash",tool_input:{command:$c}}'; }
cp() { jq -cn --arg c "$1" '{agentType:"developer",toolName:"bash",toolArgs:({command:$c}|tojson)}'; }
for shape in cc cp; do
  eq "rtk ($shape): a leading rtk is dropped" "git status" "$(rtkcmd "$($shape 'rtk git status')")"
  eq "rtk ($shape): rtk proxy is dropped too" "git log" "$(rtkcmd "$($shape 'rtk proxy git log')")"
  eq "rtk ($shape): the blanks around it go" "git diff" "$(rtkcmd "$($shape "  rtk   git diff")")"
  eq "rtk ($shape): only ONE rtk is dropped" "rtk git status" "$(rtkcmd "$($shape 'rtk rtk git status')")"
  eq "rtk ($shape): a bare rtk stays" "rtk" "$(rtkcmd "$($shape 'rtk')")"
  eq "rtk ($shape): rtk and a blank stays" "rtk " "$(rtkcmd "$($shape 'rtk ')")"
  eq "rtk ($shape): a bare rtk proxy stays" "rtk proxy" "$(rtkcmd "$($shape 'rtk proxy')")"
  eq "rtk ($shape): rtk in a later word stays" "git rtk status" "$(rtkcmd "$($shape 'git rtk status')")"
  eq "rtk ($shape): rtk in a later segment stays" "git status && rtk ls" "$(rtkcmd "$($shape 'git status && rtk ls')")"
  eq "rtk ($shape): a word that starts with rtk stays" "rtkx git status" "$(rtkcmd "$($shape 'rtkx git status')")"
  eq "rtk ($shape): rtk then a separator is not a command word" "rtk ; ls" "$(rtkcmd "$($shape 'rtk ; ls')")"
done
eq "rtk: a non-Bash tool is untouched" "rtk git status" "$(jq -r .tool_input.command <<<"$(norm '{"agent_type":"developer","tool_name":"Edit","tool_input":{"command":"rtk git status"}}')")"
sgdeny() { local o; o="$(run_sg "$1")"; [ -n "$o" ] && jq -r ".permissionDecision // \"none\"" <<<"$o" || echo none; }
for shape in cc cp; do
  eq "scope-guard ($shape): an allowed command through rtk is allowed" "none" "$(sgdeny "$($shape 'rtk git status')")"
  eq "scope-guard ($shape): rtk proxy of an allowed command is allowed" "none" "$(sgdeny "$($shape 'rtk proxy git log')")"
  eq "scope-guard ($shape): a denied command through rtk is denied" deny "$(sgdeny "$($shape 'rtk rm -rf /tmp/x')")"
  eq "scope-guard ($shape): a bare rtk is denied" deny "$(sgdeny "$($shape 'rtk')")"
  eq "scope-guard ($shape): a later rtk does not launder a denied command" deny "$(sgdeny "$($shape 'git status && rtk rm -rf /tmp/x')")"
  eq "scope-guard ($shape): rtk then a denied second segment is denied" deny "$(sgdeny "$($shape 'rtk git status && rm -rf /tmp/x')")"
done

# --- tool-advice with a Copilot payload: refuse mode denies a contract read for the developer
ta="$root/.claude/hooks/scripts/tool-advice.sh"
out="$(TOOL_ADVICE_CONTRACT=refuse CLAUDE_PROJECT_DIR=/work/wt bash "$ta" PreToolUse <<<'{"agentType":"developer","toolName":"view","toolArgs":{"path":"/work/wt/contract/dist/openapi.yaml"}}')"
eq "tool-advice (Copilot view of contract/, refuse): Copilot-shape deny" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
eq "tool-advice (Copilot view of contract/, refuse): Claude-shape deny" deny "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")"
out="$(CLAUDE_PROJECT_DIR=/work/wt bash "$ta" PreToolUse <<<'{"agentType":"developer","toolName":"bash","toolArgs":"{\"command\":\"grep -rn operationId contract/\"}"}')"
eq "tool-advice (Copilot bash grep of the contract, report): advice" advice "$(jq -r 'if .hookSpecificOutput.additionalContext then "advice" else "none" end' <<<"$out")"

# --- tools.json (the kit's real map): the names Copilot CLI 1.0.114 uses
tj="$root/.archon/copilot/tools.json"
eq "tools.json: powershell is a shell" Bash "$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"powershell","toolArgs":{"command":"ls"}}' | jq -r .tool_name)"
n="$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"grep","toolArgs":{"pattern":"X","paths":"src/main"}}')"
eq "tools.json: grep is Grep" Grep "$(jq -r .tool_name <<<"$n")"
eq "tools.json: grep's paths (one string) becomes path" src/main "$(jq -r .tool_input.path <<<"$n")"
n="$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"grep","toolArgs":{"pattern":"X","paths":["src/main"]}}')"
eq "tools.json: grep's paths as a list of one string becomes that string" src/main "$(jq -r .tool_input.path <<<"$n")"
n="$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"grep","toolArgs":{"pattern":"X","paths":["a","b"]}}')"
eq "tools.json: a list of two paths stays a list (the guards cannot read it, so they deny)" array "$(jq -r '.tool_input.path | type' <<<"$n")"
n="$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"grep","toolArgs":{"pattern":"X","paths":[7]}}')"
eq "tools.json: a list of one non-string stays a list" array "$(jq -r '.tool_input.path | type' <<<"$n")"
eq "tools.json: a grep path wins over paths" a "$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"grep","toolArgs":{"path":"a","paths":"b"}}' | jq -r .tool_input.path)"
eq "tools.json: web_fetch is WebFetch" WebFetch "$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"web_fetch","toolArgs":{"url":"u"}}' | jq -r .tool_name)"
eq "tools.json: apply_patch stays apply_patch (the scope guard denies it to a fenced agent)" apply_patch "$(COPILOT_TOOLS_JSON="$tj" norm '{"toolName":"apply_patch","toolArgs":{}}' | jq -r .tool_name)"

# --- .github/hooks/dispatch.sh with Copilot's batched preToolUse payload: {cwd, sessionId, toolCalls: [{id, name, args}]}
dp="$tmp/dproj"; mkdir -p "$dp/.github/hooks" "$dp/.claude/hooks/scripts" "$dp/.archon/copilot"
# `command cp`: cp is a payload builder above
command cp "$root/.github/hooks/dispatch.sh" "$dp/.github/hooks/"; command cp "$root/.claude/hooks/scripts/payload.sh" "$dp/.claude/hooks/scripts/"
command cp "$tj" "$dp/.archon/copilot/"
# a stub guard: logs each payload it gets (one line) and its arguments; denies --no-verify with exit 2, rm with JSON
cat > "$dp/.claude/hooks/scripts/stub.sh" <<'STUB'
in="$(cat)"; printf '%s\t%s\n' "$*" "$in" >> "$CLAUDE_PROJECT_DIR/seen"
case "$in" in
  *--no-verify*) echo "no --no-verify" >&2; exit 2 ;;
  *'"rm '*) printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no rm"}}' ;;
esac
exit 0
STUB
dsp() { # dsp <event> <matcher> <payload> [args]: out = dispatch.sh's stdout, seen = the payloads the stub got
  local e="$1" m="$2" p="$3"; shift 3; : > "$dp/seen"
  out="$(cd "$dp" && printf '%s' "$p" | CLAUDE_PROJECT_DIR="$dp" bash .github/hooks/dispatch.sh "$e" "$m" .claude/hooks/scripts/stub.sh "$@" 2>/dev/null)"
}
bt() { # bt <command>...: a batch of one skill call and one bash call per command
  jq -cn --args '{cwd:"/w",sessionId:"s",toolCalls:([{id:"k",name:"skill",args:{skill:"clean-code"}}] + [$ARGS.positional | to_entries[] | {id:"b\(.key)",name:"bash",args:{command:.value}}])}' "$@"; }
dsp PreToolUse 'Write|Edit|MultiEdit|NotebookEdit|Bash' "$(bt 'git status' 'git commit --no-verify -m x')" A1
eq "dispatch batch: a denied second call denies the batch" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
eq "dispatch batch: the reason names the call" "bash call: no --no-verify" "$(jq -r '.permissionDecisionReason' <<<"$out" | sed 's/ *$//')"
eq "dispatch batch: the deny has the Claude shape too" deny "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")"
eq "dispatch batch: the matcher skips the skill call, both bash calls run" 2 "$(wc -l < "$dp/seen" | tr -d ' ')"
eq "dispatch batch: each call is normalized on its own" "Bash Bash" "$(cut -f2 "$dp/seen" | jq -r .tool_name | paste -sd' ')"
eq "dispatch batch: each call keeps its command" "git status" "$(head -1 "$dp/seen" | cut -f2 | jq -r .tool_input.command)"
eq "dispatch batch: cwd and session come along" "/w s" "$(head -1 "$dp/seen" | cut -f2 | jq -r '"\(.cwd) \(.session_id)"')"
eq "dispatch batch: the script gets its own arguments only" A1 "$(head -1 "$dp/seen" | cut -f1)"
dsp PreToolUse 'Bash' "$(bt 'git commit --no-verify -m x' 'git status')"
eq "dispatch batch: a denied first call stops the batch" 1 "$(wc -l < "$dp/seen" | tr -d ' ')"
dsp PreToolUse 'Bash' "$(bt 'git status' 'rm -rf x')"
eq "dispatch batch: a JSON deny of one call denies the batch" "bash call: no rm" "$(jq -r '.permissionDecisionReason' <<<"$out")"
dsp PreToolUse 'Bash' "$(bt 'git status' 'git log')"
eq "dispatch batch: allowed calls print nothing" "" "$out"
dsp PreToolUse '*' "$(bt 'git status')"
eq "dispatch batch: matcher * runs every call" "Skill Bash" "$(cut -f2 "$dp/seen" | jq -r .tool_name | paste -sd' ')"
dsp PreToolUse 'Read|Grep|Glob' "$(jq -cn '{cwd:"/w",sessionId:"s",toolCalls:[{id:"a",name:"grep",args:{pattern:"X",paths:"src"}},{id:"b",name:"view",args:{path:"README.md"}}]}')"
eq "dispatch batch: grep and view calls are mapped through tools.json" "Grep:src Read:README.md" "$(cut -f2 "$dp/seen" | jq -r '"\(.tool_name):\(.tool_input.path // .tool_input.file_path)"' | paste -sd' ')"
dsp PreToolUse 'Bash' '{"cwd":"/w","sessionId":"s","toolCalls":[]}'
eq "dispatch batch: an empty toolCalls runs nothing" "0:" "$(wc -l < "$dp/seen" | tr -d ' '):$out"
dsp PreToolUse 'Bash' '{"cwd":"/w","sessionId":"s","toolCalls":"nope"}'
eq "dispatch batch: an unreadable batch is denied on PreToolUse" deny "$(jq -r '.permissionDecision // "none"' <<<"$out")"
dsp PostToolUse '' '{"cwd":"/w","sessionId":"s","toolCalls":"nope"}'
eq "dispatch batch: an unreadable batch is skipped on another event" "0:" "$(wc -l < "$dp/seen" | tr -d ' '):$out"
dsp PreToolUse 'Bash' '{"cwd":"/w","toolName":"bash","toolArgs":"{\"command\":\"git commit --no-verify\"}"}' A1 A2
eq "dispatch single call: still denied" "no --no-verify" "$(jq -r '.permissionDecisionReason' <<<"$out" | sed 's/ *$//')"
eq "dispatch single call: the script gets its arguments" "A1 A2" "$(cut -f1 "$dp/seen")"
dsp PreToolUse 'Bash' '{"cwd":"/w","toolName":"view","toolArgs":{"path":"x"}}'
eq "dispatch single call: the matcher still skips" 0 "$(wc -l < "$dp/seen" | tr -d ' ')"

echo "payload: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
