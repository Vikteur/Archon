#!/usr/bin/env bash
# Tests for .archon/scripts/ci-by-sha.sh against a throwaway repo and a stubbed gh.
# Usage: bash .archon/scripts/test/ci-by-sha.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-by-sha.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
PR_SHA=abcdef0123456789abcdef0123456789abcdef01
EXPLICIT=1234567890abcdef1234567890abcdef12345678
OLD_SHA=0123456789abcdef0123456789abcdef01234567

# gh answers: `pr view <n>` gives PR_SHA. `pr view --json headRefOid,mergeable` walks MERGEABLE_SEQ (space-separated,
# the last one repeats; default MERGEABLE) and answers "<head> <state>": the head is STUB_HEAD (default PR_SHA), or
# OLD_SHA for an entry written old:<state>, GitHub still answering for the commit before a push;
# `pr list` answers PR_NUM (the open pull request of the branch, empty for none). Anything else (an Actions question)
# fails: GitHub Actions is never asked (D14, D21).
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$*" in
  *mergeable*)
    n=$(cat "$GH_LOG.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$GH_LOG.n"
    set -- ${MERGEABLE_SEQ:-MERGEABLE}
    [ "$n" -gt "$#" ] && n=$#
    e=$(eval "echo \${$n}")
    case "$e" in old:*) echo "$OLD_SHA ${e#old:}" ;; *) echo "${STUB_HEAD:-$PR_SHA} $e" ;; esac
    exit 0 ;;
esac
case "$1 $2" in
  "pr view") echo "$PR_SHA" ;;
  "pr list") echo "${PR_NUM:-}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"

