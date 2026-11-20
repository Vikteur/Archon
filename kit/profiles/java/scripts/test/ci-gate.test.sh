#!/usr/bin/env bash
# Tests .claude/scripts/ci-gate.sh, the report-only CI gates (kit/SPEC.md, Report-only gates): tests-ran, format,
# coverage, secrets and contract-lint. In report mode a finding, or a gate that is not set up, prints a ::warning:: and
# passes; in block mode it fails; any other mode fails. gitleaks, spectral and ./gradlew are stubs on a PATH of their
# own, so no real tool runs and the suite needs no network. Each case works in a throwaway project.
# Usage: bash scripts/test/ci-gate.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/.claude/scripts/ci-gate.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }

# A PATH of the tools the script uses and nothing else, so a gitleaks or spectral on this machine never answers.
bin="$tmp/bin"; stubs="$tmp/stubs"; mkdir -p "$bin" "$stubs"
for c in bash env find grep awk sed tr sort head tail ls mktemp mkdir rm cat dirname jq printf; do
  p="$(command -v "$c")" && [ "${p#/}" != "$p" ] && ln -sf "$p" "$bin/$c"
done
# Isolate the kit config: env KIT_GATES_* and KIT_CI_GRADLE_LINE only, no project or machine kit.yaml.
export KIT_CONFIG="$tmp/none/kit.yaml"
unset KIT_GATES_TESTS_RAN KIT_GATES_FORMAT KIT_GATES_COVERAGE KIT_GATES_SECRETS KIT_GATES_CONTRACT_LINT KIT_CI_GRADLE_LINE

