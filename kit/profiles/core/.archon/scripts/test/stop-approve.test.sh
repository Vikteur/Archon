#!/usr/bin/env bash
# Tests for .archon/scripts/stop-approve.sh: drafting (governance with paths), recording the owner's chat approvals onto
# origin/main, the 7-day expiry, and revoking (owner decision 2026-11-19, the list round; docs/archon/stop-policy.md).
# Usage: bash .archon/scripts/test/stop-approve.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
script="$here/stop-approve.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"; out="$root/out"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" "$err" 2>/dev/null; fi
}

# A bare origin and a clone of it, the clone's main at origin/main.
git init -q --bare -b main "$root/origin.git"
w="$root/w"
git clone -q "$root/origin.git" "$w" 2>/dev/null
git -C "$w" config user.name t; git -C "$w" config user.email t@t
mkdir -p "$w/.archon/stop/approvals"
# The checkout's policy, with the owner and timezone these cases assert (an install's policy names its own).
jq '.owner = "Example Owner" | .timezone = "Europe/Brussels"' "$repo_root/.archon/stop/policy.json" \
  >"$w/.archon/stop/policy.json"
git -C "$w" add -A; git -C "$w" commit -qm base; git -C "$w" push -q origin HEAD:main

(cd "$w" && bash "$script" draft TASK-1 deploy "x" >"$out" 2>"$err" < /dev/null) && [ -f "$w/.git/stop-drafts/draft.json" ]
check "by default the draft is in the git folder" $?
rm -rf "$w/.git/stop-drafts"
export STOP_DRAFT_DIR="$root/drafts"
ap() { (cd "$w" && bash "$script" "$@" >"$out" 2>"$err" < /dev/null); }
on_main() { git -C "$w" fetch -q origin; git -C "$w" ls-tree --name-only origin/main .archon/stop/approvals/ | sed 's|.*/||' | grep -v '^_' | tail -n 1; }
main_file() { git -C "$w" show "origin/main:.archon/stop/approvals/$1"; }
reset() { rm -rf "$STOP_DRAFT_DIR"; }

# Drafting.
ap draft TASK-5 db-migration "V7 adds the guest table"; check "draft a coverable item" $?
ap draft TASK-5 contract-push "push the guest endpoints"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'never covered' "$err"; check "draft refuses a never-covered category (exit 4)" $?
ap draft TASK-5 secret-value "the token"; [ $? -eq 4 ]; check "draft refuses secret-value" $?
ap draft TASK-5 moon "x"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'unknown STOP category' "$err"; check "draft refuses an unknown category" $?
ap draft TASK-5 db-migration "again"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'already drafted' "$err"; check "draft refuses the same ticket and category twice" $?
ap draft nope db-migration "x"; [ $? -eq 4 ]; check "draft refuses a bad ticket id" $?
ap draft TASK-5; [ $? -eq 2 ]; check "draft without a detail: usage" $?
ap draft TASK-5 governance "edit the delegator's notes"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'must name the paths' "$err"; check "a governance draft without --paths is refused" $?
ap draft TASK-5 governance "x" --paths '**/*'; rc=$?
[ "$rc" -eq 4 ] && grep -q 'narrow glob' "$err"; check "a governance path starting with * is refused" $?
ap draft TASK-5 governance "x" --paths '../etc/passwd'; [ $? -eq 4 ]; check "a path leaving the repo is refused" $?
ap draft TASK-5 governance "add one line to the delegator's notes" --paths ".github/agents/delegator.agent.md, ./.claude/hooks/x.sh"
check "a governance draft with paths" $?
[ -f "$STOP_DRAFT_DIR/draft.json" ] && [ -z "$(git -C "$w" status --porcelain)" ]
check "the draft lives outside the work tree" $?
ap show; grep -q 'draft 1: TASK-5 db-migration' "$out" && grep -q 'draft 2: TASK-5 governance .*(paths: .github/agents/delegator.agent.md, .claude/hooks/x.sh)' "$out"
check "show lists the draft with its paths" $?

# record needs who and the owner's words; there is no sign.
STOP_NOW=2026-11-19T10:00:00Z ap record --words "ok"; rc=$?
[ "$rc" -eq 4 ] && grep -q -- '--by' "$err" && [ -z "$(on_main)" ]; check "record without --by is refused" $?
STOP_NOW=2026-11-19T10:00:00Z ap record --by chat; rc=$?
[ "$rc" -eq 4 ] && grep -q -- '--words is required' "$err" && [ -z "$(on_main)" ]; check "record without --words is refused" $?
STOP_NOW=2026-11-19T10:00:00Z ap record --by chat --words "  "; [ $? -eq 4 ]; check "record with blank --words is refused" $?
ap sign; [ $? -eq 2 ]; check "sign is gone: usage" $?

