#!/usr/bin/env bash
# Tests for .archon/scripts/ticket.sh: the ticket from the request text (backlog: false, or no TASK id) and from the
# Backlog (backlog: true and a TASK id), each writing ticket.md and the JSON line. A fake `backlog` on PATH records
# its calls. Usage: bash .archon/scripts/test/ticket.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$root/.archon/scripts/ticket.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
field() { node -e 'try { const v = JSON.parse(process.argv[1])[process.argv[2]]; console.log(v === undefined ? "<none>" : v); } catch { console.log("<not json>"); }' "$1" "$2"; }

mkdir -p "$tmp/bin" "$tmp/board/backlog"
touch "$tmp/board/backlog/config.yml"
cat > "$tmp/bin/backlog" <<'B'
#!/usr/bin/env bash
echo "$*" >> "$BACKLOG_LOG"
case "$*" in
  "task view TASK-4 --json") echo '{"task":{"id":"TASK-4","title":"Add a greeting","status":"To Do","labels":["stop-db-migration","api"],"dependencies":["TASK-1"]}}' ;;
  "task view TASK-4 --plain") printf 'Task TASK-4 - Add a greeting\n====\n\nLabels: stop-db-migration, api\nDependency Graph:\n  huge\nDescription:\n----\nServe GET /hello.\n' ;;
  "task edit TASK-4 --status In Progress") ;;
  *) exit 1 ;;
esac
B
chmod +x "$tmp/bin/backlog"
export PATH="$tmp/bin:$PATH" BACKLOG_LOG="$tmp/backlog.log"
unset KIT_BACKLOG KIT_CONFIG BACKLOG_CWD

run() { # run <artifacts dir> <request>: stdout of ticket.sh, its exit code in $rc
  mkdir -p "$1"; : > "$BACKLOG_LOG"
  out=$(cd "$tmp" && ARTIFACTS_DIR="$1" bash "$script" "$2" 2> "$1/err"); rc=$?
}

# 1. backlog: false in kit.yaml: the pasted text is the ticket, even when it names a TASK id; Backlog is never asked.
printf 'backlog: false   # Jira\n' > "$tmp/kit-off.yaml"
req=$'PROJ-12 Add a greeting endpoint\n\nServe GET /hello, see TASK-4 in the old board.\nLabels: stop-db-migration, api stop-auth\n\nAcceptance: returns 200.'
KIT_CONFIG="$tmp/kit-off.yaml" run "$tmp/a1" "$req"
check "off: exits 0 (rc=$rc: $(cat "$tmp/a1/err"))" "$rc"
[ "$(field "$out" task)" = "" ]; check "off: no task id although the text names TASK-4 ($out)" $?
[ "$(field "$out" stop)" = "stop-db-migration,stop-auth" ]; check "off: STOP labels from the Labels: line ($out)" $?
[ "$(field "$out" title)" = "PROJ-12 Add a greeting endpoint" ]; check "off: title is the first line ($out)" $?
[ "$(field "$out" pr_note)" = "" ]; check "off: no pr_note, so no Backlog ticket line in the pull request" $?
[ ! -s "$BACKLOG_LOG" ]; check "off: backlog is never called ($(cat "$BACKLOG_LOG"))" $?
grep -qx 'Ticket - PROJ-12 Add a greeting endpoint' "$tmp/a1/ticket.md"; check "off: ticket.md has the title line" $?
grep -qx 'Labels: stop-db-migration, api, stop-auth' "$tmp/a1/ticket.md"; check "off: ticket.md has the labels" $?
grep -qx 'Description:' "$tmp/a1/ticket.md"; check "off: ticket.md has a Description section" $?
[ "$(sed -n '/^Description:/,$p' "$tmp/a1/ticket.md" | sed '1,2d')" = "$req" ]; check "off: the text is written unchanged" $?
! grep -q '^Task TASK-' "$tmp/a1/ticket.md"; check "off: no Backlog title line (scaffold-check writes no follow-up id)" $?