n=0; x=0
project() { d="$tmp/p$((++n))"; mkdir -p "$d"; cd "$d" || exit 1; rm -f "$stubs"/*; }
run() { out="$(PATH="$stubs:$bin" bash "$script" "$@" 2>&1)"; rc=$?; }
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }
junit() { # junit <module> <task> <tests> <skipped>: one more TEST-*.xml of that test set
  mkdir -p "$1/build/test-results/$2"; x=$((x + 1))
  printf '<?xml version="1.0"?>\n<testsuite name="T" tests="%s" skipped="%s" failures="0" errors="0" time="0.1">\n</testsuite>\n' \
    "$3" "$4" > "$1/build/test-results/$2/TEST-T$x.xml"
}

# 1. Mode and usage.
project; run nonsense
check "1 an unknown gate is a usage error" "$([ "$rc" -eq 2 ] && said 'unknown gate'; echo $?)"
KIT_GATES_TESTS_RAN=blok run tests-ran
check "1 a mode other than report or block fails, so a typo never turns a gate off" "$([ "$rc" -eq 1 ] \
  && said "kit key gates.tests_ran is 'blok'"; echo $?)"

# 2. tests-ran.
project; run tests-ran
check "2 no JUnit XML: report-only, a warning and exit 0" "$([ "$rc" -eq 0 ] && said '::warning::ci-gate tests-ran: the build ran no test' \
  && said 'kit key gates.tests_ran: block fails the job'; echo $?)"
KIT_GATES_TESTS_RAN=block run tests-ran
check "2 no JUnit XML: block fails" "$([ "$rc" -eq 1 ] && said '::error::ci-gate tests-ran: the build ran no test'; echo $?)"
junit app test 3 0; junit app test 2 1; junit order-domain integrationTest 4 0; KIT_GATES_TESTS_RAN=block run tests-ran
check "2 tests counted per module and task: block passes" "$([ "$rc" -eq 0 ] && said 'app:test ran 5 test(s), 1 skipped' \
  && said 'order-domain:integrationTest ran 4 test(s)' && said 'ci-gate tests-ran: 9 test(s), 1 skipped' && said 'ci-gate tests-ran: ok'; echo $?)"
project; junit . test 2 0; run tests-ran
check "2 the root project's results are module ." "$([ "$rc" -eq 0 ] && said '.:test ran 2 test(s)'; echo $?)"
project; junit app test 2 2; KIT_GATES_TESTS_RAN=block run tests-ran
check "2 every test skipped is a finding" "$([ "$rc" -eq 1 ] && said 'every one of the 2 test(s) was skipped'; echo $?)"
project; junit app test 1 0; KIT_GATES_TESTS_RAN=block KIT_CI_GRADLE_LINE="./gradlew test integrationTest build" run tests-ran
check "2 a test task of ci.gradle_line without results is a note, not a finding" "$([ "$rc" -eq 0 ] \
  && said 'note: task integrationTest (kit key ci.gradle_line) left no JUnit XML' && ! said 'note: task test '; echo $?)"

# 3. format.
project; echo 'plugins { java }' > build.gradle.kts; stub gradlew 'echo should-not-run'; run format ./gradlew spotlessCheck
check "3 no Spotless in the build: not set up, report passes and runs nothing" "$([ "$rc" -eq 0 ] \
  && said 'not set up: no build file applies Spotless' && ! said should-not-run; echo $?)"
KIT_GATES_FORMAT=block run format ./gradlew spotlessCheck
check "3 no Spotless in the build: block fails" "$([ "$rc" -eq 1 ]; echo $?)"
project; mkdir -p build-logic/src; echo 'plugins { id("com.diffplug.spotless") }' > build-logic/src/java-conventions.gradle.kts
printf '#!/usr/bin/env bash\necho "gradlew $*"\n' > gradlew; chmod +x gradlew; KIT_GATES_FORMAT=block run format ./gradlew spotlessCheck --stacktrace
check "3 Spotless in a convention plugin: the command runs and passes" "$([ "$rc" -eq 0 ] && said 'gradlew spotlessCheck --stacktrace' \
  && said 'ci-gate format: ok'; echo $?)"
printf '#!/usr/bin/env bash\necho "Run spotlessApply to fix"\nexit 1\n' > gradlew; run format ./gradlew spotlessCheck
check "3 a failing format check: report passes with a warning" "$([ "$rc" -eq 0 ] && said 'Run spotlessApply' \
  && said '::warning::ci-gate format: the format check failed (exit 1)'; echo $?)"
KIT_GATES_FORMAT=block run format ./gradlew spotlessCheck
check "3 a failing format check: block fails" "$([ "$rc" -eq 1 ] && said '1 finding(s), mode block'; echo $?)"
KIT_GATES_FORMAT=block run format
check "3 no command given is a finding" "$([ "$rc" -eq 1 ] && said 'no command given'; echo $?)"

# 4. coverage.
project; echo 'plugins { java }' > build.gradle.kts; run coverage ./gradlew jacocoTestReport
check "4 no JaCoCo in the build: not set up" "$([ "$rc" -eq 0 ] && said 'not set up: no build file applies JaCoCo'; echo $?)"
project; mkdir -p app; echo 'plugins { jacoco }' > app/build.gradle.kts
cat > gradlew <<'EOF'
#!/usr/bin/env bash
mkdir -p app/build/reports/jacoco/test
printf '<report name="app"><package name="a"><counter type="LINE" missed="9" covered="1"/></package><counter type="INSTRUCTION" missed="5" covered="5"/><counter type="BRANCH" missed="1" covered="3"/><counter type="LINE" missed="25" covered="75"/></report>' \
  > app/build/reports/jacoco/test/jacocoTestReport.xml
EOF
chmod +x gradlew; KIT_GATES_COVERAGE=block run coverage ./gradlew jacocoTestReport
check "4 JaCoCo in a module: the report-level line and branch coverage, no threshold" "$([ "$rc" -eq 0 ] \
  && said 'app/build/reports/jacoco/test/jacocoTestReport.xml: branch 75.0% (3/4) line 75.0% (75/100)' && said 'ci-gate coverage: ok'; echo $?)"
printf '#!/usr/bin/env bash\nrm -rf app/build\n' > gradlew; KIT_GATES_COVERAGE=block run coverage ./gradlew jacocoTestReport
check "4 a report task that writes no XML is a finding" "$([ "$rc" -eq 1 ] && said 'no JaCoCo XML report'; echo $?)"

# 5. secrets.
project; echo 'token=x' > a.env; run secrets
check "5 no gitleaks on PATH: not set up, report passes" "$([ "$rc" -eq 0 ] && said 'not set up: gitleaks is not on PATH'; echo $?)"
KIT_GATES_SECRETS=block run secrets
check "5 no gitleaks on PATH: block fails" "$([ "$rc" -eq 1 ]; echo $?)"
# The stub writes a report with the matched text in it, as an unredacted gitleaks would: the gate never prints it.
leaks='[ "$1" = dir ] || exit 9
case " $* " in *" --redact "*) ;; *) exit 8 ;; esac
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && r="$2"; shift; done
printf "[{\"File\":\"a.env\",\"StartLine\":1,\"RuleID\":\"generic-api-key\",\"Secret\":\"hunter2-secret\",\"Match\":\"token=hunter2-secret\"}]" > "$r"'
stub gitleaks "$leaks"; run secrets
check "5 a finding prints file, line and rule, never the matched text" "$([ "$rc" -eq 0 ] \
  && said '::warning::ci-gate secrets: a.env:1 matches rule generic-api-key' && ! said hunter2; echo $?)"
KIT_GATES_SECRETS=block run secrets
check "5 a finding in block mode fails" "$([ "$rc" -eq 1 ] && ! said hunter2; echo $?)"
stub gitleaks 'while [ $# -gt 0 ]; do [ "$1" = --report-path ] && r="$2"; shift; done; printf "[]" > "$r"'
KIT_GATES_SECRETS=block run secrets
check "5 a clean scan passes in block mode" "$([ "$rc" -eq 0 ] && said 'ci-gate secrets: ok'; echo $?)"
stub gitleaks '[ "$1" = dir ] && { echo "unknown command dir"; exit 1; }
[ "$1" = detect ] && [ "$2" = --no-git ] || exit 7
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && r="$2"; shift; done; printf "[]" > "$r"'
KIT_GATES_SECRETS=block run secrets
check "5 an older gitleaks without dir: detect --no-git" "$([ "$rc" -eq 0 ] && said 'ci-gate secrets: ok'; echo $?)"
stub gitleaks 'echo "gitleaks broke"; exit 3'; run secrets
check "5 a gitleaks that does not run is a finding, not a pass" "$([ "$rc" -eq 0 ] && said 'gitleaks did not run (exit 3)'; echo $?)"

# 6. contract-lint.
project; mkdir -p contract/dist; echo 'openapi: 3.1.0' > contract/dist/openapi.yaml; run contract-lint contract/dist/openapi.yaml
check "6 no spectral: not set up" "$([ "$rc" -eq 0 ] && said 'not set up: spectral'; echo $?)"
stub spectral 'echo "spectral $1 $2 $(cat "$3") $4"'; KIT_GATES_CONTRACT_LINT=block run contract-lint contract/dist/openapi.yaml
check "6 no ruleset: spectral:oas" "$([ "$rc" -eq 0 ] && said 'spectral lint --ruleset extends: ["spectral:oas"] contract/dist/openapi.yaml' \
  && said '(ruleset spectral:oas)'; echo $?)"
echo 'extends: [spectral:oas, ./own.yaml]' > contract/.spectral.yaml; echo 'rules: {}' > .spectral.yaml
KIT_GATES_CONTRACT_LINT=block run contract-lint
check "6 the contract's own ruleset wins; the spec defaults to kit key contract.spec_path" "$([ "$rc" -eq 0 ] \
  && said '(ruleset contract/.spectral.yaml)' && said 'contract/dist/openapi.yaml'; echo $?)"
stub spectral 'echo "1:1 error oas3-schema"; exit 1'; run contract-lint contract/dist/openapi.yaml
check "6 lint errors: report passes with a warning" "$([ "$rc" -eq 0 ] && said 'oas3-schema' \
  && said '::warning::ci-gate contract-lint: spectral found errors'; echo $?)"
KIT_GATES_CONTRACT_LINT=block run contract-lint contract/dist/openapi.yaml
check "6 lint errors: block fails" "$([ "$rc" -eq 1 ]; echo $?)"
KIT_GATES_CONTRACT_LINT=block run contract-lint contract/missing.yaml
check "6 no spec at the path is a finding" "$([ "$rc" -eq 1 ] && said 'no contract spec at contract/missing.yaml'; echo $?)"

cd "$tmp" || exit 1
echo "ci-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
