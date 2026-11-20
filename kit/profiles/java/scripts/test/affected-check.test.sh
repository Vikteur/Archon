#!/usr/bin/env bash
# Tests .claude/scripts/affected-check.sh (owner decision 2026-10-17): from a change against the merge-base with
# origin/main it runs the touched modules' tests and their dependents', integrationTest only for an adapter or
# application change, only the matching shell suite, the CI workflow tests for a workflow change, and nothing for docs;
# it stops at the first failure. Before that it merges origin/main into a branch that is behind (docs/memory.md
# combined by its merge=union driver), refuses a dirty tree while behind, and aborts a real conflict. Each case builds a throwaway clone of a throwaway origin with a stub gradlew and stub
# suites that log what ran, so no real build or suite runs.
# Usage: bash scripts/test/affected-check.test.sh
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/.claude/scripts/affected-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0
failed=0

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
# No automatic gc, maintenance or receive-side gc in the throwaway repos: a background gc racing the next git call was
# the suspected cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset AFFECTED_BASE

out=""
rc=0
log=""

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# Every stub appends its name and arguments to $AFFECTED_LOG; a stub exits with the code in $tmp/rc-<name>, else 0.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$AFFECTED_LOG"\nf="%s/rc-%s"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0\n' \
    "$2" "$tmp" "$2" > "$1"
  chmod +x "$1"
}

