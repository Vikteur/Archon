#!/usr/bin/env bash
# Fails unless every compiled main and test class is Java 26 bytecode (class-file major version 70).
# Run after ./gradlew build, from the repo root.
# On the spring stack (kit key `stack`, env KIT_STACK) the Java version is the build's toolchain
# (JavaLanguageVersion.of(N) in build.gradle.kts, buildSrc or build-logic), else kit key java_version: the class files
# must be major N + 44. The quarkus stack keeps Java 26.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }
want=70
if [ "$(kit_get stack quarkus KIT_STACK)" = spring ]; then
  java="$(grep -rhoE 'JavaLanguageVersion\.of\([0-9]+\)' build.gradle.kts buildSrc build-logic 2>/dev/null | head -1 | tr -dc '0-9')" || true
  [ -n "$java" ] || java="$(kit_get java_version "" KIT_JAVA_VERSION)"
  [ -n "$java" ] || { echo "FAIL: no Java version: the build names no JavaLanguageVersion.of(N) and kit key java_version is unset"; exit 1; }
  want=$((java + 44))
fi
count=0; bad=0
while IFS= read -r -d '' f; do
  count=$((count+1))
  major=$(od -An -t u1 -j 6 -N 2 "$f" | awk '{print $1*256+$2}')
  if [ "$major" -ne "$want" ]; then echo "FAIL: $f is major $major, want $want"; bad=$((bad+1)); fi
done < <(find . -path '*/build/classes/java/*' \( -path '*/java/main/*' -o -path '*/java/test/*' \) -name '*.class' -print0)
[ "$count" -gt 0 ] || { echo "FAIL: no compiled classes found, run ./gradlew build first"; exit 1; }
echo "class-version: $count classes checked, $bad wrong"
[ "$bad" -eq 0 ]