# The status reader (local-ci-status.sh): logs "<repo> <sha>" and answers the next entry of LSEQ (";"-separated
# "<state> <detail>" lines, the last one repeats; default "green every job passed").
cat > "$root/status" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "$GH_LOG.status"
n=$(cat "$GH_LOG.sn" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$GH_LOG.sn"
IFS=';' read -ra seq <<< "${LSEQ:-green every job passed}"
[ "$n" -gt "${#seq[@]}" ] && n=${#seq[@]}
echo "${seq[$((n-1))]}"
STUB

# The queue (ci-queue.sh): `none-check <sha>` logs the call and prints QSTATE (default a queued entry).
cat > "$root/queue" <<'STUB'
echo "$*" >> "$GH_LOG.queue"
echo "${QSTATE:-queued #1 pos 1 pid 1}"
STUB

# repo <branch>: a clone of a bare origin checked out on <branch>; sets dir, head.
repo() {
  dir="$root/$1"; mkdir -p "$dir"
  git init -q --bare -b main "$dir.git"
  git clone -q "$dir.git" "$dir" 2>/dev/null
  git -C "$dir" config user.name t; git -C "$dir" config user.email t@t
  git -C "$dir" remote set-url origin https://github.com/o/repo.git
  echo base > "$dir/README.md"; git -C "$dir" add -A; git -C "$dir" commit -qm base
  [ "$2" = main ] || git -C "$dir" switch -qc "$2"
  head=$(git -C "$dir" rev-parse HEAD)
  log="$dir.log"; : > "$log"; : > "$log.status"
}
run() { # run <args...>: ci-by-sha inside the repo; sets out, rc
  out=$( (cd "$dir" && PATH="$root/bin:$PATH" PR_SHA="$PR_SHA" OLD_SHA="$OLD_SHA" GH_LOG="$log" CI_GRACE_POLLS=2 MERGE_POLLS=3 MERGE_WAIT=0 LOCAL_CI_WAIT=0 LOCAL_CI_POLLS=2 LOCAL_CI_STATUS="${LOCAL_CI_STATUS:-$root/status}" CI_QUEUE="${CI_QUEUE:-$root/queue}" bash "$script" "$@") 2>&1 ); rc=$?
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# 1. An explicit SHA is used as given, even from main.
repo one main; run "$EXPLICIT"
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 json carries the sha" $(echo "$out" | grep -q "\"sha\": \"$EXPLICIT\""; echo $?)
check "1 ci asked about the sha" $(grep -qx "o/repo $EXPLICIT" "$log.status"; echo $?)

# 2. A plain number is a pull request, resolved to its head commit.
repo two main; run 5
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 pr resolved" $(grep -q "^gh pr view 5 --json headRefOid" "$log"; echo $?)
check "2 json carries the pr head" $(echo "$out" | grep -q "\"sha\": \"$PR_SHA\""; echo $?)
check "2 ci asked about the pr head" $(grep -qx "o/repo $PR_SHA" "$log.status"; echo $?)

# 3. No argument on the default branch: refused with exit 2, CI is not asked.
repo three main; run
check "3 exit 2" $([ "$rc" -eq 2 ]; echo $?)
check "3 says why" $(echo "$out" | grep -qi "default branch"; echo $?)
check "3 ci not asked" $([ ! -s "$log.status" ]; echo $?)
repo threeb master; run
check "3b exit 2 on master" $([ "$rc" -eq 2 ]; echo $?)

# 4. No argument on a feature branch: HEAD is used.
repo four feat/x; run
check "4 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "4 json carries HEAD" $(echo "$out" | grep -q "\"sha\": \"$head\""; echo $?)
check "4 ci asked about HEAD" $(grep -qx "o/repo $head" "$log.status"; echo $?)

# 5. --check keeps its meaning with an argument: exit 1 unless green.
repo five feat/x; run --check "$EXPLICIT"
check "5 green exits 0" $([ "$rc" -eq 0 ]; echo $?)
repo fiveb feat/x; LSEQ="red local-ci/b=failure" run --check "$EXPLICIT"
check "5 red exits 1" $([ "$rc" -eq 1 ]; echo $?)
check "5 red state" $(echo "$out" | grep -q '"state": "red"'; echo $?)

# 6. A pull request that conflicts with its base never gets CI: answer "conflict" at once, without polling for runs.
repo six feat/x; MERGEABLE_SEQ=CONFLICTING run 5
check "6 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "6 conflict state" $(echo "$out" | grep -q '"state": "conflict"'; echo $?)
check "6 json carries the pr head" $(echo "$out" | grep -q "\"sha\": \"$PR_SHA\""; echo $?)
check "6 detail says to rebase onto main" $(echo "$out" | grep -q '"detail": ".*rebase-main.sh'; echo $?)
check "6 ci not asked" $([ ! -s "$log.status" ]; echo $?)
repo sixb feat/x; MERGEABLE_SEQ=CONFLICTING run --check 5
check "6b --check exits 1 on conflict" $([ "$rc" -eq 1 ]; echo $?)
check "6b conflict state" $(echo "$out" | grep -q '"state": "conflict"'; echo $?)

# 7. UNKNOWN means GitHub is still computing: ask again until it knows.
repo seven feat/x; MERGEABLE_SEQ="UNKNOWN UNKNOWN CONFLICTING" run 5
check "7 conflict after unknown" $(echo "$out" | grep -q '"state": "conflict"'; echo $?)
repo sevenb feat/x; MERGEABLE_SEQ="UNKNOWN MERGEABLE" run 5
check "7b mergeable after unknown goes on to CI" $(echo "$out" | grep -q '"state": "green"'; echo $?)
repo sevenc feat/x; MERGEABLE_SEQ=UNKNOWN run 5
check "7c still unknown after the retries goes on to CI" $(echo "$out" | grep -q '"state": "green"'; echo $?)

# 7d. Just after a push GitHub may still answer mergeable for the old head (TASK-60): that is not computed yet for the
# asked commit, so ask again, and never call the asked commit conflicting from the old one's answer.
repo sevend feat/x; MERGEABLE_SEQ="old:CONFLICTING MERGEABLE" run 5
check "7d an old head's conflict, then mergeable, goes on to CI" $(echo "$out" | grep -q '"state": "green"'; echo $?)
repo sevene feat/x; MERGEABLE_SEQ="old:CONFLICTING" run 5
check "7e a conflict only ever for the old head is no conflict" $(echo "$out" | grep -q '"state": "green"'; echo $?)
check "7e it asked again" $([ "$(grep -c mergeable "$log")" -eq 3 ]; echo $?)

# 8. No argument: the open pull request of the current branch is looked up.
repo eight feat/x; STUB_HEAD=$head PR_NUM=7 MERGEABLE_SEQ=CONFLICTING run
check "8 conflict found via the branch's pr" $(echo "$out" | grep -q '"state": "conflict"'; echo $?)
check "8 json carries HEAD" $(echo "$out" | grep -q "\"sha\": \"$head\""; echo $?)
check "8 asked about pr 7" $(grep -q "^gh pr view 7 --json headRefOid,mergeable" "$log"; echo $?)
repo eightb feat/x; run
check "8b no open pr means no mergeable question" $(! grep -q mergeable "$log"; echo $?)

# 9. The local-ci/<job> statuses are the verdict, and GitHub Actions is never asked (D14, D21).
repo nine feat/x; LSEQ="green every job passed" run --check "$EXPLICIT"
check "9 all local jobs green" $(echo "$out" | grep -q '"state": "green".*local CI'; echo $?)
check "9 green exits 0" $([ "$rc" -eq 0 ]; echo $?)
check "9 actions not asked" $(! grep -q "run \|actions" "$log"; echo $?)
repo nineb feat/x; LSEQ="red local-ci/b=failure" run --check "$EXPLICIT"
check "9b a failed local job is red" $(echo "$out" | grep -q '"state": "red".*local-ci/b=failure'; echo $?)
check "9b red exits 1" $([ "$rc" -eq 1 ]; echo $?)
repo ninec feat/x; LSEQ="pending local-ci/b=missing" run --check "$EXPLICIT"
check "9c a job without a status is never green" $(echo "$out" | grep -q '"state": "none".*local-ci/b=missing'; echo $?)
check "9c exits 1" $([ "$rc" -eq 1 ]; echo $?)
repo nined feat/x; LSEQ="pending local-ci/b=pending" run "$EXPLICIT"
check "9d a job still pending after the wait is none" $(echo "$out" | grep -q '"state": "none".*still pending.*local-ci/b=pending'; echo $?)
repo ninee feat/x; LSEQ="none no local-ci status" run --check "$EXPLICIT"
check "9e no status but a queued run: none after the grace" $(echo "$out" | grep -q '"state": "none".*no local-ci status on 1234567 after .*local-ci-run.sh'; echo $?)
check "9e exits 1" $([ "$rc" -eq 1 ]; echo $?)
check "9e it polled the grace, then stopped, never asking Actions" $([ "$(wc -l < "$log.status")" -eq 2 ] && ! grep -q "run \|actions" "$log"; echo $?)
check "9e it asked the queue about the sha" $(grep -qx "none-check $EXPLICIT" "$log.queue"; echo $?)
repo ninee2 feat/x; QSTATE=none LSEQ="none no local-ci status" CI_GRACE_POLLS=20 run --check "$EXPLICIT"
check "9e2 nothing queued: none at once, no 10-minute grace" $(echo "$out" | grep -q '"state": "none".*no run of it queued after 60s' && [ "$(wc -l < "$log.status")" -eq 1 ]; echo $?)
check "9e2 exits 1" $([ "$rc" -eq 1 ]; echo $?)
repo ninee3 feat/x; CI_QUEUE="$root/no-such-queue" LSEQ="none no local-ci status" run "$EXPLICIT"
check "9e3 no queue script: falls back to the grace polls" $(echo "$out" | grep -q '"state": "none".*after 0s' && [ "$(wc -l < "$log.status")" -eq 2 ]; echo $?)
repo ninee4 feat/x; LSEQ="stale local-ci/b=pending; no live local CI run" run --check "$EXPLICIT"
check "9e4 a dead run is none at once, saying run it again" $(echo "$out" | grep -q '"state": "none".*died before it posted.*local-ci-run.sh on it again' && [ "$(wc -l < "$log.status")" -eq 1 ] && [ "$rc" -eq 1 ]; echo $?)
repo ninee5 feat/x; LSEQ="superseded local-ci/b=PR #7 head is now abcdef1; ask about the new head" run --check "$EXPLICIT"
check "9e5 superseded is none at once, naming the new head" $(echo "$out" | grep -q '"state": "none".*no longer its pull request.*abcdef1' && [ "$(wc -l < "$log.status")" -eq 1 ] && [ "$rc" -eq 1 ]; echo $?)
repo ninee6 feat/x; LSEQ="pending x;stale local-ci/b=pending" run "$EXPLICIT"
check "9e6 pending that turns stale stops waiting" $(echo "$out" | grep -q '"state": "none".*died' && [ "$(wc -l < "$log.status")" -eq 2 ]; echo $?)
repo ninef feat/x; LSEQ="none x;pending local-ci/a=pending;green every job passed" run "$EXPLICIT"
check "9f none, then pending, then green: green" $(echo "$out" | grep -q '"state": "green"'; echo $?)
repo nineg feat/x; LOCAL_CI_STATUS="$root/no-such-reader" run --check "$EXPLICIT"
check "9g a missing status reader is none, loudly" $(echo "$out" | grep -q '"state": "none".*no-such-reader is missing' && [ "$rc" -eq 1 ]; echo $?)
repo nineh feat/x; LSEQ="off local-ci fallback switched off" run --check "$EXPLICIT"
check "9h an unknown reader answer is none" $(echo "$out" | grep -q '"state": "none".*unexpected answer' && [ "$rc" -eq 1 ]; echo $?)
repo ninei feat/x; LSEQ='red local-ci/a=unrecognised success ('"'"'say "hi"'"'"')' run "$EXPLICIT"
check "9i the JSON line stays valid whatever the detail holds" $(node -e 'JSON.parse(process.argv[1])' "$out" 2>/dev/null; echo $?)

echo "ci-by-sha tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
