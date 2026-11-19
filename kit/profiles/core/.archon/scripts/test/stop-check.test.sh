#!/usr/bin/env bash
# Tests for .archon/scripts/stop-check.sh against a throwaway origin holding the policy and the owner's chat approvals,
# with stub gh and backlog on PATH (owner decisions 2026-10-20 D4, D7 and the STOP rule changes; 2026-11-19 the list
# round: approvals recorded from chat, 7 days, governance per named path; docs/archon/stop-policy.md).
# Usage: bash .archon/scripts/test/stop-check.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
script="$here/stop-check.sh"
approve="$here/stop-approve.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"; out="$root/out"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$err" 2>/dev/null; fi
}

# Stubs: gh prints $FX/pr-<n>.json, backlog prints $FX/<id>.json (missing: exit 1).
mkdir -p "$root/bin" "$root/fx"
cat > "$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] && [ -f "$FX/pr-$3.json" ] && { cat "$FX/pr-$3.json"; exit 0; }
exit 1
EOF
cat > "$root/bin/backlog" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "task view" ] && [ -f "$FX/$3.json" ] && { cat "$FX/$3.json"; exit 0; }
exit 1
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" FX="$root/fx"

ticket() { jq -n --arg id "$1" --argjson l "$2" '{id: $id, title: "t", labels: $l}' > "$FX/$1.json"; }
pr() { # pr <n> <title> <body> <files json>
  jq -n --arg t "$2" --arg b "$3" --argjson f "$4" '{number: 1, title: $t, body: $b, state: "OPEN", files: [$f[] | {path: .}]}' > "$FX/pr-$1.json"
}

# The origin: policy and approvals on main; the clone is where stop-check reads origin/main.
git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"
git -C "$w" config user.name t; git -C "$w" config user.email t@t
mkdir -p "$w/.archon/stop/approvals"
cp "$repo_root/.archon/stop/policy.json" "$w/.archon/stop/"
cp "$repo_root/.archon/stop/approvals/_template.json" "$w/.archon/stop/approvals/"
git -C "$w" add -A; git -C "$w" commit -qm base; git -C "$w" push -q origin main

# The owner approves in chat at 11:00 Brussels (10:00Z); the entries hold for 7 days (owner decision 2026-11-19).
recorded_at=2026-11-19T10:00:00Z
night=2026-11-19T23:00:00Z
morning=2026-11-25T09:00:00Z
evening=2026-11-26T10:00:00Z
export STOP_DRAFT_DIR="$root/drafts"
ap() { (cd "$w" && STOP_NOW=${at:-$recorded_at} bash "$approve" "$@" >"$out" 2>"$err" < /dev/null); }
at=""
ap draft TASK-5.2 crypto-logging "log the guest e-mail hash in the audit line" \
  && ap draft TASK-9 auth-access "add the planner role to the access matrix" \
  && ap draft TASK-9 deploy "change the Dockerfile base image" \
  && ap draft TASK-35 governance "one line in the delegator's notes" --paths ".github/agents/delegator.agent.md,.archon/stop/approvals/*.md" \
  && ap record --by chat --words "ja voor 1, 2 en 4; de deploy niet" --only 1,2,4
check "the owner approves three of four drafted items in chat; recorded on origin/main" $?
rm -rf "$STOP_DRAFT_DIR"
git -C "$w" pull -q --ff-only origin main
file=$(ls "$w/.archon/stop/approvals/" | grep -v '^_')

run() { (cd "$w" && STOP_REPO="$w" STOP_NOW=${now:-$night} bash "$script" "$@" >"$out" 2>"$err"); }
now=""

# PR shaped like #150: a logging item, covered by the chat approval.
ticket TASK-5.2 '["stop-crypto-logging"]'
pr 150 "feat(TASK-5.2): audit log" $'## Summary\nx\n\nSTOP items this ticket touches: what gets logged where personal data is involved (the audit line).\n\n## Test plan\n- ci' '["backend/src/main/java/Audit.java"]'
run 150; rc=$?
[ "$rc" -eq 3 ] && head -n 1 "$out" | grep -q '^covered (TASK-5.2)' && grep -q "approval:${file%.json}#1" "$out"
check "#150 shape: a chat approval covers the logging item (covered, exit 3)" $?

