#!/usr/bin/env bash
# Tests for .archon/scripts/retro-digest.sh against a throwaway origin and clone, a stub gh and archon on PATH, a stub
# verify-fixes.js and a stub notify-owner.sh.
# Usage: bash .archon/scripts/test/retro-digest.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/retro-digest.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$err" 2>/dev/null; fi
}
digest() { (cd "$w" && PATH="$root/bin:$PATH" bash "$script" --audit-dir "$root/audit" "$@" >"$root/out" 2>"$err"); }
said() { grep -qF -- "$1" "$err"; }
page="$root/w/docs/retro/digest/2026-10-18.md"
# section <heading>: the lines of one "## <heading>" section of the page
section() { sed -n "/^## $1/,/^## /p" "$page"; }

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"
cd "$w" || exit 2
git config user.name t; git config user.email t@t
mkdir -p docs/retro/TASK-2 .archon/scripts
printf '# Lessons\n\n## Run bbbb2222 — 2026-10-17 — failed\n' > docs/retro/TASK-2/lessons-learned.md
GIT_COMMITTER_DATE=2026-10-16T09:00:00Z git add -A && GIT_COMMITTER_DATE=2026-10-16T09:00:00Z git commit -qm base
echo x > x.txt; git add -A; GIT_COMMITTER_DATE=2026-10-17T10:00:00Z git commit -qm "Merge pull request #20"
m20=$(git rev-parse HEAD)
echo y > y.txt; git add -A; GIT_COMMITTER_DATE=2026-10-17T11:00:00Z git commit -qm "docs: an unrecorded push"
git push -q origin main
head0=$(git rev-parse HEAD)

mkdir -p "$root/bin" "$root/audit" "$root/tools"
: > "$root/audit/s.jsonl"
cat > "$root/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\${GH_FAIL:-0}" = 1 ] && { echo "gh: HTTP 502" >&2; exit 1; }
case "\$*" in
  "pr list --state merged"*) exec cat "$root/prs.json" ;;
  "pr list --state open"*) echo "\${OPEN_PRS:-0}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$root/bin/archon" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "workflow runs" ] && exec cat "$root/runs.json"
exit 1
EOF
chmod +x "$root/bin/gh" "$root/bin/archon"
cat > "$root/tools/verify-fixes.js" <<'EOF'
const run = process.argv[2];
if (run.startsWith('dddd')) { console.log(JSON.stringify({fix: 72, verdict: 'fail', evidence: 'x'}));
  console.log(JSON.stringify({fix: 69, verdict: 'pass', evidence: 'x'})); process.exit(1); }
if (run.startsWith('cccc')) { console.log(JSON.stringify({fix: 72, verdict: 'not-in-capture', evidence: 'x'})); process.exit(3); }
console.log(JSON.stringify({fix: 72, verdict: 'pass', evidence: 'x'}));
EOF
cat > "$root/tools/run-log.js" <<'EOF'
const run = process.argv[2];
if (run.startsWith('bbbb')) { console.log(JSON.stringify({run, true_min: 95.5, resumes: 2})); process.exit(0); }
process.exit(1);
EOF
cat > .archon/scripts/notify-owner.sh <<EOF
#!/usr/bin/env bash
[ "\${NOTIFY_FAIL:-0}" = 1 ] && exit 1
echo "\$*" >> "$root/pings"
EOF

jq -n --arg m20 "$m20" '[{number: 20, title: "feat: TASK-1 a merge", mergedAt: "2026-10-17T10:00:00Z", headRefName: "a",
  body: "## Merge\n\nSTOP items this pull request touches: production configuration (approved)\n", mergeCommit: {oid: $m20}, comments: []}]' > "$root/prs.json"
