#!/usr/bin/env bash
# Tests for .archon/scripts/step-cut.js: the first open step of plan.md, cut into step.md for the test and build agents
# (its n among the checkbox lines, its block up to the next checkbox or heading, the steps folded into it, the owner
# decisions and the ANSWER lines), and the step-base and scaffold-build nodes that run it.
# Usage: bash .archon/scripts/test/step-cut.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/step-cut.js"
wf="$here/../workflows/build-feature-copilot.yaml"
pass=0; fail=0; out=""
art="$(mktemp -d)"
trap 'rm -rf "$art"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
run() { out=$(node "$script" "$art" 2>&1); rc=$?; }
step() { cat "$art/step.md" 2>/dev/null; }

# 1. No plan: exit 1; no argument: exit 2.
run
check "1 no plan: exit 1" $([ "$rc" -eq 1 ] && grep -q 'no plan' <<< "$out"; echo $?)
out=$(node "$script" 2>&1); rc=$?
check "1 no argument: exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 2. The first open step is the second checkbox; its block ends at the next checkbox.
cat > "$art/plan.md" <<'EOF'
# Plan

## Owner decisions
- Keep the old name.

## Steps
- [x] **1. Done step**
  Test skills: tdd-loop
- [ ] **2. Add the guard**
  Test skills: tdd-loop, jvm-testing
  Build skills: java, clean-code
  Hand-written: a/B.java — no-template: enum
  ```
  # a comment in a fence is no heading
  ```
- [ ] **3. Next step**
  Test skills: none

## Checks for review
- the gate
ANSWER: use the second option
EOF
run
s=$(step)
out="$out
$s"
check "2 exit 0, says step 2 of 3" $([ "$rc" -eq 0 ] && grep -q 'step 2 of 3' <<< "$out"; echo $?)
check "2 title names n" $(head -1 <<< "$s" | grep -qx '# Step 2 of 3'; echo $?)
check "2 holds the step and its lines" $(grep -qF -- '- [ ] **2. Add the guard**' <<< "$s" \
  && grep -qF 'Build skills: java, clean-code' <<< "$s" && grep -qF 'Hand-written: a/B.java' <<< "$s"; echo $?)
check "2 a fenced # line stays in the block" $(grep -qF '# a comment in a fence is no heading' <<< "$s"; echo $?)
check "2 no other step" $(! grep -qF '**3. Next step**' <<< "$s" && ! grep -qF '**1. Done step**' <<< "$s"; echo $?)
check "2 not the next section" $(! grep -qF 'the gate' <<< "$s"; echo $?)
check "2 the owner decisions" $(grep -qx '## Owner decisions' <<< "$s" && grep -qF 'Keep the old name.' <<< "$s"; echo $?)
check "2 the ANSWER lines" $(grep -qx 'ANSWER: use the second option' <<< "$s"; echo $?)
check "2 plan.md untouched" $(grep -qF -- '- [ ] **2. Add the guard**' "$art/plan.md"; echo $?)

# 3. An indented checkbox counts; a step's block ends at a heading; a step folded into it comes along.
cat > "$art/plan.md" <<'EOF'
- [x] one
  - [ ] two
Build skills: java
# Heading
text after
- [ ] (folded into step 2) three
  Build skills: clean-code
- [ ] four (folded into step 3)
EOF
run
s=$(step)
out="$out
$s"
check "3 the indented box is step 2 of 4" $(head -1 <<< "$s" | grep -qx '# Step 2 of 4'; echo $?)
check "3 the block ends at the heading" $(grep -qx 'Build skills: java' <<< "$s" && ! grep -qF 'text after' <<< "$s"; echo $?)
check "3 the step folded into it" $(grep -qx '## Folded into this step: step 3' <<< "$s" && grep -qF 'Build skills: clean-code' <<< "$s"; echo $?)
check "3 a step folded into another is left out" $(! grep -qF 'four' <<< "$s"; echo $?)
check "3 no decisions, no answers" $(! grep -q '^## Owner decisions' <<< "$s" && ! grep -q '^## Answers' <<< "$s"; echo $?)

# 3b. The notes step-check.js left come last, under one heading, their own headings one level down; without notes, no
# heading. missSide reads a note's side.
printf '# Skills missing — step 2\n\nBuild skills: java, clean-code\n\nThe build agent of step 2 never loaded these.\n' > "$art/skills-missing.md"
printf '# Scaffold missing — step 2, build side\n\n- `a/B.java`: written by hand\n' > "$art/scaffold-missing.md"
run
s=$(step)
out="$out
$s"
check "3b the notes come under one heading, last" $(grep -qx '## Misses of the last round: read these first' <<< "$s" \
  && [ "$(grep -n '^## ' <<< "$s" | tail -1 | cut -d: -f2-)" = '## Misses of the last round: read these first' ]; echo $?)
check "3b skills-missing.md is copied, its title a level down" $(grep -qx '### Skills missing — step 2' <<< "$s" && grep -qx 'Build skills: java, clean-code' <<< "$s"; echo $?)
check "3b scaffold-missing.md is copied after it" $(grep -qx '### Scaffold missing — step 2, build side' <<< "$s" \
  && [ "$(grep -n 'Scaffold missing' <<< "$s" | cut -d: -f1)" -gt "$(grep -n 'Skills missing' <<< "$s" | cut -d: -f1)" ]; echo $?)
out=$(node -e 'const {missSide}=require(process.argv[1]); const a=process.argv[2];
  console.log([missSide(a+"/skills-missing.md"), missSide(a+"/scaffold-missing.md"), missSide(a+"/none.md")].join(","))' "$script" "$art")
check "3b missSide reads build, build and '' (no file)" $([ "$out" = 'build,build,' ]; echo $?)
printf 'Test skills: tdd-loop\n' > "$art/skills-missing.md"; printf '# Scaffold missing — step 2, test side\n' > "$art/scaffold-missing.md"; echo old > "$art/x.md"
out=$(node -e 'const {missSide}=require(process.argv[1]); const a=process.argv[2];
  console.log([missSide(a+"/skills-missing.md"), missSide(a+"/scaffold-missing.md"), missSide(a+"/x.md")].join(","))' "$script" "$art")
check "3b missSide reads test, test and '' (no side named)" $([ "$out" = 'test,test,' ]; echo $?)
rm -f "$art/skills-missing.md" "$art/scaffold-missing.md" "$art/x.md"
run
s=$(step)
check "3b no notes, no heading" $(! grep -q 'Misses of the last round' <<< "$s"; echo $?)

# 4. No open step: step.md from an earlier step is removed.
sed -i 's/- \[ \]/- [x]/' "$art/plan.md"
run
check "4 no open step: exit 0, no step.md" $([ "$rc" -eq 0 ] && [ ! -e "$art/step.md" ] && grep -q 'no open step' <<< "$out"; echo $?)

# 5. The workflow cuts the step in step-base and again in scaffold-build, and both agents read step.md.
loop_node() { yq ".nodes[] | select(.id == \"implement\") | .loop_group.nodes[] | select(.id == \"$1\") | .$2" "$wf"; }
for n in step-base scaffold-build; do
  out=$(loop_node "$n" bash)
  check "5 $n runs step-cut.js" $(grep -qF 'node .archon/scripts/step-cut.js "$ARTIFACTS_DIR"' <<< "$out"; echo $?)
done
for n in write-tests build-step; do
  out=$(loop_node "$n" prompt | tr -s ' \n' ' ')
  check "5 $n reads step.md" $(grep -qF 'Read $ARTIFACTS_DIR/step.md' <<< "$out"; echo $?)
done
echo "step-cut: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
