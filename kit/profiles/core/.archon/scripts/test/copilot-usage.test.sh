#!/usr/bin/env bash
# Tests for .archon/scripts/copilot-usage.js: per node, the usage records of the Copilot session its node_complete names,
# joined to the hook trail by session id, against a throwaway ARCHON_HOME and COPILOT_HOME (no real session is read).
# Usage: bash .archon/scripts/test/copilot-usage.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/copilot-usage.js"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon" COPILOT_HOME="$root/copilot"   # the real ~/.archon and ~/.copilot are never read
run=0123456789abcdef0123456789abcdef
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
state="$COPILOT_HOME/session-state"
trail="$root/tree/.apm-audit/sessions"
mkdir -p "$logs" "$state" "$trail"
log="$logs/$run.jsonl"
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi; }
usage() { out=$(node "$script" "$@" 2>&1); rc=$?; }
done_node() { # done_node <type> <step> <preview> <origin> <duration ms>
  printf '{"type":"%s","step":"%s","duration_ms":%s,"tokens":{"input":900,"output":9},"execution":{"node":{"kind":"agent"},"binding":{"provider":"copilot","model":{"requested":"m","resolved":{"source":"unavailable","reason":"unsupported"}},"sessionPreview":"%s","sessionOrigin":"%s"}}}\n' \
    "$1" "$2" "$5" "$3" "$4" >> "$log"
}
record() { # record <session-id> <source session> <model> <input> <cache read> <cache write> <output> <cost> <ms>
  printf '{"type":"session.usage_record","timestamp":"2026-11-20T10:00:00Z","data":{"usage":{"model":"%s","responseModel":"x","inputTokens":%s,"cacheReadTokens":%s,"cacheWriteTokens":%s,"outputTokens":%s,"reasoningTokens":0,"cost":%s,"duration":%s,"initiator":"agent","accounting":{"sourceSessionId":"%s","sequence":1}}}}\n' \
    "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$2" >> "$state/$1/events.jsonl"
}
session() { mkdir -p "$state/$1"; : > "$state/$1/events.jsonl"; }

# A run: explore (one session, two model calls, a prompt line around them), plan (a resumed session holding one record
# of another session), implement's write-tests twice (two sessions summed), review failed, a node whose session is gone,
# a script node with no binding.
a=aaaaaaaa-1111-4111-8111-111111111111; b=bbbbbbbb-2222-4222-8222-222222222222
c1=cccccccc-3333-4333-8333-333333333333; c2=dddddddd-4444-4444-8444-444444444444; e=eeeeeeee-5555-4555-8555-555555555555
for s in "$a" "$b" "$c1" "$c2" "$e"; do session "$s"; done
printf '{"type":"user.message","data":{"content":"SECRET PROMPT in /home/alice/private.txt"}}\n' >> "$state/$a/events.jsonl"
record "$a" "$a" claude-haiku-5.5 1000 600 300 50 1 2000
record "$a" "$a" claude-haiku-5.5 2000 1500 400 70 1 3000
printf '{"type":"tool.execution_complete","data":{"result":"\\"type\\":\\"session.usage_record\\" inside a file"}}\n' >> "$state/$a/events.jsonl"
printf 'not json at all "type":"session.usage_record"\n' >> "$state/$a/events.jsonl"
record "$b" "$b" claude-opus-5.5 5000 4000 900 300 30 9000
record "$b" "$a" claude-haiku-5.5 7777 0 0 7777 7 7777
record "$c1" "$c1" claude-sonnet-5.5 800 500 200 40 1 1000
record "$c2" "$c2" claude-sonnet-5.5 900 600 200 60 1 1000
record "$e" "$e" claude-opus-5.5 100 0 0 10 3 500
{
  echo '{"type":"workflow_start","workflow_name":"build-feature-copilot","ts":"2026-11-20T10:00:00Z"}'
  echo '{"type":"node_start","step":"plan","execution":{"binding":{"sessionPreview":"aaaaaaaa"}}}'
  echo '{"type":"node_complete","step":"ticket","duration_ms":1400,"execution":{"node":{"kind":"exec"}}}'
} >> "$log"
done_node node_complete explore aaaaaaaa fresh 28000
done_node node_complete plan bbbbbbbb resumed 31000
done_node node_complete write-tests cccccccc fresh 20000
done_node node_complete write-tests dddddddd fresh 10000
done_node node_complete pr-text 99999999 fresh 4000
done_node node_error review eeeeeeee fresh 7000
printf '{"type":"SESSION_START","session":"%s","agent":"main","role":"","ticket":"","cwd":"/home/alice/w"}\n{"type":"TOOL","session":"%s","agent":"main","tool":"Skill","arg":"{}"}\n{"type":"TOOL","session":"%s","agent":"main","tool":"Bash","arg":"{}"}\n' "$a" "$a" "$a" > "$trail/$a.jsonl"
printf '{"type":"TOOL","session":"%s","agent":"main","tool":"Read","arg":"{}"}\n' "$b" > "$trail/$b.jsonl"

