#!/usr/bin/env bash
# Tests for .archon/scripts/rebase-behind.sh against throwaway repos with a real bare origin, the real rebase-main.sh
# and force-push.sh, a stubbed gh, and stubs of local-ci-run.sh and ci-by-sha.sh.
# Usage: bash .archon/scripts/test/rebase-behind.test.sh   (exit 0 = all pass)
set -uo pipefail
# A local CI run exports its reuse mode and scope (ci-local.sh); the policy under test must not inherit them.
unset CI_REUSE CI_SCOPE

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/rebase-behind.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
pr=https://github.com/o/r/pull/7

# gh answers `pr view` with "<state>\t<branch>\t<head>\t<base>\t<cross>": PR_STATE (OPEN), PR_BRANCH (feat/x), the
# branch's commit on origin unless PR_HEAD is set, base main, PR_CROSS (false). The stubs log their calls to $LOG; the
# ci-by-sha stub answers CI_STATE (green).
mkdir -p "$root/bin" "$root/stubs"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$LOG"
case "$*" in
  "pr view"*)
    b=${PR_BRANCH:-feat/x}
    h=${PR_HEAD:-$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$b" 2>/dev/null)}
    printf '%s\t%s\t%s\t%s\t%s\n' "${PR_STATE:-OPEN}" "$b" "$h" main "${PR_CROSS:-false}" ;;
  *) exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "local-ci-run $*" >> "$LOG"\n' > "$root/stubs/local-ci-run.sh"
cat > "$root/stubs/ci-by-sha.sh" <<'STUB'
#!/usr/bin/env bash
echo "ci-by-sha $*" >> "$LOG"
echo "{\"state\": \"${CI_STATE:-green}\", \"sha\": \"$1\", \"detail\": \"local-ci/test failed\"}"
STUB
chmod +x "$root/bin/gh" "$root/stubs/"*.sh

# repo <name>: a bare origin, the main checkout $dir (on main, as the delegator's), a second clone $other that plays
# main, and the run's worktree $wt on feat/x, pushed with an upstream. backlog/t.md has ten lines.
repo() {
  dir="$root/$1"; other="$root/$1-other"; wt="$root/$1-wt"; origin="$dir.git"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$dir" 2>/dev/null
  for c in "$dir"; do git -C "$c" config user.name t; git -C "$c" config user.email t@t; git -C "$c" config core.autocrlf false; done
  mkdir -p "$dir/backlog" "$dir/src"
  seq 1 10 > "$dir/backlog/t.md"; echo code > "$dir/src/a.txt"
  git -C "$dir" add -A; git -C "$dir" commit -qm base; git -C "$dir" push -q origin main 2>/dev/null
  git clone -q "$origin" "$other" 2>/dev/null
  git -C "$other" config user.name t; git -C "$other" config user.email t@t; git -C "$other" config core.autocrlf false
  git -C "$dir" worktree add -q -b feat/x "$wt" 2>/dev/null
  echo feature > "$wt/src/b.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm feature
  git -C "$wt" push -q -u origin feat/x 2>/dev/null
}
on_main() { # on_main <file> <text>: a commit on main, pushed from the other clone
  mkdir -p "$(dirname "$other/$1")"; printf '%s\n' "$2" >> "$other/$1"
  git -C "$other" add -A; git -C "$other" commit -qm "main: $1"; git -C "$other" push -q origin main 2>/dev/null
}
run() { # run [env...]: the script from the main checkout; sets out (stdout), err, rc, log
  : > "$root/log"
  out=$(cd "$dir" && env PATH="$root/bin:$PATH" LOG="$root/log" ORIGIN="$origin" CI_LOCAL_ROOT="$root/ci" \
    LOCAL_CI_RUN="$root/stubs/local-ci-run.sh" CI_BY_SHA="$root/stubs/ci-by-sha.sh" REBASE_FETCH_WAIT=0 "$@" \
    bash "$script" "$pr" 2> "$root/err"); rc=$?
  err=$(cat "$root/err"); log=$(cat "$root/log")
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; printf '%s\n%s\n' "$out" "$err" | sed 's/^/    /'; fi
}
state_is() { [[ "$out" == *"\"state\":\"$1\""* ]]; }
origin_head() { git --git-dir="$origin" rev-parse feat/x; }

