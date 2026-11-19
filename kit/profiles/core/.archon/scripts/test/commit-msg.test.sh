#!/usr/bin/env bash
# Tests for .archon/githooks/commit-msg (owner decision D12, 2026-10-20) and .archon/githooks/pre-push (D14: the guard
# in the clone's own hooks folder still runs under Archon's core.hooksPath): a throwaway repo with a linked worktree, the
# hook switched on the way .archon/config.yaml does it (GIT_CONFIG_COUNT), never through the repo's own config.
# Usage: bash .archon/scripts/test/commit-msg.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' <<< "${out:-}"; fi
}

# The env Archon sets, read from the config so the test fails when the config drifts.
cfg="$repo_root/.archon/config.yaml"
count=$(yq '.env.GIT_CONFIG_COUNT' "$cfg") key=$(yq '.env.GIT_CONFIG_KEY_0' "$cfg") value=$(yq '.env.GIT_CONFIG_VALUE_0' "$cfg")
out="count=$count key=$key value=$value"
check "config: env switches the hook on through core.hooksPath=.archon/githooks" \
  $([ "$count" = 1 ] && [ "$key" = core.hooksPath ] && [ "$value" = .archon/githooks ]; echo $?)
check "config: background tasks are off for Archon processes" $([ "$(yq '.env.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' "$cfg")" = 1 ]; echo $?)
out=$(grep -n 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' "$repo_root/.claude/settings.json" 2>/dev/null)
check "config: background tasks are not switched off in .claude/settings.json (a background waiter)" $([ -z "$out" ]; echo $?)
out=$(grep -n 'hooksPath' "$repo_root/.git/config" 2>/dev/null)
check "config: the clone has no clone-wide core.hooksPath" $([ -z "$out" ]; echo $?)

# A main checkout with the hook, the subject check and tdd-check committed, and a run worktree on a run branch.
main="$root/main"; wt="$root/wt"
git init -q -b main "$main"; git -C "$main" config user.name t; git -C "$main" config user.email t@t
mkdir -p "$main/.archon/githooks" "$main/.archon/scripts" "$main/.githooks"
cp "$repo_root/.archon/githooks/commit-msg" "$repo_root/.archon/githooks/pre-push" "$main/.archon/githooks/"
cp "$repo_root/.githooks/commit-msg" "$main/.githooks/"
cp "$here/tdd-check.sh" "$main/.archon/scripts/"
echo base > "$main/README.md"; git -C "$main" add -A; git -C "$main" commit -qm "chore: base"
git -C "$main" worktree add -q -b build-feature-1 "$wt"

try() { # try <dir> <on|off> <message> <file>...: commit the files; sets rc and out
  local d="$1" mode="$2" m="$3"; shift 3
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo "$RANDOM" >> "$d/$f"; done
  git -C "$d" add -A
  if [ "$mode" = on ]; then
    out=$(cd "$d" && GIT_CONFIG_COUNT=$count GIT_CONFIG_KEY_0=$key GIT_CONFIG_VALUE_0=$value git commit -q -F - <<< "$m" 2>&1); rc=$?
  else
    out=$(cd "$d" && git commit -q -F - <<< "$m" 2>&1); rc=$?
  fi
  [ "$rc" -eq 0 ] || git -C "$d" reset -q
}

# 1. In a run worktree a feat commit that changes a test source is refused, with both ways out named.
try "$wt" on "feat: Foo" src/main/java/Foo.java src/test/java/FooTest.java
check "1 a feat commit with a test source is refused" $([ "$rc" -ne 0 ]; echo $?)
check "1 the refusal names Test fix: and a test commit" $(grep -q 'Test fix:' <<< "$out" && grep -q 'test(...)' <<< "$out"; echo $?)
check "1 the refusal says only unpushed commits may be rewritten" $(grep -q 'pushed one never' <<< "$out"; echo $?)

# 2. The same with a Test fix: line goes through; so do a test commit and a code commit.
try "$wt" on "$(printf 'feat: Foo\n\nTest fix: the old name')" src/main/java/Foo.java src/test/java/FooTest.java
check "2 Test fix: lets it through" $([ "$rc" -eq 0 ]; echo $?)
try "$wt" on "test(step 1): BarTest" src/test/java/BarTest.java
check "2 a test commit goes through" $([ "$rc" -eq 0 ]; echo $?)
try "$wt" on "feat(step 1): Bar" src/main/java/Bar.java
check "2 a code commit goes through" $([ "$rc" -eq 0 ]; echo $?)
try "$wt" on "backlog: TASK-9 done (repo PR #7 merged, CI green on abc1234)" backlog/tasks/task-9.md
check "2 a script's backlog commit goes through" $([ "$rc" -eq 0 ]; echo $?)

# 3. A subject that is not a Conventional Commit is refused.
try "$wt" on "added stuff" src/main/java/Baz.java
check "3 a bad subject is refused" $([ "$rc" -ne 0 ]; echo $?)

# 4. Only Archon's env switches it on: without it, and in the main checkout, nothing is checked.
try "$wt" off "added stuff" src/main/java/Qux.java
check "4 without the env the hook does not run" $([ "$rc" -eq 0 ]; echo $?)
try "$main" on "added stuff" other.txt
check "4 the main checkout is not checked (run worktrees only)" $([ "$rc" -eq 0 ]; echo $?)

# 5. A missing tdd-check.sh fails open with a warning; the subject check still runs.
rm "$wt/.archon/scripts/tdd-check.sh"
try "$wt" on "feat: Zed" src/main/java/Zed.java src/test/java/ZedTest.java
check "5 a missing tdd-check.sh lets the commit through" $([ "$rc" -eq 0 ]; echo $?)
check "5 and says the shape is not checked" $(grep -q 'not checked' <<< "$out"; echo $?)
try "$wt" on "more stuff" src/main/java/Zed2.java
check "5 the subject check still refuses" $([ "$rc" -ne 0 ]; echo $?)

# 6. pre-push: under Archon's env the clone's own pre-push hook (where push-guard.sh install puts the guard) still runs.
remote="$root/remote.git"; git init -q --bare "$remote"; git -C "$main" remote add origin "$remote"
push() { # push <on|off>: push the worktree's branch; sets rc and out
  if [ "$1" = on ]; then
    out=$(cd "$wt" && GIT_CONFIG_COUNT=$count GIT_CONFIG_KEY_0=$key GIT_CONFIG_VALUE_0=$value git push -q origin HEAD:refs/heads/b$RANDOM 2>&1); rc=$?
  else
    out=$(cd "$wt" && git push -q origin HEAD:refs/heads/b$RANDOM 2>&1); rc=$?
  fi
}
push on
check "6 no clone hook: the push goes through" $([ "$rc" -eq 0 ]; echo $?)
printf '#!/usr/bin/env bash\ncat > "%s/stdin"; echo "$@" > "%s/args"; exit 1\n' "$root" "$root" > "$main/.git/hooks/pre-push"
chmod +x "$main/.git/hooks/pre-push"
push on
check "6 a refusing clone hook stops the push under Archon's env" $([ "$rc" -ne 0 ]; echo $?)
check "6 it gets git's arguments and the ref lines" $(grep -q "origin $remote" "$root/args" && grep -qE '^HEAD [0-9a-f]{40} refs/heads/b[0-9]+ ' "$root/stdin"; echo $?)
push off
check "6 without the env git runs the clone hook itself" $([ "$rc" -ne 0 ]; echo $?)
printf '#!/usr/bin/env bash\nexit 0\n' > "$main/.git/hooks/pre-push"
push on
check "6 an allowing clone hook lets it through" $([ "$rc" -eq 0 ]; echo $?)
chmod -x "$main/.git/hooks/pre-push"
push on
check "6 a clone hook that is not executable: refused (fails closed)" $([ "$rc" -ne 0 ]; echo $?)

echo "commit-msg tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
