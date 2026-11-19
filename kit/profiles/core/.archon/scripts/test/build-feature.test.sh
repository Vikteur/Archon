#!/usr/bin/env bash
# Tests for build-feature's faster steps and commit rules (R12, R13; roadmap T9, T10; D12): the step-base and
# review-base nodes (their own bash, read from the workflow and run in a throwaway repo), the per-step AFFECTED_BASE in
# the build agent's and review's affected-check, the review-tests node, the plan's ban on check-only steps, the model
# of finalize, the scaffolding rules of the plan and agent prompts (scaffold.sh --for, the two
# `Hand-written:` forms, the plan's `Scaffold:` lines and the two nodes that render them), and the denied tools (no agent of a run skips the commit-msg hook; no Monitor, no
# background command in the agent nodes).
# Usage: bash .archon/scripts/test/build-feature.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$here/../workflows/build-feature.yaml"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
loop_node() { yq ".nodes[] | select(.id == \"implement\") | .loop_group.nodes[] | select(.id == \"$1\") | .$2" "$wf"; }
node() { yq ".nodes[] | select(.id == \"$1\") | .$2" "$wf"; }

step_bash=$(loop_node step-base bash)
review_bash=$(node review-base bash)

# A throwaway repo and an artifacts folder.
r="$root/repo"; art="$root/art"; mkdir -p "$r" "$art"
git -C "$r" init -q -b main; git -C "$r" config user.name t; git -C "$r" config user.email t@t
echo one > "$r/a"; git -C "$r" add -A; git -C "$r" commit -qm init
commit() { echo "$1" >> "$r/a"; git -C "$r" commit -qam "$1"; }
run_step() { out=$(cd "$r" && ARTIFACTS_DIR="$art" bash -c "$step_bash" 2>&1); rc=$?; }

# 1. No plan: the node fails.
run_step
check "1 no plan: exit 1" $([ "$rc" -eq 1 ]; echo $?)

# 2. The first open checkbox is step 2 (indented boxes and an x box count; other lines do not).
cat > "$art/plan.md" <<'EOF'
# Plan
- [x] step one
Test skills: none
  - [ ] step two
- [ ] step three
EOF
h1=$(git -C "$r" rev-parse HEAD)
run_step
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 step 2's base is HEAD" $([ "$(cat "$art/step-base-2.sha")" = "$h1" ]; echo $?)
check "2 step-base.sha is that base" $([ "$(cat "$art/step-base.sha")" = "$h1" ]; echo $?)
check "2 no file for another step" $([ ! -e "$art/step-base-1.sha" ] && [ ! -e "$art/step-base-3.sha" ]; echo $?)

# 3. The same step goes round again after commits (red build, skills miss): it keeps its first base.
commit "test(step 2)"; commit "feat: step 2 half"
run_step
check "3 the same step keeps its first base" $([ "$(cat "$art/step-base.sha")" = "$h1" ]; echo $?)

# 4. The next step gets the HEAD it starts from.
sed -i 's/  - \[ \] step two/  - [x] step two/' "$art/plan.md"
h2=$(git -C "$r" rev-parse HEAD)
run_step
check "4 step 3's base is the HEAD after step 2" $([ "$(cat "$art/step-base-3.sha")" = "$h2" ] \
  && [ "$(cat "$art/step-base.sha")" = "$h2" ]; echo $?)

# 5. A step opened again (build-side skills miss) takes its kept base back.
sed -i 's/  - \[x\] step two/  - [ ] step two/' "$art/plan.md"
commit "feat: step 3"
run_step
check "5 a reopened step takes its kept base back" $([ "$(cat "$art/step-base.sha")" = "$h1" ]; echo $?)

# 6. No open step: exit 0, nothing changed.
sed -i 's/- \[ \]/- [x]/' "$art/plan.md"
before=$(cat "$art/step-base.sha")
run_step
check "6 no open step: exit 0" $([ "$rc" -eq 0 ] && [ "$(cat "$art/step-base.sha")" = "$before" ]; echo $?)

