#!/usr/bin/env bash
# Checks a built image against the container contract of TASK-1.3 (docs/memory.md, 2026-10-17):
# Dockerfile stages, fast-jar under /app on a Java 26 JRE, uid/gid 10001, JAVA_OPTS, port, entrypoint, health check,
# and a running container next to a database.
# Usage: image-check.sh <image>
# IMAGE_CHECK_PORT (default 18080) is the host port of the running container and IMAGE_CHECK_NAME (default
# wedding-image-check) the prefix of its container and network names, <prefix>-<pid>: the local CI passes its own per
# run (owner decision D18), so two runs side by side never share a port or a name.
# The stack (kit key `stack`, env KIT_STACK, default quarkus) picks the app's part of the contract; the rest (stages,
# JRE without javac, uid/gid 10001, JAVA_OPTS, port 8080, health-check timings, PID 1, a database next to it) is the same.
#   quarkus: :application:quarkusBuild, the fast-jar under /app, Java 26, /api/health with the fixture body,
#            QUARKUS_DATASOURCE_* and the ops/throttle settings.
#   spring:  :application:bootJar, the exploded boot jar under /app (BOOT-INF/, the loader) run by JarLauncher, the Java
#            version of the build's toolchain (JavaLanguageVersion.of(N) beside the Dockerfile, else kit key java_version),
#            /actuator/health answering status UP, SPRING_DATASOURCE_*. It has no app settings of its own to pass.
set -euo pipefail

# Git Bash would rewrite /app/... arguments passed to docker.
export MSYS_NO_PATHCONV=1

[ $# -eq 1 ] || { echo "usage: image-check.sh <image>" >&2; exit 2; }
image="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dockerfile="${DOCKERFILE:-$repo_root/Dockerfile}"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$repo_root/.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }
stack="$(kit_get stack quarkus KIT_STACK)"
polls="${IMAGE_CHECK_POLLS:-60}"
interval="${IMAGE_CHECK_INTERVAL:-2}"
port="${IMAGE_CHECK_PORT:-18080}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect() { # <what> <expected> <actual>
  if [[ "$2" != "$3" ]]; then
    fail "$1: expected '$2' but was '$3'"
  fi
}

if [[ "$stack" == spring ]]; then
  # The build beside the Dockerfile (its context) names the toolchain; kit key java_version only when it names none.
  build_dir="$(dirname "$dockerfile")"
  java="$(grep -rhoE 'JavaLanguageVersion\.of\([0-9]+\)' "$build_dir/build.gradle.kts" "$build_dir/buildSrc" \
    "$build_dir/build-logic" 2>/dev/null | head -1 | tr -dc '0-9')" || true
  [[ -n "$java" ]] || java="$(kit_get java_version "" KIT_JAVA_VERSION)"
  [[ -n "$java" ]] || fail "no Java version: the build names no JavaLanguageVersion.of(N) and kit key java_version is unset"
  app_build=':application:bootJar'
  skips='-x test -x integrationTest'
  skips_what='test and integrationTest'
  layout='test -d /app/BOOT-INF/lib && test -d /app/BOOT-INF/classes && test -d /app/org/springframework/boot/loader'
  layout_what='the exploded boot jar (BOOT-INF/lib/, BOOT-INF/classes/, org/springframework/boot/loader/)'
  entrypoint='["sh","-c","exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]'
  health_path=/actuator/health
else
  java=26
  app_build=':application:quarkusBuild'
  skips='-x test -x integrationTest -x startupTest'
  skips_what='test, integrationTest and startupTest'
  layout='test -f /app/quarkus-run.jar && test -d /app/lib && test -d /app/app && test -d /app/quarkus'
  layout_what='quarkus-run.jar, lib/, app/ and quarkus/'
  entrypoint='["sh","-c","exec java $JAVA_OPTS -jar /app/quarkus-run.jar"]'
  health_path=/api/health
fi

echo "Check: Dockerfile stages"
[ -f "$dockerfile" ] || fail "Dockerfile $dockerfile not found"
grep -qx "FROM eclipse-temurin:$java-jdk AS build" "$dockerfile" || fail "build stage is not 'FROM eclipse-temurin:$java-jdk AS build'"
grep -qF -- "./gradlew --no-daemon $app_build $skips" "$dockerfile" \
  || fail "the Gradle build does not skip $skips_what"
# On the Gradle build line itself: the flag in a comment reaches no build.
grep -F -- "./gradlew --no-daemon $app_build" "$dockerfile" | grep -v '^[[:space:]]*#' \
  | grep -qF -e '-Pcontract.spec=contract/dist/openapi.yaml' \
  || fail "the Gradle build does not pass -Pcontract.spec=contract/dist/openapi.yaml"
tr -d '\r' < "$(dirname "$dockerfile")/.dockerignore" 2>/dev/null | grep -qxF '!contract/dist/openapi.yaml' \
  || fail ".dockerignore does not let in contract/dist/openapi.yaml"
grep -qx "FROM eclipse-temurin:$java-jre AS runtime" "$dockerfile" || fail "runtime stage is not 'FROM eclipse-temurin:$java-jre AS runtime'"

config="$(docker image inspect "$image" --format '{{json .Config}}')" || fail "image $image not found"
cfg() { jq -c "$1" <<<"$config"; }

if [[ "$stack" == spring ]]; then echo "Check: boot-jar layout under /app"; else echo "Check: fast-jar layout under /app"; fi
docker run --rm --entrypoint sh "$image" -c "$layout" || fail "/app does not hold $layout_what"

