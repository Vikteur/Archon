#!/usr/bin/env bash
# The local CI queue (CI plan 2026-10-20, C6; closes TASK-68): one visible first-come-first-served queue in front of
# the run locks, so a waiting run shows on its commit at once, runs in the order it asked, and one commit is never run
# twice side by side.
#   Source it (ci-local.sh does) after setting CI_QUEUE_ROOT, or run it:
#     ci-queue.sh list                  the live entries, oldest first: #n state sha pid@host since what
#     ci-queue.sh state <sha>           one line: queued #n pos p pid N | running #n pid N | stale #n pid N | none
#     ci-queue.sh none-check <sha>      waits up to CI_NONE_GRACE (60) seconds for an entry of <sha>; prints "none" when
#                                       none came (the caller then answers "no run" after 60 s, not after 600), else
#                                       the state line of the entry that came
# State lives in $CI_QUEUE_ROOT/.queue (default: ci-local/ beside the main checkout): one file <n> per live entry
# (key=value lines: n sha pr mode what pid pstart host t state), moved to .queue/done/<n> when it ends with its rc.
# Every change happens under one mutex (flock on .queue/.mutex), so adding an entry and the check for a live entry of the
# same commit (the dedupe) are one atomic step. An entry whose process is gone (its pid ended, or the pid now belongs to
# another process: the start time from /proc/<pid>/stat no longer matches) is reaped as "stale".
# Slots: CI_LOCAL_SLOTS (default 1, owner decision 2026-10-22; D18's 2 lets two side by side) runs may hold a slot at a time.
# Slot 1 is the lock folder .running (the lock of the runner before the queue, so an older runner and this one still
# exclude each other), slot k > 1 is .running.<k>. An entry may take a slot when fewer than CI_LOCAL_SLOTS live entries
# are ahead of it and none of them is the same commit, or a commit with the same 7-character prefix: a run's folder,
# WSL clone, image tag and container names are named by that prefix (ci-local.sh), so two such runs never go side by
# side.

q_init() { # q_init [root]
  CI_QUEUE_ROOT=${1:-${CI_QUEUE_ROOT:?CI_QUEUE_ROOT is not set}}
  Q="$CI_QUEUE_ROOT/.queue"
  mkdir -p "$Q/done"
}

q_locked() { # q_locked <command...>: runs it under the queue mutex
  if command -v flock > /dev/null; then
    ( flock -w 60 9 || { echo "ci-queue: the queue mutex is held for over 60 s" >&2; exit 75; }; "$@" ) 9>>"$Q/.mutex"
  else
    ( local i=0
      until mkdir "$Q/.mutex.d" 2>/dev/null; do
        i=$((i + 1)); [ $i -gt 600 ] && { echo "ci-queue: the queue mutex is held for over 60 s" >&2; exit 75; }; sleep 0.1
      done
      trap 'rmdir "$Q/.mutex.d" 2>/dev/null' EXIT
      "$@" )
  fi
}

q_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; } # q_get <file> <key>

