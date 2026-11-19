#!/usr/bin/env bash
# Tests the versioned pre-push hook (TASK-37): .githooks/pre-push runs .claude/scripts/groma-check.sh before a push and
# stops the push when the check fails or the groma CLI is missing; scripts/install-hooks.sh switches it on per clone.
# It builds throwaway git repos with a stub check script, so it tests the hook, not the real map, and does not depend on
# whether the real groma CLI is installed. A repo without groma/ has not set Groma up: the hook and groma-check.sh print
# a notice and pass. `backlog: false` drops groma-check.sh's Backlog.md checks.
# Usage: bash scripts/test/pre-push.test.sh
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0
failed=0

# The tests do not read the machine's git config (a global hooksPath or template would change what they see).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

# last_err is the stderr file of the most recent push or run; a failing check prints the end of it.
last_err=""

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
    if [ -n "$last_err" ] && [ -f "$last_err" ]; then
      echo "       last stderr ($last_err):"
      tail -n 15 "$last_err" | sed 's/^/       | /'
    fi
  fi
}

# Stubs. The check script exits with the code in $STUB_RC_FILE and leaves a marker in $STUB_RAN_FILE when it runs; both
# files live outside the work tree, so the stub never dirties it.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/groma"
chmod +x "$stub_bin/groma"
export STUB_RC_FILE="$tmp/rc"
export STUB_RAN_FILE="$tmp/ran"
export STUB_GROMA_FILE="$tmp/groma-seen"
stub_check='#!/usr/bin/env bash
echo "stub groma-check ran" >&2
echo ran > "$STUB_RAN_FILE"
echo "${GROMA:-unset}" > "$STUB_GROMA_FILE"
exit "$(cat "$STUB_RC_FILE")"
'

# new_repo <name> [nomap]: a work clone with the real hook files and the stub check, plus a bare remote with main pushed.
# It keeps a Groma map (groma/), unless nomap. The hook is not switched on yet.
new_repo() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  git init -q -b main --bare "$dir/remote.git"
  git init -q -b main "$dir/work"
  git -C "$dir/work" config user.name "Test"
  git -C "$dir/work" config user.email "test@example.com"
  git -C "$dir/work" config core.autocrlf false
  mkdir -p "$dir/work/.githooks" "$dir/work/scripts" "$dir/work/.claude/scripts"
  cp "$repo_root/.githooks/pre-push" "$dir/work/.githooks/pre-push"
  cp "$repo_root/scripts/install-hooks.sh" "$dir/work/scripts/install-hooks.sh"
  printf '%s' "$stub_check" > "$dir/work/.claude/scripts/groma-check.sh"
  chmod +x "$dir/work/.githooks/pre-push" "$dir/work/scripts/install-hooks.sh"
  if [ "${2:-}" != nomap ]; then
    mkdir -p "$dir/work/groma"
    echo '{"scanners": [{"id": "java"}]}' > "$dir/work/groma/scanners.json"
  fi
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -q -m "initial"
  git -C "$dir/work" remote add origin "$dir/remote.git"
  git -C "$dir/work" push -q origin main
  echo "$dir"
}

# push_from <work-dir> <branch> <check-exit-code> <groma-cli> <stderr-file>: commits, then pushes; returns git's status.
push_from() {
  local work="$1" branch="$2" rc="$3" cli="$4" err="$5"
  last_err="$err"
  echo "$rc" > "$STUB_RC_FILE"
  rm -f "$STUB_RAN_FILE"
  echo "$RANDOM$RANDOM" > "$work/change.txt"
  git -C "$work" add change.txt
  git -C "$work" commit -q -m "change"
  (cd "$work" && GROMA="$cli" git push origin "HEAD:refs/heads/$branch" 2> "$err")
}

remote_ref() { git -C "$1/remote.git" rev-parse --verify -q "refs/heads/$2" || echo none; }

# --- (a) install-hooks.sh switches the hook on, from any cwd, and is idempotent
r="$(new_repo install)"
mkdir -p "$r/work/sub/deeper"
before="$(git -C "$r/work" config --get core.hooksPath || echo unset)"
check "hooks are off before the install script runs" test "$before" = "unset"
(cd "$r/work/sub/deeper" && bash ../../scripts/install-hooks.sh) > "$tmp/install1.out" 2>&1
check "install-hooks.sh sets core.hooksPath to .githooks from a subdirectory" \
  test "$(git -C "$r/work" config --get core.hooksPath)" = ".githooks"
