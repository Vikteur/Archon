#!/usr/bin/env bash
# Tests for .archon/scripts/merge-ready.sh (owner decision 2026-10-20, D7) against a stubbed gh, stop-check.sh,
# merge-turn.sh, auto-merge.sh and notify-owner.sh. One case or more per exit code: 0 merged, 10 held, 3 behind,
# 4 not ready, 5 closed, 2 usage, 1 error; plus the head-change and hold-marker checks and the audit comment and log line.
# Usage: bash .archon/scripts/test/merge-ready.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/merge-ready.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
PR=https://github.com/o/repo/pull/7
H0=aaaa000000000000000000000000000000000000
H1=bbbb111111111111111111111111111111111111

# gh: `pr view <pr> --json state,...` answers the lines of $C/facts one per call (the last one repeats), as
# "<state> <head> <draft> <mergeable>"; `--json headRefOid` answers $C/merged_head (H0 when missing); `--json url` the
# pull request url; `pr comment` exits $C/comment_rc (0 when missing). Every call of every stub goes to $C/log.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$C/log"
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json state,headRefOid,isDraft,mergeable"*)
        n=$(cat "$C/facts.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$C/facts.n"
        total=$(wc -l < "$C/facts"); [ "$n" -gt "$total" ] && n=$total
        sed -n "${n}p" "$C/facts" ;;
      *"--json headRefOid"*) cat "$C/merged_head" 2>/dev/null || echo "$H0" ;;
      *"--json url"*) echo "https://github.com/o/repo/pull/$3" ;;
    esac ;;
  "pr comment") echo "$*" > "$C/comment"; exit "$(cat "$C/comment_rc" 2>/dev/null || echo 0)" ;;
esac
STUB
# stop-check prints $C/verdict (stdout; "none" when missing) and exits 0.
cat > "$root/bin/stop-check" <<'STUB'
#!/usr/bin/env bash
echo "stop-check $*" >> "$C/log"
if [ -f "$C/verdict" ]; then cat "$C/verdict"; else echo none; fi
STUB
# merge-turn: `wait` runs $C/turn_hook when present, prints $C/turn_out and exits $C/turn_rc (0); `drop` is logged.
cat > "$root/bin/merge-turn" <<'STUB'
#!/usr/bin/env bash
echo "merge-turn $*" >> "$C/log"
[ "$1" = wait ] || exit 0
[ -f "$C/turn_hook" ] && bash "$C/turn_hook"
cat "$C/turn_out" 2>/dev/null; exit "$(cat "$C/turn_rc" 2>/dev/null || echo 0)"
STUB
# auto-merge sleeps $C/am_sleep seconds when present, then prints $C/am_out (merged as feedface when missing).
cat > "$root/bin/auto-merge" <<'STUB'
#!/usr/bin/env bash
echo "auto-merge $*" >> "$C/log"
[ -f "$C/am_sleep" ] && sleep "$(cat "$C/am_sleep")"
if [ -f "$C/am_out" ]; then cat "$C/am_out"; else echo '{"state":"merged","sha":"feedface","detail":"merged"}'; fi
STUB
# red-triage prints $C/triage (a red own run when missing) and exits 0.
cat > "$root/bin/red-triage" <<'STUB'
#!/usr/bin/env bash
echo "red-triage $*" >> "$C/log"
if [ -f "$C/triage" ]; then cat "$C/triage"; else echo '{"class":"own","sha":"tip1","rerun":"none","jobs":"test=own","detail":""}'; fi
STUB
cat > "$root/bin/notify" <<'STUB'
#!/usr/bin/env bash
echo "notify $*" >> "$C/log"
STUB
chmod +x "$root/bin/"*

setup() { # setup <case> <facts line>...: a fresh case folder and its queue folder
  C="$root/$1"; shift; mkdir -p "$C/q"; : > "$C/log"; printf '%s\n' "$@" > "$C/facts"
}
mr() { # mr <args...>: sets out (stdout), err, rc
  out=$(PATH="$root/bin:$PATH" C="$C" H0="$H0" MERGE_QUEUE_DIR="$C/q" STOP_CHECK="$root/bin/stop-check" \
    MERGE_TURN="$root/bin/merge-turn" AUTO_MERGE="$root/bin/auto-merge" NOTIFY_OWNER="${NOTIFY:-$root/bin/notify}" \
    RED_TRIAGE="$root/bin/red-triage" MERGE_READY_TIMEOUT="${TMO:-30}" timeout 60 bash "$script" "$@" 2> "$C/err"); rc=$?; err=$(cat "$C/err")
}
field() { printf '%s' "$out" | jq -r ".$1"; }
logged() { grep -q "$1" "$C/log"; }
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}
OPEN="OPEN $H0 false MERGEABLE"