# build_template <dir>: a clone of a fresh origin whose main holds a three-module chain (domain <- usecase <- adapter,
# plus application on all and a lone gateway), shell scripts with suites, a workflow and docs; the clone is on branch
# feat. Built once per suite run: new_repo copies it, which is far cheaper than rebuilding it (~2.6 s a case on Git Bash).
build_template() {
  local d="$1"
  git init -q --bare -b main "$d.git"
  git init -q -b main "$d"
  cd "$d" || exit 1
  printf 'include("x-domain", "x-usecase", "x-adapter", "application", "y-gateway")\n' > settings.gradle.kts
  printf 'plugins { java }\n' > build.gradle.kts
  mkdir -p x-domain x-usecase x-adapter application y-gateway
  printf '// testImplementation(testFixtures(project(":x-adapter")))\n' > x-domain/build.gradle.kts
  printf 'dependencies { api(project(":x-domain")) }\n' > x-usecase/build.gradle.kts
  printf 'dependencies { api(project(":x-usecase")) }\n' > x-adapter/build.gradle.kts
  printf 'dependencies { implementation(project(":x-adapter"))\n implementation(project(":y-gateway")) }\n' \
    > application/build.gradle.kts
  printf 'dependencies { }\n' > y-gateway/build.gradle.kts
  for m in x-domain x-usecase x-adapter application y-gateway; do mkdir -p "$m/src"; echo a > "$m/src/A.java"; done
  # Test files: the tag, not the class name, picks the set. DomainIT has no tag, so it is a unit test.
  tagged() { mkdir -p "$(dirname "$1")"; printf '@Tag("%s")\nclass X {}\n' "$2" > "$1"; }
  mkdir -p x-domain/src/test/java && echo 'class DomainIT {}' > x-domain/src/test/java/DomainIT.java
  tagged x-adapter/src/test/java/RepoTest.java integration
  tagged application/src/test/java/BootTest.java integration
  tagged application/src/test/java/RefusalTest.java quarkus-unit-test
  tagged application/src/test/java/WebTest.java resource-test
  tagged y-gateway/src/test/java/StubTest.java integration
  stub gradlew gradlew
  mkdir -p .archon/scripts/test scripts/test/fixtures/tok scripts/tok .claude/scripts .github/workflows docs
  cp "$repo_root/.archon/scripts/test-task.sh" .archon/scripts/test-task.sh
  cp "$repo_root/.archon/scripts/kit-config.sh" .archon/scripts/kit-config.sh
  stub scripts/test/affected-check.test.sh affected-check.test.sh
  echo a > .archon/scripts/merge.sh; stub .archon/scripts/test/merge.test.sh merge.test.sh
  stub .archon/scripts/test/other.test.sh other.test.sh
  echo a > scripts/tok/build.js; echo a > scripts/test/fixtures/tok/in.txt; stub scripts/test/tok.test.sh tok.test.sh
  echo a > scripts/lone.sh
  echo a > .claude/scripts/shape-check.sh; stub scripts/test/shape-check.test.sh shape-check.test.sh
  stub .claude/scripts/ci-workflow-check.sh ci-workflow-check.sh
  for t in contract-read-only-check ci-workflow-check ci-workflow generated-untracked-check codegen contract-pin; do
    stub "scripts/test/$t.test.sh" "$t.test.sh"
  done
  # The archon suite selector: what $tmp/archon-sel holds, else "all" for ci.yml and .gitignore, else each .archon
  # script's own suite (a changed suite is itself).
  cat > .claude/scripts/archon-suites.sh <<STUB
#!/usr/bin/env bash
[ -f "$tmp/archon-sel" ] && { cat "$tmp/archon-sel"; exit 0; }
[ -f "$tmp/archon-sel-fail" ] && exit 1
while IFS= read -r f; do
  case "\$f" in
    .github/workflows/ci.yml|.gitignore) echo all; exit 0 ;;
    .archon/scripts/test/*.test.sh) echo "\$f" ;;
    .archon/scripts/*) x="\${f#.archon/scripts/}"; x="\${x%%/*}"; echo ".archon/scripts/test/\${x%.sh}.test.sh" ;;
  esac
done
STUB
  echo a > .github/workflows/ci.yml
  echo a > docs/readme.md
  printf 'docs/memory.md merge=union\n' > .gitattributes
  printf '# Memory\n\n- base entry\n' > docs/memory.md
  git add -A && git commit -qm base
  git remote add origin "$d.git" && git push -q origin main
  git checkout -qb feat
}

# new_repo <dir>: a fresh copy of the template clone and its origin, cd-ed into, with an empty stub log. Each case gets
# its own <dir>-<n>: reusing one path made Git Bash's rm -rf leave a held-open repo.git behind, and cp -a then nested the
# template inside it. The trap on $tmp removes them all at the end.
cases=0
new_repo() {
  cases=$((cases + 1))
  local d="$1-$cases"
  cd "$tmp" || exit 1
  rm -rf "$tmp/rc-"* "$tmp/archon-sel" "$tmp/archon-sel-fail"
  [ -d "$tmp/template" ] || ( build_template "$tmp/template" ) > /dev/null 2>&1 || exit 1
  cp -a "$tmp/template" "$d" && cp -a "$tmp/template.git" "$d.git" || exit 1
  cd "$d" || exit 1
  git remote set-url origin "$d.git"
  log="$tmp/log"
  : > "$log"
  export AFFECTED_LOG="$log"
}

run() {
  : > "$log"
  out="$(bash "$script" "$@" 2>&1)"
  rc=$?
}

has() { grep -qxF "$1" "$log"; }
# The cases below expect the quarkus sets (startupTest); the spring ones set KIT_STACK=spring, and the default
# (spring, with no env and no kit.yaml) has a case of its own at the end.
export KIT_STACK=quarkus
ran_nothing() { [ ! -s "$log" ]; }
said() { grep -qF "$1" <<< "$out"; }
same_head() { [ "$(git rev-parse HEAD)" = "$1" ]; }
clean_tree() { [ -z "$(git status --porcelain)" ] && ! git rev-parse -q --verify MERGE_HEAD > /dev/null; }
merges() { git rev-list --merges --count HEAD; }
# on_main <command>: run it on main, commit and push, then back to feat: origin/main moves ahead of the branch.
on_main() { git checkout -q main && eval "$1" && git commit -qam main-moves && git push -q origin main && git checkout -q feat; }

r="$tmp/repo"

# Docs only: nothing runs.
new_repo "$r"
echo b > docs/readme.md && git commit -qam docs
run
check "docs only: exit 0" test "$rc" -eq 0
check "docs only: nothing runs" ran_nothing
check "docs only: says so" said "nothing to run"
check "docs only: the UTF-8 check ran" said "run: UTF-8 check of 1 changed .md file(s)"

# A changed .md file that is not valid UTF-8 fails before anything runs.
new_repo "$r"
printf 'caf\xe9\n' > docs/bad.md && echo b > x-domain/src/A.java
run
check "bad UTF-8: exit non-zero" test "$rc" -ne 0
check "bad UTF-8: names the file" said "FAIL: docs/bad.md is not valid UTF-8"
check "bad UTF-8: nothing runs" ran_nothing

# Paths no local command covers are named with the CI job that still checks them.
new_repo "$r"
mkdir -p backlog && echo a > backlog/t.md && echo a > Dockerfile && echo a > other.txt
run
check "backlog is not listed" bash -c '! grep -qF "backlog/t.md" <<< "$1"' _ "$out"
check "not checked: Dockerfile for every job" said "not checked locally: Dockerfile (every job)"
check "not checked: anything else for every job" said "not checked locally: other.txt (every job)"
check "not checked: still nothing runs" ran_nothing

# An unknown option is refused.
new_repo "$r"
run --bogus
check "unknown option: exit 2" test "$rc" -eq 2

# A domain change: its own and its dependents' unit tests, no integrationTest, the lone gateway untouched.
new_repo "$r"
echo b > x-domain/src/A.java && git commit -qam dom
run
check "domain: exit 0" test "$rc" -eq 0
check "domain: unit tests of it and its dependents" has "gradlew :application:test :x-adapter:test :x-domain:test :x-usecase:test"
check "domain: prints what it ran" said "run: ./gradlew :application:test"
check "domain: ends ok" said "affected-check: ok"

# An adapter change: its tests and application's, and the slow sets their tests are tagged for.
new_repo "$r"
echo b > x-adapter/src/A.java && git commit -qam ad
run
check "adapter: unit tests, then the tagged slow sets" \
  has "gradlew :application:test :x-adapter:test :application:integrationTest :x-adapter:integrationTest :application:startupTest :application:resourceTest"

# An uncommitted application change counts.
new_repo "$r"
echo b > application/src/A.java
run
check "application, uncommitted: its tests and its tagged slow sets" \
  has "gradlew :application:test :application:integrationTest :application:startupTest :application:resourceTest"

# An untracked file in a gateway's main code counts; that does not run the gateway's slow set.
new_repo "$r"
echo b > y-gateway/src/B.java
run
check "gateway main code, untracked: unit tests only" has "gradlew :application:test :y-gateway:test"

# A changed test file tagged integration runs its module's integrationTest, by the shared tag rule.
new_repo "$r"
echo '// b' >> y-gateway/src/test/java/StubTest.java && git commit -qam t
run
check "tagged test file: its set" has "gradlew :application:test :y-gateway:test :y-gateway:integrationTest"

# A changed test file tagged resource-test runs its module's resourceTest.
new_repo "$r"
echo '// b' >> application/src/test/java/WebTest.java && git commit -qam t
run
check "resource-test tagged file: resourceTest" has "gradlew :application:test :application:integrationTest :application:startupTest :application:resourceTest"

# A class named *IT without a tag is a unit test: the name never picks the set.
new_repo "$r"
echo '// b' >> x-domain/src/test/java/DomainIT.java && git commit -qam t
run
check "untagged *IT file: unit tests only" \
  has "gradlew :application:test :x-adapter:test :x-domain:test :x-usecase:test"

# A root Gradle file changes every module.
new_repo "$r"
echo b > build.gradle.kts && git commit -qam root
run
check "root build file: every module, then every tagged slow set" \
  has "gradlew :application:test :x-adapter:test :x-domain:test :x-usecase:test :y-gateway:test :application:integrationTest :x-adapter:integrationTest :y-gateway:integrationTest :application:startupTest :application:resourceTest"

# The shared tag rule: this suite (step-gate.sh shared it until agent-feature was removed, D19).
new_repo "$r"
echo '# b' >> .archon/scripts/test-task.sh && git commit -qam t
run
check "tag rule: the affected-check suite" \
  test "$(cat "$log")" = "affected-check.test.sh "

# Shell scripts: only the matching suite.
new_repo "$r"
echo b > .archon/scripts/merge.sh && git commit -qam s
run
check ".archon script: only its suite" has "merge.test.sh "
check ".archon script: no other suite" test "$(wc -l < "$log" | tr -d ' ')" -eq 1

new_repo "$r"
echo 'echo x' >> .archon/scripts/test/other.test.sh && git commit -qam s
run
check ".archon suite: only itself" has "other.test.sh "
check ".archon suite: nothing else" test "$(wc -l < "$log" | tr -d ' ')" -eq 1

new_repo "$r"
echo b > scripts/tok/build.js && echo b > scripts/test/fixtures/tok/in.txt && git commit -qam s
run
check "scripts dir and fixture: its suite once" test "$(cat "$log")" = "tok.test.sh "

new_repo "$r"
echo b > .claude/scripts/shape-check.sh && git commit -qam s
run
check ".claude script: its suite" test "$(cat "$log")" = "shape-check.test.sh "

new_repo "$r"
echo b > scripts/lone.sh && git commit -qam s
run
check "script without a suite: nothing runs" ran_nothing
check "script without a suite: named as not checked" said "not checked locally: scripts/lone.sh (every job)"

# A workflow change: the CI workflow check and its tests, nothing else.
new_repo "$r"
echo b > .github/workflows/ci.yml && git commit -qam wf
run
check "workflow: every .archon suite, the check and the suites that need no contract" test "$(cat "$log")" = "$(printf 'merge.test.sh \nother.test.sh \nci-workflow-check.sh \ncontract-read-only-check.test.sh \nci-workflow-check.test.sh \nci-workflow.test.sh \ncontract-pin.test.sh ')"
check "workflow: codegen is named as not checked without a contract checkout" said "not checked locally: scripts/test/codegen.test.sh"
check "workflow: generated-untracked-check is named as not checked without a contract checkout" said "not checked locally: scripts/test/generated-untracked-check.test.sh"

# With a contract checkout, codegen runs too; another workflow file runs the check and the suites, but no .archon suite.
new_repo "$r"
mkdir -p contract/dist && echo a > contract/dist/openapi.yaml && echo contract/ > .git/info/exclude
echo a > .github/workflows/other.yml && git add -A && git commit -qm wf
run
check "other workflow with a contract: the check and all six suites" test "$(cat "$log")" = "$(printf 'ci-workflow-check.sh \ncontract-read-only-check.test.sh \nci-workflow-check.test.sh \nci-workflow.test.sh \ngenerated-untracked-check.test.sh \ncodegen.test.sh \ncontract-pin.test.sh ')"

# gradle.properties (the contract pin) and the check's own scripts run the CI workflow tests too.
new_repo "$r"
echo "# b" >> .claude/scripts/ci-workflow-check.sh && git commit -qam c
run
check "ci-workflow-check.sh: the check and the suites" has "contract-pin.test.sh "
new_repo "$r"
echo 'contract.tag=v2' > gradle.properties && git add -A && git commit -qm p
run
check "gradle.properties: every module" has "gradlew :application:test :x-adapter:test :x-domain:test :x-usecase:test :y-gateway:test :application:integrationTest :x-adapter:integrationTest :y-gateway:integrationTest :application:startupTest :application:resourceTest"
check "gradle.properties: the CI workflow tests" has "contract-pin.test.sh "

# The archon suite selection: a hook or .gitignore change runs what the selector picks; a failed selection runs all.
new_repo "$r"
mkdir -p .claude/hooks && echo a > .claude/hooks/scope-guard.sh && git add -A && git commit -qm h
echo .archon/scripts/test/other.test.sh > "$tmp/archon-sel"
run
check "hook change: the selected suite only" test "$(cat "$log")" = "other.test.sh "
new_repo "$r"
echo x > .gitignore && git add -A && git commit -qm g
run
check ".gitignore: every .archon suite" test "$(cat "$log")" = "$(printf 'merge.test.sh \nother.test.sh ')"
new_repo "$r"
echo b > .archon/scripts/merge.sh && git commit -qam s
touch "$tmp/archon-sel-fail"
run
check "failed selection: every .archon suite" test "$(wc -l < "$log" | tr -d ' ')" -eq 2
new_repo "$r"
echo b > .archon/scripts/merge.sh && git commit -qam s
: > "$tmp/archon-sel"
run
check "empty selection: the script's own suite still runs" test "$(cat "$log")" = "merge.test.sh "

# The merge-base, not origin/main's tip: a later commit on main is not this branch's change.
new_repo "$r"
echo b > docs/readme.md && git commit -qam docs
on_main 'echo b > x-domain/src/A.java'
AFFECTED_NO_SYNC=1 run
check "merge-base: main's later commit does not count" ran_nothing

# A changed main class of a usecase module runs the tests of that module and of every module that depends on it.
new_repo "$r"
mkdir -p x-usecase/src/main/java/app && echo b > x-usecase/src/main/java/app/B.java && git add -A && git commit -qm uc
run
check "usecase main class: its module's tests and its dependents'" \
  test "$(cat "$log")" = "gradlew :application:test :x-adapter:test :x-usecase:test"

# The first failure stops the run with its exit code.
new_repo "$r"
echo b > x-domain/src/A.java && echo b > .archon/scripts/merge.sh && git commit -qam two
echo 3 > "$tmp/rc-gradlew"
run
check "failure: exit code of the failing command" test "$rc" -eq 3
check "failure: names it" said "FAIL: ./gradlew"
check "failure: nothing after it runs" test "$(wc -l < "$log" | tr -d ' ')" -eq 1

# --dry-run prints the plan and runs nothing.
new_repo "$r"
echo b > x-domain/src/A.java && git commit -qam dom
run --dry-run
check "dry run: prints the plan" said "run: ./gradlew :application:test"
check "dry run: runs nothing" ran_nothing

# With run-suites.sh, the .archon suites run side by side after the other commands; a failing one is named, exit 1.
new_repo "$r"
cp "$repo_root/.claude/scripts/run-suites.sh" .claude/scripts/run-suites.sh && git add -A && git commit -qm runner
echo b > x-domain/src/A.java && echo b > .archon/scripts/merge.sh && echo 'echo x' >> .archon/scripts/test/other.test.sh
git commit -qam three
run
check "suites: exit 0" test "$rc" -eq 0
check "suites: gradle first" bash -c 'head -1 "$1" | grep -q "^gradlew "' _ "$log"
check "suites: both suites ran" bash -c 'grep -qxF "merge.test.sh " "$1" && grep -qxF "other.test.sh " "$1"' _ "$log"
check "suites: through run-suites" said "run-suites: 2 suites, 4 at a time"
check "suites: each in its block" said "archon/scripts/test/merge.test.sh ("
echo 5 > "$tmp/rc-other.test.sh"
run
check "suite failure: exit 1" test "$rc" -eq 1
check "suite failure: names it" said "FAIL: bash .archon/scripts/test/other.test.sh"
check "suite failure: not the passing one" bash -c '! grep -qF "FAIL: bash .archon/scripts/test/merge.test.sh" <<< "$1"' _ "$out"
check "suite failure: no ok" bash -c '! grep -qF "affected-check: ok" <<< "$1"' _ "$out"
echo 3 > "$tmp/rc-gradlew"
run
check "gradle failure before the suites: no suite runs" test "$(wc -l < "$log" | tr -d ' ')" -eq 1
run --dry-run
check "suites, dry run: prints each suite" said "run: bash .archon/scripts/test/other.test.sh"
check "suites, dry run: runs nothing" ran_nothing

# Sync, up to date: no merge commit, HEAD unchanged.
new_repo "$r"
echo b > docs/readme.md && git commit -qam docs
head="$(git rev-parse HEAD)"
run
check "sync up to date: exit 0" test "$rc" -eq 0
check "sync up to date: HEAD unchanged" same_head "$head"
check "sync up to date: no merge commit" test "$(merges)" -eq 0

# Sync, behind with a parallel docs/memory.md append on both sides: the union driver merges it.
new_repo "$r"
on_main "echo '- main entry' >> docs/memory.md"
echo '- feat entry' >> docs/memory.md && git commit -qam mem
run
mem="$(cat docs/memory.md)"
check "sync memory append: exit 0" test "$rc" -eq 0
check "sync memory append: says it merged" said "sync: merging origin/main"
check "sync memory append: one merge commit" test "$(merges)" -eq 1
check "sync memory append: origin/main is in the branch" git merge-base --is-ancestor origin/main HEAD
check "sync memory append: conventional subject" test "$(git log -1 --format=%s)" = "chore: merge origin/main"
check "sync memory append: main's entry kept" grep -qxF -- "- main entry" docs/memory.md
check "sync memory append: the branch's entry kept" grep -qxF -- "- feat entry" docs/memory.md
check "sync memory append: no conflict markers" test "$(grep -cE '^(<<<<<<<|=======|>>>>>>>)' <<< "$mem")" -eq 0
check "sync memory append: tree clean" clean_tree
check "sync memory append: diffs against the new base, docs only" said "nothing to run"

# Sync, behind with a real conflict elsewhere: aborted, named, the branch left as it was, nothing run.
new_repo "$r"
on_main 'echo main > scripts/lone.sh'
echo feat > scripts/lone.sh && git commit -qam lone
head="$(git rev-parse HEAD)"
run
check "sync conflict: exit non-zero" test "$rc" -ne 0
check "sync conflict: names the file" said "scripts/lone.sh"
check "sync conflict: tells to merge by hand" said "by hand"
check "sync conflict: HEAD unchanged" same_head "$head"
check "sync conflict: tree clean, no merge in progress" clean_tree
check "sync conflict: nothing runs" ran_nothing

# Sync, behind with uncommitted changes: refused, nothing touched.
new_repo "$r"
on_main 'echo b > docs/readme.md'
echo b > x-domain/src/A.java
head="$(git rev-parse HEAD)"
run
check "sync dirty: exit non-zero" test "$rc" -ne 0
check "sync dirty: says why" said "uncommitted changes"
check "sync dirty: HEAD unchanged" same_head "$head"
check "sync dirty: the change is still there" test "$(cat x-domain/src/A.java)" = b
check "sync dirty: nothing runs" ran_nothing

# AFFECTED_NO_SYNC=1 and --dry-run never merge.
new_repo "$r"
on_main 'echo b > docs/readme.md'
head="$(git rev-parse HEAD)"
AFFECTED_NO_SYNC=1 run
check "no sync: HEAD unchanged" same_head "$head"
run --no-sync
check "--no-sync: HEAD unchanged" same_head "$head"
check "--no-sync: no merge" bash -c '! grep -qF "sync: merging" <<< "$1"' _ "$out"
run --dry-run
check "sync dry run: says a merge is due" said "sync: would merge origin/main"
check "sync dry run: HEAD unchanged" same_head "$head"

# A gate file runs gate-change-check.sh against the base first (C11); without the script nothing is added.
new_repo "$r"
stub .claude/scripts/gate-change-check.sh gate-change-check.sh
mkdir -p .archon/scripts && echo a > .archon/scripts/local-ci-status.sh && git add -A && git commit -qm gate
echo .archon/scripts/test/other.test.sh > "$tmp/archon-sel"
run
check "gate file: gate-change-check first, against the base" \
  test "$(cat "$log")" = "$(printf 'gate-change-check.sh origin/main\nother.test.sh ')"
echo 1 > "$tmp/rc-gate-change-check.sh"
run
check "gate file: a missing decision entry fails the run" test "$rc" -ne 0
new_repo "$r"
stub .claude/scripts/gate-change-check.sh gate-change-check.sh
echo b > docs/readme.md && git add -A && git commit -qm docs
run
check "no gate file: no gate-change-check" bash -c 'test "$1" -eq 0 && ! grep -qF gate-change-check "$2"' _ "$rc" "$log"

# An agent instruction text runs agent-script-names.test.sh (C18).
new_repo "$r"
stub scripts/test/agent-script-names.test.sh agent-script-names.test.sh
mkdir -p .github/agents && echo a > .github/agents/dev.agent.md && git add -A && git commit -qm agent
run
check "agent text: the script-names suite" test "$(cat "$log")" = "agent-script-names.test.sh "

# The spring stack (KIT_STACK=spring) has no startupTest: the quarkus-unit-test tag picks no set there, so a file
# tagged with it is a unit test; integration and resource-test pick the same sets as on quarkus.
new_repo "$r"
echo b > application/src/A.java
KIT_STACK=spring run
check "spring, application: its tagged slow sets, no startupTest" \
  has "gradlew :application:test :application:integrationTest :application:resourceTest"
new_repo "$r"
printf '@Tag("quarkus-unit-test")\nclass BootRefusalTest {}\n' > x-domain/src/test/java/BootRefusalTest.java
KIT_STACK=spring run
check "spring, quarkus-unit-test tagged file: unit tests only" \
  has "gradlew :application:test :x-adapter:test :x-domain:test :x-usecase:test"
run
check "quarkus, quarkus-unit-test tagged file: startupTest" \
  has "gradlew :application:test :x-adapter:test :x-domain:test :x-usecase:test :x-domain:startupTest"
# The kit file names the stack when no env does.
new_repo "$r"
printf 'stack: spring\n' > .archon/kit.yaml
echo b > application/src/A.java
KIT_STACK= run
check "kit.yaml stack: spring, application: no startupTest" \
  has "gradlew :application:test :application:integrationTest :application:resourceTest"
printf 'stack: quarkus\n' > .archon/kit.yaml
KIT_STACK= run
check "kit.yaml stack: quarkus, application: startupTest" \
  has "gradlew :application:test :application:integrationTest :application:startupTest :application:resourceTest"
# No env and no kit.yaml: the stack is spring.
rm .archon/kit.yaml
KIT_STACK= run
check "no stack named: spring, application: no startupTest" \
  has "gradlew :application:test :application:integrationTest :application:resourceTest"

cd "$repo_root" || exit 1
echo "affected-check tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