# 2. The same through the environment, a Markdown title and bold labels; a label that is not a plain word is no STOP.
req=$'# Title: Rename the **order** table\n**Labels:** stop-db-migration, `stop-x;rm`, stop-$(id)\nbody'
KIT_BACKLOG=false run "$tmp/a2" "$req"
check "env off: exits 0 (rc=$rc)" "$rc"
[ "$(field "$out" title)" = 'Rename the **order** table' ]; check "env off: # and Title: dropped from the title ($out)" $?
[ "$(field "$out" stop)" = "stop-db-migration" ]; check "env off: only plain stop- labels count ($out)" $?
[ ! -s "$BACKLOG_LOG" ]; check "env off: backlog is never called" $?

# 3. backlog on (no kit.yaml: the default) and a request without a TASK id: the request is the ticket as well.
run "$tmp/a3" $'Make the greeting configurable\nno labels here'
check "on, no id: exits 0 (rc=$rc)" "$rc"
[ "$(field "$out" task)" = "" ] && [ "$(field "$out" stop)" = "" ]; check "on, no id: no task, no STOP ($out)" $?
grep -qx 'Ticket - Make the greeting configurable' "$tmp/a3/ticket.md"; check "on, no id: ticket.md written" $?
! grep -q '^Labels:' "$tmp/a3/ticket.md"; check "on, no id: no Labels line without labels" $?
[ ! -s "$BACKLOG_LOG" ]; check "on, no id: backlog is never called" $?

# 4. An empty request still writes a ticket.md.
KIT_BACKLOG=false run "$tmp/a4" ""
check "empty: exits 0 (rc=$rc)" "$rc"
[ "$(field "$out" title)" = "" ]; check "empty: empty title ($out)" $?
grep -qx 'Ticket - (no title)' "$tmp/a4/ticket.md"; check "empty: ticket.md says so" $?

# 5. backlog on and a TASK id: the Backlog ticket, as before, with its title and a pr_note naming it.
BACKLOG_CWD="$tmp/board" run "$tmp/a5" "build task-4 please"
check "on, TASK: exits 0 (rc=$rc: $(cat "$tmp/a5/err"))" "$rc"
[ "$(field "$out" task)" = "TASK-4" ] && [ "$(field "$out" stop)" = "stop-db-migration" ]; check "on, TASK: id and STOP labels ($out)" $?
[ "$(field "$out" title)" = "Add a greeting" ]; check "on, TASK: title from the Backlog ($out)" $?
[ "$(field "$out" pr_note)" = "Name its Backlog ticket, TASK-4 (Add a greeting)." ]; check "on, TASK: pr_note names the ticket ($out)" $?
grep -qx 'Task TASK-4 - Add a greeting' "$tmp/a5/ticket.md" && grep -qx 'Depends on: TASK-1' "$tmp/a5/ticket.md" \
  && ! grep -q huge "$tmp/a5/ticket.md"; check "on, TASK: ticket.md from the plain view, the graph dropped" $?
grep -qx 'task edit TASK-4 --status In Progress' "$BACKLOG_LOG"; check "on, TASK: a To Do ticket is set In Progress" $?

# 6. backlog: true written in kit.yaml behaves as the default.
printf 'backlog: true\n' > "$tmp/kit-on.yaml"
KIT_CONFIG="$tmp/kit-on.yaml" BACKLOG_CWD="$tmp/board" run "$tmp/a6" "TASK-4"
[ "$rc" -eq 0 ] && [ "$(field "$out" task)" = "TASK-4" ]; check "kit.yaml on: the Backlog ticket ($out)" $?

# 7. backlog on, a TASK id and no backlog/ anywhere: the node fails and says how to go without Backlog.
mkdir -p "$tmp/lone/repo"; git -C "$tmp/lone/repo" init -q
out=$(cd "$tmp/lone/repo" && ARTIFACTS_DIR="$tmp/lone" bash "$script" "TASK-4" 2> "$tmp/lone/err"); rc=$?
[ "$rc" -ne 0 ]; check "on, TASK, no board: fails (rc=$rc)" $?
grep -q 'backlog: false' "$tmp/lone/err"; check "on, TASK, no board: names backlog: false ($(cat "$tmp/lone/err"))" $?

echo "ticket: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
