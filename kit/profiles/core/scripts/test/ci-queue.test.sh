#!/usr/bin/env bash
# Tests for .claude/scripts/ci-queue.sh: first come first served, one commit never twice side by side, a duplicate --post
# attaches to the run already there, a dead process is reaped as stale, and the slots follow CI_LOCAL_SLOTS (default 1).
# Usage: bash scripts/test/ci-queue.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-queue.sh"
pass=0; fail=0
root="$(mktemp -d)"
sleepers=()
trap 'kill "${sleepers[@]}" 2>/dev/null; rm -rf "$root"' EXIT
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}
live() { sleep 300 & sleepers+=($!); LIVE=$!; }  # a process that stays alive for an entry to belong to
dead() { sleep 0 & DEAD=$!; wait "$DEAD"; }       # a pid whose process has ended
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb C=cccccccccccccccccccccccccccccccccccccccc
# shellcheck source=../../.claude/scripts/ci-queue.sh
. "$script"
q_init "$root/q1"
export CI_QUEUE_ROOT="$root/q1" CI_LOCAL_SLOTS=1

# 1. Entering: a new entry, the dedupe of a post of the same commit, and a run (not a post) of it never attaches.
live; p1=$LIVE; live; p2=$LIVE; live; p3=$LIVE; live; p4=$LIVE
e1=$(q_locked q_enter "$A" 145 post "PR #145" "$p1")
e2=$(q_locked q_enter "$A" 145 post "PR #145" "$p2")
e3=$(q_locked q_enter "$A" "" run "commit aaaaaaa" "$p3")
e4=$(q_locked q_enter "$B" 146 post "PR #146" "$p4")
check "1 the first entry is new" $([ "$e1" = "new 1" ]; echo $?)
check "1 a second post of the same commit attaches to it" $([ "$e2" = "attach 1" ]; echo $?)
check "1 a plain run of that commit is its own entry" $([ "$e3" = "new 2" ]; echo $?)
check "1 another commit is a new entry" $([ "$e4" = "new 3" ]; echo $?)
check "1 the entry holds what it is" $([ "$(q_get "$Q/1" sha)" = "$A" ] && [ "$(q_get "$Q/1" pid)" = "$p1" ] \
  && [ "$(q_get "$Q/1" host)" = "$(hostname)" ] && [ "$(q_get "$Q/1" state)" = queued ]; echo $?)
# Twenty posts of one commit at once: one entry, nineteen attach (the dedupe is atomic).
q_init "$root/q2"
ps=(); for i in $(seq 1 20); do q_locked q_enter "$C" 1 post x "$p1" > "$root/enter.$i" & ps+=($!); done; wait "${ps[@]}"
check "1 twenty posts of one commit at once give one entry" $([ "$(cat "$root"/enter.* | grep -c '^new ')" -eq 1 ] \
  && [ "$(cat "$root"/enter.* | grep -c '^attach 1$')" -eq 19 ] && [ "$(q_active | wc -l)" -eq 1 ]; echo $?)
q_init "$root/q1"

# 2. The order: position, who is ahead, who may start with one slot and with two.
check "2 positions" $([ "$(q_pos 1)" = 1 ] && [ "$(q_pos 2)" = 2 ] && [ "$(q_pos 3)" = 3 ]; echo $?)
check "2 the first may start, the others wait" $(q_may_start 1 && ! q_may_start 2 && ! q_may_start 3; echo $?)
check "2 the oldest ahead is named" $([ "$(q_ahead 3)" = 1 ] && ! q_ahead 1; echo $?)
check "2 two slots: the second may start, unless it is the same commit" \
  $(CI_LOCAL_SLOTS=2; ! q_may_start 2 && CI_LOCAL_SLOTS=3 q_may_start 3 && ! CI_LOCAL_SLOTS=2 q_may_start 3; echo $?)
q_locked q_finish 1 done 0
check "2 when the first ends, the next moves up" $(q_may_start 2 && [ "$(q_pos 3)" = 2 ] && [ "$(q_get "$Q/done/1" rc)" = 0 ]; echo $?)
check "2 two slots let a different commit start beside" $(CI_LOCAL_SLOTS=2 q_may_start 3 && ! q_may_start 3; echo $?)

# 3. State lines and the list.
q_locked q_set 2 state running
check "3 running" $([ "$(q_locked q_state "$A")" = "running #2 pid $p3" ]; echo $?)
check "3 queued" $([ "$(q_locked q_state "$B")" = "queued #3 pos 2 pid $p4" ]; echo $?)
check "3 none" $([ "$(q_locked q_state "$C")" = none ]; echo $?)
check "3 the command line agrees" $([ "$(bash "$script" state "$B")" = "queued #3 pos 2 pid $p4" ]; echo $?)
l=$(bash "$script" list)
check "3 list shows the live entries oldest first" $([ "$(wc -l <<<"$l")" -eq 2 ] && grep -q "^#2 running aaaaaaa $p3@" <<<"$l" \
  && sed -n 2p <<<"$l" | grep -q "^#3 queued bbbbbbb $p4@.* PR #146$"; echo $?)

