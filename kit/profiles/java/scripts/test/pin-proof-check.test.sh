#!/usr/bin/env bash
# Tests for .claude/scripts/pin-proof-check.sh (TASK-6.6 AC #2, FW-P-04): it reads the JUnit XML of the tests that prove
# the phase-0 framework pins and refuses a report that is missing, empty, failed, errored or skipped. Each case builds a
# temp root with all reports passing, changes one, and checks the exit code and the FAIL line.
# Run from anywhere: bash scripts/test/pin-proof-check.test.sh   (exit 0 = all pass)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/.claude/scripts/pin-proof-check.sh"
passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/       | /'; }

# <item>|<module>|<task>|<class> — the list each root's .archon/pin-proofs.txt holds (this repo's own)
proofs='starts @QuarkusTest|application|integrationTest|com.example.application.ModuleBeanDiscoveryTest
the Jandex discovery test|application|integrationTest|com.example.application.ModuleBeanDiscoveryTest
openApiGenerate|shared-adapter|test|com.example.common.adapter.controller.OpenApiGenerateTest
the generated output path|shared-adapter|test|com.example.common.adapter.controller.OpenApiGenerateTest
Hibernate validate|application|startupTest|com.example.application.persistence.HibernateValidateRefusesAnUnmigratedEntityTest
Testcontainers|application|integrationTest|com.example.application.persistence.SchemaMigrationTest
the V1 schema baseline|application|integrationTest|com.example.application.persistence.SchemaMigrationTest
the V1 schema baseline|application|integrationTest|com.example.application.persistence.migration.V1MigrationTest
ArchUnit|application|test|com.example.application.architecture.LayerDirectionConventionTest
ArchUnit|application|test|com.example.application.architecture.FrozenBaselineTest
ArchUnit on Java 26 bytecode|application|test|com.example.application.architecture.SuiteCoverageTest
both rollback tests|application|integrationTest|com.example.application.persistence.RowRollbackTest
both rollback tests|application|resourceTest|com.example.application.transaction.UseCaseTransactionBoundaryTest
the datasource-less profile|application|resourceTest|com.example.application.ResourceTestBootTest
WireMock 3|spotify-gateway|integrationTest|com.example.library.gateway.spotify.ProbeStatusGatewayTest
the 403 body|application|resourceTest|com.example.application.security.RoleDeniedResourceTest
the notification body per family|shared-adapter|integrationTest|com.example.common.adapter.controller.ErrorMappersResourceTest
the Quarkus line pinned|application|test|com.example.application.FrameworkPinProofTest'
# module|task|class — each proof's report, once
rows="$(awk -F'|' '!seen[$2 FS $3 FS $4]++ { print $2 "|" $3 "|" $4 }' <<<"$proofs")"
victim_row='application|test|com.example.application.architecture.FrozenBaselineTest'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

write_report() { # <root> <module> <task> <class> <tests> <skipped> <failures> <errors>
  local dir="$1/$2/build/test-results/$3"
  mkdir -p "$dir"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="%s" tests="%s" skipped="%s" failures="%s" errors="%s" timestamp="2026-10-22T10:00:00" hostname="h" time="0.1">\n  <properties/>\n</testsuite>\n' \
    "$4" "$5" "$6" "$7" "$8" >"$dir/TEST-$4.xml"
}

# fresh_root <name>: a root whose list is $proofs and where every listed report passes
fresh_root() {
  local r="$tmp/$1" m t c
  mkdir -p "$r/.archon"
  printf '%s\n' "$proofs" >"$r/.archon/pin-proofs.txt"
  while IFS='|' read -r m t c; do
    write_report "$r" "$m" "$t" "$c" 3 0 0 0
  done <<<"$rows"
  echo "$r"
}

victim_path() { # <root> -> report path of the victim row
  local m t c
  IFS='|' read -r m t c <<<"$victim_row"
  echo "$1/$m/build/test-results/$t/TEST-$c.xml"
}

# refused <case> <root> <expected FAIL fragment>. Here-strings, not printf | grep -q: under pipefail, grep -q quitting at
# the first match can SIGPIPE the printf and turn a match red (seen with 8 suites side by side).
refused() {
  local out rc
  out="$(bash "$script" "$2" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q '^FAIL: ' <<<"$out" && grep -qF "$3" <<<"$out"; then
    pass "$1"
  else
    fail "$1: exit $rc, expected 1 with FAIL naming '$3'" "$out"
  fi
}

# the root default is the repo root of the script; always pass a temp root
r="$(fresh_root accepts)"
out="$(bash "$script" "$r" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "pin-proof: ok" <<<"$out"; then
  pass "accepts_every_report_passing"
else
  fail "accepts_every_report_passing: exit $rc" "$out"
fi

r="$(fresh_root missing)"
rm -f "$(victim_path "$r")"
refused "refuses_a_missing_report" "$r" "ArchUnit"
# One FAIL line per refused item: a missing report is not also read as an unreadable one.
out="$(bash "$script" "$r" 2>&1)"
if [ "$(printf '%s\n' "$out" | grep -c '^FAIL: ')" -eq 1 ]; then
  pass "a_missing_report_gives_one_fail_line"
else
  fail "a_missing_report_gives_one_fail_line" "$out"
fi

