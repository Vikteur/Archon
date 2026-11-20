#!/usr/bin/env bash
# Tests the scope of .claude/scripts/ci-workflow-check.sh in a project the kit is installed in: the rules fail only on
# the workflows the kit owns (the paths .archon/kit.lock.json tracks; every workflow where there is no lock), a
# workflow the project wrote itself gets BASELINE lines that never fail, and the Java toolchain may sit in a convention
# plugin under buildSrc/ or build-logic/. The contract rules hold where the openapi-contract profile is installed (no
# lock, or the lock tracks its contract-pin.sh, or that script is in the tree); without it the kit's workflow has no
# contract steps and may have none. Each case builds a throwaway repo; nothing reads this checkout's workflows.
# Usage: bash scripts/test/ci-workflow-scope.test.sh   (exit 0 = all pass; needs yq, mikefarah v4)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-workflow-check.sh"
command -v yq > /dev/null 2>&1 || { echo "ci-workflow-scope tests: yq is required"; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0
export KIT_CONTRACT_REPO=acme/api-contract

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }
run() { out="$(cd "$repo" && bash "$script" 2>&1)"; rc=$?; }

sha=0123456789abcdef0123456789abcdef01234567
# The kit's workflow without the openapi-contract profile, every rule kept: <java version> [<gradle line>]
plain_ci() {
  cat << EOF
name: ci
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@$sha
      - uses: actions/setup-java@$sha
        with:
          distribution: temurin
          java-version: '$1'
      - id: gradle
        run: ${2:-./gradlew test integrationTest build} --build-cache --parallel --stacktrace
      - if: failure() && steps.gradle.outcome == 'failure'
        uses: actions/upload-artifact@$sha
        with:
          name: test-reports
          path: |
            */build/reports/tests/
            */build/test-results/**/*.xml
EOF
}
# The kit's workflow with the openapi-contract profile, every rule kept: <java version> [<checkout ref>]
kit_ci() {
  cat << EOF
name: ci
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@${2:-$sha}
      - name: Check out api-contract
        uses: actions/checkout@$sha
        with:
          repository: acme/api-contract
          path: contract
          token: \${{ secrets.CONTRACT_TOKEN }}
      - run: bash .claude/scripts/contract-read-only-check.sh contract
      - run: bash .claude/scripts/contract-pin.sh contract
      - uses: actions/setup-java@$sha
        with:
          distribution: temurin
          java-version: '$1'
      - run: ./gradlew test integrationTest build -Pcontract.spec=contract/dist/openapi.yaml
EOF
}
# The project's own workflow: an action pinned by tag and the contract token used outside the checkout.
own_ci() {
  cat << 'EOF'
name: release
on: push
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./publish.sh
        env:
          TOKEN: ${{ secrets.CONTRACT_TOKEN }}
EOF
}
# new_repo <name> <lock: yes|no|plain> [<toolchain file>]: a repo with the kit's ci.yml (Java 21) and the project's
# release.yml. yes: the lock of an install with the openapi-contract profile (it tracks contract-pin.sh); plain: the
# lock of an install without that profile, and the kit's workflow without contract steps.
new_repo() {
  repo="$tmp/$1"
  mkdir -p "$repo/.github/workflows" "$repo/docs" "$repo/.archon"
  if [ "$2" = plain ]; then plain_ci 21; else kit_ci 21; fi > "$repo/.github/workflows/ci.yml"
  own_ci > "$repo/.github/workflows/release.yml"
  echo '- CI job set: `build`' > "$repo/docs/memory.md"
  local tc="${3:-build.gradle.kts}"
  mkdir -p "$(dirname "$repo/$tc")"
  printf 'java {\n  toolchain { languageVersion.set(JavaLanguageVersion.of(21)) }\n}\n' > "$repo/$tc"
  [ "$tc" = build.gradle.kts ] || echo 'plugins { id("conventions") }' > "$repo/build.gradle.kts"
  local contract='".claude/scripts/contract-pin.sh":"z",'
  [ "$2" = yes ] || contract=""
  [ "$2" = no ] || printf '{"kit":{"name":"k","commit":"c"},"files":{%s".github/workflows/ci.yml":"x",".archon/kit.yaml":"y"}}\n' \
    "$contract" > "$repo/.archon/kit.lock.json"
}