# 1. Behind by a code commit: rebased onto origin/main, force-pushed, CI asked for the new head, green.
repo one
on_main src/c.txt main-code
old=$(origin_head)
run
new=$(git -C "$wt" rev-parse HEAD)
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 state green" $(state_is green; echo $?)
check "1 origin has the rebased head" $([ "$(origin_head)" = "$new" ] && [ "$new" != "$old" ]; echo $?)
check "1 the branch sits on origin/main" $(git -C "$wt" merge-base --is-ancestor origin/main HEAD; echo $?)
check "1 no merge commit" $([ -z "$(git -C "$wt" rev-list --merges origin/main..HEAD)" ]; echo $?)
check "1 CI asked for the new head" $(grep -qx "local-ci-run $pr --head $new" <<< "$log"; echo $?)
check "1 verdict read by the new SHA" $(grep -qx "ci-by-sha $new" <<< "$log"; echo $?)
check "1 force-push.sh did the push" $(grep -q "force-pushed: feat/x" <<< "$err"; echo $?)
check "1 main untouched" $([ "$(git --git-dir="$origin" rev-parse main)" = "$(git -C "$other" rev-parse HEAD)" ]; echo $?)

# 2. Already up to date: nothing pushed, no CI.
repo two
old=$(origin_head)
run
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 state up-to-date" $(state_is up-to-date; echo $?)
check "2 origin unchanged" $([ "$(origin_head)" = "$old" ]; echo $?)
check "2 no CI call" $(! grep -q local-ci-run <<< "$log"; echo $?)

# 3. Behind only by a backlog/ file the branch does not touch, reuse not live (the default): not behind (TASK-73).
repo three
on_main backlog/other.md ticket
old=$(origin_head)
run
check "3 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "3 state not-behind" $(state_is not-behind; echo $?)
check "3 origin unchanged" $([ "$(origin_head)" = "$old" ]; echo $?)
check "3 local head unchanged" $([ "$(git -C "$wt" rev-parse HEAD)" = "$old" ]; echo $?)
check "3 no CI call" $(! grep -q local-ci-run <<< "$log"; echo $?)

# 4. The same with reuse live: behind means rebase.
repo four
on_main backlog/other.md ticket
old=$(origin_head)
run CI_REUSE=live
check "4 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "4 state green" $(state_is green; echo $?)
check "4 origin rebased" $([ "$(origin_head)" != "$old" ]; echo $?)

# 5. Reuse live but the kill switch is on (file or CI_SCOPE=all): reuse is off, so TASK-73 holds.
repo five
on_main backlog/other.md ticket
mkdir -p "$root/ci"; touch "$root/ci/scope-all"
run CI_REUSE=live
check "5 scope-all file: not-behind" $(state_is not-behind; echo $?)
rm -f "$root/ci/scope-all"
run CI_REUSE=live CI_SCOPE=all
check "5 CI_SCOPE=all: not-behind" $(state_is not-behind; echo $?)

# 6. A backlog/ file both sides change (no textual conflict): behind under task-73 too, so rebased.
repo six
sed -i '1s/.*/ours/' "$wt/backlog/t.md"; git -C "$wt" commit -qam "ours: t.md"; git -C "$wt" push -q origin feat/x 2>/dev/null
sed -i '10s/.*/theirs/' "$other/backlog/t.md"; git -C "$other" commit -qam "theirs: t.md"; git -C "$other" push -q origin main 2>/dev/null
old=$(origin_head)
run
check "6 state green" $(state_is green; echo $?)
check "6 origin rebased" $([ "$(origin_head)" != "$old" ]; echo $?)

# 7. A real conflict: exit 1, rebase aborted, nothing pushed, the worktree as it was.
repo seven
echo ours > "$wt/src/a.txt"; git -C "$wt" commit -qam "ours: a"; git -C "$wt" push -q origin feat/x 2>/dev/null
on_main src/a.txt theirs
old=$(origin_head)
run
check "7 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "7 state conflict" $(state_is conflict; echo $?)
check "7 names the file" $(grep -q 'src/a.txt' <<< "$err"; echo $?)
check "7 origin unchanged" $([ "$(origin_head)" = "$old" ]; echo $?)
check "7 local head unchanged and clean" $([ "$(git -C "$wt" rev-parse HEAD)" = "$old" ] && [ -z "$(git -C "$wt" status --porcelain)" ]; echo $?)
check "7 no CI call" $(! grep -q local-ci-run <<< "$log"; echo $?)

