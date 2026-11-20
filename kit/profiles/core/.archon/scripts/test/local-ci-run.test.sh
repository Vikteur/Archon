#!/usr/bin/env bash
# Tests for .archon/scripts/local-ci-run.sh against a throwaway repo, a stubbed gh, status reader and runner.
# Usage: bash .archon/scripts/test/local-ci-run.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/local-ci-run.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
PR_SHA=abcdef0123456789abcdef0123456789abcdef01

OLD_SHA=0123456789abcdef0123456789abcdef01234567

# gh: `repo view` names the repo, `pr view --json number` answers PR_NUM (fails when empty), `pr view <n>` gives PR_SHA,
# or OLD_SHA for as many more calls as the number in $LAG says: GitHub's head lagging just after a push.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "repo view"*) echo owner/repo ;;
  *"--json number"*) [ -n "${PR_NUM:-}" ] && echo "$PR_NUM" || exit 1 ;;
  "pr view "*)
    n=$(cat "$LAG" 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then echo $((n - 1)) > "$LAG"; echo "$OLD_SHA"; else echo "$PR_SHA"; fi ;;
esac
STUB
# The status reader: OLD_SHA already has a green local run; any other commit has $STATE until the runner has run
# POSTS_AFTER times (default 1), after which the run has posted its result: green.
cat > "$root/status" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "$STATUS_LOG"
runs=$(wc -l < "$RUN_LOG" 2>/dev/null || echo 0)
if [ "$2" = "$OLD_SHA" ]; then echo "green some detail"
elif [ "$runs" -ge "${POSTS_AFTER:-1}" ]; then echo "green posted"
else echo "$STATE some detail"; fi
STUB
cat > "$root/runner" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RUN_LOG"; echo runner-output
STUB
chmod +x "$root/bin/gh"
export PATH="$root/bin:$PATH" PR_SHA OLD_SHA LOCAL_CI_STATUS="$root/status" CI_LOCAL="$root/runner" \
  STATUS_LOG="$root/status.log" RUN_LOG="$root/run.log" CI_LOCAL_ROOT="$root/out" LAG="$root/lag" \
  LOCAL_CI_HEAD_POLL=0

r=$root/repo
git init -q "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
head=$(git -C "$r" rev-parse HEAD)

check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
run() { : > "$RUN_LOG"; : > "$STATUS_LOG"; (cd "$r" && STATE=$1 bash "$script" "${@:2}" > "$root/stdout" 2> "$root/stderr"); echo $? > "$root/rc"; }

run none 42
check "a PR number runs the runner on the PR" '[ "$(cat "$RUN_LOG")" = "--post 42" ]'
check "the status is read on the PR head, before and after the run" '[ "$(sort -u "$STATUS_LOG")" = "owner/repo $PR_SHA" ] && [ "$(wc -l < "$STATUS_LOG")" = 2 ]'
check "nothing goes to stdout" '[ ! -s "$root/stdout" ]'
check "the runner output goes to stderr" 'grep -q runner-output "$root/stderr"'
check "exit 0 after a run" '[ "$(cat "$root/rc")" = 0 ]'

run none https://github.com/owner/repo/pull/42/
check "a PR url is read as its number" '[ "$(cat "$RUN_LOG")" = "--post 42" ]'

run none "$head"
check "a sha runs the runner on the sha" '[ "$(cat "$RUN_LOG")" = "--post $head" ]'

run none
check "no argument and no PR runs HEAD" '[ "$(cat "$RUN_LOG")" = "--post $head" ]'
PR_NUM=7 run none
check "no argument takes the branch's PR" '[ "$(cat "$RUN_LOG")" = "--post 7" ]'

for s in pending green red; do
  run "$s" 42
  check "a commit that is already $s is not run again" '[ ! -s "$RUN_LOG" ] && [ "$(cat "$root/rc")" = 0 ]'
done
run superseded 42
check "a superseded commit is not run, and not called already run" '[ ! -s "$RUN_LOG" ] && [ "$(cat "$root/rc")" = 0 ] && grep -q "no longer its pull request" "$root/stderr" && ! grep -q "already has" "$root/stderr"'
run stale 42
check "a commit whose run died is run again" '[ "$(cat "$RUN_LOG")" = "--post 42" ] && [ "$(cat "$root/rc")" = 0 ] && grep -q "died" "$root/stderr"'

# --no-wait: the check happens at once, the run in the background; its output goes to the no-wait log.
run none "$head" --no-wait
check "--no-wait returns 0 at once" '[ "$(cat "$root/rc")" = 0 ] && grep -q "started in the background" "$root/stderr"'
for _ in $(seq 1 50); do [ -s "$RUN_LOG" ] && grep -q "done (exit" "$root/out/no-wait/${head:0:7}.log" 2>/dev/null && break; sleep 0.1; done
check "--no-wait runs the runner on the commit in the background" '[ "$(cat "$RUN_LOG")" = "--post $head" ]'
check "--no-wait logs to no-wait/<sha7>.log" 'grep -q runner-output "$root/out/no-wait/${head:0:7}.log"'
check "--no-wait prints nothing on stdout" '[ ! -s "$root/stdout" ]'
# --no-wait from a run worktree runs the main checkout's copy: the worktree may be deleted while the run goes on.
mkdir -p "$r/.archon/scripts"
sed 's/^set -uo pipefail$/set -uo pipefail; echo from-the-main-copy >\&2/' "$script" > "$r/.archon/scripts/local-ci-run.sh"
wt=$root/wt; git -C "$r" worktree add -q --detach "$wt"
: > "$RUN_LOG"; (cd "$wt" && STATE=none bash "$script" "$head" --no-wait > "$root/stdout" 2> "$root/stderr")
for _ in $(seq 1 50); do grep -q "done (exit" "$root/out/no-wait/${head:0:7}.log" 2>/dev/null && break; sleep 0.1; done
check "--no-wait from a worktree runs the main checkout's copy" 'grep -q from-the-main-copy "$root/out/no-wait/${head:0:7}.log" && [ "$(cat "$RUN_LOG")" = "--post $head" ]'
git -C "$r" worktree remove --force "$wt"; rm -rf "$r/.archon"
run green "$head" --no-wait
check "--no-wait on a commit with a run starts nothing" '[ ! -s "$RUN_LOG" ] && grep -q "already has" "$root/stderr" && ! grep -q background "$root/stderr"'

# The runner returns but posted nothing: it runs once more; when it still posted nothing, exit 1, loudly.
POSTS_AFTER=99 run none 42
check "a run that posts nothing is run once more" '[ "$(wc -l < "$RUN_LOG")" = 2 ]'
check "and then exits 1 naming the commit" '[ "$(cat "$root/rc")" = 1 ] && grep -q "posted nothing for ${PR_SHA:0:7}" "$root/stderr"'
POSTS_AFTER=2 run none 42
check "a retry that posts is exit 0" '[ "$(wc -l < "$RUN_LOG")" = 2 ] && [ "$(cat "$root/rc")" = 0 ]'

run none not-a-commit
check "an unknown commit exits 1 and runs nothing" '[ "$(cat "$root/rc")" = 1 ] && [ ! -s "$RUN_LOG" ]'

run none --logs 42
check "--logs prints the run folder of the PR head" '[ "$(cat "$root/stdout")" = "$root/out/${PR_SHA:0:7}" ] && [ ! -s "$RUN_LOG" ]'
check "--logs reads no status" '[ ! -s "$STATUS_LOG" ]'

# Just after a push GitHub still reports the old head, which already has a green run (TASK-59).
echo 2 > "$LAG"; run none 42 --head "$PR_SHA"
check "--head waits for GitHub to report the pushed head, then runs CI" '[ "$(cat "$RUN_LOG")" = "--post 42" ] && [ "$(cat "$root/rc")" = 0 ]'
check "--head reads the status of the pushed head, not the old one" '[ "$(sort -u "$STATUS_LOG")" = "owner/repo $PR_SHA" ]'
echo 2 > "$LAG"; run none --head "$PR_SHA" 42
check "--head may come before the pull request" '[ "$(cat "$RUN_LOG")" = "--post 42" ]'
echo 1000 > "$LAG"; LOCAL_CI_HEAD_WAIT=0 run none 42 --head "$PR_SHA"
check "a pushed head GitHub never reports exits 1 and runs nothing" '[ "$(cat "$root/rc")" = 1 ] && [ ! -s "$RUN_LOG" ]'
check "the message names both commits" 'grep -q "${PR_SHA:0:7}" "$root/stderr" && grep -q "${OLD_SHA:0:7}" "$root/stderr"'
rm -f "$LAG"
run none 42 --head
check "--head without a commit is bad usage" '[ "$(cat "$root/rc")" = 2 ] && [ ! -s "$RUN_LOG" ]'

# A commit the clone does not have is fetched from origin once, under the lock, then run.
o=$root/origin.git; git init -q --bare "$o"; git -C "$r" remote add origin "$o"
other=$root/other; git clone -q "$o" "$other" 2>/dev/null
git -C "$other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m remote
git -C "$other" push -q origin HEAD:refs/heads/side 2>/dev/null
remote=$(git -C "$other" rev-parse HEAD)
run none "$remote"
check "a commit only origin has is fetched, then run" '[ "$(cat "$RUN_LOG")" = "--post $remote" ] && [ "$(cat "$root/rc")" = 0 ]'
check "the fetch took the lock in the runner folder" '[ -f "$root/out/.fetch.lock" ] && grep -q "fetching origin" "$root/stderr"'
run none "${remote:0:10}"
check "a short sha the clone now has runs without a fetch" '[ "$(cat "$RUN_LOG")" = "--post $remote" ] && ! grep -q "fetching origin" "$root/stderr"'
run none 0123456789abcdef0123456789abcdef0123ffff
check "a sha origin does not have either exits 1 and runs nothing" '[ "$(cat "$root/rc")" = 1 ] && [ ! -s "$RUN_LOG" ]'
check "after one fetch" '[ "$(grep -c "not in this clone; fetching origin" "$root/stderr")" = 1 ]'
(flock 9; sleep 3) 9> "$root/out/.fetch.lock" &
sleep 0.5; LOCAL_CI_FETCH_WAIT=0 run none 0123456789abcdef0123456789abcdef0123ffff
check "a fetch lock held elsewhere is waited for, then given up loudly" 'grep -q "no fetch lock" "$root/stderr" && [ "$(cat "$root/rc")" = 1 ]'
wait

# Archon substitutes a node output already quoted; inside double quotes the quotes stay in the argument (TASK-65).
# A run started before TASK-65 keeps that YAML on a resume: one pair of Archon's quotes is unwrapped (TASK-66).
echo 2 > "$LAG"; run none "'https://github.com/owner/repo/pull/42'" --head "$PR_SHA"
check "an argument in one pair of single quotes is the value inside them" '[ "$(cat "$RUN_LOG")" = "--post 42" ] && [ "$(cat "$root/rc")" = 0 ]'
rm -f "$LAG"
run none "'https://github.com/owner/repo/pull/42" --head "$PR_SHA"
check "any other quote in the argument is bad usage and runs nothing" '[ "$(cat "$root/rc")" = 2 ] && [ ! -s "$RUN_LOG" ]'
check "the message names the argument" 'grep -qF "'"'"'https://github.com/owner/repo/pull/42" "$root/stderr"'
run none '"42"'
check "a double-quoted argument is bad usage" '[ "$(cat "$root/rc")" = 2 ] && [ ! -s "$RUN_LOG" ]'

# A commit that changes only backlog/, docs/retro/ or docs/tokenomics/ runs no CI (owner decisions 2026-10-22,
# 2026-10-23); one that also changes anything else runs as before. On origin/main such a commit runs the newest commit
# under it that changes anything else, when that one has no run yet, so main's tip never stays without a verdict (D9).
on() { local f; for f in "${@:2}"; do mkdir -p "$r/$(dirname "$f")"; echo "$1" >> "$r/$f"; done
  git -C "$r" add -A; git -C "$r" -c user.name=t -c user.email=t@t commit -qm "$1"; git -C "$r" rev-parse HEAD; }
retro=$(on retro docs/retro/TASK-9/lessons-learned.md)
run none "$retro"
check "a retro-only commit runs nothing and reads no status" '[ "$(cat "$root/rc")" = 0 ] && [ ! -s "$RUN_LOG" ] && [ ! -s "$STATUS_LOG" ] && grep -q "gets no local CI" "$root/stderr"'
tokens=$(on tokens docs/tokenomics/daily-token-reports/2026-10-22.md)
run none "$tokens" --no-wait
check "a token-report-only commit runs nothing, also with --no-wait" '[ "$(cat "$root/rc")" = 0 ] && [ ! -s "$RUN_LOG" ] && grep -q "gets no local CI" "$root/stderr" && ! grep -q background "$root/stderr"'
mixed=$(on mixed docs/retro/TASK-9/lessons-learned.md src/App.java)
run none "$mixed"
check "a retro plus code commit runs CI" '[ "$(cat "$RUN_LOG")" = "--post $mixed" ] && [ "$(cat "$root/rc")" = 0 ]'
ticket=$(on ticket "backlog/tasks/task-9 - x.md")
run none "$ticket"
check "a ticket-only commit runs nothing" '[ "$(cat "$root/rc")" = 0 ] && [ ! -s "$RUN_LOG" ] && grep -q "gets no local CI" "$root/stderr"'
mixed=$(on mixed2 "backlog/tasks/task-9 - x.md" src/App.java)
run none "$mixed"
check "a ticket plus code commit runs CI" '[ "$(cat "$RUN_LOG")" = "--post $mixed" ]'
ticket=$(on ticket2 "backlog/tasks/task-9 - x.md"); git -C "$r" push -q origin HEAD:refs/heads/main 2>/dev/null
run none "$ticket"
check "a ticket-only tip of origin/main runs the code commit under it" '[ "$(cat "$RUN_LOG")" = "--post $mixed" ] && grep -q "its verdict is the one of ${mixed:0:7}" "$root/stderr"'
run green "$ticket"
check "and leaves it alone when that one already has a run" '[ ! -s "$RUN_LOG" ] && [ "$(cat "$root/rc")" = 0 ]'

echo "local-ci-run tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