# 7. review-base keeps HEAD.
out=$(cd "$r" && ARTIFACTS_DIR="$art" bash -c "$review_bash" 2>&1); rc=$?
check "7 review-base writes HEAD" $([ "$rc" -eq 0 ] && [ "$(cat "$art/review-base.sha")" = "$(git -C "$r" rev-parse HEAD)" ]; echo $?)

# 8. The order: step-base first in the loop, review-base between scaffold-check and review.
check "8 scaffold-tests depends on step-base" $([ "$(loop_node scaffold-tests 'depends_on[0]')" = step-base ]; echo $?)
check "8 write-tests depends on scaffold-tests" $([ "$(loop_node write-tests 'depends_on | join(",")')" = scaffold-tests ]; echo $?)
check "8 step-base is the loop's first node" \
  $([ "$(yq '.nodes[] | select(.id == "implement") | .loop_group.nodes[0].id' "$wf")" = step-base ]; echo $?)
check "8 review-base after scaffold-check" $([ "$(node review-base 'depends_on[0]')" = scaffold-check ]; echo $?)
check "8 review after scaffold-check, review-base and review-tests" \
  $([ "$(node review 'depends_on | join(",")')" = scaffold-check,review-base,review-tests ]; echo $?)
check "8 review-tests after review-base" $([ "$(node review-tests 'depends_on[0]')" = review-base ]; echo $?)

# 9. The build agent's affected-check runs against the step's base; review's re-run against review-base.
build_prompt=$(loop_node build-step prompt | tr '\n' ' ')
review_prompt=$(node review prompt | tr '\n' ' ')
out="$build_prompt"
check "9 build-step: every affected-check has the step base" \
  $([ "$(grep -o 'affected-check\.sh' <<< "$build_prompt" | wc -l)" -eq "$(grep -o 'AFFECTED_BASE="$(cat "$ARTIFACTS_DIR/step-base.sha")" bash *\.claude/scripts/affected-check' <<< "$build_prompt" | wc -l)" ]; echo $?)
check "9 build-step: verify-only runs no suite" $(grep -q 'verify only)` has no tests: make the docs change it names, or run the one generator it *names, and run no test suite' <<< "$build_prompt"; echo $?)
out="$review_prompt"
check "9 review: reads the branch-wide run of review-tests, runs none first" \
  $(grep -q 'Read $ARTIFACTS_DIR/review-tests.log' <<< "$review_prompt" && ! grep -q 'First run' <<< "$review_prompt"; echo $?)

# 9b. review-tests runs the branch-wide affected-check (with the mutation gate) once, into review-tests.log, and never
# fails the node: a red run is the review's to read and fix. A stub affected-check stands in for the real one.
tests_bash=$(node review-tests bash)
out="$tests_bash"
check "9b review-tests runs affected-check branch-wide, not synced" $(grep -q 'AFFECTED_NO_SYNC=1 bash .claude/scripts/affected-check.sh' <<< "$tests_bash"; echo $?)
check "9b review-tests has a timeout" $([ "$(node review-tests timeout)" -ge 1800000 ] 2>/dev/null; echo $?)
mkdir -p "$r/.claude/scripts"
for want in 0 1; do
  printf 'echo "SURVIVED: a mutant"; echo "base=${AFFECTED_BASE:-none} sync=${AFFECTED_NO_SYNC:-}"; exit %s\n' "$want" > "$r/.claude/scripts/affected-check.sh"
  out=$(cd "$r" && ARTIFACTS_DIR="$art" bash -c "$tests_bash" 2>&1); rc=$?
  check "9b review-tests (affected-check exit $want): the node passes and says the exit" $([ "$rc" -eq 0 ] && grep -q "exit $want" <<< "$out"; echo $?)
  check "9b review-tests (affected-check exit $want): the log holds the output" \
    $(grep -qx 'SURVIVED: a mutant' "$art/review-tests.log" && grep -qx 'base=none sync=1' "$art/review-tests.log"; echo $?)
done
rm -rf "$r/.claude"
check "9 review: the re-run uses review-base" $(grep -q 'AFFECTED_BASE="$(cat "$ARTIFACTS_DIR/review-base.sha")"' <<< "$review_prompt"; echo $?)

