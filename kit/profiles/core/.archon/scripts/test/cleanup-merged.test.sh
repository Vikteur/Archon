#!/usr/bin/env bash
# Tests for .archon/scripts/cleanup-merged.sh against a throwaway origin, a clone and its worktrees.
# Usage: bash .archon/scripts/test/cleanup-merged.test.sh   (exit 0 = all pass)
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/cleanup-merged.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$err" 2>/dev/null; fi
}
clean() { (cd "$w" && bash "$script" "$@" >"$root/out" 2>"$err"); }
has_branch() { git -C "$w" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
has_remote() { git -C "$root/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
said() { grep -qF -- "$1" "$err"; }

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"
cd "$w" || exit 2
git config user.name t; git config user.email t@t
printf 'ignored/\n' > .gitignore; echo base > README.md; git add -A; git commit -qm base; git push -q origin main

# branch <name> [merge]: a branch in its own worktree with one commit, pushed; merged into main when asked.
branch() {
  git worktree add -q -b "$1" "$root/wt-$1" main
  (cd "$root/wt-$1" && echo "$1" > "$1.txt" && git add -A && git commit -qm "$1" && git push -q origin "$1")
  if [ "${2:-}" = merge ]; then git merge -q --no-ff --no-edit "$1" && git push -q origin main; fi
}

# 1. Merged, clean, with only ignored files left: worktree, local and remote branch all go.
branch done merge
mkdir -p "$root/wt-done/ignored" && echo build > "$root/wt-done/ignored/out"
clean --dry-run done; rc=$?
check "1 dry run exit 0" $([ "$rc" -eq 0 ] && grep -qF "would delete worktree $root/wt-done" "$root/out"; echo $?)
check "1 dry run deletes nothing" $([ -d "$root/wt-done" ] && has_branch done && has_remote done; echo $?)
clean done; rc=$?
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 worktree gone" $([ ! -d "$root/wt-done" ]; echo $?)
check "1 local branch gone" $(! has_branch done; echo $?)
check "1 remote branch gone" $(! has_remote done; echo $?)

# 2. Not merged: refused, nothing changed.
branch open
clean open; rc=$?
check "2 unmerged refused" $([ "$rc" -eq 1 ] && said "local open" && said "nothing deleted"; echo $?)
check "2 nothing changed" $([ -d "$root/wt-open" ] && has_branch open && has_remote open; echo $?)

# 3. Merged, but the remote branch got a commit after the merge.
branch late merge
(cd "$root/wt-late" && echo more >> late.txt && git commit -qam more && git push -q origin late && git reset -q --hard HEAD~1)
git -C "$root/wt-late" status --porcelain >/dev/null
clean late; rc=$?
check "3 remote ahead refused" $([ "$rc" -eq 1 ] && said "origin/late"; echo $?)
check "3 nothing changed" $([ -d "$root/wt-late" ] && has_remote late; echo $?)

# 4. Merged, but the worktree has an uncommitted change, then an untracked file.
branch dirty merge
echo edit >> "$root/wt-dirty/dirty.txt"
clean dirty; rc=$?
check "4 uncommitted change refused" $([ "$rc" -eq 1 ] && said "uncommitted or untracked"; echo $?)
(cd "$root/wt-dirty" && git checkout -q -- dirty.txt && echo new > untracked.txt)
clean dirty; rc=$?
check "4 untracked file refused" $([ "$rc" -eq 1 ] && said "untracked.txt"; echo $?)
check "4 nothing changed" $([ -d "$root/wt-dirty" ] && has_branch dirty && has_remote dirty; echo $?)
rm "$root/wt-dirty/untracked.txt"

# 5. Merged, but the worktree sits on a commit that is not merged (detached, never pushed).
branch detached merge
(cd "$root/wt-detached" && git checkout -q --detach && echo x > x.txt && git add -A && git commit -qm x)
clean detached "$root/wt-detached"; rc=$?
check "5 worktree HEAD not merged refused" $([ "$rc" -eq 1 ] && said "not in origin/main"; echo $?)

# 6. A stash made on the branch.
branch stashed merge
(cd "$root/wt-stashed" && echo s >> stashed.txt && git stash -q)
clean stashed; rc=$?
check "6 stash refused" $([ "$rc" -eq 1 ] && said "stash entry"; echo $?)
git stash drop -q

# 7. Protected names, the checkout itself, unknown branch, usage.
for b in main master; do clean "$b"; rc=$?; check "7 $b refused" $([ "$rc" -eq 1 ]; echo $?); done
BASE=trunk clean trunk; rc=$?
check "7 the base refused" $([ "$rc" -eq 1 ]; echo $?)
git checkout -q -b here; git push -q origin here; git checkout -q main; git merge -q here
git checkout -q here
clean here; rc=$?
check "7 checked-out branch refused" $([ "$rc" -eq 1 ] && said "checked out here"; echo $?)
git checkout -q main
clean nosuch; rc=$?
check "7 unknown branch refused" $([ "$rc" -eq 1 ] && said "no branch 'nosuch'"; echo $?)
clean dirty "$w"; rc=$?
check "7 the checkout as worktree refused" $([ "$rc" -eq 1 ] && said "the checkout this runs from"; echo $?)
clean dirty "$root"; rc=$?
check "7 a folder that is no worktree refused" $([ "$rc" -eq 1 ] && said "not a worktree"; echo $?)
clean; rc=$?
check "7 usage exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 8. Merged, then the clean worktree of 4 goes once it is clean (the refusals left it intact).
clean dirty; rc=$?
check "8 clean again: deleted" $([ "$rc" -eq 0 ] && [ ! -d "$root/wt-dirty" ] && ! has_branch dirty && ! has_remote dirty; echo $?)

# 9. The sweep: every worktree judged by the same checks; only fully merged ones go (owner decision 2026-10-20).
# Left from above: wt-open (not merged), wt-late (origin ahead), wt-detached (detached), wt-stashed (merged, clean).
branch swept merge
branch busy merge
branch gone merge
rm -rf "$root/wt-gone"
echo "{\"runs\":[{\"id\":\"run-busy\",\"status\":\"running\",\"working_path\":\"$root/wt-busy\"},
  {\"id\":\"run-old\",\"status\":\"completed\",\"working_path\":\"$root/wt-swept\"}]}" > "$root/runs.json"
sweep() { (cd "$w" && CLEANUP_RUNS_JSON="$root/runs.json" bash "$script" "$@" >"$root/out" 2>"$err"); }
kept() { grep -qF "kept $1" "$root/out"; }
sweep --sweep --dry-run; rc=$?
check "9 dry sweep exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "9 dry sweep deletes nothing" $([ -d "$root/wt-swept" ] && [ -d "$root/wt-stashed" ] && has_remote swept; echo $?)
check "9 dry sweep names what it would delete" $(grep -qF "would delete worktree $root/wt-swept" "$root/out" && grep -qF "would delete worktree $root/wt-stashed" "$root/out"; echo $?)
check "9 dry sweep counts" $(grep -qF "sweep would delete 2, kept" "$root/out"; echo $?)
sweep --dry-run --sweep; rc=$?
check "9 --dry-run before --sweep works too" $([ "$rc" -eq 0 ] && [ -d "$root/wt-swept" ]; echo $?)
sweep --sweep; rc=$?
check "9 sweep exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "9 merged and clean: deleted" $([ ! -d "$root/wt-swept" ] && ! has_branch swept && ! has_remote swept && [ ! -d "$root/wt-stashed" ]; echo $?)
check "9 the main checkout kept" $(grep -qF "kept $w: the main checkout" "$root/out"; echo $?)
check "9 not merged: kept with the reason" $(kept "$root/wt-open (open): local open" && [ -d "$root/wt-open" ] && has_remote open; echo $?)
check "9 origin ahead: kept" $(kept "$root/wt-late (late)" && [ -d "$root/wt-late" ]; echo $?)
check "9 detached: kept" $(kept "$root/wt-detached: detached HEAD" && [ -d "$root/wt-detached" ]; echo $?)
check "9 a live run's worktree is kept, though merged" $(kept "$root/wt-busy: a live run works in it (run-busy)" && [ -d "$root/wt-busy" ] && has_branch busy; echo $?)
check "9 a missing folder is kept for prune" $(kept "$root/wt-gone: the folder is gone" && has_branch gone; echo $?)
check "9 counts" $(grep -qF "sweep deleted 2, kept 6" "$root/out"; echo $?)
(cd "$root/wt-open" && CLEANUP_RUNS_JSON="$root/runs.json" bash "$script" --sweep >"$root/out" 2>"$err"); rc=$?
check "9 the checkout it runs from is kept" $([ "$rc" -eq 0 ] && kept "$root/wt-open: the checkout this runs from"; echo $?)
echo 'oops' > "$root/runs.json"
sweep --sweep; rc=$?
check "9 unreadable live runs: refused, nothing deleted" $([ "$rc" -eq 1 ] && said "live Archon runs" && [ -d "$root/wt-busy" ]; echo $?)
for args in "--sweep x" "x --sweep" "--sweep --dry-run x"; do
  # shellcheck disable=SC2086
  sweep $args; rc=$?; check "9 usage '$args'" $([ "$rc" -eq 2 ]; echo $?)
done

# 10. A CodeGraph MCP server that serves the worktree (by --path, or from inside it) is stopped before the folder
# goes; one that serves another folder is left alone.
branch served merge
serve() { (cd "$1" && exec -a "codegraph.js serve --mcp ${2:+--path $2}" sleep 60) & }
gone() { [ ! -e "/proc/$1" ] || grep -q '^[0-9]* ([^)]*) Z' "/proc/$1/stat"; }
serve "$root" "$root/wt-served"; by_path=$!
serve "$root/wt-served"; by_cwd=$!
serve "$root" "$root/wt-served-not"; other=$!
sleep 0.2
clean served; rc=$?
sleep 0.2
check "10 exit 0" $([ "$rc" -eq 0 ] && [ ! -d "$root/wt-served" ]; echo $?)
check "10 the server named by --path is stopped" $(gone "$by_path"; echo $?)
check "10 the server working inside it is stopped" $(gone "$by_cwd"; echo $?)
check "10 it says what it stopped" $([ "$(grep -c '^stopped codegraph server' "$root/out")" -eq 2 ]; echo $?)
check "10 a server of another folder is left alone" $(! gone "$other"; echo $?)
kill "$by_path" "$by_cwd" "$other" 2>/dev/null; wait 2>/dev/null

echo "cleanup-merged: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