# The same PR on day 6: still covered; after 7 days it has expired.
now=$morning run 150; rc=$?
[ "$rc" -eq 3 ] && head -n 1 "$out" | grep -q '^covered'
check "the entry still covers on day 6: covered, exit 3" $?
now=$evening run 150; rc=$?
[ "$rc" -eq 1 ] && head -n 1 "$out" | grep -q '^owner' && grep -q 'expired' "$out"
check "the entry expires after 7 days: owner, exit 1" $?
now=""

# PR shaped like #143: a contract push (never covered) and a migration (standing rule, no production database).
ticket TASK-7.2 '["stop-contract-push", "stop-db-migration"]'
pr 143 "feat(TASK-7.2): sign-in tables" $'STOP items this ticket touches:\n- a contract change pushed to the hub\n- a database migration (V3)\n\n## Test plan' '["backend/src/main/resources/db/migration/V3__x.sql"]'
run 143; rc=$?
[ "$rc" -eq 1 ] && grep -q '^contract-push (label): owner' "$out" && grep -q '^db-migration (label): covered — rule:no-production-db' "$out" \
  && grep -q '^db-migration (diff): covered' "$out"
check "#143 shape: contract push holds for the owner, the migration is covered by the standing rule" $?

# PR shaped like #144: a contract push and production config (pre-launch rule).
ticket TASK-7.3 '["stop-contract-push", "stop-production-config"]'
pr 144 "feat(TASK-7.3): sessions" $'STOP items: a contract change; production configuration (%prod session cookie)\n## Test plan' '["backend/src/main/resources/application.properties"]'
run 144; rc=$?
[ "$rc" -eq 1 ] && grep -q '^contract-push.*owner' "$out" && grep -q '^production-config (label): covered — rule:pre-launch-production-config' "$out"
check "#144 shape: contract push holds, production config is pre-approved before launch" $?

# A ticket with no STOP item and a PR that says so.
ticket TASK-20 '["backend"]'
pr 20 "feat(TASK-20): guest list" $'STOP items: touches no STOP item.\n\n## Test plan' '["backend/src/main/java/G.java"]'
run 20; rc=$?
[ "$rc" -eq 0 ] && [ "$(head -n 1 "$out")" = "none (TASK-20)" ]
check "no STOP item anywhere: none, exit 0" $?

# The line as pr-refresh.sh writes it, last in its generated block: the end marker ends the section (PR #196 shape).
pr 22 "feat(TASK-20): guest list" $'## Tests\nx\n\n<!-- pr-refresh:start -->\n### Commits (generated)\n- abc feat: x\n\nSTOP items touched: the ticket touches no STOP item.\n<!-- pr-refresh:end -->\n\n## Merge\nThe owner merges.' '["backend/src/main/java/G.java"]'
run 22; rc=$?
[ "$rc" -eq 0 ] && [ "$(head -n 1 "$out")" = "none (TASK-20)" ]
check "pr-refresh's STOP line in its block: none, exit 0" $?

# A PR without the STOP section fails closed.
pr 21 "feat(TASK-20): guest list" $'## Summary\nno section' '[]'
run 21; rc=$?
[ "$rc" -eq 1 ] && head -n 1 "$out" | grep -q '^owner' && grep -q 'no "STOP items" section' "$out"
check "no STOP section in the PR body: owner (fails closed)" $?

# A contract push stays the owner's even with a hand-made approval-looking entry: never coverable.
ticket TASK-9 '["stop-auth-access", "stop-contract-push"]'
pr 9 "feat(TASK-9): planner role" $'STOP items: authorization (planner role)\n## Test plan' '[]'
run 9; rc=$?
[ "$rc" -eq 1 ] && grep -q '^auth-access (label): covered — approval:' "$out" && grep -q '^contract-push (label): owner — contract-push is never covered' "$out"
check "auth item covered by its entry, contract push never covered" $?

# Secrets are never covered, by label or by a key file in the diff.
ticket TASK-30 '[]'
pr 30 "feat(TASK-30): x" $'STOP items: touches no STOP item.\n## Test plan' '["config/server.key"]'
run 30; rc=$?
[ "$rc" -eq 1 ] && grep -q '^secret-value (diff): owner' "$out"
check "a key file in the diff: secret-value, owner" $?