# 4. Reaping: a dead pid, or a pid that now belongs to another process, is stale; the state says so.
dead
n=$(q_locked q_add "$C" 147 post "PR #147" "$DEAD")
out=$(q_locked q_state "$C" 2>&1)
check "4 a dead pid is reaped as stale" $([ ! -f "$Q/$n" ] && [ "$(q_get "$Q/done/$n" state)" = stale ] \
  && [ "$out" = "stale #$n pid $DEAD" ]; echo $?)
n=$(q_locked q_add "$C" 147 post "PR #147" "$p2")
q_locked q_set "$n" pstart 1
q_locked q_reap 2>/dev/null
check "4 a reused pid is stale too" $([ "$(q_get "$Q/done/$n" state)" = stale ]; echo $?)
n=$(q_locked q_add "$C" 147 post "PR #147" "$DEAD")
q_locked q_set "$n" host elsewhere
q_locked q_reap 2>/dev/null
check "4 an entry of another host is left alone" $([ -f "$Q/$n" ]; echo $?)
q_locked q_finish "$n" done 0
led="$root/ledger.jsonl"
( CI_LEDGER=$led; ci_ledger() { printf '%s\n' "$*" >> "$CI_LEDGER"; }; dead
  n=$(q_locked q_add "$C" 147 post x "$DEAD"); q_locked q_reap 2>/dev/null )
check "4 a reap writes a stale ledger line" $(grep -q '^stale --argjson n' "$led"; echo $?)
check "4 a stale entry no longer blocks a post of its commit" $([ "$(q_locked q_enter "$C" 147 post x "$p1" | cut -d' ' -f1)" = new ]; echo $?)

# 5. Waiting on an entry: its rc, and 75 when it went stale.
live; pw=$LIVE
n=$(q_locked q_add "$A" 1 post x "$pw")
( sleep 1; q_locked q_finish "$n" done 3 ) &
st=$(CI_LOCAL_LOCK_POLL=0.2 q_wait "$n"); rc=$?
check "5 q_wait returns the entry's rc" $([ "$st" = done ] && [ "$rc" -eq 3 ]; echo $?)
live; pw=$LIVE
n=$(q_locked q_add "$A" 1 post x "$pw")
( sleep 1; kill "$pw" ) &
st=$(CI_LOCAL_LOCK_POLL=0.2 q_wait "$n" 2>/dev/null); rc=$?
check "5 q_wait returns 75 when the entry went stale" $([ "$st" = stale ] && [ "$rc" -eq 75 ]; echo $?)

# 5a. A finished entry shows up in done/ whole: a slow writer (a slow date) never exposes an empty or half-written file
# (one without its state= line: q_wait reads it the moment it exists).
live; pw=$LIVE
n=$(q_locked q_add "$A" 1 post x "$pw")
( date() { sleep 1; command date "$@"; }; q_finish "$n" done 3 ) &
fw=$!; seen=1
for _ in $(seq 1 40); do
  if [ -e "$Q/done/$n" ]; then grep -q '^state=done$' "$Q/done/$n" && seen=0 || seen=1; break; fi
  sleep 0.05
done
wait "$fw"
check "5a done/<n> is never visible without its state" $seen

# 5b. Fail-fast (D6) asks whether another run waits: the oldest live queued entry other than the asker, if any.
q_init "$root/q5"
live; pa=$LIVE; live; pb=$LIVE
na=$(q_locked q_add "$A" 1 post x "$pa"); q_locked q_set "$na" state running
check "5b nothing else queued: none" $(! q_locked q_queued_other "$na" > /dev/null; echo $?)
nb=$(q_locked q_add "$B" 2 post x "$pb")
check "5b another run queued: it is named" $([ "$(q_locked q_queued_other "$na")" = "$nb" ]; echo $?)
q_locked q_set "$nb" state running
check "5b a running entry is not waiting" $(! q_locked q_queued_other "$na" > /dev/null; echo $?)
q_locked q_set "$nb" state queued; kill "$pb"; wait "$pb" 2>/dev/null
check "5b a queued entry whose process is gone does not count" $(! q_locked q_queued_other "$na" > /dev/null; echo $?)

# 6. Slots: slot 1 is .running, a held slot blocks, a lock of a dead process is taken over, two slots give .running.2.
q_init "$root/q3"
check "6 the first take gets slot 1" $(q_take_slot "$p1" "PR #1" && [ "$Q_SLOT" = 1 ] && [ "$Q_LOCK" = "$root/q3/.running" ] \
  && [ "$(cat "$Q_LOCK/pid")" = "$p1" ]; echo $?)
check "6 a held slot blocks and names its holder" $(! q_take_slot "$p2" "PR #2" && [ "$Q_HOLDER_PID" = "$p1" ] \
  && [ "$Q_HOLDER_WHAT" = "PR #1" ]; echo $?)