# 1. No lock (the kit's own source): every workflow is the kit's, so the project's release.yml fails.
new_repo nolock no
run
check "1 without a lock every workflow is checked and fails" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: .github/workflows/release.yml: actions/checkout@v4 is not pinned' && ! said 'BASELINE'; echo $?)"

# 2. A lock: the project's own release.yml is a baseline, the kit's ci.yml still holds every rule.
new_repo lock yes
run
check "2 the project's own workflow is a baseline, not a fail" "$([ "$rc" -eq 0 ] && said 'ci-workflow: ok' \
  && said 'BASELINE: .github/workflows/release.yml: actions/checkout@v4 is not pinned by a 40-character commit SHA' \
  && said 'BASELINE: .github/workflows/release.yml: CONTRACT_TOKEN may appear only as the token of the api-contract checkout' \
  && said 'ci-workflow: 2 baseline finding(s)' && ! said 'FAIL'; echo $?)"
kit_ci 21 v4 > "$repo/.github/workflows/ci.yml"
run
check "2 a rule broken in the kit's own workflow still fails" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: .github/workflows/ci.yml: actions/checkout@v4 is not pinned'; echo $?)"
kit_ci 21 > "$repo/.github/workflows/ci.yml"
printf 'on: [\n' > "$repo/.github/workflows/broken.yml"
run
check "2 invalid YAML in the project's own workflow is a baseline" "$([ "$rc" -eq 0 ] \
  && said 'BASELINE: .github/workflows/broken.yml is not valid YAML'; echo $?)"
rm "$repo/.github/workflows/broken.yml"
kit_ci 21 | sed 's/^name: ci/name: nightly/' > "$repo/.github/workflows/nightly.yml"
run
check "2 the project's own gradle workflow is not a second job definition" "$([ "$rc" -eq 0 ] \
  && ! said 'more than one workflow'; echo $?)"
rm "$repo/.github/workflows/ci.yml"
run
check "2 with the kit's workflow gone, the project's gradle workflow does not stand in" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: no workflow runs ./gradlew test integrationTest build (of the workflows the kit owns)'; echo $?)"

# 3. The toolchain in a convention plugin.
new_repo logic yes build-logic/src/main/kotlin/conventions.gradle.kts
mkdir -p "$repo/build-logic/build/kotlin"
echo 'JavaLanguageVersion.of(11)' > "$repo/build-logic/build/kotlin/old.gradle.kts"
run
check "3 a toolchain under build-logic/ is the toolchain, build output skipped" "$([ "$rc" -eq 0 ] && said 'ci-workflow: ok'; echo $?)"
kit_ci 17 > "$repo/.github/workflows/ci.yml"
run
check "3 a setup-java that is not that toolchain fails" "$([ "$rc" -eq 1 ] && said 'must set up Temurin 21'; echo $?)"
new_repo src yes buildSrc/src/main/kotlin/java.gradle.kts
run
check "3 a toolchain under buildSrc/ is the toolchain" "$([ "$rc" -eq 0 ]; echo $?)"
rm -r "$repo/buildSrc"
run
check "3 no toolchain anywhere fails and names where it looked" "$([ "$rc" -eq 1 ] \
  && said 'build.gradle.kts names no Java toolchain (nor does a Gradle file under buildSrc/ or build-logic/)'; echo $?)"

