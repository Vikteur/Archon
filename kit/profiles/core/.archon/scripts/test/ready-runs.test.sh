#!/usr/bin/env bash
# Tests for .archon/scripts/ready-runs.sh (TASK-69; short ids, wait --all, hold and ack: R4) against a stubbed archon
# and a throwaway ready folder, and for the ready record wait-merge.sh keeps while a run waits at its merged node.
# Usage: bash .archon/scripts/test/ready-runs.test.sh   (exit 0 = all pass)
set -uo pipefail
# The scripts' defaults, not the checkout's .archon/kit.yaml (an install's build_workflow differs).
export KIT_CONFIG=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/ready-runs.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$root"' EXIT
U=https://github.com/o/repo/pull

# archon answers `workflow get <run> --json` with {"status": <$root/status/<run>, running when missing>}; gh answers
# `pr view <url> --json state` with the state in $root/pr/<n> (OPEN when missing), and every other call with nothing.
mkdir -p "$root/bin" "$root/status" "$root/pr"
# With $root/ids (one full id per line), `workflow get` resolves a prefix of one of them as archon does, and refuses an
# ambiguous or unknown one. `workflow runs` prints $root/runs.json ($root/verbose.json with --verbose); with $root/down
# every archon call fails.
cat > "$root/bin/archon" <<'STUB'
#!/usr/bin/env bash
[ -e "$ROOT/down" ] && exit 1
case "$1 $2" in
  "workflow get")
    id=$3
    if [ -f "$ROOT/ids" ]; then
      m=$(grep "^$3" "$ROOT/ids")
      case $(printf '%s' "$m" | grep -c .) in
        1) id=$m ;;
        0) printf '{"ok": false, "runId": "%s", "error": "No run %s"}\n' "$3" "$3"; exit 1 ;;
        *) printf '{"ok": false, "runId": "%s", "error": "Run id %s matches more than one run"}\n' "$3" "$3"; exit 1 ;;
      esac
    fi
    printf '{"id": "%s", "status": "%s"}\n' "$id" "$(cat "$ROOT/status/$id" 2>/dev/null || echo running)" ;;
  "workflow runs")
    case "$*" in *--verbose*) cat "$ROOT/verbose.json" 2>/dev/null || echo '{"runs": []}' ;;
                 *) cat "$ROOT/runs.json" 2>/dev/null || echo '{"runs": []}' ;; esac ;;
  *) exit 1 ;;
esac
STUB
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view "*" --json state -q .state") n=${3##*/}; cat "$ROOT/pr/$n" 2>/dev/null || echo OPEN ;;
  *) echo "" ;;
esac
STUB
chmod +x "$root/bin/archon" "$root/bin/gh"

