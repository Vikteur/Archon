#!/usr/bin/env bash
# Tests for the Copilot reader of scripts/tokenomics/tokenomics.js: an Archon node that ran in the Copilot CLI gets its
# tokens from its session's usage records, its models as copilot/<id> (unpriced), its cost in Copilot cost units.
# Everything is a throwaway fixture: no real transcript, Archon database or Copilot session is read.
# Usage: bash scripts/test/tokenomics-copilot.test.sh   (exit 0 = all pass)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo/scripts/tokenomics/tokenomics.js"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi; }

state="$root/home/.copilot/session-state"
sid=12345678-aaaa-4aaa-8aaa-aaaaaaaaaaaa
mkdir -p "$root/out" "$root/projects" "$root/repo" "$state/$sid"
echo '{"models":{},"usdPerEur":1.1,"timeZone":"UTC"}' > "$root/out/pricing.json"
echo '{"include":["no-such-project"]}' > "$root/out/scope.json"
{
  printf '{"type":"user.message","data":{"content":"PROMPT TEXT about /home/alice/secret"}}\n'
  for i in 1 2; do
    printf '{"type":"session.usage_record","data":{"usage":{"model":"claude-opus-5.5","inputTokens":1000,"cacheReadTokens":700,"cacheWriteTokens":200,"outputTokens":40,"cost":1.5,"duration":2000,"accounting":{"sourceSessionId":"%s"}}}}\n' "$sid"
  done
} > "$state/$sid/events.jsonl"
cat > "$root/runs.json" <<JSON
{"runs":[{"id":"0123456789abcdef0123456789abcdef","workflowName":"build-feature-copilot","userMessage":"TASK-7 add a thing",
  "workingPath":"$root/home/.archon/workspaces/o/r/worktrees/feat/task-7-x","startedAt":"2026-11-20T10:00:00Z",
  "nodes":[{"nodeId":"plan","sessionPreview":"12345678","model":"","sessionOrigin":"fresh","status":"completed","costUsd":0,"numTurns":0,"durationMs":5000},
           {"nodeId":"review","sessionPreview":"99999999","model":"","sessionOrigin":"fresh","status":"completed","costUsd":0,"numTurns":0,"durationMs":1000}]}]}
JSON

out=$(node "$script" update --home "$root/home" --projects "$root/projects" --out "$root/out" --repo "$root/repo" \
  --archon-runs "$root/runs.json" --artifacts "$root/ws" 2>&1); rc=$?
check "update exits 0" "$rc"
summary=$(echo "$out" | grep '^{')
q() { echo "$summary" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const d=JSON.parse(s);console.log(JSON.stringify($1))})"; }
check "one node read from its Copilot session, the one with no session ignored" \
  $([ "$(q '[d.archonNodesCopilot,d.archonNodesIgnored]')" = '[1,1]' ]; echo $?)
check "the Copilot model is unpriced: tokens counted, no money guessed" $([ "$(q 'd.unpricedModels')" = '["copilot/claude-opus-5.5"]' ]; echo $?)

day="$root/out/ledger/2026-11/2026-11-20.json"
rec() { node -e "const r=require('$day').records['$sid'];console.log(JSON.stringify($1))"; }
check "the record: fresh input, the cache apart, per call" \
  $([ "$(rec 'r.models["copilot/claude-opus-5.5"]')" = '{"cacheRead":1400,"cacheWrite1h":0,"cacheWrite5m":400,"calls":2,"input":200,"output":80,"webSearch":0}' ]; echo $?)
check "Copilot cost units kept apart, Archon USD 0" $([ "$(rec '[r.archon.copilotCostUnits,r.archon.costUsd,r.archon.node]')" = '[3,0,"plan"]' ]; echo $?)
check "the ticket from the run's request" $([ "$(rec '[r.kind,r.label,r.ticket,r.rule]')" = '["archon-node","build-feature-copilot/plan","TASK-7","archon-request"]' ]; echo $?)
ticket="$root/out/ticket-token-reports/TASK-7.md"
check "the ticket report shows the cost units, not as money" $(grep -qF '| 3 Copilot cost units |' "$ticket"; echo $?)
check "no prompt text or home path in the ledger or the reports" \
  $(! grep -rqE 'PROMPT|alice|secret' "$root/out" && ! grep -rqF "$root/home" "$root/out"; echo $?)

# The run again: the same record, not a second one.
node "$script" update --home "$root/home" --projects "$root/projects" --out "$root/out" --repo "$root/repo" \
  --archon-runs "$root/runs.json" --artifacts "$root/ws" >/dev/null 2>&1
check "a second update keeps one record" $([ "$(node -e "console.log(Object.keys(require('$day').records).length)")" = 1 ]; echo $?)

# No session folder: the node is ignored, as before the reader.
rm -rf "$root/out/ledger" && out=$(node "$script" update --home "$root/home" --projects "$root/projects" --out "$root/out" --repo "$root/repo" \
  --archon-runs "$root/runs.json" --artifacts "$root/ws" --copilot "$root/none" 2>&1)
summary=$(echo "$out" | grep '^{')
check "--copilot to a missing folder: both nodes ignored" $([ "$(q '[d.archonNodesCopilot,d.archonNodesIgnored,d.records]')" = '[0,2,0]' ]; echo $?)

echo "tokenomics-copilot: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
