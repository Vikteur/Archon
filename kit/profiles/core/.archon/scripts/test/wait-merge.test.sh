#!/usr/bin/env bash
# Tests for .archon/scripts/wait-merge.sh against a throwaway checkout, a stubbed gh and a stubbed status reader.
# Usage: bash .archon/scripts/test/wait-merge.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wait-merge.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
HEAD_SHA=abcdef0123456789abcdef0123456789abcdef01
MERGE_SHA=1234567890abcdef1234567890abcdef12345678

# gh: `pr view <url> --json <field>` answers PR_STATE (default MERGED), the merge commit, the head and the branch; every
# call is logged, and an Actions question (`run list`) is logged as such and fails: GitHub Actions is never asked.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$*" in
  *"--json state "*) echo "${PR_STATE:-MERGED}" ;;
  *"--json mergeCommit"*) echo "$MERGE_SHA" ;;
  *"--json headRefOid"*) echo "$HEAD_SHA" ;;
  *"--json headRefName"*) echo feat/x ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"
# The status reader: logs "<repo> <sha>" and prints $LSTATE (default "green every job passed").
cat > "$root/status" <<'STUB'
echo "$1 $2" >> "$GH_LOG.status"
echo "${LSTATE:-green every job passed}"
STUB

repo="$root/repo"; mkdir -p "$repo/backlog"; git -C "$repo" init -q; touch "$repo/backlog/config.yml"
log="$root/gh.log"
run() { # run [env...]: wait-merge on pull request 7; sets out, err, rc
  : > "$log"; : > "$log.status"
  out=$(cd "$repo" && env PATH="$root/bin:$PATH" GH_LOG="$log" HEAD_SHA="$HEAD_SHA" MERGE_SHA="$MERGE_SHA" \
    LOCAL_CI_STATUS="$root/status" MERGE_POLL_SECONDS=0 "$@" bash "$script" https://github.com/o/repo/pull/7 2> "$root/err")
  rc=$?; err=$(cat "$root/err")
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}
field() { node -e 'console.log(JSON.parse(process.argv[1])[process.argv[2]])' "$out" "$1"; }

# 1. A merge whose head is green by local CI: ci green, exit 0, the head asked about in the right repo.
run
check "1 green" $([ "$(field ci)" = green ] && [ "$(field state)" = merged ] && [ "$rc" -eq 0 ]; echo $?)
check "1 merge and head" $([ "$(field merge)" = "$MERGE_SHA" ] && [ "$(field head)" = "$HEAD_SHA" ]; echo $?)
check "1 the reader was asked about the head" $(grep -qx "o/repo $HEAD_SHA" "$log.status"; echo $?)
check "1 GitHub Actions is never asked" $(! grep -q "run list\|actions" "$log"; echo $?)

# 2. A red head: ci red, exit 1, nothing finalized.
run LSTATE="red local-ci/test=failure"
check "2 red fails the node" $([ "$(field ci)" = red ] && [ "$rc" -eq 1 ] && echo "$err" | grep -q "not finalized"; echo $?)

# 3. Nothing but green and red is a verdict: none, pending, stale and superseded are none, and fail the node.
for s in "none no status" "pending local-ci/test=pending" "stale local-ci/test=pending" "superseded local-ci/test=PR #7"; do
  run LSTATE="$s"
  check "3 '${s%% *}' is none" $([ "$(field ci)" = none ] && [ "$rc" -eq 1 ]; echo $?)
done

# 4. A missing status reader is none, said plainly; never green.
run LOCAL_CI_STATUS="$root/no-such-reader"
check "4 missing reader: none" $([ "$(field ci)" = none ] && [ "$rc" -eq 1 ] && echo "$err" | grep -q "no-such-reader is missing"; echo $?)

# 5. A closed pull request is reported, and is no failure.
run PR_STATE=CLOSED LSTATE="none no status"
check "5 closed" $([ "$(field state)" = closed ] && [ "$rc" -eq 0 ]; echo $?)

# The poll is 15 s (owner decision 2026-10-23): a 60 s poll put a minute's floor under every run's merged node.
check "6 polls every 15 s by default" $(grep -qF 'POLL=${MERGE_POLL_SECONDS:-15}' "$script"; echo $?)

echo "wait-merge tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