check "6 two slots give .running.2" $(CI_LOCAL_SLOTS=2 q_take_slot "$p2" "PR #2" && [ "$Q_SLOT" = 2 ] \
  && [ -d "$root/q3/.running.2" ]; echo $?)
dead; echo "$DEAD" > "$root/q3/.running/pid"
out=$(q_take_slot "$p3" "PR #3" 2>&1 >/dev/null; echo "slot=$Q_SLOT")
check "6 a lock of a dead process is taken over" $(grep -q "the local CI lock of pid $DEAD is stale" <<<"$out" \
  && grep -q slot=1 <<<"$out" && [ "$(cat "$root/q3/.running/pid")" = "$p3" ]; echo $?)

# 7. none-check: none after the grace when no entry comes, the state line when one comes in time.
q_init "$root/q4"
t0=$(date +%s)
out=$(CI_QUEUE_ROOT="$root/q4" CI_NONE_GRACE=1 CI_QUEUE_POLL=0.2 bash "$script" none-check "$A")
check "7 no entry within the grace gives none" $([ "$out" = none ] && [ $(( $(date +%s) - t0 )) -le 4 ]; echo $?)
( sleep 1; q_locked q_add "$A" 1 post x "$p1" > /dev/null ) &
out=$(CI_QUEUE_ROOT="$root/q4" CI_NONE_GRACE=10 CI_QUEUE_POLL=0.2 bash "$script" none-check "$A")
check "7 an entry that comes in time gives its state" $([ "$out" = "queued #1 pos 1 pid $p1" ]; echo $?)
check "7 usage errors exit 2" $(bash "$script" state > /dev/null 2>&1; [ $? -eq 2 ]; echo $?)

# 8. One slot by default (owner decision 2026-10-22): with CI_LOCAL_SLOTS unset the second commit waits. With two (D18),
# two commits go side by side, in .running and .running.2, and a third waits; a commit with the same 7-character prefix
# as one ahead waits even with a slot free (a run's folder, WSL clone and Docker names go by that prefix).
q_init "$root/q6"
A2=aaaaaaa000000000000000000000000000000000
live; pa=$LIVE; live; pb=$LIVE; live; pc=$LIVE
na=$(q_locked q_add "$A" 1 post x "$pa"); nb=$(q_locked q_add "$B" 2 post x "$pb"); nc=$(q_locked q_add "$C" 3 post x "$pc")
check "8 unset: one at a time, the second waits" $(unset CI_LOCAL_SLOTS; q_may_start "$na" && ! q_may_start "$nb"; echo $?)
check "8 two slots: two commits may start side by side, a third waits" $(CI_LOCAL_SLOTS=2; q_may_start "$na" && q_may_start "$nb" && ! q_may_start "$nc"; echo $?)
check "8 two slots: two are taken, a third take fails" $(CI_LOCAL_SLOTS=2; q_take_slot "$pa" a && [ "$Q_SLOT" = 1 ] \
  && q_take_slot "$pb" b && [ "$Q_SLOT" = 2 ] && [ -d "$root/q6/.running" ] && [ -d "$root/q6/.running.2" ] && ! q_take_slot "$pc" c; echo $?)
check "8 CI_LOCAL_SLOTS=1: the second waits" $(unset CI_LOCAL_SLOTS; ! q_may_start "$nb"; echo $?)
q_locked q_finish "$nc" done 0
live; pd=$LIVE
nd=$(q_locked q_add "$A2" 4 post x "$pd")
check "8 the same 7-character prefix as a run ahead waits, also with a slot free" $(CI_LOCAL_SLOTS=3; ! q_may_start "$nd"; echo $?)
q_locked q_finish "$na" done 0
check "8 two slots: it may start once that run ended" $(CI_LOCAL_SLOTS=2; q_may_start "$nd"; echo $?)

# 9. --force (TASK-68): a 6th argument "new" never attaches; without it the post still attaches. The forced entry waits
# for the live one (same 7-character prefix).
q_init "$root/q7"
export CI_QUEUE_ROOT="$root/q7"
live; p9a=$LIVE; live; p9b=$LIVE; live; p9c=$LIVE
n9a=$(q_locked q_add "$A" 1 post x "$p9a")
e9=$(q_locked q_enter "$A" 1 post x "$p9b" new)
check "9 q_enter with new adds a second entry beside a live post entry of the same commit" \
  $([ "$e9" = "new $((n9a + 1))" ] && [ "$(q_active | wc -l)" -eq 2 ]; echo $?)
check "9 the new entry may not start beside the live one" $(! q_may_start "${e9#new }"; echo $?)
e9b=$(q_locked q_enter "$A" 1 post x "$p9c")
check "9 q_enter without a 6th argument still attaches" $([ "${e9b%% *}" = attach ]; echo $?)

echo "ci-queue tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
