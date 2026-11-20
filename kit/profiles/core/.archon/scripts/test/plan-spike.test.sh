#!/usr/bin/env bash
# Tests for .archon/scripts/plan-spike.sh against a throwaway repo whose committed ./gradlew is a stub, and for the plan
# node's fence in .archon/workflows/build-feature-copilot.yaml: no Gradle, no script that runs Gradle, no test suite.
# Usage: bash .archon/scripts/test/plan-spike.test.sh   (exit 0 = all pass)
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/plan-spike.sh"
top="$(cd "$here/../.." && pwd)"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}

# The stub gradlew logs where it ran and its arguments, and fails for the task `broken`.
repo="$root/repo"; art="$root/art"
mkdir -p "$repo" "$art"
cd "$repo" || exit 1
git init -q && git config user.email t@t && git config user.name t
cat > gradlew <<'STUB'
#!/usr/bin/env bash
echo "gradlew $* in $(pwd)" >> "$SPIKE_LOG"
echo "BUILD OUTPUT for $1"
[ "$1" != broken ]
STUB
chmod +x gradlew
echo committed > a.txt
git add -A && git commit -qm init
echo dirty > a.txt
export SPIKE_LOG="$root/spike.log"

out=$(bash "$script" "$art" :shared-adapter:compileJava "Does the generated interface compile?"); code=$?
check "spike exits with Gradle's code" $code
grep -q "^gradlew :shared-adapter:compileJava --offline in " "$SPIKE_LOG"; check "one task, offline" $?
! grep -q " in $repo\$" "$SPIKE_LOG"; check "runs in a scratch copy, not the checkout" $?
[ "$(cat a.txt)" = dirty ] && [ -z "$(git status --porcelain -- gradlew)" ]; check "checkout untouched" $?
grep -q "Question: Does the generated interface compile?" "$art/plan-spike.md" && grep -q "Exit: 0" "$art/plan-spike.md" \
  && grep -q "BUILD OUTPUT for :shared-adapter:compileJava" "$art/plan-spike.md"; check "plan-spike.md records it" $?
printf '%s' "$out" | grep -q "BUILD OUTPUT"; check "result printed" $?
dir=$(sed -n 's/.* in //p' "$SPIKE_LOG" | head -1); [ ! -d "$dir" ]; check "scratch copy removed" $?

bash "$script" "$art" compileJava "again" > /dev/null 2>&1; [ $? -eq 2 ]; check "second spike refused" $?
[ "$(wc -l < "$SPIKE_LOG")" -eq 1 ]; check "refused spike runs nothing" $?

# A failed spike still uses up the one run.
art2="$root/art2"; mkdir -p "$art2"
bash "$script" "$art2" broken "Why does it break?" > /dev/null 2>&1; [ $? -eq 1 ]; check "failed spike exits non-zero" $?
grep -q "Exit: 1" "$art2/plan-spike.md"; check "failed spike recorded" $?
bash "$script" "$art2" compileJava "retry" > /dev/null 2>&1; [ $? -eq 2 ]; check "no second spike after a failed one" $?

# Refusals: anything but one task name, or no question.
for bad in "compileJava test" "--offline" "-x" "compileJava;ls" ":a:b --rerun" "" "build&&x"; do
  art3="$root/art-$RANDOM"; mkdir -p "$art3"
  bash "$script" "$art3" "$bad" "q" > /dev/null 2>&1; [ $? -eq 2 ] && [ ! -e "$art3/plan-spike.md" ]; check "refuses task '$bad'" $?
done
art4="$root/art4"; mkdir -p "$art4"
bash "$script" "$art4" compileJava > /dev/null 2>&1; [ $? -eq 2 ] && [ ! -e "$art4/plan-spike.md" ]; check "refuses no question" $?
bash "$script" "$root/none" compileJava "q" > /dev/null 2>&1; [ $? -eq 2 ]; check "refuses a missing artifacts dir" $?
[ "$(wc -l < "$SPIKE_LOG")" -eq 2 ]; check "refusals run nothing" $?

# The plan node's fence. Its denied_tools hold the Gradle wrapper, every script that runs Gradle and every test-suite
# run; plan-spike.sh, the one exception, matches none of them. The plan node is an agent of its own, not an included
# block (the plan-block trial ended 2026-10-24): an include: cannot carry denied_tools.
wf="$top/.archon/workflows/build-feature-copilot.yaml"
block=$(awk '/^  - id: plan$/ { p = 1; next } /^  - id: / { p = 0 } p && /^    include: / { print $2; exit }' "$wf")
[ -z "$block" ]; check "build-feature-copilot's plan includes no block ($block)" $?
denied=$(awk '/^  - id: plan$/ { p = 1; next } /^  - id: / { p = 0 } p && /denied_tools:/ { d = 1 } p && d { print } p && d && /\]/ { exit }' "$wf")
for want in '*gradlew*' '*affected-check*' '*build-shape-check*' '*step-gate*' '*ci-local*' '*local-ci-run*' \
  'bash *.test.sh*' 'sh *.test.sh*' './*.test.sh*' 'scripts/test/*.test.sh*' '.archon/scripts/test/*.test.sh*'; do
  grep -qF "\"Bash($want)\"" <<< "$denied"; check "plan denies Bash($want)" $?
done
grep -q 'plan-spike' <<< "$denied"; [ $? -ne 0 ]; check "plan-spike.sh is not denied" $?

# The analyst's skills (owner request 2026-10-24).
# Without `skills:` the node gets no skill, and skill-check fails a plan that never loaded clean-architecture.
skills=$(awk '/^  - id: plan$/ { p = 1; next } /^  - id: / { p = 0 } p && /^    skills: / { sub(/^    skills: /, ""); print; exit }' "$wf")
[ "$skills" = "[clean-architecture, contract-slice, contract-db-parity, design-review]" ]
check "plan's skills are the analyst-era allow-list ($skills)" $?

# Every non-test script that runs ./gradlew is denied; a script that only names it is listed here, with why.
mention_only=(
  .archon/scripts/plan-spike.sh            # the one allowed Gradle run
  .archon/scripts/run-trace.js             # matches ./gradlew in a log
  .claude/hooks/scripts/scope-guard.sh     # a pattern in the agent fence (D12)
  .claude/hooks/scripts/arch-fitness.sh    # a SubagentStop hook; names it in a hint
  .claude/hooks/scripts/lint-format.sh     # a hook; names it in a hint
  .claude/scripts/ci-workflow-check.sh     # checks the workflow text
  .claude/scripts/class-version-check.sh   # names it in an error
  scripts/tokenomics/tokenomics.js         # parses commands
)
for f in $(cd "$top" && git ls-files -- '*.sh' '*.js' '*.mjs' | grep -v '/test/' | xargs grep -l 'gradlew' 2>/dev/null); do
  base=$(basename "$f"); base="${base%.*}"
  if printf '%s\n' "${mention_only[@]}" | grep -qx "$f"; then continue; fi
  grep -qF "\"Bash(*$base*)\"" <<< "$denied"; check "$f runs Gradle and is denied to the plan" $?
done

echo "plan-spike: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