# An unknown stop-* label goes to the owner.
ticket TASK-31 '["stop-something-new"]'
run ticket TASK-31; rc=$?
[ "$rc" -eq 1 ] && grep -q 'unknown STOP label stop-something-new' "$out"
check "an unknown stop-* label: owner" $?

# A protected path in the diff goes to the owner, even with no label.
ticket TASK-32 '[]'
pr 32 "chore(TASK-32): x" $'STOP items: touches no STOP item.\n## Test plan' '[".github/agents/delegator.agent.md"]'
run 32; rc=$?
[ "$rc" -eq 1 ] && grep -q '^governance (protected-path): owner' "$out"
check "a protected path in the diff: owner" $?

# Governance approved in chat for TASK-35 covers exactly the paths it names, for that ticket only.
ticket TASK-35 '[]'
pr 35 "chore(TASK-35): x" $'STOP items: the agent scope allowlist (the delegator notes).\n## Test plan' '[".github/agents/delegator.agent.md", ".archon/stop/approvals/README.md"]'
run 35; rc=$?
[ "$rc" -eq 3 ] && [ "$(grep -c '^governance (protected-path): covered — approval:' "$out")" -eq 2 ] && grep -q '^governance (plan): covered' "$out"
check "governance: the named paths (and a glob) are covered" $?
pr 36 "chore(TASK-35): x" $'STOP items: the agent scope allowlist (the delegator notes).\n## Test plan' '[".github/agents/delegator.agent.md", ".claude/hooks/scope-guard.sh"]'
run 36; rc=$?
[ "$rc" -eq 1 ] && grep -q '^governance (protected-path): owner — a protected path no approval for this ticket names' "$out"
check "governance: a protected path the approval does not name holds the merge" $?
pr 37 "chore(TASK-32): x" $'STOP items: touches no STOP item.\n## Test plan' '[".github/agents/delegator.agent.md"]'
run 37; rc=$?
[ "$rc" -eq 1 ] && grep -q '^governance (protected-path): owner' "$out"
check "governance: another ticket's approval for the same path covers nothing" $?

# The supervisor's units, scripts and decision schema are protected paths (owner D15).
pr 34 "chore(TASK-32): x" $'STOP items: touches no STOP item.\n## Test plan' '[".archon/systemd/delegator-supervisor.timer", ".archon/scripts/supervisor-tick.sh", ".archon/schemas/delegator-decision.json"]'
run 34; rc=$?
[ "$rc" -eq 1 ] && [ "$(grep -c '^governance (protected-path): owner' "$out")" -eq 3 ]
check "the supervisor's units, scripts and schema: owner" $?

# STOP text that names no known category goes to the owner.
pr 33 "chore(TASK-32): x" $'STOP items: something odd about the moon.\n## Test plan' '[]'
run 33; rc=$?
[ "$rc" -eq 1 ] && grep -q 'names no known category' "$out"
check "STOP text naming no category: owner" $?

# Ticket mode: an approval for another ticket does not cover this one.
ticket TASK-40 '["stop-crypto-logging"]'
run ticket TASK-40; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no approval in chat for TASK-40 crypto-logging' "$out"
check "ticket mode: an entry covers exactly its own ticket" $?
run ticket TASK-5.2; rc=$?
[ "$rc" -eq 3 ] && head -n 1 "$out" | grep -q '^covered'
check "ticket mode: covered, exit 3" $?

# The item the owner said no to was never recorded: TASK-9 deploy is not covered.
ticket TASK-9 '["stop-deploy"]'
run ticket TASK-9; rc=$?
[ "$rc" -eq 1 ] && grep -q '^deploy (label): owner' "$out"
check "an entry the owner said no to covers nothing" $?

# A hand edit after recording breaks the digest.
cp "$w/.archon/stop/approvals/$file" "$root/orig.json"
jq '.entries[0].ticket = "TASK-40"' "$root/orig.json" > "$w/.archon/stop/approvals/$file"
git -C "$w" commit -qam edit; git -C "$w" push -q origin main
run ticket TASK-40; rc=$?
[ "$rc" -eq 1 ] && grep -q 'digest does not match' "$out"
check "an entry edited after recording covers nothing (digest)" $?