env_() { PATH="$root/bin:$PATH" ROOT="$root" READY_RUNS_DIR="$root/ready" READY_POLL_SECONDS=1 "$@"; }
rr() { # rr <args...>: sets out (stdout), err, rc
  out=$(env_ bash "$script" "$@" 2> "$root/err"); rc=$?; err=$(cat "$root/err")
}
settle() { # settle <file>: wait up to 10 s for it to appear
  for _ in $(seq 1 20); do [ -e "$1" ] && return 0; sleep 0.5; done; return 1
}
reset() { kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; rm -rf "$root/ready" "$root"/status/* "$root"/pr/* "$root"/rc.* "$root"/out.* "$root"/ids "$root"/runs.json "$root"/verbose.json "$root"/down; }
field() { printf '%s' "$1" | jq -r ".$2"; }
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}

# 1. Nothing ready: list prints nothing.
reset; rr list
check "1 list of nothing exits 0 and prints nothing" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)

# 2. mark records a run with its pull request; list names both.
rr mark run-a "$U/7"
check "2 mark exits 0" $([ "$rc" -eq 0 ]; echo $?)
rr list
check "2 list names the run" $([ "$(field "$out" run)" = run-a ]; echo $?)
check "2 list names the pull request" $([ "$(field "$out" pr)" = "$U/7" ]; echo $?)
check "2 list says since when" $([ -n "$(field "$out" since)" ] && [ "$(field "$out" since)" != null ]; echo $?)

# 3. clear removes the record.
rr clear run-a; rr list
check "3 a cleared run is not listed" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)

# 4. A record left by a run that is no longer running (cancelled, killed) is not listed, and is removed.
reset; rr mark run-a "$U/7"; rr mark run-b "$U/8"; echo cancelled > "$root/status/run-a"; rr list
check "4 only the running one is listed" $([ "$(printf '%s\n' "$out" | jq -r .run)" = run-b ]; echo $?)
check "4 the stale record is removed" $([ ! -e "$root/ready/run-a.json" ]; echo $?)

# 5. wait on a run that is already ready returns at once with it.
reset; rr mark run-a "$U/7"; rr wait run-a
check "5 wait exits 0" $([ "$rc" -eq 0 ]; echo $?)
check "5 wait says ready" $([ "$(field "$out" state)" = ready ]; echo $?)
check "5 wait names the run and the pull request" $([ "$(field "$out" run)" = run-a ] && [ "$(field "$out" pr)" = "$U/7" ]; echo $?)

# 6. wait on a building run returns once it reaches its merged node (well within a minute).
reset
( env_ bash "$script" wait run-a run-b > "$root/out.6"; echo $? > "$root/rc.6" ) &
sleep 1.2   # one poll round and a bit: a wait that returned early has written rc.6 by now
check "6 still waiting while both build" $([ ! -e "$root/rc.6" ]; echo $?)
rr mark run-b "$U/8"
settle "$root/rc.6"; out=$(cat "$root/out.6" 2>/dev/null)
check "6 returns once run-b is ready" $([ "$(cat "$root/rc.6" 2>/dev/null)" = 0 ] && [ "$(field "$out" state)" = ready ]; echo $?)
check "6 names run-b and its pull request" $([ "$(field "$out" run)" = run-b ] && [ "$(field "$out" pr)" = "$U/8" ]; echo $?)

# 7. wait also returns when a run ends without reaching its merged node (failed on BLOCKED, completed).
reset
( env_ bash "$script" wait run-a > "$root/out.7"; echo $? > "$root/rc.7" ) &
sleep 1.2; echo failed > "$root/status/run-a"
settle "$root/rc.7"; out=$(cat "$root/out.7" 2>/dev/null)
check "7 returns once the run ended" $([ "$(cat "$root/rc.7" 2>/dev/null)" = 0 ] && [ "$(field "$out" state)" = ended ]; echo $?)
check "7 names the run and its status" $([ "$(field "$out" run)" = run-a ] && [ "$(field "$out" status)" = failed ]; echo $?)

# 8. --timeout gives up: exit 1, state timeout.
reset; rr wait run-a --timeout 2
check "8 a timeout exits 1" $([ "$rc" -eq 1 ] && [ "$(field "$out" state)" = timeout ]; echo $?)

# 9. Usage errors exit 2.
rr wait; check "9 wait needs a run id" $([ "$rc" -eq 2 ]; echo $?)
rr mark run-a; check "9 mark needs a pull request" $([ "$rc" -eq 2 ]; echo $?)
rr bogus; check "9 an unknown command" $([ "$rc" -eq 2 ]; echo $?)

# 10. wait-merge.sh keeps the ready record while it waits for the merge, and clears it when the pull request merges.
reset; mkdir -p "$root/repo"; git -C "$root/repo" init -q; mkdir -p "$root/repo/backlog"; touch "$root/repo/backlog/config.yml"
( cd "$root/repo" && env_ env RUN_ID=run-a MERGE_POLL_SECONDS=1 LOCAL_CI_STATUS=/nonexistent \
    bash "$here/wait-merge.sh" "$U/7" > "$root/out.10" 2>/dev/null; echo $? > "$root/rc.10" ) &
settle "$root/ready/run-a.json"; rr list
check "10 the waiting run is listed as ready" $([ "$(field "$out" run)" = run-a ] && [ "$(field "$out" pr)" = "$U/7" ]; echo $?)
echo MERGED > "$root/pr/7"; settle "$root/rc.10"
check "10 the record is cleared after the merge" $([ -e "$root/rc.10" ] && [ ! -e "$root/ready/run-a.json" ]; echo $?)

# 11. The workflow's merged node hands wait-merge.sh the run id.
check "11 merged node passes RUN_ID" $(yq '.nodes[] | select(.id == "merged") | .bash' "$here/../workflows/build-feature.yaml" \
  | grep -q 'RUN_ID=\$WORKFLOW_ID bash .archon/scripts/wait-merge.sh'; echo $?)

# --- R4 (T1): short ids, wait --all, hold and ack. Each case fails on the script before R4. ---
A=37e12149a273706431e3cd80eb39e39f; B=37e12149bb0000000000000000000002; C=4b33311d3c445ff6541aedd627da6e1f
ids() { printf '%s\n' "$@" > "$root/ids"; }
# runs <id>:<status>[:merged][:<attention at>]...: the build-feature runs `workflow runs --json` lists, newest first
runs() {
  local r out=() id st node at
  for r in "$@"; do
    IFS=: read -r id st node at <<< "$r"
    out+=("$(jq -cn --arg id "$id" --arg st "$st" --arg node "$node" --arg at "$at" \
      '{id: $id, workflow_name: "build-feature", status: $st, active_nodes: (if $node == "merged" then ["merged"] else ["implement"] end),
        last_activity_at: (if $at == "" then null else $at end)}')")
  done
  printf '%s\n' "${out[@]}" | jq -s '{runs: .}' > "$root/runs.json"
}

# 12. wait on an 8-character prefix returns ready for the run marked under its full id, and names the full id.
reset; ids "$A" "$C"; rr mark "$A" "$U/150"; rr wait 37e12149 --timeout 3
check "12 a prefix waits on the marked run: ready" $([ "$rc" -eq 0 ] && [ "$(field "$out" state)" = ready ]; echo $?)
check "12 the line names the full id" $([ "$(field "$out" run)" = "$A" ]; echo $?)

# 13. A prefix that matches two ready records, or two runs archon knows, exits 2 and says so.
reset; ids "$A" "$B"; rr mark "$A" "$U/150"; rr mark "$B" "$U/151"; rr wait 37e12149 --timeout 3
check "13 an ambiguous prefix among the records exits 2" $([ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q ambiguous; echo $?)
reset; ids "$A" "$B"; rr wait 37e12149 --timeout 3
check "13 an ambiguous prefix archon refuses exits 2" $([ "$rc" -eq 2 ]; echo $?)

# 14. An unknown id exits 2 at once, never a silent wait into a timeout.
reset; ids "$A"; rr wait ffffff99 --timeout 3
check "14 an unknown id exits 2" $([ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "unknown run id ffffff99"; echo $?)

# 15. resolve prints the full id; full and short ids mix in one wait.
reset; ids "$A" "$C"; rr resolve 4b33311d
check "15 resolve prints the full id" $([ "$rc" -eq 0 ] && [ "$out" = "$C" ]; echo $?)
rr mark "$C" "$U/152"; rr wait "$A" 4b33 --timeout 3
check "15 a full and a short id in one wait" $([ "$rc" -eq 0 ] && [ "$(field "$out" run)" = "$C" ]; echo $?)

# 16. wait --all returns ready for any live run: a marked one (source mark), and one at its merged node with no record
# (source node, its pull request and since read from its nodes).
reset; runs "$A:running" "$C:running"; rr mark "$C" "$U/152"; rr wait --all --timeout 3
check "16 a marked run nobody named is ready (mark)" $([ "$(field "$out" state)" = ready ] && [ "$(field "$out" run)" = "$C" ] && [ "$(field "$out" source)" = mark ]; echo $?)
reset; runs "$A:running:merged" "$C:running"
jq -n --arg id "$A" '{runs: [{id: $id, nodes: [{nodeId: "open-pr", outputPreview: "{\"pr\": \"https://github.com/o/repo/pull/150\", \"sha\": \"abc\"}"},
  {nodeId: "merged", startedAt: "2026-10-18T21:47:37.000Z"}]}]}' > "$root/verbose.json"
rr wait --all --timeout 3
check "16 a run at merged without a record is ready (node)" $([ "$rc" -eq 0 ] && [ "$(field "$out" run)" = "$A" ] && [ "$(field "$out" source)" = node ]; echo $?)
check "16 node source names the pull request and the merged start" $([ "$(field "$out" pr)" = "$U/150" ] && [ "$(field "$out" since)" = 2026-10-18T21:47:37.000Z ]; echo $?)

# 17. attention for a paused run, ended for a run a wait --all saw live, idle when nothing is live.
reset; runs "$A:paused::2026-10-20T01:00:00Z"; rr wait --all --timeout 3
check "17 a paused run needs attention" $([ "$rc" -eq 0 ] && [ "$(field "$out" state)" = attention ] && [ "$(field "$out" run)" = "$A" ]; echo $?)
reset; ids "$A"; runs "$A:running"; rr wait --all --timeout 1
runs "$A:failed"; rr wait --all --timeout 3
check "17 a run seen live that failed has ended" $([ "$(field "$out" state)" = ended ] && [ "$(field "$out" status)" = failed ]; echo $?)
rr ack "${A:0:8}"; rr wait --all --timeout 3
check "17 an acknowledged end is forgotten, and nothing live is idle" $([ "$rc" -eq 0 ] && [ "$(field "$out" state)" = idle ]; echo $?)
reset; runs "$C:completed"; rr wait --all --timeout 3
check "17 a run no wait saw live is not reported: idle" $([ "$(field "$out" state)" = idle ]; echo $?)

# 18. A timeout exits 1; archon down for four polls exits 4.
reset; runs "$A:running"; rr wait --all --timeout 2
check "18 only building runs: timeout exits 1" $([ "$rc" -eq 1 ] && [ "$(field "$out" state)" = timeout ]; echo $?)
reset; touch "$root/down"; rr wait --all --timeout 30
check "18 archon down exits 4" $([ "$rc" -eq 4 ] && [ "$(field "$out" state)" = error ]; echo $?)

# 19. hold skips a run for ready and attention; unhold brings it back.
reset; ids "$A" "$C"; runs "$A:running" "$C:paused::2026-10-20T01:00:00Z"; rr mark "$A" "$U/150"
rr hold 37e12149 "owner holds the merge"; rr hold 4b33311d; rr wait --all --timeout 2
check "19 held runs are neither ready nor attention" $([ "$rc" -eq 1 ]; echo $?)
rr list
check "19 list marks the held run" $([ "$(field "$out" held)" = true ]; echo $?)
rr unhold 37e12149; rr wait --all --timeout 3
check "19 unhold makes it ready again" $([ "$(field "$out" run)" = "$A" ] && [ "$(field "$out" state)" = ready ]; echo $?)

# 20. ack looks past a handled event: the next wait --all names the next run, and a new pause is new.
reset; ids "$A" "$C"; runs "$A:running" "$C:paused::2026-10-20T01:00:00Z"; rr mark "$A" "$U/150"
rr wait --all --timeout 3; first=$(field "$out" run); rr ack "$first"; rr wait --all --timeout 3
check "20 after ack the next event is the paused run" $([ "$first" = "$A" ] && [ "$(field "$out" state)" = attention ]; echo $?)
rr ack "$C"; rr wait --all --timeout 2
check "20 both acknowledged: nothing to say until something changes" $([ "$rc" -eq 1 ]; echo $?)
runs "$A:running" "$C:paused::2026-10-20T02:00:00Z"; rr wait --all --timeout 3
check "20 a second pause is a new event" $([ "$(field "$out" state)" = attention ] && [ "$(field "$out" since)" = 2026-10-20T02:00:00Z ]; echo $?)
rr ack zzzzzzzz; check "20 ack of an unknown id exits 2" $([ "$rc" -eq 2 ]; echo $?)

echo "ready-runs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
