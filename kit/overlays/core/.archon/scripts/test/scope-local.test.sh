#!/usr/bin/env bash
# scope-guard.sh + .claude/hooks/agent-scopes.local.json: the project may only ADD command prefixes to the agents the
# kit's agent-scopes.json fences. Adding a prefix works and keeps the kit's list; a file that would remove or replace an
# entry, change another fence, add an agent, or that is malformed is refused, and then every call of a fenced agent is
# denied with the reason. Each case writes its own policy in a throwaway folder; nothing reads this checkout's fences.
# Usage: bash .archon/scripts/test/scope-local.test.sh   (exit 0 = all pass; needs jq)
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
sg="$root/.claude/hooks/scripts/scope-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }

base="$tmp/agent-scopes.json"
cat > "$base" << 'EOF'
{"agents": {
  "builder": {"allowedFilePaths": ["src/"], "commandAllowlist": ["git status", "./gradlew test"]},
  "reader": {"allowedFilePaths": []}
}}
EOF
loc="$tmp/agent-scopes.local.json"
out=""
# sg_call <agent|""> <tool> <tool_input json> [<policy file>]: the hook's stdout for that call
sg_call() {
  jq -cn --arg a "$1" --arg t "$2" --argjson i "$3" --arg r "$tmp" \
    '(if $a == "" then {} else {agent_type:$a} end) + {tool_name:$t,cwd:$r,tool_input:$i}' \
    | CLAUDE_PROJECT_DIR="$tmp" CLAUDE_SCOPE_POLICY="${4:-$base}" CLAUDE_SCOPE_LOCAL="$loc" bash "$sg" PreToolUse
}
decision() { [ -n "$out" ] || { echo none; return; }; printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; }
# cmd_case <label> <want> <agent> <command>: run the command as the agent (out stays set for said) and check the decision
cmd_case() { out="$(sg_call "$3" Bash "$(jq -cn --arg c "$4" '{command:$c}')")"; case_ "$1" "$2" "$(decision)"; }
why() { printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
case_() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "decision=$3, want $2"; fi; }
said() { # said <label> <text>: the last decision's reason holds the text
  if why | grep -qF -- "$2"; then ok "$1"; else bad "$1" "reason: $(why)"; fi
}

# 1. Without a local file the kit's lists hold.
rm -f "$loc"
cmd_case "1 the kit's entry runs" none builder 'git status'
cmd_case "1 a command outside the kit's list is denied" deny builder './gradlew build'

# 2. Adding a prefix works, and the kit's entries stay.
echo '{"_comment": "ours", "agents": {"builder": {"commandAllowlist": ["./gradlew build", "node scripts/x.mjs"]}}}' > "$loc"
cmd_case "2 an added prefix runs" none builder './gradlew build --scan'
cmd_case "2 an added script for an interpreter runs" none builder 'node scripts/x.mjs --check'
cmd_case "2 the kit's entries stay" none builder 'git status'
cmd_case "2 a command in neither list is still denied" deny builder 'make'
cmd_case "2 the addition reaches only that agent" deny reader './gradlew build'
echo '{"agents": {"reader": {"commandAllowlist": ["make lint"]}}}' > "$loc"
cmd_case "2 an agent without a command list can be given one" none reader 'make lint'

# 3. Removing an entry is refused: no form of the file takes one out of the kit's list.
echo '{"agents": {"builder": {"commandAllowlist": ["./gradlew build"]}}}' > "$loc"
cmd_case "3 a local list without a kit entry does not remove it" none builder 'git status'
for shape in '"commandAllowlist": [], "remove": ["git status"]' '"commandDenylist": ["git status"]'; do
  echo "{\"agents\": {\"builder\": {$shape}}}" > "$loc"
  cmd_case "3 a removal ($shape) is refused: even the kit's entry is denied" deny builder 'git status'
  said "3 ... and the reason says only commandAllowlist may be set" 'may set only commandAllowlist'
done
echo '{"agents": {"builder": {"commandAllowlist": null}}}' > "$loc"
cmd_case "3 a null list is refused" deny builder 'git status'
said "3 ... as not a list" 'must be a list of command prefixes'

