#!/usr/bin/env bash
# Tests the rules of .claude/scripts/ci-workflow-check.sh on the job definition (ci-workflow-scope.test.sh tests which
# workflows they hold on): workflow_dispatch as the only event, no path filter, a timeout and no if on every job, no
# continue-on-error and no [skip ci] marker, the job set of docs/memory.md, no excluded gradle task, the only failure()
# gate after the contract checkout, the contract checkout, read-only proof and pin in every job that runs ./gradlew,
# the spec argument on every ./gradlew run (a report-only gate step's too), and one job definition. Each case writes a
# throwaway repo without a lock (every workflow is the kit's, the contract rules hold). Where this checkout is an
# install, the kit's own rendered ci.yml must pass as well, or, with the contract profile in and kit key contract.repo
# unset, be refused with that key named.
# Usage: bash scripts/test/ci-workflow-check.test.sh   (exit 0 = all pass; needs yq, mikefarah v4)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/.claude/scripts/ci-workflow-check.sh"
command -v yq >/dev/null 2>&1 || { echo "ci-workflow-check tests: yq is required"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }
unset KIT_CI_GRADLE_LINE KIT_CONTRACT_CHECKOUT_STEP

# 0. The kit's own ci.yml, as this install rendered it, with this install's lock and kit.yaml (skipped in the source).
ci="$root/.github/workflows/ci.yml"
if [ -f "$ci" ] && [ -f "$root/docs/memory.md" ] && ! grep -q '@@KIT_' "$ci"; then
  java="$(yq '[.jobs[].steps[] | select(has("uses")) | select(.uses | test("^actions/setup-java@")) | .with["java-version"]][0]' "$ci")"
  printf 'java { toolchain { languageVersion.set(JavaLanguageVersion.of(%s)) } }\n' "$java" > "$tmp/build.gradle.kts"
  out="$(cd "$root" && bash "$script" .github/workflows "$tmp/build.gradle.kts" docs/memory.md 2>&1)"; rc=$?
  # The install's own config, read the way the checker reads it: kit key contract.repo (env KIT_CONTRACT_REPO first),
  # and the openapi-contract profile in when its contract-pin.sh is in the tree or kit key profiles names it.
  repo="$(cd "$root" && . .archon/scripts/kit-config.sh 2>/dev/null && kit_get contract.repo "" KIT_CONTRACT_REPO)"
  contract_in=0
  if [ -f "$root/.claude/scripts/contract-pin.sh" ] || (cd "$root" && . .archon/scripts/kit-config.sh 2>/dev/null \
      && kit_list profiles | tr -d '\r' | grep -qxF openapi-contract); then contract_in=1; fi
  if [ "$contract_in" -eq 0 ] || [ -n "$repo" ]; then
    check "0 the kit's rendered ci.yml passes, its report-only gate steps included" "$([ "$rc" -eq 0 ] \
      && said 'ci-workflow: ok' && grep -q 'ci-gate.sh tests-ran' "$ci"; echo $?)"
  else
    # A default install: the contract profile is in and contract.repo is "", so ci.yml checks out an empty repository.
    check "0 the kit's rendered ci.yml with contract.repo unset is refused, the unset repo named" "$([ "$rc" -eq 1 ] \
      && said 'FAIL: kit key contract.repo is not set' && ! said 'ci-workflow: ok'; echo $?)"
  fi
fi

