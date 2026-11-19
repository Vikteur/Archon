#!/usr/bin/env bash
# Tests for .archon/scripts/close-out.sh against throwaway repos and stubbed gh/archon.
# Usage: bash .archon/scripts/test/close-out.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-out.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# Stubs first on PATH: gh answers from STUB_HEAD; archon models the real refusal inside a running workflow.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr list"*) # the open run pull requests (STUB_OPEN_PRS, one number per line, the jq filter applied); STUB_LIST_FAIL fails
    [ -n "${STUB_LIST_FAIL:-}" ] && exit 1
    printf '%s' "${STUB_OPEN_PRS:-}" ;;
  *number*) echo 7 ;;
  *headRefOid*) echo "$STUB_HEAD" ;;
  *headRefName*) echo feat ;;
esac
STUB
cat > "$root/bin/archon" <<'STUB'
#!/usr/bin/env bash
echo "archon $*" >> "$ARCHON_LOG"
[ "$1" = complete ] || exit 0
if [ "${2:-}" != --force ]; then
  echo "Blocked: $2 ✗ running workflow: build-feature (id: x) Use --force to override." >&2
  exit 1
fi
branch=$3
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $1=="branch" && $2==b {print w}')
case "${STUB_MODE:-}" in
  failzero) # real archon on a half-removed worktree: prints a failed line, exits 0, leaves the registered empty folder
    find "$wt" -mindepth 1 -delete; echo "Complete: 0 completed, 1 failed" >&2; exit 0 ;;
  noop) echo "Complete: 0 completed, 1 failed" >&2; exit 0 ;;
esac
[ -n "$wt" ] && git worktree remove --force "$wt"
if [ -n "${STUB_LOCKED:-}" ]; then
  # Windows: the files are gone and git forgot the worktree, but a process holds the directory as its cwd.
  mkdir -p "$wt"
  [ "$STUB_LOCKED" = full ] && echo left > "$wt/left.txt"
  echo "error: failed to delete '$wt': Permission denied" >&2
  exit 1
