# shellcheck shell=bash
# Sourced, not run: the Gradle test task a test file runs in, by its JUnit tag, never by its class name (PR #99; the
# sets are defined in build.gradle.kts). Used by .claude/scripts/affected-check.sh (step-gate.sh
# shared it until agent-feature was removed, owner decision D19, 2026-10-20).
# The stack (kit key `stack`, env KIT_STACK, default spring) decides the start-up set: on quarkus, startupTest holds
# the @Tag("quarkus-unit-test") refusal tests that boot Quarkus; a spring build has no such set and no such tag, so
# there that tag picks nothing and the file falls through to the next rule. resource-test and integration are the same
# on both stacks.
# shellcheck source=kit-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }
# test_startup_tag: the JUnit tag of the start-up set on this stack, or nothing.
test_startup_tag() {
  case "$(kit_get stack spring KIT_STACK)" in
    spring) ;;
    *) printf '%s' quarkus-unit-test ;;
  esac
}
#   test_task_of <file>: prints startupTest for @Tag("quarkus-unit-test") (quarkus only), resourceTest for
#   @Tag("resource-test"), integrationTest for @Tag("integration"), else test.
test_task_of() {
  local startup; startup="$(test_startup_tag)"
  if [ -n "$startup" ] && grep -q "@Tag(\"$startup\")" "$1" 2>/dev/null; then echo startupTest
  elif grep -q '@Tag("resource-test")' "$1" 2>/dev/null; then echo resourceTest
  elif grep -q '@Tag("integration")' "$1" 2>/dev/null; then echo integrationTest
  else echo test
  fi
}
#   test_tasks_of <file...>: "<task> <file>" for each existing file, by the same tags and order as test_task_of, in one
#   awk pass instead of up to three greps a file (affected-check routes every test file of an affected module).
test_tasks_of() {
  [ "$#" -gt 0 ] || return 0
  awk -v startup="$(test_startup_tag)" 'startup != "" && index($0, "@Tag(\"" startup "\")") { t[FILENAME] = 3 }
       index($0, "@Tag(\"resource-test\")") && t[FILENAME] < 2 { t[FILENAME] = 2 }
       index($0, "@Tag(\"integration\")") && t[FILENAME] < 1 { t[FILENAME] = 1 }
       END { split("integrationTest resourceTest startupTest", n, " ")
             for (i = 1; i < ARGC; i++) print (t[ARGV[i]] ? n[t[ARGV[i]]] : "test"), ARGV[i] }' "$@"
}
