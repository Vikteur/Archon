#!/usr/bin/env bash
# Tests for .archon/scripts/pr-body.sh against a throwaway repo: the pull request body from its template (the model's
# summary, the ticket, the test commits, the owner decisions word for word, the pr-refresh block, Merge, the footer),
# and the pr-text and open-pr nodes that use it.
# Usage: bash .archon/scripts/test/pr-body.test.sh   (exit 0 = all pass)
set -uo pipefail
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/pr-body.sh"
wf="$here/../workflows/build-feature-copilot.yaml"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

d="$root/r"; mkdir -p "$d"
git init -q --bare -b main "$d/origin.git"
git clone -q "$d/origin.git" "$d/w" 2>/dev/null
cd "$d/w" || exit 2
git config user.name t; git config user.email t@t
echo base > README.md; git add -A; git commit -qm base; git push -q origin main
git checkout -q -b feat
echo a > a.txt; git add -A; git commit -qm "test(step 1): a blank name is refused"
echo b > b.txt; git add -A; git commit -qm "feat: refuse a blank name"
echo c > c.txt; git add -A; git commit -qm "test: the guard holds on update"
git fetch -q origin
art="$root/art"; mkdir -p "$art"
body="$root/body.md"
run() { out=$(ARTIFACTS_DIR="$art" bash "$script" "$@" 2>&1); rc=$?; b=$(cat "$body" 2>/dev/null); out="$out
$b"; }

# 1. Usage: exit 2.
run main TASK-1
check "1 three arguments: exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 2. The whole body from a summary, a ticket and a plan with owner decisions.
printf 'Refuses a blank name on create and update.\nSTOP items touched: none\n' > "$root/summary.md"
cat > "$art/plan.md" <<'PLAN'
# Plan

## Owner decisions
- 2026-11-20, the owner: a blank name is refused, not trimmed.

## Steps
- [x] one
PLAN
run main TASK-7 "$root/summary.md" "$body"
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 the summary first" $(head -1 "$body" | grep -qx 'Refuses a blank name on create and update.'; echo $?)
check "2 no STOP items line" $(! grep -q '^STOP items' "$body"; echo $?)
check "2 the ticket" $(grep -qx 'Backlog ticket: TASK-7' "$body"; echo $?)
check "2 the test commits, oldest first, no code commit" \
  $(grep -A6 '^## Tests' "$body" | grep -x -- '- test(step 1): a blank name is refused' >/dev/null \
    && grep -qx -- '- test: the guard holds on update' "$body" && ! grep -qx -- '- feat: refuse a blank name' "$body" \
    && [ "$(grep -n 'test(step 1)' "$body" | cut -d: -f1)" -lt "$(grep -n 'test: the guard' "$body" | cut -d: -f1)" ]; echo $?)
check "2 the decisions word for word" $(grep -qx '## Decisions' "$body" \
  && grep -qxF -- '- 2026-11-20, the owner: a blank name is refused, not trimmed.' "$body"; echo $?)
check "2 not the steps" $(! grep -q '^## Steps' "$body"; echo $?)
check "2 the empty pr-refresh block before Merge" \
  $(s=$(grep -nx '<!-- pr-refresh:start -->' "$body" | cut -d: -f1); e=$(grep -nx '<!-- pr-refresh:end -->' "$body" | cut -d: -f1)
    m=$(grep -nx '## Merge' "$body" | cut -d: -f1); [ -n "$s" ] && [ "$e" -eq $((s+1)) ] && [ "$m" -gt "$e" ]; echo $?)
check "2 Merge: a team member merges, never the workflow" $(grep -A3 '^## Merge' "$body" | tr '\n' ' ' | grep -q 'A team member reviews and merges.*never merges it itself.*requesting changes'; echo $?)
check "2 ends with the footer" $(tail -1 "$body" | grep -qx '🤖 Generated with GitHub Copilot through Archon (build-feature-copilot)'; echo $?)

# 3. No summary, no ticket, no plan, no test commit.
git checkout -q main
rm -f "$art/plan.md"
run main "" "$root/none.md" "$body"
check "3 exit 0, says no summary" $([ "$rc" -eq 0 ] && head -1 "$body" | grep -q '^No summary was written'; echo $?)
check "3 no ticket line" $(! grep -q '^Backlog ticket' "$body"; echo $?)
check "3 no test commit" $(grep -qx 'No test commit on this branch.' "$body"; echo $?)
check "3 no decisions" $(! grep -q '^## Decisions' "$body"; echo $?)

# 4. The nodes: pr-text writes only the summary and the title, open-pr renders the body before it opens the pull request.
out=$(yq '.nodes[] | select(.id == "pr-text") | .prompt' "$wf")
check "4 pr-text writes pr-summary.md" $(grep -qF '$ARTIFACTS_DIR/pr-summary.md' <<< "$out" && ! grep -qF 'pr-body.md' <<< "$out"; echo $?)
out=$(yq '.nodes[] | select(.id == "open-pr") | .bash' "$wf")
check "4 open-pr renders the body, then opens the pull request" \
  $(tr -s ' \n\\' ' ' <<< "$out" | grep -qF 'bash .archon/scripts/pr-body.sh "$BASE_BRANCH" "$task" "$ARTIFACTS_DIR/pr-summary.md" "$ARTIFACTS_DIR/pr-body.md" && bash .archon/scripts/open-pr.sh'; echo $?)
# Archon shell-quotes a substitution in a bash node, so the ticket id goes through a plain assignment, never in quotes.
check "4 open-pr takes the ticket id unquoted" $(grep -qx ' *task=\$ticket.output.task' <<< "$out" && ! grep -qF '"$ticket.output' <<< "$out"; echo $?)

echo "pr-body: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
