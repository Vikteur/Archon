#!/usr/bin/env bash
# Tests for .archon/scripts/mcp-use-check.js against fixture run logs under a throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/mcp-use-check.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/mcp-use-check.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
run=0123456789abcdef0123456789abcdef
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
art="$root/artifacts"
md="$art/mcp-use.md"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$md" 2>/dev/null; fi
}
row() { grep "^| $1 |" "$md"; }
fresh() { rm -rf "$art" "$logs"; mkdir -p "$art" "$logs"; : > "$logs/$run.jsonl"; }
status() { echo "mcp: @@KIT_CONTRACT_SERVER_NAME@@ $1, codegraph $2" > "$art/mcp-status.txt"; }
call() { # call <step> <tool name> <rawInput json>
  printf '{"type":"provider_event","step":"%s","event":{"type":"tool_call","name":"%s","rawInput":%s}}\n' "$1" "$2" "$3" >> "$logs/$run.jsonl"
}
times() { local i; for i in $(seq "$1"); do call "$2" "$3" "$4"; done; }
gate() { node "$script" "$art" "$run" "$@" > "$root/out" 2> "$root/err"; }

# 1. explore greps the code 8 times and never asks CodeGraph: warned; the threshold is 8.
fresh; status up up
times 8 explore Grep '{"pattern":"SignInUseCase","path":"identity-usecase/src/main"}'
gate; rc=$?
check "1 exit 0 in report mode" "$rc"
check "1 explore warned" $(row explore | grep -qF 'WARN: searched or read code by hand 8 times (threshold 8) and never asked CodeGraph'; echo $?)
check "1 the counts" $(row explore | grep -qF '| explore | 0 | 0 | 8 | 0 | 0 | 0 | 0 |'; echo $?)
check "1 stderr names the node" $(grep -qF 'mcp-use-check: explore: WARN' "$root/err"; echo $?)
check "1 stdout counts the warned nodes" $(grep -qx 'mcp-use-check: 1 of 2 nodes warned' "$root/out"; echo $?)
check "1 plan without calls" $(row plan | grep -qF 'no tool calls in the log'; echo $?)
gate --strict; check "1 --strict exits 1 on a warning" $([ $? -eq 1 ]; echo $?)

# 2. 7 greps stay under explore's threshold; one CodeGraph call clears any number of them.
fresh; status up up
times 7 explore Grep '{"pattern":"X"}'
gate; check "2 under the threshold: ok" $(row explore | grep -qF '| ok |'; echo $?)
times 5 explore Grep '{"pattern":"X"}'
call explore mcp__codegraph__codegraph_explore '{"query":"X"}'
gate; check "2 a CodeGraph call: ok" $(row explore | grep -qF '| explore | 0 | 1 | 12 |' && row explore | grep -qF '| ok |'; echo $?)
gate --strict; check "2 --strict exits 0 with no warning" $?

# 3. plan: a threshold of 5, Bash searches count by their first stage, whole Java reads count, docs do not.
fresh; status up up
call plan Bash '{"command":"cd x && grep -rn \"SessionCookies\" identity-adapter/src"}'
call plan Bash '{"command":"sed -n 1,40p identity-domain/src/main/java/A.java; cat B.java | head -5"}'
call plan Bash '{"command":"git log --oneline | grep fix"}'
call plan Read '{"file_path":"/w/worktrees/run1/identity-domain/src/main/java/C.java"}'
call plan Read '{"file_path":"D.java","offset":10,"limit":20}'
call plan Bash '{"command":"sed -n 10,40p docs/memory.md; cat \"$ARTIFACTS_DIR/explore.md\""}'
call plan Grep '{"pattern":"PIN-10","path":"docs/rewrite"}'
call plan Glob '{"pattern":"**/*.md"}'
gate; check "3 four hand-work calls: under plan's 5" $(row plan | grep -qF '| plan | 0 | 0 | 0 | 0 | 3 | 0 | 1 | ok |'; echo $?)
call plan Bash '{"command":"find . -name \"*Mapper.java\""}'
gate; check "3 five: plan warned" $(row plan | grep -qF 'searched or read code by hand 5 times (threshold 5)'; echo $?)