git -C "$r/work" config --unset core.hooksPath
(cd / && bash "$r/work/scripts/install-hooks.sh") > "$tmp/install2.out" 2>&1
check "install-hooks.sh sets core.hooksPath when run from outside the repo" \
  test "$(git -C "$r/work" config --get core.hooksPath)" = ".githooks"
bash "$r/work/scripts/install-hooks.sh" > "$tmp/install3.out" 2>&1
check "install-hooks.sh twice succeeds and leaves one value" \
  test "$(git -C "$r/work" config --get-all core.hooksPath | tr '\n' ' ')" = ".githooks "
check "install-hooks.sh prints one line" test "$(wc -l < "$tmp/install3.out" | tr -d ' ')" = "1"

# --- (b) a passing check lets the push through
r="$(new_repo pass)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
push_from "$r/work" main 0 "$stub_bin/groma" "$tmp/pass.err"
pass_rc=$?
check "a passing check lets the push succeed" test "$pass_rc" -eq 0
check "the check ran on the passing push" test -f "$STUB_RAN_FILE"
check "the remote moved to the pushed commit" \
  test "$(remote_ref "$r" main)" = "$(git -C "$r/work" rev-parse HEAD)"
check "the hook hands GROMA on to the check script" grep -q "/bin/groma$" "$STUB_GROMA_FILE"

# --- (c) a failing check stops the push and says what to do
r="$(new_repo fail)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
remote_before="$(remote_ref "$r" main)"
push_from "$r/work" main 1 "$stub_bin/groma" "$tmp/fail.err"
fail_rc=$?
check "a failing check rejects the push" test "$fail_rc" -ne 0
check "the remote ref is unchanged after a rejected push" test "$(remote_ref "$r" main)" = "$remote_before"
check "the rejection names groma scan" grep -q 'groma scan' "$tmp/fail.err"
check "the rejection names committing groma/" grep -q 'commit groma/' "$tmp/fail.err"
check "the output of the check itself stays visible" grep -q 'stub groma-check ran' "$tmp/fail.err"
check "the rejection says to read the FAIL lines above" grep -q 'Read the FAIL lines above' "$tmp/fail.err"
check "the rejection names git push --no-verify for an emergency" grep -qF 'git push --no-verify' "$tmp/fail.err"
check "the rejection says CI still checks" grep -q 'CI still' "$tmp/fail.err"

# --- (d) a missing groma CLI stops the push with the install hint, without running the check
r="$(new_repo missing)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
remote_before="$(remote_ref "$r" main)"
push_from "$r/work" main 0 "groma-cli-that-is-not-installed" "$tmp/missing.err"
missing_rc=$?
check "a missing CLI rejects the push" test "$missing_rc" -ne 0
check "the remote ref is unchanged when the CLI is missing" test "$(remote_ref "$r" main)" = "$remote_before"
check "the rejection gives the install hint" grep -qF 'npm install -g groma.md@0.6.6' "$tmp/missing.err"
check "the check script did not run without the CLI" test ! -e "$STUB_RAN_FILE"

# --- (e) the work tree is as it was, pass or fail
r="$(new_repo tree)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
for outcome in 0 1; do
  echo "scratch" > "$r/work/untracked.txt"
  echo "edited $outcome" >> "$r/work/scripts/install-hooks.sh"
  # push_from commits change.txt only; the untracked and edited files stay in the tree
  push_from "$r/work" "tree-$outcome" "$outcome" "$stub_bin/groma" "$tmp/tree.err"
  status_before="$(git -C "$r/work" status --porcelain)"
  # a second push, so the status is taken around a hook run and nothing else
  push_from "$r/work" "tree-$outcome-again" "$outcome" "$stub_bin/groma" "$tmp/tree.err"
  status_after="$(git -C "$r/work" status --porcelain)"
  check "git status is identical before and after a push (check exit $outcome)" \
    test "$status_before" = "$status_after"
  check "the dirty tree was not empty (check exit $outcome)" test -n "$status_after"
  git -C "$r/work" checkout -q -- scripts/install-hooks.sh
done

# --- (f) a linked worktree on another branch behaves the same
r="$(new_repo worktree)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
git -C "$r/work" worktree add -q -b feature "$r/linked" main
push_from "$r/linked" feature 0 "$stub_bin/groma" "$tmp/wt-pass.err"
wt_pass_rc=$?
check "a passing push from a linked worktree succeeds" test "$wt_pass_rc" -eq 0
check "the linked worktree's branch reached the remote" \
  test "$(remote_ref "$r" feature)" = "$(git -C "$r/linked" rev-parse HEAD)"
