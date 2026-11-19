#!/usr/bin/env bash
# Tests for .archon/scripts/stop-round.sh: the owner's chat answers in the list round become a preview of the entries and
# backlog commands, and with --apply one recorded approvals file on origin/main plus the ticket edits (owner decision
# 2026-11-19, the list round; docs/archon/stop-policy.md).
# Usage: bash .archon/scripts/test/stop-round.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
script="$here/stop-round.sh"
approve="$here/stop-approve.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"; out="$root/out"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$err" 2>/dev/null; fi
}

# backlog stub: `task view <id> --json` prints $FX/<id>.json; every other call is logged to $root/writes.
mkdir -p "$root/bin" "$root/fx"
cat > "$root/bin/backlog" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "task view" ]; then [ -f "$FX/$3.json" ] && { cat "$FX/$3.json"; exit 0; }; exit 1; fi
printf '%s\n' "$*" >> "$WRITES"; exit 0
EOF
chmod +x "$root/bin/backlog"
export PATH="$root/bin:$PATH" FX="$root/fx" WRITES="$root/writes" STOP_DRAFT_DIR="$root/drafts"
ticket() { jq -n --arg id "$1" --argjson l "$2" '{id: $id, title: "t", labels: $l}' > "$FX/$1.json"; }

git init -q --bare -b main "$root/origin.git"
w="$root/w"
git clone -q "$root/origin.git" "$w" 2>/dev/null
git -C "$w" config user.name t; git -C "$w" config user.email t@t
mkdir -p "$w/.archon/stop/approvals"
# The checkout's policy, with the owner and timezone these cases assert (an install's policy names its own).
jq '.owner = "Example Owner" | .timezone = "Europe/Brussels"' "$repo_root/.archon/stop/policy.json" \
  >"$w/.archon/stop/policy.json"
git -C "$w" add -A; git -C "$w" commit -qm base; git -C "$w" push -q origin HEAD:main
round() { (cd "$w" && STOP_NOW=${now:-2026-11-19T10:00:00Z} bash "$script" "$@" >"$out" 2>"$err" < /dev/null); }
on_main() { git -C "$w" fetch -q origin; git -C "$w" ls-tree --name-only origin/main .archon/stop/approvals/ | sed 's|.*/||' | grep -v '^_'; }
now=""

ticket TASK-1 '["stop-auth-access"]'
ticket TASK-2 '[]'
ticket TASK-3 '["stop-contract-push"]'
ticket TASK-4 '[]'
ticket TASK-5 '["stop-governance"]'
cat > "$root/answers" <<'EOF2'
# list round 2026-11-19
TASK-1 auth-access approve the planner role in the access matrix
TASK-2 crypto-logging approve log the hashed e-mail in the audit line
TASK-3 contract-push approve push the guest endpoints
TASK-4 db-migration refuse wait for the schema review
TASK-5 governance approve paths=.github/agents/delegator.agent.md one line in the delegator's notes
EOF2

: > "$WRITES"
round "$root/answers"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WRITES" ] && [ -z "$(on_main)" ] && [ ! -e "$STOP_DRAFT_DIR/draft.json" ]
check "without --apply: no backlog write, nothing recorded, nothing drafted" $?
grep -qx 'backlog task edit TASK-1 --remove-label stop-auth-access' "$out" && ! grep -q 'TASK-2 --remove-label' "$out"
check "an approved labelled item loses its label; an unlabelled one has none to lose" $?
grep -q "^backlog task edit TASK-2 --append-notes .*crypto-logging.*approved" "$out"
check "an unlabelled approved item is recorded in the notes only" $?
! grep -q 'TASK-3 --remove-label' "$out" && grep -q '^backlog task edit TASK-3 --append-notes .*never.*covered' "$out"
check "a never-covered approval keeps its label, notes only" $?
grep -qx 'backlog task edit TASK-4 --add-label stop-db-migration' "$out" && grep -q '^backlog task edit TASK-4 --append-notes .*refused' "$out"
check "a refused item gets its label and a note" $?
grep -qx 'backlog task edit TASK-5 --remove-label stop-governance' "$out" \
  && grep -q '^#   3 TASK-5 governance: one line in the delegator.s notes (paths: .github/agents/delegator.agent.md)$' "$out"