# 1. Verdict none, ready: waits for its turn, merges the checked head, posts the audit comment, logs the merge.
setup one "$OPEN"; mr "$PR"
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 merged" $([ "$(field state)" = merged ] && [ "$(field verdict)" = none ]; echo $?)
check "1 the turn is waited for" $(logged "merge-turn wait $PR"; echo $?)
check "1 merges the checked head only" $(logged "auto-merge $PR --head $H0"; echo $?)
check "1 the turn comes before the merge" $([ "$(grep -n 'merge-turn wait' "$C/log" | cut -d: -f1)" -lt "$(grep -n '^auto-merge' "$C/log" | cut -d: -f1)" ]; echo $?)
check "1 audit comment names head, merge commit and verdict" $(grep -q "$H0" "$C/comment" && grep -q feedface "$C/comment" \
  && grep -q "STOP verdict: none" "$C/comment"; echo $?)
check "1 audit comment carries the merge-ledger marker" $(grep -qF '<!-- merge-ledger: by=merge-ready.sh; rule=D7: no unapproved STOP item -->' "$C/comment"; echo $?)
check "1 log line" $([ "$(jq -r .state "$C/q/merge-ready.log")" = merged ] && [ "$(jq -r .head "$C/q/merge-ready.log")" = "$H0" ]; echo $?)
check "1 no ping" $(! logged "^notify"; echo $?)

# 2. Verdict covered (an approval covers every item): merged, the reasons go in the audit comment.
setup two "$OPEN"; printf 'covered\napproval 2026-10-20#1 covers stop-migration\n' > "$C/verdict"; mr "$PR"
check "2 covered merges" $([ "$rc" -eq 0 ] && [ "$(field verdict)" = covered ]; echo $?)
check "2 the reasons are in the audit comment" $(grep -q "covers stop-migration" "$C/comment"; echo $?)

# 3. Verdict owner: held (exit 10), out of the queue, the owner pinged; no turn waited for, nothing merged.
setup three "$OPEN"; printf 'owner\nstop-auth (label): owner — no signed approval for Jan Peeters\n' > "$C/verdict"; mr "$PR"
check "3 exit 10" $([ "$rc" -eq 10 ] && [ "$(field state)" = held ]; echo $?)
check "3 the reason is reported" $(field detail | grep -q "stop-auth (label): owner — no signed approval for Jan Peeters"; echo $?)
check "3 dropped from the queue" $(logged "merge-turn drop $PR"; echo $?)
check "3 no wait, no merge" $(! logged "merge-turn wait" && ! logged "^auto-merge"; echo $?)
check "3 owner pinged once" $([ "$(grep -c "^notify act merge-held-7" "$C/log")" -eq 1 ]; echo $?)
check "3 the ping is about the pull request, open until it is merged or closed" $(grep "^notify act merge-held-7" "$C/log" | grep -qE -- " --about pr:7$"; echo $?)
check "3 the ping carries the category id, never the reason text" $(grep "^notify act merge-held-7" "$C/log" | grep -q "stop-auth" \
  && ! grep "^notify" "$C/log" | grep -qE "no signed approval|Jan Peeters"; echo $?)
check "3 logged" $([ "$(jq -r .state "$C/q/merge-ready.log")" = held ]; echo $?)

# 4. notify-owner.sh missing: still held, the undelivered ping is logged, not fatal.
setup four "$OPEN"; echo owner > "$C/verdict"; NOTIFY=/nonexistent mr "$PR"
check "4 still exit 10 without a ping script" $([ "$rc" -eq 10 ] && echo "$err" | grep -q "ping not delivered"; echo $?)

# 5. Hold marker: --hold needs a reason, sets the marker and leaves the queue; a held pull request is not even checked;
#    --unhold removes it, and the next call merges.
setup five "$OPEN"; mr "$PR" --hold
check "5 --hold without --reason is usage" $([ "$rc" -eq 2 ]; echo $?)
mr "$PR" --hold --reason "owner asked to wait"
check "5 --hold exits 10" $([ "$rc" -eq 10 ] && [ -f "$C/q/holds/o_repo_7" ]; echo $?)
check "5 --hold leaves the queue" $(logged "merge-turn drop $PR"; echo $?)
: > "$C/log"; mr "$PR"
check "5 held: exit 10 with the reason" $([ "$rc" -eq 10 ] && field detail | grep -q "owner asked to wait"; echo $?)
check "5 held: no verdict asked, nothing merged" $(! logged "stop-check" && ! logged "^auto-merge"; echo $?)
mr "$PR" --unhold
check "5 --unhold exits 0" $([ "$rc" -eq 0 ] && [ ! -f "$C/q/holds/o_repo_7" ]; echo $?)
mr "$PR"
check "5 merged after --unhold" $([ "$rc" -eq 0 ] && [ "$(field state)" = merged ]; echo $?)
mr "$PR" --unhold
check "5 --unhold without a marker is an error" $([ "$rc" -eq 1 ]; echo $?)

