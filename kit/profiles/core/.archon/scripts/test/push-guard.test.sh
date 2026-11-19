#!/usr/bin/env bash
# Tests for .archon/scripts/push-guard.sh (owner decision 2026-10-20, D14 and its exemption): a push to main is refused
# unless every commit it adds stays inside one exempt script's paths (backlog/, docs/retro/, docs/tokenomics/,
# .archon/stop/approvals/), or a
# root-owned, unexpired, unused allow entry names the pushed commit. Throwaway git repos with a bare remote; the guard under test is
# a copy whose allow folder is a temp folder and whose owner uid is this user's (the real one is /etc and root, which a
# test cannot write: the same reason an agent cannot).
# Usage: bash .archon/scripts/test/push-guard.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/push-guard.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$root/home"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"

# guard_copy <file> <owner uid>: the guard with its allow folder at $root/allow and the given owner uid.
guard_copy() {
  sed -e "s#^ALLOW_DIR=.*#ALLOW_DIR=$root/allow#" -e "s#^OWNER_UID=.*#OWNER_UID=$2#" "$script" > "$1"
}
allow() { # allow <sha> [<expires epoch>]: an allow entry as `allow` writes it
  mkdir -p "$root/allow"; printf 'sha: %s\nexpires: %s\n' "$1" "${2:-$(( $(date +%s) + 600 ))}" > "$root/allow/$1"
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$root/err" 2>/dev/null; fi
}

# A clone of a bare remote, with the guard copy at its .archon/scripts/ and the hook installed by `install`.
git init -q --bare -b main "$root/remote.git"
git clone -q "$root/remote.git" "$root/clone" 2>/dev/null
cd "$root/clone" || exit 1
git checkout -q -b main
mkdir -p .archon/scripts; guard_copy .archon/scripts/push-guard.sh "$(id -u)"
echo a > a; git add a; git commit -qm a
bash .archon/scripts/push-guard.sh install 2> "$root/err"
check "install writes an executable pre-push hook" $([ -x .git/hooks/pre-push ] && grep -q "push-guard.sh" .git/hooks/pre-push; echo $?)
check "install sets no core.hooksPath" $([ -z "$(git config --get core.hooksPath)" ]; echo $?)

# 1. A branch other than main is pushed as usual.
git push -q origin main:refs/heads/feat/x 2> "$root/err"
check "1 a feature branch push passes" $([ $? -eq 0 ]; echo $?)

# 2. A push to main without an allow entry is refused, and says how the owner allows one.
git push -q origin main 2> "$root/err"; rc=$?
check "2 a push to main is refused" $([ "$rc" -ne 0 ] && [ -z "$(git ls-remote origin refs/heads/main)" ]; echo $?)
check "2 the refusal names D14 and the allow command" $(grep -q "D14" "$root/err" && grep -q "sudo bash .archon/scripts/push-guard.sh allow" "$root/err"; echo $?)

