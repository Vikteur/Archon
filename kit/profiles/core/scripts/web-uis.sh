#!/usr/bin/env bash
# Starts the browser views of the work in the background and prints their URLs: the Backlog.md board of
# this project (`backlog browser`), the Groma architecture map of this project (`groma web`) with that backlog
# attached (BACKLOG_CWD), so the open tickets show on the map, and the MCP Inspector (`mcp-inspector --web`) on the
# project's MCP servers. A view already running is reused; `stop` ends all of them.
# Board and map read this repo's main checkout, not a worktree, so they show what is on main.
#   web-uis.sh [start|status|stop] [--open]
# --open (with start): also opens every printed URL in the browser, with the first of wslview, explorer.exe, xdg-open,
# open that exists; without it nothing is opened.
# The MCP view: one Inspector process per MCP server of .github/mcp.json (Copilot, key mcpServers), else .mcp.json,
# of MAP_DIR, plus one codegraph-<folder> server per absolute path in .archon/kit.yaml codegraph.extra_projects (the
# codegraph server's command and env with `--path <that folder>`). Each process shows only its one server, on its
# own ports (the web port, +1 the MCP Apps sandbox, +4 the app origin; the next server 10 higher), bound to 127.0.0.1,
# with the Inspector's API-token auth ON: a new random token per start, which is part of the printed URL:
#   mcp-<name>: http://127.0.0.1:<port>/?MCP_INSPECTOR_API_TOKEN=<token>
# `status` prints the same line for every running one (kept in $STATE_DIR/mcp-<name>.url next to its pid). The view is
# skipped, with the reason, when there is no mcp.json, no mcp-inspector on PATH (scripts/install-tools.sh) or no jq.
# Overrides: MAP_DIR (default: this repo's main checkout), HUB_DIR (the checkout that holds
# backlog/; default: MAP_DIR), BACKLOG_PORT (6420), GROMA_PORT (6421), MCP_PORT_BASE (6274: the first MCP server's
# web port), WEB_UIS_OPEN (the command --open runs on each URL, instead of the first of the four above), STATE_DIR (pid,
# url, log and inspector config files; default: $TMPDIR/web-uis).
# The board is skipped, with the reason, when HUB_DIR has no backlog/config.yml (a fresh kit install).
# The map is skipped, with the reason, while this project has no groma/ folder (no map built yet).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
main="$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')"
map="${MAP_DIR:-$main}"
hub="${HUB_DIR:-$map}"
backlog_port="${BACKLOG_PORT:-6420}"
groma_port="${GROMA_PORT:-6421}"
mcp_base="${MCP_PORT_BASE:-6274}"
state="${STATE_DIR:-${TMPDIR:-/tmp}/web-uis}"
urls=()   # what --open opens: every URL a start printed

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
  rm -f "$state/$1.pid" "$state/$1.url"
  echo "$1: stopped"
}