q_pstart() { # q_pstart <pid>: the process start time (field 22 of /proc/<pid>/stat), empty where there is no /proc
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  s=${s##*) }
  set -- $s
  printf '%s' "${20:-}"
}

q_alive() { # q_alive <entry file>: its process still runs (an entry of another host is taken as alive)
  local pid start host
  pid=$(q_get "$1" pid) start=$(q_get "$1" pstart) host=$(q_get "$1" host)
  [ "$host" = "$(hostname)" ] || return 0
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  [ -z "$start" ] || [ "$(q_pstart "$pid")" = "$start" ] || [ -z "$(q_pstart "$pid")" ]
}

q_active() { # the live entry numbers, oldest first
  local f
  for f in "$Q"/[0-9]*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done | sort -n
}

q_set() { # q_set <n> <key> <value>: under the mutex; a file write is a rename, so a reader never sees half of one
  local f="$Q/$1"
  [ -f "$f" ] || return 1
  { grep -v "^$2=" "$f"; printf '%s=%s\n' "$2" "$3"; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

q_finish() { # q_finish <n> <state> [rc]: under the mutex; the entry leaves the queue for done/
  local f="$Q/$1" tmp="$Q/done/.$1.$$"
  [ -f "$f" ] || return 0
  { grep -v -e '^state=' -e '^rc=' "$f"; printf 'state=%s\nrc=%s\nt_end=%s\n' "$2" "${3:-}" "$(date -u +%s)"; } \
    > "$tmp" && mv -f "$tmp" "$Q/done/$1" && rm -f "$f"  # tmp + mv: a q_wait poll never reads a half-written file
}

q_reap() { # under the mutex: every live entry whose process is gone becomes stale
  local n
  for n in $(q_active); do
    q_alive "$Q/$n" && continue
    echo "ci-queue: entry #$n ($(q_get "$Q/$n" sha | cut -c1-7), pid $(q_get "$Q/$n" pid)) is stale: its process is gone" >&2
    declare -F ci_ledger > /dev/null && ci_ledger stale --argjson n "$n" --arg sha "$(q_get "$Q/$n" sha)" \
      --arg pid "$(q_get "$Q/$n" pid)"
    q_finish "$n" stale
  done
}

q_live_of() { # q_live_of <sha> [mode]: the oldest live entry of <sha> (of that mode), if any
  local n
  for n in $(q_active); do
    [ "$(q_get "$Q/$n" sha)" = "$1" ] || continue
    [ -z "${2:-}" ] || [ "$(q_get "$Q/$n" mode)" = "$2" ] || continue
    echo "$n"; return 0
  done
  return 1
}

q_add() { # q_add <sha> <pr> <mode> <what> <pid>: under the mutex; prints the new entry's number
  local n
  n=$(( $(cat "$Q/.seq" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$Q/.seq"
  printf 'n=%s\nsha=%s\npr=%s\nmode=%s\nwhat=%s\npid=%s\npstart=%s\nhost=%s\nt=%s\nstate=queued\n' \
    "$n" "$1" "$2" "$3" "$4" "$5" "$(q_pstart "$5")" "$(hostname)" "$(date -u +%s)" > "$Q/$n.tmp" && mv -f "$Q/$n.tmp" "$Q/$n"
  echo "$n"
}

# q_enter <sha> <pr> <mode> <what> <pid> [attach|new], under the mutex: "attach <n>" when <mode> is post and a live post
# entry of the same commit exists (the dedupe: its result is the answer), else "new <n>" for a new entry. A 6th argument
# "new" never attaches (--force, TASK-68).
q_enter() {
  local n how=${6:-attach}
  q_reap
  if [ "$how" = attach ] && [ "$3" = post ] && n=$(q_live_of "$1" post); then echo "attach $n"; return 0; fi
  echo "new $(q_add "$1" "$2" "$3" "$4" "$5")"
}

q_queued_other() { # q_queued_other <n>: the oldest live entry other than <n> still waiting its turn (fail-fast, D6)
  local e
  for e in $(q_active); do
    [ "$e" = "$1" ] && continue
    [ "$(q_get "$Q/$e" state)" = queued ] && q_alive "$Q/$e" && { echo "$e"; return 0; }
  done
  return 1
}

q_pos() { # q_pos <n>: its place among the live entries (1 = first)
  local m p=1
  for m in $(q_active); do [ "$m" -lt "$1" ] && p=$((p + 1)); done
  echo "$p"
}

q_ahead() { # q_ahead <n>: the oldest live entry ahead of it, if any
  local m
  for m in $(q_active); do [ "$m" -lt "$1" ] && { echo "$m"; return 0; }; done
  return 1
}

q_may_start() { # q_may_start <n>: fewer than CI_LOCAL_SLOTS live entries are ahead of it, none of them its own commit (sha7)
  local m ahead=0 sha
  sha=$(q_get "$Q/$1" sha)
  for m in $(q_active); do
    [ "$m" -lt "$1" ] || continue
    ahead=$((ahead + 1))
    [ "$(q_get "$Q/$m" sha | cut -c1-7)" = "${sha:0:7}" ] && return 1
  done
  [ "$ahead" -lt "${CI_LOCAL_SLOTS:-1}" ]
}

q_slot_lock() { if [ "$1" = 1 ]; then echo "$CI_QUEUE_ROOT/.running"; else echo "$CI_QUEUE_ROOT/.running.$1"; fi; }

# q_take_slot <pid> <what>: takes a free slot (a lock whose process is gone is taken over), sets Q_SLOT and Q_LOCK.
# Returns 1 when every slot is held; Q_HOLDER_PID and Q_HOLDER_WHAT then name the holder of slot 1.
q_take_slot() {
  local k lock holder
  Q_HOLDER_PID="" Q_HOLDER_WHAT=""
  for k in $(seq 1 "${CI_LOCAL_SLOTS:-1}"); do
    lock=$(q_slot_lock "$k")
    if mkdir "$lock" 2>/dev/null; then
      echo "$1" > "$lock/pid"; echo "$2" > "$lock/what"
      Q_SLOT=$k Q_LOCK=$lock; return 0
    fi
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      echo "the local CI lock of pid $holder is stale (the process is gone); taking over" >&2
      [ "$(cat "$lock/pid" 2>/dev/null)" = "$holder" ] && rm -rf "$lock"
      if mkdir "$lock" 2>/dev/null; then
        echo "$1" > "$lock/pid"; echo "$2" > "$lock/what"
        Q_SLOT=$k Q_LOCK=$lock; return 0
      fi
    fi
    [ "$k" = 1 ] && Q_HOLDER_PID=${holder:-?} Q_HOLDER_WHAT=$(cat "$lock/what" 2>/dev/null)
  done
  return 1
}

# q_wait <n>: waits until entry <n> has ended (a look every CI_LOCAL_LOCK_POLL, default 2, seconds), reaping it when its
# process dies; prints its final state and returns its rc (75 when it went stale, so the caller can queue again).
q_wait() {
  local f="$Q/done/$1" state rc
  until [ -f "$f" ]; do
    q_locked q_reap 2>/dev/null
    [ -f "$f" ] || sleep "${CI_LOCAL_LOCK_POLL:-2}"
  done
  state=$(q_get "$f" state) rc=$(q_get "$f" rc)
  echo "$state"
  [ "$state" = stale ] && return 75
  return "${rc:-1}"
}

q_state() { # q_state <sha>, under the mutex: the line ci-queue.sh state prints
  local n last
  q_reap 2>/dev/null
  if n=$(q_live_of "$1"); then
    if [ "$(q_get "$Q/$n" state)" = running ]; then echo "running #$n pid $(q_get "$Q/$n" pid)"
    else echo "queued #$n pos $(q_pos "$n") pid $(q_get "$Q/$n" pid)"
    fi
    return 0
  fi
  last=$(grep -lx "sha=$1" "$Q"/done/[0-9]* 2>/dev/null | sed 's#.*/##' | sort -n | tail -1)
  if [ -n "$last" ] && [ "$(q_get "$Q/done/$last" state)" = stale ]; then
    echo "stale #$last pid $(q_get "$Q/done/$last" pid)"
  else
    echo none
  fi
}

q_list() {
  local n
  for n in $(q_active); do
    printf '#%s %s %s %s@%s since %s %s\n' "$n" "$(q_get "$Q/$n" state)" "$(q_get "$Q/$n" sha | cut -c1-7)" \
      "$(q_get "$Q/$n" pid)" "$(q_get "$Q/$n" host)" "$(date -d "@$(q_get "$Q/$n" t)" +%H:%M 2>/dev/null)" "$(q_get "$Q/$n" what)"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  if [ -z "${CI_QUEUE_ROOT:-}" ]; then
    main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    CI_QUEUE_ROOT=${CI_LOCAL_ROOT:-$(dirname "${main:-$PWD}")/ci-local}
  fi
  q_init "$CI_QUEUE_ROOT"
  case "${1:-}" in
    list) q_locked q_reap 2>/dev/null; q_list ;;
    state) [ -n "${2:-}" ] || { echo "usage: ci-queue.sh state <sha>" >&2; exit 2; }; q_locked q_state "$2" ;;
    none-check)
      [ -n "${2:-}" ] || { echo "usage: ci-queue.sh none-check <sha>" >&2; exit 2; }
      end=$(( $(date +%s) + ${CI_NONE_GRACE:-60} ))
      while :; do
        s=$(q_locked q_state "$2")
        case "$s" in none|stale*) ;; *) echo "$s"; exit 0 ;; esac
        [ "$(date +%s)" -ge "$end" ] && { echo none; exit 0; }
        sleep "${CI_QUEUE_POLL:-2}"
      done ;;
    *) sed -n '2,22p' "$0"; exit 2 ;;
  esac
fi
