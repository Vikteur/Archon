#!/usr/bin/env bash
# Tests for .archon/scripts/stop-scan.js: the list round's scan of whole tickets and their linked specs
# (owner decision 2026-10-20, STOP rule changes; docs/archon/stop-policy.md).
# Usage: bash .archon/scripts/test/stop-scan.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
script="$here/stop-scan.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"; out="$root/out"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$err" 2>/dev/null; fi
}

r="$root/repo"; t="$root/tickets"
mkdir -p "$r/.archon/stop" "$r/docs/rewrite/tickets/p1" "$t" "$root/bin"
cp "$repo_root/.archon/stop/policy.json" "$r/.archon/stop/"
cat > "$r/docs/rewrite/tickets/p1/P1-E02-T03.md" <<'EOF'
# Sessions

The session cookie is set in the %prod profile.
Every failed sign-in is logged with the account id.

## Definition of Done
- a database migration is reviewed (generic text, skipped)
EOF
printf 'line one\nThe planner role enters the access matrix.\nline three\n' > "$r/docs/roles.md"
jq -n '{id: "TASK-7", title: "Sessions", status: "To Do", labels: ["stop-production-config", "stop-weird"],
  description: "Plan item `P1-E02-T03`.\nAdd a Flyway migration for the session table.",
  acceptanceCriteria: [{index: 1, text: "The contract change is pushed to the hub first"}],
  references: ["docs/roles.md:2-2"]}' > "$t/TASK-7.json"
jq -n '{id: "TASK-8", title: "Copy fix", status: "To Do", labels: [], description: "Fix a typo on the RSVP page."}' > "$t/TASK-8.json"
jq -n '{task: {id: "TASK-9", title: "Wrapped", status: "To Do", labels: ["stop-auth-access"], description: "Nothing here."}}' > "$t/TASK-9.json"

scan() { STOP_SCAN_ROOT="$r" STOP_SCAN_TICKETS="$t" node "$script" "$@" >"$out" 2>"$err"; }

scan TASK-7; rc=$?
[ "$rc" -eq 0 ]; check "scan prints, exit 0" $?
grep -q '^  db-migration — unlabelled; .*standing rule no-production-db' "$out" && grep -q '! description:2: .*Flyway migration' "$out"
check "an unlabelled migration is found, with its line and the standing rule" $?
grep -q '^  contract-push — unlabelled; .*never covered' "$out" && grep -q 'AC #1: The contract change' "$out"
check "a contract push in an AC is found and marked never covered" $?
grep -q '^  production-config — labelled' "$out" && grep -q 'P1-E02-T03.md:3: .*%prod' "$out"
check "the linked spec is read, with its line numbers" $?
grep -q '^  crypto-logging — unlabelled' "$out" && grep -q 'P1-E02-T03.md:4' "$out"
check "a logging line of the spec is found" $?
! grep -q 'P1-E02-T03.md:8' "$out"
check "the spec's Definition of Done is skipped" $?
grep -q '^  auth-access — unlabelled' "$out" && grep -q 'docs/roles.md:2: .*access matrix' "$out"
check "a referenced docs line range is read" $?
grep -q 'unknown STOP label stop-weird' "$out"
check "an unknown stop-* label is reported" $?

scan TASK-8; grep -q 'no STOP signal' "$out"
check "a ticket with no signal says so" $?
scan TASK-9; grep -q '^  auth-access — labelled' "$out" && grep -q 'label only' "$out"
check "a label with no text hit is still listed" $?

scan --json TASK-7 TASK-8; rc=$?
[ "$rc" -eq 0 ] && jq -e 'length == 2 and (.[0].items | map(.category) | index("db-migration")) != null and (.[1].items | length) == 0' "$out" >/dev/null
check "--json, several tickets" $?

scan TASK-7 TASK-404; rc=$?
[ "$rc" -eq 1 ] && grep -q 'cannot read TASK-404' "$err" && grep -q '^TASK-7 ' "$out"
check "an unreadable ticket: exit 1, the others still printed" $?
scan; [ $? -eq 2 ]; check "no ticket: usage" $?
scan nope; [ $? -eq 2 ]; check "a bad id: usage" $?

# Without STOP_SCAN_TICKETS it reads the ticket with `backlog task view <id> --json`, nothing else.
cat > "$root/bin/backlog" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$root/calls"
cat "$t/TASK-8.json"
EOF
chmod +x "$root/bin/backlog"
PATH="$root/bin:$PATH" STOP_SCAN_ROOT="$r" node "$script" TASK-8 >"$out" 2>"$err"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$root/calls")" = "task view TASK-8 --json" ]
check "reads through backlog task view only (read-only)" $?

echo "stop-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
