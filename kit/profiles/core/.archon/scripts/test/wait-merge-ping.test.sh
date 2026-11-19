#!/usr/bin/env bash
# Tests for .archon/scripts/wait-merge.sh's queue drop and owner ping (R14, owner decision 2026-10-20, D9) against a
# stubbed gh, merge-turn.sh, notify-owner.sh and local-ci-status.sh (always green). The rest of wait-merge.sh is
# tested in wait-merge.test.sh, the ready record it keeps is tested in ready-runs.test.sh.
# Usage: bash .archon/scripts/test/wait-merge-ping.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wait-merge.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$root"' EXIT
PR=https://github.com/o/repo/pull/7

# gh answers `pr view --json state` with $C/state (OPEN when missing), the merge commit, head and branch with fixed
# values. Local CI is green on every head. merge-turn and notify log their calls to $C/log.
mkdir -p "$root/bin" "$root/repo/backlog"; touch "$root/repo/backlog/config.yml"; git -C "$root/repo" init -q
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view "*" --json state -q .state") cat "$C/state" 2>/dev/null || echo OPEN ;;
  *"mergeCommit"*) echo feedface ;;
  *"headRefOid"*) echo abc123 ;;
  *"headRefName"*) echo feat/x ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "merge-turn $*" >> "$C/log"; exit "${TURN_RC:-0}"\n' > "$root/bin/merge-turn"
printf '#!/usr/bin/env bash\necho "notify $*" >> "$C/log"; exit "${NOTIFY_RC:-0}"\n' > "$root/bin/notify"
printf '#!/usr/bin/env bash\necho "green every job passed"\n' > "$root/bin/local-ci-status"
chmod +x "$root/bin/"*

setup() { C="$root/$1"; mkdir -p "$C"; : > "$C/log"; }
wm() { # wm: run it in the background, its exit code in $C/rc
  ( cd "$root/repo" && PATH="$root/bin:$PATH" C="$C" BACKLOG_CWD="$root/repo" LOCAL_CI_STATUS="$root/bin/local-ci-status" \
      MERGE_POLL_SECONDS=1 MERGE_PING_SECONDS="${PING:-1800}" MERGE_TURN="$root/bin/merge-turn" \
      NOTIFY_OWNER="${NOTIFY:-$root/bin/notify}" bash "$script" "$PR" > "$C/out" 2> "$C/err"; echo $? > "$C/rc" ) &
}
settle() { for _ in $(seq 1 30); do [ -e "$1" ] && return 0; sleep 0.5; done; return 1; }
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$C/err" "$C/log" 2>/dev/null; fi
}

# 1. Merged: it leaves the merge queue, and no ping before 30 min.
setup one; echo MERGED > "$C/state"; wm; settle "$C/rc"
check "1 exit 0, merged" $([ "$(cat "$C/rc")" = 0 ] && grep -q '"state":"merged"' "$C/out"; echo $?)
check "1 dropped from the queue" $(grep -q "merge-turn drop $PR" "$C/log"; echo $?)
check "1 no ping" $(! grep -q "^notify" "$C/log"; echo $?)

# 2. Closed: it leaves the queue too; a drop of one not queued (exit 1) is fine.
setup two; echo CLOSED > "$C/state"; TURN_RC=1 wm; settle "$C/rc"
check "2 closed, dropped, exit 0" $([ "$(cat "$C/rc")" = 0 ] && grep -q "merge-turn drop $PR" "$C/log"; echo $?)

# 3. Still open past the ping time: exactly one ping, act level, keyed per pull request, naming merge-ready.sh.
setup three; PING=1 wm; sleep 4.5; echo MERGED > "$C/state"; settle "$C/rc"
check "3 pinged once" $([ "$(grep -c '^notify' "$C/log")" -eq 1 ]; echo $?)
check "3 act, keyed per pull request" $(grep -q "^notify act merge-wait-7 " "$C/log"; echo $?)
check "3 about the pull request, skipped while it has an open ping" $(grep "^notify act merge-wait-7 " "$C/log" | grep -qE -- " --about pr:7 --if-none-open$"; echo $?)
check "3 the subject holds only the number, the minutes and the URL, no free text" $(grep "^notify act merge-wait-7 " "$C/log" \
  | grep -qxE "notify act merge-wait-7 PR #7 is ready and not merged after [0-9]+ min: bash \.archon/scripts/merge-ready\.sh https://github\.com/[^ ]+/pull/7 --about pr:7 --if-none-open"; echo $?)
check "3 names the merge command" $(grep -q "merge-ready.sh $PR" "$C/log"; echo $?)
check "3 still ends merged" $([ "$(cat "$C/rc")" = 0 ]; echo $?)

# 4. No notify-owner.sh, or a failing one: the undelivered ping is logged, the wait goes on to the merge.
setup four; PING=1 NOTIFY=/nonexistent wm; sleep 2.5; echo MERGED > "$C/state"; settle "$C/rc"
check "4 missing ping script: logged, exit 0" $([ "$(cat "$C/rc")" = 0 ] && grep -q "ping not delivered" "$C/err"; echo $?)
setup fourb; PING=1 NOTIFY_RC=3 wm; sleep 2.5; echo MERGED > "$C/state"; settle "$C/rc"
check "4 failing ping: logged, exit 0" $([ "$(cat "$C/rc")" = 0 ] && grep -q "ping not delivered" "$C/err"; echo $?)

echo "wait-merge-ping: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
