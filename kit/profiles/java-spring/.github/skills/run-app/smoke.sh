#!/usr/bin/env bash
# Starts a Spring Boot app with `./gradlew bootRun` in the background, waits until its actuator health answers UP,
# checks it over HTTP and in its local database, and stops it cleanly. A running instance on the port is reused.
#   smoke.sh [up|start|check|stop|status]     (default: up = start, then check)
# Settings, each from the environment first, then from a `key: value` line in docs/code-maps/run-app.md, then the
# default: APP_MODULE (application), PORT (8080), HEALTH_PATH (/actuator/health), COMPOSE_FILE (compose.yaml),
# DB_SERVICE (postgres), DB_USER and DB_NAME (read from the compose service when unset), STATE_DIR (pid and log;
# ${TMPDIR:-/tmp}/run-app-<repo>), START_TIMEOUT seconds (300), EXTRA_CHECKS (a file of `<status> <path> [regex]`
# lines checked after health).
# Exits 0 when every step passed, 1 otherwise; each check prints one PASS or FAIL line.
set -uo pipefail

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
facts="$root/docs/code-maps/run-app.md"

setting() { # setting <NAME> <default>: env, then the code map's `NAME: value` line, then the default
  local name=$1 fallback=$2 value="${!1:-}"
  if [ -z "$value" ] && [ -f "$facts" ]; then
    value="$(grep -m1 -E "^[-* ]*\`?$name\`?[[:space:]]*[:=]" "$facts" | sed -E "s/^[^:=]*[:=][[:space:]]*//; s/^\`//; s/\`[[:space:]]*$//")"
  fi
  printf '%s' "${value:-$fallback}"
}

module="$(setting APP_MODULE application)"
port="$(setting PORT 8080)"
health="$(setting HEALTH_PATH /actuator/health)"
compose="$root/$(setting COMPOSE_FILE compose.yaml)"
db_service="$(setting DB_SERVICE postgres)"
extra="$(setting EXTRA_CHECKS '')"
timeout="$(setting START_TIMEOUT 300)"
state="$(setting STATE_DIR "${TMPDIR:-/tmp}/run-app-$(basename "$root")")"
log="$state/app.log"
base="http://localhost:$port"
mkdir -p "$state"

up() { curl -s --max-time 2 "$base$health" | grep -q '"status" *: *"UP"'; }
answers() { curl -s -o /dev/null --max-time 2 "$base$health"; }
listener() { ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }
compose_cmd() { docker compose -f "$compose" "$@"; }

# spring-boot-docker-compose on the module's classpath starts the compose file itself; without it, the script does.
uses_boot_compose() { grep -qs 'spring-boot-docker-compose' "$root/$module/build.gradle.kts" "$root/$module/build.gradle"; }

ensure_database() {
  [ -f "$compose" ] || { echo "OK: no $compose, so no local database to start"; return 0; }
  if uses_boot_compose; then echo "OK: bootRun starts $compose (spring-boot-docker-compose)"; return 0; fi
  compose_cmd up -d --wait >/dev/null 2>&1 || { echo "FAIL: docker compose up --wait on $compose"; return 1; }
  echo "OK: $compose is up"
}

start() {
  if answers; then echo "OK: already running at $base (pid $(listener))"; return 0; fi
  ensure_database || return 1
  # SERVER_PORT is Spring's relaxed binding of server.port, so the app listens where the checks look.
  (cd "$root" && SERVER_PORT="$port" exec nohup ./gradlew ":$module:bootRun" --console=plain > "$log" 2>&1 < /dev/null) &
  echo $! > "$state/gradle.pid"
  echo "starting (log $log) ..."
  local deadline=$(( SECONDS + timeout ))
  while [ $SECONDS -lt $deadline ]; do
    if up; then echo "OK: UP at $base after ${SECONDS}s"; return 0; fi
    if grep -qE 'BUILD FAILED|APPLICATION FAILED TO START|Application run failed' "$log"; then
      echo "FAIL: start-up failed; the cause:"
      grep -A8 -E 'What went wrong|APPLICATION FAILED TO START|Application run failed' "$log" | head -24; return 1
    fi
    kill -0 "$(cat "$state/gradle.pid")" 2>/dev/null || { echo "FAIL: gradle exited; tail of $log:"; tail -20 "$log"; return 1; }
    sleep 2
  done
  echo "FAIL: not UP after ${timeout}s; tail of $log:"; tail -20 "$log"; return 1
}

fails=0
expect() { # expect <label> <status> <body-regex|-> <curl args...>
  local label=$1 want=$2 re=$3; shift 3
  local body code
  body="$(curl -s --max-time 10 -w '\n%{http_code}' "$@")"
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [ "$code" = "$want" ] && { [ "$re" = - ] || grep -qE "$re" <<<"$body"; }; then
    echo "PASS $label: $code"
  else
    echo "FAIL $label: got $code, want $want${re:+ matching $re}: $(head -c 200 <<<"$body")"; fails=$((fails + 1))
  fi
}

compose_env() { # compose_env <VAR>: the database service's environment value from the resolved compose file
  compose_cmd config --format json 2>/dev/null \
    | python3 -c "import json,sys; e=json.load(sys.stdin)['services']['$db_service'].get('environment') or {}; print(e.get('$1',''))" 2>/dev/null
}

check_database() { # Flyway's history shows which migrations ran
  [ -f "$compose" ] || return 0
  local db user name hist
  db="$(compose_cmd ps -q "$db_service" 2>/dev/null | head -1)"
  if [ -z "$db" ]; then echo "FAIL database: no running '$db_service' service in $compose"; fails=$((fails + 1)); return; fi
  user="$(setting DB_USER "$(compose_env POSTGRES_USER)")"; user="${user:-postgres}"
  name="$(setting DB_NAME "$(compose_env POSTGRES_DB)")"; name="${name:-$user}"
  hist="$(docker exec "$db" psql -U "$user" -d "$name" -tAc \
    "select coalesce(version, 'R') || ' ' || description || ' ' || success from flyway_schema_history order by installed_rank" 2>&1)"
  if grep -q ' t$\| true$' <<<"$hist" && ! grep -q ' f$\| false$' <<<"$hist"; then
    echo "PASS database $db_service: flyway history"; sed 's/^/       /' <<<"$hist"
  else
    echo "FAIL database $db_service: $hist"; fails=$((fails + 1))
  fi
}

check() {
  answers || { echo "FAIL: nothing answers at $base; run: smoke.sh start"; return 1; }
  expect "GET $health"           200 '"status" *: *"UP"' "$base$health"
  expect "GET $health/liveness"  200 '"status" *: *"UP"' "$base$health/liveness"
  expect "GET $health/readiness" 200 '"status" *: *"UP"' "$base$health/readiness"
  if [ -n "$extra" ] && [ -f "$root/$extra" ]; then
    while read -r want path re; do
      case "$want" in ''|\#*) continue ;; esac
      expect "GET $path" "$want" "${re:--}" "$base$path"
    done < "$root/$extra"
  fi
  check_database
  [ "$fails" -eq 0 ]
}

stop() { # SIGTERM to the app's JVM (the port's listener) first: Spring shuts down gracefully, then the gradle client ends
  local pid; pid="$(listener)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  for _ in $(seq 1 30); do answers || break; sleep 1; done
  [ -f "$state/gradle.pid" ] && kill "$(cat "$state/gradle.pid")" 2>/dev/null
  rm -f "$state/gradle.pid"
  if answers; then echo "FAIL: still answering at $base"; return 1; fi
  if grep -qE 'Graceful shutdown complete|Commencing graceful shutdown' "$log" 2>/dev/null; then
    echo "OK: stopped (graceful shutdown)"
  else
    echo "OK: stopped"
  fi
  # The compose database stays up for the next start (spring-boot-docker-compose start-only, or our own up);
  # `docker compose -f <file> down` ends it.
}

case "${1:-up}" in
  up)     start && check ;;
  start)  start ;;
  check)  check ;;
  stop)   stop ;;
  status) if answers; then echo "running at $base (pid $(listener))"; else echo "stopped"; fi ;;
  *)      echo "usage: smoke.sh [up|start|check|stop|status]" >&2; exit 2 ;;
esac