# 4. The contract read by hand: Read, Grep and Bash under contract/, openapi.yaml or an operationId; @@KIT_CONTRACT_SERVER_NAME@@ clears it.
fresh; status up up
call plan Read '{"file_path":"/w/worktrees/run1/contract/dist/openapi.yaml","offset":100,"limit":50}'
call plan Grep '{"pattern":"signIn","path":"contract/src"}'
call plan Bash '{"command":"cd contract && sed -n 160,235p dist/openapi.yaml"}'
call plan Bash '{"command":"grep -n \"operationId: signIn$\" x.yaml"}'
call plan Read '{"file_path":"docs/contract-notes/x.md"}'
gate; check "4 four contract reads, warned" $(row plan | grep -qF '| plan | 0 | 0 | 0 | 0 | 0 | 4 | 0 | WARN: read the contract by hand 4 times and never asked @@KIT_CONTRACT_SERVER_NAME@@ |'; echo $?)
call plan mcp__@@KIT_CONTRACT_SERVER_NAME@@__schema '{"name":"signInRequest"}'
gate; check "4 a @@KIT_CONTRACT_SERVER_NAME@@ call: ok" $(row plan | grep -qF '| plan | 1 | 0 |' && row plan | grep -qF '| ok |'; echo $?)

# 5. A server that was down skips its rule; no status file judges nothing.
fresh; status up down
times 9 explore Grep '{"pattern":"X"}'
call explore Read '{"file_path":"contract/dist/openapi.yaml"}'
gate; check "5 codegraph down: no hand-work warning, the contract one stays" $(row explore | grep -qF 'WARN: read the contract' && ! row explore | grep -qF 'never asked CodeGraph'; echo $?)
check "5 the servers line" $(grep -qx 'Servers: @@KIT_CONTRACT_SERVER_NAME@@ up, codegraph down.' "$md"; echo $?)
rm "$art/mcp-status.txt"
gate; check "5 no status: not judged" $(row explore | grep -qF 'not judged: no MCP status for this run' && grep -qx 'Servers: no MCP status for this run.' "$md"; echo $?)

# 5b. contract.server_name names the contract server: its calls count, the status line and the header name it.
fresh; echo "mcp: contract-api up, codegraph up" > "$art/mcp-status.txt"
call plan Read '{"file_path":"contract/dist/openapi.yaml"}'
call plan mcp__contract-api__read '{"operationId":"x"}'
KIT_CONTRACT_SERVER_NAME=contract-api gate
check "5b a configured server's call counts" $(row plan | grep -qF '| plan | 1 | 0 |' && row plan | grep -qF '| ok |'; echo $?)
check "5b the servers line and header name it" $(grep -qx 'Servers: contract-api up, codegraph up.' "$md" && grep -qF '| Node | contract-api | codegraph |' "$md"; echo $?)

# 5c. The shell fallback counts: the codegraph CLI (after rtk or rtk proxy) and the contract server's cli.mjs, also the
# kit's renamed form; other codegraph subcommands, other scripts and a mention inside an argument do not.
fresh; status up up
call plan Bash '{"command":"codegraph explore \"SignInUseCase\""}'
call plan Bash '{"command":"rtk codegraph node SignInUseCase"}'
call plan Bash '{"command":"rtk proxy codegraph callers X && rtk proxy codegraph impact X"}'
call plan Bash '{"command":"codegraph status"}'
call plan Bash '{"command":"echo codegraph explore X"}'
call plan Bash '{"command":"node scripts/contract-mcp/cli.mjs read signIn"}'
call plan Bash '{"command":"rtk node scripts/contract-mcp/cli.mjs where --status live"}'
call plan Bash '{"command":"node scripts/contract-mcp/server.mjs"}'
gate; check "5c the CLI calls count as codegraph and server use" $(row plan | grep -qF '| plan | 2 | 4 | 0 | 0 | 0 | 0 | 0 | ok |'; echo $?)
fresh; status up up
times 9 plan Grep '{"pattern":"X"}'
call plan Bash '{"command":"codegraph query SignIn"}'
gate; check "5c a codegraph CLI call clears the hand-work warning" $(row plan | grep -qF '| ok |'; echo $?)
fresh; status up up
call plan Read '{"file_path":"contract/dist/openapi.yaml"}'
call plan Bash '{"command":"node scripts/contract-mcp/cli.mjs schema signInRequest"}'
gate; check "5c a server CLI call clears the contract-by-hand warning" $(row plan | grep -qF '| ok |'; echo $?)