check "the check ran from the linked worktree" test -f "$STUB_RAN_FILE"
feature_before="$(remote_ref "$r" feature)"
push_from "$r/linked" feature 1 "$stub_bin/groma" "$tmp/wt-fail.err"
wt_fail_rc=$?
check "a failing push from a linked worktree is rejected" test "$wt_fail_rc" -ne 0
check "the remote branch is unchanged after the rejected worktree push" \
  test "$(remote_ref "$r" feature)" = "$feature_before"
check "the worktree rejection names groma scan" grep -q 'groma scan' "$tmp/wt-fail.err"

# --- (g) a push that only deletes remote branches carries no code, so it is not checked; a push that also updates one is
r="$(new_repo delete)"
git -C "$r/work" push -q origin main:refs/heads/old-a main:refs/heads/old-b main:refs/heads/old-c main:refs/heads/old-d
bash "$r/work/scripts/install-hooks.sh" >/dev/null
echo 1 > "$STUB_RC_FILE"
rm -f "$STUB_RAN_FILE"
(cd "$r/work" && GROMA="$stub_bin/groma" git push origin --delete old-a old-b 2> "$tmp/delete.err")
delete_rc=$?
check "a delete-only push succeeds although the check would fail" test "$delete_rc" -eq 0
check "the check did not run on a delete-only push" test ! -e "$STUB_RAN_FILE"
check "the deleted branches are gone from the remote" \
  test "$(remote_ref "$r" old-a) $(remote_ref "$r" old-b)" = "none none"
(cd "$r/work" && GROMA="groma-cli-that-is-not-installed" git push origin --delete old-c 2> "$tmp/delete-nocli.err")
check "a delete-only push needs no groma CLI" test $? -eq 0
main_before="$(remote_ref "$r" main)"
echo "$RANDOM$RANDOM" > "$r/work/change.txt"
git -C "$r/work" add change.txt
git -C "$r/work" commit -q -m "change"
rm -f "$STUB_RAN_FILE"
(cd "$r/work" && GROMA="$stub_bin/groma" git push origin :refs/heads/old-d HEAD:refs/heads/main 2> "$tmp/mixed.err")
mixed_rc=$?
check "a push that deletes one branch and updates another is checked and rejected" test "$mixed_rc" -ne 0
check "the check ran on the mixed push" test -f "$STUB_RAN_FILE"
check "neither ref changed after the rejected mixed push" \
  test "$(remote_ref "$r" main) $(remote_ref "$r" old-d)" = "$main_before $(git -C "$r/work" rev-parse main~1)"

# --- (h) a rejection names uncommitted changes outside groma/, which the check scans along with the commits
check "a rejection from a clean tree does not mention uncommitted changes" \
  bash -c '! grep -q "uncommitted changes" "$1"' _ "$tmp/fail.err"
r="$(new_repo dirty)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
mkdir -p "$r/work/groma"
echo "half-curated" > "$r/work/groma/element.md"
push_from "$r/work" main 1 "$stub_bin/groma" "$tmp/dirty-groma.err"
check "a rejection with only groma/ uncommitted does not mention other uncommitted changes" \
  bash -c '! grep -q "uncommitted changes: commit or stash" "$1"' _ "$tmp/dirty-groma.err"
echo "scratch" > "$r/work/Scratch.java"
push_from "$r/work" main 1 "$stub_bin/groma" "$tmp/dirty-src.err"
check "a rejection with uncommitted source says to commit or stash it first" \
  grep -q 'uncommitted changes: commit or stash them first' "$tmp/dirty-src.err"

# --- (i) the real groma-check.sh in a throwaway repo, with GROMA naming a stub CLI. The stub logs every call; `scan`
# writes into groma/ (a new file and a change to a tracked one) and exits with $STUB_SCAN_RC.
new_map_repo() {
  local dir="$tmp/$1"
  mkdir -p "$dir/.claude/scripts" "$dir/scripts" "$dir/groma"
  cp "$repo_root/.claude/scripts/groma-check.sh" "$dir/.claude/scripts/groma-check.sh"
  echo '{"scanners": [{"id": "java"}]}' > "$dir/groma/scanners.json"
  echo '@AGENTS.md' > "$dir/CLAUDE.md"
  printf 'Run groma agent-instructions. Tickets live in its own Backlog.md backlog.\n' > "$dir/AGENTS.md"
  git init -q -b main "$dir"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config core.autocrlf false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "initial"
  echo "$dir"
}
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "$*" >> "$STUB_GROMA_LOG"' \
  'case "$1" in' \
  '  agent-instructions) echo "Groma agent instructions" ;;' \
  '  scan) echo "scanned" > groma/scanned.md; echo "changed" >> groma/scanners.json; exit "${STUB_SCAN_RC:-0}" ;;' \
  'esac' > "$tmp/map-groma"
