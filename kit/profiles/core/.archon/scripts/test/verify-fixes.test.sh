#!/usr/bin/env bash
# Tests for .archon/scripts/verify-fixes.js (R18, T13) against fixture runs under a throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/verify-fixes.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/verify-fixes.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
export RUN_LOG_OFFLINE=1            # and archon is never asked
export READY_RUNS_DIR="$root/ready"; mkdir -p "$READY_RUNS_DIR"
ws="$ARCHON_HOME/workspaces/owner/repo"
mkdir -p "$ws/logs"
out="$root/out.txt"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$out" 2>/dev/null; fi
}
verdict() { grep "\"fix\":$1," "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(s?JSON.parse(s).verdict:"none"))'; }
capture() { # capture <run> <yaml text> <close-out text>
  mkdir -p "$ws/workflow-source/runs/$1/project/.archon/workflows" "$ws/workflow-source/runs/$1/project/.archon/scripts"
  printf '%s\n' "$2" > "$ws/workflow-source/runs/$1/project/.archon/workflows/build-feature.yaml"
  printf '%s\n' "$3" > "$ws/workflow-source/runs/$1/project/.archon/scripts/close-out.sh"
}
ns() { echo "{\"type\":\"node_start\",\"step\":\"$1\",\"ts\":\"$2\",\"execution\":{\"path\":\"$1\",\"node\":{\"kind\":\"exec\"}}}"; }
ex() { # ex <step> <exit> <stdout json string> <stderr json string>
  echo "{\"type\":\"exec_output\",\"ts\":\"2026-10-19T07:30:00Z\",\"step\":\"$1\",\"exit_code\":$2,\"stdout_tail\":$3,\"stderr_tail\":$4}"
}
yaml_all='env: RUN_ID=$WORKFLOW_ID
main-ci: bash .archon/scripts/main-ci.sh'
close_all='bash "$umbrella/scripts/tokenomics/commit-reports.sh" || echo warn'
sha=da45888c5b454602acc8e90708f3a9cd20201cfd

# Run A, shaped like 4b33311d: carries every fix, but main-ci could not tell its commit and the token reports failed.
a=4b33311d000000000000000000000000
capture $a "$yaml_all" "$close_all"
{
  echo '{"type":"workflow_start","ts":"2026-10-19T07:00:00Z"}'
  ns ticket 2026-10-19T07:00:01Z
  ns open-pr 2026-10-19T07:50:00Z
  ex open-pr 1 '""' '"hint: use git pull before pushing again."'
  ex open-pr 0 "\"{\\\"pr\\\": \\\"https://github.com/o/r/pull/152\\\", \\\"sha\\\": \\\"$sha\\\"}\"" '"Everything up-to-date"'
  ns ci 2026-10-19T07:51:00Z
  ex ci 0 "\"{\\\"state\\\": \\\"red\\\", \\\"sha\\\": \\\"$sha\\\", \\\"detail\\\": \\\"local CI: local-ci/groma=failure\\\"}\"" '"local-ci-run: done (exit 1)"'
  ex ready 0 '"https://github.com/o/r/pull/152"' '"marked as ready"'
  ex gate 0 '"{\"state\":\"ready\"}"' '""'
  ns merged 2026-10-19T08:00:00Z
  ex merged 0 '"{\"state\":\"merged\"}"' '""'
  ns main-ci 2026-10-19T08:10:00Z
  ex main-ci 0 '"{\"state\": \"none\", \"sha\": \"7b1cbba\", \"detail\": \"no CI run registered for 7b1cbba\"}"' '"local-ci-run: cannot tell which commit to run (7b1cbba)"'
  ns close-out 2026-10-19T08:20:00Z
  ex close-out 0 '"{\"backlog\":\"4b59ab9a\"}"' '"orts.sh: Permission denied\nwarning: the token reports were not committed."'
  echo '{"type":"workflow_complete","ts":"2026-10-19T08:21:00Z"}'
} > "$ws/logs/$a.jsonl"
node "$script" $a --woke 2026-10-19T08:00:40Z > "$out"; code=$?
[ $code -eq 1 ]; check "a 4b33311d-shaped run exits 1" $?
[ "$(verdict 72)" = fail ]; check "72 fails on cannot tell which commit" $?
[ "$(verdict 74)" = fail ]; check "74 fails on Permission denied" $?
[ "$(verdict 57)" = pass ] && [ "$(verdict 59)" = pass ] && [ "$(verdict 70)" = pass ] && [ "$(verdict 65)" = pass ] && [ "$(verdict 71)" = pass ]
check "57, 59, 65, 70 and 71 pass" $?
[ "$(verdict 69)" = pass ]; check "69 passes 40 s after merged started" $?
[ "$(verdict 64)" = not-triggered ]; check "64 without --commit is not triggered" $?
[ "$(verdict 66)" = unknown ]; check "66 without archon's record is unknown" $?
tail -1 "$out" | grep -q '"fail":2'; check "the summary counts the fails" $?

node "$script" 4b33311d --fixes 69 --woke 2026-10-19T08:02:00Z > "$out"; [ $? -eq 1 ] && [ "$(verdict 69)" = fail ]
check "69 fails when the ready signal came more than 75 s late; --fixes and a prefix work" $?
echo '{}' > "$READY_RUNS_DIR/$a.json"
node "$script" $a --fixes 69 --woke 2026-10-19T08:00:10Z > "$out"; [ "$(verdict 69)" = fail ]
check "69 fails on a ready record left after completion" $?
rm "$READY_RUNS_DIR/$a.json"

# Run B: the reuse detail passes 72; a quoted output fails 65; a missing local-ci job fails 71.
b=bbbb0000000000000000000000000000
capture $b "$yaml_all" "$close_all"
{
  echo '{"type":"workflow_start","ts":"2026-10-19T07:00:00Z"}'
  ns ticket 2026-10-19T07:00:01Z
  ex ci 0 "\"{\\\"state\\\": \\\"green\\\", \\\"sha\\\": \\\"$sha\\\"}\"" '"local-ci/build=missing"'
  ex gate 0 '""' "\"error: 147' is not a number\""
  ex main-ci 0 "\"{\\\"state\\\": \\\"green\\\", \\\"sha\\\": \\\"7b1cbba\\\", \\\"detail\\\": \\\"the head's green result is reused, no local CI was run\\\"}\"" '""'
} > "$ws/logs/$b.jsonl"
node "$script" $b > "$out"
[ "$(verdict 72)" = pass ]; check "the reuse detail passes 72" $?
[ "$(verdict 65)" = fail ]; check "a NNN' in gate stderr fails 65" $?
[ "$(verdict 71)" = fail ]; check "local-ci/<job>=missing fails 71" $?
[ "$(verdict 59)" = fail ]; check "ci on a sha open-pr never pushed fails 59" $?
[ "$(verdict 69)" = not-triggered ] && [ "$(verdict 74)" = not-triggered ]; check "a run that never merged leaves 69 and 74 not triggered" $?

# Run C: a capture without RUN_ID is no valid canary.
c=cccc0000000000000000000000000000
capture $c 'main-ci: bash .archon/scripts/main-ci.sh' "$close_all"
{ echo '{"type":"workflow_start","ts":"2026-10-19T07:00:00Z"}'; ns ticket 2026-10-19T07:00:01Z; } > "$ws/logs/$c.jsonl"
node "$script" $c > "$out"; code=$?
[ $code -eq 3 ] && [ "$(verdict 69)" = not-in-capture ]; check "a capture without RUN_ID exits 3" $?

# Run D: a cut stderr tail never passes a check that needs the absence of an error.
d=dddd0000000000000000000000000000
capture $d "$yaml_all" "$close_all"
{
  echo '{"type":"workflow_start","ts":"2026-10-19T07:00:00Z"}'
  ns close-out 2026-10-19T07:00:01Z
  ex close-out 0 '"{}"' '"…[truncated to last 2000 chars]\n  Completed: build-feature-1"'
} > "$ws/logs/$d.jsonl"
node "$script" $d --fixes 74 > "$out"; code=$?
[ $code -eq 0 ] && [ "$(verdict 74)" = unknown ]; check "a cut tail gives unknown, exit 0" $?

# Fix 64 against a throwaway repo.
repo="$root/repo"; git init -q "$repo"; git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
mkdir -p "$repo/backlog" "$repo/src"; echo x > "$repo/backlog/t.md"; git -C "$repo" add .; git -C "$repo" commit -qm ticket
ok=$(git -C "$repo" rev-parse HEAD)
echo y > "$repo/src/a.txt"; echo z >> "$repo/backlog/t.md"; git -C "$repo" add .; git -C "$repo" commit -qm both
bad=$(git -C "$repo" rev-parse HEAD)
VERIFY_FIXES_REPO="$repo" node "$script" $a --fixes 64 --commit "$ok" > "$out"; [ "$(verdict 64)" = pass ]; check "64 passes a backlog-only commit" $?
VERIFY_FIXES_REPO="$repo" node "$script" $a --fixes 64 --commit "$bad" > "$out"; [ "$(verdict 64)" = fail ]; check "64 fails a commit outside backlog/" $?

# Errors.
node "$script" > "$out" 2>&1; [ $? -eq 2 ]; check "no run id exits 2" $?
node "$script" ffff0000 > "$out" 2>&1; [ $? -eq 2 ]; check "an unknown run exits 2" $?
node "$script" $a --fixes 99 > "$out" 2>&1; [ $? -eq 2 ]; check "an unknown fix exits 2" $?

# Preflight against stub scripts in a throwaway checkout.
mkdir -p "$repo/.archon/scripts" "$root/bin"
for s in sync-main merge-turn ready-runs; do printf '#!/usr/bin/env bash\ncat "%s/%s.out" 2>/dev/null; exit $(cat "%s/%s.code" 2>/dev/null || echo 0)\n' "$root" $s "$root" $s > "$repo/.archon/scripts/$s.sh"; done
printf '#!/usr/bin/env bash\necho "{\\"runs\\":[]}"\n' > "$root/bin/archon"; chmod +x "$root/bin/archon"
printf '.archon/\n' > "$repo/.gitignore"; git -C "$repo" add .gitignore; git -C "$repo" commit -qm ignore
PATH="$root/bin:$PATH" VERIFY_FIXES_REPO="$repo" node "$script" --preflight > "$out"; [ $? -eq 0 ] && [ "$(grep -c '"ok":true' "$out")" -eq 5 ]
check "preflight passes when every precondition holds" $?
echo "https://github.com/o/r/pull/156" > "$root/merge-turn.out"
PATH="$root/bin:$PATH" VERIFY_FIXES_REPO="$repo" node "$script" --preflight > "$out"; [ $? -eq 1 ] && grep -q '"check":"merge-queue-empty","ok":false' "$out"
check "preflight fails on a stale merge queue entry" $?

echo "verify-fixes: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