# record --only 2: the governance entry goes to origin/main; the db-migration entry stays drafted.
head_before=$(git -C "$w" rev-parse HEAD)
STOP_NOW=2026-11-19T10:00:00Z ap record --by chat --words "ja, goedgekeurd" --only 2; rc=$?
f=$(on_main)
[ "$rc" -eq 0 ] && [ "$f" = 2026-11-19-1100.json ] && grep -q "on origin/main as" "$out" \
  && main_file "$f" | jq -e '.expires_at == "2026-11-26T10:00:00.000Z" and .recorded_by == "chat" and .words == "ja, goedgekeurd"
    and .signed_by == "Example Owner" and (.entries | length) == 1 and .entries[0].category == "governance"
    and .entries[0].paths == [".github/agents/delegator.agent.md", ".claude/hooks/x.sh"] and (.entries[0].digest | length) == 64' >/dev/null
check "record --only: one commit on origin/main, 7 days, who, words and paths" $?
[ "$(git -C "$w" rev-parse HEAD)" = "$head_before" ] && [ -z "$(git -C "$w" status --porcelain)" ]
check "record leaves the work tree and HEAD alone" $?
[ "$(git -C "$w" log -1 --format=%s origin/main)" = "stop: owner approvals 2026-11-19-1100.json (in chat)" ] \
  && [ "$(git -C "$w" diff --name-only origin/main~1 origin/main)" = ".archon/stop/approvals/2026-11-19-1100.json" ]
check "the commit changes only the approvals file" $?
ap show; grep -q 'draft 1: TASK-5 db-migration' "$out" && ! grep -q 'draft 2' "$out"; check "the recorded entry leaves the draft" $?

# The digest covers the paths: widening them by hand voids the entry.
main_file "$f" > "$root/f.json"
node -e '
const lib = require(process.argv[1]); const fs = require("fs");
const p = lib.loadPolicy(fs.readFileSync(process.argv[2], "utf8")); const f = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const ok = lib.entryProblem(f, f.entries[0], p) === "";
f.entries[0].paths.push(".archon/stop/policy.json");
process.exit(ok && /digest/.test(lib.entryProblem(f, f.entries[0], p)) ? 0 : 1);' "$here/stop-lib.js" "$w/.archon/stop/policy.json" "$root/f.json"
check "an added path voids the entry's digest" $?

# --until: later than now, at most 7 days; any time of day.
STOP_NOW=2026-11-19T10:00:00Z ap record --by delegator --words "ok" --until 2026-11-27T10:00:00Z; rc=$?
[ "$rc" -eq 4 ] && grep -q 'more than 7 days' "$err"; check "--until past 7 days is refused" $?
STOP_NOW=2026-11-19T10:00:00Z ap record --by delegator --words "ok" --until 2026-11-19T09:00:00Z; [ $? -eq 4 ]
check "--until in the past is refused" $?
STOP_NOW=2026-11-19T10:01:00Z ap record --by delegator --words "ok, tot morgen" --until 2026-11-20T08:15:00Z; rc=$?
g=$(on_main)
[ "$rc" -eq 0 ] && main_file "$g" | jq -e '.expires_at == "2026-11-20T08:15:00.000Z" and .recorded_by == "delegator"' >/dev/null \
  && [ ! -f "$STOP_DRAFT_DIR/draft.json" ]
check "--until at any hour within 7 days; the draft is empty and removed" $?
STOP_NOW=2026-11-19T10:02:00Z ap record --by chat --words "ok"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'no draft' "$err"; check "record with no draft is refused" $?

# show reads the work tree: after a pull the recorded files are active, and expire after their 7 days.
git -C "$w" pull -q --ff-only origin main
STOP_NOW=2026-11-25T10:00:00Z ap show; grep -q "#1 TASK-5 governance: active" "$out"; check "show: active on day 6" $?
STOP_NOW=2026-11-26T10:00:00Z ap show; grep -q "2026-11-19-1100: grants nothing (expired" "$out"; check "show: expired after 7 days" $?

# record retries on a moved main: another commit lands first; the record still lands on top of it.
git -C "$w" commit -q --allow-empty -m other; git -C "$w" push -q origin HEAD:main
ap draft TASK-6 auth-access "planner role in the access matrix" >/dev/null
STOP_NOW=2026-11-19T12:00:00Z ap record --by chat --words "ok"; rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$w" log -2 --format=%s origin/main | tail -n 1)" = other ]; check "record builds on the newest main" $?

# Revoke one entry, then the file: each its own commit on origin/main.
id=2026-11-19-1100
STOP_NOW=2026-11-19T13:00:00Z ap revoke "$id" 1; rc=$?
[ "$rc" -eq 0 ] && main_file "$id.json" | jq -e '.entries[0].revoked_at == "2026-11-19T13:00:00.000Z" and .revoked_at == null' >/dev/null
check "revoke one entry" $?
STOP_NOW=2026-11-19T13:00:00Z ap revoke "$id"; rc=$?
[ "$rc" -eq 0 ] && main_file "$id.json" | jq -e '.revoked_at != null' >/dev/null; check "revoke the file" $?
ap revoke 1999-01-01-0000; [ $? -eq 4 ]; check "revoke an unknown file is refused" $?
ap frobnicate; [ $? -eq 2 ]; check "an unknown command: usage" $?

echo "stop-approve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