# 10. The plan writes no check-only step.
plan_prompt=$(node plan prompt | tr '\n' ' ')
out="$plan_prompt"
check "10 plan: no step only runs checks" $(grep -q 'Never write a step that only runs tests, checks or gates' <<< "$plan_prompt"; echo $?)
check "10 plan: criteria proven by a check go under Checks for review" $(grep -q '## Checks for review' <<< "$plan_prompt"; echo $?)
check "10 plan: verify-only is no longer 'only runs checks'" $(! grep -q 'it only runs checks' <<< "$plan_prompt"; echo $?)
check "10 plan: loads clean-architecture with the Skill tool, which skill-check requires" $(grep -q 'Load clean-architecture with the Skill tool first, always' <<< "$plan_prompt"; echo $?)
check "10 review reads Checks for review" $(grep -q '## Checks for review' <<< "$review_prompt"; echo $?)

# 11. No committing agent may skip the hook; the agent nodes may not use Monitor.
denies() { yq "[.. | select(tag == \"!!map\" and .id == \"$2\") | .denied_tools[]] | join(\" \")" "$1"; }
for n in write-tests build-step review map-curate fix github-agent; do
  d=$(denies "$wf" "$n"); out="$n: $d"
  check "11 build-feature $n denies --no-verify and commit -n" $([[ "$d" == *'Bash(*--no-verify*)'* && "$d" == *'Bash(*commit -n *)'* ]]; echo $?)
done
for n in plan write-tests build-step review; do
  d=$(denies "$wf" "$n"); out="$n: $d"
  check "11 build-feature $n denies Monitor" $([[ " $d " == *' Monitor '* ]]; echo $?)
done

# 12. The agents are told the hook's rule and to run in the foreground.
wt_prompt=$(loop_node write-tests prompt | tr '\n' ' ')
for p in wt_prompt build_prompt review_prompt; do
  out="${!p}"
  check "12 $p: a refused commit is split, only unpushed ones rewritten" $(grep -q 'a pushed one never' <<< "${!p}"; echo $?)
  check "12 $p: foreground" $(grep -q 'in the foreground' <<< "${!p}"; echo $?)
done
out="$wt_prompt"
check "12 write-tests: test-tree files go in the test commit" $(grep -q 'goes in that test commit, never with code' <<< "$wt_prompt"; echo $?)

# 13. ci-fix (failure recovery, D13): red-head first, fix-made fails a round without a commit, no push to main.
cif() { yq ".nodes[] | select(.id == \"ci-fix\") | .loop_group.nodes[] | select(.id == \"$1\") | .$2" "$wf"; }
check "13 red-head is ci-fix's first node" \
  $([ "$(yq '.nodes[] | select(.id == "ci-fix") | .loop_group.nodes[0].id' "$wf")" = red-head ]; echo $?)
check "13 diagnose after red-head, fix-ci after fix-made" $([ "$(cif diagnose 'depends_on[0]')" = red-head ] \
  && [ "$(cif fix-made 'depends_on[0]')" = fix ] && [ "$(cif fix-ci 'depends_on[0]')" = fix-made ]; echo $?)
made=$(cif fix-made bash)
git -C "$r" rev-parse HEAD > "$art/ci-fix-before.sha"
out=$(cd "$r" && ARTIFACTS_DIR="$art" bash -c "$made" 2>&1); rc=$?
check "13 fix-made: no commit -> CI_FIX_NO_COMMIT, exit 1" $([ "$rc" -eq 1 ] && grep -q '^CI_FIX_NO_COMMIT' <<< "$out"; echo $?)
commit "fix: ci"
out=$(cd "$r" && ARTIFACTS_DIR="$art" bash -c "$made" 2>&1); rc=$?
check "13 fix-made: a commit passes" $([ "$rc" -eq 0 ]; echo $?)
rm "$art/ci-fix-before.sha"
out=$(cd "$r" && ARTIFACTS_DIR="$art" bash -c "$made" 2>&1); rc=$?
check "13 fix-made: no before sha counts as a commit made (red-head did not run)" $([ "$rc" -eq 0 ]; echo $?)
check "13 red-head prints RED_FROM_MAIN" $(cif red-head bash | grep -q 'RED_FROM_MAIN'; echo $?)
for n in diagnose fix github-agent; do
  d=$(denies "$wf" "$n"); out="$n: $d"
  check "13 $n cannot push to main or commit tickets" $([[ "$d" == *'Bash(*git push*main*)'* && "$d" == *'Bash(*commit-tickets*)'* && "$d" == *'Bash(*sync-main*)'* ]]; echo $?)