# 6. A hold marker set while it waited for its turn stops the merge.
setup six "$OPEN"; echo "mkdir -p '$C/q/holds'; echo 'reason: late hold' > '$C/q/holds/o_repo_7'" > "$C/turn_hook"; mr "$PR"
check "6 a hold during the turn wait: exit 10, nothing merged" $([ "$rc" -eq 10 ] && ! logged "^auto-merge"; echo $?)

# 7. The head moved after the verdict (a push during the turn wait): not ready, nothing merged.
setup seven "$OPEN" "OPEN $H1 false MERGEABLE"; mr "$PR"
check "7 a changed head: exit 4" $([ "$rc" -eq 4 ] && field detail | grep -q "moved from $H0 to $H1"; echo $?)
check "7 nothing merged" $(! logged "^auto-merge"; echo $?)
# ... and when it moves between that look and the merge, auto-merge.sh --head answers moved.
setup sevenb "$OPEN"; echo '{"state":"moved","sha":"'"$H1"'","detail":"head moved"}' > "$C/am_out"; mr "$PR"
check "7b auto-merge moved: exit 4" $([ "$rc" -eq 4 ] && [ "$(field state)" = not-ready ]; echo $?)

# 8. Behind its base at its turn: exit 3 with merge-turn's detail; nothing merged.
setup eight "$OPEN"; echo 3 > "$C/turn_rc"
echo '{"state":"behind","sha":"'"$H0"'","detail":"2 commit(s) behind main"}' > "$C/turn_out"; mr "$PR"
check "8 behind: exit 3" $([ "$rc" -eq 3 ] && [ "$(field state)" = behind ] && field detail | grep -q "2 commit"; echo $?)
check "8 nothing merged" $(! logged "^auto-merge"; echo $?)

# 9. Not ready (exit 4): a draft, a conflict, CI red, reviews still open past the timeout.
setup nine "OPEN $H0 true MERGEABLE"; mr "$PR"
check "9 a draft: exit 4, no turn taken" $([ "$rc" -eq 4 ] && ! logged "merge-turn wait"; echo $?)
setup ninb "OPEN $H0 false CONFLICTING"; mr "$PR"
check "9 a conflict: exit 4" $([ "$rc" -eq 4 ] && field detail | grep -q conflict; echo $?)
setup ninc "$OPEN"; echo '{"state":"red","sha":"'"$H0"'","detail":"build failed"}' > "$C/am_out"; mr "$PR"
check "9 CI red: exit 4" $([ "$rc" -eq 4 ] && field detail | grep -q "build failed"; echo $?)
setup nind "$OPEN"; echo '{"state":"main-red","sha":"tip1","detail":"the tip tip1 of main is red"}' > "$C/am_out"; mr "$PR"
check "9 main's tip red (D9): exit 4, says main-red" $([ "$rc" -eq 4 ] && field detail | grep -q "main-red"; echo $?)
check "9 main red: the tip is triaged (one flake rerun)" $(logged "red-triage --base main tip1"; echo $?)
check "9 main red for real: one act ping per SHA, about it" $(logged "^notify act main-red-tip1 .* --about sha:tip1$" \
  && [ "$(grep -c '^notify' "$C/log")" -eq 1 ]; echo $?)
setup ninf "$OPEN"; echo '{"state":"main-red","sha":"c0ffee1234567","detail":"the tip c0ffee1 of main is red"}' > "$C/am_out"
echo '{"class":"green","sha":"c0ffee1234567","rerun":"green-after:flaky:merge-path-7a","jobs":"","detail":""}' > "$C/triage"; mr "$PR"
check "9 main red by a listed flake, green after its rerun: no ping, call again" $([ "$rc" -eq 4 ] && ! logged "^notify" \
  && field detail | grep -q "green after a rerun"; echo $?)
