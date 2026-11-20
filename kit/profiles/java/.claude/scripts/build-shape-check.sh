#!/usr/bin/env bash
# Checks the build's shape: the CI task names exist, only the application module applies the Spring Boot plugin
# (bootJar), every usecase, adapter and gateway package lies inside the @SpringBootApplication's component scan, the
# boot jar has the loader layout, and no Python or forbidden remnant (kit key build_shape.forbidden) is back. Run after
# ./gradlew build. The project facts (the module list, the decision note, the forbidden remnant) are kit keys under
# build_shape with this repo's values as defaults; `-` turns one off, and the check then says so.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }
fail=0
bad() { echo "FAIL: $1"; fail=1; }

# The tasks are the ones CI runs, kit key ci.gradle_line (its words without ./gradlew and the options), and the boot
# jar's; with the key unset, test, integrationTest and build.
tasks="" skip=0
for w in $(kit_get ci.gradle_line "" KIT_CI_GRADLE_LINE); do
  [ "$skip" -eq 1 ] && { skip=0; continue; }
  case "$w" in -x | --exclude-task) skip=1 ;; ./gradlew | gradlew | gradle | -*) ;; *) tasks="$tasks $w" ;; esac
done
[ -n "$tasks" ] || tasks=" test integrationTest build"
for t in $tasks :application:bootJar; do
  ./gradlew -q help --task "$t" >/dev/null 2>&1 || bad "task $t does not exist"
done

default_mods="-"
want_mods="$(kit_get build_shape.modules "$default_mods" KIT_BUILD_SHAPE_MODULES)"
if [ "$want_mods" = - ]; then
  echo "build-shape: no module-list check (kit key build_shape.modules is -)"
else
  root_name="$(sed -nE 's/^rootProject\.name *= *"([^"]+)".*/\1/p' settings.gradle.kts | head -1)"
  mods=$(grep -oE '"[a-z-]+"' settings.gradle.kts | grep -vxF "\"${root_name:-}\"" | tr -d '"' | sort | paste -sd' ' -)
  want_mods="$(printf '%s\n' $want_mods | sort | paste -sd' ' -)"
  if [ "$want_mods" = "$default_mods" ]; then
    [ "$mods" = "$want_mods" ] \
      || bad "settings.gradle.kts must include exactly the 23 modules (shared-domain, shared-usecase, shared-adapter, five context triads, spotify-gateway, musicfolder-gateway, pdf-gateway, application, logging), found: $mods"
  else
    [ "$mods" = "$want_mods" ] \
      || bad "settings.gradle.kts must include exactly the modules kit key build_shape.modules names ($want_mods), found: $mods"
  fi
fi
own=$(grep -nE '"org\.springframework\.boot[^"]*:[^":]+:[^"]+"' build.gradle.kts */build.gradle.kts 2>/dev/null | paste -sd' ' -)
[ -z "$own" ] || bad "a module names a Spring Boot version of its own: $own"
marker="$(kit_get build_shape.memory_marker - KIT_BUILD_SHAPE_MEMORY_MARKER)"
if [ "$marker" = - ]; then
  echo "build-shape: no decision-note check (kit key build_shape.memory_marker is -)"
elif [ "$marker" = UD-17 ]; then
  grep -q 'UD-17' docs/memory.md || bad "docs/memory.md does not name the executor (UD-17)"
else
  grep -qF -- "$marker" docs/memory.md 2>/dev/null || bad "docs/memory.md does not name $marker (kit key build_shape.memory_marker)"
fi

# Only application builds a boot jar. Another module may apply the plugin, with its bootJar off; the root build may only
# put it on the classpath (apply false).
splugin='id\("org\.springframework\.boot"\)|alias\(libs\.plugins\.spring\.boot\)'
grep -qE "$splugin" application/build.gradle.kts || bad "application must apply the Spring Boot plugin"
for f in $(grep -lE "$splugin" */build.gradle.kts 2>/dev/null); do
  [ "$f" = application/build.gradle.kts ] && continue
  grep -q '"bootJar"' "$f" && grep -q 'enabled = false' "$f" ||
    bad "$f applies the Spring Boot plugin without turning its bootJar off; only application builds an app"
done
! grep -E "$splugin" build.gradle.kts | grep -qv 'apply false' || bad "the root build may apply the Spring Boot plugin only with apply false"
# Spring finds a module's beans only inside the component scan: every package of a usecase, adapter or gateway module
# lies under a scanBasePackages entry of the @SpringBootApplication (its own package when it names none).
boot=$(grep -rlE '^@SpringBootApplication' application/src/main/java 2>/dev/null | head -1)
if [ -z "$boot" ]; then
  bad "no @SpringBootApplication class under application/src/main/java"
else
  ann=$(tr '\n' ' ' <"$boot" | grep -oE '@SpringBootApplication *(\([^)]*\))?' | head -1)
  bases=$(grep -oE 'scanBasePackages *= *(\{[^}]*\}|"[^"]*")' <<<"$ann" | grep -oE '"[^"]+"' | tr -d '"')
  [ -n "$bases" ] || bases=$(sed -nE 's/^package +([a-zA-Z0-9_.]+);.*/\1/p' "$boot" | head -1)
  outside=$(for m in *-usecase *-adapter *-gateway; do
    [ -d "$m/src/main/java" ] || continue
    grep -rhoE '^package +[a-zA-Z0-9_.]+;' "$m/src/main/java" --include='*.java' | sed -E 's/^package +//; s/;$//' | sort -u |
      while IFS= read -r p; do
        hit=0
        for b in $bases; do case "$p" in "$b"|"$b".*) hit=1 ;; esac; done
        [ "$hit" -eq 1 ] || echo "$m:$p"
      done
  done | paste -sd' ' -)
  [ -z "$outside" ] || bad "packages outside the component scan of $boot ($(printf '%s ' $bases)): $outside"
fi

jar=$(ls application/build/libs/*.jar 2>/dev/null | grep -v -- '-plain\.jar$' | head -1)
if [ -z "$jar" ]; then
  bad "application/build/libs/<name>.jar missing (no boot jar)"
elif ! command -v unzip >/dev/null 2>&1; then
  bad "unzip is not installed: cannot read the layout of $jar"
else
  entries=$(unzip -Z1 "$jar" 2>/dev/null)
  for d in BOOT-INF/lib/ BOOT-INF/classes/ org/springframework/boot/loader/; do
    grep -q "^$d" <<<"$entries" || bad "$jar has no $d"
  done
fi

py=$(git ls-files '*.py' | paste -sd' ' -)
[ -z "$py" ] || bad "tracked Python files: $py"
grep -qiE '(^|[[:space:]-])(python[0-9.]*|pip[0-9]*|actions/setup-python)([[:space:]@]|$)' .github/workflows/*.yml \
  && bad "a workflow step runs Python"
forbidden="$(kit_get build_shape.forbidden - KIT_BUILD_SHAPE_FORBIDDEN)"
if [ "$forbidden" = - ]; then
  echo "build-shape: no remnant check (kit key build_shape.forbidden is -)"
else
  api=$(grep -lF -- "$forbidden" settings.gradle.kts build.gradle.kts */build.gradle.kts gradle/libs.versions.toml .github/workflows/*.yml 2>/dev/null | paste -sd' ' -)
  [ -z "$api" ] || bad "$forbidden referenced in: $api"
fi

[ "$fail" -eq 0 ] && echo "build-shape: ok"
exit $fail
