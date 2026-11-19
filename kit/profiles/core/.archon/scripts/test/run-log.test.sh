#!/usr/bin/env bash
# Tests for .archon/scripts/run-log.js (R18, T13) against fixture run logs under a throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/run-log.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/run-log.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
export RUN_LOG_OFFLINE=1            # and archon is never asked
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
mkdir -p "$logs"
out="$root/out.json"; err="$root/err.txt"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$err" 2>/dev/null; fi
}
field() { node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(process.argv[2].split(".").reduce((a,k)=>a?.[k],o))' "$out" "$1"; }
is() { [ "$(field "$1")" = "$2" ]; }
node_ev() { # node_ev <type> <path> <ts> [attempt]
  echo "{\"type\":\"$1\",\"step\":\"${2##*.}\",\"ts\":\"$3\",\"execution\":{\"path\":\"$2\",\"node\":{\"kind\":\"exec\"},\"attempt\":{\"id\":\"${4:-$2-a}\"}}}"
}

# Run A: four resumes. Archon would report only the last stretch; the log holds the whole night.
a=aaaa1111aaaa1111aaaa1111aaaa1111
{
  echo '{"type":"workflow_start","workflow_id":"'$a'","ts":"2026-10-18T10:00:00Z"}'
  node_ev node_start ticket 2026-10-18T10:00:00Z
  node_ev node_complete ticket 2026-10-18T10:10:00Z
  node_ev node_start implement 2026-10-18T10:10:00Z
  node_ev node_start implement.write-tests 2026-10-18T10:11:00Z
  echo '{"type":"workflow_error","ts":"2026-10-18T10:20:00Z","error":"boom"}'
  for i in 1 2 3 4; do
    echo '{"type":"workflow_resume","ts":"2026-10-18T1'$i':00:00Z"}'
    node_ev node_start implement 2026-10-18T1$i:00:00Z implement-$i
    [ "$i" -lt 4 ] && echo '{"type":"workflow_error","ts":"2026-10-18T1'$i':10:00Z","error":"again"}'
  done
  node_ev node_complete implement 2026-10-18T14:20:00Z implement-4
  node_ev node_start ci 2026-10-18T14:20:00Z
  node_ev node_complete ci 2026-10-18T14:30:00Z
  node_ev node_start auto-merge 2026-10-18T14:30:00Z
  node_ev node_start auto-merge.gate 2026-10-18T14:30:01Z
  node_ev node_complete auto-merge 2026-10-18T14:35:00Z
  node_ev node_start merged 2026-10-18T14:35:00Z
  node_ev node_complete merged 2026-10-18T15:35:00Z
  node_ev node_start main-ci 2026-10-18T15:35:00Z
  node_ev node_complete main-ci 2026-10-18T15:40:00Z
  node_ev node_skipped close-out 2026-10-18T15:40:00Z
  echo '{"type":"workflow_complete","ts":"2026-10-18T15:41:00Z"}'
} > "$logs/$a.jsonl"

node "$script" $a > "$out" 2> "$err"; check "a logged run exits 0" $?
is start 2026-10-18T10:00:00.000Z && is start_source workflow_start; check "start is the first workflow_start" $?
is end 2026-10-18T15:41:00.000Z && is open false && is status completed; check "end is workflow_complete" $?
is true_min 341; check "true minutes span start to end" $?
is resumes 4; check "four resumes counted" $?
# stopped: 10:20-11:00 (40) + 11:10-12:00 (50) + 12:10-13:00 (50) + 13:10-14:00 (50) = 190
is stopped_min 190 && is buckets.stopped 190; check "stopped intervals summed" $?
# build: ticket 10 + implement 10:10-10:20 (10) + four implement stretches 10+10+10+20 = 70
is buckets.build 70; check "build bucket" $?
is buckets.ci 10 && is buckets.gate 5 && is buckets.merged 60 && is buckets.post 5; check "ci, gate, merged and post buckets" $?
is buckets.idle 1 && is buckets.other 0; check "idle is the gap with no node running" $?
s=$(node -e 'const o=require(process.argv[1]);console.log(Object.entries(o.buckets).reduce((a,[,v])=>a+v,0))' "$out"); [ "$s" = 341 ]
check "buckets add up to the true minutes" $?
node -e 'const o=require(process.argv[1]);const c=o.nodes.find(n=>n.id==="close-out");process.exit(c&&c.min===0&&c.outcome==="skipped"&&!o.nodes.some(n=>n.id.includes("."))?0:1)' "$out"
check "a skipped node is 0 minutes; loop children are not listed" $?
node -e 'const o=require(process.argv[1]);process.exit(o.nodes.filter(n=>n.id==="implement").length===5?0:1)' "$out"
check "one implement span per attempt" $?

node "$script" aaaa1111 > "$out" 2> "$err" && is run $a; check "a prefix resolves to the run" $?

# Run B: no workflow_start, an unknown node, still running. Start falls back to the capture's captured_at.
b=bbbb2222bbbb2222bbbb2222bbbb2222
mkdir -p "$ARCHON_HOME/workspaces/owner/repo/workflow-source/runs/$b"
echo '{"captured_at":"2026-10-18T09:55:00Z"}' > "$ARCHON_HOME/workspaces/owner/repo/workflow-source/runs/$b/manifest.json"
{
  node_ev node_start ticket 2026-10-18T10:00:00Z
  node_ev node_complete ticket 2026-10-18T10:05:00Z
  node_ev node_start brand-new-node 2026-10-18T10:05:00Z
} > "$logs/$b.jsonl"
node "$script" $b > "$out" 2> "$err"; check "a run without workflow_start exits 0" $?
is start 2026-10-18T09:55:00.000Z && is start_source captured_at; check "start falls back to captured_at and names it" $?
is open true && is status running; check "a run still going is open" $?
grep -q 'brand-new-node' "$err"; check "an unknown node warns on stderr" $?
node -e 'const o=require(process.argv[1]);process.exit(o.buckets.other>0?0:1)' "$out"; check "an unknown node counts as other" $?
node "$script" $b --at 2026-10-18T10:15:00Z > "$out" 2> "$err"
is end 2026-10-18T10:15:00.000Z && is true_min 20 && is buckets.other 10; check "--at replays the run at that moment" $?
rm "$ARCHON_HOME/workspaces/owner/repo/workflow-source/runs/$b/manifest.json"
node "$script" $b > "$out" 2> "$err"; is start_source first_event && is start 2026-10-18T10:00:00.000Z
check "without a capture, start is the first event" $?

# Errors.
node "$script" ffffffff > "$out" 2> "$err"; [ $? -eq 1 ]; check "no log exits 1" $?
cp "$logs/$a.jsonl" "$logs/aaaa1111ffff0000aaaa1111ffff0000.jsonl"
node "$script" aaaa1111 > "$out" 2> "$err"; [ $? -eq 2 ] && grep -q ambiguous "$err"; check "an ambiguous prefix exits 2" $?
node "$script" > "$out" 2> "$err"; [ $? -eq 2 ]; check "no run id exits 2" $?
node "$script" $a --at nonsense > "$out" 2> "$err"; [ $? -eq 2 ]; check "a bad --at exits 2" $?

echo "run-log: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
