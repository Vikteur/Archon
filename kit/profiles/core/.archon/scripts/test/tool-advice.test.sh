#!/usr/bin/env bash
# Tests for .claude/hooks/scripts/tool-advice.sh: the contract and symbol advice per agent and in a run worktree (nodes,
# for a ready CLI or a listed server), on Read, Grep, Glob and Bash, report and refuse modes, and silence everywhere else. Usage: bash .archon/scripts/test/tool-advice.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
hook="${TOOL_ADVICE:-$root/.claude/hooks/scripts/tool-advice.sh}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }
wt=/work/run-wt

call() { # call <agent> <tool> <tool_input JSON> → what the hook prints
  jq -cn --arg a "$1" --arg t "$2" --argjson i "$3" '{agent_type:$a,tool_name:$t,tool_input:$i}' \
    | CLAUDE_PROJECT_DIR="$wt" bash "$hook" PreToolUse
}
kind() { # the hook's answer as one word: none, advice or deny
  local o; o="$(cat)"; [ -n "$o" ] || { echo none; return; }
  printf '%s' "$o" | jq -r 'if .hookSpecificOutput.permissionDecision == "deny" then "deny"
    elif .hookSpecificOutput.additionalContext then "advice" else "other" end'
}
case_() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "got $3, want $2"; fi; }

case_ "developer Read of contract/ is advised" advice "$(call developer Read "{\"file_path\":\"$wt/contract/dist/openapi.yaml\"}" | kind)"
case_ "analyst Grep in contract/ is advised" advice "$(call analyst Grep "{\"pattern\":\"signIn\",\"path\":\"$wt/contract\"}" | kind)"
case_ "test-writer Glob of contract/** without a path is advised" advice "$(call test-writer Glob '{"pattern":"contract/**/*.yaml"}' | kind)"
case_ "debugger Read of a relative contract path is advised" advice "$(call debugger Read '{"file_path":"contract/src/paths/auth.yaml"}' | kind)"
out="$(call developer Read "{\"file_path\":\"$wt/contract/dist/openapi.yaml\"}")"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("mcp__@@KIT_CONTRACT_SERVER_NAME@@__search") and contains("mcp__@@KIT_CONTRACT_SERVER_NAME@@__read")' >/dev/null \
  && ok "the advice names search and read" || bad "the advice names search and read" "$out"
printf '%s' "$out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null \
  && ok "report mode decides nothing, so the call runs as it would" || bad "report mode decides nothing" "$out"
case_ "TOOL_ADVICE_CONTRACT=refuse denies it" deny \
  "$(jq -cn --arg p "$wt/contract/x.yaml" '{agent_type:"developer",tool_name:"Read",tool_input:{file_path:$p}}' \
      | TOOL_ADVICE_CONTRACT=refuse CLAUDE_PROJECT_DIR="$wt" bash "$hook" PreToolUse | kind)"
case_ "the contract-agent is never covered" none "$(call contract-agent Read "{\"file_path\":\"$wt/contract/dist/openapi.yaml\"}" | kind)"
case_ "the main session (no agent_type) is never covered" none \
  "$(jq -cn '{tool_name:"Read",tool_input:{file_path:"contract/x.yaml"}}' | bash "$hook" PreToolUse | kind)"
case_ "a folder that only ends in contract is not the contract" none "$(call developer Read "{\"file_path\":\"$wt/docs/contract-notes/a.md\"}" | kind)"
case_ "a file outside contract/ is silent" none "$(call developer Read "{\"file_path\":\"$wt/docs/memory.md\"}" | kind)"

