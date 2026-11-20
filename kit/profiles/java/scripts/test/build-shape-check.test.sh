#!/usr/bin/env bash
# Tests .claude/scripts/build-shape-check.sh on the spring stack: the CI tasks exist, only application builds a boot
# jar, no module pins a Spring Boot version of its own, every usecase, adapter and gateway package lies inside the
# @SpringBootApplication's component scan, the boot jar has the loader layout, no Python is back, and the kit keys under
# build_shape (modules, memory_marker, forbidden) hold, "-" turning one off with a notice. Each case copies a small
# project that passes, breaks one thing, and checks the exit code and the FAIL line. ./gradlew is a stub.
# Usage: bash scripts/test/build-shape-check.test.sh   (exit 0 = all pass; needs zip and unzip)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/.claude/scripts/build-shape-check.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
said() { grep -qF -- "$1" <<< "$out"; }
command -v zip >/dev/null && command -v unzip >/dev/null || { echo "build-shape-check: needs zip and unzip"; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# The stack is set, not the script's default; no project or machine kit.yaml is read.
export KIT_STACK=spring KIT_CONFIG="$tmp/none/kit.yaml"
unset KIT_BUILD_SHAPE_MODULES KIT_BUILD_SHAPE_MEMORY_MARKER KIT_BUILD_SHAPE_FORBIDDEN

# The project that passes: application with the boot plugin and the boot jar, one usecase module inside the scan.
tpl="$tmp/tpl"
mkdir -p "$tpl/application/src/main/java/com/acme" "$tpl/order-usecase/src/main/java/com/acme/order" \
  "$tpl/application/build/libs" "$tpl/.github/workflows" "$tpl/docs" "$tpl/jar/BOOT-INF/lib" "$tpl/jar/BOOT-INF/classes" \
  "$tpl/jar/org/springframework/boot/loader"
# The stub answers `help --task <t>` for the tasks it knows (MISSING_TASK takes one away).
cat > "$tpl/gradlew" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2 $3" = "-q help --task" ] || exit 1
case "$4" in "${MISSING_TASK:-}") exit 1 ;; test | integrationTest | build | :application:bootJar) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$tpl/gradlew"
printf 'rootProject.name = "shop"\ninclude("application", "order-usecase")\n' > "$tpl/settings.gradle.kts"
printf 'plugins {\n    id("org.springframework.boot") version "3.5.7" apply false\n}\n' > "$tpl/build.gradle.kts"
printf 'plugins {\n    id("org.springframework.boot")\n}\n' > "$tpl/application/build.gradle.kts"
printf 'plugins { java }\ndependencies { implementation("org.springframework:spring-context") }\n' > "$tpl/order-usecase/build.gradle.kts"
printf 'package com.acme;\n\n@SpringBootApplication\npublic class ShopApplication {}\n' > "$tpl/application/src/main/java/com/acme/ShopApplication.java"
printf 'package com.acme.order;\n\npublic class PlaceOrder {}\n' > "$tpl/order-usecase/src/main/java/com/acme/order/PlaceOrder.java"
printf 'on:\n  workflow_dispatch:\njobs:\n  test:\n    steps:\n      - run: ./gradlew build\n' > "$tpl/.github/workflows/ci.yml"
printf '# Memory\n\n- D7: one boot jar, in application.\n' > "$tpl/docs/memory.md"
touch "$tpl/jar/BOOT-INF/lib/x.jar" "$tpl/jar/BOOT-INF/classes/A.class" "$tpl/jar/org/springframework/boot/loader/L.class"
(cd "$tpl/jar" && zip -qr ../application/build/libs/shop.jar . && zip -qr ../application/build/libs/shop-plain.jar BOOT-INF/classes)
rm -rf "$tpl/jar"
git -C "$tpl" init -q -b main && git -C "$tpl" add -A && git -C "$tpl" commit -qm base

n=0
project() { d="$tmp/p$((++n))"; cp -r "$tpl" "$d"; cd "$d" || exit 1; }
run() { out="$(bash "$script" 2>&1)"; rc=$?; }

# 1. The project as it is.
project; run
check "1 the spring project passes, each check that is - says it is off" "$([ "$rc" -eq 0 ] && said 'build-shape: ok' \
  && said 'no module-list check (kit key build_shape.modules is -)' && said 'no decision-note check' && said 'no remnant check'; echo $?)"

# 2. The CI tasks.
project; MISSING_TASK=integrationTest run
check "2 a CI task that does not exist fails" "$([ "$rc" -eq 1 ] && said 'FAIL: task integrationTest does not exist'; echo $?)"
project; MISSING_TASK=:application:bootJar run
check "2 no :application:bootJar fails" "$([ "$rc" -eq 1 ] && said 'FAIL: task :application:bootJar does not exist'; echo $?)"