# 6. Nodes: the steps inside a node count for it; other nodes are left out; nodes can be named.
fresh; status up up
times 8 implement.build-step Grep '{"pattern":"X"}'
times 8 review Grep '{"pattern":"X"}'
gate; check "6 only explore and plan by default" $(! grep -q '^| implement\|^| review' "$md"; echo $?)
gate implement; check "6 implement counts its inner steps" $(row implement | grep -qF '| implement | 0 | 0 | 8 |' && [ "$(grep -c '^| implement ' "$md")" -eq 1 ] && ! grep -q '^| explore ' "$md"; echo $?)

# 7. No log at all: a report that says so, exit 0; a usage error exits 2.
fresh; rm "$logs/$run.jsonl"; status up up
gate; rc=$?
check "7 no log: exit 0" "$rc"
check "7 no log: said so" $(grep -qF 'No Archon log for this run: nothing counted.' "$md"; echo $?)
node "$script" "$art" > /dev/null 2>&1; check "7 usage error exits 2" $([ $? -eq 2 ]; echo $?)

# 7b. A Copilot run: its lower-case tool names count as the Claude tools of .archon/copilot/tools.json (grep's folder in
# `paths`, view's file in `path`); without the map they would count nothing.
fresh; status up up
times 3 explore grep '{"pattern":"SignInUseCase","paths":"identity-usecase/src/main"}'
call explore glob '{"pattern":"**/*.java"}'
call explore bash '{"command":"grep -rn Session identity-adapter/src; sed -n 1,9p docs/memory.md"}'
call explore view '{"path":"/w/worktrees/run1/identity-domain/src/main/java/C.java"}'
call explore view '{"path":"contract/openapi.yaml"}'
call explore bash '{"command":"codegraph explore \"SignInUseCase\""}'
gate; check "7b Copilot names counted" $(row explore | grep -qF '| explore | 0 | 1 | 3 | 1 | 1 | 1 | 1 |'; echo $?)
COPILOT_TOOLS="$root/none.json" gate
check "7b without tools.json the names count as they are" $(row explore | grep -qF '| explore | 0 | 0 | 0 | 0 | 0 | 0 | 0 |'; echo $?)

# 8. The workflow runs it after plan, report only, and stop-route waits for it.
wf="$here/../workflows/build-feature-copilot.yaml"
check "8 mcp-use node after plan" $(awk '/^  - id: mcp-use$/{on=1;next} on&&/^  - id:/{exit} on' "$wf" | grep -qF 'depends_on: [plan]'; echo $?)
node8=$(awk '/^  - id: mcp-use$/{on=1;next} on&&/^  - id:/{exit} on' "$wf")
check "8 report only, a failure named on stderr" $(echo "$node8" | grep -qF 'mcp-use-check.js "$ARTIFACTS_DIR" "$WORKFLOW_ID" explore plan \' \
  && echo "$node8" | grep -qF '|| echo "mcp-use-check.js failed; the run has no mcp-use.md" >&2'; echo $?)
check "8 stop-route does not wait for it (report only)" $(grep -A1 '^  - id: stop-route$' "$wf" | grep -qxF '    depends_on: [plan-check]'; echo $?)

echo "mcp-use-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