export KIT_CONTRACT_REPO=acme/api-contract KIT_CONFIG="$tmp/none/kit.yaml"
sha=0123456789abcdef0123456789abcdef01234567
spec="-Pcontract.spec=contract/dist/openapi.yaml"
# The job definition that passes, shaped like the kit's: the test job with the contract steps, a report-only gate
# after the build, a failure-only upload, and the archon-scripts job without ./gradlew.
good_ci() {
  cat << EOF
name: CI
on:
  workflow_dispatch:
jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@$sha
      - name: Check out api-contract
        uses: actions/checkout@$sha
        with:
          repository: acme/api-contract
          path: contract
          token: \${{ secrets.CONTRACT_TOKEN }}
      - run: bash .claude/scripts/contract-read-only-check.sh contract
      - run: bash .claude/scripts/contract-pin.sh contract
      - uses: actions/setup-java@$sha # a comment may say [skip ci]
        with:
          distribution: temurin
          java-version: '21'
      - name: Build and test
        id: gradle
        run: ./gradlew test integrationTest build --build-cache $spec --stacktrace
      - name: Tests ran before the red build
        if: failure() && steps.gradle.outcome == 'failure'
        run: bash .claude/scripts/ci-gate.sh tests-ran
      - name: Format (Spotless, report-only)
        run: bash .claude/scripts/ci-gate.sh format ./gradlew spotlessCheck $spec
  archon-scripts:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@$sha
      - run: bash .claude/scripts/ci-workflow-check.sh
EOF
}
n=0
new_repo() { # a repo with good_ci, the job set in docs/memory.md and a Java 21 toolchain
  repo="$tmp/r$((++n))"
  mkdir -p "$repo/.github/workflows" "$repo/docs"
  good_ci > "$repo/.github/workflows/ci.yml"
  printf -- '- CI job set (N7): `archon-scripts test`.\n' > "$repo/docs/memory.md"
  printf 'java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }\n' > "$repo/build.gradle.kts"
}
run() { out="$(cd "$repo" && bash "$script" 2>&1)"; rc=$?; }
edit() { yq -i "$1" "$repo/.github/workflows/ci.yml"; }   # edit <yq expression>: change the repo's ci.yml

# 1. The workflow that passes.
new_repo; run
check "1 the kit-shaped workflow passes, a [skip ci] in a comment is no marker" "$([ "$rc" -eq 0 ] && said 'ci-workflow: ok'; echo $?)"

# 2. Triggers (D21) and filters (N3).
new_repo; edit '.on.push = {}'; run
check "2 a push event fails: workflow_dispatch only" "$([ "$rc" -eq 1 ] \
  && said 'on must hold workflow_dispatch only, it holds push workflow_dispatch'; echo $?)"
new_repo; edit '.on.workflow_dispatch = {"paths": ["src/**"]}'; run
check "2 an event filtered by paths fails (N3)" "$([ "$rc" -eq 1 ] && said 'on.workflow_dispatch may not filter by paths'; echo $?)"

# 3. Every job runs, with a timeout, and never fails softly (N1, N4).
new_repo; edit 'del(.jobs["archon-scripts"]["timeout-minutes"])'; run
check "3 a job without timeout-minutes fails (N1)" "$([ "$rc" -eq 1 ] && said 'job archon-scripts must set a positive whole timeout-minutes'; echo $?)"
new_repo; edit '.jobs.test["timeout-minutes"] = "30m"'; run
check "3 a timeout that is no whole number fails (N1)" "$([ "$rc" -eq 1 ] && said 'job test must set a positive whole timeout-minutes'; echo $?)"
new_repo; edit '.jobs["archon-scripts"].if = "github.ref == '"'refs/heads/main'"'"'; run
check "3 a job-level if fails (N4)" "$([ "$rc" -eq 1 ] && said 'job archon-scripts may not have an if'; echo $?)"
new_repo; edit '.jobs["archon-scripts"].steps[1]["continue-on-error"] = true'; run
check "3 continue-on-error on a step of another job fails (N4)" "$([ "$rc" -eq 1 ] && said 'job archon-scripts may not continue on error (N4)'; echo $?)"
new_repo; edit '.jobs.test.steps[7]["continue-on-error"] = true'; run
check "3 continue-on-error on a report-only gate step fails, by its name" "$([ "$rc" -eq 1 ] \
  && said 'job test may not continue on error (Format (Spotless, report-only))'; echo $?)"
new_repo; edit '.jobs["archon-scripts"].steps[1].run = "echo [skip ci]"'; run
check "3 a [skip ci] marker in the YAML fails (N4)" "$([ "$rc" -eq 1 ] && said 'may depend on a [skip ci] marker'; echo $?)"

# 4. The job set of docs/memory.md (N7).
new_repo; edit '.jobs.lint = .jobs["archon-scripts"]'; run
check "4 a job the decision record does not name fails (N7)" "$([ "$rc" -eq 1 ] \
  && said 'the jobs are archon-scripts lint test, but docs/memory.md records archon-scripts test'; echo $?)"
