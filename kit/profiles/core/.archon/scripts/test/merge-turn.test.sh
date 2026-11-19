#!/usr/bin/env bash
# Tests for .archon/scripts/merge-turn.sh against a stubbed gh and a throwaway queue folder.
# Usage: bash .archon/scripts/test/merge-turn.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/merge-turn.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$root"' EXIT
U=https://github.com/o/repo/pull

# gh answers `pr view <url>` with "<state> head<n> main", the state read from $root/state/<n> (OPEN when missing).
# `api .../compare/main...head<n>` answers the compare JSON: behind_by from $root/behind/<n> (0 when missing) and, as
# files, what the pull request changes, one path per line in $root/prfiles/<n>; with `--jq .behind_by` only the number.
# `api .../compare/head<n>...main` answers as files what main changed since the merge base, from $root/basefiles/<n>
# ("old -> new" is a rename). Every call is logged.
# $root/big/<n> adds a 300000-byte patch (above the 131072-byte limit of one argument) to the main...head answer;
# $root/badjson/<n> and $root/badbehind/<n> make that answer not JSON / lack behind_by; $root/badbase/<n> makes the
# head...main answer not JSON and $root/failbase/<n> makes that call fail.
mkdir -p "$root/bin" "$root/state" "$root/behind" "$root/prfiles" "$root/basefiles" "$root/big" "$root/badjson" "$root/badbehind" "$root/badbase" "$root/failbase"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$ROOT/gh.log"
files() { # files <list file>: the compare JSON files array
  node -e 'const l = require("fs").existsSync(process.argv[1]) ? require("fs").readFileSync(process.argv[1], "utf8") : "";
    console.log(JSON.stringify(l.split("\n").filter(Boolean).map(f => { const [a, b] = f.split(" -> ");
      return b ? { filename: b, previous_filename: a, status: "renamed" } : { filename: a, status: "modified" }; })));' "$1"
}
case "$1 $2" in
  "pr view") n=${3##*/}; echo "$(cat "$ROOT/state/$n" 2>/dev/null || echo OPEN) head$n main" ;;
  "api repos/o/repo/compare/main...head"*)
    n=${2##*...head}; b=$(cat "$ROOT/behind/$n" 2>/dev/null || echo 0)
    arr=$(files "$ROOT/prfiles/$n")
    if [ -e "$ROOT/big/$n" ]; then # builtins only: the padding never goes through an exec
      printf -v pad '%0300000d' 0; rest=${arr#[}
      arr="[{\"filename\": \"src/Big.java\", \"status\": \"modified\", \"patch\": \"$pad\"}"
      if [ "$rest" = "]" ]; then arr+="]"; else arr+=",$rest"; fi
    fi
    if [ -e "$ROOT/badjson/$n" ]; then echo "not json"
    elif [ -e "$ROOT/badbehind/$n" ]; then echo '{"files": []}'
    elif [[ " $* " == *" --jq .behind_by "* ]]; then echo "$b"
    else echo "{\"behind_by\": $b, $(cat "$ROOT/tip.json" 2>/dev/null) \"files\": $arr}"; fi ;;
  "api repos/o/repo/compare/head"*)
    n=${2#repos/o/repo/compare/head}; n=${n%%...*}
    [ -e "$ROOT/failbase/$n" ] && exit 1
    if [ -e "$ROOT/badbase/$n" ]; then echo "not json"; else echo "{\"files\": $(files "$ROOT/basefiles/$n")}"; fi ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"
# The status reader prints "$TIP_STATE detail" (green when unset) and logs "<repo> <sha>"; local-ci-run.sh logs its
# arguments and exits $RUN_RC. With $root/tip.json holding `"base_commit": {"sha": "..."},` the compare names main's tip.
cat > "$root/status" <<'STUB'
echo "$1 $2" >> "$ROOT/status.log"; echo "${TIP_STATE:-green} detail"
STUB
cat > "$root/run-ci" <<'STUB'
echo "$*" >> "$ROOT/run-ci.log"; exit "${RUN_RC:-0}"
STUB
# rebase-behind.sh --policy prints $POLICY (task-73 when unset) and logs the call.
cat > "$root/rebase-behind" <<'STUB'
echo "$*" >> "$ROOT/policy.log"; [ "$1" = --policy ] || exit 2; echo "${POLICY:-task-73}"
STUB
export LOCAL_CI_STATUS="$root/status" LOCAL_CI_RUN="$root/run-ci" REBASE_BEHIND="$root/rebase-behind"

mt() { # mt <args...>: sets out (stdout), err, rc
  out=$(PATH="$root/bin:$PATH" ROOT="$root" MERGE_QUEUE_DIR="$root/q" MERGE_TURN_POLL_SECONDS=1 \
    bash "$script" "$@" 2> "$root/err"); rc=$?; err=$(cat "$root/err")
}
bg() { # bg <pr number>: `wait` in the background; its exit code lands in $root/rc.<n>
  ( PATH="$root/bin:$PATH" ROOT="$root" MERGE_QUEUE_DIR="$root/q" MERGE_TURN_POLL_SECONDS=1 \
      bash "$script" wait "$U/$1" > "$root/out.$1" 2> "$root/err.$1"; echo $? > "$root/rc.$1" ) &
}
settle() { # settle <file>: wait up to 10 s for it to appear
  for _ in $(seq 1 20); do [ -e "$1" ] && return 0; sleep 0.5; done; return 1
}
poll() { # poll <condition>: wait up to 5 s for it to hold
  for _ in $(seq 1 50); do eval "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1
}
queue() { tr '\n' ' ' < "$root/q/queue" | sed 's#https://github.com/o/repo/pull/##g; s/ $//'; }
seed() { mkdir -p "$root/q"; : > "$root/q/queue"; for n in "$@"; do echo "$U/$n" >> "$root/q/queue"; done; }
reset() { rm -f "$root/tip.json" "$root/status.log" "$root/run-ci.log"; rm -rf "$root/q" "$root"/state/* "$root"/behind/* "$root"/prfiles/* "$root"/basefiles/* "$root"/big/* "$root"/badjson/* "$root"/badbehind/* "$root"/badbase/* "$root"/failbase/* "$root"/rc.* "$root"/out.* "$root"/err.*; }
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}

# 1. An empty queue: the turn is the caller's at once, and the queue holds it.
reset; mt wait "$U/7"
check "1 exit 0 at once" $([ "$rc" -eq 0 ]; echo $?)
check "1 nothing on stdout" $([ -z "$out" ]; echo $?)
check "1 queued" $([ "$(queue)" = 7 ]; echo $?)
mt wait "$U/7"
check "1 waiting again does not queue it twice" $([ "$rc" -eq 0 ] && [ "$(queue)" = 7 ]; echo $?)

# 2. Another open pull request holds the turn: wait until it merges, then it leaves the queue on its own.
reset; seed 7; bg 8
poll '[ "$(queue)" = "7 8" ] && grep -q pull/7 "$root/err.8"'; sleep 1.2   # queued, then one poll round more
check "2 still waiting while 7 is open" $([ ! -e "$root/rc.8" ]; echo $?)
check "2 queued behind 7" $([ "$(queue)" = "7 8" ]; echo $?)
check "2 says who holds the turn" $(grep -q "pull/7" "$root/err.8"; echo $?)
echo MERGED > "$root/state/7"
settle "$root/rc.8"
check "2 the turn comes once 7 merged" $([ "$(cat "$root/rc.8" 2>/dev/null)" = 0 ]; echo $?)
check "2 the merged one left the queue" $([ "$(queue)" = 8 ]; echo $?)

# 3. A closed pull request leaves too.
reset; seed 7 8; echo CLOSED > "$root/state/7"; mt wait "$U/8"
check "3 a closed one leaves" $([ "$rc" -eq 0 ] && [ "$(queue)" = 8 ]; echo $?)

# 4. First come, first merged: arrival order, the list prints it.
reset; seed 7; bg 8; poll '[ "$(queue)" = "7 8" ]'; bg 9; poll '[ "$(queue)" = "7 8 9" ]'
mt list
check "4 list in arrival order" $([ "$rc" -eq 0 ] && [ "$(echo "$out" | sed 's#.*/##' | tr '\n' ' ')" = "7 8 9 " ]; echo $?)

# 5. The delegator's order: first <pr>... gives those the next turns, in that order; 7 holds the turn and keeps it.
mt first "$U/9" "$U/8"
check "5 first reorders behind the turn's holder" $([ "$rc" -eq 0 ] && [ "$(queue)" = "7 9 8" ]; echo $?)
echo MERGED > "$root/state/7"; settle "$root/rc.9"
check "5 9 gets the turn, not 8" $([ "$(cat "$root/rc.9" 2>/dev/null)" = 0 ] && [ ! -e "$root/rc.8" ]; echo $?)
mt first "$U/5"
check "5 a pull request not queued is refused" $([ "$rc" -eq 1 ] && [ "$(queue)" = "9 8" ]; echo $?)

# 6. drop: a run's pull request that will not merge leaves the queue; the next one gets the turn.
mt drop "$U/9"
check "6 dropped" $([ "$rc" -eq 0 ] && [ "$(queue)" = 8 ]; echo $?)
settle "$root/rc.8"
check "6 8 gets the turn" $([ "$(cat "$root/rc.8" 2>/dev/null)" = 0 ]; echo $?)
mt drop "$U/9"
check "6 dropping one not queued is refused" $([ "$rc" -eq 1 ]; echo $?)

# 7. At its turn, a pull request behind its base: exit 3 and a JSON line, still first in the queue.
reset; seed 7; echo 2 > "$root/behind/7"; echo src/App.java > "$root/basefiles/7"; mt wait "$U/7"
check "7 behind exits 3" $([ "$rc" -eq 3 ]; echo $?)
check "7 behind JSON with the head" $(echo "$out" | grep -q '"state":"behind","sha":"head7"'; echo $?)
check "7 the detail says how far" $(echo "$out" | grep -q '2 commit(s) behind main'; echo $?)
check "7 keeps the turn" $([ "$(queue)" = 7 ]; echo $?)

# 8. Its own pull request merged meanwhile (by someone else): the turn ends, exit 0.
reset; seed 7; echo MERGED > "$root/state/7"; mt wait "$U/7"
check "8 merged: exit 0, gone from the queue" $([ "$rc" -eq 0 ] && [ -z "$(queue)" ]; echo $?)

# 11. At its turn, behind only by commits that change backlog/ files the pull request does not touch (a ticket close-out,
# the delegator's ticket commit): not behind, the turn is its own (TASK-73).
reset; seed 7; echo 2 > "$root/behind/7"
printf 'backlog/tasks/task-4.2 - x.md\nbacklog/tasks/task-69 - y.md\n' > "$root/basefiles/7"
printf '.archon/scripts/open-pr.sh\nbacklog/tasks/task-70 - z.md\n' > "$root/prfiles/7"
mt wait "$U/7"
check "11 backlog-only behind: exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "11 nothing on stdout" $([ -z "$out" ]; echo $?)
check "11 says the backlog commits do not count" $(grep -q "only exempt files" <<<"$err"; echo $?)
check "11 keeps the turn" $([ "$(queue)" = 7 ]; echo $?)

# 12. Any missing main change outside backlog/ still answers behind.
reset; seed 7; echo 2 > "$root/behind/7"
printf 'backlog/tasks/task-4.2 - x.md\ndocs/memory.md\n' > "$root/basefiles/7"
echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
mt wait "$U/7"
check "12 a change outside backlog/: behind, exit 3" $([ "$rc" -eq 3 ] && echo "$out" | grep -q '"state":"behind"'; echo $?)

# 13. A missing backlog/ change to a file the pull request also changes still answers behind.
reset; seed 7; echo 1 > "$root/behind/7"
echo 'backlog/tasks/task-70 - z.md' > "$root/basefiles/7"
printf '.archon/scripts/open-pr.sh\nbacklog/tasks/task-70 - z.md\n' > "$root/prfiles/7"
mt wait "$U/7"
check "13 a backlog/ file the pull request also changes: behind, exit 3" $([ "$rc" -eq 3 ] && echo "$out" | grep -q '"state":"behind"'; echo $?)

# 14. A file renamed into backlog/ from outside it is a change outside backlog/.
reset; seed 7; echo 1 > "$root/behind/7"
echo 'docs/notes.md -> backlog/docs/notes.md' > "$root/basefiles/7"
mt wait "$U/7"
check "14 a rename from outside backlog/: behind, exit 3" $([ "$rc" -eq 3 ]; echo $?)

# 15. GitHub lists at most 300 files of a compare: a full list may hide a change outside backlog/, so it is behind.
reset; seed 7; echo 1 > "$root/behind/7"
for i in $(seq 1 300); do echo "backlog/tasks/task-$i.md"; done > "$root/basefiles/7"
mt wait "$U/7"
check "15 a compare of 300 files: behind, exit 3" $([ "$rc" -eq 3 ]; echo $?)

# 17. D7 staged: once rebase-behind.sh --policy prints behind-means-rebase (reuse is live), only the paths that run no
# CI stay exempt (ci-skip.sh: backlog/, docs/retro/, docs/tokenomics/; owner decisions 2026-10-22, 2026-10-23); a
# change under any other path beside them is behind.
reset; seed 7; echo 2 > "$root/behind/7"; : > "$root/gh.log"; : > "$root/policy.log"
printf 'backlog/tasks/task-4.2 - x.md\nbacklog/tasks/task-69 - y.md\n' > "$root/basefiles/7"
echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
POLICY=behind-means-rebase mt wait "$U/7"
check "17 behind-means-rebase: backlog-only behind is not behind, exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "17 the policy was asked" $(grep -qx -- --policy "$root/policy.log"; echo $?)
check "17 says only the paths that run no CI stay exempt" $(grep -q "only backlog/ docs/retro/ docs/tokenomics/ stay exempt" <<<"$err"; echo $?)
reset; seed 7; echo 2 > "$root/behind/7"
printf 'docs/retro/TASK-9/lessons-learned.md\ndocs/tokenomics/daily-token-reports/2026-10-22.md\n' > "$root/basefiles/7"
echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
POLICY=behind-means-rebase mt wait "$U/7"
check "17 behind-means-rebase: behind only by a retro and the token reports is not behind, exit 0" $([ "$rc" -eq 0 ] \
  && grep -q "exempt files (backlog/ docs/retro/ docs/tokenomics/)" <<<"$err"; echo $?)
reset; seed 7; echo 2 > "$root/behind/7"
printf 'docs/retro/TASK-9/lessons-learned.md\nbacklog/tasks/task-69 - y.md\n' > "$root/basefiles/7"
echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
POLICY=behind-means-rebase mt wait "$U/7"
check "17 behind-means-rebase: a retro beside a ticket commit is not behind, exit 0" $([ "$rc" -eq 0 ]; echo $?)
reset; seed 7; echo 2 > "$root/behind/7"
printf 'backlog/tasks/task-69 - y.md\nsrc/App.java\n' > "$root/basefiles/7"
echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
POLICY=behind-means-rebase mt wait "$U/7"
check "17 behind-means-rebase: a ticket beside a code change is behind, exit 3" $([ "$rc" -eq 3 ]; echo $?)
# Any other answer, or a policy call that fails, keeps the exemption (the staged default).
for pol in task-73 garbage; do
  reset; seed 7; echo 2 > "$root/behind/7"
  printf 'backlog/tasks/task-4.2 - x.md\n' > "$root/basefiles/7"; echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
  POLICY=$pol mt wait "$U/7"
  check "17 policy $pol: the exemption holds, exit 0" $([ "$rc" -eq 0 ] && grep -q "exempt files" <<<"$err"; echo $?)
done
reset; seed 7; echo 2 > "$root/behind/7"
printf 'backlog/tasks/task-4.2 - x.md\n' > "$root/basefiles/7"; echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
REBASE_BEHIND=/nonexistent/rebase-behind.sh mt wait "$U/7"
check "17 the policy cannot be asked: the exemption holds, exit 0" $([ "$rc" -eq 0 ]; echo $?)

# 18. The exempt paths are push-guard.sh's list (owner decision 2026-10-20, D14): a retro or a token report commit on
# main does not make a pull request behind either; a look-alike folder or a mix with another path still does.
reset; seed 7; echo 2 > "$root/behind/7"
printf 'docs/retro/TASK-1/lessons-learned.md\ndocs/retro/README.md\ndocs/tokenomics/ledger/day.json\nbacklog/tasks/t.md\n' > "$root/basefiles/7"
echo src/App.java > "$root/prfiles/7"
mt wait "$U/7"
check "18 docs/retro/ and docs/tokenomics/ commits: not behind" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)
reset; seed 7; echo 1 > "$root/behind/7"; echo docs/retro-evil/a.md > "$root/basefiles/7"
mt wait "$U/7"
check "18 a look-alike folder (docs/retro-evil/): behind" $([ "$rc" -eq 3 ]; echo $?)
reset; seed 7; echo 1 > "$root/behind/7"; printf 'docs/tokenomics/a.json\ndocs/memory.md\n' > "$root/basefiles/7"
mt wait "$U/7"
check "18 docs/tokenomics/ mixed with another path: behind" $([ "$rc" -eq 3 ]; echo $?)
reset; seed 7; echo 1 > "$root/behind/7"; echo docs/retro/x.md > "$root/basefiles/7"; echo docs/retro/x.md > "$root/prfiles/7"
mt wait "$U/7"
check "18 an exempt file the pull request also changes: behind" $([ "$rc" -eq 3 ]; echo $?)
check "18 one list: merge-turn reads push-guard.sh paths" $(grep -q 'push-guard.sh' "$script" && grep -q '"$push_guard" paths' "$script"; echo $?)

# 16. Up to date: the file lists are not asked for.
reset; seed 7; : > "$root/gh.log"; mt wait "$U/7"
check "16 up to date: exit 0, main's changes not asked for" $([ "$rc" -eq 0 ] && ! grep -q 'compare/head7' "$root/gh.log"; echo $?)

# 21. A compare larger than one argument may be (TASK-75, PR #180): it is read from a file, so the answer is the same
# as for a small compare and never "Argument list too long".
reset; seed 7; touch "$root/big/7"; mt wait "$U/7"
check "21a large up-to-date compare: exit 0, nothing on stdout" $([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)
check "21a no 'Argument list too long'" $(! grep -q 'Argument list too long' <<<"$err"; echo $?)
reset; seed 7; touch "$root/big/7"; echo 2 > "$root/behind/7"
echo 'backlog/tasks/task-4.2 - x.md' > "$root/basefiles/7"; echo .archon/scripts/open-pr.sh > "$root/prfiles/7"
mt wait "$U/7"
check "21b large compare, backlog-only behind: exit 0" $([ "$rc" -eq 0 ] && grep -q "only exempt files" <<<"$err"; echo $?)
reset; seed 7; touch "$root/big/7"; echo 2 > "$root/behind/7"; echo src/App.java > "$root/basefiles/7"
mt wait "$U/7"
check "21c large compare, behind: exit 3 and how far" $([ "$rc" -eq 3 ] && echo "$out" | grep -q '"state":"behind"' && echo "$out" | grep -q '2 commit(s) behind main'; echo $?)
reset; touch "$root/big/20"; echo "\"base_commit\": {\"sha\": \"1111111111111111111111111111111111111111\"}," > "$root/tip.json"
TIP_STATE=none mt wait "$U/20"
check "21d large compare: the tip is still read" $(grep -qx "o/repo 1111111111111111111111111111111111111111" "$root/status.log"; echo $?)

# 22. An unreadable compare fails safe and says why: no stack trace, no silent fallback.
reset; seed 7; touch "$root/badjson/7"; mt wait "$U/7"
check "22a main...head not JSON: exit 1 with the reason" $([ "$rc" -eq 1 ] && grep -q 'cannot read the compare' <<<"$err" && ! grep -q 'at JSON.parse' <<<"$err"; echo $?)
reset; seed 7; touch "$root/badbehind/7"; mt wait "$U/7"
check "22b no behind_by: exit 1 naming it" $([ "$rc" -eq 1 ] && grep -q 'behind_by' <<<"$err" && ! grep -q 'at JSON.parse' <<<"$err"; echo $?)
reset; seed 7; touch "$root/failbase/7"; echo 2 > "$root/behind/7"; echo 'backlog/tasks/task-4.2 - x.md' > "$root/basefiles/7"
mt wait "$U/7"
check "22c head...main cannot be fetched: behind, with the reason" $([ "$rc" -eq 3 ] && echo "$out" | grep -q '"state":"behind"' && grep -q 'cannot read' <<<"$err" && ! grep -q 'at JSON.parse' <<<"$err"; echo $?)
reset; seed 7; touch "$root/badbase/7"; echo 2 > "$root/behind/7"; echo 'backlog/tasks/task-4.2 - x.md' > "$root/basefiles/7"
mt wait "$U/7"
check "22d head...main not JSON: behind, with the reason" $([ "$rc" -eq 3 ] && grep -q 'cannot read' <<<"$err" && ! grep -q 'at JSON.parse' <<<"$err"; echo $?)
reset; seed 7; echo -1 > "$root/behind/7"; mt wait "$U/7"
check "22e a negative behind_by: exit 1 naming it" $([ "$rc" -eq 1 ] && grep -q 'behind_by' <<<"$err"; echo $?)

# 23. The compare files leave no trace: the temp folder is gone after a turn given, a behind answer and an unreadable
# compare.
mkdir -p "$root/tmp"
reset; seed 7; touch "$root/big/7"; TMPDIR="$root/tmp" mt wait "$U/7"
check "23 turn given: no temp files left" $([ "$rc" -eq 0 ] && [ -z "$(ls -A "$root/tmp")" ]; echo $?)
reset; seed 7; echo 2 > "$root/behind/7"; echo src/App.java > "$root/basefiles/7"; TMPDIR="$root/tmp" mt wait "$U/7"
check "23 behind: no temp files left" $([ "$rc" -eq 3 ] && [ -z "$(ls -A "$root/tmp")" ]; echo $?)
reset; seed 7; touch "$root/badjson/7"; TMPDIR="$root/tmp" mt wait "$U/7"
check "23 unreadable: no temp files left" $([ "$rc" -eq 1 ] && [ -z "$(ls -A "$root/tmp")" ]; echo $?)

# 9. Usage.
mt wait not-a-url; check "9 not a pull request url" $([ "$rc" -eq 2 ]; echo $?)
mt frobnicate; check "9 unknown command" $([ "$rc" -eq 2 ]; echo $?)
mt first; check "9 first needs a pull request" $([ "$rc" -eq 2 ]; echo $?)

# 10. build-feature's merge gate takes the turn before its local CI and the merge, and a behind answer goes to its
# GitHub agent like a conflict.
wf="$(dirname "$script")/../workflows/build-feature.yaml"
gate=$(yq '.nodes[] | select(.id == "auto-merge") | .loop_group.nodes[] | select(.id == "gate") | .bash' "$wf")
order=$(grep -noE 'merge-turn\.sh wait|local-ci-run\.sh|auto-merge\.sh' <<<"$gate" | sed 's/^[0-9]*://' | tr '\n' ,)
check "10 the gate waits for its turn, then runs CI, then merges" $([ "$order" = "merge-turn.sh wait,local-ci-run.sh,auto-merge.sh," ]; echo $?)
check "10 behind is a gate state" $(yq '.nodes[] | select(.id == "auto-merge") | .loop_group.nodes[] | select(.id == "gate") | .output_format.properties.state.enum[]' "$wf" | grep -qx behind; echo $?)
check "10 the GitHub agent takes a behind answer" $(yq '.nodes[] | select(.id == "auto-merge") | .loop_group.nodes[] | select(.id == "github-agent") | .when' "$wf" | grep -q "'behind'"; echo $?)

# 20. At its turn, main's tip without a verdict gets local CI started on it first (D9; a wait that polls twice under
# load may start it twice, which local-ci-run.sh ignores); a green tip is left alone, a red
# one is said; none of it changes the answer.
TIP=1111111111111111111111111111111111111111
for st in none stale green red; do
  reset; echo "\"base_commit\": {\"sha\": \"$TIP\"}," > "$root/tip.json"
  TIP_STATE=$st mt wait "$U/20"
  check "20 $st: the turn is given" $([ "$rc" -eq 0 ]; echo $?)
  check "20 $st: the tip is asked in the repo" $(grep -qx "o/repo $TIP" "$root/status.log"; echo $?)
  case $st in
    none|stale) check "20 $st: CI started on the tip" $([ "$(sort -u "$root/run-ci.log")" = "$TIP --no-wait" ] && echo "$err" | grep -q "started on it first"; echo $?) ;;
    green) check "20 green: nothing started" $([ ! -s "$root/run-ci.log" ]; echo $?) ;;
    red) check "20 red: said, nothing started" $([ ! -s "$root/run-ci.log" ] && echo "$err" | grep -q "red main"; echo $?) ;;
  esac
done
reset; echo "\"base_commit\": {\"sha\": \"$TIP\"}," > "$root/tip.json"
TIP_STATE=none RUN_RC=1 mt wait "$U/20"
check "20 a failed start is a warning only" $([ "$rc" -eq 0 ] && echo "$err" | grep -q "did not start"; echo $?)
reset; mt wait "$U/20"
check "20 no tip in the compare: nothing asked" $([ "$rc" -eq 0 ] && [ ! -s "$root/status.log" ]; echo $?)

echo "merge-turn tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