case_ "a CamelCase Grep over src/main is advised" advice "$(call developer Grep "{\"pattern\":\"SignInUseCase\",\"path\":\"$wt/identity-usecase/src/main\"}" | kind)"
case_ "Class.member over the whole checkout is advised" advice "$(call debugger Grep '{"pattern":"SignInUseCase.execute"}' | kind)"
case_ "a CamelCase Grep with a *.java glob is advised" advice "$(call analyst Grep "{\"pattern\":\"OrderId\",\"path\":\"$wt\",\"glob\":\"*.java\"}" | kind)"
case_ "a CamelCase Grep with type java is advised" advice "$(call test-writer Grep '{"pattern":"OrderId","path":"docs","type":"java"}' | kind)"
case_ "a string with spaces is silent" none "$(call developer Grep '{"pattern":"Sign In Use"}' | kind)"
case_ "a regex is silent" none "$(call developer Grep '{"pattern":"SignIn.*Case"}' | kind)"
out="$(call developer Grep '{"pattern":"ThrottledException|ThrottleKeyHasher|auth_attempts|proxy-address-forwarding"}')"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | startswith("tool-advice: ThrottledException, ThrottleKeyHasher are Java symbols") and contains("codegraph_explore")' >/dev/null \
  && ok "an alternation naming two symbols is advised codegraph_explore with them" || bad "an alternation naming two symbols" "$out"
case_ "one symbol in an alternation with a table name is silent" none "$(call developer Grep '{"pattern":"billing_number_sequences|BillingNumberSequence"}' | kind)"
case_ "a file name is not a symbol" none "$(call developer Grep '{"pattern":"SignInUseCase.java"}' | kind)"
case_ "a lowercase word is silent" none "$(call developer Grep '{"pattern":"signIn"}' | kind)"
case_ "a CamelCase Grep in docs/ is silent" none "$(call developer Grep "{\"pattern\":\"SignInUseCase\",\"path\":\"$wt/docs\"}" | kind)"
case_ "a CamelCase Grep in src/test is silent" none "$(call developer Grep "{\"pattern\":\"SignInUseCase\",\"path\":\"$wt/identity-usecase/src/test\"}" | kind)"
case_ "the reviewer is not covered" none "$(call reviewer Grep '{"pattern":"SignInUseCase"}' | kind)"
case_ "a Read of a Java file is silent" none "$(call developer Read "{\"file_path\":\"$wt/identity-usecase/src/main/java/A.java\"}" | kind)"

# Bash searches: the same two rules on each command's first pipeline stage.
case_ "Bash sed of openapi.yaml after a cd is advised" advice "$(call developer Bash '{"command":"cd contract && sed -n 160,235p dist/openapi.yaml"}' | kind)"
case_ "Bash grep for an operationId is advised" advice "$(call analyst Bash '{"command":"grep -n \"operationId: signIn$\" x.yaml"}' | kind)"
case_ "Bash contract read under refuse is denied" deny \
  "$(jq -cn '{agent_type:"developer",tool_name:"Bash",tool_input:{command:"cat contract/src/paths/auth.yaml"}}' \
      | TOOL_ADVICE_CONTRACT=refuse CLAUDE_PROJECT_DIR="$wt" bash "$hook" PreToolUse | kind)"
case_ "Bash grep for a symbol is advised" advice "$(call developer Bash '{"command":"cd x && grep -rn \"SessionCookies\" identity-adapter/src"}' | kind)"
out="$(call developer Bash '{"command":"grep -rn SignInUseCase.execute ."}')"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("SignInUseCase.execute is a Java symbol") and contains("Bash grep still runs")' >/dev/null \
  && ok "the Bash advice names the symbol and the program" || bad "the Bash advice names the symbol and the program" "$out"
out="$(call developer Bash '{"command":"grep -rnE \"AuthController|SignInAccountTest\" --include=*.java . | head"}')"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | startswith("tool-advice: AuthController, SignInAccountTest are Java symbols")' >/dev/null \
  && ok "a quoted | in a Bash grep splits nothing" || bad "a quoted | in a Bash grep splits nothing" "$out"