# 3. The kit keys under build_shape.
project; KIT_BUILD_SHAPE_MODULES="order-usecase application" run
check "3 build_shape.modules equal to settings.gradle.kts passes, in any order" "$([ "$rc" -eq 0 ]; echo $?)"
KIT_BUILD_SHAPE_MODULES="application order-usecase order-adapter" run
check "3 build_shape.modules other than settings.gradle.kts fails" "$([ "$rc" -eq 1 ] \
  && said 'must include exactly the modules kit key build_shape.modules names (application order-adapter order-usecase), found: application order-usecase'; echo $?)"
KIT_BUILD_SHAPE_MEMORY_MARKER=D7 run
check "3 build_shape.memory_marker named in docs/memory.md passes" "$([ "$rc" -eq 0 ]; echo $?)"
KIT_BUILD_SHAPE_MEMORY_MARKER=D9 run
check "3 build_shape.memory_marker missing from docs/memory.md fails" "$([ "$rc" -eq 1 ] \
  && said 'docs/memory.md does not name D9 (kit key build_shape.memory_marker)'; echo $?)"
echo 'implementation("io.quarkus:quarkus-core")' >> order-usecase/build.gradle.kts; KIT_BUILD_SHAPE_FORBIDDEN=io.quarkus run
check "3 the build_shape.forbidden remnant in a build file fails" "$([ "$rc" -eq 1 ] \
  && said 'io.quarkus referenced in: order-usecase/build.gradle.kts'; echo $?)"

# 4. The Spring Boot plugin and version.
project; echo 'dependencies { implementation("org.springframework.boot:spring-boot-starter:3.4.0") }' >> order-usecase/build.gradle.kts; run
check "4 a module with a Spring Boot version of its own fails" "$([ "$rc" -eq 1 ] && said 'a module names a Spring Boot version of its own'; echo $?)"
project; printf 'plugins { java }\n' > application/build.gradle.kts; run
check "4 application without the plugin fails" "$([ "$rc" -eq 1 ] && said 'application must apply the Spring Boot plugin'; echo $?)"
project; printf 'plugins {\n    id("org.springframework.boot")\n}\n' > order-usecase/build.gradle.kts; run
check "4 another module with the plugin and its bootJar on fails" "$([ "$rc" -eq 1 ] \
  && said 'order-usecase/build.gradle.kts applies the Spring Boot plugin without turning its bootJar off'; echo $?)"
printf 'tasks.named("bootJar") { enabled = false }\n' >> order-usecase/build.gradle.kts; run
check "4 ... and passes with its bootJar off" "$([ "$rc" -eq 0 ]; echo $?)"
project; printf 'plugins {\n    id("org.springframework.boot") version "3.5.7"\n}\n' > build.gradle.kts; run
check "4 the root build applying the plugin fails" "$([ "$rc" -eq 1 ] && said 'the root build may apply the Spring Boot plugin only with apply false'; echo $?)"

# 5. The component scan.
project; mkdir -p order-usecase/src/main/java/org/other; printf 'package org.other;\nclass X {}\n' > order-usecase/src/main/java/org/other/X.java; run
check "5 a usecase package outside the scan fails and is named" "$([ "$rc" -eq 1 ] && said 'packages outside the component scan' \
  && said 'order-usecase:org.other'; echo $?)"
printf 'package com.acme;\n\n@SpringBootApplication(scanBasePackages = {"com.acme", "org.other"})\npublic class ShopApplication {}\n' \
  > application/src/main/java/com/acme/ShopApplication.java; run
check "5 ... and passes once scanBasePackages names it" "$([ "$rc" -eq 0 ]; echo $?)"
project; printf 'package com.acme;\npublic class ShopApplication {}\n' > application/src/main/java/com/acme/ShopApplication.java; run
check "5 no @SpringBootApplication fails" "$([ "$rc" -eq 1 ] && said 'no @SpringBootApplication class under application/src/main/java'; echo $?)"

# 6. The boot jar.
project; rm application/build/libs/shop.jar; run
check "6 only a -plain jar is no boot jar" "$([ "$rc" -eq 1 ] && said 'application/build/libs/<name>.jar missing (no boot jar)'; echo $?)"
project; zip -qd application/build/libs/shop.jar 'org/*' >/dev/null; run
check "6 a jar without the loader fails" "$([ "$rc" -eq 1 ] && said 'has no org/springframework/boot/loader/'; echo $?)"

# 7. No Python.
project; echo 'print(1)' > tool.py; git add tool.py; run
check "7 a tracked Python file fails" "$([ "$rc" -eq 1 ] && said 'tracked Python files: tool.py'; echo $?)"
project; printf '      - run: python3 tool.py\n' >> .github/workflows/ci.yml; run
check "7 a workflow step that runs Python fails" "$([ "$rc" -eq 1 ] && said 'a workflow step runs Python'; echo $?)"

cd "$tmp" || exit 1
echo "build-shape-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
