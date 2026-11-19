#!/usr/bin/env bash
# Starts the two browser views of the work in the background and prints their URLs: the Backlog.md board of
# this project (`backlog browser`) and the Groma architecture map of this project (`groma web`) with that backlog
# attached (BACKLOG_CWD), so the open tickets show on the map. A view already running is reused; `stop` ends both.
# Both read this repo's main checkout, not a worktree, so the board shows what is on main.
#   web-uis.sh [start|status|stop]
# Overrides: MAP_DIR (default: this repo's main checkout), HUB_DIR (the checkout that holds
# backlog/; default: MAP_DIR), BACKLOG_PORT (6420), GROMA_PORT (6421), STATE_DIR (pid and log files; default:
# $TMPDIR/web-uis).
# The map is skipped, with the reason, while this project has no groma/ folder (no map built yet).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
main="$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')"
map="${MAP_DIR:-$main}"
hub="${HUB_DIR:-$map}"
backlog_port="${BACKLOG_PORT:-6420}"
groma_port="${GROMA_PORT:-6421}"
state="${STATE_DIR:-${TMPDIR:-/tmp}/web-uis}"

running() { [ -f "$state/$1.pid" ] && kill -0 "$(cat "$state/$1.pid")" 2>/dev/null; }

stop_one() { # stop_one <name>: ends the process and, on Windows, the native tree it started
  local pid winpid
  [ -f "$state/$1.pid" ] || return 0
  pid="$(cat "$state/$1.pid")"
  winpid="$(cat "/proc/$pid/winpid" 2>/dev/null || true)"
  if [ -n "$winpid" ] && command -v taskkill >/dev/null 2>&1; then taskkill //T //F //PID "$winpid" >/dev/null 2>&1; fi
  kill "$pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -9 "$pid" 2>/dev/null
  rm -f "$state/$1.pid"
  echo "$1: stopped"
}

start_one() { # start_one <name> <port> <dir> <command...>: starts it detached unless it already runs
  local name=$1 port=$2 dir=$3; shift 3
  if running "$name"; then
    echo "$name: already running at http://127.0.0.1:$port (pid $(cat "$state/$name.pid"))"
    return 0
  fi
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port"; then
    echo "$name: port $port is already in use (started elsewhere?): open http://127.0.0.1:$port or set the port override"
    return 0
  fi
  (cd "$dir" && exec nohup "$@" > "$state/$name.log" 2>&1 < /dev/null) &
  echo $! > "$state/$name.pid"
  echo "$name: http://127.0.0.1:$port (log $state/$name.log)"
}

status_one() { # status_one <name> <port>
  if running "$1"; then echo "$1: running at http://127.0.0.1:$2 (pid $(cat "$state/$1.pid"))"; else echo "$1: stopped"; fi
}

case "${1:-start}" in
  start)
    if [ ! -f "$hub/backlog/config.yml" ]; then
      echo "web-uis: no backlog at $hub (backlog/config.yml missing); set HUB_DIR." >&2
      exit 1
    fi
    mkdir -p "$state"
    start_one backlog "$backlog_port" "$hub" backlog browser --non-interactive --port "$backlog_port"
    if [ -d "$map/groma" ]; then
      BACKLOG_CWD="$hub" start_one groma "$groma_port" "$map" groma web --port "$groma_port"
    else
      echo "groma: skipped, no Groma map in $map (no groma/ folder yet)"
    fi
    ;;
  status) status_one backlog "$backlog_port"; status_one groma "$groma_port" ;;
  stop)   stop_one backlog; stop_one groma ;;
  *) echo "usage: web-uis.sh [start|status|stop]" >&2; exit 2 ;;
esac
