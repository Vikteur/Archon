#!/usr/bin/env bash
# Tests for .archon/scripts/merge-ledger.sh against a throwaway origin and clone, a stub gh and archon on PATH and a
# fixture audit trail.
# Usage: bash .archon/scripts/test/merge-ledger.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/merge-ledger.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
err="$root/err"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$err" 2>/dev/null; fi
}
ledger() { (cd "$w" && PATH="$root/bin:$PATH" bash "$script" --audit-dir "$root/audit" "$@" >"$root/out" 2>"$err"); }
# row <ref> <field>: one field of the --json row for a pull request (#n) or a push (short sha)
row() { jq -r --arg r "$1" --arg f "$2" '.[] | select(.ref == $r) | .[$f]' "$root/out"; }
said() { grep -qF -- "$1" "$err"; }

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"
cd "$w" || exit 2
git config user.name t; git config user.email t@t
# commit <iso time> <subject> [file]: one commit on main at that committer time; prints its sha
commit() {
  echo "$2" > "${3:-f.txt}"; git add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -qm "$2"; git rev-parse HEAD
}
mkdir -p docs/retro/TASK-11
commit 2026-10-16T09:00:00Z base docs/retro/TASK-11/lessons-learned.md >/dev/null
m9=$(commit 2026-10-16T12:00:00Z "feat: TASK-9 before the window")
m10=$(commit 2026-10-17T10:00:00Z "Merge pull request #10")
m11=$(commit 2026-10-17T11:00:00Z "Merge pull request #11")
m12=$(commit 2026-10-17T12:00:00Z "Merge pull request #12")
p1=$(commit 2026-10-17T13:00:00Z "chore(backlog): TASK-5")
p2=$(commit 2026-10-17T14:00:00Z "docs: nobody recorded this push")
p3=$(commit 2026-10-17T15:00:00Z "chore(backlog): TASK-10 close-out")
m13=$(commit 2026-10-17T16:00:00Z "Merge pull request #13")
m14=$(commit 2026-10-17T17:00:00Z "Merge pull request #14")
p4=$(commit 2026-10-17T19:00:00Z "docs: a push named only inside a heredoc")
p5=$(commit 2026-10-17T20:00:00Z "docs: the main session pushed this")
p6=$(commit 2026-10-17T21:00:00Z "docs: pushed to another branch, then merged by hand")
git push -q origin main

# The stub gh answers `gh pr list` from prs.json (GH_FAIL=1: it fails); the stub archon answers `workflow runs`.
mkdir -p "$root/bin" "$root/audit"
cat > "$root/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\${GH_FAIL:-0}" = 1 ] && { echo "gh: HTTP 502" >&2; exit 1; }
[ "\$1 \$2" = "pr list" ] && exec cat "$root/prs.json"
exit 1
EOF
cat > "$root/bin/archon" <<EOF
#!/usr/bin/env bash
[ "\${ARCHON_FAIL:-0}" = 1 ] && exit 1
[ "\$1 \$2" = "workflow runs" ] && exec cat "$root/runs.json"
exit 1
EOF
chmod +x "$root/bin/gh" "$root/bin/archon"