# 8. Rebased and pushed, but CI on the new head is red: exit 4, state red, sha the new head.
repo eight
on_main src/c.txt main-code
run CI_STATE=red
new=$(git -C "$wt" rev-parse HEAD)
check "8 exit 4" $([ "$rc" -eq 4 ]; echo $?)
check "8 state red" $(state_is red; echo $?)
check "8 names the new head" $([[ "$out" == *"\"sha\":\"$new\""* ]]; echo $?)
check "8 pushed" $([ "$(origin_head)" = "$new" ]; echo $?)

# 9. Refusals: nothing changes on origin, exit 3.
repo nine
on_main src/c.txt main-code
old=$(origin_head)
echo dirty >> "$wt/src/a.txt"
run
check "9 dirty worktree refused" $([ "$rc" -eq 3 ] && state_is refused && grep -q 'not clean' <<< "$err"; echo $?)
git -C "$wt" checkout -q -- src/a.txt
echo more > "$wt/src/d.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm unpushed
run
check "9 unpushed local commit refused" $([ "$rc" -eq 3 ] && grep -q "not the pull request's head" <<< "$err"; echo $?)
git -C "$wt" reset -q --hard "$old"
run PR_BRANCH=main
check "9 main refused" $([ "$rc" -eq 3 ] && grep -q "only a run's own" <<< "$err"; echo $?)
run PR_CROSS=true
check "9 a fork refused" $([ "$rc" -eq 3 ] && grep -q fork <<< "$err"; echo $?)
run PR_STATE=MERGED
check "9 a merged pull request refused" $([ "$rc" -eq 3 ] && grep -q 'not open' <<< "$err"; echo $?)
run PR_BRANCH=feat/none
check "9 no worktree refused" $([ "$rc" -eq 3 ] && grep -q 'no worktree' <<< "$err"; echo $?)
check "9 origin never changed" $([ "$(origin_head)" = "$old" ]; echo $?)
check "9 no CI call" $(! grep -q local-ci-run "$root/log"; echo $?)

# 10. Someone pushed to the branch after our last look and GitHub still reported our head: the lease refuses the push,
#     the local branch goes back to the old head, exit 3.
repo ten
on_main src/c.txt main-code
mine=$(origin_head)
late="$root/ten-late"; git clone -q -b feat/x "$origin" "$late" 2>/dev/null
git -C "$late" config user.name t; git -C "$late" config user.email t@t
echo late > "$late/late.txt"; git -C "$late" add -A; git -C "$late" commit -qm late; git -C "$late" push -q origin feat/x 2>/dev/null
theirs=$(origin_head)
run PR_HEAD="$mine"
check "10 exit 3" $([ "$rc" -eq 3 ]; echo $?)
check "10 says the lease" $(grep -q lease <<< "$err"; echo $?)
check "10 the other push survives" $([ "$(origin_head)" = "$theirs" ]; echo $?)
check "10 local branch back at its head" $([ "$(git -C "$wt" rev-parse HEAD)" = "$mine" ]; echo $?)

# 11. --policy, and bad usage.
out=$(cd "$dir" && CI_LOCAL_ROOT="$root/ci" bash "$script" --policy)
check "11 policy task-73 by default" $([ "$out" = task-73 ]; echo $?)
out=$(cd "$dir" && CI_LOCAL_ROOT="$root/ci" CI_REUSE=live bash "$script" --policy)
check "11 policy behind-means-rebase when reuse is live" $([ "$out" = behind-means-rebase ]; echo $?)
out=$(cd "$dir" && CI_LOCAL_ROOT="$root/ci" CI_REUSE=shadow bash "$script" --policy)
check "11 policy task-73 in shadow mode" $([ "$out" = task-73 ]; echo $?)
mkdir -p "$root/ci" && touch "$root/ci/reuse-live"
out=$(cd "$dir" && CI_LOCAL_ROOT="$root/ci" bash "$script" --policy)
check "11 policy behind-means-rebase under the reuse-live file" $([ "$out" = behind-means-rebase ]; echo $?)
out=$(cd "$dir" && CI_LOCAL_ROOT="$root/ci" CI_REUSE=shadow bash "$script" --policy)
check "11 CI_REUSE=shadow overrides the reuse-live file" $([ "$out" = task-73 ]; echo $?)
rm "$root/ci/reuse-live"
(cd "$dir" && bash "$script" 2>/dev/null); rc=$?
check "11 no argument: exit 2" $([ "$rc" -eq 2 ]; echo $?)
(cd "$dir" && bash "$script" https://github.com/o/r/issues/1 2>/dev/null); rc=$?
check "11 not a pull request url: exit 2" $([ "$rc" -eq 2 ]; echo $?)

echo "rebase-behind tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
