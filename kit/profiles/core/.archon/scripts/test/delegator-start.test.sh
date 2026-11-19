#!/usr/bin/env bash
# Tests for .archon/scripts/delegator-start.sh (R2, owner decision 2026-10-20 D3) in a throwaway repo with a stubbed
# claude: it starts only from the main checkout on main (exit 2 otherwise), refuses a live lock (exit 3), removes a stale
# one, and starts claude as the delegator with the checked-in settings in auto mode.
# Usage: bash .archon/scripts/test/delegator-start.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/delegator-start.sh"
pass=0; fail=0
root="$(mktemp -d)"
sleeper=""
trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; rm -rf "$root"' EXIT

# claude prints its arguments, one per line, into $ROOT/claude.args.
mkdir -p "$root/bin"
cat > "$root/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ROOT/claude.args"
STUB
chmod +x "$root/bin/claude"

repo=$root/repo
git init -q -b main "$repo"
mkdir -p "$repo/.claude"; echo '{}' > "$repo/.claude/delegator.settings.json"
git -C "$repo" add -A; git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
git -C "$repo" worktree add -q -b feat/x "$root/wt" 2>/dev/null
state=$root/state

ds() { # ds <dir> [args...]: sets out, err, rc
  local d=$1; shift
  rm -f "$root/claude.args"
  out=$(cd "$d" && PATH="$root/bin:$PATH" ROOT="$root" DELEGATOR_STATE_DIR="$state" bash "$script" "$@" 2> "$root/err")
  rc=$?; err=$(cat "$root/err")
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (rc=$rc)"; echo "$out" "$err" | sed 's/^/    /'; fi
}

# 1. From a run worktree: exit 2, claude not started.
ds "$root/wt"
check "1 a worktree exits 2" $([ "$rc" -eq 2 ]; echo $?)
check "1 claude is not started" $([ ! -f "$root/claude.args" ]; echo $?)

# 2. The main checkout on another branch: exit 2.
git -C "$repo" checkout -q -b other
ds "$repo"
check "2 the main checkout off main exits 2" $([ "$rc" -eq 2 ] && [[ "$err" == *"not main"* ]]; echo $?)
git -C "$repo" checkout -q main

# 3. A live lock: exit 3, claude not started, the lock kept.
mkdir -p "$state"; sleep 300 & sleeper=$!
echo "sess-1 $sleeper 2026-10-20" > "$state/session.lock"
ds "$repo"
check "3 a live lock exits 3" $([ "$rc" -eq 3 ] && [[ "$err" == *"sess-1"* ]]; echo $?)
check "3 claude is not started" $([ ! -f "$root/claude.args" ]; echo $?)
check "3 the lock is kept" $(grep -q "sess-1" "$state/session.lock"; echo $?)
kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; sleeper=""

# 4. A stale lock (its process is gone): removed with a line, and the session starts.
ds "$repo"
check "4 a stale lock is removed and the start goes on" $([ "$rc" -eq 0 ] && [[ "$err" == *"stale lock"* ]]; echo $?)

# 5. The start: claude as the delegator, the checked-in settings, auto mode, Remote Control, extra args passed on.
ds "$repo" --name night
args=$(cat "$root/claude.args" 2>/dev/null)
check "5 starts the delegator agent" $(grep -qx -- "--agent" <<< "$args" && grep -qx delegator <<< "$args"; echo $?)
check "5 with the checked-in settings" $(grep -qx "$repo/.claude/delegator.settings.json" <<< "$args"; echo $?)
check "5 in auto mode" $(grep -A1 -x -- "--permission-mode" <<< "$args" | grep -qx auto; echo $?)
check "5 with Remote Control" $(grep -qx -- "--remote-control" <<< "$args"; echo $?)
check "5 passes extra args on" $(grep -A1 -x -- "--name" <<< "$args" | grep -qx night; echo $?)
check "5 writes the lock" $(grep -q '^starting ' "$state/session.lock"; echo $?)

# 6. No settings file: exit 1.
rm -f "$state/session.lock"; mv "$repo/.claude/delegator.settings.json" "$root/s.json"
ds "$repo"
check "6 a missing settings file exits 1" $([ "$rc" -eq 1 ]; echo $?)

# 7. AGENT_CLI=copilot starts copilot as the delegator with all tools allowed, no claude-only flags.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$ROOT/copilot.args"\n' > "$root/bin/copilot"; chmod +x "$root/bin/copilot"
echo '{}' > "$repo/.claude/delegator.settings.json"; rm -f "$root/copilot.args" "$root/claude.args"; rm -rf "$state"
out=$(cd "$repo" && PATH="$root/bin:$PATH" ROOT="$root" AGENT_CLI=copilot DELEGATOR_STATE_DIR="$state" bash "$script" --model x 2> "$root/err"); rc=$?
check "7 copilot is started as the delegator" $([ "$rc" -eq 0 ] && [ "$(tr '\n' ' ' < "$root/copilot.args")" = "--agent delegator --allow-all-tools --model x " ] && [ ! -f "$root/claude.args" ]; echo $?)

echo "delegator-start: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
