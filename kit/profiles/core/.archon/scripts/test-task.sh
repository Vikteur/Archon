# shellcheck shell=bash
# Sourced, not run: the Gradle test task a test file runs in, by its JUnit tag, never by its class name (PR #99; the
# sets are defined in build.gradle.kts). Used by .claude/scripts/affected-check.sh (step-gate.sh
# shared it until agent-feature was removed, owner decision D19, 2026-10-20).
#   test_task_of <file>: prints startupTest for @Tag("quarkus-unit-test"), resourceTest for @Tag("resource-test"),
#   integrationTest for @Tag("integration"), else test.
test_task_of() {
  if grep -q '@Tag("quarkus-unit-test")' "$1" 2>/dev/null; then echo startupTest
  elif grep -q '@Tag("resource-test")' "$1" 2>/dev/null; then echo resourceTest
  elif grep -q '@Tag("integration")' "$1" 2>/dev/null; then echo integrationTest
  else echo test
  fi
}
#   test_tasks_of <file...>: "<task> <file>" for each existing file, by the same tags and order as test_task_of, in one
#   awk pass instead of up to three greps a file (affected-check routes every test file of an affected module).
test_tasks_of() {
  [ "$#" -gt 0 ] || return 0
  awk 'index($0, "@Tag(\"quarkus-unit-test\")") { t[FILENAME] = 3 }
       index($0, "@Tag(\"resource-test\")") && t[FILENAME] < 2 { t[FILENAME] = 2 }
       index($0, "@Tag(\"integration\")") && t[FILENAME] < 1 { t[FILENAME] = 1 }
       END { split("integrationTest resourceTest startupTest", n, " ")
             for (i = 1; i < ARGC; i++) print (t[ARGV[i]] ? n[t[ARGV[i]]] : "test"), ARGV[i] }' "$@"
}
