#!/usr/bin/env bash
# Tests for .archon/scripts/sync-main.sh against a throwaway origin, the main checkout that is synced and a second
# clone that pushes to main.
# Usage: bash .archon/scripts/test/sync-main.test.sh   (exit 0 = all pass)
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/sync-main.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"
# local-ci-run.sh is stubbed (CI plan C13): it logs "<cwd> <args>" and exits with the code in $root/run-ci.rc (0 when
# absent). Never the real one: that would start local CI on a throwaway commit.
cat > "$root/run-ci.sh" <<STUB
#!/usr/bin/env bash
echo "\$PWD \$*" >> "$root/run-ci.log"
exit \$(cat "$root/run-ci.rc" 2>/dev/null || echo 0)
STUB
export LOCAL_CI_RUN="$root/run-ci.sh"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$root/out" "$err" 2>/dev/null; fi
}
sync() { (cd "$w" && bash "$script" "$@" >"$root/out" 2>"$err"); }
said() { grep -qF -- "$1" "$root/out" "$err"; }
head_is_origin() { [ "$(git -C "$w" rev-parse HEAD)" = "$(git -C "$root/origin.git" rev-parse main)" ]; }
backups() { find "$w/.git/sync-main-backup" -type f 2>/dev/null | wc -l; }
# push <path> <content>: another checkout commits <path> to main and pushes it.
push() {
  mkdir -p "$(dirname "$root/p/$1")"
  (cd "$root/p" && git pull -q --ff-only && printf '%s\n' "$2" > "$1" && git add -A && git commit -qm "$1" && git push -q origin main)
}

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"
(cd "$w" && git config user.name t && git config user.email t@t && mkdir -p backlog/tasks && echo base > README.md \
  && echo old > backlog/tasks/edited.md && git add -A && git commit -qm base && git push -q origin main)
git clone -q "$root/origin.git" "$root/p" 2>/dev/null
git -C "$root/p" config user.name t; git -C "$root/p" config user.email t@t

t56="backlog/tasks/task-56 - A ticket with spaces.md"

# 1. Nothing to do: up to date, exit 0, nothing backed up.
sync; rc=$?
check "1 up to date exit 0" $([ "$rc" -eq 0 ] && said "up to date"; echo $?)

# 2. Behind, clean: fast-forwarded.
push other.txt one
sync; rc=$?
check "2 clean fast-forward" $([ "$rc" -eq 0 ] && head_is_origin && [ "$(backups)" -eq 0 ]; echo $?)

# 3. Untracked ticket, byte-identical to the pushed one (the 2026-10-18 failure): moved aside, fast-forwarded.
push "$t56" "same ticket"
printf '%s\n' "same ticket" > "$w/$t56"
echo keep > "$w/untouched.txt"
sync; rc=$?
check "3 identical untracked exit 0" $([ "$rc" -eq 0 ] && head_is_origin; echo $?)
check "3 file is origin's" $([ "$(cat "$w/$t56")" = "same ticket" ] && [ -z "$(git -C "$w" status --porcelain -- "$t56")" ]; echo $?)
check "3 backed up, not deleted" $([ "$(backups)" -eq 1 ] && said "same as origin/main: $t56"; echo $?)
check "3 an unrelated untracked file stays" $([ -f "$w/untouched.txt" ]; echo $?)

# 4. Ticket edited locally (delegator notes) and on origin (the run's notes): backed up, fast-forwarded, named.
push backlog/tasks/edited.md "run notes"
echo "delegator notes" > "$w/backlog/tasks/edited.md"
sync; rc=$?
check "4 differing backlog exit 0" $([ "$rc" -eq 0 ] && head_is_origin; echo $?)
check "4 file is origin's" $([ "$(cat "$w/backlog/tasks/edited.md")" = "run notes" ]; echo $?)
check "4 named for re-applying" $(said "differs from origin/main, re-apply: backlog/tasks/edited.md" && \
  grep -rqF "delegator notes" "$w/.git/sync-main-backup"; echo $?)

# 5. A differing file outside backlog/: refused, nothing changed.
push src.txt "theirs"
echo mine > "$w/src.txt"
before=$(git -C "$w" rev-parse HEAD); n=$(backups)
sync; rc=$?
check "5 differing other refused" $([ "$rc" -eq 1 ] && said "src.txt"; echo $?)
check "5 nothing changed" $([ "$(git -C "$w" rev-parse HEAD)" = "$before" ] && [ "$(cat "$w/src.txt")" = mine ] \
  && [ "$(backups)" -eq "$n" ]; echo $?)
rm "$w/src.txt"; sync

# 6. A staged, byte-identical change to a tracked file: restored, fast-forwarded.
push README.md "new readme"
echo "new readme" > "$w/README.md"; git -C "$w" add README.md
sync; rc=$?
check "6 identical staged exit 0" $([ "$rc" -eq 0 ] && head_is_origin && [ -z "$(git -C "$w" status --porcelain -- README.md)" ]; echo $?)

# 7. Local commit on main: refused, nothing changed.
(cd "$w" && echo x > local.txt && git add local.txt && git commit -qm local)
push other.txt two
before=$(git -C "$w" rev-parse HEAD)
sync; rc=$?
check "7 local commit refused" $([ "$rc" -eq 1 ] && said "commits not in origin/main" && \
  [ "$(git -C "$w" rev-parse HEAD)" = "$before" ]; echo $?)
git -C "$w" reset -q --hard origin/main

# 8. Not on main: refused.
git -C "$w" switch -q -c feat/x
sync; rc=$?
check "8 off main refused" $([ "$rc" -eq 1 ] && said "not on main"; echo $?)
git -C "$w" switch -q main

# 9. --dry-run: says what it would do, changes nothing.
push "backlog/tasks/new.md" "fresh"
echo fresh > "$w/backlog/tasks/new.md"
before=$(git -C "$w" rev-parse HEAD); n=$(backups)
sync --dry-run; rc=$?
check "9 dry run changes nothing" $([ "$rc" -eq 0 ] && said "would" && [ "$(git -C "$w" rev-parse HEAD)" = "$before" ] \
  && [ "$(backups)" -eq "$n" ] && [ -f "$w/backlog/tasks/new.md" ]; echo $?)

# 11. The main tip gets local CI started on it in the background (C13): after a fast-forward and when up to date, never
# on a dry run or a refusal; a failed start is only a warning.
push other.txt three; : > "$root/run-ci.log"
sync; rc=$?
check "11 fast-forward starts CI on the tip" $([ "$rc" -eq 0 ] && [ "$(cat "$root/run-ci.log")" = "$w $(git -C "$root/origin.git" rev-parse main) --no-wait" ]; echo $?)
: > "$root/run-ci.log"; sync; rc=$?
check "11 up to date starts CI on the tip" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$root/run-ci.log")" -eq 1 ]; echo $?)
push other.txt four; : > "$root/run-ci.log"
sync --dry-run; rc=$?
check "11 a dry run starts nothing" $([ "$rc" -eq 0 ] && [ ! -s "$root/run-ci.log" ]; echo $?)
git -C "$w" switch -q -c feat/y; sync; git -C "$w" switch -q main
check "11 a refusal starts nothing" $([ ! -s "$root/run-ci.log" ]; echo $?)
echo 1 > "$root/run-ci.rc"; sync; rc=$?; rm -f "$root/run-ci.rc"
check "11 a failed start is only a warning" $([ "$rc" -eq 0 ] && head_is_origin && said "local CI was not started"; echo $?)

# 10. Usage.
sync --bogus; rc=$?
check "10 usage exit 2" $([ "$rc" -eq 2 ]; echo $?)

echo "sync-main: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