jq -n '{runs: [
  {id: "aaaa1111x", workflow_name: "build-feature", status: "completed", user_message: "Build TASK-1",
   started_at: "2026-10-17T09:00:00.000Z", completed_at: "2026-10-17T10:05:00.000Z", last_activity_at: "2026-10-17T10:04:00.000Z"},
  {id: "bbbb2222x", workflow_name: "build-feature", status: "failed", user_message: "Build TASK-2\nmore",
   started_at: "2026-10-17T12:00:00.000Z", completed_at: "2026-10-17T12:30:00.000Z", last_activity_at: "2026-10-17T12:05:00.000Z"},
  {id: "cccc3333x", workflow_name: "build-feature", status: "completed", user_message: "Build TASK-3",
   started_at: "2026-10-17T13:00:00.000Z", completed_at: "2026-10-17T15:00:00.000Z", last_activity_at: "2026-10-17T14:00:00.000Z"},
  {id: "dddd4444x", workflow_name: "build-feature", status: "completed", user_message: "Build TASK-4",
   started_at: "2026-10-17T16:00:00.000Z", completed_at: "2026-10-17T17:00:00.000Z", last_activity_at: "2026-10-17T16:59:00.000Z"},
  {id: "eeee5555x", workflow_name: "build-feature", status: "cancelled", user_message: "Build TASK-5",
   started_at: "2026-10-17T18:00:00.000Z", completed_at: "2026-10-17T18:10:00.000Z", last_activity_at: "2026-10-17T18:09:00.000Z"},
  {id: "ffff6666x", workflow_name: "build-feature", status: "failed", user_message: "Build TASK-6",
   started_at: "2026-10-15T09:00:00.000Z", completed_at: "2026-10-15T10:00:00.000Z", last_activity_at: "2026-10-15T09:59:00.000Z"},
  {id: "99997777x", workflow_name: "other", status: "failed", user_message: "Review TASK-7",
   started_at: "2026-10-17T09:00:00.000Z", completed_at: "2026-10-17T09:10:00.000Z", last_activity_at: "2026-10-17T09:09:00.000Z"}
]}' > "$root/runs.json"

# 1. A night with every kind of finding, with fix verdicts.
RETRO_DIGEST_TOOLS="$root/tools" digest --since 2026-10-17 --until 2026-10-18; rc=$?
check "1 exit 0, prints the page path" $([ "$rc" -eq 0 ] && [ "$(cat "$root/out")" = "$page" ] && [ -f "$page" ]; echo $?)
check "1 commits nothing" $([ "$(git rev-parse HEAD)" = "$head0" ] && [ -z "$(git status --porcelain -- . ':!docs/retro/digest' ':!.archon')" ]; echo $?)
check "1 title and window" $(head -1 "$page" | grep -qx "# Retro digest 2026-10-17 to 2026-10-18" && grep -qF "for 2026-10-17T00:00:00Z to 2026-10-18T00:00:00Z" "$page"; echo $?)
check "1 summary counts" $(grep -qF -- "- 1 merges (1 unattributed), 1 direct pushes to main (1 unattributed)." "$page" \
  && grep -qF -- "- 5 build-feature runs: 1 cancelled, 3 completed, 1 failed." "$page"; echo $?)
inc=$(section Incidents)
check "1 failed and stalled run: one incident row, its retro section found" \
  $(grep -qF "| bbbb2222 | TASK-2 | the run failed; stalled 25 min before its end | yes |" <<<"$inc" && [ "$(grep -c bbbb2222 <<<"$inc")" -eq 1 ]; echo $?)
check "1 stall is an incident" $(grep -qF "| cccc3333 | TASK-3 | stalled 60 min before its end | missing |" <<<"$inc"; echo $?)
check "1 failed fix verdict is an incident" $(grep -qF "| dddd4444 | TASK-4 | fix 72 failed (verify-fixes.js) | missing |" <<<"$inc"; echo $?)
check "1 a clean run is no incident" $(! grep -qF "aaaa1111" <<<"$inc"; echo $?)
rev=$(section "Review after")
check "1 review: STOP named, no retro, unattributed push, cancelled run" $(grep -qF "| #20 | STOP items named: production configuration (approved) |" <<<"$rev" \
 && grep -qF "| unattributed push | docs: an unrecorded push |" <<<"$rev" \
  && grep -qF "| eeee5555 | cancelled run with no stopped section (retro-stopped.sh) |" <<<"$rev"; echo $?)