check "a governance approval is recorded with its paths" $?
grep -q '^#   1 TASK-1 auth-access' "$out" && grep -q '^#   2 TASK-2 crypto-logging' "$out" && ! grep -q '^#   . TASK-3' "$out"
check "the preview lists the coverable approvals, not the never-covered one" $?
grep -q '^# List (no refused item): TASK-1 TASK-2 TASK-3 TASK-5$' "$out" && grep -q '^# Leave the list: TASK-4$' "$out"
check "the list and the tickets that leave it" $?

# --apply needs who and the owner's words.
round --apply "$root/answers"; [ $? -eq 2 ] && [ -z "$(on_main)" ]; check "--apply without --by and --words: usage" $?
round --apply --by chat --words " " "$root/answers"; [ $? -eq 2 ]; check "--apply with blank words: usage" $?
round --by chat "$root/answers"; [ $? -eq 2 ]; check "--by without --apply: usage" $?

# --apply records one file on origin/main and runs the edits, citing the entry.
: > "$WRITES"
round --apply --by chat --words "ja voor alle vijf, behalve TASK-4" "$root/answers"; rc=$?
f=$(on_main)
[ "$rc" -eq 0 ] && [ "$f" = 2026-11-19-1100.json ] && git -C "$w" show "origin/main:.archon/stop/approvals/$f" \
  | jq -e '.recorded_by == "chat" and .words == "ja voor alle vijf, behalve TASK-4" and (.entries | length) == 3
      and .entries[2].ticket == "TASK-5" and .entries[2].paths == [".github/agents/delegator.agent.md"]' >/dev/null
check "--apply: one approvals file on origin/main with the coverable approvals" $?
grep -qx 'task edit TASK-1 --remove-label stop-auth-access' "$WRITES" && grep -qx 'task edit TASK-4 --add-label stop-db-migration' "$WRITES" \
  && [ "$(grep -c -- '--append-notes' "$WRITES")" -eq 5 ] \
  && grep -q 'TASK-1 --append-notes Owner 2026-11-19 list round: STOP item auth-access approved in chat .* Entry approval:2026-11-19-1100#1' "$WRITES" \
  && grep -q 'TASK-5 --append-notes .*paths: .github/agents/delegator.agent.md.* Entry approval:2026-11-19-1100#3' "$WRITES"
check "--apply: labels and notes, citing the recorded entry" $?
[ ! -e "$STOP_DRAFT_DIR/draft.json" ]; check "--apply leaves the shared draft alone" $?

# A refuse-only answer file records nothing and still edits.
printf 'TASK-4 db-migration refuse not this week\n' > "$root/refuse"
: > "$WRITES"
now=2026-11-19T10:05:00Z round --apply --by chat --words "nee" "$root/refuse"; rc=$?
[ "$rc" -eq 0 ] && [ "$(on_main | wc -l)" -eq 1 ] && grep -q 'TASK-4 --append-notes' "$WRITES"
check "only refusals: nothing recorded, the notes still written" $?

# Bad lines are refused before anything happens.
printf 'TASK-1 auth-access maybe x\n' > "$root/bad"
round "$root/bad"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'bad answer line' "$err"; check "a bad verb is refused" $?
printf 'TASK-1 moon approve x\n' > "$root/bad"
round "$root/bad"; [ $? -eq 4 ]; check "an unknown category is refused" $?
printf 'TASK-1 auth-access approve\n' > "$root/bad"
round "$root/bad"; [ $? -eq 4 ]; check "an answer without text is refused" $?
printf 'TASK-404 auth-access refuse x\n' > "$root/bad"
round "$root/bad"; [ $? -eq 1 ]; check "an unreadable ticket: exit 1" $?
printf '# nothing\n' > "$root/bad"
round "$root/bad"; [ $? -eq 2 ]; check "no answers: usage" $?
round a b; [ $? -eq 2 ]; check "two files: usage" $?
printf 'TASK-5 governance approve the delegator notes\n' > "$root/bad"
round "$root/bad"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'names its paths' "$err"; check "a governance approval without paths= is refused" $?
printf 'TASK-5 governance approve paths=.github/agents/delegator.agent.md\n' > "$root/bad"
round "$root/bad"; [ $? -eq 4 ]; check "a governance approval without what is refused" $?

echo "stop-round: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
