#!/usr/bin/env bash
# Tests for .archon/scripts/commit-tickets.sh against a throwaway origin, the main checkout that commits and a second
# clone that pushes to main.
# Usage: bash .archon/scripts/test/commit-tickets.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/commit-tickets.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"
# The Groma delta check is stubbed: it logs its arguments and exits with the code in $root/delta.rc (0 when absent).
cat > "$root/delta.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$root/delta.log"
exit \$(cat "$root/delta.rc" 2>/dev/null || echo 0)
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

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$root/out" "$err" 2>/dev/null; fi
}
ct() { (cd "$w" && bash "$script" "$@" >"$root/out" 2>"$err"); }
said() { grep -qF -- "$1" "$root/out" "$err"; }
origin() { git -C "$root/origin.git" rev-parse main; }
on_origin() { git -C "$root/origin.git" cat-file -e "main:$1" 2>/dev/null; }
head_is_origin() { [ "$(git -C "$w" rev-parse HEAD)" = "$(origin)" ]; }
dirty() { [ -n "$(git -C "$w" status --porcelain -- "$1")" ]; }
# push <path> <content>: another checkout commits <path> to main and pushes it.
push() {
  mkdir -p "$(dirname "$root/p/$1")"
  (cd "$root/p" && git pull -q --ff-only && printf '%s\n' "$2" > "$1" && git add -A && git commit -qm "$1" && git push -q origin main)
}

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"
t7="backlog/tasks/task-7 - Seven.md"
t241="backlog/tasks/task-24.1 - Twenty four one.md"
t2410="backlog/tasks/task-24.10 - Twenty four ten.md"
(cd "$w" && git config user.name t && git config user.email t@t && mkdir -p backlog/tasks backlog/completed \
  && echo base > README.md && echo seven > "$t7" && echo one > "$t241" && git add -A && git commit -qm base \
  && git push -q origin main)
git clone -q "$root/origin.git" "$root/p" 2>/dev/null
git -C "$root/p" config user.name t; git -C "$root/p" config user.email t@t

# 1. A new ticket is committed on origin/main and pushed; the checkout follows; other local changes stay as they were.
echo ten > "$w/$t2410"
echo "seven, edited" > "$w/$t7"
echo keep > "$w/untouched.txt"
before=$(origin)
ct TASK-24.10; rc=$?
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 the new ticket is on origin/main" $(on_origin "$t2410"; echo $?)
check "1 one commit on top of origin/main" $([ "$(git -C "$root/origin.git" rev-parse main~1)" = "$before" ]; echo $?)
check "1 only that file" $([ "$(git -C "$root/origin.git" diff --name-only main~1 main)" = "$t2410" ]; echo $?)
check "1 the checkout is fast-forwarded" $(head_is_origin; echo $?)
check "1 another ticket's edit stays local" $(dirty "$t7" && [ "$(cat "$w/$t7")" = "seven, edited" ]; echo $?)
check "1 a file outside backlog stays" $([ "$(cat "$w/untouched.txt")" = keep ]; echo $?)
check "1 prints the commit" $(jq -e --arg c "$(origin)" '.commit == $c and .files == 1' "$root/out" >/dev/null; echo $?)
check "1 subject names the ticket" $([ "$(git -C "$root/origin.git" log -1 --format=%s main)" = "chore(backlog): TASK-24.10" ]; echo $?)

# 2. TASK-24.1 takes its own file, never TASK-24.10's; -m gives the body; ids are case-insensitive.
echo "one, edited" > "$w/$t241"
echo "ten, edited" > "$w/$t2410"
ct task-24.1 -m "notes from the delegator"; rc=$?
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 only TASK-24.1's file" $([ "$(git -C "$root/origin.git" diff --name-only main~1 main)" = "$t241" ]; echo $?)
check "2 TASK-24.10's edit stays local" $(dirty "$t2410"; echo $?)
check "2 the body is the message" $([ "$(git -C "$root/origin.git" log -1 --format=%b main | head -1)" = "notes from the delegator" ]; echo $?)

# 3. Several tickets in one commit, and a moved ticket takes both paths.
git -C "$w" mv "$t7" "backlog/completed/task-7 - Seven.md" && git -C "$w" reset -q
ct TASK-7 TASK-24.10; rc=$?
check "3 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "3 the move is committed" $(on_origin "backlog/completed/task-7 - Seven.md" && ! on_origin "$t7"; echo $?)
check "3 both tickets in one commit" $([ "$(git -C "$root/origin.git" diff --name-only main~1 main | wc -l)" -eq 3 ]; echo $?)
check "3 subject names both" $([ "$(git -C "$root/origin.git" log -1 --format=%s main)" = "chore(backlog): TASK-7, TASK-24.10" ]; echo $?)
check "3 the checkout is clean" $([ -z "$(git -C "$w" status --porcelain -- backlog/)" ]; echo $?)

