#!/usr/bin/env bash
# Tests for scripts/web-uis.sh: it starts the Backlog.md board of the hub and the Groma map of the project (with the hub's
# backlog attached) in the background, reports their URLs, and stops them again. The real CLIs are replaced by fakes on
# PATH that record where and how they were started, then idle until killed.
# Run from anywhere: bash scripts/test/web-uis.test.sh   (exit 0 = all pass)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/scripts/web-uis.sh"
pass=0; fail=0
tmp="$(mktemp -d)"
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

mkdir -p "$tmp/bin" "$tmp/hub/backlog" "$tmp/project" "$tmp/state"
: > "$tmp/hub/backlog/config.yml"
for cli in backlog groma; do
  cat > "$tmp/bin/$cli" <<EOF
#!/usr/bin/env bash
echo "\$PWD|\$*|BACKLOG_CWD=\${BACKLOG_CWD:-}" >> "$tmp/$cli.log"
exec sleep 60
EOF
  chmod +x "$tmp/bin/$cli"
done

run() { PATH="$tmp/bin:$PATH" BACKLOG_PORT="${BACKLOG_PORT:-7101}" GROMA_PORT="${GROMA_PORT:-7102}" HUB_DIR="$tmp/hub" MAP_DIR="$tmp/project" STATE_DIR="$tmp/state" bash "$script" "$@" 2>&1; }
alive() { [ -f "$tmp/state/$1.pid" ] && kill -0 "$(cat "$tmp/state/$1.pid")" 2>/dev/null; }
settle() { for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/$1.log" ] && return; sleep 0.2; done; }
cleanup() { run stop >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT

[ -f "$script" ] && ok || bad "$script exists"

# No Groma map in the project yet: the board starts, the map is skipped with a reason.
out="$(run start)"; rc=$?; settle backlog
check "start exits 0 (rc=$rc): $out" '[ "$rc" -eq 0 ]'
check "board URL printed: $out" '[[ "$out" == *"http://127.0.0.1:7101"* ]]'
check "board started in the hub: $(cat "$tmp/backlog.log" 2>/dev/null)" 'grep -q "^$tmp/hub|browser --non-interactive --port 7101|" "$tmp/backlog.log"'
check "board process recorded and alive" 'alive backlog'
check "no map without a groma/ folder: $out" '[[ "$out" == *"no Groma map"* ]] && [ ! -s "$tmp/groma.log" ] && ! alive groma'

# A second start reuses the running board.
out="$(run start)"; settle backlog
check "second start reports the board as running: $out" '[[ "$out" == *"already running"* ]]'
check "second start does not start another board" '[ "$(wc -l < "$tmp/backlog.log")" -eq 1 ]'

out="$(run status)"
check "status names the running board: $out" '[[ "$out" == *"backlog"*"running"*"7101"* ]]'

pid="$(cat "$tmp/state/backlog.pid")"
out="$(run stop)"
check "stop ends the board: $out" '! kill -0 "$pid" 2>/dev/null && [ ! -f "$tmp/state/backlog.pid" ]'
out="$(run status)"
check "status after stop says stopped: $out" '[[ "$out" == *"stopped"* ]]'

# With a Groma map: the map starts in the project with the hub's backlog attached, on overridable ports.
mkdir -p "$tmp/project/groma"; : > "$tmp/backlog.log"
out="$(BACKLOG_PORT=7001 GROMA_PORT=7002 run start)"; settle groma
check "map URL printed: $out" '[[ "$out" == *"http://127.0.0.1:7002"* && "$out" == *"http://127.0.0.1:7001"* ]]'
check "map started in the project with BACKLOG_CWD=hub: $(cat "$tmp/groma.log" 2>/dev/null)" 'grep -q "^$tmp/project|web --port 7002|BACKLOG_CWD=$tmp/hub$" "$tmp/groma.log"'
check "map process recorded and alive" 'alive groma'
run stop >/dev/null
check "stop ends the map too" '! alive groma && ! alive backlog'

# A port that already answers (a board started by hand) is reported, not started a second time on another port.
if command -v python3 >/dev/null 2>&1; then py=python3; else py=python; fi
busy=7011
(cd "$tmp" && exec "$py" -m http.server "$busy" --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
for _ in $(seq 1 25); do curl -s -o /dev/null "http://127.0.0.1:$busy" && break; sleep 0.2; done
: > "$tmp/backlog.log"
out="$(BACKLOG_PORT=$busy run start)"; sleep 0.5
check "busy port reported, nothing started: $out" '[[ "$out" == *"already in use"*"$busy"* ]] && [ ! -s "$tmp/backlog.log" ] && ! alive backlog'
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
run stop >/dev/null

# No backlog in the hub (a fresh kit install): the board is skipped with a line, the rest still starts.
rm -f "$tmp/hub/backlog/config.yml"; : > "$tmp/backlog.log"
out="$(run start)"; rc=$?
check "skips the board without a backlog (rc=$rc): $out" '[ "$rc" -eq 0 ] && [[ "$out" == *"backlog: skipped, no Backlog.md board at $tmp/hub (no backlog/config.yml"* ]] && [ ! -s "$tmp/backlog.log" ]'
run stop >/dev/null

out="$(run bogus)"; rc=$?
check "unknown command is refused with usage (rc=$rc): $out" '[ "$rc" -ne 0 ] && [[ "$out" == *"usage"* ]]'

# ---- The MCP Inspector view: skip reasons first (no config, then no mcp-inspector), then the real start.
rm -rf "$tmp/project/groma"; : > "$tmp/hub/backlog/config.yml"
mkdir -p "$tmp/mcpbin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/mcpbin/mcp-inspector"; chmod +x "$tmp/mcpbin/mcp-inspector"
out="$(PATH="$tmp/mcpbin:$PATH" run start)"
check "mcp skipped with no mcp.json: $out" '[[ "$out" == *"mcp: skipped, no .github/mcp.json or .mcp.json"* ]]'
mkdir -p "$tmp/project/.github" "$tmp/project/.archon" "$tmp/front/app"
cat > "$tmp/project/.github/mcp.json" <<'EOF2'
{"mcpServers":{
  "codegraph":{"type":"local","command":"codegraph","args":["serve","--mcp","--path","/somewhere"],"env":{"CODEGRAPH_MCP_TOOLS":"explore,node"},"tools":["*"]},
  "@@KIT_CONTRACT_SERVER_NAME@@":{"type":"local","command":"node","args":["server.mjs"],"tools":["*"]}}}
EOF2
printf 'codegraph:\n  extra_projects:\n    - %s/front/app\n' "$tmp" > "$tmp/project/.archon/kit.yaml"
mkdir -p "$tmp/nopath"; for t in bash env cat sleep nohup curl jq yq dirname basename tr od openssl git rm mkdir sed grep head sort; do
  p="$(command -v $t)" && ln -sf "$p" "$tmp/nopath/$t"; done
out="$(PATH="$tmp/nopath" /bin/bash "$script" start 2>&1)"
check "mcp skipped without mcp-inspector on PATH: $out" '[[ "$out" == *"mcp: skipped, mcp-inspector is not on PATH"* ]]'
run stop >/dev/null

# the fake Inspector: records where, how and with which environment it started, then idles
mkdir -p "$tmp/mcpbin"
cat > "$tmp/mcpbin/mcp-inspector" <<EOF2
#!/usr/bin/env bash
{ echo "\$PWD|\$*"; env | grep -E '^(HOST|CLIENT_PORT|MCP_SANDBOX_PORT|MCP_APP_ORIGIN_PORT|MCP_INSPECTOR_API_TOKEN|MCP_AUTO_OPEN_ENABLED|DANGEROUSLY_[A-Z_]*)=' | sort; echo ---; } >> "$tmp/inspector.log"
exec sleep 60
EOF2
chmod +x "$tmp/mcpbin/mcp-inspector"
cat > "$tmp/mcpbin/fake-open" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$tmp/open.log"
EOF2
chmod +x "$tmp/mcpbin/fake-open"
runm() { DANGEROUSLY_OMIT_AUTH=true DANGEROUSLY_BIND_ALL_INTERFACES=true MCP_PORT_BASE="${MCP_PORT_BASE:-7201}" PATH="$tmp/mcpbin:$PATH" run "$@"; }
msettle() { for _ in $(seq 1 25); do [ "$(grep -c '^---' "$tmp/inspector.log" 2>/dev/null)" -ge "$1" ] && return; sleep 0.2; done; }
: > "$tmp/inspector.log"
out="$(runm start)"; msettle 3
url1="$(sed -n 's/^mcp-codegraph: //p' <<<"$out")"; url2="$(sed -n 's/^mcp-project-api: //p' <<<"$out")"
url3="$(sed -n 's/^mcp-codegraph-app: //p' <<<"$out")"
tok() { sed -n 's/.*[?&]MCP_INSPECTOR_API_TOKEN=\([0-9a-f]*\)$/\1/p' <<<"$1"; }
check "a line per server, own ports, token in the URL: $out" '[[ "$url1" == "http://127.0.0.1:7201/?MCP_INSPECTOR_API_TOKEN="* && "$url2" == "http://127.0.0.1:7211/?MCP_INSPECTOR_API_TOKEN="* && "$url3" == "http://127.0.0.1:7221/?"* ]]'
check "the token is long and random per server" '[ "$(tok "$url1" | wc -c)" -ge 33 ] && [ "$(tok "$url1")" != "$(tok "$url2")" ]'
check "the extra project is a server (codegraph-app)" '[ -n "$url3" ]'
check "three Inspector processes alive" 'alive mcp-codegraph && alive mcp-project-api && alive mcp-codegraph-app'
check "started from the project with --web --config: $(head -1 "$tmp/inspector.log")" 'grep -q "^$tmp/project|--web --config $tmp/state/mcp-codegraph.config.json$" "$tmp/inspector.log"'
check "bound to 127.0.0.1, ports and token in the child env, no browser of its own" 'grep -qx "HOST=127.0.0.1" "$tmp/inspector.log" && grep -qx "CLIENT_PORT=7201" "$tmp/inspector.log" && grep -qx "MCP_SANDBOX_PORT=7202" "$tmp/inspector.log" && grep -qx "MCP_APP_ORIGIN_PORT=7205" "$tmp/inspector.log" && grep -qx "MCP_INSPECTOR_API_TOKEN=$(tok "$url1")" "$tmp/inspector.log" && grep -qx "MCP_AUTO_OPEN_ENABLED=false" "$tmp/inspector.log"'
check "no DANGEROUSLY_* variable reaches the child (even set in the caller)" '! grep -q "^DANGEROUSLY_" "$tmp/inspector.log"'
check "one server per config file" '[ "$(jq -r ".mcpServers | keys | join(\",\")" "$tmp/state/mcp-project-api.config.json")" = @@KIT_CONTRACT_SERVER_NAME@@ ] && [ "$(jq -r ".mcpServers.\"@@KIT_CONTRACT_SERVER_NAME@@\".type" "$tmp/state/mcp-project-api.config.json")" = stdio ] && [ "$(jq -r ".mcpServers.\"@@KIT_CONTRACT_SERVER_NAME@@\".tools // \"none\"" "$tmp/state/mcp-project-api.config.json")" = none ]'
check "the extra codegraph server: same command and env, --path to the extra project" '[ "$(jq -c ".mcpServers[\"codegraph-app\"] | [.command, .args, .env.CODEGRAPH_MCP_TOOLS]" "$tmp/state/mcp-codegraph-app.config.json")" = "[\"codegraph\",[\"serve\",\"--mcp\",\"--path\",\"$tmp/front/app\"],\"explore,node\"]" ]'
check "the config files are private" '[ "$(stat -c %a "$tmp/state/mcp-codegraph.config.json")" = 600 ]'
check "nothing opened without --open" '[ ! -e "$tmp/open.log" ]'

out="$(runm status)"
check "status prints the same URL lines: $out" '[[ "$out" == *"mcp-codegraph: $url1"* && "$out" == *"mcp-project-api: $url2"* ]]'
out="$(runm start)"
check "a second start reuses them, same token" '[[ "$out" == *"mcp-codegraph: $url1"* ]] && [ "$(grep -c "^---" "$tmp/inspector.log")" -eq 3 ]'
pidm="$(cat "$tmp/state/mcp-codegraph.pid")"
out="$(runm stop)"
check "stop ends every Inspector: $out" '! kill -0 "$pidm" 2>/dev/null && ! alive mcp-project-api && ! alive mcp-codegraph-app && [ ! -e "$tmp/state/mcp-codegraph.url" ]'
check "stop removes the inspector configs" '! ls "$tmp"/state/mcp-*.config.json >/dev/null 2>&1'
out="$(runm status)"
check "status after stop prints no URL: $out" '[[ "$out" != *"MCP_INSPECTOR_API_TOKEN"* ]]'

# A new start gets a new token; --open opens every printed URL with WEB_UIS_OPEN, and only then.
: > "$tmp/inspector.log"
out="$(runm start)"; msettle 3
newtok="$(tok "$(sed -n 's/^mcp-codegraph: //p' <<<"$out")")"
check "the token differs per start" '[ -n "$newtok" ] && [ "$newtok" != "$(tok "$url1")" ]'
runm stop >/dev/null
out="$(WEB_UIS_OPEN="$tmp/mcpbin/fake-open" runm start --open)"; sleep 0.5
check "--open opened the board and the three MCP URLs: $(cat "$tmp/open.log" 2>/dev/null)" '[ "$(wc -l < "$tmp/open.log")" -eq 4 ] && grep -q "^http://127.0.0.1:7101$" "$tmp/open.log" && grep -q "^http://127.0.0.1:7201/?MCP_INSPECTOR_API_TOKEN=" "$tmp/open.log" && grep -q "^http://127.0.0.1:7221/?MCP_INSPECTOR_API_TOKEN=" "$tmp/open.log"'
runm stop >/dev/null

# A slot another process holds (here its app-origin port, base+4) is passed over: every server moves one slot up.
(cd "$tmp" && exec "$py" -m http.server 7205 --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
for _ in $(seq 1 25); do curl -s -o /dev/null "http://127.0.0.1:7205" && break; sleep 0.2; done
: > "$tmp/inspector.log"
out="$(runm start)"; msettle 3
check "a busy slot is passed over, with a line: $out" '[[ "$out" == *"mcp-codegraph: port 7201 or 7202/7205 is in use, trying 7211"* ]] && [[ "$(sed -n "s/^mcp-codegraph: http/http/p" <<<"$out")" == "http://127.0.0.1:7211/?"* ]] && [[ "$(sed -n "s/^mcp-codegraph-app: //p" <<<"$out")" == "http://127.0.0.1:7231/?"* ]] && alive mcp-codegraph'
runm stop >/dev/null
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null

# No kit.yaml: no extra server; .mcp.json is the fallback when there is no .github/mcp.json.
rm -f "$tmp/project/.archon/kit.yaml"; mv "$tmp/project/.github/mcp.json" "$tmp/project/.mcp.json"
out="$(runm start)"
check "no extra_projects: no extra server; .mcp.json is read: $out" '[[ "$out" == *"mcp-codegraph:"* && "$out" != *"codegraph-app"* ]]'
runm stop >/dev/null

echo "web-uis: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
