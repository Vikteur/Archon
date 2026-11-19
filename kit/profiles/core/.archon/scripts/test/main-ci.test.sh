#!/usr/bin/env bash
# Tests for build-feature's main-ci node (TASK-72), CI plan C13: its own bash, read from the workflow, run in a throwaway repo whose
# .archon/scripts holds main-ci.sh and stubs of local-ci-run.sh, ci-by-sha.sh and red-triage.sh.
# Usage: bash .archon/scripts/test/main-ci.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$here/../workflows/build-feature.yaml"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
node_bash=$(yq '.nodes[] | select(.id == "main-ci") | .bash' "$wf")

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}

# repo <name>: a fresh repo with one commit on main, the scripts under test and the stubs. local-ci-run.sh logs its
# argument and exits RUN_RC (default 0); ci-by-sha.sh logs its arguments, answers the state in $CI_STATES/<sha> (none
# when missing) and, with --check, exits 1 unless green; it fails for a sha in $CI_FAILS. red-triage.sh logs its
# arguments and answers TRIAGE (default own): green also turns the sha green, as its rerun would; TRIAGE_RC is its exit.
repo() {
  r="$root/$1"; mkdir -p "$r/.archon/scripts" "$r/src" "$r/backlog/tasks"
  git -C "$r" init -q -b main; git -C "$r" config user.name t; git -C "$r" config user.email t@t
  [ -f "$here/main-ci.sh" ] && cp "$here/main-ci.sh" "$r/.archon/scripts/"
  cat > "$r/.archon/scripts/local-ci-run.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RUN_LOG"
exit "${RUN_RC:-0}"
STUB
  cat > "$r/.archon/scripts/ci-by-sha.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RUN_LOG.ci"
c=""; [ "$1" = --check ] && { c=1; shift; }
case " ${CI_FAILS:-} " in *" $1 "*) echo "gh: no answer" >&2; exit 1 ;; esac
s=$(cat "$CI_STATES/$1" 2>/dev/null || echo none)
echo "{\"state\": \"$s\", \"sha\": \"$1\", \"detail\": \"stub CI of $1\"}"
[ -z "$c" ] || [ "$s" = green ]
STUB
  cat > "$r/.archon/scripts/red-triage.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RUN_LOG.triage"
