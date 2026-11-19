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

# No backlog in the hub: refuse, start nothing.
rm -f "$tmp/hub/backlog/config.yml"; : > "$tmp/backlog.log"
out="$(run start)"; rc=$?
check "refuses without a backlog (rc=$rc): $out" '[ "$rc" -ne 0 ] && [[ "$out" == *"backlog/config.yml"* ]] && [ ! -s "$tmp/backlog.log" ]'

out="$(run bogus)"; rc=$?
check "unknown command is refused with usage (rc=$rc): $out" '[ "$rc" -ne 0 ] && [[ "$out" == *"usage"* ]]'

echo "web-uis: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