case_ "a quoted ; with cat after it starts no stage" none "$(call developer Bash '{"command":"echo \"a; cat contract/x.yaml\""}' | kind)"
case_ "Bash grep of a symbol in docs/ is silent" none "$(call developer Bash '{"command":"grep -rn SignInUseCase docs/rewrite"}' | kind)"
case_ "Bash grep of a symbol in src/test is silent" none "$(call developer Bash '{"command":"grep -rn SignInUseCase identity-usecase/src/test"}' | kind)"
case_ "Bash grep filtering another command's output is silent" none "$(call developer Bash '{"command":"git log --oneline | grep SignInUseCase"}' | kind)"
case_ "Bash grep of a lowercase word is silent" none "$(call developer Bash '{"command":"grep -rn signIn identity-adapter"}' | kind)"
case_ "Bash grep -l of a file name is silent" none "$(call developer Bash '{"command":"grep -rl SignInUseCase.java ."}' | kind)"
case_ "a Bash glob is not expanded" none "$(cd "$root" && call developer Bash '{"command":"grep -rn x *.md"}' | kind)"
case_ "Bash that only builds is silent" none "$(call developer Bash '{"command":"./gradlew :identity-adapter:test"}' | kind)"
case_ "the main session's Bash is never covered" none \
  "$(jq -cn '{tool_name:"Bash",tool_input:{command:"cat contract/dist/openapi.yaml"}}' | bash "$hook" PreToolUse | kind)"

# A build-feature run worktree: every session in it is covered, for the servers in its build-tools.json.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
home="$tmp/archon"; run="$home/workspaces/owner/repo/worktrees/build-feature-1"
mkdir -p "$run/.archon/mcp" "$tmp/elsewhere"
tools() { printf '%s' "$1" > "$run/.archon/mcp/build-tools.json"; }
node() { # node <agent_type or ""> <tool> <tool_input JSON> [cwd [project dir]]
  jq -cn --arg a "$1" --arg t "$2" --argjson i "$3" --arg c "${4:-$run}" \
    '{tool_name:$t,tool_input:$i,cwd:$c} + (if $a == "" then {} else {agent_type:$a} end)' \
    | ARCHON_HOME="$home" CLAUDE_PROJECT_DIR="${5:-$run}" bash "$hook" PreToolUse
}
tools '{"@@KIT_CONTRACT_SERVER_NAME@@":{},"codegraph":{}}'
case_ "a node (no agent_type) grepping a symbol is advised" advice "$(node "" Grep '{"pattern":"SignInUseCase"}' | kind)"
case_ "a node reading the contract is advised" advice "$(node "" Read "{\"file_path\":\"$run/contract/dist/openapi.yaml\"}" | kind)"
case_ "a node's Bash contract read is advised" advice "$(node "" Bash '{"command":"cd contract && sed -n 1,9p dist/openapi.yaml"}' | kind)"
case_ "a node's Bash symbol grep is advised" advice "$(node "" Bash '{"command":"grep -rn SessionCookies identity-adapter/src"}' | kind)"
case_ "a node from a subfolder of the worktree is advised" advice "$(node "" Grep '{"pattern":"SignInUseCase"}' "$run/identity-usecase" | kind)"
case_ "a subagent a node started (any type) is advised" advice "$(node Explore Grep '{"pattern":"SignInUseCase"}' | kind)"
case_ "the contract-agent stays uncovered in a run" none "$(node contract-agent Read "{\"file_path\":\"$run/contract/x.yaml\"}" | kind)"
case_ "a node's docs read is silent" none "$(node "" Read "{\"file_path\":\"$run/docs/memory.md\"}" | kind)"
case_ "a main session outside a run worktree is silent" none "$(node "" Grep '{"pattern":"SignInUseCase"}' "$tmp/elsewhere" "$tmp/elsewhere" | kind)"
tools '{"@@KIT_CONTRACT_SERVER_NAME@@":{}}'
case_ "codegraph down in the run: no symbol advice" none "$(node "" Grep '{"pattern":"SignInUseCase"}' | kind)"
case_ "@@KIT_CONTRACT_SERVER_NAME@@ up in the run: the contract advice stays" advice "$(node "" Read "{\"file_path\":\"$run/contract/x.yaml\"}" | kind)"
tools '{"codegraph":{}}'
case_ "@@KIT_CONTRACT_SERVER_NAME@@ down in the run: no contract advice" none "$(node "" Read "{\"file_path\":\"$run/contract/x.yaml\"}" | kind)"
tools '{"shop-api":{}}'
case_ "contract.server_name: its server up in the run keeps the advice" advice \
  "$(KIT_CONTRACT_SERVER_NAME=shop-api node "" Read "{\"file_path\":\"$run/contract/x.yaml\"}" | kind)"
