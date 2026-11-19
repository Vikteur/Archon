#!/usr/bin/env bash
# Tests for .archon/scripts/blocked-stop.sh against throwaway plans, and for its place in the build loops of
# build-feature: a `BLOCKED:` plan stops inside the loop, so it never reaches skill-check.
# Usage: bash .archon/scripts/test/blocked-stop.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/blocked-stop.sh"
wf="$here/../workflows"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

run() { # run <args...>: sets out (stderr), so (stdout), rc
  so=$(bash "$script" "$@" 2> "$root/err"); rc=$?; out=$(cat "$root/err")
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
fresh() { art="$root/art-$RANDOM$RANDOM"; mkdir -p "$art"; printf '%s' "$1" > "$art/plan.md"; }

# 1. Nothing to stop: no plan, or a plan without a BLOCKED: line.
art="$root/none"; mkdir -p "$art"
run "$art" run-1
check "1 no plan passes" $([ "$rc" -eq 0 ] && [ -z "$out$so" ]; echo $?)
fresh $'# Plan\n- [x] step 1\n- [ ] step 2\n'
run "$art" run-1
check "1 an open plan passes, silent" $([ "$rc" -eq 0 ] && [ -z "$out$so" ] && [ ! -e "$art/blocked.md" ]; echo $?)
fresh $'# Plan\n- [ ] step 2\n  Note: a line that only mentions BLOCKED: is no question\n'
run "$art" run-1
check "1 BLOCKED: not at the start of a line passes" $([ "$rc" -eq 0 ]; echo $?)

# 2. A BLOCKED: line fails with the question and how to go on.
fresh $'# Plan\n- [x] step 1\n- [ ] step 2\nBLOCKED: step 2: may the guard move to step 3?\n'
run "$art" 4c92a55f
check "2 a blocked plan fails" $([ "$rc" -eq 1 ]; echo $?)
check "2 the question is on stderr" $(grep -qx 'BLOCKED: step 2: may the guard move to step 3?' <<< "$out"; echo $?)
check "2 it says how to answer" $(grep -q 'replace each BLOCKED: line by ANSWER: <your answer>' <<< "$out"; echo $?)
check "2 it names the resume command for this run" $(grep -q 'archon workflow resume 4c92a55f' <<< "$out"; echo $?)
check "2 it names how to end the run instead" $(grep -q 'stop-run.sh 4c92a55f' <<< "$out"; echo $?)
check "2 the stop is kept in blocked.md" $(grep -q 'may the guard move to step 3' "$art/blocked.md"; echo $?)
check "2 nothing on stdout" $([ -z "$so" ]; echo $?)

fresh $'- [ ] step 1\r\nBLOCKED: one?\r\nBLOCKED: two?\r\n'
run "$art" r
check "2 every question is named, CRLF stripped" $([ "$rc" -eq 1 ] && grep -qx 'BLOCKED: one?' <<< "$out" && grep -qx 'BLOCKED: two?' <<< "$out"; echo $?)

# 3. Answered: the ANSWER: line in place of the BLOCKED: one lets the loop go on.
fresh $'# Plan\n- [ ] step 2\nANSWER: yes, move it\n'
run "$art" r
check "3 an answered plan passes" $([ "$rc" -eq 0 ]; echo $?)

# 4. The workflows: in every loop that ends on a BLOCKED: line, the body's sinks run blocked-stop.sh, and no agent
#    node follows another agent node without one in between. So a blocked plan fails the loop in the iteration that
#    wrote it, and the gates after the loop (skill-check) never see a step nobody built.
loops() { # loops <workflow>: one JSON object per loop body {loop, nodes: [{id, deps, prompt, stop}]}
  yq -o=json '.' "$wf/$1.yaml" | node -e '
    const w = JSON.parse(require("fs").readFileSync(0, "utf8"));
    for (const n of w.nodes) {
      const g = n.loop_group;
      if (!g || !/BLOCKED/.test(g.until_bash || "")) continue;
      console.log(JSON.stringify({ loop: n.id, nodes: g.nodes.map(b => ({ id: b.id, deps: b.depends_on || [],
        prompt: !!b.prompt, stop: /blocked-stop\.sh/.test(b.bash || "") })) }));
    }'
}
verdict() { # verdict <loop json>: prints the problems, nothing when the loop stops on BLOCKED
  node -e '
    const l = JSON.parse(process.argv[1]);
    const by = new Map(l.nodes.map(n => [n.id, n]));
    const used = new Set(l.nodes.flatMap(n => n.deps));
    for (const n of l.nodes) if (!used.has(n.id) && !n.stop) console.log(`${l.loop}: sink ${n.id} does not run blocked-stop.sh`);
    // an agent reached from another agent without a blocked-stop node in between could build on a blocked plan
    for (const n of l.nodes.filter(n => n.prompt)) {
      const seen = new Set(), todo = [...n.deps];
      while (todo.length) {
        const d = by.get(todo.pop());
        if (!d || seen.has(d.id) || d.stop) continue;
        seen.add(d.id);
        if (d.prompt) console.log(`${l.loop}: agent ${n.id} follows agent ${d.id} with no blocked-stop.sh between`);
        todo.push(...d.deps);
      }
    }' "$1"
}
for w in build-feature; do
  ls_=$(loops "$w")
  out="$ls_"
  check "4 $w has a loop that ends on BLOCKED:" $([ -n "$ls_" ]; echo $?)
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    out=$(verdict "$l")
    check "4 $w loop $(node -e 'console.log(JSON.parse(process.argv[1]).loop)' "$l") stops on BLOCKED: inside the loop" \
      $([ -z "$out" ]; echo $?)
  done <<< "$ls_"
done

# 5. The check in 4 catches the shape that let run 4c92a55f reach skill-check: no stop in the loop body.
out=$(verdict '{"loop":"implement","nodes":[{"id":"write-tests","deps":[],"prompt":true,"stop":false},{"id":"build-step","deps":["write-tests"],"prompt":true,"stop":false}]}')
check "5 the old build-feature loop is refused" $(grep -q 'sink build-step does not run blocked-stop.sh' <<< "$out" &&
  grep -q 'agent build-step follows agent write-tests' <<< "$out"; echo $?)

echo "blocked-stop tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
