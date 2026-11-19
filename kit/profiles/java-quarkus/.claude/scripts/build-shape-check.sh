#!/usr/bin/env bash
# Checks the build's shape: the CI task names exist, only the application module applies the Quarkus plugin,
# every usecase, adapter and gateway module is a bean archive, the fast-jar layout is produced, and no Python or
# rekord-api remnant is back. Run after ./gradlew build.
set -uo pipefail
fail=0
bad() { echo "FAIL: $1"; fail=1; }

for t in test integrationTest build :application:quarkusBuild; do
  ./gradlew -q help --task "$t" >/dev/null 2>&1 || bad "task $t does not exist"
done

mods=$(grep -oE '"[a-z-]+"' settings.gradle.kts | grep -v '"wedding-portal"' | tr -d '"' | sort | paste -sd' ' -)
[ "$mods" = "application identity-adapter identity-domain identity-usecase library-adapter library-domain library-usecase logging matching-adapter matching-domain matching-usecase musicfolder-gateway pdf-gateway planning-adapter planning-domain planning-usecase portal-adapter portal-domain portal-usecase shared-adapter shared-domain shared-usecase spotify-gateway" ] \
  || bad "settings.gradle.kts must include exactly the 23 modules (shared-domain, shared-usecase, shared-adapter, five context triads, spotify-gateway, musicfolder-gateway, pdf-gateway, application, logging), found: $mods"
own=$(grep -nE '"io\.quarkus[^"]*:[^":]+:[^"]+"' build.gradle.kts */build.gradle.kts 2>/dev/null | paste -sd' ' -)
[ -z "$own" ] || bad "a module names a Quarkus version of its own: $own"
grep -q 'UD-17' docs/memory.md || bad "docs/memory.md does not name the executor (UD-17)"

# Only application builds a Quarkus app. Another module may apply the plugin for @QuarkusTest, with its app build off;
# the root build may only put it on the classpath (apply false).
qplugin='id\("io\.quarkus"\)|alias\(libs\.plugins\.quarkus\)'
grep -qE "$qplugin" application/build.gradle.kts || bad "application must apply the Quarkus plugin"
for f in $(grep -lE "$qplugin" */build.gradle.kts 2>/dev/null); do
  [ "$f" = application/build.gradle.kts ] && continue
  grep -q '"quarkusBuild"' "$f" && grep -q 'enabled = false' "$f" ||
    bad "$f applies the Quarkus plugin without turning its quarkusBuild off; only application builds an app"
done
! grep -E "$qplugin" build.gradle.kts | grep -qv 'apply false' || bad "the root build may apply the Quarkus plugin only with apply false"
# Quarkus finds a library module's beans only when its jar is a bean archive (META-INF/beans.xml); the usecase modules
# have no probe bean that would show a missing file at test time.
nobeans=$(for m in *-usecase *-adapter *-gateway; do [ -f "$m/src/main/resources/META-INF/beans.xml" ] || echo "$m"; done | paste -sd' ' -)
[ -z "$nobeans" ] || bad "every usecase, adapter and gateway module must ship src/main/resources/META-INF/beans.xml, missing in: $nobeans"

app=application/build/quarkus-app
[ -f "$app/quarkus-run.jar" ] || bad "$app/quarkus-run.jar missing"
for d in lib app quarkus; do [ -d "$app/$d" ] || bad "$app/$d/ missing"; done

py=$(git ls-files '*.py' | paste -sd' ' -)
[ -z "$py" ] || bad "tracked Python files: $py"
grep -qiE '(^|[[:space:]-])(python[0-9.]*|pip[0-9]*|actions/setup-python)([[:space:]@]|$)' .github/workflows/*.yml \
  && bad "a workflow step runs Python"
api=$(grep -l 'rekord-api' settings.gradle.kts build.gradle.kts */build.gradle.kts gradle/libs.versions.toml .github/workflows/*.yml 2>/dev/null | paste -sd' ' -)
[ -z "$api" ] || bad "rekord-api referenced in: $api"

[ "$fail" -eq 0 ] && echo "build-shape: ok"
exit $fail