chmod +x "$tmp/map-groma"
export STUB_GROMA_LOG="$tmp/groma-calls"

# GROMA is the CLI groma-check.sh runs, for agent-instructions and for scan (not a plain `groma` from the PATH).
r="$(new_map_repo mapuse)"
: > "$STUB_GROMA_LOG"
(cd "$r" && GROMA="$tmp/map-groma" STUB_SCAN_RC=0 bash .claude/scripts/groma-check.sh > "$tmp/mapuse.out" 2> "$tmp/mapuse.err")
last_err="$tmp/mapuse.err"
check "groma-check.sh asks the GROMA cli for the agent instructions" grep -qx 'agent-instructions' "$STUB_GROMA_LOG"
check "groma-check.sh scans with the GROMA cli" grep -qx 'scan' "$STUB_GROMA_LOG"
# A scan that changes groma/ is reported, and groma/ is put back.
check "a scan that changes groma/ fails the check" grep -q 'a fresh groma scan changed groma/' "$tmp/mapuse.err"
check "groma/ is restored after a scan that changed it" test -z "$(git -C "$r" status --porcelain)"

# A scan that fails part way, after writing into groma/: the check fails with a clear message and groma/ is restored.
r="$(new_map_repo mapfail)"
: > "$STUB_GROMA_LOG"
(cd "$r" && GROMA="$tmp/map-groma" STUB_SCAN_RC=3 bash .claude/scripts/groma-check.sh > "$tmp/mapfail.out" 2> "$tmp/mapfail.err")
mapfail_rc=$?
last_err="$tmp/mapfail.err"
check "a failing scan fails the check" test "$mapfail_rc" -eq 1
check "a failing scan is reported as such" grep -q 'FAIL: groma scan failed' "$tmp/mapfail.err"
check "the checks after a failing scan still run" grep -q 'groma-check: [0-9]* failed' "$tmp/mapfail.err"
check "groma/ is restored after a failing scan" test -z "$(git -C "$r" status --porcelain)"

# Every open, non-epic ticket references a map element id; done tickets and epics need none.
r="$(new_map_repo mappins)"
mkdir -p "$r/groma/actors" "$r/backlog/tasks"
printf -- '---\ntype: C4 Actor\ndescription: x\ngroma:\n  id: visitor\n---\n' > "$r/groma/actors/visitor.md"
ticket() { # ticket <file> <status> <label> <ref>
  printf -- "---\nid: %s\nstatus: %s\nlabels:\n  - %s\nreferences:\n  - 'src/A.java:1'\n  - %s\n---\nbody\n" \
    "$1" "$2" "$3" "$4" > "$r/backlog/tasks/$1.md"
}
ticket pinned 'To Do' feature visitor
ticket unpinned 'In Progress' feature visitor-x
ticket done Done feature none
ticket epic 'To Do' epic none
git -C "$r" add -A && git -C "$r" commit -q -m tickets
(cd "$r" && GROMA="$tmp/map-groma" STUB_SCAN_RC=0 bash .claude/scripts/groma-check.sh > "$tmp/mappins.out" 2> "$tmp/mappins.err")
last_err="$tmp/mappins.err"
check "an open ticket that names no map element fails the check" grep -q 'unpinned.md references no map element' "$tmp/mappins.err"
check "a ticket that names a map element passes" bash -c '! grep -q "/pinned.md references" "$1"' _ "$tmp/mappins.err"
check "done tickets and epics need no map element" bash -c '! grep -qE "/(done|epic).md references" "$1"' _ "$tmp/mappins.err"

# --- (j) a repo without groma/ has not set Groma up: the push goes through with a notice, CLI or not
r="$(new_repo nomap nomap)"
bash "$r/work/scripts/install-hooks.sh" >/dev/null
push_from "$r/work" main 1 "groma-cli-that-is-not-installed" "$tmp/nomap.err"
nomap_rc=$?
check "without groma/ the push succeeds, although the check would fail and the CLI is missing" test "$nomap_rc" -eq 0
check "the remote moved to the pushed commit without groma/" \
  test "$(remote_ref "$r" main)" = "$(git -C "$r/work" rev-parse HEAD)"
check "without groma/ the hook says to run groma init" grep -q 'not set up: run groma init' "$tmp/nomap.err"
check "without groma/ the check script does not run" test ! -e "$STUB_RAN_FILE"