jq -n --arg m9 "$m9" --arg m10 "$m10" --arg m11 "$m11" --arg m12 "$m12" --arg m13 "$m13" --arg m14 "$m14" '[
  {number: 9, title: "feat: TASK-9", mergedAt: "2026-10-16T12:00:00Z", headRefName: "a", body: "", mergeCommit: {oid: $m9}, comments: []},
  {number: 10, title: "feat(x): TASK-10 gate merged", mergedAt: "2026-10-17T10:00:00Z", headRefName: "build-feature-1",
   body: "Summary\n\n## Merge\n\nSTOP items this pull request touches: authentication (approved by the owner)\n\n🤖 Generated with x",
   mergeCommit: {oid: $m10}, comments: []},
  {number: 11, title: "fix: TASK-11 delegator merged", mergedAt: "2026-10-17T11:00:00Z", headRefName: "b", body: "No merge section",
   mergeCommit: {oid: $m11}, comments: []},
  {number: 12, title: "docs: nobody merged this", mergedAt: "2026-10-17T12:00:00Z", headRefName: "c",
   body: "## Merge\n\nSTOP items: none.\n", mergeCommit: {oid: $m12}, comments: []},
  {number: 13, title: "feat: TASK-13 marked", mergedAt: "2026-10-17T16:00:00Z", headRefName: "d", body: "",
   mergeCommit: {oid: $m13}, comments: [{body: "merged\n<!-- merge-ledger: by=merge-ready.sh; rule=D7: no unapproved STOP item -->"}]},
  {number: 14, title: "chore: hand merge", mergedAt: "2026-10-17T17:00:00Z", headRefName: "e",
   body: "## Merge\n\nSTOP items this pull request touches: none; the ticket touches no STOP item.\n",
   mergeCommit: {oid: $m14}, comments: []}
]' > "$root/prs.json"
jq -n --arg m10 "$m10" --arg m11 "$m11" --arg p3 "${p3:0:12}" '{runs: [
  {id: "aaaa1111bbbb", workflow_name: "build-feature", nodes: [
    {nodeId: "auto-merge.gate", outputPreview: ("{\"state\": \"merged\", \"sha\": \"" + $m10 + "\"}")},
    {nodeId: "close-out", outputPreview: ("{\"backlog\": \"" + $p3 + "\"}")}]},
  {id: "cccc2222dddd", workflow_name: "other-workflow", nodes: [
    {nodeId: "auto-merge.gate", outputPreview: ("{\"state\": \"merged\", \"sha\": \"" + $m11 + "\"}")}]}
]}' > "$root/runs.json"

# tool <iso time> <agent> <ok> <arg>: one audit-trail record
tool() { jq -nc --arg t "$1" --arg a "$2" --argjson ok "$3" --arg arg "$4" \
  '{type: "TOOL", tool: "Bash", ok: $ok, loggedAt: $t, session: ("s-" + $a + "-0123456789"), agent: $a, arg: $arg}' >> "$root/audit/s.jsonl"; }
tool 2026-10-17T11:01:00Z reviewer true 'bash .archon/scripts/auto-merge.sh 11 --no-merge'
tool 2026-10-17T11:05:00Z delegator true 'cd /x && bash .archon/scripts/auto-merge.sh 11 2>&1 | tail -3'
tool 2026-10-17T12:01:00Z main false 'bash .archon/scripts/auto-merge.sh 12'
tool 2026-10-17T12:02:00Z main true $'cat > note.md <<EOF\nbash .archon/scripts/auto-merge.sh 12\nEOF'
tool 2026-10-17T12:03:00Z main true 'gh pr merge 12 --repo someone/else --squash'
tool 2026-10-17T14:30:00Z main true 'bash .archon/scripts/auto-merge.sh 12'
tool 2026-10-17T13:02:00Z delegator true 'bash .archon/scripts/commit-tickets.sh "TASK-5"'
tool 2026-10-17T12:58:00Z main true 'git push -q origin HEAD:main'
tool 2026-10-17T17:01:00Z main true 'gh pr merge 14 --merge'
tool 2026-10-17T19:01:00Z main true $'git commit -qm "$(cat <<EOF\nrun git push origin main later\nEOF\n)"'
tool 2026-10-17T20:01:00Z main true 'git fetch -q && git push -q origin HEAD:main 2>&1'
tool 2026-10-17T21:01:00Z main true 'git push -q origin HEAD:feature'

# 1. The full ledger since a date, as JSON.
ledger --since 2026-10-17 --json; rc=$?
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 a merge before --since is left out" $([ -z "$(row '#9' who)" ] && [ -z "$(row "${m9:0:8}" who)" ]; echo $?)
check "1 merge commits are not listed as pushes" $([ -z "$(row "${m10:0:8}" who)" ]; echo $?)
check "1 oldest first" $([ "$(jq -r 'map(.ref) | join(" ")' "$root/out")" = "#10 #11 #12 ${p1:0:8} ${p2:0:8} ${p3:0:8} #13 #14 ${p4:0:8} ${p5:0:8} ${p6:0:8}" ]; echo $?)

# 2. Merges.
check "2 gate merge: the build-feature run" $([ "$(row '#10' who)" = "build-feature run aaaa1111 (auto-merge gate)" ] \
  && row '#10' rule | grep -q "ended by TASK-58"; echo $?)
