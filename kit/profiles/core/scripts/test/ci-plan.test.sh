#!/usr/bin/env bash
# Tests for .claude/scripts/ci-plan.sh against a throwaway repo and ledger: which jobs run, which may reuse, and what
# the audit reports. Also checks .github/ci-inputs.yml of this repo against its ci.yml, and that the target rule has one copy.
# Usage: bash scripts/test/ci-plan.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script=$here/.claude/scripts/ci-plan.sh
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export CI_LOCAL_ROOT=$root/ci CI_LEDGER=$root/ci/ledger.jsonl CI_PLAN_RUNNER=runner-1 CI_PLAN_SALT=salt-1 \
  CI_PLAN_CONTRACT_COMMIT=1111111111111111111111111111111111111111 CI_PLAN_BASE_IMAGES="eclipse-temurin:26 sha256:aa" \
  CI_PLAN_NOW=1792500000 CI_PLAN_MUTATION_BASE=main
unset CI_SCOPE CI_REUSE CI_PLAN_SCOPE_FILE CI_PLAN_SALT_FILE CI_PLAN_MAX_AGE
mkdir -p "$CI_LOCAL_ROOT"; : > "$CI_LEDGER"

check() { # check <name> <got> <want>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: got '$2', want '$3'"; fi
}

# The repo: the five jobs, this repo's manifest, a Gradle-ish tree, bookkeeping folders, a Docker context.
r=$root/repo
mkdir -p "$r/.github/workflows" "$r/.claude/scripts" "$r/scripts/test" "$r/app/src/main/java/x" "$r/app/src/test/java/x" \
  "$r/foo-domain/src/main/java/x" "$r/backlog/tasks" "$r/docs/retro" "$r/docs/tokenomics/daily-token-reports" "$r/config"
cat > "$r/.github/workflows/ci.yml" <<'YML'
jobs:
  test:
    steps:
      - run: ./gradlew build && bash scripts/test/unit.test.sh
  mutation:
    steps:
      - run: bash .claude/scripts/mutation-gate.sh
  image:
    steps:
      - run: bash scripts/test/image.test.sh
  archon-scripts:
    steps:
      - run: bash scripts/test/unit.test.sh
  groma:
    steps:
      - run: bash .claude/scripts/groma-check.sh
YML
cp "$here/.github/ci-inputs.yml" "$r/.github/ci-inputs.yml"
cp "$script" "$r/.claude/scripts/ci-plan.sh"
echo 'echo unit; cat config/settings.txt' > "$r/scripts/test/unit.test.sh"
echo 'docker build .' > "$r/scripts/test/image.test.sh"
cp "$here/.claude/scripts/mutation-gate.sh" "$r/.claude/scripts/mutation-gate.sh"
echo 'echo groma' > "$r/.claude/scripts/groma-check.sh"
echo 'a=1' > "$r/config/settings.txt"
printf '@@KIT_CONTRACT_TAG_KEY@@=v1.0.0\n' > "$r/gradle.properties"
echo 'echo gradle' > "$r/gradlew"
echo 'include("app")' > "$r/settings.gradle.kts"
echo 'plugins {}' > "$r/app/build.gradle.kts"
printf 'FROM eclipse-temurin:26 AS build\nCOPY . .\n' > "$r/Dockerfile"
printf '*\n!gradlew\n!settings.gradle.kts\n!*/build.gradle.kts\n!*/src/main/\nbuild/\n' > "$r/.dockerignore"
echo 'class A {}' > "$r/app/src/main/java/x/A.java"
echo 'class ATest {}' > "$r/app/src/test/java/x/ATest.java"
echo 'class Y {}' > "$r/foo-domain/src/main/java/x/Y.java"
echo 'task' > "$r/backlog/tasks/task-1.md"
echo 'retro' > "$r/docs/retro/r1.md"
echo 'report' > "$r/docs/tokenomics/daily-token-reports/d1.md"
echo 'memory' > "$r/docs/memory.md"
git -C "$r" init -q -b main && git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm init
c0=$(git -C "$r" rev-parse HEAD)

