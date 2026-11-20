#!/usr/bin/env bash
# Tests .claude/scripts/class-version-check.sh: every compiled main and test class is the
# bytecode of the build's toolchain (JavaLanguageVersion.of(N) in build.gradle.kts, buildSrc/ or build-logic/, else kit
# key java_version), class-file major N + 44. Each case writes class files of a chosen major into a throwaway root.
# Usage: bash scripts/test/class-version-check.test.sh   (exit 0 = all pass)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/.claude/scripts/class-version-check.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }
# No project or machine kit.yaml is read.
export KIT_CONFIG="$tmp/none/kit.yaml"
unset KIT_JAVA_VERSION

n=0
project() { d="$tmp/p$((++n))"; mkdir -p "$d"; cd "$d" || exit 1; }
run() { out="$(bash "$script" 2>&1)"; rc=$?; }
class() { # class <path> <major>: a class file header (magic, minor 0, major)
  mkdir -p "$(dirname "$1")"
  printf "\\xca\\xfe\\xba\\xbe\\x00\\x00\\x$(printf '%02x' $(($2 / 256)))\\x$(printf '%02x' $(($2 % 256)))" > "$1"
}
toolchain() { printf 'java {\n    toolchain {\n        languageVersion = JavaLanguageVersion.of(%s)\n    }\n}\n' "$2" > "$1"; }

project; toolchain build.gradle.kts 21
class app/build/classes/java/main/com/acme/App.class 65; class app/build/classes/java/test/com/acme/AppTest.class 65; run
check "1 Java 21 toolchain, major 65 main and test classes pass" "$([ "$rc" -eq 0 ] && said 'class-version: 2 classes checked, 0 wrong'; echo $?)"
class order-domain/build/classes/java/main/com/acme/Order.class 61; run
check "1 one class of another major fails and is named" "$([ "$rc" -eq 1 ] \
  && said 'FAIL: ./order-domain/build/classes/java/main/com/acme/Order.class is major 61, want 65' && said '3 classes checked, 1 wrong'; echo $?)"

project; mkdir -p build-logic/src/main/kotlin; toolchain build-logic/src/main/kotlin/java-conventions.gradle.kts 25
echo 'plugins { id("java-conventions") }' > build.gradle.kts; class app/build/classes/java/main/A.class 69; run
check "2 a toolchain in a build-logic convention plugin counts" "$([ "$rc" -eq 0 ] && said '1 classes checked, 0 wrong'; echo $?)"
project; mkdir -p buildSrc/src/main/kotlin; toolchain buildSrc/src/main/kotlin/conventions.gradle.kts 26
class app/build/classes/java/main/A.class 70; run
check "2 a toolchain under buildSrc/ counts" "$([ "$rc" -eq 0 ]; echo $?)"

project; echo 'plugins { java }' > build.gradle.kts; class app/build/classes/java/main/A.class 66
KIT_JAVA_VERSION=22 run
check "3 no toolchain in the build: kit key java_version" "$([ "$rc" -eq 0 ] && said '1 classes checked'; echo $?)"
run
check "3 no toolchain and no java_version fails and says so" "$([ "$rc" -eq 1 ] && said 'FAIL: no Java version'; echo $?)"

project; toolchain build.gradle.kts 21; run
check "4 no compiled classes fails: run the build first" "$([ "$rc" -eq 1 ] && said 'FAIL: no compiled classes found'; echo $?)"
class app/build/classes/kotlin/main/K.class 52; class app/build/classes/java/main/A.class 65
class app/build/classes/java/jmh/B.class 52; class app/out/A.class 52; run
check "4 only java main and test output is read" "$([ "$rc" -eq 0 ] && said '1 classes checked, 0 wrong'; echo $?)"

cd "$tmp" || exit 1
echo "class-version-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
