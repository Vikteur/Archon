#!/usr/bin/env bash
# Tests for .archon/scripts/auto-merge.sh against a stubbed gh and a stubbed ci-by-sha.sh.
# Usage: bash .archon/scripts/test/auto-merge.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/auto-merge.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
PR=https://github.com/o/repo/pull/7
HEAD_SHA=abcdef0123456789abcdef0123456789abcdef01

# gh answers `pr view` with the pull request JSON files $FACTS/1.json, 2.json, ... one per call (the last one repeats),
# `api graphql` with $THREADS unresolved review threads, `pr merge` with exit $MERGE_RC; every call is logged.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    n=$(cat "$GH_LOG.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$GH_LOG.n"
    while [ "$n" -gt 1 ] && [ ! -f "$FACTS/$n.json" ]; do n=$((n-1)); done
    cat "$FACTS/$n.json" ;;
  "api graphql")
    nodes=""; for _ in $(seq 1 "${THREADS:-0}"); do nodes="$nodes{\"isResolved\":false},"; done
    echo "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[$nodes{\"isResolved\":true}]}}}}}" ;;
  "pr merge") exit "${MERGE_RC:-0}" ;;
  "pr ready") exit 0 ;;
  "api repos/o/repo/commits/main") echo "${TIP_SHA:-1111111111111111111111111111111111111111}" ;;
  "api repos/"*) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"
cat > "$root/bin/ci" <<'STUB'
#!/usr/bin/env bash
echo "ci $*" >> "$GH_LOG"
echo "{\"state\": \"${CI_STATE:-green}\", \"sha\": \"$1\", \"detail\": \"${CI_DETAIL:-ok}\"}"
STUB