# commit <msg> <path> <content> [<path> <content>...]: a commit on the current branch; prints its sha.
commit() {
  local m=$1; shift
  while [ $# -gt 1 ]; do mkdir -p "$r/$(dirname "$1")"; printf '%s\n' "$2" > "$r/$1"; git -C "$r" add -- "$1"; shift 2; done
  git -C "$r" -c user.name=t -c user.email=t@t commit -qm "$m" --allow-empty
  git -C "$r" rev-parse HEAD
}
plan() { bash "$script" "$r" "$@" 2>"$root/err"; }
line() { printf '%s\n' "$2" | awk -v j="$1" '$1 == j { $1 = ""; sub(/^ /, ""); print }'; }
fp() { line "$1" "$2" | sed -nE 's/.*fp=([0-9a-f-]+).*/\1/p'; }
decision() { line "$1" "$2" | cut -d' ' -f1; }
green() { # green <sha> <job> <fp> [extra jq object]
  jq -nc --arg sha "$1" --arg job "$2" --arg fp "$3" --argjson ts "$CI_PLAN_NOW" --argjson x "${4:-{\}}" \
    '{event: "verdict", ts: ($ts - 3600), sha: $sha, job: $job, status: "success", fp: $fp, decision: "ran"} + $x' \
    >> "$CI_LEDGER"
}

# --- the plan's shape ---------------------------------------------------------------------------------------------
out=$(plan "$c0")
check "a header line" "$(printf '%s\n' "$out" | head -n 1 | cut -d' ' -f1-2)" "# ci-plan"
check "one line per ci.yml job, in its order" "$(printf '%s\n' "$out" | sed 1d | cut -d' ' -f1 | sort | tr '\n' ' ')" \
  "archon-scripts groma image mutation test "
check "every job has a fingerprint" "$(printf '%s\n' "$out" | sed 1d | grep -cE ' fp=[0-9a-f]{64}$')" 5
check "an empty ledger reuses nothing" "$(printf '%s\n' "$out" | sed 1d | cut -d' ' -f2 | sort -u)" run
check "the plan is deterministic" "$(plan "$c0")" "$out"
check "the reason goes to stderr" "$(grep -c 'test: run, no green run' "$root/err")" 1
mv "$CI_LEDGER" "$CI_LEDGER.off"
o_nl=$(plan "$c0")
check "no ledger: every job runs, mode all" "$(printf '%s\n' "$o_nl" | head -n 1 | sed 's/.* mode=//')" all
grep -q 'no ledger at' "$root/err"; check "no ledger is named" "$?" 0
mv "$CI_LEDGER.off" "$CI_LEDGER"

# --- which change moves which fingerprint -------------------------------------------------------------------------
c_backlog=$(commit backlog backlog/tasks/task-2.md 'new task' docs/retro/r2.md 'r2' docs/tokenomics/daily-token-reports/d2.md 'd')
o_backlog=$(plan "$c_backlog")
for j in test mutation image; do
  check "a bookkeeping-only change keeps the $j fingerprint" "$(fp $j "$o_backlog")" "$(fp $j "$out")"
done
for j in groma archon-scripts; do
  [ "$(fp $j "$o_backlog")" != "$(fp $j "$out")" ]; check "a bookkeeping change moves $j (never narrowed)" "$?" 0
done
# The test job is the Java side (owner decision 2026-10-23): a pipeline-script change keeps it, docs/memory.md moves it.
c_arch=$(commit archon .archon/scripts/x.sh 'echo x')
o_arch=$(plan "$c_arch")
check "an .archon-only change keeps the test fingerprint" "$(fp test "$o_arch")" "$(fp test "$o_backlog")"
c_mem=$(commit memory docs/memory.md 'memory 1b')
[ "$(fp test "$(plan "$c_mem")")" != "$(fp test "$o_arch")" ]; check "a docs/memory.md change moves test (the tests read it)" "$?" 0
c_leaf=$(commit leaf docs/code-maps/test-data.md 'leaf 1')
# (the source's test-data gate case is left out: it asserts the source's own ci-inputs.yml)
c_test=$(commit src-test app/src/test/java/x/ATest.java 'class ATest { int x; }')
o_test=$(plan "$c_test")
[ "$(fp test "$o_test")" != "$(fp test "$o_backlog")" ]; check "a src/test change moves test" "$?" 0
# The image job's codegen and WireMock suites build every module (2026-10-23): a src/test change moves it too, a
# pipeline-script change does not.
[ "$(fp image "$o_test")" != "$(fp image "$o_backlog")" ]; check "a src/test change moves image (its Gradle suites)" "$?" 0
check "an .archon-only change keeps the image fingerprint" "$(fp image "$o_arch")" "$(fp image "$o_backlog")"
check "a change outside the targets keeps mutation" "$(fp mutation "$o_test")" "$(fp mutation "$o_backlog")"
c_main=$(commit src-main app/src/main/java/x/A.java 'class A { int y; }')
o_main=$(plan "$c_main")
[ "$(fp image "$o_main")" != "$(fp image "$o_test")" ]; check "a src/main change moves image" "$?" 0
c_ci=$(commit ci .github/workflows/ci.yml "$(cat "$r/.github/workflows/ci.yml")
# a comment")
o_ci=$(plan "$c_ci")
check "a ci.yml edit moves every job" "$(for j in test mutation image archon-scripts groma; do [ "$(fp $j "$o_ci")" != "$(fp $j "$o_main")" ] && echo x; done | wc -l | tr -d ' ')" 5
c_man=$(commit manifest .github/ci-inputs.yml "$(cat "$r/.github/ci-inputs.yml")
# a comment")
o_man=$(plan "$c_man")
check "a manifest change moves every job" "$(for j in test mutation image archon-scripts groma; do [ "$(fp $j "$o_man")" != "$(fp $j "$o_ci")" ] && echo x; done | wc -l | tr -d ' ')" 5
c_self=$(commit self .claude/scripts/ci-plan.sh "$(cat "$script")
# changed")
o_self=$(plan "$c_self")
check "a planner change in the tree moves every job" "$(for j in test mutation image archon-scripts groma; do [ "$(fp $j "$o_self")" != "$(fp $j "$o_man")" ] && echo x; done | wc -l | tr -d ' ')" 5
check "another salt moves the fingerprint" "$( [ "$(CI_PLAN_SALT=salt-2 plan "$c_self" | grep '^test ')" != "$(line test "$o_self" | sed 's/^/test /')" ] && echo moved)" moved
check "another runner class moves the fingerprint" "$( [ "$(CI_PLAN_RUNNER=runner-2 plan "$c_self" | grep '^groma ')" != "groma $(line groma "$o_self")" ] && echo moved)" moved
check "another contract commit moves test" "$( [ "$(fp test "$(CI_PLAN_CONTRACT_COMMIT=2222222222222222222222222222222222222222 plan "$c_self")")" != "$(fp test "$o_self")" ] && echo moved)" moved
check "another contract commit keeps groma" "$(fp groma "$(CI_PLAN_CONTRACT_COMMIT=2222222222222222222222222222222222222222 plan "$c_self")")" "$(fp groma "$o_self")"
check "another base image keeps test" "$(fp test "$(CI_PLAN_BASE_IMAGES=other plan "$c_self")")" "$(fp test "$o_self")"
[ "$(fp image "$(CI_PLAN_BASE_IMAGES=other plan "$c_self")")" != "$(fp image "$o_self")" ]
check "another base image moves image" "$?" 0

# An exclusion a reader names is cancelled for that plan.
c_name=$(commit names-backlog config/settings.txt 'dir=backlog/tasks')
o_name=$(plan "$c_name" --explain)
grep -q 'test: exclusion backlog/ cancelled, config/settings.txt names backlog' "$root/err"
check "a reader that names backlog cancels its exclusion" "$?" 0
# test no longer reads backlog/ (2026-10-23), so the proof that a cancelled exclusion counts runs on a whole-tree test.
c_wide=$(commit wide .github/ci-inputs.yml "$(yq '.jobs.test.inputs = ["."]' "$r/.github/ci-inputs.yml")")
o_wide=$(plan "$c_wide")
c_name2=$(commit names-backlog-2 backlog/tasks/task-3.md 'x')
[ "$(fp test "$(plan "$c_name2")")" != "$(fp test "$o_wide")" ]; check "then a backlog change moves test" "$?" 0
commit narrow .github/ci-inputs.yml "$(cat "$here/.github/ci-inputs.yml")" > /dev/null
c_comment=$(commit comment-only config/settings.txt '# the backlog is not read
a=1')
o_comment=$(plan "$c_comment" --explain)
grep -q 'exclusion backlog/ cancelled' "$root/err"; check "a comment line cancels nothing" "$?" 1
# A data file names a folder only in a path shape: a permission rule "Bash(backlog task edit *)" is a command.
c_data=$(commit data-file scripts/test/unit.test.sh 'echo unit; jq . config/perm.json' \
  config/perm.json '{"allow": ["Bash(backlog task edit *)", "Bash(backlog task view *)"]}')
plan "$c_data" --explain > /dev/null
grep -q 'test: exclusion backlog/ cancelled' "$root/err"; check "a data file's command naming backlog cancels nothing" "$?" 1
c_data2=$(commit data-path config/perm.json '{"read": ["backlog/tasks"]}')
plan "$c_data2" --explain > /dev/null
grep -q 'test: exclusion backlog/ cancelled, config/perm.json names backlog' "$root/err"
check "a data file's path backlog/ cancels the exclusion" "$?" 0
c_data3=$(commit data-quoted config/perm.json '{"dir": "backlog"}')
plan "$c_data3" --explain > /dev/null
grep -q 'test: exclusion backlog/ cancelled, config/perm.json names backlog' "$root/err"
check "a data file's quoted backlog cancels the exclusion" "$?" 0
c_data4=$(commit data-code scripts/test/unit.test.sh 'echo unit; ls backlog' config/perm.json '{}')
plan "$c_data4" --explain > /dev/null
grep -q 'test: exclusion backlog/ cancelled, scripts/test/unit.test.sh names backlog' "$root/err"
check "code keeps the word rule: a bare backlog in a script cancels" "$?" 0
c_comment=$(commit restore scripts/test/unit.test.sh 'echo unit; cat config/settings.txt')

# Mutation targets: a domain main class makes Gradle run, so the whole tree counts.
git -C "$r" checkout -q -b feat "$c_comment"
c_dom=$(commit domain foo-domain/src/main/java/x/Y.java 'class Y { int z; }')
o_dom=$(plan "$c_dom" --explain)
grep -q 'mutation: .* targets 1;' "$root/err"; check "a domain main class is a mutation target" "$?" 0
c_dom2=$(commit domain-doc docs/memory.md 'memory 2')
[ "$(fp mutation "$(plan "$c_dom2")")" != "$(fp mutation "$o_dom")" ]; check "with a target, any tree change moves mutation" "$?" 0
check "without a target, docs/ does not move mutation" "$(fp mutation "$(CI_PLAN_MUTATION_BASE=$c_dom plan "$c_dom2")")" \
  "$(fp mutation "$(CI_PLAN_MUTATION_BASE=$c_dom plan "$c_dom")")"
check "no base for the targets: mutation runs without a fingerprint" "$(line mutation "$(CI_PLAN_MUTATION_BASE=nope plan "$c_dom2")")" "run fp=-"
check "the tree's gate lists the targets: a domain test class is none" \
  "$(plan "$(commit dom-test foo-domain/src/test/java/x/YTest.java 'class YTest {}')" --explain > /dev/null; grep -c 'mutation: .* targets 1;' "$root/err")" 1
c_oldgate=$(commit old-gate .claude/scripts/mutation-gate.sh 'echo "FAIL: unknown argument $1"; exit 2')
check "a gate without --list-targets: mutation runs without a fingerprint" "$(line mutation "$(plan "$c_oldgate")")" "run fp=-"
grep -q 'mutation: run, no base for the mutation targets, or .claude/scripts/mutation-gate.sh cannot list them' "$root/err"
check "and says why" "$?" 0
git -C "$r" checkout -q main

# .dockerignore that does not deny by default: the image reads the whole tree.
c_di=$(commit dockerignore .dockerignore 'build/')
o_di=$(plan "$c_di")
c_di2=$(commit dockerignore-2 docs/memory.md 'memory 3')
[ "$(fp image "$(plan "$c_di2")")" != "$(fp image "$o_di")" ]; check "an allow-by-default .dockerignore gives image the whole tree" "$?" 0
c_branch=$(commit branch-pin gradle.properties '@@KIT_CONTRACT_TAG_KEY@@=feature/x')
o_branch=$(plan "$c_branch")
check "a branch pin runs test without a fingerprint" "$(line test "$o_branch")" "run fp=-"
check "a branch pin leaves groma alone" "$(fp groma "$o_branch" | grep -cE '^[0-9a-f]{64}$')" 1
git -C "$r" reset -q --hard "$c_self"

# --- reuse --------------------------------------------------------------------------------------------------------
# c_twin: another commit with the same tree as c_self's child (a merge commit on main, a rerun after an amend).
c_a=$(commit a docs/retro/r3.md 'x')
o_a=$(plan "$c_a")
c_twin=$(git -C "$r" commit-tree "$c_a^{tree}" -p "$c_self" -m twin)
green "$c_a" test "$(fp test "$o_a")"
o_twin=$(plan "$c_twin")
check "shadow (default): a green twin is logged, and the job runs" "$(line test "$o_twin")" "run fp=$(fp test "$o_a") shadow=$c_a"
grep -q "test: run (shadow: would reuse ${c_a:0:12}" "$root/err"; check "shadow logs would reuse" "$?" 0
check "live: the job reuses" "$(line test "$(CI_REUSE=live plan "$c_twin")")" "reuse $c_a fp=$(fp test "$o_a")"
check "live: a job without a green source runs" "$(decision groma "$(CI_REUSE=live plan "$c_twin")")" run
check "an unknown CI_REUSE is shadow" "$(decision test "$(CI_REUSE=yes plan "$c_twin")")" run
touch "$CI_LOCAL_ROOT/reuse-live"
check "the reuse-live file is live" "$(decision test "$(plan "$c_twin")")" reuse
check "CI_REUSE=shadow overrides the reuse-live file" "$(decision test "$(CI_REUSE=shadow plan "$c_twin")")" run
rm "$CI_LOCAL_ROOT/reuse-live"
check "a commit is never its own source" "$(decision test "$(CI_REUSE=live plan "$c_a")")" run
check "--all never reuses" "$(decision test "$(CI_REUSE=live plan "$c_twin" --all)")" run
check "--audit never reuses" "$(decision test "$(CI_REUSE=live plan "$c_twin" --audit)")" run
check "CI_SCOPE=all never reuses" "$(decision test "$(CI_SCOPE=all CI_REUSE=live plan "$c_twin")")" run
touch "$CI_LOCAL_ROOT/scope-all"
check "the scope-all file never reuses" "$(CI_REUSE=live plan "$c_twin" | grep -c reuse)" 0
grep -q 'kill switch scope-all is on' "$root/err"; check "the kill switch is named" "$?" 0
rm "$CI_LOCAL_ROOT/scope-all"
check "a bookkeeping-only child reuses test too" "$(decision test "$(CI_REUSE=live plan "$(commit b backlog/tasks/task-9.md 'y')")")" reuse

# The source's limits: 24 h, newest record of its commit, never a reuse, same runner, a parseable record.
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"ts": 1792400000}'
check "a source older than 24 h is no source" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
check "CI_PLAN_MAX_AGE widens it" "$(decision test "$(CI_PLAN_MAX_AGE=200000 CI_REUSE=live plan "$c_twin")")" reuse
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"ts": "2026-10-20T12:00:00.123Z"}'
check "an ISO time is read" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" reuse
green "$c_a" test "$(fp test "$o_a")" '{"status": "failure", "ts": 1792499000}'
check "a later red of the source wins" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" "{\"source\": \"$c0\"}"
check "a reuse is never a source (no chains)" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"decision": "reused"}'
check "decision reused is never a source" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"runner": "x"}'
check "another runner field is no source" "$(decision test "$(CI_REUSE=live CI_PLAN_RUNNER=x plan "$c_twin")")" run
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"event": "queued"}'
check "only a verdict or end record is a result" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
{ echo 'not json'; echo '{"event":"end","job":"test"'; echo '[1,2]'; } >> "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"event": "end", "ts": 1792499999}'
check "broken lines are skipped, a good end record is a source" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" reuse
green "$c_a" test "$(fp test "$o_a")" '{"sha": "abc"}'
check "a short sha is no source" "$(line test "$(CI_REUSE=live plan "$c_twin")" | cut -d' ' -f2)" "$c_a"
: > "$CI_LEDGER"
jq -nc --arg sha "$c_a" --arg fp "$(fp test "$o_a")" --argjson t "$CI_PLAN_NOW" \
  '{v: 1, ev: "verdict", t: ($t - 60), host: "h", sha: $sha, job: "test", state: "success", status: "success", fp: $fp}' >> "$CI_LEDGER"
check "a ci-ledger.sh verdict (ev, t) is a source" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" reuse
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")" '{"narrowed": true}'
check "a narrowed run is no source" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
: > "$CI_LEDGER"
green "$c_a" test "$(fp test "$o_a")"
jq -nc --arg sha "$c_a" --argjson t "$CI_PLAN_NOW" '{event: "kept", ts: $t, sha: $sha, job: "test", status: "success"}' >> "$CI_LEDGER"
check "a later kept record (a rerun of the reds) leaves the source" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" reuse
rule=$(printf '%s' "$(yq -o=json -I0 '.jobs.test' "$r/.github/ci-inputs.yml")" | sha256sum | cut -d' ' -f1)
jq -nc --arg rule "$rule" '{event: "violation", job: "test", rule: $rule, path: "backlog/x"}' >> "$CI_LEDGER"
check "an audit violation stops the reuse" "$(decision test "$(CI_REUSE=live plan "$c_twin")")" run
grep -q 'test: run, an audit found a read' "$root/err"; check "the violation is named" "$?" 0
: > "$CI_LEDGER"

# --- the merged tree ----------------------------------------------------------------------------------------------
git -C "$r" checkout -q -b pr "$c_a"
c_pr=$(commit pr app/src/test/java/x/BTest.java 'class BTest {}')
git -C "$r" checkout -q main
c_m=$(commit main-moves docs/retro/r4.md 'z')
o_pr=$(plan "$c_pr" --base "$c_m")
check "--base plans the merge of the two" "$(printf '%s\n' "$o_pr" | head -n 1 | sed -E 's/.* tree=([0-9a-f]+) .*/\1/')" \
  "$(git -C "$r" merge-tree --write-tree "$c_m" "$c_pr")"
git -C "$r" checkout -q pr
c_x=$(commit conflict docs/retro/r4.md 'other')
git -C "$r" checkout -q main
o_x=$(plan "$c_x" --base "$c_m")
check "a conflict runs every job without a fingerprint" "$(printf '%s\n' "$o_x" | sed 1d | sort -u | cut -d' ' -f2- | sort -u)" "run fp=-"
check "a conflict still lists every job" "$(printf '%s\n' "$o_x" | sed 1d | wc -l | tr -d ' ')" 5

# --- an invalid manifest ------------------------------------------------------------------------------------------
git -C "$r" checkout -q -b bad "$c_m"
c_bad=$(commit bad-groma .github/ci-inputs.yml "$(yq '.jobs.groma.exclude = ["backlog/"]' "$r/.github/ci-inputs.yml")")
o_bad=$(plan "$c_bad")
check "groma may exclude nothing: every job runs" "$(printf '%s\n' "$o_bad" | sed 1d | cut -d' ' -f2- | sort -u)" "run fp=-"
grep -q 'job groma may exclude nothing' "$root/err"; check "the refusal is named" "$?" 0
git -C "$r" reset -q --hard "$c_m"
c_bad2=$(commit bad-excl .github/ci-inputs.yml "$(yq '.jobs.test.exclude += ["docs/"]' "$r/.github/ci-inputs.yml")")
check "an exclusion outside D3 v1: every job runs" "$(plan "$c_bad2" | sed 1d | cut -d' ' -f2- | sort -u)" "run fp=-"
c_bad3=$(commit bad-yaml .github/ci-inputs.yml 'version: [')
check "a manifest that does not parse: every job runs" "$(plan "$c_bad3" | sed 1d | cut -d' ' -f2- | sort -u)" "run fp=-"
git -C "$r" checkout -q main

# --- the base's copy ----------------------------------------------------------------------------------------------
o_from=$(bash "$script" --self-from "$c_m" "$r" "$c_m" 2>/dev/null)
check "--self-from runs the base's blob" "$(printf '%s\n' "$o_from" | head -n 1 | sed -E 's/.* planner=([0-9a-f]+) .*/\1/')" \
  "$(git -C "$r" rev-parse "$c_m:.claude/scripts/ci-plan.sh")"
check "--self-from names the base" "$(printf '%s\n' "$o_from" | head -n 1 | grep -c " from=$c_m")" 1
git -C "$r" checkout -q -b noplanner "$c0"
git -C "$r" rm -q .claude/scripts/ci-plan.sh && c_np=$(commit no-planner)
git -C "$r" checkout -q main
o_none=$(bash "$script" --self-from "$c_np" "$r" "$c_m" 2>/dev/null)
check "a base without a planner: every job runs" "$(printf '%s\n' "$o_none" | sed 1d | cut -d' ' -f2- | sort -u)" "run fp=-"
check "a base without a planner: every job listed" "$(printf '%s\n' "$o_none" | sed 1d | wc -l | tr -d ' ')" 5

# --- audit --------------------------------------------------------------------------------------------------------
wt=$root/wt
git -C "$r" worktree add -q --detach "$wt" "$c_m"
wtp=$(cd "$wt" && pwd -P)
cat > "$root/trace" <<TRACE
101 openat(AT_FDCWD</x>, "app/src/main/java/x/A.java", O_RDONLY) = 3<$wtp/app/src/main/java/x/A.java>
101 openat(AT_FDCWD</x>, "backlog/tasks/task-1.md", O_RDONLY) = 4<$wtp/backlog/tasks/task-1.md>
101 openat(AT_FDCWD</x>, "docs", O_RDONLY|O_DIRECTORY) = 5<$wtp/docs/retro>
101 openat(AT_FDCWD</x>, "build/x", O_RDONLY) = 6<$wtp/app/build/x.class>
101 openat(AT_FDCWD</x>, "/etc/passwd", O_RDONLY) = 7</etc/passwd>
101 openat(AT_FDCWD</x>, ".git/HEAD", O_RDONLY) = 8<$wtp/.git>
TRACE
a_out=$(CI_PLAN_MUTATION_BASE=HEAD bash "$script" --audit-trace test "$wt" "$root/trace" 2>/dev/null); a_rc=$?
check "audit: a read of an excluded file is a violation" "$(printf '%s\n' "$a_out" | grep -c '^violation test backlog/tasks/task-1.md$')" 1
check "audit: a listed folder outside the inputs is a violation" "$(printf '%s\n' "$a_out" | grep -c '^violation test docs/retro/$')" 1
check "audit: the summary" "$(printf '%s\n' "$a_out" | head -n 1)" "audit test: 2 tracked files read, 2 outside its inputs"
check "audit: exit 1 on a violation" "$a_rc" 1
CI_PLAN_MUTATION_BASE=HEAD bash "$script" --audit-trace groma "$wt" "$root/trace" > /dev/null 2>&1
check "audit: groma reads the whole tree, no violation" "$?" 0
CI_PLAN_MUTATION_BASE=HEAD bash "$script" --audit-trace test "$wt" "$root/trace" --record > /dev/null 2>&1
check "audit --record writes violation lines" "$(jq -r 'select(.event == "violation") | .path' "$CI_LEDGER" | sort | tr '\n' ' ')" \
  "backlog/tasks/task-1.md docs/retro/ "
check "a recorded violation stops the reuse" "$(CI_REUSE=live plan "$c_m" | grep -c '^test reuse')" 0
: > "$CI_LEDGER"
# Without strace the command still runs, with its exit status, and the audit says it did not trace.
mkdir -p "$root/nostrace"
for t in bash git cat dirname mktemp rm sed; do ln -sf "$(command -v "$t")" "$root/nostrace/$t"; done
PATH=$root/nostrace bash "$script" --audit-run test "$wt" -- bash -c 'exit 3' 2> "$root/err"
check "no strace: the command's exit status" "$?" 3
grep -q 'strace not found' "$root/err"; check "no strace: said so" "$?" 0
# The fake strace is not called when this suite runs traced itself (ci-local --audit): audit_run then runs the
# command untraced, the "already traced" case below.
if [ "$(awk '/^TracerPid:/ { print $2 }' /proc/self/status 2> /dev/null)" = 0 ]; then
  # strace ending 1 on its own ptrace error does not fail a command that passed: the command's exit status counts.
  mkdir -p "$root/badstrace"
  cat > "$root/badstrace/strace" <<'SH'
#!/bin/bash
while [ "$1" != -- ]; do [ "$1" = -o ] && { : > "$2"; shift; }; shift; done; shift
"$@"; echo "strace: ptrace(PTRACE_LISTEN,pid:1,sig:0): Input/output error" >&2; exit 1
SH
  chmod +x "$root/badstrace/strace"
  CI_PLAN_MUTATION_BASE=HEAD PATH=$root/badstrace:$PATH bash "$script" --audit-run test "$wt" -- bash -c 'exit 0' 2> "$root/err"
  check "strace ends 1, the command 0: the command's exit status" "$?" 0
  grep -q "strace ended 1, the command 0" "$root/err"; check "strace ends 1, the command 0: said so" "$?" 0
  # strace quitting before the command (its PTRACE_LISTEN race is fatal) does not cut the step short: audit_run waits.
  cat > "$root/badstrace/strace" <<'SH'
#!/bin/bash
while [ "$1" != -- ]; do [ "$1" = -o ] && { : > "$2"; shift; }; shift; done; shift
"$@" & sleep 1; echo "strace: ptrace(PTRACE_LISTEN,pid:1,sig:0): Input/output error" >&2; exit 1
SH
  CI_PLAN_MUTATION_BASE=HEAD PATH=$root/badstrace:$PATH bash "$script" --audit-run test "$wt" -- \
    bash -c 'sleep 3; exit 6' 2> "$root/err"
  check "strace quits first: the command's exit status" "$?" 6
  grep -q "strace ended 1 before the command" "$root/err"; check "strace quits first: said so" "$?" 0
else
  echo "skip: this suite runs traced, the fake strace is not called"
fi
if command -v strace > /dev/null 2>&1 && strace -f -qq -o /dev/null true 2>/dev/null; then
  CI_PLAN_MUTATION_BASE=HEAD bash "$script" --audit-run test "$wt" --report "$root/report" -- cat backlog/tasks/task-1.md > /dev/null 2>&1
  check "strace: the command's exit status" "$?" 0
  check "strace: the excluded read is reported" "$(grep -c '^violation test backlog/tasks/task-1.md$' "$root/report")" 1
  # A process the command leaves running (a Gradle daemon) is stopped when the command ends: strace -f waits for it.
  CI_PLAN_MUTATION_BASE=HEAD timeout 60 bash "$script" --audit-run test "$wt" -- \
    bash -c 'setsid sleep 301 > /dev/null 2>&1 & exit 4' 2> "$root/err"
  check "strace: a process left running does not hold the command, its exit status" "$?" 4
  check "strace: the process left running is stopped and counted" \
    "$(grep -c 'stopped 1 process(es) the command left running' "$root/err")" 1
  # Under an outer trace strace cannot attach: the command runs untraced and the audit says so.
  CI_PLAN_MUTATION_BASE=HEAD timeout 60 strace -f -qq -o /dev/null bash "$script" --audit-run test "$wt" -- \
    bash -c 'exit 5' 2> "$root/err"
  check "already traced: the command's exit status" "$?" 5
  grep -q 'already traced' "$root/err"; check "already traced: said so" "$?" 0
else
  echo "skip: strace cannot trace here"
fi
git -C "$r" worktree remove --force "$wt"

# --- this repo's manifest -----------------------------------------------------------------------------------------
man=$here/.github/ci-inputs.yml
check "the manifest names exactly the ci.yml jobs" "$(yq '.jobs | keys | .[]' "$man" | sort | tr '\n' ' ')" \
  "$(yq '.jobs | keys | .[]' "$here/.github/workflows/ci.yml" | sort | tr '\n' ' ')"
check "groma is the whole tree, excluding nothing" "$(yq -o=json -I0 '[.jobs.groma.inputs, .jobs.groma.exclude]' "$man")" '[["."],null]'
check "test is narrowed to the Java side, not the whole tree" "$(yq '.jobs.test.inputs[]' "$man" | grep -cxE '\.|\.archon/')" 0
check "the planner, manifest and workflow are inputs of every job" \
  "$(yq '.always[]' "$man" | grep -cxE '\.github/ci-inputs\.yml|\.github/workflows/ci\.yml|\.claude/scripts/ci-plan\.sh')" 3
check "the planner keeps no copy of the target rule (it asks mutation-gate.sh --list-targets)" \
  "$(grep -c 'src/main/java' "$script")" 0

echo "ci-plan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
