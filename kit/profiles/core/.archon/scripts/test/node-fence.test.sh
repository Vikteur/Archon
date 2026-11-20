#!/usr/bin/env bash
# Fences per Archon workflow node, under Copilot CLI (owner decision 2026-11-20). Two guards, fed like Copilot feeds
# them, in a throwaway project that holds this checkout's hook files:
#   - .archon/copilot/hooks/run-guard.sh enforces the node's own denied_tools of the run's workflow (ARCHON_NODE_EXECUTION
#     names the node), anywhere, also outside a run worktree; an unknown node gets every node's denied_tools; a node
#     path, a workflow or a list it cannot read denies.
#   - .github/hooks/dispatch.sh names the node (KIT_NODE) and .claude/hooks/scripts/scope-guard.sh fences the call by
#     the agent .archon/copilot/node-fences.json maps the node to, with that node's additions only; an unknown node gets
#     the strictest common set; a node file it cannot read, or one that breaks its rules, denies.
# Outside a node nothing changes. Usage: bash .archon/scripts/test/node-fence.test.sh   (exit 0 = all pass; needs jq, node)
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }

# The project: the hook files of this checkout, and the shipped workflow and fences.
proj="$tmp/proj"
for f in .github/hooks/dispatch.sh .github/hooks/kit.json .claude/hooks/scripts/scope-guard.sh .claude/hooks/scripts/payload.sh \
  .claude/hooks/agent-scopes.json .archon/copilot/hooks/run-guard.sh .archon/copilot/tools.json \
  .archon/copilot/node-fences.json .archon/workflows/build-feature-copilot.yaml; do
  [ -f "$repo/$f" ] || { echo "FAIL: $f is missing from this checkout"; exit 1; }
  mkdir -p "$proj/$(dirname "$f")" && cp "$repo/$f" "$proj/$f"
done
ah="$tmp/archon-home"; wid="run1"
arts="$ah/workspaces/o/r/artifacts/runs/$wid"
mkdir -p "$arts"
node_exec() { printf '{"runId":"%s","path":"%s","invocation":1,"attempt":1}' "$wid" "$1"; }
out=""; rc=0