echo "Check: Java $java JRE"
java_version="$(docker run --rm --entrypoint java "$image" -version 2>&1)" || true
[[ "$java_version" == *"version \"$java"* ]] || fail "java -version does not contain 'version \"$java': $java_version"
docker run --rm --entrypoint sh "$image" -c 'test ! -e /opt/java/openjdk/bin/javac' || fail "the image ships javac (a JDK, not a JRE)"

echo "Check: image configuration"
expect "Config.User" '"10001:10001"' "$(cfg '.User')"
expect "JAVA_OPTS in Config.Env" 'true' \
  "$(cfg '(.Env // []) | index("JAVA_OPTS=-XX:MaxRAMPercentage=70 -Duser.timezone=UTC") != null')"
expect "8080/tcp in Config.ExposedPorts" 'true' "$(cfg '(.ExposedPorts // {}) | has("8080/tcp")')"
expect "Config.Entrypoint" \
  "$entrypoint" "$(cfg '.Entrypoint')"
expect "Healthcheck.Test" \
  "[\"CMD-SHELL\",\"curl -fsS --max-time 3 http://127.0.0.1:8080$health_path || exit 1\"]" \
  "$(cfg '.Healthcheck.Test')"
expect "Healthcheck.Interval" '30000000000' "$(cfg '.Healthcheck.Interval')"
expect "Healthcheck.Timeout" '5000000000' "$(cfg '.Healthcheck.Timeout')"
expect "Healthcheck.StartPeriod" '40000000000' "$(cfg '.Healthcheck.StartPeriod')"
expect "Healthcheck.Retries" '3' "$(cfg '.Healthcheck.Retries')"

echo "Check: running container"
# Flyway migrates at start, so the image cannot start without a database: run a throwaway postgres next to it.
run_id="${IMAGE_CHECK_NAME:-wedding-image-check}-$$"
network="$run_id"
db_container=""
container=""
workdir="$(mktemp -d)"
cleanup() {
  status=$?
  if [[ $status -ne 0 && -n "$container" ]]; then
    docker logs "$container" >&2 || true
  fi
  [[ -z "$container" ]] || docker rm -f "$container" >/dev/null 2>&1 || true
  [[ -z "$db_container" ]] || docker rm -f "$db_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$workdir"
  exit $status
}
trap cleanup EXIT

db_user="wedding_portal"
db_name="wedding_portal"
db_password="$(openssl rand -hex 16)"
docker network create "$network" >/dev/null
db_container="$(docker run -d --network "$network" --name "$run_id-db" \
  -e POSTGRES_DB="$db_name" -e POSTGRES_USER="$db_user" -e POSTGRES_PASSWORD="$db_password" \
  postgres:18.6-alpine)"
# Over TCP: during initdb the entrypoint runs a temporary server on the socket only, which must not count as ready.
db_ready=""
for _ in $(seq 1 30); do
  if docker exec "$db_container" pg_isready -h 127.0.0.1 -U "$db_user" -d "$db_name" >/dev/null 2>&1; then
    db_ready=yes
    break
  fi
  sleep "$interval"
done
[[ -n "$db_ready" ]] || fail "postgres did not become ready"

if [[ "$stack" == spring ]]; then
container="$(docker run -d --network "$network" -p "127.0.0.1:$port:8080" \
  -e SPRING_DATASOURCE_URL="jdbc:postgresql://$run_id-db:5432/$db_name" \
  -e SPRING_DATASOURCE_USERNAME="$db_user" -e SPRING_DATASOURCE_PASSWORD="$db_password" "$image")"
else
container="$(docker run -d --network "$network" -p "127.0.0.1:$port:8080" \
  -e QUARKUS_DATASOURCE_JDBC_URL="jdbc:postgresql://$run_id-db:5432/$db_name" \
  -e QUARKUS_DATASOURCE_USERNAME="$db_user" -e QUARKUS_DATASOURCE_PASSWORD="$db_password"   -e WEDDING_OPS_USERNAME="ops" -e WEDDING_OPS_PASSWORD="$(openssl rand -hex 16)" \
  -e WEDDING_THROTTLE_SERVER_KEY="$(openssl rand -base64 32)" "$image")"
fi

health=""
for _ in $(seq 1 "$polls"); do
  running="$(docker inspect --format '{{.State.Running}}' "$container")"
  [[ "$running" == "true" ]] || fail "container exited before becoming healthy"
  health="$(docker inspect --format '{{.State.Health.Status}}' "$container")"
  [[ "$health" != "unhealthy" ]] || fail "container became unhealthy"
  [[ "$health" != "healthy" ]] || break
  sleep "$interval"
done
expect "health status" "healthy" "$health"

expect "name of PID 1" "java" "$(docker exec "$container" cat /proc/1/comm)"
expect "uid of PID 1" "10001" "$(docker exec "$container" stat -c %u /proc/1)"
expect "gid of PID 1" "10001" "$(docker exec "$container" stat -c %g /proc/1)"

# Relative output path from inside workdir: a native curl.exe cannot write the /tmp/... form (Git Bash).
code="$(cd "$workdir" && curl -sS -o body -w '%{http_code}' "http://127.0.0.1:$port$health_path")"
expect "GET $health_path status" "200" "$code"
if [[ "$stack" == spring ]]; then
  expect "GET $health_path status field" "UP" "$(jq -r '.status // empty' <"$workdir/body" 2>/dev/null || true)"
else
  expected_body="$(jq -r .body <"$repo_root/shared-adapter/src/test/resources/fixtures/health-200.json")"
  expect "GET /api/health body" "$expected_body" "$(cat "$workdir/body")"
fi

echo "OK: $image"