# An entry revoked, then the whole file revoked.
# (revoke commits and pushes the change itself)
cp "$root/orig.json" "$w/.archon/stop/approvals/$file"
git -C "$w" commit -qam restore; git -C "$w" push -q origin main
ap revoke "${file%.json}" 1; git -C "$w" pull -q --ff-only origin main
run ticket TASK-5.2; rc=$?
[ "$rc" -eq 1 ] && grep -q 'entry revoked' "$out"
check "a revoked entry covers nothing" $?
ap revoke "${file%.json}"; git -C "$w" pull -q --ff-only origin main
ticket TASK-9 '["stop-auth-access"]'
run ticket TASK-9; rc=$?
[ "$rc" -eq 1 ] && grep -q 'approvals ignored: .*revoked' "$out"
check "a revoked file grants nothing" $?

# Approvals only on a branch, not on origin/main, grant nothing.
cp "$root/orig.json" "$w/.archon/stop/approvals/$file"
git -C "$w" commit -qam restore-local   # committed, not pushed
run ticket TASK-5.2; rc=$?
[ "$rc" -eq 1 ]
check "an approval not on origin/main grants nothing" $?
git -C "$w" push -q origin main
run ticket TASK-5.2; rc=$?
[ "$rc" -eq 3 ]
check "once pushed to main it binds" $?

# TASK-79: a sentence of the plan's STOP text that only denies categories names no item. Approvals for TASK-7.6 first.
at=2026-11-19T10:05:00Z
export STOP_DRAFT_DIR="$root/drafts"
ap draft TASK-7.6 auth-access "the rm_session cookie and the session mechanism" \
  && ap draft TASK-7.6 crypto-logging "the session token hash, kept out of logs" \
  && ap record --by chat --words "ja voor beide"
check "the owner approves the two TASK-7.6 items in chat" $?
rm -rf "$STOP_DRAFT_DIR"
git -C "$w" pull -q --ff-only origin main
at=""
ticket TASK-7.6 '[]'

files256='["identity-domain/src/main/java/com/example/identity/domain/SessionToken.java", "application/src/main/java/com/example/application/security/SessionCookieMechanism.java"]'
text256="The plan touches two STOP items. auth-access: the rm_session cookie (HttpOnly, SameSite=Lax, Max-Age=2592000, Secure only behind a trusted proxy's X-Forwarded-Proto https), a new Quarkus HttpAuthenticationMechanism and IdentityProvider resolving the session on every request, 7-day idle and 30-day absolute limits, roles read from membership_roles, no Origin check. crypto-logging: a 32-byte base64url token with only its SHA-256 hash stored in sessions.token_hash, and the token and hash kept out of logs. The owner approved both in the list round of 2026-11-19 (approval:2026-11-19-0713#1 and #2, valid until the merge, at most 7 days), and the build-feature exception covers this run's steps. The pull request must name both items and the one-way doors. No contract change and no migration."
pr 256 "feat(identity): stay signed in with the rm_session cookie and expiry limits (TASK-7.6)" $'## STOP items touched\nSTOP items touched: plan: '"$text256" "$files256"
run 256; rc=$?
[ "$rc" -eq 3 ] && head -n 1 "$out" | grep -q '^covered (TASK-7.6)' && grep -q '^auth-access (plan): covered — approval:' "$out" \
  && grep -q '^crypto-logging (plan): covered — approval:' "$out" && ! grep -q '^contract-push' "$out" && ! grep -q '^db-migration' "$out"
check "#256 shape: a closing denial names no contract-push or db-migration item" $?

gfiles='["backend/src/main/java/G.java"]'
denial_pr() { pr "$1" "feat(TASK-7.6): x" "STOP items touched: plan: $2"$'\n\n## Test plan' "${3:-$gfiles}"; run "$1"; }
n=270
for t in "No contract change and no migration." "No contract push." "It touches no migration."; do
  n=$((n+1)); denial_pr $n "$t"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(head -n 1 "$out")" = "none (TASK-7.6)" ] && ! grep -q '^contract-push' "$out" && ! grep -q '^db-migration' "$out"
  check "denial: \"$t\" names no item" $?
