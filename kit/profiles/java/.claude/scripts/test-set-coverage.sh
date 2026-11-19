#!/usr/bin/env bash
# The test-set coverage gate (CI plan C19, owner decision D11 2026-10-20, docs/memory.md): build.gradle.kts skips a slow
# test set's JVM when no compiled test class of a module names the set's tag (PR #113). This fails when that skip would
# drop a real test: one whose JUnit tags (@Tag/@Tags, meta-annotations, superclasses, interfaces, the enclosing class of a
# @Nested class, the test method; across modules) include the tag while no class file of its module names it. Keyed on
# the compiled annotations, never on class names. The sets and tags are read from the build file's onlyIf list, so the
# gate checks what the build skips.
# Usage: bash .claude/scripts/test-set-coverage.sh [--root <dir>] [--build <build-file>] [<module>...]
#   Reads <root>/*/build/classes/java/{main,test,testFixtures}: run it after the build has compiled the test classes
#   (CI's test job runs it after its Gradle step). No module named: every module with a src/test/java. A module with
#   test sources but no compiled test classes fails.
# Exit 0 "test-set-coverage: ok ...", 1 a FAIL line per uncovered set, 2 usage or cannot run (no Java 24+, no set list).
# TEST_SET_COVERAGE_JAVA overrides the java binary (default: $JAVA_HOME/bin/java, else java on PATH).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build=""
modules=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "test-set-coverage: --root needs a dir" >&2; exit 2; }; root="$2"; shift 2 ;;
    --build) [ $# -ge 2 ] || { echo "test-set-coverage: --build needs a file" >&2; exit 2; }; build="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "test-set-coverage: unknown option $1" >&2; exit 2 ;;
    *) modules+=("$1"); shift ;;
  esac
done
[ -d "$root" ] || { echo "test-set-coverage: no dir $root" >&2; exit 2; }
build="${build:-$root/build.gradle.kts}"

java="${TEST_SET_COVERAGE_JAVA:-}"
if [ -z "$java" ]; then
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then java="$JAVA_HOME/bin/java"; else java="java"; fi
fi
command -v "$java" > /dev/null 2>&1 || { echo "test-set-coverage: no java ($java)" >&2; exit 2; }
spec="$("$java" -XshowSettings:properties -version 2>&1 | tr -d '\r' | sed -n 's/^ *java\.specification\.version = //p' | head -n 1)"
# The class-file API (java.lang.classfile) is final from Java 24.
[[ "$spec" =~ ^[0-9]+$ ]] && [ "$spec" -ge 24 ] || { echo "test-set-coverage: needs Java 24 or later, $java is ${spec:-unknown}" >&2; exit 2; }

# The skipped sets: the `listOf(<task> to "<tag>", ...)` that the build's onlyIf walks.
sets="$(grep -E 'listOf\(([A-Za-z]+ to "[^"]+"(, *)?)+\)' "$build" 2>/dev/null | grep -oE '[A-Za-z]+ to "[^"]+"' | sed -E 's/^([A-Za-z]+) to "([^"]+)"$/\1=\2/')"
[ -n "$sets" ] || { echo "test-set-coverage: $build names no skipped test set (listOf(<task> to \"<tag>\", ...))" >&2; exit 2; }

args=()
while IFS= read -r s; do args+=(--set "$s"); done <<< "$sets"
for m in "${modules[@]}"; do args+=(--module "$m"); done
"$java" "$here/test-set-coverage.java" "$root" "${args[@]}"