check "1 a merge without a retro is no review item (D16)" $(! grep -qF "without a retro" <<<"$rev"; echo $?)
runs=$(section Runs)
check "1 runs: outside the window and other workflows left out" $(! grep -qF "ffff6666" <<<"$runs" && ! grep -qF "99997777" <<<"$runs"; echo $?)
check "1 runs: archon duration without a log, idle gap, pass" $(grep -qF "| aaaa1111 | TASK-1 | completed | 2026-10-17T09:00:00Z | 65 min | archon | 1 min | pass |" <<<"$runs"; echo $?)
check "1 runs: true clock from run-log.js with resumes" $(grep -qF "| bbbb2222 | TASK-2 | failed | 2026-10-17T12:00:00Z | 95 min | true clock, 2 resumes | 25 min | pass |" <<<"$runs"; echo $?)
check "1 runs: failed fixes named; a capture without the fix is no valid canary, no incident" \
  $(grep -qF "| dddd4444 | TASK-4 | completed | 2026-10-17T16:00:00Z | 60 min | archon | 1 min | fail 72 |" <<<"$runs" \
  && grep -qF "| cccc3333 | TASK-3 | completed | 2026-10-17T13:00:00Z | 120 min | archon | 60 min | no valid canary |" <<<"$runs" \
  && grep -qF "| cccc3333 | TASK-3 | stalled 60 min before its end | missing |" <<<"$inc"; echo $?)
check "1 evidence missing: runs without an event log" $(grep -qF -- "- run-log.js: no event log for 4 runs" "$page"; echo $?)
check "1 pinged the owner once" $([ "$(wc -l < "$root/pings")" -eq 1 ] && grep -qF "warn retro-digest-2026-10-18 Retro digest: 3 incidents need a full retro" "$root/pings"; echo $?)
check "1 no open pull request: no commit warning" $(! said "commit the digest once"; echo $?)

# 2. No verify-fixes, an open pull request, a failing notifier, --out and --title.
rm -f "$root/pings"
OPEN_PRS=2 NOTIFY_FAIL=1 RETRO_DIGEST_TOOLS="$root/none" digest --since 2026-10-17 --until 2026-10-18 --out "$root/d.md" --title "Catch-up"; rc=$?
check "2 exit 0 despite the failing ping" $([ "$rc" -eq 0 ] && [ "$(cat "$root/out")" = "$root/d.md" ] && said "ping not delivered (2 incidents)"; echo $?)
check "2 title" $(head -1 "$root/d.md" | grep -qx "# Catch-up"; echo $?)
check "2 evidence missing names verify-fixes" $(grep -qF -- "- verify-fixes.js: no fix verdicts (R18 not landed)" "$root/d.md"; echo $?)
check "2 open pull requests: told to commit later" $(said "2 open pull requests, 0 live runs: commit the digest once both are 0"; echo $?)

# 3. Failures and usage.
rm -f "$page"
GH_FAIL=1 digest --since 2026-10-17 --until 2026-10-18; rc=$?
check "3 ledger failure exits 1 and writes nothing" $([ "$rc" -eq 1 ] && said "merge-ledger.sh failed" && [ ! -f "$page" ]; echo $?)
for args in "--stall x" "--since 2026-10-18 --until 2026-10-17" "--since yesterday" "--bogus" "--out"; do
  # shellcheck disable=SC2086
  digest $args; rc=$?; check "3 usage '$args'" $([ "$rc" -eq 2 ]; echo $?)
done

echo "retro-digest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