start_one() { # start_one <name> <port> <dir> <command...>: starts it detached unless it already runs
  local name=$1 port=$2 dir=$3; shift 3
  urls+=("http://127.0.0.1:$port")
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

# The MCP Inspector view. Env the Inspector must not inherit: they would switch its auth off or open it to the network.
mcp_scrub=(-u DANGEROUSLY_OMIT_AUTH -u DANGEROUSLY_BIND_ALL_INTERFACES -u MCP_PROXY_AUTH_TOKEN -u ALLOWED_ORIGINS
  -u MCP_CATALOG_PATH -u MCP_INSPECTOR_ALLOWED_HOSTS -u INSPECTOR_TLS_KEY_PATH -u INSPECTOR_TLS_CERT_PATH)

new_token() { # 32 hex characters from the OS random source
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16; else od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; fi
}

mcp_servers() { # the servers to show as one JSON object {name: entry} (Inspector format); empty when there is no list
  local cfg="" f extras="[]" d
  for f in "$map/.github/mcp.json" "$map/.mcp.json"; do [ -f "$f" ] && { cfg=$f; break; }; done
  [ -n "$cfg" ] || return 1
  if [ -f "$here/.archon/scripts/kit-config.sh" ]; then
    # shellcheck source=../.archon/scripts/kit-config.sh
    . "$here/.archon/scripts/kit-config.sh"
    extras="$(KIT_CONFIG="${KIT_CONFIG:-$map/.archon/kit.yaml}" kit_list codegraph.extra_projects | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  fi
  # Copilot entries say type "local" and carry a tools list; the Inspector wants stdio and ignores neither. Each extra
  # project is a copy of the codegraph server (command, env) pointed at that folder with --path.
  jq -c --argjson extras "$extras" '
    def withpath($dir): (.args // []) as $a
      | (reduce range(0; $a | length) as $i ({out: [], skip: false};
          if .skip then .skip = false elif $a[$i] == "--path" then .skip = true else .out += [$a[$i]] end) | .out) + ["--path", $dir];
    ((.mcpServers // {}) | with_entries(.value |= (del(.tools) | if (.url // "") == "" and (.type // "local") == "local" then .type = "stdio" else . end))) as $base
    | $base + ([$extras[] | . as $dir | {
        key: ("codegraph-" + ($dir | sub("/+$"; "") | split("/") | last)),
        value: (($base.codegraph // {command: "codegraph", args: ["serve", "--mcp"], type: "stdio"}) | .args = withpath($dir))
      }] | from_entries)' "$cfg"
}

start_mcp() { # start_mcp: one Inspector per server; prints one "mcp-<name>: <url>" line each
  local servers names name safe n=0 port token url cfgfile
  if ! command -v mcp-inspector >/dev/null 2>&1; then
    echo "mcp: skipped, mcp-inspector is not on PATH (bash scripts/install-tools.sh installs it)"; return 0
  fi
  command -v jq >/dev/null 2>&1 || { echo "mcp: skipped, jq is not on PATH (bash scripts/install-tools.sh installs it)"; return 0; }
  if ! servers="$(mcp_servers)" || [ -z "$servers" ]; then
    echo "mcp: skipped, no .github/mcp.json or .mcp.json in $map"; return 0
  fi
  names="$(jq -r 'keys_unsorted[]' <<<"$servers")"
  [ -n "$names" ] || { echo "mcp: skipped, no MCP servers in the mcp.json of $map"; return 0; }
  while IFS= read -r name; do
    safe="mcp-$(printf '%s' "$name" | tr -c 'A-Za-z0-9._\n-' '_')"
    port=$((mcp_base + n * 10)); n=$((n + 1))
    if running "$safe" && [ -s "$state/$safe.url" ]; then
      url="$(cat "$state/$safe.url")"
      echo "mcp-$name: $url"; urls+=("$url"); continue
    fi
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port"; then
      echo "mcp-$name: port $port is already in use (started elsewhere?): set MCP_PORT_BASE"; continue
    fi
    token="$(new_token)"
    cfgfile="$state/$safe.config.json"
    ( umask 077; jq --arg n "$name" '{mcpServers: {($n): .[$n]}}' <<<"$servers" > "$cfgfile" )
    (cd "$map" && exec nohup env "${mcp_scrub[@]}" HOST=127.0.0.1 CLIENT_PORT="$port" MCP_SANDBOX_PORT=$((port + 1)) \
      MCP_APP_ORIGIN_PORT=$((port + 4)) MCP_INSPECTOR_API_TOKEN="$token" MCP_AUTO_OPEN_ENABLED=false \
      mcp-inspector --web --config "$cfgfile" > "$state/$safe.log" 2>&1 < /dev/null) &
    echo $! > "$state/$safe.pid"
    url="http://127.0.0.1:$port/?MCP_INSPECTOR_API_TOKEN=$token"
    printf '%s\n' "$url" > "$state/$safe.url"
    echo "mcp-$name: $url"; urls+=("$url")
  done <<<"$names"
}

status_mcp() {
  local f safe
  for f in "$state"/mcp-*.pid; do
    [ -e "$f" ] || continue
    safe="$(basename "$f" .pid)"
    if running "$safe" && [ -s "$state/$safe.url" ]; then echo "$safe: $(cat "$state/$safe.url")"; else echo "$safe: stopped"; fi
  done
}

stop_mcp() {
  local f
  for f in "$state"/mcp-*.pid; do [ -e "$f" ] && stop_one "$(basename "$f" .pid)"; done
  rm -f "$state"/mcp-*.config.json
}

open_urls() { # open_urls: every URL a start printed, with WEB_UIS_OPEN or the first opener that exists
  local opener="${WEB_UIS_OPEN:-}" c u
  if [ -z "$opener" ]; then
    for c in wslview explorer.exe xdg-open open; do command -v "$c" >/dev/null 2>&1 && { opener=$c; break; }; done
  fi
  [ -n "$opener" ] || { echo "web-uis: --open: no wslview, explorer.exe, xdg-open or open found" >&2; return 0; }
  for u in ${urls[@]+"${urls[@]}"}; do "$opener" "$u" >/dev/null 2>&1 || true; done
}

open_after=0
cmd=start
for a in "$@"; do
  case "$a" in
    --open) open_after=1 ;;
    start | status | stop) cmd=$a ;;
    *) echo "usage: web-uis.sh [start|status|stop] [--open]" >&2; exit 2 ;;
  esac
done

case "$cmd" in
  start)
    mkdir -p "$state"
    # A project without a Backlog.md board (a fresh kit install) still gets the map and the MCP views.
    if [ -f "$hub/backlog/config.yml" ]; then
      start_one backlog "$backlog_port" "$hub" backlog browser --non-interactive --port "$backlog_port"
      export BACKLOG_CWD="$hub"   # the map shows the board's open tickets
    else
      echo "backlog: skipped, no Backlog.md board at $hub (no backlog/config.yml; set HUB_DIR)"
    fi
    if [ -d "$map/groma" ]; then
      start_one groma "$groma_port" "$map" groma web --port "$groma_port"
    else
      echo "groma: skipped, no Groma map in $map (no groma/ folder yet)"
    fi
    start_mcp
    [ "$open_after" -eq 0 ] || open_urls
    ;;
  status) status_one backlog "$backlog_port"; status_one groma "$groma_port"; status_mcp ;;
  stop)   stop_one backlog; stop_one groma; stop_mcp ;;
esac