check "2 STOP section named" $([ "$(row '#10' stop)" = "authentication (approved by the owner)" ]; echo $?)
check "2 no retro folder" $([ "$(row '#10' retro)" = no ]; echo $?)
check "2 delegator merge from the audit trail, --no-merge ignored, other workflow ignored" \
  $([ "$(row '#11' who)" = "delegator session s-delega (auto-merge.sh)" ] && [ "$(row '#11' rule)" = "TASK-55: the delegator merges through auto-merge.sh" ]; echo $?)
check "2 no merge section: stop -" $([ "$(row '#11' stop)" = "-" ]; echo $?)
check "2 retro folder found" $([ "$(row '#11' retro)" = yes ]; echo $?)
check "2 failed call, heredoc text, other repo, outside window: unattributed" \
  $([ "$(row '#12' who)" = unattributed ] && [ "$(row '#12' rule)" = "-" ]; echo $?)
check "2 STOP items: none. reads as -" $([ "$(row '#12' stop)" = "-" ]; echo $?)
check "2 STOP items: none; ... reads as -" $([ "$(row '#14' stop)" = "-" ]; echo $?)
check "2 no ticket: retro -" $([ "$(row '#12' retro)" = "-" ]; echo $?)
check "2 marker comment" $([ "$(row '#13' who)" = "merge-ready.sh" ] && [ "$(row '#13' rule)" = "D7: no unapproved STOP item" ]; echo $?)
check "2 gh pr merge by hand" $([ "$(row '#14' who)" = "main session s-main-0 (gh pr merge)" ] && [ "$(row '#14' rule)" = "none recorded" ]; echo $?)

# 3. Direct pushes.
check "3 pushing script after the commit wins over a push before it" \
  $([ "$(row "${p1:0:8}" who)" = "delegator session s-delega (commit-tickets.sh)" ] && row "${p1:0:8}" rule | grep -q "^TASK-64"; echo $?)
check "3 nothing recorded: unattributed" $([ "$(row "${p2:0:8}" who)" = unattributed ]; echo $?)
check "3 close-out push from the run" $([ "$(row "${p3:0:8}" who)" = "build-feature run aaaa1111 (close-out)" ]; echo $?)
check "3 git push named only in a heredoc: unattributed" $([ "$(row "${p4:0:8}" who)" = unattributed ]; echo $?)
check "3 git push to main as its own segment" $([ "$(row "${p5:0:8}" who)" = "main session s-main-0 (git push)" ]; echo $?)
check "3 git push to another branch does not count" $([ "$(row "${p6:0:8}" who)" = unattributed ]; echo $?)
check "3 push rows carry the ticket" $([ "$(row "${p1:0:8}" ticket)" = TASK-5 ]; echo $?)

# 4. --until, text output.
ledger --since 2026-10-17 --until 2026-10-17T13:30:00Z; rc=$?
check "4 text exit 0 with header" $([ "$rc" -eq 0 ] && head -1 "$root/out" | grep -q "^kind	ref	at	who	rule	stop	retro	title$"; echo $?)
check "4 --until cuts the window" $(! grep -q "^merge	#13	" "$root/out" && grep -q "^merge	#12	" "$root/out"; echo $?)
check "4 STOP column reads named" $(grep "^merge	#10	" "$root/out" | cut -f6 | grep -qx named; echo $?)
check "4 total line" $(tail -1 "$root/out" | grep -qx "# total: 3 merges (1 unattributed), 1 direct pushes (0 unattributed)"; echo $?)

# 5. Archon unavailable: the run sources drop, the rest still answers.
ARCHON_FAIL=1 ledger --since 2026-10-17 --json; rc=$?
check "5 archon down: exit 0, warned, gate merge unattributed" \
  $([ "$rc" -eq 0 ] && said "archon unavailable" && [ "$(row '#10' who)" = unattributed ] && [ "$(row "${p3:0:8}" who)" = unattributed ]; echo $?)

# 6. Failures and usage.
GH_FAIL=1 ledger --since 2026-10-17; rc=$?
check "6 gh failure exits 1" $([ "$rc" -eq 1 ] && said "gh pr list failed"; echo $?)
for args in "" "--since" "--since yesterday" "--since 2026-10-17 --window x" "--since 2026-10-17 --bogus"; do
  # shellcheck disable=SC2086
  ledger $args; rc=$?; check "6 usage '$args'" $([ "$rc" -eq 2 ]; echo $?)
done

echo "merge-ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