# 4. Without the openapi-contract profile: the kit's workflow has no contract steps, and the check holds it to that.
new_repo plain plain
run
check "4 without the contract profile, a workflow with no contract steps passes, a multi-line upload path read as one step" "$([ "$rc" -eq 0 ] \
  && said 'ci-workflow: ok' && ! said 'FAIL' && ! said 'syntax error'; echo $?)"
kit_ci 21 > "$repo/.github/workflows/ci.yml"
run
check "4 without the contract profile, the contract steps fail, each named" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: .github/workflows/ci.yml: CONTRACT_TOKEN is the CI secret of the openapi-contract profile, which is not installed' \
  && said 'FAIL: .github/workflows/ci.yml: job build checks out a contract, but the openapi-contract profile is not installed' \
  && said 'job build runs a script of the openapi-contract profile, which is not installed: .claude/scripts/contract-pin.sh .claude/scripts/contract-read-only-check.sh' \
  && said 'FAIL: .github/workflows/ci.yml: job build passes -Pcontract.spec, but the openapi-contract profile is not installed'; echo $?)"
plain_ci 21 | sed 's|--stacktrace$|--stacktrace\n      - run: bash .claude/scripts/generated-untracked-check.sh|' > "$repo/.github/workflows/ci.yml"
run
check "4 without the contract profile, generated-untracked-check.sh (it ships with that profile) fails" "$([ "$rc" -eq 1 ] \
  && said 'runs a script of the openapi-contract profile, which is not installed: .claude/scripts/generated-untracked-check.sh'; echo $?)"
plain_ci 21 > "$repo/.github/workflows/ci.yml"
mkdir -p "$repo/.claude/scripts"; : > "$repo/.claude/scripts/contract-pin.sh"
run
check "4 contract-pin.sh in the tree holds the workflow to the contract rules, whatever the lock says" "$([ "$rc" -eq 1 ] \
  && said 'job build has no step that checks out acme/api-contract'; echo $?)"
rm -r "$repo/.claude"
# With the contract profile (its contract-pin.sh in the lock), a workflow without the contract steps fails, as before.
new_repo contract yes
plain_ci 21 > "$repo/.github/workflows/ci.yml"
run
check "4 with the contract profile, a workflow without the contract steps fails" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: .github/workflows/ci.yml: job build has no step that checks out acme/api-contract' \
  && said 'FAIL: .github/workflows/ci.yml: job build generates code or starts the application but does not check out'; echo $?)"
# Kit key profiles naming openapi-contract holds the workflow to the contract rules (kit_list, from kit-config.sh: it
# ships with core, so this case runs in an install, not in the java profile's folder alone).
if [ -f "$(dirname "$script")/../../.archon/scripts/kit-config.sh" ]; then
  new_repo profiles plain
  git -C "$repo" init -q
  printf 'profiles: [core, java, java-spring, openapi-contract]\n' > "$repo/.archon/kit.yaml"
  run
  check "4 kit key profiles naming openapi-contract holds the workflow to the contract rules" "$([ "$rc" -eq 1 ] \
    && said 'job build has no step that checks out acme/api-contract'; echo $?)"
  printf 'profiles: [core, java, java-spring]\n' > "$repo/.archon/kit.yaml"
  run
  check "4 kit key profiles without openapi-contract: the workflow without contract steps passes" "$([ "$rc" -eq 0 ]; echo $?)"
fi

# 5. The required gradle run is kit key ci.gradle_line.
new_repo line plain
KIT_CI_GRADLE_LINE="./gradlew check" run
check "5 a gradle run other than kit key ci.gradle_line is not the job definition" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: no workflow runs ./gradlew check (of the workflows the kit owns)'; echo $?)"
plain_ci 21 "./gradlew check" > "$repo/.github/workflows/ci.yml"
KIT_CI_GRADLE_LINE="./gradlew check" run
check "5 the gradle run of kit key ci.gradle_line passes" "$([ "$rc" -eq 0 ] && said 'ci-workflow: ok'; echo $?)"

echo "ci-workflow-scope tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