done

pr 280 "feat(TASK-7.6): x" $'STOP items touched: ticket labels: stop-auth-access; plan: No contract push.\n\n## Test plan' "$gfiles"
run 280; rc=$?
[ "$rc" -eq 3 ] && grep -q '^auth-access (plan): covered — approval:' "$out" && ! grep -q '^contract-push' "$out"
check "denial: stop-route's \"ticket labels: ...; plan: <denial>\" keeps the label item only" $?

denial_pr 281 "No contract push. The migration ships as V1.012."; rc=$?
[ "$rc" -eq 3 ] && grep -q '^db-migration (plan): covered — rule:no-production-db' "$out" && ! grep -q '^contract-push' "$out"
check "denial: a denied item drops, a named one in the next sentence stays" $?

denial_pr 282 "No migration, but the contract change ships with it"; rc=$?
[ "$rc" -eq 1 ] && grep -q '^contract-push (plan): owner' "$out" && grep -q '^db-migration (plan): covered — rule:no-production-db' "$out"
check "denial: \"but ...\" after a denial keeps every category" $?

denial_pr 283 "No contract change and a database migration (V3)."; rc=$?
[ "$rc" -eq 1 ] && grep -q '^contract-push (plan): owner' "$out" && grep -q '^db-migration (plan): covered' "$out"
check "denial: a sentence that also names an item keeps both" $?

ticket TASK-7.7 '["stop-something-new"]'
pr 284 "feat(TASK-7.7): x" $'STOP items touched: plan: No contract change and no migration.\n\n## Test plan' "$gfiles"
run 284; rc=$?
[ "$rc" -eq 1 ] && head -n 1 "$out" | grep -q '^owner' && grep -q 'unknown STOP label stop-something-new' "$out" && ! grep -q '^contract-push' "$out"
check "denial: an unknown stop-* label is still owner" $?

denial_pr 285 "No contract push." '[".claude/hooks/scope-guard.sh"]'; rc=$?
[ "$rc" -eq 1 ] && grep -q '^governance (protected-path): owner' "$out"
check "denial: a protected path is still owner" $?

denial_pr 286 "something odd about the moon. No contract push."; rc=$?
[ "$rc" -eq 1 ] && grep -q 'names no known category' "$out" && ! grep -q '^contract-push' "$out"
check "denial: text naming no category is still owner" $?

# The item detail is the first kept sentence that names the category, cut to 160 characters; the unknown:plan detail
# is the first kept sentence, not the whole text.
run --json 256
jq -e '[.items[] | select(.source == "plan")] as $p
  | ($p | map(select(.category == "auth-access"))[0].detail | startswith("auth-access: the rm_session cookie") and length == 160)
  and ($p | map(select(.category == "crypto-logging"))[0].detail | startswith("crypto-logging: a 32-byte base64url token"))' "$out" >/dev/null
check "denial: a plan item's detail is the first kept sentence naming it, at most 160 characters" $?
run --json 286
jq -e '[.items[] | select(.category == "unknown:plan")][0].detail == "plan: something odd about the moon."' "$out" >/dev/null
check "denial: the unknown:plan detail is the first kept sentence" $?

# A denial beside a stray dash: the dash names nothing and is no item (as stop-check reads a lone "-").
denial_pr 287 "No contract push. -"; rc=$?
[ "$rc" -eq 0 ] && [ "$(head -n 1 "$out")" = "none (TASK-7.6)" ]
check "denial: a leftover with no letter adds no unknown:plan item" $?