setup ning "$OPEN"; echo '{"state":"main-red","sha":"c0ffee1234567","detail":"red"}' > "$C/am_out"
echo '{"class":"own","sha":"c0ffee1234567","rerun":"red-after:flaky:merge-path-7a","jobs":"x=own","detail":""}' > "$C/triage"; mr "$PR"
check "9 red again after the rerun: pinged, keyed by the short SHA" $(logged "^notify act main-red-c0ffee1 .* --about sha:c0ffee1234567$"; echo $?)
setup nind "$OPEN"; echo 5 > "$C/am_sleep"; TMO=1 mr "$PR"
check "9 still waiting at the timeout: exit 4" $([ "$rc" -eq 4 ] && field detail | grep -q "after 1s"; echo $?)
check "9 no audit comment when not merged" $([ ! -f "$C/comment" ]; echo $?)

# 10. Closed without a merge: exit 5; already merged by someone else: exit 0 without an audit comment.
setup ten "CLOSED $H0 false UNKNOWN"; mr "$PR"
check "10 closed: exit 5" $([ "$rc" -eq 5 ] && [ "$(field state)" = closed ]; echo $?)
setup tenb "MERGED $H0 false UNKNOWN"; mr "$PR"
check "10 merged elsewhere: exit 0, no comment, no merge" $([ "$rc" -eq 0 ] && [ ! -f "$C/comment" ] && ! logged "^auto-merge"; echo $?)

# 11. Usage (exit 2).
setup eleven "$OPEN"
mr; check "11 no pull request" $([ "$rc" -eq 2 ]; echo $?)
mr not-a-url; check "11 a bad url" $([ "$rc" -eq 2 ]; echo $?)
mr "$PR" --bogus; check "11 an unknown option" $([ "$rc" -eq 2 ]; echo $?)
mr "$PR" --reason x; check "11 --reason without --hold" $([ "$rc" -eq 2 ]; echo $?)

# 12. Errors (exit 1): no stop-check.sh, a verdict that is not one, GitHub unreadable, a merged head not the checked one.
setup twelve "$OPEN"
out=$(PATH="$root/bin:$PATH" C="$C" MERGE_QUEUE_DIR="$C/q" STOP_CHECK=/nonexistent MERGE_TURN="$root/bin/merge-turn" \
  AUTO_MERGE="$root/bin/auto-merge" NOTIFY_OWNER="$root/bin/notify" bash "$script" "$PR" 2>/dev/null); rc=$?
check "12 no stop-check: exit 1, nothing merged" $([ "$rc" -eq 1 ] && ! logged "^auto-merge"; echo $?)
setup twelveb "$OPEN"; echo "maybe" > "$C/verdict"; mr "$PR"
check "12 a garbled verdict: exit 1, nothing merged" $([ "$rc" -eq 1 ] && ! logged "^auto-merge"; echo $?)
setup twelvec ""; mr "$PR"
check "12 GitHub unreadable: exit 1" $([ "$rc" -eq 1 ]; echo $?)
setup twelved "$OPEN"; echo "$H1" > "$C/merged_head"; mr "$PR"
check "12 merged at another head: exit 1 and a ping" $([ "$rc" -eq 1 ] && logged "^notify act merge-head-7"; echo $?)

# 13. --check: every check, no turn, no merge.
setup thirteen "$OPEN"; mr "$PR" --check
check "13 --check: exit 0, ready" $([ "$rc" -eq 0 ] && [ "$(field state)" = ready ]; echo $?)
check "13 --check merges nothing" $(! logged "merge-turn wait" && ! logged "^auto-merge"; echo $?)
setup thirteenb "$OPEN"; echo owner > "$C/verdict"; mr "$PR" --check
check "13 --check reports held" $([ "$rc" -eq 10 ]; echo $?)
check "13 --check on owner: no queue change, no ping, no log line" $(! logged "^merge-turn" && ! logged "^notify" \
  && [ ! -s "$C/q/merge-ready.log" ] && [ -z "$(ls -A "$C/q/holds")" ]; echo $?)

# 14. The audit comment fails: merged still exits 0, the log says so and the owner gets a warning.
setup fourteen "$OPEN"; echo 1 > "$C/comment_rc"; mr "$PR"
check "14 merged without the comment: exit 0" $([ "$rc" -eq 0 ] && field detail | grep -q "NOT posted"; echo $?)
check "14 warned" $(logged "^notify warn merge-audit-7"; echo $?)

# 15. A pull request number is resolved to its url.
setup fifteen "$OPEN"; mr 7
check "15 a number works" $([ "$rc" -eq 0 ] && [ "$(field pr)" = "$PR" ]; echo $?)

echo "merge-ready: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