# 3. With an allow entry for exactly that commit the push passes, once.
head=$(git rev-parse HEAD); allow "$head"
git push -q origin main 2> "$root/err"
check "3 an allowed push passes" $([ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$head" ]; echo $?)
check "3 the entry is recorded as used" $(grep -qxF "$head" "$HOME/.local/state/push-guard/used"; echo $?)
echo "refs/heads/main $head refs/heads/main 0000" | bash .archon/scripts/push-guard.sh check origin x 2> "$root/err"
check "3 a used entry does not count again" $([ $? -eq 1 ]; echo $?)

# 4. An entry for another commit, an expired entry, a deleted main: refused.
echo b > b; git add b; git commit -qm b; allow "$head"
git push -q origin main 2> "$root/err"
check "4 an entry for another commit does not count" $([ $? -ne 0 ]; echo $?)
new=$(git rev-parse HEAD); allow "$new" $(( $(date +%s) - 1 ))
git push -q origin main 2> "$root/err"
check "4 an expired entry does not count" $([ $? -ne 0 ]; echo $?)
allow "$new"
printf 'refs/heads/main %s refs/heads/main x\n(delete) 0000000000000000000000000000000000000000 refs/heads/main x\n' "$new" \
  | bash .archon/scripts/push-guard.sh check origin x 2> "$root/err"
check "4 a delete of main is refused even with an allow entry" $([ $? -eq 1 ] && grep -q "delete of main" "$root/err"; echo $?)

# 5. An entry not owned by the owner uid (one an agent wrote) does not count.
guard_copy "$root/root-guard.sh" 0; allow "$new"
echo "refs/heads/main $new refs/heads/main x" | bash "$root/root-guard.sh" check origin x 2> "$root/err"
check "5 an entry this user wrote does not count for a root-owned guard" $([ $? -eq 1 ]; echo $?)

# 6. allow: only root, only a full sha, 1 to 240 minutes; usage errors exit 2.
bash "$script" allow "$new" 2> "$root/err"; rc=$?
check "6 allow as a normal user exits 1" $([ "$rc" -eq 1 ] && grep -q "root only" "$root/err"; echo $?)
bash "$script" allow HEAD 2> "$root/err"; check "6 allow needs a full sha" $([ $? -eq 2 ]; echo $?)
bash "$script" allow "$new" 999 2> "$root/err"; check "6 at most 240 minutes" $([ $? -eq 2 ]; echo $?)
bash "$script" bogus 2> "$root/err"; check "6 an unknown command exits 2" $([ $? -eq 2 ]; echo $?)

# 7. The real guard has no way around it in the environment: the root-owned /etc folder and uid 0 are fixed.
check "7 fixed allow folder and owner" $(grep -qx 'ALLOW_DIR=/etc/push-guard/allow' "$script" && grep -qx 'OWNER_UID=0' "$script" \
  && ! grep -qE 'ALLOW_DIR=\$\{|OWNER_UID=\$\{' "$script"; echo $?)

# 9. Exempt pushes: every commit stays inside ONE exempt script's paths; no allow entry is needed or used.
fresh() { git fetch -q origin; git reset -q --hard origin/main; }   # back to the remote's main
commit() { # commit <subject> <path>...: one commit writing each path
  local f; for f in "${@:2}"; do mkdir -p "$(dirname "$f")"; echo "$RANDOM" >> "$f"; git add -- "$f"; done
  git commit -qm "$1"
}
pushed() { [ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$(git rev-parse HEAD)" ]; }
fresh; commit "backlog: TASK-1 done" "backlog/tasks/task-1 - x.md"
git push -q origin main 2> "$root/err"
check "9 a backlog/-only commit (commit-tickets, close-out) is exempt" $(pushed && grep -q "exempt" "$root/err"; echo $?)
commit "retro: TASK-1" docs/retro/TASK-1/lessons-learned.md docs/retro/README.md
commit "chore(tokenomics): reports" docs/tokenomics/ledger/day.json
git push -q origin main 2> "$root/err"
check "9 a retro commit then a token report commit: each fits one entry" $(pushed; echo $?)
commit "stop: owner approvals 2026-11-19-1200.json (in chat)" .archon/stop/approvals/2026-11-19-1200.json
git push -q origin main 2> "$root/err"
check "9 an approvals-only commit (stop-approve.sh record) is exempt" $(pushed; echo $?)
fresh; commit "stop: approvals and a policy edit" .archon/stop/approvals/x.json .archon/stop/policy.json
git push -q origin main 2> "$root/err"
check "9 an approvals commit that also edits the policy is refused" $(! pushed && grep -q "policy.json" "$root/err"; echo $?)

# 10. Escapes: an arbitrary push dressed up as an exempt one is refused, whatever its subject says.
fresh; commit "chore(backlog): TASK-2" backlog/tasks/t2.md src/App.java
git push -q origin main 2> "$root/err"
check "10 a backlog/ commit that also changes src/ is refused, naming the path" $(! pushed && grep -q "src/App.java" "$root/err"; echo $?)
fresh; commit "backlog: mixed" backlog/tasks/t3.md docs/retro/x.md
git push -q origin main 2> "$root/err"
check "10 one commit across two exempt entries is refused" $(! pushed; echo $?)
fresh; commit "backlog: ok" backlog/tasks/t4.md; commit "backlog: sneaky" .archon/scripts/x.sh
git push -q origin main 2> "$root/err"
check "10 an exempt commit followed by another one is refused" $(! pushed; echo $?)
fresh; commit "backlog: look-alike" backlogx/a.md
git push -q origin main 2> "$root/err"
check "10 a look-alike folder (backlogx/) is refused" $(! pushed; echo $?)
fresh; commit "retro: look-alike" docs/retro-evil/a.md
git push -q origin main 2> "$root/err"
check "10 a look-alike folder (docs/retro-evil/) is refused" $(! pushed; echo $?)
fresh; mkdir -p backlog; git mv a backlog/a; git commit -qm "backlog: move"
git push -q origin main 2> "$root/err"
check "10 a rename from outside into backlog/ is refused" $(! pushed; echo $?)
fresh; git reset -q --hard HEAD~1; commit "backlog: rewrite" backlog/tasks/t5.md
git push -q -f origin main 2> "$root/err"
check "10 a forced push of a backlog/-only commit is refused" $(! pushed && grep -q "fast-forward" "$root/err"; echo $?)
fresh; base=$(git rev-parse HEAD); git checkout -q -b side; commit "backlog: side" backlog/tasks/t6.md
git checkout -q main; commit "backlog: main" backlog/tasks/t7.md; git merge -q --no-edit side
git push -q origin main 2> "$root/err"
check "10 a merge commit is refused even when it changes only backlog/" $(! pushed && grep -q "merge commit" "$root/err"; echo $?)
# ... and the owner's allow still lets any one push through.
allow "$(git rev-parse HEAD)"
git push -q origin main 2> "$root/err"
check "10 an owner allow lets a non-exempt push through" $(pushed; echo $?)
check "10 the exempt list in the guard is fixed (no override)" $(grep -q '"commit-tickets.sh, close-out.sh|backlog/"' "$script" \
  && ! grep -qE 'EXEMPT=\$|EXEMPT\+=' "$script"; echo $?)

# 11. paths prints the exempt prefixes, the one list merge-turn.sh reads.
check "11 paths prints the exempt prefixes" $([ "$(bash "$script" paths | tr '\n' ' ')" = "backlog/ docs/retro/ docs/tokenomics/ .archon/stop/approvals/ " ]; echo $?)

# 8. The installed hook refuses every push when the guard is missing from the main checkout.
mv .archon/scripts/push-guard.sh "$root/away.sh"
git push -q origin main:refs/heads/feat/y 2> "$root/err"
check "8 a missing guard refuses the push" $([ $? -ne 0 ] && grep -q "missing" "$root/err"; echo $?)

echo "push-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