printf -- '- CI job set (N7): `archon-scripts lint test`, the lint job added.\n' >> "$repo/docs/memory.md"; run
check "4 ... and passes once a later entry names the new set" "$([ "$rc" -eq 0 ]; echo $?)"
new_repo; : > "$repo/docs/memory.md"; run
check "4 no job set recorded fails (N7)" "$([ "$rc" -eq 1 ] && said 'docs/memory.md records no CI job set'; echo $?)"

# 5. The gradle run and the job definition.
new_repo; edit '.jobs.test.steps[5].run = "./gradlew test integrationTest build -x integrationTest '"$spec"'"'; run
check "5 an excluded gradle task fails" "$([ "$rc" -eq 1 ] && said 'the gradle run may not exclude a task'; echo $?)"
new_repo; good_ci > "$repo/.github/workflows/second.yml"; run
check "5 a second workflow with the gradle run fails: one job definition" "$([ "$rc" -eq 1 ] && said 'more than one workflow runs'; echo $?)"
new_repo; edit '.jobs.test.steps[4].with.distribution = "zulu"'; run
check "5 a setup-java other than Temurin of the toolchain fails" "$([ "$rc" -eq 1 ] && said 'must set up Temurin 21'; echo $?)"

# 6. Fail closed after the contract checkout: a failure() step runs only after the gradle step failed.
new_repo; edit '.jobs.test.steps[6].if = "always()"'; run
check "6 an always() step after the contract checkout fails" "$([ "$rc" -eq 1 ] \
  && said 'step Tests ran before the red build runs after a failed contract checkout (if: always())'; echo $?)"
new_repo; edit '.jobs.test.steps[6].if = "failure()"'; run
check "6 a bare failure() step fails" "$([ "$rc" -eq 1 ] && said 'runs after a failed contract checkout (if: failure())'; echo $?)"
new_repo; edit '.jobs.test.steps[6].if = "failure() && steps.nothere.outcome == '"'failure'"'"'; run
check "6 a failure() gate on a step id that does not exist fails" "$([ "$rc" -eq 1 ] && said 'runs after a failed contract checkout'; echo $?)"
new_repo; edit '.jobs.test.steps[2].if = "success()"'; run
check "6 an if on the read-only proof fails" "$([ "$rc" -eq 1 ] && said 'may not have an if'; echo $?)"

# 7. The contract in every job that runs ./gradlew, the spec on every ./gradlew run.
new_repo; edit '.jobs.test.steps[7].run = "bash .claude/scripts/ci-gate.sh format ./gradlew spotlessCheck"'; run
check "7 a report-only gate's ./gradlew run without the spec fails" "$([ "$rc" -eq 1 ] \
  && said "job test: every ./gradlew run must pass $spec"; echo $?)"
new_repo; edit '.jobs["archon-scripts"].steps[1].run = "./gradlew help '"$spec"'"'; run
check "7 another job that runs ./gradlew without the contract checkout fails" "$([ "$rc" -eq 1 ] \
  && said 'job archon-scripts generates code or starts the application but does not check out'; echo $?)"
new_repo; edit '.jobs.test.steps[3].run = "echo pin"'; run
check "7 no pin right after the read-only proof fails" "$([ "$rc" -eq 1 ] \
  && said 'the step after the read-only check must run bash .claude/scripts/contract-pin.sh contract'; echo $?)"
new_repo; edit '.jobs.test.steps[1].with.token = "${{ secrets.OTHER }}"'; run
check "7 a contract checkout with another secret fails" "$([ "$rc" -eq 1 ] \
  && said 'checkout must use token ${{ secrets.CONTRACT_TOKEN }} and nothing else'; echo $?)"
new_repo; edit '.jobs.test.steps[0].uses = "actions/checkout@v4"'; run
check "7 an action pinned by tag fails" "$([ "$rc" -eq 1 ] && said 'actions/checkout@v4 is not pinned by a 40-character commit SHA'; echo $?)"

echo "ci-workflow-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