# 1. The markdown table: fresh input, the cache apart, Copilot cost units, the node time, Archon's own counts beside.
usage "$run"
check "1 exit 0" "$rc"
row() { echo "$out" | grep -F "| $1 |"; }
check "1 explore: two calls, fresh input 200, cache 2100/700, output 120, 2 units, 28 s" \
  $(row explore | grep -qF '| explore | aaaaaaaa | claude-haiku-5.5 | 2 | 200 | 2,100 | 700 | 120 | 2 | 28 s | 900/9 |'; echo $?)
check "1 plan: the other session's record left out" \
  $(row plan | grep -qF '| plan | bbbbbbbb | claude-opus-5.5 | 1 | 100 | 4,000 | 900 | 300 | 30 | 31 s | 900/9 |'; echo $?)
check "1 plan: the left-out record is named" $(echo "$out" | grep -qxF -- '- plan: 1 records of another session left out'; echo $?)
check "1 write-tests: two sessions summed" \
  $(row write-tests | grep -qF '| write-tests | cccccccc, dddddddd | claude-sonnet-5.5 | 2 | 200 | 1,100 | 400 | 100 | 2 | 30 s | 1,800/18 |'; echo $?)
check "1 a failed node is marked" $(echo "$out" | grep -qF '| review (failed) | eeeeeeee | claude-opus-5.5 | 1 | 100 |'; echo $?)
check "1 a session that is gone is named, not guessed" $(echo "$out" | grep -qxF -- '- pr-text: 99999999: session not found, not counted'; echo $?)
check "1 the run total" $(echo "$out" | grep -qF '| **run** | | | 6 | 600 | 7,200 | 2,000 | 530 | 37 |'; echo $?)
check "1 a script node is no row" $(! echo "$out" | grep -qF '| ticket'; echo $?)
check "1 cost is never money" $(echo "$out" | grep -qF 'Copilot cost units' && ! echo "$out" | grep -qiE 'usd|\$[0-9]'; echo $?)
check "1 no trail section without --audit" $(! echo "$out" | grep -qF 'Hook audit trail'; echo $?)

# 2. Personal data: no prompt text, no path and no other session's content in the report.
check "2 no prompt text or path copied" $(! echo "$out" | grep -qE 'SECRET|alice|/home/|inside a file'; echo $?)

# 3. --audit joins the hook trail by session id (its agent says "main"): counts only.
usage "$run" --audit "$trail"
check "3 trail counts per node" $(echo "$out" | grep -qF '| explore | 3 | 2 | 1 |' && echo "$out" | grep -qF '| plan | 1 | 1 | 0 |'; echo $?)
check "3 no trail path or cwd copied" $(! echo "$out" | grep -qE 'alice|/home/'; echo $?)

# 4. --json: the same rows, models by name.
usage "$run" --json
check "4 json" $(echo "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);const e=r.find(x=>x.step==="explore");process.exit(e.input===200&&e.models["claude-haiku-5.5"].calls===2&&e.costUnits===2?0:1)})'; echo $?)

# 5. A preview that matches two sessions is not guessed; no Copilot node at all says so; an unknown run exits 1.
session aaaaaaaa-9999-4999-8999-999999999999
usage "$run"
check "5 ambiguous preview named" $(echo "$out" | grep -qxF -- '- explore: aaaaaaaa: preview matches 2 sessions, not counted'; echo $?)
rm -rf "$state/aaaaaaaa-9999-4999-8999-999999999999"
printf '{"type":"node_complete","step":"ticket","execution":{"node":{"kind":"exec"}}}\n' > "$logs/ffffffffffffffffffffffffffffffff.jsonl"
usage ffffffffffffffffffffffffffffffff
check "5 no Copilot node" $([ "$rc" -eq 0 ] && [ "$out" = "No Copilot agent node in this run." ]; echo $?)
usage 11111111111111111111111111111111
check "5 unknown run exits 1" $([ "$rc" -eq 1 ]; echo $?)
usage
check "5 usage error exits 2" $([ "$rc" -eq 2 ]; echo $?)

# 6. No session folder at all: every node named, exit 0.
COPILOT_HOME="$root/none" usage "$run"
check "6 no session folder" $([ "$rc" -eq 0 ] && echo "$out" | grep -qxF -- '- explore: aaaaaaaa: no Copilot session folder, not counted'; echo $?)

echo "copilot-usage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