# ── run-guard: the denied_tools of the node ──────────────────────────────────────────────────────────────────────
# rg <node path|""> <payload json> [VAR=value...]: run-guard from the project (not a run worktree)
rg() {
  local n="$1" p="$2"; shift 2
  out="$(cd "$proj" && printf '%s' "$p" | env -u ARCHON_NODE_EXECUTION -u RUN_GUARD_WORKFLOW CLAUDE_PROJECT_DIR="$proj" \
    ARCHON_HOME="$ah" WORKFLOW_ID="$wid" ${n:+ARCHON_NODE_EXECUTION="$(node_exec "$n")"} "$@" bash "$proj/.archon/copilot/hooks/run-guard.sh" 2>/dev/null)"
  rc=$?
}
cp_bash() { jq -cn --arg c "$1" --arg d "$proj" '{toolName:"bash",toolArgs:{command:$c},cwd:$d}'; }
rg_case() { # rg_case <label> <want deny|allow> <node path> <command> [<reason text>]
  rg "$3" "$(cp_bash "$4")"
  local got=allow; [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && got=deny
  if [ "$got" != "$2" ]; then bad "$1" "got $got: $out"; return; fi
  if [ -n "${5:-}" ] && ! printf '%s' "$out" | grep -qF -- "$5"; then bad "$1" "reason: $out"; return; fi
  ok "$1"
}
rg_case "run-guard: plan may not run gradle (its denied_tools)" deny plan './gradlew test' 'node plan'
rg_case "run-guard: plan, gradle behind cd && is still met" deny plan 'cd app && ./gradlew test' 'Bash(*gradlew*)'
rg_case "run-guard: plan, a test script after ; is met" deny plan 'true; bash scripts/test/x.test.sh' 'Bash(bash *.test.sh*)'
rg_case "run-guard: plan may run git status" allow plan 'git status'
rg_case "run-guard: implement.build-step is node build-step: gradle allowed" allow implement.build-step './gradlew :app:test'
rg_case "run-guard: build-step, a commit with -n is denied outside a run worktree too" deny implement.build-step 'git commit -n -m x' 'node build-step'
rg_case "run-guard: ci-fix.fix may not run backlog task at all (its denied_tools)" deny ci-fix.fix 'BACKLOG_CWD=. backlog task edit 1' 'Bash(*backlog task*)'
rg_case "run-guard: explore declares no denied_tools" allow explore './gradlew test'
rg_case "run-guard: an unknown node gets every node's denied_tools" deny some-new-node './gradlew test' 'not in the workflow'
rg_case "run-guard: an unknown node may run what no node denies" allow some-new-node 'git status'
rg_case "run-guard: outside a node the node rules do not apply" allow "" './gradlew test'

rg 'bad"path' "$(cp_bash 'git status')"
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'node of this Archon run is not readable'; then ok "run-guard: an unreadable node path denies"; else bad "run-guard: an unreadable node path denies" "$out"; fi
rg plan "$(cp_bash 'git status')" RUN_GUARD_WORKFLOW="$tmp/none.yaml"
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'not readable'; then ok "run-guard: a missing workflow denies inside a node"; else bad "run-guard: a missing workflow denies inside a node" "$out"; fi
printf 'nodes:\n  - id: plan\n    denied_tools:\n      - Bash(*x*)\n' >"$tmp/block.yaml"
rg plan "$(cp_bash 'git status')" RUN_GUARD_WORKFLOW="$tmp/block.yaml"
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'not a flow list'; then ok "run-guard: a denied_tools list it cannot read denies"; else bad "run-guard: a denied_tools list it cannot read denies" "$out"; fi
rg plan 'not json'
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'not readable JSON'; then ok "run-guard: an unreadable payload denies inside a node"; else bad "run-guard: an unreadable payload denies inside a node" "$out"; fi
rg plan "$(jq -cn --arg d "$proj" '{cwd:$d,sessionId:"s",toolCalls:[{id:"1",name:"bash",args:{command:"git status"}},{id:"2",name:"bash",args:{command:"./gradlew build"}}]}')"
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'Bash(*gradlew*)'; then ok "run-guard: a batch with one denied call is denied"; else bad "run-guard: a batch with one denied call is denied" "$out"; fi

# The run's own workflow, from the snapshot Archon took (its manifest names it); text in a block scalar is not a rule.
snap="$ah/workspaces/o/r/workflow-source/runs/$wid"
mkdir -p "$snap/project/.archon/workflows"
printf '{"workflow_name":"other"}' >"$snap/manifest.json"
cat >"$snap/project/.archon/workflows/other.yaml" <<'EOF'
name: other
nodes:
  - id: plan
    prompt: |
      denied_tools: this is prompt text
    denied_tools: ["Bash(*npm*)"]
EOF
rg_case "run-guard: the snapshot of the run names its workflow (npm denied there)" deny plan 'npm test' 'other.yaml'
rg_case "run-guard: the snapshot workflow replaces the project one (gradle allowed there)" allow plan './gradlew test'
printf '{"workflow_name":"gone"}' >"$snap/manifest.json"
rg_case "run-guard: a snapshot without its workflow denies" deny plan 'git status' 'not in the snapshot'
mv "$snap" "$tmp/snap.off"

# Tool names match in any case: a node whose denied_tools hold Monitor may not call monitor.
printf 'nodes:\n  - id: plan\n    denied_tools: ["Monitor", "Bash(*gradlew*)"]\n  - id: explore\n' >"$tmp/mon.yaml"
for t in Monitor monitor MONITOR; do
  rg plan "$(jq -cn --arg t "$t" --arg d "$proj" '{toolName:$t,toolArgs:{},cwd:$d}')" RUN_GUARD_WORKFLOW="$tmp/mon.yaml"
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'hold Monitor'; then ok "run-guard: denied_tools Monitor denies $t"; else bad "run-guard: denied_tools Monitor denies $t" "$out"; fi
done
rg explore "$(jq -cn --arg d "$proj" '{toolName:"monitor",toolArgs:{},cwd:$d}')" RUN_GUARD_WORKFLOW="$tmp/mon.yaml"
if [ "$rc" -eq 0 ]; then ok "run-guard: a node that does not deny Monitor may call monitor"; else bad "run-guard: a node that does not deny Monitor may call monitor" "$out"; fi
# The hook folders: a node changes none of them, also outside a run worktree; reading them stays allowed.
rg_case "run-guard: a node may not redirect into a hook folder" deny implement.build-step 'echo x > .github/hooks/kit.json' 'hook folders'
rg_case "run-guard: a node may not sed -i a hook script" deny implement.build-step 'sed -i s/a/b/ .claude/hooks/scripts/scope-guard.sh' 'hook folders'
rg_case "run-guard: a node may not cp over the node fences" deny ci-fix.fix 'cp /tmp/x .archon/copilot/node-fences.json' 'hook folders'
rg_case "run-guard: a node may not rm the git hooks" deny review 'rm -rf .githooks' 'hook folders'
rg_case "run-guard: a node may read a hook folder" allow implement.build-step 'cat .github/hooks/kit.json'
rg_case "run-guard: outside a node and a run a hook folder edit passes" allow "" 'echo x > .github/hooks/kit.json'
rg plan "$(jq -cn --arg d "$proj" '{toolName:"create",toolArgs:{path:".claude/hooks/x.sh",file_text:"x"},cwd:$d}')"
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'hook folders'; then ok "run-guard: a node may not create a file in a hook folder"; else bad "run-guard: a node may not create a file in a hook folder" "$out"; fi

# ── scope-guard through dispatch.sh: the fence of the node's agent ─────────────────────────────────────────────────
# sg <node path|""> <matcher> <payload json> [extra script arg] [VAR=value...]: the hook's stdout as Copilot runs it
sg() {
  local n="$1" m="$2" p="$3" x="${4:-}"; shift 4 2>/dev/null || shift $#
  out="$(cd "$proj" && printf '%s' "$p" | env -u ARCHON_NODE_EXECUTION -u KIT_NODE -u KIT_AGENT -u CLAUDE_SCOPE_POLICY \
    -u CLAUDE_SCOPE_NODES CLAUDE_PROJECT_DIR="$proj" ARCHON_HOME="$ah" WORKFLOW_ID="$wid" \
    ${n:+ARCHON_NODE_EXECUTION="$(node_exec "$n")"} "$@" \
    bash "$proj/.github/hooks/dispatch.sh" PreToolUse "$m" .claude/hooks/scripts/scope-guard.sh PreToolUse $x 2>/dev/null)"
}
decision() { [ -n "$out" ] || { echo allow; return; }; printf '%s' "$out" | jq -r '.permissionDecision // "allow"'; }
why() { printf '%s' "$out" | jq -r '.permissionDecisionReason // ""'; }
sg_check() { # sg_check <label> <want> [<reason text>]
  local got; got="$(decision)"
  if [ "$got" != "$2" ]; then bad "$1" "got $got: $(why)"; return; fi
  if [ -n "${3:-}" ] && ! why | grep -qF -- "$3"; then bad "$1" "reason: $(why)"; return; fi
  ok "$1"
}
cmd() { # cmd <label> <want> <node path> <command> [<reason text>]
  sg "$3" 'Write|Edit|MultiEdit|NotebookEdit|Bash' "$(cp_bash "$4")" ""; sg_check "$1" "$2" "${5:-}"
}
put() { # put <label> <want> <node path> <path> [<reason text>]
  sg "$3" 'Write|Edit|MultiEdit|NotebookEdit|Bash' "$(jq -cn --arg f "$4" --arg d "$proj" '{toolName:"create",toolArgs:{path:$f,file_text:"x"},cwd:$d}')" ""
  sg_check "$1" "$2" "${5:-}"
}
cmd "plan: as analyst, git is not on its list" deny plan 'git status' 'analyst (node plan)'
cmd "plan: its node addition plan-spike.sh runs" allow plan 'bash .archon/scripts/plan-spike.sh --check'
cmd "plan: codegraph runs (the analyst list)" allow plan 'codegraph explore "Foo"'
put "plan: writes into the run's artifacts folder" allow plan "$arts/plan.md"
put "plan: may not write another run's artifacts" deny plan "$ah/workspaces/o/r/artifacts/runs/run2/plan.md"
put "plan: may not climb out of its artifacts folder" deny plan "$arts/../run2/plan.md"
put "plan: may not write source code" deny plan src/main/java/A.java 'analyst (node plan)'
put "explore: writes docs/ (the analyst fence)" allow explore docs/notes.md
cmd "write-tests (implement.write-tests): mkdir -p is its node addition" allow implement.write-tests 'mkdir -p app/src/test/java/x'
cmd "write-tests: a module test task is its node addition" allow implement.write-tests './gradlew :app:test --tests X'
put "write-tests: writes a test" allow implement.write-tests app/src/test/java/x/ATest.java
put "write-tests: may not write production code" deny implement.write-tests app/src/main/java/x/A.java 'test-writer (node write-tests)'
cmd "build-step: affected-check with its env and a run file, as the prompt says" allow implement.build-step \
  "AFFECTED_NO_SYNC=1 AFFECTED_BASE=\"\$(cat \"$arts/step-base.sha\")\" bash .claude/scripts/affected-check.sh"
cmd "build-step: a substitution of a file outside the run is still denied" deny implement.build-step \
  'AFFECTED_BASE="$(cat /etc/hostname)" bash .claude/scripts/affected-check.sh' 'command substitution'
cmd "build-step: an env name not on its list is denied" deny implement.build-step 'PATH=/tmp bash .claude/scripts/affected-check.sh'
cmd "build-step: an env prefix does not unlock a command off the list" deny implement.build-step 'AFFECTED_BASE=x ./gradlew test'
cmd "build-step: the full suite stays off the developer list" deny implement.build-step './gradlew test' 'developer (node build-step)'
put "build-step: may write any project path (the developer fence)" allow implement.build-step app/src/main/java/x/A.java
put "build-step: may not change the node fences" deny implement.build-step .archon/copilot/node-fences.json 'node fences'
put "build-step: may not change the agent fences" deny implement.build-step .claude/hooks/agent-scopes.json 'agent fences'
put "build-step: may not write .github/hooks (the developer fence holds the hook folders out)" deny implement.build-step .github/hooks/kit.json 'hook folder'
put "build-step: may not write .claude/hooks" deny implement.build-step .claude/hooks/scripts/scope-guard.sh 'hook folder'
put "build-step: may not write .archon/copilot" deny implement.build-step .archon/copilot/tools.json 'hook folder'
put "build-step: may not write .archon/githooks" deny implement.build-step .archon/githooks/pre-commit 'hook folder'
put "build-step: may not write .githooks, in another case" deny implement.build-step .GitHooks/commit-msg 'hook folder'
put "build-step: may not write .git/hooks through ./ and //" deny implement.build-step './.git//hooks/pre-push' 'hook folder'
put "build-step: may not write a hook folder by its absolute path" deny implement.build-step "$proj/.github/hooks/x.json" 'hook folder'
put "build-step: a folder called hooks elsewhere is writable" allow implement.build-step app/src/main/java/hooks/A.java
cmd "review: commits a fix (its node addition)" allow review 'git commit -m "fix: x"'
cmd "review: may not push (not on reviewer or node list)" deny review 'git push' 'reviewer (node review)'
put "review: writes src/ (its node addition)" allow review app/src/main/java/x/A.java
put "review: may not write the build file" deny review build.gradle.kts
cmd "pr-text: reads git log (its node addition)" allow pr-text 'git log --oneline -5'
put "pr-text: may not write the repo" deny pr-text README.md 'reviewer (node pr-text)'
cmd "diagnose (ci-fix.diagnose): git log is on the debugger list" allow ci-fix.diagnose 'git log -3'
put "diagnose: writes the run's artifacts folder" allow ci-fix.diagnose "$arts/ci-diagnosis.md"
put "diagnose: may not write code" deny ci-fix.diagnose app/src/main/java/x/A.java 'debugger (node diagnose)'
cmd "fix (ci-fix.fix): mkdir -p is its node addition" allow ci-fix.fix 'mkdir -p app/src/test'
# Copilot's grep sends its folder as `paths`, a string or a list (seen in a real run): a list of one is read as that
# path; a longer list cannot be read as one path, so it is still denied.
srch() { # srch <label> <want> <node path> <paths json> [<reason text>]
  sg "$3" 'Read|Grep|Glob' "$(jq -cn --argjson p "$4" --arg d "$proj" '{toolName:"grep",toolArgs:{pattern:"X",paths:$p},cwd:$d}')" ""
  sg_check "$1" "$2" "${5:-}"
}
srch "explore: a grep with paths as a list of one folder runs" allow explore '["src/main"]'
srch "explore: a grep with paths as one string runs" allow explore '"src/main"'
srch "explore: a grep with a list of two paths is still denied" deny explore '["src/main","docs"]'
cmd "unknown node: git is outside the strictest common set" deny some-new-node 'git status' 'strictest common set'
cmd "unknown node: codegraph is in every node's list" allow some-new-node 'codegraph node Foo'
put "unknown node: writes only the run's artifacts folder" allow some-new-node "$arts/x.md"
put "unknown node: may not write docs/ (not every node may)" deny some-new-node docs/x.md
cmd "a node path dispatch.sh cannot read gets the strictest set" deny 'implement.bad node' 'git status' 'node ? '
cmd "outside a node nothing is fenced" allow "" './gradlew test'

sg plan '*' "$(jq -cn --arg d "$proj" '{toolName:"apply_patch",toolArgs:{input:"x"},cwd:$d}')" --other-tools
sg_check "a tool no named entry checks (apply_patch) is denied inside a node" deny "Copilot tool 'apply_patch'"
sg "" '*' "$(jq -cn --arg d "$proj" '{toolName:"apply_patch",toolArgs:{input:"x"},cwd:$d}')" --other-tools
sg_check "the --other-tools entry does nothing outside a node" allow
if jq -e '[.hooks.preToolUse[].bash] | any(test("dispatch.sh PreToolUse .\\*. .claude/hooks/scripts/scope-guard.sh PreToolUse --other-tools"))' "$proj/.github/hooks/kit.json" >/dev/null; then
  ok "kit.json registers the --other-tools scope-guard entry"; else bad "kit.json registers the --other-tools scope-guard entry"; fi
sg implement.build-step 'Write|Edit|MultiEdit|NotebookEdit|Bash' "$(jq -cn --arg d "$proj" '{toolName:"bash",toolArgs:{command:"git commit -m x"},agentType:"reviewer",cwd:$d}')" ""
sg_check "a reviewer subagent inside build-step keeps its own fence (no commit)" deny "agent 'reviewer'"

# The node file: missing, not JSON, or breaking a rule denies every call inside a node.
nf_case() { # nf_case <label> <file content|-> <reason text>
  local f="$tmp/nf.json"
  if [ "$2" = "-" ]; then f="$tmp/missing.json"; else printf '%s' "$2" >"$f"; fi
  sg plan 'Write|Edit|MultiEdit|NotebookEdit|Bash' "$(cp_bash 'codegraph explore x')" "" CLAUDE_SCOPE_NODES="$f"
  sg_check "$1" deny "$3"
}
nf_case "node file missing" - 'missing or empty'
nf_case "node file not JSON" 'nope' 'not valid JSON'
nf_case "node file with another top-level key" '{"nodes":{"plan":{"agent":"analyst"}},"agents":{}}' 'may hold only'
nf_case "node mapped to an agent the fences do not hold" '{"nodes":{"plan":{"agent":"nobody"}}}' 'must name an agent'
nf_case "node command entry that is an interpreter" '{"nodes":{"plan":{"agent":"analyst","commandAllowlist":["bash -c"]}}}' 'bare interpreter'
nf_case "node command entry with a shell operator" '{"nodes":{"plan":{"agent":"analyst","commandAllowlist":["ls; rm"]}}}' 'shell operator'
nf_case "node path outside the project" '{"nodes":{"plan":{"agent":"analyst","allowedFilePaths":["/etc/"]}}}' 'not a path inside the project'
nf_case "node path with .." '{"nodes":{"plan":{"agent":"analyst","allowedFilePaths":["docs/../x"]}}}' 'not a path inside the project'
nf_case "node env name that changes the shell" '{"nodes":{"plan":{"agent":"analyst","env":["PATH"]}}}' 'changes how a shell'
nf_case "node env name of git" '{"nodes":{"plan":{"agent":"analyst","env":["GIT_DIR"]}}}' 'changes how a shell'
nf_case "node with an unknown key" '{"nodes":{"plan":{"agent":"analyst","readPaths":[]}}}' 'may set only'

# A Claude payload with a tool name in another case meets the check of its name (it was let through before); a
# Copilot name in another case stays denied (its arguments are not mapped).
for t in WRITE Edit EDIT; do
  out="$(cd "$proj/.claude/hooks" && jq -cn --arg t "$t" --arg d "$proj" '{tool_name:$t,tool_input:{file_path:"src/A.java"},agent_type:"analyst",cwd:$d}' \
    | env -u KIT_NODE -u ARCHON_NODE_EXECUTION CLAUDE_PROJECT_DIR="$proj" bash "$proj/.claude/hooks/scripts/scope-guard.sh" PreToolUse 2>/dev/null)"
  sg_check "scope-guard: a Claude $t of src/ by the analyst meets the write fence" deny 'may only write under'
done
out="$(cd "$proj/.claude/hooks" && jq -cn --arg d "$proj" '{tool_name:"BASH",tool_input:{command:"rm -rf x"},agent_type:"analyst",cwd:$d}' \
  | env -u KIT_NODE -u ARCHON_NODE_EXECUTION CLAUDE_PROJECT_DIR="$proj" bash "$proj/.claude/hooks/scripts/scope-guard.sh" PreToolUse 2>/dev/null)"
sg_check "scope-guard: a Claude BASH by the analyst meets its command list" deny 'may not run'
out="$(cd "$proj/.claude/hooks" && jq -cn --arg d "$proj" '{toolName:"Create",toolArgs:{path:"src/A.java"},agentType:"analyst",cwd:$d}' \
  | env -u KIT_NODE -u ARCHON_NODE_EXECUTION CLAUDE_PROJECT_DIR="$proj" bash "$proj/.claude/hooks/scripts/scope-guard.sh" PreToolUse 2>/dev/null)"
sg_check "scope-guard: a Copilot Create (any case, mapped through tools.json) meets the write fence" deny 'may only write under'
out="$(cd "$proj/.claude/hooks" && jq -cn --arg d "$proj" '{toolName:"Apply_Patch",toolArgs:{input:"x"},agentType:"analyst",cwd:$d}' \
  | env -u KIT_NODE -u ARCHON_NODE_EXECUTION CLAUDE_PROJECT_DIR="$proj" bash "$proj/.claude/hooks/scripts/scope-guard.sh" PreToolUse 2>/dev/null)"
sg_check "scope-guard: a Copilot tool it cannot read stays denied in any case" deny "Copilot tool"

echo "node-fence: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