# 4. Origin moved on another file: the commit goes on top of it and the checkout gets both.
push other.txt one
echo "one, again" > "$w/$t241"
ct TASK-24.1; rc=$?
check "4 exit 0 on a moved origin" $([ "$rc" -eq 0 ] && head_is_origin && [ -f "$w/other.txt" ]; echo $?)

# 5. Refusals: nothing committed, nothing pushed.
before=$(origin)
ct TASK-24.1; rc=$?
check "5 a ticket with no change is refused" $([ "$rc" -eq 1 ] && said "TASK-24.1" && [ "$(origin)" = "$before" ]; echo $?)
echo "ten, again" > "$w/$t2410"
push "$t2410" "ten, from a pull request"
ct TASK-24.10; rc=$?
check "5 a ticket origin changed since HEAD is refused" $([ "$rc" -eq 1 ] && said "sync-main" && [ "$(origin)" != "$before" ] \
  && [ "$(git -C "$root/origin.git" show "main:$t2410")" = "ten, from a pull request" ]; echo $?)
check "5 the local edit is kept" $([ "$(cat "$w/$t2410")" = "ten, again" ]; echo $?)
git -C "$w" checkout -q -- "$t2410"; (cd "$w" && git pull -q --ff-only)
git -C "$w" switch -qc side
echo "one, side" > "$w/$t241"
ct TASK-24.1; rc=$?
check "5 not on main is refused" $([ "$rc" -eq 1 ]; echo $?)
git -C "$w" checkout -q -- "$t241"; git -C "$w" switch -q main
(cd "$w" && echo local > local.txt && git add local.txt && git commit -qm local)
echo "one, ahead" > "$w/$t241"
before=$(origin)
ct TASK-24.1; rc=$?
check "5 main with local commits is refused" $([ "$rc" -eq 1 ] && [ "$(origin)" = "$before" ]; echo $?)

# 6. The Groma delta check runs on the pushed commit against the origin/main it goes on; a refusal pushes nothing.
git -C "$w" reset -q --hard origin/main
echo "one, groma" > "$w/$t241"
: > "$root/delta.log"
ct TASK-24.1; rc=$?
check "6 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "6 the delta checked the pushed commit on its base" \
  $([ "$(cat "$root/delta.log")" = "$(origin) $(git -C "$root/origin.git" rev-parse main~1)" ]; echo $?)
echo "one, refused" > "$w/$t241"
echo 1 > "$root/delta.rc"
before=$(origin)
ct TASK-24.1; rc=$?
check "6 a refused Groma check pushes nothing" $([ "$rc" -eq 1 ] && said "Groma check refused" && [ "$(origin)" = "$before" ]; echo $?)
check "6 the edit stays local" $([ "$(cat "$w/$t241")" = "one, refused" ]; echo $?)
echo 3 > "$root/delta.rc"
ct TASK-24.1; rc=$?
check "6 a Groma CLI error pushes nothing" $([ "$rc" -eq 1 ] && [ "$(origin)" = "$before" ]; echo $?)
rm -f "$root/delta.rc"

# 8. Every pushed commit gets local CI started on it in the background (C13), from this checkout; a failed start is a
# warning and the push still counts.
git -C "$w" reset -q --hard origin/main
echo "one, ci" > "$w/$t241"; : > "$root/run-ci.log"
ct TASK-24.1; rc=$?
check "8 local CI started on the pushed commit" \
  $([ "$rc" -eq 0 ] && grep -qx "$w $(origin) --no-wait" "$root/run-ci.log"; echo $?)
echo "one, ci again" > "$w/$t241"; echo 1 > "$root/run-ci.rc"
ct TASK-24.1; rc=$?; rm -f "$root/run-ci.rc"
check "8 a failed start is only a warning" $([ "$rc" -eq 0 ] && said "local CI was not started" && on_origin "$t241"; echo $?)
echo "one, refused again" > "$w/$t241"; echo 1 > "$root/delta.rc"; : > "$root/run-ci.log"
ct TASK-24.1; rc=$?; rm -f "$root/delta.rc"
check "8 a refused commit starts no CI" $([ "$rc" -eq 1 ] && [ ! -s "$root/run-ci.log" ]; echo $?)
git -C "$w" checkout -q -- "$t241"

# 7. Usage.
ct; rc=$?
check "7 no ticket is usage" $([ "$rc" -eq 2 ]; echo $?)
ct notaticket; rc=$?
check "7 a bad id is usage" $([ "$rc" -eq 2 ]; echo $?)

echo "commit-tickets: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