done

# 14. finalize only fills in a form from files the run wrote: Sonnet (@build), not Opus (2026-10-23).
for n in finalize; do
  out="$n: $(node "$n" model)"
  check "14 $n runs on @build" $([ "$(node "$n" model)" = "@build" ]; echo $?)
done

# 15. Scaffolding (owner decision 2026-10-23): the test and build agents must run scaffold.sh --for on every new file,
# and the plan and both agents name a file by hand in one of the two forms, never with a free reason.
nt='`Hand-written: <repo-relative path> — no-template: <shape>`'
tm='`Hand-written: <repo-relative path> — template-misfit: <template> — <why>`'
wt=$(loop_node write-tests prompt); bs=$(loop_node build-step prompt); pl=$(node plan prompt)
out="$wt"; check "15 write-tests must run --test --for" $(tr -s ' \n' ' ' <<< "$wt" | grep -qF 'run `scripts/scaffold.sh --test --for <path>` before you write it'; echo $?)
out="$bs"; check "15 build-step must run --for" $(tr -s ' \n' ' ' <<< "$bs" | grep -qF 'run `scripts/scaffold.sh --for <path>` before you write it'; echo $?)
for n in write-tests build-step plan; do
  case $n in write-tests) p="$wt" ;; build-step) p="$bs" ;; plan) p="$pl" ;; esac
  out="$p"; check "15 $n names both forms" $(tr -s ' \n' ' ' <<< "$p" | grep -qF "$nt" && tr -s ' \n' ' ' <<< "$p" | grep -qF "$tm"; echo $?)
  check "15 $n has no free reason left" $(! grep -qF 'why no template fits' <<< "$p"; echo $?)
done

# 16. Scaffold lines (docs/memory.md, 2026-10-24): the plan names its renders, scaffold-tests renders the test-tree ones
# before the test agent and scaffold-build the others only after the step's tests passed tests-check, never failing the
# loop; each agent reads its side's report and still runs --for for every other new file.
out="$pl"; check "16 plan names the Scaffold form" \
  $(tr -s ' \n' ' ' <<< "$pl" | grep -qF 'add one line `Scaffold: <template> <repo-relative path> <vars>`'; echo $?)
check "16 plan never renders a file itself" $(tr -s ' \n' ' ' <<< "$pl" | grep -qF 'never render a file yourself'; echo $?)
for side in tests build; do
  s=${side%s}
  out=$(loop_node "scaffold-$side" bash)
  check "16 scaffold-$side runs scaffold-step.js for the $s side and never fails the node" \
    $(tr -s ' \n\\' ' ' <<< "$out" | grep -qE "^node \.archon/scripts/scaffold-step\.js \"\\\$ARTIFACTS_DIR\" $s +\|\| echo "; echo $?)
done
check "16 scaffold-build runs after tests-check, only when it passed" \
  $([ "$(loop_node scaffold-build 'depends_on | join(",")')" = tests-check ] \
    && [ "$(loop_node scaffold-build when)" = "\$tests-check.output.ok == 'true'" ]; echo $?)
check "16 build-step waits for scaffold-build" \
  $([ "$(loop_node build-step 'depends_on | join(",")')" = tests-check,scaffold-build ]; echo $?)
out="$wt"; check "16 write-tests reads its report" $(tr -s ' \n' ' ' <<< "$wt" | grep -qF 'read $ARTIFACTS_DIR/scaffold-render/step-<n>-test.md'; echo $?)
out="$bs"; check "16 build-step reads its report" $(tr -s ' \n' ' ' <<< "$bs" | grep -qF 'read $ARTIFACTS_DIR/scaffold-render/step-<n>-build.md'; echo $?)
check "16 build-step knows its n" $(tr -s ' \n' ' ' <<< "$bs" | grep -qF 'n is its position among the plan'"'"'s checkbox lines'; echo $?)

echo "build-feature tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