fi
git branch -D "$branch" > /dev/null
git push -q origin --delete "$branch"
STUB
# git wrapper: with STUB_PERMDENIED set, `worktree remove` empties the folder, keeps it registered and fails the way
# Windows does when a process (a Gradle daemon) holds the directory.
real_git=$(command -v git)
cat > "$root/bin/git" <<STUB
#!/usr/bin/env bash
if [ -n "\${STUB_PERMDENIED:-}" ] && [ "\${1:-}" = worktree ] && [ "\${2:-}" = remove ]; then
  dir=\${!#}
  find "\$dir" -mindepth 1 -delete
  echo "error: failed to delete '\$dir': Permission denied" >&2
  exit 1
fi
exec "$real_git" "\$@"
STUB
chmod +x "$root/bin/gh" "$root/bin/archon" "$root/bin/git"
# The Groma delta check is stubbed: it logs "<HEAD subject> <args>", runs $root/delta.race once when it exists (a merge
# landing between the pull and the push) and exits with the code $root/delta.rc held when it started (0 when absent).
cat > "$root/delta.sh" <<STUB
#!/usr/bin/env bash
echo "\$(git log -1 --format=%s) \$*" >> "$root/delta.log"
rc=\$(cat "$root/delta.rc" 2>/dev/null || echo 0)
if [ -f "$root/delta.race" ]; then mv "$root/delta.race" "$root/delta.race.ran"; bash "$root/delta.race.ran"; fi
exit \$rc
STUB
export GROMA_DELTA="$root/delta.sh"
# local-ci-run.sh is stubbed (CI plan C13): it logs "<cwd> <args>" and exits with the code in $root/run-ci.rc (0 when
# absent). Never the real one: that would start local CI on a throwaway commit.
cat > "$root/run-ci.sh" <<STUB
#!/usr/bin/env bash
echo "\$PWD \$*" >> "$root/run-ci.log"
exit \$(cat "$root/run-ci.rc" 2>/dev/null || echo 0)
STUB
export LOCAL_CI_RUN="$root/run-ci.sh"
# The CI audit is stubbed the same way: it logs "<cwd> <args>" to $root/audit.log, exits with $root/audit.rc.
cat > "$root/audit.sh" <<STUB
#!/usr/bin/env bash
echo "\$PWD \$*" >> "$root/audit.log"
exit \$(cat "$root/audit.rc" 2>/dev/null || echo 0)
STUB
export CI_AUDIT="$root/audit.sh"

# scenario <name>: builds origin, main clone, worktree on feat with one pushed commit; sets main_dir wt head log.
scenario() {
  local d="$root/$1"; mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/main" 2>/dev/null
  git -C "$d/main" config user.name t; git -C "$d/main" config user.email t@t
  echo base > "$d/main/README.md"; git -C "$d/main" add -A; git -C "$d/main" commit -qm base
  git -C "$d/main" push -q origin main
  git -C "$d/main" worktree add -q -b feat "$d/wt"
  echo work > "$d/wt/work.txt"; git -C "$d/wt" add -A; git -C "$d/wt" commit -qm work
  git -C "$d/wt" push -q origin feat
  main_dir="$d/main"; wt="$d/wt"; log="$d/archon.log"; : > "$log"
  head=$(git -C "$wt" rev-parse HEAD)
}
run() { # run: close-out inside the worktree; sets out, rc
  out=$( (cd "$wt" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" \
    bash "$script" "" https://github.com/o/repo/pull/7 "$main_dir") 2>&1 ); rc=$?
}
finish() { # finish: the re-runnable cleanup, from the main checkout; sets out, rc
  out=$( (cd "$main_dir" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" \
    bash "$script" --finish "" https://github.com/o/repo/pull/7 "$main_dir") 2>&1 ); rc=$?
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
called() { grep -q "^archon complete" "$log"; }

# 1. Clean worktree at the merged head: forced complete deletes branch and worktree.
scenario one; run
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 json deleted/removed" $(echo "$out" | grep -q '"branch":"deleted","worktree":"removed"'; echo $?)
check "1 archon --force" $(grep -q "^archon complete --force" "$log"; echo $?)

# 2. A local commit after the PR head: nothing is deleted, archon is not called.
scenario two
echo more > "$wt/more.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm extra
run
check "2 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "2 archon not called" $(! called; echo $?)
check "2 branch kept" $(git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)

# 3. Uncommitted change in the worktree: nothing is deleted, archon is not called.
scenario three
echo dirty >> "$wt/work.txt"
run
check "3 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "3 archon not called" $(! called; echo $?)
check "3 worktree kept" $([ -d "$wt" ]; echo $?)

# 4. Windows: git unregistered the worktree, an empty directory is left, archon fails: branch gone, exit 0, warning.
scenario four
STUB_LOCKED=empty run
check "4 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "4 json deleted/removed" $(echo "$out" | grep -q '"branch":"deleted","worktree":"removed"'; echo $?)
check "4 local branch deleted" $(! git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
check "4 remote branch deleted" $(! git -C "$main_dir" ls-remote --exit-code --heads origin feat >/dev/null 2>&1; echo $?)
check "4 the emptied directory is removed, not left behind" $([ ! -e "$wt" ]; echo $?)

# 5. Unregistered but the directory still holds files: still fails, branch kept.
scenario five
STUB_LOCKED=full run
check "5 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "5 incomplete" $(echo "$out" | grep -q "Close-out incomplete"; echo $?)
check "5 branch kept" $(git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
check "5 files kept" $([ -f "$wt/left.txt" ]; echo $?)

# 6. An empty unregistered sibling of the run worktree is swept; a non-empty one and a registered one are not.
scenario six
d=$(dirname "$main_dir")
mkdir "$d/old-empty" "$d/old-full"; echo x > "$d/old-full/f.txt"
git -C "$main_dir" worktree add -q -b other "$d/other"
run
check "6 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "6 empty sibling swept" $([ ! -e "$d/old-empty" ]; echo $?)
check "6 non-empty sibling kept" $([ -f "$d/old-full/f.txt" ]; echo $?)
check "6 registered sibling kept" $([ -f "$d/other/README.md" ]; echo $?)
check "6 main checkout kept" $([ -d "$main_dir/.git" ]; echo $?)

# 7. Run from the main checkout (not a run worktree): the sweep is skipped, an empty folder beside the repos survives.
scenario seven
d=$(dirname "$main_dir"); mkdir "$d/empty-beside-main"
out=$( (cd "$main_dir" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log"   bash "$script" "" https://github.com/o/repo/pull/7 "$main_dir") 2>&1 ); rc=$?
check "7 empty folder beside the main checkout survives" $([ -d "$d/empty-beside-main" ]; echo $?)

# 8. archon prints a failed line, exits 0 and leaves the registered empty worktree: judged by state, not exit code.
scenario eight
STUB_MODE=failzero run
check "8 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "8 json deleted/removed" $(echo "$out" | grep -q '"branch":"deleted","worktree":"removed"'; echo $?)
check "8 worktree folder gone" $([ ! -e "$wt" ]; echo $?)
check "8 worktree unregistered" $(! git -C "$main_dir" worktree list --porcelain | grep -qF "$(basename "$wt")"; echo $?)
check "8 local branch deleted" $(! git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
check "8 remote branch deleted" $(! git -C "$main_dir" ls-remote --exit-code --heads origin feat >/dev/null 2>&1; echo $?)

# 9. archon exits 0 but did nothing: the worktree is still registered and holds files -> failed, re-runnable command.
scenario nine
STUB_MODE=noop run
check "9 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "9 branch kept" $(git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
check "9 files kept" $([ -f "$wt/work.txt" ]; echo $?)
check "9 prints the exact finishing command" $(echo "$out" | grep -qF -- "bash $script --finish '' https://github.com/o/repo/pull/7 $main_dir"; echo $?)
check "9 no finish by hand" $(! echo "$out" | grep -qi "by hand"; echo $?)

# 10. Squash merge: the branch is not an ancestor of main, so only a forced delete works (tip == merged head proved it).
scenario ten
git -C "$main_dir" merge -q --squash feat && git -C "$main_dir" commit -qm "squash feat" && git -C "$main_dir" push -q origin main
STUB_MODE=failzero run
check "10 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "10 local branch deleted" $(! git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
check "10 remote branch deleted" $(! git -C "$main_dir" ls-remote --exit-code --heads origin feat >/dev/null 2>&1; echo $?)

# 11. Permission denied: git worktree remove fails and leaves an empty registered folder -> rmdir + prune + branch -D.
scenario eleven
STUB_PERMDENIED=1 run
check "11 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "11 json deleted/removed" $(echo "$out" | grep -q '"branch":"deleted","worktree":"removed"'; echo $?)
check "11 folder gone" $([ ! -e "$wt" ]; echo $?)
check "11 local branch deleted" $(! git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)

# 12. --finish redoes only the cleanup, idempotently (and never when the tip is not the merged head).
scenario twelve
find "$wt" -mindepth 1 -delete   # a half-removed worktree left by an earlier run
finish
check "12 finish exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "12 folder gone" $([ ! -e "$wt" ]; echo $?)
check "12 local branch deleted" $(! git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
check "12 archon not called" $(! called; echo $?)
finish
check "12 second finish exit 0" $([ "$rc" -eq 0 ]; echo $?)
scenario twelve-b
echo more > "$wt/more.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm extra
finish
check "12b finish refuses a branch past the merged head" $([ "$rc" -eq 1 ]; echo $?)
check "12b branch kept" $(git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)

# 13. No step stops a process outside the worktree being closed; the forced complete cites the amended rule.
check "13 script stops no foreign process" $(! grep -Eqi 'gradlew|taskkill|pkill|killall|(^|[^a-z])kill[ ]|daemon.*--stop' "$script"; echo $?)
check "13 force cites the amended rule" $(grep -q 'UD-21.c as amended 2026-10-09' "$script"; echo $?)
# 14. The token report script is called with the umbrella dir when it exists, and the JSON line stays the only stdout line.
stub_reports() { # stub_reports <exit code> [noexec]: a commit-reports.sh stub that records its arguments, in an
  # umbrella; noexec leaves it without the execute bit, as git checks it out (TASK-74)
  mkdir -p "$main_dir/scripts/tokenomics" "$main_dir/docs/retro"; echo '# Retro' > "$main_dir/docs/retro/README.md"
  printf '#!/usr/bin/env bash
echo "$*" > "%s/reports.args"
echo {\\"commit\\":\\"abc\\"}
exit %s
' "$(dirname "$main_dir")" "$1" > "$main_dir/scripts/tokenomics/commit-reports.sh"
  [ "${2:-}" = noexec ] || chmod +x "$main_dir/scripts/tokenomics/commit-reports.sh"
}
run_split() { # like run, but keeps stdout apart: sets out (stderr and stdout), json (stdout), rc
  json=$( (cd "$wt" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log"     bash "$script" "" https://github.com/o/repo/pull/7 "$main_dir") 2> "$root/stderr.txt" ); rc=$?
  out="$json
$(cat "$root/stderr.txt")"
}
scenario fourteen; stub_reports 0; run_split
check "14 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "14 report script called with the umbrella dir" $([ "$(cat "$(dirname "$main_dir")/reports.args")" = "$main_dir" ]; echo $?)
check "14 stdout is the unchanged JSON line" $([ "$json" = '{"backlog":"","branch":"deleted","worktree":"removed"}' ]; echo $?)

# 15. A failing report script is only a warning.
scenario fifteen; stub_reports 1; run_split
check "15 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "15 report script was called" $([ -f "$(dirname "$main_dir")/reports.args" ]; echo $?)
check "15 warning on stderr" $(grep -q "token reports were not committed" "$root/stderr.txt"; echo $?)
check "15 stdout is the unchanged JSON line" $([ "$json" = '{"backlog":"","branch":"deleted","worktree":"removed"}' ]; echo $?)

# 15b. A report script without the execute bit (as git checks it out) still runs (TASK-74).
scenario fifteenb; stub_reports 0 noexec; run_split
check "15b exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "15b a non-executable report script is called with the umbrella dir" $([ "$(cat "$(dirname "$main_dir")/reports.args" 2>/dev/null)" = "$main_dir" ]; echo $?)
check "15b no warning about the token reports" $(! grep -q "token reports were not committed" "$root/stderr.txt"; echo $?)

# 16. Without the report script nothing is called and nothing is said about it.
scenario sixteen; run_split
check "16 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "16 no mention of the token reports" $(! grep -q "token reports" "$root/stderr.txt"; echo $?)

# 16b. Token reports wait while another run's pull request is open (R14), and the last close-out commits them.
run_env() { # run_env <VAR=value>...: like run_split, with extra stub settings
  json=$( (cd "$wt" && env PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" "$@" \
    bash "$script" "" https://github.com/o/repo/pull/7 "$main_dir") 2> "$root/stderr.txt" ); rc=$?
}
scenario sixteenb; stub_reports 0; run_env STUB_OPEN_PRS=$'7\n12\n15\n'
check "16b exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "16b the report script is not called while run PRs are open" $([ ! -f "$(dirname "$main_dir")/reports.args" ]; echo $?)
check "16b deferred, naming the open run PRs but its own" $(grep -q 'token reports deferred: run pull requests #12 #15 are open' "$root/stderr.txt"; echo $?)
check "16b stdout is the unchanged JSON line" $([ "$json" = '{"backlog":"","branch":"deleted","worktree":"removed"}' ]; echo $?)
scenario sixteenc; stub_reports 0; run_env STUB_OPEN_PRS=$'7\n'
check "16c only its own PR open: the reports are committed" $([ "$(cat "$(dirname "$main_dir")/reports.args" 2>/dev/null)" = "$main_dir" ]; echo $?)
scenario sixteend; stub_reports 0; run_env STUB_LIST_FAIL=1
check "16d gh cannot list the PRs: deferred" $([ "$rc" -eq 0 ] && [ ! -f "$(dirname "$main_dir")/reports.args" ] && grep -q 'deferred' "$root/stderr.txt"; echo $?)

# 16e. --flush-reports: only the report step, from the main checkout, with the same deferral.
flush() { # flush <VAR=value>...: sets json, rc
  json=$( (cd "$main_dir" && env PATH="$root/bin:$PATH" "$@" bash "$script" --flush-reports) 2> "$root/stderr.txt" ); rc=$?
}
scenario sixteene; stub_reports 0; flush STUB_OPEN_PRS=$'12\n'
check "16e flush with a run PR open: deferred, exit 0" $([ "$rc" -eq 0 ] && [ "$json" = '{"reports":"deferred"}' ] && [ ! -f "$(dirname "$main_dir")/reports.args" ]; echo $?)
flush STUB_OPEN_PRS=
check "16e flush with none open: committed" $([ "$rc" -eq 0 ] && [ "$json" = '{"reports":"committed"}' ] && [ "$(cat "$(dirname "$main_dir")/reports.args" 2>/dev/null)" = "$main_dir" ]; echo $?)
check "16e flush touches no branch or worktree" $([ ! -s "$log" ] && git -C "$main_dir" show-ref --verify --quiet refs/heads/feat; echo $?)
stub_reports 1; flush STUB_OPEN_PRS=
check "16e a failing report script: failed, exit 1" $([ "$rc" -eq 1 ] && [ "$json" = '{"reports":"failed"}' ]; echo $?)

# 17. The ticket is in the repo's own main checkout, which the merge moved on: main is pulled first, so the Backlog
# commit lands on top of the merge and its push is not rejected.
cat > "$root/bin/backlog" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "task view TASK-9 --json" ] && echo '{"task":{"status":"Done","path":"backlog/tasks/task-9.md","parentTaskId":null}}'
STUB
chmod +x "$root/bin/backlog"
scenario seventeen; other="$root/seventeen/other"
mkdir -p "$main_dir/backlog/tasks"; echo todo > "$main_dir/backlog/tasks/task-9.md"
git -C "$main_dir" add -A; git -C "$main_dir" commit -qm ticket; git -C "$main_dir" push -q origin main
git clone -q "$root/seventeen/origin.git" "$other" 2>/dev/null
git -C "$other" config user.name t; git -C "$other" config user.email t@t
echo merged > "$other/work.txt"; git -C "$other" add -A; git -C "$other" commit -qm "the merge"
git -C "$other" push -q origin main
echo done > "$main_dir/backlog/tasks/task-9.md"
out=$( (cd "$wt" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" \
  bash "$script" TASK-9 https://github.com/o/repo/pull/7 "$main_dir") 2>&1 ); rc=$?
origin_log() { git --git-dir="$root/seventeen/origin.git" log -1 --skip="$1" --format=%s main; }
check "17 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "17 ticket committed and pushed" $([ "$(origin_log 0)" = "backlog: TASK-9 done (repo PR #7 merged, CI green on ${head:0:7})" ]; echo $?)
check "17 on top of the merge" $([ "$(origin_log 1)" = "the merge" ]; echo $?)

# 18. Git hooks that print to stdout (the pre-push hook prints its Groma check) do not get into the JSON line.
scenario eighteen
mkdir -p "$main_dir/backlog/tasks"; echo todo > "$main_dir/backlog/tasks/task-9.md"
git -C "$main_dir" add -A; git -C "$main_dir" commit -qm ticket; git -C "$main_dir" push -q origin main
printf '#!/usr/bin/env bash\necho "hook says hi"\n' > "$main_dir/.git/hooks/pre-push"
chmod +x "$main_dir/.git/hooks/pre-push"
echo done > "$main_dir/backlog/tasks/task-9.md"
json=$( (cd "$wt" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" \
  bash "$script" TASK-9 https://github.com/o/repo/pull/7 "$main_dir") 2> "$root/stderr.txt" ); rc=$?
check "18 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "18 hook output on stderr" $(grep -q "hook says hi" "$root/stderr.txt"; echo $?)
check "18 stdout is only the JSON line" \
  $([ "$json" = "{\"backlog\":\"$(git -C "$main_dir" rev-parse --short HEAD)\",\"branch\":\"deleted\",\"worktree\":\"removed\"}" ]; echo $?)

# 19. The Groma delta check runs on the Backlog commit against origin/main before the push.
ticket_scenario() { # ticket_scenario <name>: scenario plus a pushed TASK-9 ticket, edited to done in the main checkout
  scenario "$1"; other="$root/$1/other"
  mkdir -p "$main_dir/backlog/tasks"; echo todo > "$main_dir/backlog/tasks/task-9.md"
  git -C "$main_dir" add -A; git -C "$main_dir" commit -qm ticket; git -C "$main_dir" push -q origin main
  git clone -q "$root/$1/origin.git" "$other" 2>/dev/null
  git -C "$other" config user.name t; git -C "$other" config user.email t@t
  echo done > "$main_dir/backlog/tasks/task-9.md"
  : > "$root/delta.log"; rm -f "$root/delta.rc" "$root/delta.race.ran"
}
run_ticket() { # run_ticket: close-out of TASK-9; sets json (stdout), out (stderr), rc
  json=$( (cd "$wt" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" \
    bash "$script" TASK-9 https://github.com/o/repo/pull/7 "$main_dir") 2> "$root/stderr.txt" ); rc=$?
  out=$(cat "$root/stderr.txt")
}
subject9="backlog: TASK-9 done (repo PR #7 merged, CI green on"
ticket_scenario nineteen; run_ticket
check "19 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "19 the delta checked the Backlog commit against origin/main" \
  $([ "$(cat "$root/delta.log")" = "$subject9 ${head:0:7}) HEAD origin/main" ]; echo $?)

# 20. A merge lands between the pull and the push: the rejected push is rebased once, checked again and pushed.
ticket_scenario twenty
printf 'cd %q && echo merged > work.txt && git add -A && git commit -qm "the merge" && git push -q origin main\n' "$other" \
  > "$root/delta.race"
run_ticket
origin_log() { git --git-dir="$root/twenty/origin.git" log -1 --skip="$1" --format=%s main; }
check "20 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "20 the merge landed during the push" $([ -f "$root/delta.race.ran" ]; echo $?)
check "20 the Backlog commit is on top of the merge" \
  $(origin_log 0 | grep -qF "$subject9" && [ "$(origin_log 1)" = "the merge" ]; echo $?)
check "20 checked again after the rebase" $([ "$(wc -l < "$root/delta.log")" -eq 2 ]; echo $?)
check "20 no local commit is left on main" \
  $([ "$(git -C "$main_dir" rev-parse main)" = "$(git --git-dir="$root/twenty/origin.git" rev-parse main)" ]; echo $?)
check "20 the JSON names the pushed commit" \
  $([ "$json" = "{\"backlog\":\"$(git -C "$main_dir" rev-parse --short HEAD)\",\"branch\":\"deleted\",\"worktree\":\"removed\"}" ]; echo $?)

# 21. A refused Groma check pushes nothing and leaves no local commit: the change stays staged, the node fails.
ticket_scenario twentyone; before=$(git -C "$main_dir" rev-parse HEAD)
echo 1 > "$root/delta.rc"; run_ticket; rm -f "$root/delta.rc"
check "21 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "21 nothing pushed" $([ "$(git --git-dir="$root/twentyone/origin.git" rev-parse main)" = "$before" ]; echo $?)
check "21 no local commit" $([ "$(git -C "$main_dir" rev-parse HEAD)" = "$before" ]; echo $?)
check "21 the change is staged" $([ "$(git -C "$main_dir" diff --cached --name-only)" = backlog/tasks/task-9.md ]; echo $?)
check "21 the reason is reported" $(grep -q "Groma check refused" "$root/stderr.txt"; echo $?)
check "21 the JSON has no Backlog commit" $(echo "$json" | grep -q '"backlog":""'; echo $?)

# 22. A refusal after the rebase also leaves no local commit, on top of the merge it pulled.
ticket_scenario twentytwo
printf 'cd %q && echo merged > work.txt && git add -A && git commit -qm "the merge" && git push -q origin main && echo 1 > %q\n' \
  "$other" "$root/delta.rc" > "$root/delta.race"
run_ticket; rm -f "$root/delta.rc"
check "22 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "22 no local commit, main is the merge" \
  $([ "$(git -C "$main_dir" rev-parse HEAD)" = "$(git --git-dir="$root/twentytwo/origin.git" rev-parse main)" ] \
    && [ "$(git -C "$main_dir" log -1 --format=%s)" = "the merge" ]; echo $?)
check "22 the change is staged" $([ "$(git -C "$main_dir" diff --cached --name-only)" = backlog/tasks/task-9.md ]; echo $?)
check "22 the reason is reported" $(grep -q "refused it after the rebase" "$root/stderr.txt"; echo $?)

# 23. The Backlog commit (main's tip) gets local CI started on it in the background (C13), and the daily audit runs,
# both from the main checkout (this run's worktree is deleted).
ticket_scenario twentythree; : > "$root/run-ci.log"; : > "$root/audit.log"; run_ticket
sha=$(git --git-dir="$root/twentythree/origin.git" rev-parse main)
check "23 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "23 CI started once, on the Backlog commit, from main" $([ "$(cat "$root/run-ci.log")" = "$main_dir $sha --no-wait" ]; echo $?)
check "23 the daily audit ran from main" $([ "$(cat "$root/audit.log")" = "$main_dir daily --no-wait" ]; echo $?)

# 24. Without a ticket, main's tip after the pull is run; a failed start or audit is only a warning.
scenario twentyfour; : > "$root/run-ci.log"; echo 1 > "$root/run-ci.rc"; echo 1 > "$root/audit.rc"; run
rm -f "$root/run-ci.rc" "$root/audit.rc"
check "24 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "24 CI on the main tip" $(grep -qx "$main_dir $(git --git-dir="$root/twentyfour/origin.git" rev-parse main) --no-wait" "$root/run-ci.log"; echo $?)
check "24 warnings, not failures" $(echo "$out" | grep -q "local CI was not started" && echo "$out" | grep -q "daily CI audit did not run"; echo $?)

# 25. --finish starts nothing: it redoes only the cleanup.
scenario twentyfive; run; : > "$root/run-ci.log"; : > "$root/audit.log"; finish
check "25 --finish starts no CI and no audit" $([ ! -s "$root/run-ci.log" ] && [ ! -s "$root/audit.log" ]; echo $?)

# 26. Every sub-step logs its time on stderr, one line each (owner decision 2026-10-23: close-out took 4 to 19 min and
# nothing said where), and stdout stays the JSON line.
scenario twentysix
json=$( (cd "$wt" && PATH="$root/bin:$PATH" STUB_HEAD="$head" ARCHON_LOG="$log" \
  bash "$script" "" https://github.com/o/repo/pull/7 "$main_dir") 2> "$root/stderr.txt" ); rc=$?; out=$(cat "$root/stderr.txt")
for step in backlog pull local-ci reports cleanup; do
  check "26 the $step sub-step logs its time" $(grep -qE "^close-out: $step took [0-9]+s$" "$root/stderr.txt"; echo $?)
done
check "26 stdout is only the JSON line" $([ "$(printf '%s\n' "$json" | wc -l)" -eq 1 ] && grep -q '^{"backlog"' <<< "$json"; echo $?)
check "26 --finish logs only what it runs" $(finish; ! grep -qE '^close-out: (backlog|pull|local-ci) took' <<< "$out" && grep -qE '^close-out: cleanup took' <<< "$out"; echo $?)

echo "close-out tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
