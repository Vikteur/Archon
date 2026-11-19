#!/usr/bin/env bash
# The tests that prove the phase-0 framework pins ran and passed (TASK-6.6, AC #2, FW-P-04): reads the JUnit XML that
# Gradle wrote for each listed class and refuses a report that is missing (the set was skipped, the class renamed or never
# run), holds no test, or shows a failed, errored or skipped one. Run it after the Gradle build.
# Usage: bash .claude/scripts/pin-proof-check.sh [<repo-root>]   (default: this repository)
# Exit 0 = ok, 1 = refused (one FAIL line each), 2 = usage.
# The stack (kit key `stack`, env KIT_STACK, default quarkus) picks the list: quarkus checks the list below; spring has
# no such list of its own, so it checks the project's file (kit key `pin_proofs`, env KIT_PIN_PROOFS, default
# .archon/pin-proofs.txt; same `<item>|<module>|<task>|<class>` lines, `#` comments and blank lines skipped) and
# refuses a missing or empty one, so a spring build never passes with nothing proven.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }

if [ "$#" -gt 1 ] || [[ "${1:-}" == -* ]]; then
  echo "usage: pin-proof-check.sh [<repo-root>]" >&2
  exit 2
fi
repo="${1:-$(cd "$here/../.." && pwd)}"
cd "$repo" 2>/dev/null || { echo "FAIL: $repo is not a directory"; exit 1; }

# <item>|<module>|<task>|<class>
proofs='starts @QuarkusTest|application|integrationTest|app.rekord.application.ModuleBeanDiscoveryTest
the Jandex discovery test|application|integrationTest|app.rekord.application.ModuleBeanDiscoveryTest
openApiGenerate|shared-adapter|test|app.rekord.common.adapter.controller.OpenApiGenerateTest
the generated output path|shared-adapter|test|app.rekord.common.adapter.controller.OpenApiGenerateTest
Hibernate validate|application|startupTest|app.rekord.application.persistence.HibernateValidateRefusesAnUnmigratedEntityTest
Testcontainers|application|integrationTest|app.rekord.application.persistence.SchemaMigrationTest
the V1 schema baseline|application|integrationTest|app.rekord.application.persistence.SchemaMigrationTest
the V1 schema baseline|application|integrationTest|app.rekord.application.persistence.migration.V1MigrationTest
ArchUnit|application|test|app.rekord.application.architecture.LayerDirectionConventionTest
ArchUnit|application|test|app.rekord.application.architecture.FrozenBaselineTest
ArchUnit on Java 26 bytecode|application|test|app.rekord.application.architecture.SuiteCoverageTest
both rollback tests|application|integrationTest|app.rekord.application.persistence.RowRollbackTest
both rollback tests|application|resourceTest|app.rekord.application.transaction.UseCaseTransactionBoundaryTest
the datasource-less profile|application|resourceTest|app.rekord.application.ResourceTestBootTest
WireMock 3|spotify-gateway|integrationTest|app.rekord.library.gateway.spotify.ProbeStatusGatewayTest
the 403 body|application|resourceTest|app.rekord.application.security.RoleDeniedResourceTest
the notification body per family|shared-adapter|integrationTest|app.rekord.common.adapter.controller.ErrorMappersResourceTest
the Quarkus line pinned|application|test|app.rekord.application.FrameworkPinProofTest'

failed=0
fail() { echo "FAIL: $1"; failed=1; }

if [ "$(kit_get stack quarkus KIT_STACK)" = spring ]; then
  list="$(kit_get pin_proofs .archon/pin-proofs.txt KIT_PIN_PROOFS)"
  proofs=""
  [ -f "$list" ] && proofs="$(tr -d '\r' <"$list" | grep -vE '^[[:space:]]*(#|$)')"
  if [ -z "$proofs" ]; then
    echo "FAIL: no pin proofs in $list (spring stack: list each <item>|<module>|<task>|<class> there)"
    exit 1
  fi
fi

if ! compgen -G "*/build/test-results" >/dev/null; then
  fail "no */build/test-results under $repo: run the Gradle build first"
fi

# attr <testsuite line> <name> -> the numeric value, or empty
attr() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\"\([0-9][0-9]*\)\".*/\1/p"; }

while IFS='|' read -r item module task class; do
  report="$module/build/test-results/$task/TEST-$class.xml"
  if [ ! -f "$report" ]; then
    fail "$item: no report $report (the set was skipped, the class renamed or never run)"
    continue
  fi
  suite="$(tr -d '\r' <"$report" | grep -m1 '<testsuite ')"
  tests="$(attr "$suite" tests)"; skipped="$(attr "$suite" skipped)"
  failures="$(attr "$suite" failures)"; errors="$(attr "$suite" errors)"
  if [ -z "$suite" ] || [ -z "$tests" ] || [ -z "$skipped" ] || [ -z "$failures" ] || [ -z "$errors" ]; then
    fail "$item: $report is unreadable (no <testsuite> element or its counts do not parse)"
  elif [ "$tests" -eq 0 ]; then
    fail "$item: $report holds no test"
  elif [ "$failures" -gt 0 ]; then
    fail "$item: $report has $failures failed test(s)"
  elif [ "$errors" -gt 0 ]; then
    fail "$item: $report has $errors errored test(s)"
  elif [ "$skipped" -gt 0 ]; then
    fail "$item: $report has $skipped skipped test(s)"
  fi
done <<<"$proofs"

[ "$failed" -eq 0 ] && echo "pin-proof: ok"
exit "$failed"
