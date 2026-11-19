#!/usr/bin/env bash
# Starts the backend in Quarkus dev mode in the background, waits until it answers, and checks it over HTTP and in its
# dev database. A running instance on the port is reused, never restarted.
#   smoke.sh [up|start|check|stop|status]     (default: up = start, then check)
# Overrides: PORT (8080), STATE_DIR (pid and log; default ${TMPDIR:-/tmp}/run-app),
# WEDDING_OPS_USERNAME / WEDDING_OPS_PASSWORD (default ops / local-dev-only: a throwaway local pair, never a real one),
# START_TIMEOUT seconds (300).
# Exits 0 when every step passed, 1 otherwise; each check prints one PASS or FAIL line.
set -uo pipefail

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
port="${PORT:-8080}"
state="${STATE_DIR:-${TMPDIR:-/tmp}/run-app}"
log="$state/app.log"
base="http://localhost:$port"
export WEDDING_OPS_USERNAME="${WEDDING_OPS_USERNAME:-ops}"
export WEDDING_OPS_PASSWORD="${WEDDING_OPS_PASSWORD:-local-dev-only}"
mkdir -p "$state"

up() { curl -s -o /dev/null --max-time 2 "$base/api/health"; }
listener() { ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }

ensure_contract() { # the build generates the API from contract/dist/openapi.yaml, at the tag gradle.properties pins
  if [ ! -d "$root/contract/.git" ]; then
    git clone -q https://github.com/@@KIT_CONTRACT_REPO@@.git "$root/contract" || { echo "FAIL: clone rekord-contract into contract/"; return 1; }
  fi
  bash "$root/.claude/scripts/contract-pin.sh" "$root/contract"
}

start() {
  if up; then echo "OK: already running at $base (pid $(listener))"; return 0; fi
  ensure_contract || return 1
  (cd "$root" && exec nohup ./gradlew :application:quarkusDev -Dquarkus.console.enabled=false --console=plain \
     > "$log" 2>&1 < /dev/null) &
  echo $! > "$state/gradle.pid"
  echo "starting (log $log) ..."
  local deadline=$(( SECONDS + ${START_TIMEOUT:-300} ))
  while [ $SECONDS -lt $deadline ]; do
    if up; then echo "OK: listening at $base after ${SECONDS}s"; return 0; fi
    if grep -qE 'BUILD FAILED|Failed to start application' "$log"; then
      echo "FAIL: start-up failed; the cause:"; grep -A6 -E 'What went wrong|Failed to start' "$log" | head -20; return 1
    fi
    kill -0 "$(cat "$state/gradle.pid")" 2>/dev/null || { echo "FAIL: gradle exited; tail of $log:"; tail -20 "$log"; return 1; }
    sleep 2
  done
  echo "FAIL: not up after ${START_TIMEOUT:-300}s; tail of $log:"; tail -20 "$log"; return 1
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

check() {
  up || { echo "FAIL: nothing answers at $base; run: smoke.sh start"; return 1; }
  local ops="$WEDDING_OPS_USERNAME:$WEDDING_OPS_PASSWORD"
  expect "GET /api/health (open)"                    200 '"ok":true'               "$base/api/health"
  expect "GET /q/health/live (open)"                 200 '"status": "UP"'          "$base/q/health/live"
  expect "GET /q/health/ready without credentials"   401 -                         "$base/q/health/ready"
  expect "GET /q/health/ready as ops"                200 'Database connections health check' -u "$ops" "$base/q/health/ready"
  expect "GET /q/metrics as ops"                     200 'http_server_requests'    -u "$ops" "$base/q/metrics"
  expect "GET unknown /api route"                    404 '"code":"NOT_FOUND"'      "$base/api/no-such-route"
  expect "GET /api/health with a bad basic header"   401 -                         -u nobody:wrong "$base/api/health"
  # The dev database: Dev Services' reusable container; Flyway's history shows which migrations ran.
  local db
  db="$(docker ps --filter ancestor=postgres:18.6-alpine --format '{{.ID}}' | head -1)"
  if [ -z "$db" ]; then
    echo "FAIL dev database: no postgres:18.6-alpine container"; fails=$((fails + 1))
  else
    local hist
    hist="$(docker exec "$db" psql -U quarkus -d wedding_portal -tAc \
      "select coalesce(version, 'R') || ' ' || description || ' ' || success from flyway_schema_history order by installed_rank" 2>&1)"
    if grep -q ' true$' <<<"$hist" && ! grep -q ' false$' <<<"$hist"; then
      echo "PASS dev database $db: flyway history"; sed 's/^/       /' <<<"$hist"
    else
      echo "FAIL dev database $db: $hist"; fails=$((fails + 1))
    fi
  fi
  [ "$fails" -eq 0 ]
}

stop() { # the gradle client does not forward SIGTERM to the dev-mode JVM, so the port's listener is ended first
  local pid; pid="$(listener)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  [ -f "$state/gradle.pid" ] && kill "$(cat "$state/gradle.pid")" 2>/dev/null
  rm -f "$state/gradle.pid"
  for _ in $(seq 1 30); do up || break; sleep 1; done
  if up; then echo "FAIL: still answering at $base"; return 1; fi
  echo "OK: stopped"
}

case "${1:-up}" in
  up)     start && check ;;
  start)  start ;;
  check)  check ;;
  stop)   stop ;;
  status) if up; then echo "running at $base (pid $(listener))"; else echo "stopped"; fi ;;
  *)      echo "usage: smoke.sh [up|start|check|stop|status]" >&2; exit 2 ;;
esac