# Every listed proof is read: a missing report of any one of them turns the check red, naming that report.
while IFS='|' read -r m t c; do
  r="$(fresh_root "missing-$c")"
  rm -f "$r/$m/build/test-results/$t/TEST-$c.xml"
  refused "refuses_a_missing_report_of $c" "$r" "$m/build/test-results/$t/TEST-$c.xml"
done <<<"$rows"

r="$(fresh_root empty)"
IFS='|' read -r m t c <<<"$victim_row"
write_report "$r" "$m" "$t" "$c" 0 0 0 0
refused "refuses_a_report_with_no_test" "$r" "ArchUnit"

r="$(fresh_root failed)"
write_report "$r" "$m" "$t" "$c" 3 0 1 0
refused "refuses_a_failed_test" "$r" "ArchUnit"

r="$(fresh_root errored)"
write_report "$r" "$m" "$t" "$c" 3 0 0 1
refused "refuses_an_errored_test" "$r" "ArchUnit"

r="$(fresh_root skipped)"
write_report "$r" "$m" "$t" "$c" 3 1 0 0
refused "refuses_a_skipped_test" "$r" "ArchUnit"

r="$(fresh_root unreadable)"
echo "not xml at all" >"$(victim_path "$r")"
refused "refuses_an_unreadable_report" "$r" "ArchUnit"

r="$(fresh_root nonnumeric)"
printf '<testsuite name="x" tests="many" skipped="0" failures="0" errors="0"/>\n' >"$(victim_path "$r")"
refused "refuses_an_unreadable_report (counts do not parse)" "$r" "ArchUnit"

mkdir -p "$tmp/noresults/.archon"
printf '%s\n' "$proofs" >"$tmp/noresults/.archon/pin-proofs.txt"
refused "refuses_a_root_without_results" "$tmp/noresults" "run the Gradle build first"

bash "$script" a b >/dev/null 2>&1; rc1=$?
bash "$script" --help >/dev/null 2>&1; rc2=$?
if [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ]; then
  pass "usage_exits_2"
else
  fail "usage_exits_2: two arguments gave $rc1, an option gave $rc2"
fi

# The spring stack (KIT_STACK=spring) reads the same file; so does a root with no list.
r="$(fresh_root nolist)"; rm -f "$r/.archon/pin-proofs.txt"
refused "refuses_a_root_without_a_list" "$r" "no pin proofs in .archon/pin-proofs.txt"
spring_list='# item|module|task|class
starts @SpringBootTest|application|integrationTest|com.example.application.guest.GuestApiIntegrationTest

ArchUnit|application|test|com.example.application.architecture.ArchitectureTest'
spring_root() { # <name> [list text]: reports for both spring rows pass; the list file holds $2 (none when empty)
  local r="$tmp/$1"
  mkdir -p "$r/.archon"
  write_report "$r" application integrationTest com.example.application.guest.GuestApiIntegrationTest 2 0 0 0
  write_report "$r" application test com.example.application.architecture.ArchitectureTest 4 0 0 0
  [ -n "${2:-}" ] && printf '%s\n' "$2" >"$r/.archon/pin-proofs.txt"
  echo "$r"
}
srefused() { # <case> <root> <fragment>: refused with KIT_STACK=spring
  local out rc
  out="$(KIT_STACK=spring bash "$script" "$2" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q '^FAIL: ' <<<"$out" && grep -qF "$3" <<<"$out"; then pass "$1"; else fail "$1: exit $rc, expected 1 with FAIL naming '$3'" "$out"; fi
}
r="$(spring_root spring-ok "$spring_list")"
out="$(KIT_STACK=spring bash "$script" "$r" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "pin-proof: ok" <<<"$out"; then pass "spring_accepts_the_listed_reports_passing"; else fail "spring_accepts_the_listed_reports_passing: exit $rc" "$out"; fi
srefused "spring_refuses_no_list_file" "$(spring_root spring-nolist)" "no pin proofs in .archon/pin-proofs.txt"
srefused "spring_refuses_a_list_of_only_comments" "$(spring_root spring-comments '# nothing yet')" "no pin proofs"
r="$(spring_root spring-failed "$spring_list")"
write_report "$r" application test com.example.application.architecture.ArchitectureTest 4 0 1 0
srefused "spring_refuses_a_failed_listed_test" "$r" "ArchUnit: application/build/test-results/test/TEST-com.example.application.architecture.ArchitectureTest.xml has 1 failed"
r="$(spring_root spring-missing "$spring_list")"
rm -f "$r/application/build/test-results/integrationTest/TEST-com.example.application.guest.GuestApiIntegrationTest.xml"
srefused "spring_refuses_a_missing_listed_report" "$r" "starts @SpringBootTest: no report"
# KIT_PIN_PROOFS names another list file.
r="$(spring_root spring-env)"
printf '%s\n' "$spring_list" >"$r/proofs.txt"
out="$(KIT_STACK=spring KIT_PIN_PROOFS=proofs.txt bash "$script" "$r" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qxF "pin-proof: ok" <<<"$out"; then pass "spring_reads_the_list_KIT_PIN_PROOFS_names"; else fail "spring_reads_the_list_KIT_PIN_PROOFS_names: exit $rc" "$out"; fi

echo "pin-proof-check: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