# 4. No other fence changes here.
echo '{"agents": {"builder": {"allowedFilePaths": ["/"]}}}' > "$loc"
out="$(sg_call builder Write '{"file_path":"other/a.txt"}')"
case_ "4 widening the write fence is refused" deny "$(decision)"
said "4 ... and the reason names the key" 'not "allowedFilePaths"'
echo '{"agents": {}, "defaults": {"commandAllowlist": ["make"]}}' > "$loc"
cmd_case "4 another top-level key is refused" deny builder 'git status'
said "4 ... and the reason names it" 'not "defaults"'

# 5. Adding an agent is refused.
echo '{"agents": {"stranger": {"commandAllowlist": ["make"]}}}' > "$loc"
cmd_case "5 a new agent is refused: the fenced agents are denied" deny builder 'git status'
said "5 ... and the reason names the agent" 'adds the agent "stranger"'
cmd_case "5 the unfenced agent itself is still not this hook's business" none stranger 'make'
cmd_case "5 a call outside any agent is never touched" none '' 'make'

# 6. A malformed file is a deny with a reason.
printf '{"agents": {"builder": ' > "$loc"
cmd_case "6 malformed JSON denies a fenced agent" deny builder 'git status'
said "6 ... with the reason" 'agent-scopes.local.json is refused'
said "6 ... that says why" 'it is not valid JSON'
out="$(sg_call builder Read '{"file_path":"src/a.txt"}')"
case_ "6 ... on every tool, not only Bash" deny "$(decision)"
echo '[]' > "$loc"
cmd_case "6 a file that is not an object is refused" deny builder 'git status'
said "6 ... as not an object" 'not a JSON object'

# 7. An entry that would let any command through is refused.
for entry in '' '   ' 'git status; rm -rf x' 'git status && make' 'echo $(id)' 'env' 'xargs rm' 'sudo make' \
  'bash' 'bash -c' 'sh -c' 'node' 'node -e' 'python3 -c' '-c'; do
  jq -cn --arg e "$entry" '{agents: {builder: {commandAllowlist: [$e]}}}' > "$loc"
  cmd_case "7 the entry '$entry' is refused" deny builder 'git status'
done
echo '{"agents": {"builder": {"commandAllowlist": [1]}}}' > "$loc"
cmd_case "7 an entry that is not a string is refused" deny builder 'git status'

# 8. No agent may write the file, also one whose writes are not fenced.
rm -f "$loc"
echo '{"agents": {"free": {"commandAllowlist": ["git status"]}}}' > "$tmp/free.json"
out="$(sg_call free Write "$(jq -cn --arg p "$tmp/.claude/hooks/agent-scopes.local.json" '{file_path:$p}')" "$tmp/free.json")"
case_ "8 an agent may not write agent-scopes.local.json" deny "$(decision)"

# 9. Where the project keeps it: beside agent-scopes.json, read when no test names a policy.
proj="$tmp/proj"
mkdir -p "$proj/.claude/hooks"
cp -R "$root/.claude/hooks/scripts" "$proj/.claude/hooks/"
cp "$base" "$proj/.claude/hooks/agent-scopes.json"
echo '{"agents": {"builder": {"commandAllowlist": ["./gradlew build"]}}}' > "$proj/.claude/hooks/agent-scopes.local.json"
run_proj() {
  jq -cn --arg c "$1" --arg r "$proj" '{agent_type:"builder",tool_name:"Bash",cwd:$r,tool_input:{command:$c}}' \
    | env -u CLAUDE_SCOPE_POLICY -u CLAUDE_SCOPE_LOCAL CLAUDE_PROJECT_DIR="$proj" bash "$proj/.claude/hooks/scripts/scope-guard.sh" PreToolUse
}
out="$(run_proj './gradlew build')"
case_ "9 the project's file beside agent-scopes.json is read" none "$(decision)"
out="$(run_proj 'make')"
case_ "9 ... and adds only what it lists" deny "$(decision)"
out="$(jq -cn --arg r "$proj" '{agent_type:"builder",tool_name:"Bash",cwd:$r,tool_input:{command:"./gradlew build"}}' \
  | CLAUDE_PROJECT_DIR="$proj" CLAUDE_SCOPE_POLICY="$proj/.claude/hooks/agent-scopes.json" bash "$proj/.claude/hooks/scripts/scope-guard.sh" PreToolUse)"
case_ "9 a suite that names its policy is not changed by the project's file" deny "$(decision)"

echo "scope-local tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