case_ "contract.server_name: @@KIT_CONTRACT_SERVER_NAME@@ alone does not count for another server" none \
  "$(tools '{"@@KIT_CONTRACT_SERVER_NAME@@":{}}'; KIT_CONTRACT_SERVER_NAME=shop-api node "" Read "{\"file_path\":\"$run/contract/x.yaml\"}" | kind)"
out="$(KIT_CONTRACT_SERVER_NAME=shop-api call developer Read "{\"file_path\":\"$wt/contract/dist/openapi.yaml\"}")"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("mcp__shop-api__search") and (contains("@@KIT_CONTRACT_SERVER_NAME@@") | not)' >/dev/null \
  && ok "contract.server_name: the advice names the configured server" || bad "the advice names the configured server" "$out"
rm "$run/.archon/mcp/build-tools.json"
case_ "no build-tools.json (both down): silent" none "$(node "" Grep '{"pattern":"SignInUseCase"}' | kind)"
case_ "the four agents keep their advice outside a run" advice "$(call developer Grep '{"pattern":"SignInUseCase"}' | kind)"

# The CLIs answer without a server (an organization's MCP registry can block the servers): a ready CLI keeps its advice
# in a run with no build-tools.json, and the advice names the CLI first.
mkdir -p "$tmp/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/codegraph"; chmod +x "$tmp/bin/codegraph"
mkdir -p "$run/.codegraph"
out="$(PATH="$tmp/bin:$PATH" node "" Grep '{"pattern":"SignInUseCase"}')"
case_ "codegraph CLI ready, no server: symbol advice" advice "$(printf '%s' "$out" | kind)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("`codegraph callers <name>`") and contains("`codegraph node <name>`")' >/dev/null \
  && ok "the symbol advice names the codegraph CLI" || bad "the symbol advice names the codegraph CLI" "$out"
if PATH=/usr/bin:/bin command -v codegraph >/dev/null 2>&1; then ok "a .codegraph index without the codegraph command (skipped: codegraph is in /usr/bin)"
else case_ "a .codegraph index without the codegraph command: no symbol advice" none \
  "$(PATH=/usr/bin:/bin node "" Grep '{"pattern":"SignInUseCase"}' | kind)"; fi
rm -rf "$run/.codegraph"
case_ "the codegraph command without an index: no symbol advice" none "$(PATH="$tmp/bin:$PATH" node "" Grep '{"pattern":"SignInUseCase"}' | kind)"
mkdir -p "$run/scripts/contract-mcp"; : > "$run/scripts/contract-mcp/cli.mjs"
case_ "the contract CLI without its node_modules: no contract advice" none "$(node "" Read "{\"file_path\":\"$run/contract/x.yaml\"}" | kind)"
mkdir -p "$run/scripts/contract-mcp/node_modules"
out="$(node "" Read "{\"file_path\":\"$run/contract/x.yaml\"}")"
case_ "contract CLI ready, no server: contract advice" advice "$(printf '%s' "$out" | kind)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("`node scripts/contract-mcp/cli.mjs search <words>`") and contains("`node scripts/contract-mcp/cli.mjs read <operationId>`")' >/dev/null \
  && ok "the contract advice names the contract CLI" || bad "the contract advice names the contract CLI" "$out"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | (index("cli.mjs search") < index("mcp__"))' >/dev/null \
  && ok "the contract advice names the CLI before the MCP tool" || bad "the CLI before the MCP tool" "$out"
rm -rf "$run/scripts"

case_ "an unparseable payload is silent" none "$(printf 'not json' | bash "$hook" PreToolUse | kind)"
printf '{}' | bash "$hook" PreToolUse >/dev/null; case_ "it exits 0" 0 "$?"

echo "tool-advice: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
