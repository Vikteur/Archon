#!/usr/bin/env bash
# Tests for .archon/scripts/park-ticket.sh in a throwaway checkout, with backlog, merge-turn.sh, ready-runs.sh and
# commit-tickets.sh stubbed (each stub logs its call).
# Usage: bash .archon/scripts/test/park-ticket.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/park-ticket.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out="$root/out"
log="$root/calls"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$log" 2>/dev/null; fi
}
w="$root/w"
park() { : > "$log"; (cd "$root/wt" && PATH="$root/bin:$PATH" PARK_SCRIPTS_DIR="$root/scripts" STATE="$root/state.json" \
  TICKET="$w/backlog/tasks/task-6.1 - Six one.md" LOG="$log" bash "$script" "$@" >"$out" 2>&1); }
said() { grep -qF -- "$1" "$out"; }
called() { grep -qF -- "$1" "$log"; }
labels() { jq -r '.labels | join(",")' "$root/state.json"; }

# A checkout with one ticket; the script must work from a second worktree too (it runs backlog in the main one).
git init -q -b main "$w"
(cd "$w" && git config user.name t && git config user.email t@t && mkdir -p backlog/tasks \
  && echo six > "backlog/tasks/task-6.1 - Six one.md" && git add -A && git commit -qm base && git worktree add -q "$root/wt" -b side)
echo '{"id":"TASK-6.1","status":"In Progress","labels":["technical","P0"],"notes":""}' > "$root/state.json"

mkdir -p "$root/bin" "$root/scripts"
cat > "$root/bin/backlog" <<'STUB'
#!/usr/bin/env bash
echo "backlog $* (in $PWD)" >> "$LOG"
[ -n "${BACKLOG_FAILS:-}" ] && [ "$2" = edit ] && exit 1
case "$1 $2" in
  "task view")
    [ "$3" = TASK-6.1 ] || exit 1
    jq -c '{version: 1, task: .}' "$STATE" ;;
  "task edit")
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) jq --arg l "$2" '.labels += [$l]' "$STATE" > "$STATE.t" ;;
        --remove-label) jq --arg l "$2" '.labels -= [$l]' "$STATE" > "$STATE.t" ;;
        --append-notes) jq --arg n "$2" '.notes += $n + "\n"' "$STATE" > "$STATE.t" ;;
        *) echo "unexpected edit flag $1" >> "$LOG"; exit 9 ;;
      esac
      mv "$STATE.t" "$STATE"; shift 2
    done
    jq -r '.labels | join(",")' "$STATE" > "$TICKET" ;;
  *) exit 3 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "merge-turn $*" >> "$LOG"\nexit ${DROP_RC:-0}\n' > "$root/scripts/merge-turn.sh"
printf '#!/usr/bin/env bash\necho "ready-runs $*" >> "$LOG"\n' > "$root/scripts/ready-runs.sh"
printf '#!/usr/bin/env bash\necho "commit-tickets $*" >> "$LOG"\n[ -n "${COMMIT_FAILS:-}" ] && exit 1\ngit -C "$(dirname "$TICKET")" commit -qam park\n' > "$root/scripts/commit-tickets.sh"
chmod +x "$root/bin/backlog"

pr=https://github.com/example-org/example-app/pull/150
run=37e12149abcdef0123456789abcdef01

# 1. Park: label, note with run and PR, drop, clear, commit, in that order; the status is untouched.
park task-6.1 -m "held: owner STOP item" --run "$run" --pr "$pr"; rc=$?
check "1 exit 0" $([ "$rc" -eq 0 ] && said "parked TASK-6.1"; echo $?)
check "1 label added" $([ "$(labels)" = "technical,P0,parked" ]; echo $?)
check "1 note names why, the run and the PR" $(jq -e --arg r "$run" --arg p "$pr" '.notes | test("^Parked [0-9-]+ [0-9:]+ [A-Z][A-Za-z0-9+-]*: held: owner STOP item; run " + $r + "; PR " + $p)' "$root/state.json" >/dev/null; echo $?)
check "1 status unchanged" $(jq -e '.status == "In Progress"' "$root/state.json" >/dev/null; echo $?)
check "1 backlog runs in the main checkout" $(called "(in $w)"; echo $?)
check "1 the steps run in order" $([ "$(grep -v '^backlog task view' "$log" | cut -d' ' -f1-3 | tr '\n' '|')" = "backlog task edit|merge-turn drop $pr|ready-runs clear $run|commit-tickets TASK-6.1 -m|" ]; echo $?)
check "1 commit message" $(called "commit-tickets TASK-6.1 -m park TASK-6.1: held: owner STOP item"; echo $?)
check "1 never a status, demote or archon call" $(! grep -qE -- '--status|-s |demote|archon' "$log"; echo $?)