# The status reader answers main's tip: the words of $TIP_STATES one per call (the last one repeats; green when unset),
# logged as "status <repo> <sha>"; local-ci-run.sh logs "run <args>" and exits $RUN_RC.
cat > "$root/bin/status" <<'STUB'
#!/usr/bin/env bash
echo "status $*" >> "$GH_LOG"
read -ra s <<< "${TIP_STATES:-green}"
n=$(cat "$GH_LOG.t" 2>/dev/null || echo 0); echo $((n+1)) > "$GH_LOG.t"
[ "$n" -ge "${#s[@]}" ] && n=$((${#s[@]}-1))
echo "${s[$n]} local-ci/test=detail"
STUB
cat > "$root/bin/run-ci" <<'STUB'
#!/usr/bin/env bash
echo "run $*" >> "$GH_LOG"; exit "${RUN_RC:-0}"
STUB
chmod +x "$root/bin/status" "$root/bin/run-ci"
export LOCAL_CI_STATUS="$root/bin/status" LOCAL_CI_RUN="$root/bin/run-ci"

# fact <n> <state> <mergeable> [draft] [requests] [reviews json] [merge commit]: writes the n-th pull request answer.
fact() {
  local reqs="[]"
  [ "${5:-0}" -gt 0 ] && reqs='[{"login":"a"}]'
  echo "{\"state\":\"$2\",\"mergeable\":\"$3\",\"isDraft\":${4:-false},\"headRefOid\":\"$HEAD_SHA\",
    \"mergeCommit\":${7:-null},\"reviewRequests\":$reqs,\"reviews\":${6:-[]}}" > "$FACTS/$1.json"
}
setup() { case_dir="$root/$1"; FACTS="$case_dir/facts"; mkdir -p "$FACTS"; log="$case_dir/gh.log"; : > "$log"; }
run() { # run <extra args...>: sets out (stdout), err, rc
  out=$(PATH="$root/bin:$PATH" GH_LOG="$log" FACTS="$FACTS" CI_BY_SHA="$root/bin/ci" AUTO_MERGE_POLL_SECONDS=0 \
    timeout 30 bash "$script" "$PR" "$@" 2> "$case_dir/err"); rc=$?; err=$(cat "$case_dir/err")
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}
merged='{"oid":"feedface"}'

# 1. Green CI, no reviews pending: it merges with a merge commit pinned to the head, then reports the merge commit.
setup one; fact 1 OPEN MERGEABLE; fact 2 MERGED UNKNOWN false 0 '[]' "$merged"
unset CI_STATE THREADS MERGE_RC
run
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 merged" $(echo "$out" | grep -q '"state":"merged"'; echo $?)
check "1 reports the merge commit" $(echo "$out" | grep -q '"sha":"feedface"'; echo $?)
check "1 merge commit, pinned to the head" $(grep -q "pr merge $PR --merge --match-head-commit $HEAD_SHA" "$log"; echo $?)
check "1 CI asked by the head sha" $(grep -q "^ci $HEAD_SHA" "$log"; echo $?)

# 2. A conflict is reported at once: no CI asked, no merge.
setup two; fact 1 OPEN CONFLICTING
run
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 conflict" $(echo "$out" | grep -q '"state":"conflict"'; echo $?)
check "2 no merge" $(! grep -q "pr merge" "$log"; echo $?)
check "2 no CI asked" $(! grep -q "^ci " "$log"; echo $?)

# 3. Red CI is reported with its detail, never merged.
setup three; fact 1 OPEN MERGEABLE
CI_STATE=red CI_DETAIL="build failed" run
check "3 red" $(echo "$out" | grep -q '"state":"red"'; echo $?)
check "3 carries the detail" $(echo "$out" | grep -q 'build failed'; echo $?)
check "3 no merge" $(! grep -q "pr merge" "$log"; echo $?)

# 4. No CI run for the head: no merge, exit 1 (P5).
setup four; fact 1 OPEN MERGEABLE
CI_STATE=none run
check "4 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "4 none" $(echo "$out" | grep -q '"state":"none"'; echo $?)
check "4 no merge" $(! grep -q "pr merge" "$log"; echo $?)

# 5. A requested review that is not given yet holds the merge until it is gone.
setup five; fact 1 OPEN MERGEABLE false 1; fact 2 OPEN MERGEABLE false 1; fact 3 OPEN MERGEABLE; \
  fact 4 MERGED UNKNOWN false 0 '[]' "$merged"
run
check "5 merged in the end" $(echo "$out" | grep -q '"state":"merged"'; echo $?)
check "5 said why it waited" $(echo "$err" | grep -q "requested review"; echo $?)
check "5 merged once, after the request was gone" $([ "$(grep -c "pr merge" "$log")" -eq 1 ] && \
  [ "$(grep -n "pr merge" "$log" | cut -d: -f1)" -gt "$(grep -n "pr view" "$log" | sed -n 3p | cut -d: -f1)" ]; echo $?)

# 6. A reviewer's latest review requesting changes holds the merge; an approval by the same reviewer after it releases it.
setup six
cr='[{"author":{"login":"rev"},"state":"CHANGES_REQUESTED"}]'
ok='[{"author":{"login":"rev"},"state":"CHANGES_REQUESTED"},{"author":{"login":"rev"},"state":"COMMENTED"},{"author":{"login":"rev"},"state":"APPROVED"}]'
fact 1 OPEN MERGEABLE false 0 "$cr"; fact 2 OPEN MERGEABLE false 0 "$ok"; fact 3 MERGED UNKNOWN false 0 '[]' "$merged"
run
check "6 waited on changes requested" $(echo "$err" | grep -q "changes requested by rev"; echo $?)
check "6 merged once approved" $([ "$(grep -c "pr merge" "$log")" -eq 1 ]; echo $?)
setup sixb; fact 1 OPEN MERGEABLE false 0 "$cr"
out=$( (PATH="$root/bin:$PATH" GH_LOG="$log" FACTS="$FACTS" CI_BY_SHA="$root/bin/ci" AUTO_MERGE_POLL_SECONDS=0 \
  timeout 5 bash "$script" "$PR") 2>&1 ); rc=$?
check "6b changes requested never merges" $([ "$rc" -eq 124 ] && ! grep -q "pr merge" "$log"; echo $?)

# 7. An unresolved review thread holds the merge.
setup seven; fact 1 OPEN MERGEABLE
out=$( (PATH="$root/bin:$PATH" GH_LOG="$log" FACTS="$FACTS" CI_BY_SHA="$root/bin/ci" AUTO_MERGE_POLL_SECONDS=0 THREADS=2 \
  timeout 5 bash "$script" "$PR") 2>&1 ); rc=$?
check "7 waits on unresolved threads" $([ "$rc" -eq 124 ] && echo "$out" | grep -q "2 unresolved review thread"; echo $?)
check "7 never merges" $(! grep -q "pr merge" "$log"; echo $?)

# 8. A draft is marked ready before the merge; --pre runs before the merge, and a failing --pre blocks it (exit 1).
setup eight; fact 1 OPEN MERGEABLE true; fact 2 MERGED UNKNOWN false 0 '[]' "$merged"
run --pre "echo pre-ran >> '$log'"
check "8 ready before merge" $(grep -n "pr ready\|pr merge" "$log" | head -1 | grep -q "pr ready"; echo $?)
check "8 pre ran before the merge" $(grep -n "pre-ran\|pr merge" "$log" | head -1 | grep -q "pre-ran"; echo $?)
setup eightb; fact 1 OPEN MERGEABLE
run --pre "exit 3"
check "8b failing pre exits 1" $([ "$rc" -eq 1 ]; echo $?)
check "8b blocked" $(echo "$out" | grep -q '"state":"blocked"'; echo $?)
check "8b no merge" $(! grep -q "pr merge" "$log"; echo $?)

# 9. A refused merge (the head moved) is retried on the next poll, not reported as merged.
setup nine; fact 1 OPEN MERGEABLE; fact 2 OPEN MERGEABLE; fact 3 MERGED UNKNOWN false 0 '[]' "$merged"
out=$(PATH="$root/bin:$PATH" GH_LOG="$log" FACTS="$FACTS" CI_BY_SHA="$root/bin/ci" AUTO_MERGE_POLL_SECONDS=0 MERGE_RC=1 \
  bash "$script" "$PR" 2> "$case_dir/err"); rc=$?; err=$(cat "$case_dir/err")
check "9 said the merge was refused" $(echo "$err" | grep -q "refused"; echo $?)
check "9 reported merged only once GitHub says so" $(echo "$out" | grep -q '"state":"merged"'; echo $?)

# 10. Closed without a merge, and a malformed url.
setup ten; fact 1 CLOSED UNKNOWN
run
check "10 closed" $(echo "$out" | grep -q '"state":"closed"'; echo $?)
out=$(bash "$script" not-a-url 2>&1); rc=$?
check "10 bad url exits 2" $([ "$rc" -eq 2 ]; echo $?)

# 11. --no-merge (build-feature's gate; TASK-58): when all is clear it runs --pre, marks a draft ready and reports ready
#     without merging; the delegator or the owner merges.
setup eleven; fact 1 OPEN MERGEABLE true
run --pre "echo pre-ran >> '$log'" --no-merge
check "11 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "11 ready, at the head" $(echo "$out" | grep -q '"state":"ready","sha":"'"$HEAD_SHA"'"'; echo $?)
check "11 pre ran, draft marked ready" $(grep -q "pre-ran" "$log" && grep -q "pr ready" "$log"; echo $?)
check "11 no merge" $(! grep -q "pr merge" "$log"; echo $?)
setup elevenb; fact 1 OPEN MERGEABLE false 0 "$cr"; fact 2 OPEN MERGEABLE false 0 "$ok"
run --no-merge
check "11b waits on requested changes, then ready" $(echo "$err" | grep -q "changes requested by rev" && \
  echo "$out" | grep -q '"state":"ready"' && ! grep -q "pr merge" "$log"; echo $?)
setup elevenc; fact 1 MERGED UNKNOWN false 0 '[]' "$merged"
run --no-merge
check "11c a merge by someone else is still reported" $(echo "$out" | grep -q '"state":"merged"'; echo $?)

# 12. The merge goes only onto a green main tip (C14, D9): the tip is asked by its sha before the merge.
TIP=1111111111111111111111111111111111111111
setup twelve; fact 1 OPEN MERGEABLE; fact 2 MERGED UNKNOWN false 0 '[]' "$merged"
run
check "12 the tip of main is asked before the merge" $(grep -n "status o/repo $TIP\|pr merge" "$log" | head -1 | grep -q status; echo $?)

# 12b. A red tip: main-red, exit 1, no merge.
setup twelveb; fact 1 OPEN MERGEABLE
TIP_STATES=red run
check "12b main-red, exit 1" $([ "$rc" -eq 1 ] && echo "$out" | grep -q '"state":"main-red","sha":"'"$TIP"'"'; echo $?)
check "12b no merge" $(! grep -q "pr merge" "$log"; echo $?)

# 12c. A tip without a verdict: local CI started on it once, waited for, then merged once green.
setup twelvec; fact 1 OPEN MERGEABLE; fact 4 MERGED UNKNOWN false 0 '[]' "$merged"
TIP_STATES="none none green" run
check "12c merged once the tip is green" $([ "$rc" -eq 0 ] && echo "$out" | grep -q '"state":"merged"'; echo $?)
check "12c local CI started on the tip once" $([ "$(grep -c "^run $TIP --no-wait" "$log")" -eq 1 ]; echo $?)
check "12c the wait is said" $(echo "$err" | grep -q "has no CI verdict"; echo $?)

# 12d. A stale tip (its run died) is started again; a pending one is only waited for.
setup twelved; fact 1 OPEN MERGEABLE; fact 4 MERGED UNKNOWN false 0 '[]' "$merged"
TIP_STATES="pending stale green" run
check "12d pending waited, stale started, then merged" $([ "$rc" -eq 0 ] && [ "$(grep -c "^run $TIP" "$log")" -eq 1 ] \
  && echo "$err" | grep -q "still going"; echo $?)

# 12e. --no-merge does not ask about main's tip: a ready pull request waits for the merge, where the tip is checked.
setup twelvee; fact 1 OPEN MERGEABLE
TIP_STATES=red run --no-merge
check "12e --no-merge: ready, the tip not asked" $(echo "$out" | grep -q '"state":"ready"' && ! grep -q "^status" "$log"; echo $?)

# 13. --head (merge-ready.sh, D7): it merges only that head; a moved head answers moved and merges nothing.
setup thirteen; fact 1 OPEN MERGEABLE; fact 2 MERGED UNKNOWN false 0 '[]' "$merged"
run --head "$HEAD_SHA"
check "13 the expected head merges" $([ "$rc" -eq 0 ] && echo "$out" | grep -q '"state":"merged"' \
  && grep -q "pr merge $PR --merge --match-head-commit $HEAD_SHA" "$log"; echo $?)
setup thirteenb; fact 1 OPEN MERGEABLE
run --head 1111111111111111111111111111111111111111
check "13b a moved head: moved, exit 0" $([ "$rc" -eq 0 ] && echo "$out" | grep -q '"state":"moved","sha":"'"$HEAD_SHA"'"'; echo $?)
check "13b nothing merged, no CI asked" $(! grep -q "pr merge" "$log" && ! grep -q "^ci " "$log"; echo $?)

echo "auto-merge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