# --- (k) groma-check.sh without groma/ (the CI groma job): a notice, exit 0, no groma call
r="$tmp/nomapcheck"
mkdir -p "$r/.claude/scripts"
cp "$repo_root/.claude/scripts/groma-check.sh" "$r/.claude/scripts/groma-check.sh"
git init -q -b main "$r"
: > "$STUB_GROMA_LOG"
(cd "$r" && GROMA="$tmp/map-groma" bash .claude/scripts/groma-check.sh > "$tmp/nomapcheck.out" 2> "$tmp/nomapcheck.err")
nomapcheck_rc=$?
last_err="$tmp/nomapcheck.err"
check "groma-check.sh passes without groma/" test "$nomapcheck_rc" -eq 0
check "groma-check.sh without groma/ says not set up: run groma init" \
  grep -q '^groma-check: not set up: run groma init' "$tmp/nomapcheck.out"
check "groma-check.sh without groma/ calls no groma CLI" test ! -s "$STUB_GROMA_LOG"
(cd "$r" && GITHUB_ACTIONS=true GROMA="$tmp/map-groma" bash .claude/scripts/groma-check.sh > "$tmp/nomapgh.out" 2>&1)
check "in GitHub Actions the notice is a ::notice:: annotation" test "$? $(head -c 10 "$tmp/nomapgh.out")" = "0 ::notice::"
(cd "$r" && GROMA=groma-cli-that-is-not-installed bash .claude/scripts/groma-check.sh > /dev/null 2>&1)
check "groma-check.sh without groma/ needs no groma CLI" test $? -eq 0

# --- (l) backlog: false drops the Backlog.md checks: an unpinned open ticket and an AGENTS.md without the backlog line
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$STUB_GROMA_LOG"' \
  '[ "$1" != agent-instructions ] || echo "Groma agent instructions"' > "$tmp/quiet-groma"
chmod +x "$tmp/quiet-groma"
backlog_repo() { # backlog_repo <name> <kit.yaml backlog line or -> <kit.defaults.yaml backlog line or ->
  local d
  d="$(new_map_repo "$1")"
  printf 'Run groma agent-instructions.\n' > "$d/AGENTS.md"
  mkdir -p "$d/backlog/tasks" "$d/.archon"
  printf -- "---\nid: open\nstatus: To Do\nlabels:\n  - feature\nreferences:\n  - nothing\n---\nbody\n" > "$d/backlog/tasks/open.md"
  [ "$2" = - ] || printf 'profiles: [core]\n%s\n' "$2" > "$d/.archon/kit.yaml"
  [ "$3" = - ] || printf '%s\n' "$3" > "$d/.archon/kit.defaults.yaml"
  git -C "$d" add -A && git -C "$d" commit -q -m backlog
  echo "$d"
}
run_check() { # run_check <repo> <name> [env...]: runs groma-check.sh, prints its exit code
  local d="$1" n="$2"; shift 2
  (cd "$d" && env "$@" GROMA="$tmp/quiet-groma" bash .claude/scripts/groma-check.sh > "$tmp/$n.out" 2> "$tmp/$n.err")
  echo $?
}
r="$(backlog_repo blon - -)"
rc="$(run_check "$r" blon)"; last_err="$tmp/blon.err"
check "with Backlog.md on, an unpinned open ticket fails the check" grep -q 'open.md references no map element' "$tmp/blon.err"
check "with Backlog.md on, AGENTS.md must name the Backlog.md backlog" grep -q 'Backlog.md backlog' "$tmp/blon.err"
check "with Backlog.md on, the check fails" test "$rc" -eq 1
r="$(backlog_repo bloff 'backlog: false' -)"
rc="$(run_check "$r" bloff)"; last_err="$tmp/bloff.err"
check "backlog: false in kit.yaml passes the check" test "$rc" -eq 0
check "backlog: false says the ticket check is skipped" grep -q 'skipped: backlog: false' "$tmp/bloff.out"
r="$(backlog_repo bldef - 'backlog: false')"
rc="$(run_check "$r" bldef)"; last_err="$tmp/bldef.err"
check "backlog: false in kit.defaults.yaml alone passes the check" test "$rc" -eq 0
r="$(backlog_repo blover 'backlog: true' 'backlog: false')"
rc="$(run_check "$r" blover)"; last_err="$tmp/blover.err"
check "backlog: true in kit.yaml wins over the defaults' false" test "$rc" -eq 1
r="$(backlog_repo blenv - -)"
rc="$(run_check "$r" blenv KIT_BACKLOG=0)"; last_err="$tmp/blenv.err"
check "KIT_BACKLOG=0 switches the Backlog.md checks off" test "$rc" -eq 0

echo "pre-push tests: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