sha=${*: -1}; c=${TRIAGE:-own}
[ "$c" = green ] && echo green > "$CI_STATES/$sha"
echo "{\"class\": \"$c\", \"sha\": \"$sha\", \"rerun\": \"none\", \"jobs\": \"\", \"detail\": \"stub\"}"
exit "${TRIAGE_RC:-0}"
STUB
  echo one > "$r/src/App.java"; git -C "$r" add -A; git -C "$r" commit -qm init
  mkdir -p "$r.states"; : > "$r.run.log"; : > "$r.run.log.ci"; : > "$r.run.log.triage"
}
branch() { # branch: a pull request branch with one commit; sets head
  git -C "$r" checkout -qb feat; echo two > "$r/src/App.java"; git -C "$r" commit -qam feat
  head=$(git -C "$r" rev-parse HEAD); git -C "$r" checkout -q main
}
on_main() { # on_main <path>: a commit on main the pull request lacks
  mkdir -p "$r/$(dirname "$1")"; echo "$RANDOM" > "$r/$1"; git -C "$r" add -A; git -C "$r" commit -qm "main: $1"
}
merge_it() { git -C "$r" merge -q --no-ff -m merge feat; merge=$(git -C "$r" rev-parse HEAD); }
green() { echo green > "$r.states/$1"; }
main_ci() { # main_ci: run the node's bash; sets out (stdout), err, rc, ran (local-ci-run.sh arguments)
  local b=${node_bash//\$merged.output.merge/$merge}; b=${b//\$merged.output.head/$head}
  out=$(cd "$r" && RUN_LOG="$r.run.log" CI_STATES="$r.states" CI_FAILS="${CI_FAILS:-}" RUN_RC="${RUN_RC:-0}" \
    TRIAGE="${TRIAGE:-}" TRIAGE_RC="${TRIAGE_RC:-0}" bash -c "$b" 2> "$root/err"); rc=$?
  err=$(cat "$root/err"); ran=$(cat "$r.run.log"); asked=$(cat "$r.run.log.ci"); triaged=$(cat "$r.run.log.triage")
}
field() { node -e 'console.log(JSON.parse(process.argv[1])[process.argv[2]])' "$out" "$1" 2>/dev/null; }

# 1. The merge commit has the head's tree (the pull request was up to date) and the head is green: the merge commit
# still gets its own local CI run and its own statuses (CI plan C13); the head's result is never answered for it.
repo one; branch; merge_it; green "$head"; green "$merge"; main_ci
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 green" $([ "$(field state)" = green ]; echo $?)
check "1 the answer is for the merge commit" $([ "$(field sha)" = "$merge" ]; echo $?)
check "1 local CI runs on the merge commit" $([ "$ran" = "$merge" ]; echo $?)
check "1 the head is not asked: its result is not reused" $(! grep -q "$head" "$r.run.log.ci"; echo $?)
check "1 the answer is the merge commit's own CI" $(field detail | grep -q "stub CI of $merge"; echo $?)

# 1b. Same tree, green head, but no statuses on the merge commit: none, and the node stops (no green from the head).
repo oneb; branch; merge_it; green "$head"; main_ci
check "1b no own statuses: none, exit 1" $([ "$(field state)" = none ] && [ "$rc" -ne 0 ]; echo $?)

# 2. The trees differ (merged while behind main by a code change): local CI runs on the merge commit as before.
repo two; branch; on_main src/Other.java; merge_it; green "$head"; green "$merge"; main_ci
check "2 local CI runs on the merge commit" $([ "$ran" = "$merge" ]; echo $?)
check "2 the answer is the merge commit's own CI" $([ "$(field sha)" = "$merge" ] && field detail | grep -q "stub CI of $merge"; echo $?)

# 2b. Behind only by backlog/ commits (merge-turn lets it merge, TASK-73): the trees differ, and the groma job reads
# backlog/, so the head's result is not reused.
repo twob; branch; on_main "backlog/tasks/task-9 - x.md"; merge_it; green "$head"; main_ci
check "2b backlog-only difference: local CI runs on the merge commit" $([ "$ran" = "$merge" ]; echo $?)

# 3. Same tree, but the head is red: local CI runs on the merge commit (fails closed).
repo three; branch; merge_it; echo red > "$r.states/$head"; main_ci
check "3 a red head: local CI runs on the merge commit" $([ "$ran" = "$merge" ]; echo $?)
check "3 the answer is the merge commit's own CI" $([ "$(field sha)" = "$merge" ] && [ "$(field state)" = none ]; echo $?)
check "3 the node stops: a merge commit without green CI exits 1" $([ "$rc" -ne 0 ]; echo $?)
check "3 the merge commit is asked, and the node decides on its answer" $(grep -qx -- "$merge" "$r.run.log.ci"; echo $?)

# 3b. Same tree, but the head's result cannot be read: local CI runs on the merge commit.
repo threeb; branch; merge_it; green "$head"; CI_FAILS="$head" main_ci
check "3b an unreadable head result: local CI runs on the merge commit" $([ "$ran" = "$merge" ]; echo $?)

# 3c. No head SHA (an older run's node output): local CI runs on the merge commit.
repo threec; branch; merge_it; green "$head"; head="" main_ci
check "3c no head: local CI runs on the merge commit" $([ "$ran" = "$merge" ]; echo $?)

# 2c. The merge commit's own CI is green: the node goes on.
repo twoc; branch; on_main src/Other.java; merge_it; green "$merge"; main_ci
check "2c a green merge commit exits 0" $([ "$rc" -eq 0 ] && [ "$(field state)" = green ]; echo $?)

# 2d. The merge commit's own CI is red: the node stops.
repo twod; branch; on_main src/Other.java; merge_it; echo red > "$r.states/$merge"; main_ci
check "2d a red merge commit exits 1" $([ "$rc" -ne 0 ] && [ "$(field state)" = red ]; echo $?)
check "2d a red merge commit is triaged against main" $([ "$triaged" = "--base main $merge" ]; echo $?)

# 2e. Red, and red-triage's one rerun of a flaky or infra red turns it green (TASK-6.6): the node goes on, with the
# merge commit's CI asked again.
repo twoe; branch; on_main src/Other.java; merge_it; echo red > "$r.states/$merge"; TRIAGE=green main_ci
check "2e a red turned green by red-triage's rerun exits 0" $([ "$rc" -eq 0 ] && [ "$(field state)" = green ]; echo $?)
check "2e the merge commit's CI is asked again after the triage" $([ "$(grep -c "$merge" "$r.run.log.ci")" -eq 2 ]; echo $?)

# 2f. Red, and red-triage cannot triage it or finds it the merge's own: red stays, the node stops.
repo twof; branch; on_main src/Other.java; merge_it; echo red > "$r.states/$merge"; TRIAGE_RC=1 main_ci
check "2f an untriaged red exits 1, red" $([ "$rc" -ne 0 ] && [ "$(field state)" = red ]; echo $?)
repo twog; branch; on_main src/Other.java; merge_it; echo red > "$r.states/$merge"; TRIAGE=infra TRIAGE_RC=3 main_ci
check "2g an infra red still red after its rerun exits 1" $([ "$rc" -ne 0 ] && [ "$(field state)" = red ]; echo $?)

# 2h. Green or none is never triaged: red-triage reruns only a red.
check "2h a green merge commit is not triaged" $(repo twoh; branch; on_main src/Other.java; merge_it; green "$merge"; main_ci; [ -z "$triaged" ]; echo $?)

# 4. local-ci-run.sh cannot run local CI on the merge commit: none at once, loudly, without asking ci-by-sha.sh about
# the merge commit (it would wait the whole grace for a status that never comes), and the node stops.
repo four; branch; on_main src/Other.java; merge_it; RUN_RC=1 main_ci
check "4 runner failure: none" $([ "$(field state)" = none ] && [ "$(field sha)" = "$merge" ]; echo $?)
check "4 the detail names the runner's exit" $(field detail | grep -q "local-ci-run.sh exit 1"; echo $?)
check "4 ci-by-sha not asked about the merge commit" $(! grep -q "$merge" "$r.run.log.ci"; echo $?)
check "4 the node stops" $([ "$rc" -ne 0 ]; echo $?)

# 5. The script without --check (a caller that reads the JSON) still exits 0 on none and on red.
repo five; branch; on_main src/Other.java; merge_it
out=$(cd "$r" && RUN_LOG="$r.run.log" CI_STATES="$r.states" RUN_RC=1 bash .archon/scripts/main-ci.sh "$merge" "$head" 2>/dev/null); rc=$?
check "5 without --check a runner failure is none, exit 0" $([ "$rc" -eq 0 ] && [ "$(field state)" = none ]; echo $?)
echo red > "$r.states/$merge"
out=$(cd "$r" && RUN_LOG="$r.run.log" CI_STATES="$r.states" bash .archon/scripts/main-ci.sh "$merge" "$head" 2>/dev/null); rc=$?
check "5 without --check red is exit 0" $([ "$rc" -eq 0 ] && [ "$(field state)" = red ]; echo $?)

echo "main-ci tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