# The library reading, sentence by sentence.
export TEXT256="$text256"
node -e '
  const { loadPolicy, planCategories } = require(process.argv[1] + "/stop-lib.js");
  const p = loadPolicy(require("fs").readFileSync(process.argv[2], "utf8"));
  const CP = "contract-push", DB = "db-migration";
  const AA = "auth-access";
  // [text, categories, how many sentences are denials]
  const rows = [
    ["No contract change and no migration.", [], 1],
    ["No contract push.", [], 1],
    ["It touches no migration.", [], 1],
    ["The ticket touches no STOP item. No contract push.", [], 2],
    ["No migration, but the contract change ships with it", [CP, DB], 0],
    ["No contract change and a database migration (V3).", [CP, DB], 0],
    ["No migration ships with the contract change.", [CP, DB], 0],
    ["No contract change or migration.", [CP, DB], 0],
    ["No doubt the contract change ships.", [CP], 0],
    ["- a contract change pushed to the hub\n- a database migration (V3)", [CP, DB], 0],
    [process.env.TEXT256, ["auth-access", "crypto-logging"], 1],
    ["No contract change, no migration.", [], 1],
    ["No contract change, and no migration.", [], 1],
    ["No new migration needed here.", [], 1],
    ["No `stop-contract-push` item.", [], 1],
    ["No new items here.", [], 0],
    ["- no contract push\n- the access matrix (planner role)", [AA], 1],
    ["No contract push\n\nthe access matrix (planner role)", [AA], 1],
    ["No contract push\r\n\r\nthe access matrix (planner role)", [AA], 1],
  ];
  let bad = 0;
  for (const [t, want, denials] of rows) {
    const r = planCategories(t, p);
    const got = JSON.stringify([r.categories, r.denied.length]);
    if (got !== JSON.stringify([want, denials])) { console.error(`"${t.slice(0, 60)}": ${got} != ${JSON.stringify([want, denials])}`); bad++; }
  }
  const r = planCategories("something odd about the moon. No contract push.", p);
  if (JSON.stringify(r.kept) !== JSON.stringify(["something odd about the moon."]) || JSON.stringify(r.denied) !== JSON.stringify(["No contract push."])) {
    console.error("kept/denied: " + JSON.stringify(r)); bad++;
  }
  process.exit(bad ? 1 : 0);
' "$here" "$repo_root/.archon/stop/policy.json" >"$out" 2>"$err"
check "planCategories: denial sentences, sentence by sentence" $?

# Cleanup mode: fully merged → covered; not merged → owner.
printf '#!/usr/bin/env bash\nexit 0\n' > "$root/cm-ok"; printf '#!/usr/bin/env bash\necho "feat/x: 2 commits not in main"; exit 1\n' > "$root/cm-no"
CLEANUP_MERGED="$root/cm-ok" run cleanup feat/x; rc=$?
[ "$rc" -eq 3 ] && grep -q 'rule:merged-cleanup' "$out"
check "cleanup of a fully merged branch: covered" $?
CLEANUP_MERGED="$root/cm-no" run cleanup feat/x; rc=$?
[ "$rc" -eq 1 ] && grep -q 'not all in main' "$out"
check "cleanup of a branch not all in main: owner" $?

# A label for delete-history outside cleanup mode is not covered by the cleanup rule.
ticket TASK-41 '["stop-delete-history"]'
run ticket TASK-41; rc=$?
[ "$rc" -eq 1 ]
check "delete-history outside cleanup: owner" $?

# --json and errors.
run --json ticket TASK-5.2; rc=$?
[ "$rc" -eq 3 ] && jq -e '.verdict == "covered"' "$out" >/dev/null
check "--json prints the verdict JSON" $?
run ticket TASK-404; rc=$?
[ "$rc" -eq 1 ] && head -n 1 "$out" | grep -q '^owner' && grep -q 'cannot read TASK-404' "$out"
check "an unreadable ticket: owner (fails closed)" $?
run 999; rc=$?
[ "$rc" -eq 1 ] && grep -q 'cannot read pull request' "$out"
check "an unreadable PR: owner" $?
(cd "$w" && STOP_REPO="$w" STOP_REF=origin/nope STOP_NO_FETCH=1 bash "$script" ticket TASK-5.2 >"$out" 2>"$err"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'no .archon/stop/policy.json' "$out"
check "no policy at the ref: owner" $?
(cd "$repo_root" && STOP_REF=HEAD STOP_NO_FETCH=1 bash "$script" ticket TASK-5.2 >"$out" 2>"$err"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'for test repos' "$out"
check "another ref in a real checkout is refused: only origin/main counts" $?
run; rc=$?
[ "$rc" -eq 2 ]
check "no argument: usage, exit 2" $?
run ticket; rc=$?
[ "$rc" -eq 2 ]
check "ticket without an id: usage, exit 2" $?

echo "stop-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