# 2. A rerun is idempotent: no second label or note, no commit (nothing changed); drop and clear repeat.
notes=$(jq -r .notes "$root/state.json")
DROP_RC=1 park TASK-6.1 -m "again" --run "$run" --pr "$pr"; rc=$?
check "2 exit 0" $([ "$rc" -eq 0 ] && said "already parked" && said "was not in the merge queue"; echo $?)
check "2 no second label or note" $([ "$(labels)" = "technical,P0,parked" ] && [ "$(jq -r .notes "$root/state.json")" = "$notes" ]; echo $?)
check "2 no edit, no commit" $(! called "task edit" && ! called "commit-tickets"; echo $?)
check "2 drop and clear repeated" $(called "merge-turn drop" && called "ready-runs clear"; echo $?)

# 3. Unpark: the label goes, a note is added, it commits.
park --unpark TASK-6.1 -m "owner approved"; rc=$?
check "3 exit 0" $([ "$rc" -eq 0 ] && said "unparked TASK-6.1"; echo $?)
check "3 label removed" $([ "$(labels)" = "technical,P0" ]; echo $?)
check "3 note added" $(jq -e '.notes | test("Unparked .*: owner approved")' "$root/state.json" >/dev/null; echo $?)
check "3 committed" $(called "commit-tickets TASK-6.1 -m unpark TASK-6.1: owner approved"; echo $?)

# 4. The commit fails: exit 3, the label stays; a rerun commits the pending change.
COMMIT_FAILS=1 park TASK-6.1 -m "held again"; rc=$?
check "4 commit failed: exit 3" $([ "$rc" -eq 3 ] && said "commit to main failed" && [ "$(labels)" = "technical,P0,parked" ]; echo $?)
park TASK-6.1 -m "held again"; rc=$?
check "4 a rerun commits the pending change" $([ "$rc" -eq 0 ] && called "commit-tickets" && ! called "task edit"; echo $?)

# 5. --no-commit; a failing backlog edit; a drop that errors.
park --unpark TASK-6.1 -m x --no-commit; rc=$?
check "5 --no-commit commits nothing" $([ "$rc" -eq 0 ] && ! called "commit-tickets"; echo $?)
BACKLOG_FAILS=1 park TASK-6.1 -m x; rc=$?
check "5 a failing edit exits 1 and says which" $([ "$rc" -eq 1 ] && said "add the label"; echo $?)
DROP_RC=4 park TASK-6.1 -m x --pr "$pr" --no-commit; rc=$?
check "5 a failing drop exits 1" $([ "$rc" -eq 1 ] && said "merge-turn.sh drop"; echo $?)
park TASK-9.9 -m x; rc=$?
check "5 an unknown ticket exits 1" $([ "$rc" -eq 1 ] && said "cannot read TASK-9.9"; echo $?)

# 5b. The reason as a plain argument after the id (the form delegator.md uses).
park --unpark TASK-6.1 "positional reason" --no-commit; rc=$?
check "5b a plain-argument reason works" $([ "$rc" -eq 0 ] && jq -e '.notes | test("Unparked .*: positional reason")' "$root/state.json" >/dev/null; echo $?)

# 6. Usage.
for args in "" "TASK-6.1" "-m why" "notaticket -m x" "TASK-6.1 -m x --run zz" "TASK-6.1 -m x --pr nope" "--unpark TASK-6.1 -m x --pr $pr" "TASK-6.1 TASK-7 -m x" "TASK-6.1 why -m x" "TASK-6.1 a b"; do
  # shellcheck disable=SC2086
  park $args; rc=$?
  check "6 usage: '$args'" $([ "$rc" -eq 2 ]; echo $?)
done

echo "park-ticket: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
