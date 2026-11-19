#!/usr/bin/env bash
# The one grammar of the local-ci/<job> commit status descriptions (CI plan 2026-10-20, C3; red team F2): every writer
# formats through these functions and every reader parses through ci_status_parse, so the forms cannot drift apart.
# Source it (`. ci-status-grammar.sh`) or run it: ci-status-grammar.sh format <form> <args...> | parse <state> <description>
#
# State     Description (at most 140 characters; GitHub cuts the rest)                        kind
# success   success in <s>s on <host>[; fp=<fp10>][; narrowed: archon-suites][; skipped-locally <n>]
#             [; green on rerun after <sig>]   ran (a pass; sig: the infra signature a --rerun-failed reran it after)
# failure   failure in <s>s on <host>[; fp=<fp10>][; narrowed: archon-suites][; skipped-locally <n>]   ran
# success   reused from <sha12>; fp=<fp10>; scope=<blob7>                                             reused
# success   reused from <sha12>; same tree   a merge commit whose tree its PR head's green run tested    same-tree
# failure   failure (infra: <reason>) on <host>     the runner could not run the job (worktree, wsl-checkout) infra
# failure   failure (<reason>) on <host>            the job did not run: a needed job failed, a merge conflict notrun
# failure   timed out after <m> min (ci.yml timeout-minutes)                                          timedout
# error     cancelled: <why>, not a pass                                                             cancelled
# error     superseded: PR #<n> head is now <sha7>, not run                                          superseded
# pending   queued #<n> pos <p> since <hh:mm>, pid <pid>@<host>                                       queued
# pending   running since <hh:mm>, pid <pid>@<host>                                                  running
# The descriptions posted before this grammar parse as kind legacy ("success in 21s on host, 2 step(s) skipped
# locally", "running on host"): such a success may hide a narrowed run, so a gate must not take it for a full pass.
# Anything else, or a description whose first word contradicts the state, is kind unknown: a reader fails closed on it.
# fp is the planner's input fingerprint (ci-plan.sh); until the planner runs, a ran status carries none.

ci_status_ran() { # ci_status_ran <success|failure> <secs> <host> [fp] [narrowed 0|1] [skipped-locally n] [rerun sig]
  local d="$1 in ${2}s on $3"
  [ -n "${4:-}" ] && d+="; fp=${4:0:10}"
  [ "${5:-0}" = 1 ] && d+="; narrowed: archon-suites"
  [ "${6:-0}" -gt 0 ] 2>/dev/null && d+="; skipped-locally $6"
  [ "$1" = success ] && [ -n "${7:-}" ] && d+="; green on rerun after ${7//;/,}"
  printf '%s' "$d"
}
ci_status_reused() { printf 'reused from %s; fp=%s; scope=%s' "${1:0:12}" "${2:0:10}" "${3:0:7}"; } # <sha> <fp> <blob>
ci_status_same_tree() { printf 'reused from %s; same tree' "${1:0:12}"; }   # <pull request head sha> (2026-10-23)
ci_status_infra() { printf 'failure (infra: %s) on %s' "$1" "$2"; }       # <reason> <host>
ci_status_notrun() { printf 'failure (%s) on %s' "$1" "$2"; }             # <reason> <host>
ci_status_timedout() { printf 'timed out after %s min (ci.yml timeout-minutes)' "$1"; }
ci_status_cancelled() { printf 'cancelled: %s, not a pass' "$1"; }        # <why>
ci_status_superseded() { printf 'superseded: PR #%s head is now %s, not run' "$1" "${2:0:7}"; }
ci_status_queued() { # <n> <pos> <pid> <host> [hh:mm]
  printf 'queued #%s pos %s since %s, pid %s@%s' "$1" "$2" "${5:-$(date +%H:%M)}" "$3" "$4"
}
ci_status_running() { printf 'running since %s, pid %s@%s' "${3:-$(date +%H:%M)}" "$1" "$2"; } # <pid> <host> [hh:mm]

# ci_status_parse <state> <description>: one key=value per line, kind first; never evaluate the output, a status can be
# posted by anyone with write access. Keys: kind state secs host fp narrowed skipped from scope reason n pos since pid
# minutes legacy rerun (the sig of `green on rerun after <sig>`, a pass).
ci_status_parse() {
  local state=$1 d=$2 rest tok kind=unknown
  local secs="" host="" fp="" rerun="" narrowed=0 skipped=0 from="" scope="" reason="" n="" pos="" since="" pid="" minutes="" legacy=0
  if [[ "$d" =~ ^(success|failure)\ in\ ([0-9]+)s\ on\ ([^\;,\ ]+)(,\ ([0-9]+)\ step\(s\)\ skipped\ locally)?(\;\ .*)?$ ]]; then
    kind=ran secs=${BASH_REMATCH[2]} host=${BASH_REMATCH[3]} rest=${BASH_REMATCH[6]#; }
    [ "${BASH_REMATCH[1]}" = "$state" ] || kind=unknown
    if [ -n "${BASH_REMATCH[4]}" ]; then legacy=1 skipped=${BASH_REMATCH[5]}; fi
    while [ -n "$rest" ] && [ "$kind" = ran ]; do
      tok=${rest%%; *}; [ "$tok" = "$rest" ] && rest="" || rest=${rest#*; }
      if [[ "$tok" =~ ^fp=([0-9a-f]{1,64})$ ]]; then fp=${BASH_REMATCH[1]}
      elif [ "$tok" = "narrowed: archon-suites" ]; then narrowed=1
      elif [[ "$tok" =~ ^skipped-locally\ ([0-9]+)$ ]] && [ "$legacy" = 0 ]; then skipped=${BASH_REMATCH[1]}
      elif [[ "$tok" =~ ^green\ on\ rerun\ after\ ([^\;]+)$ ]] && [ "$state" = success ] && [ -z "$rest" ]; then
        rerun=${BASH_REMATCH[1]}
      else kind=unknown
      fi
    done
  elif [[ "$d" =~ ^reused\ from\ ([0-9a-f]{12})\;\ fp=([0-9a-f]{10})\;\ scope=([0-9a-f]{7})$ ]]; then
    [ "$state" = success ] && kind=reused from=${BASH_REMATCH[1]} fp=${BASH_REMATCH[2]} scope=${BASH_REMATCH[3]}
  elif [[ "$d" =~ ^reused\ from\ ([0-9a-f]{12})\;\ same\ tree$ ]]; then
    [ "$state" = success ] && kind=same-tree from=${BASH_REMATCH[1]}
  elif [[ "$d" =~ ^failure\ \(infra:\ ([^\)]+)\)\ on\ ([^\;,\ ]+)$ ]]; then
    [ "$state" = failure ] && kind=infra reason=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]}
  elif [[ "$d" =~ ^failure\ \(([^\)]+)\)\ on\ ([^\;,\ ]+)$ ]]; then
    [ "$state" = failure ] && kind=notrun reason=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]}
  elif [[ "$d" =~ ^timed\ out\ after\ ([0-9]+(\.[0-9]+)?)\ min ]]; then
    [ "$state" = failure ] && kind=timedout minutes=${BASH_REMATCH[1]}
  elif [[ "$d" =~ ^cancelled:\ (.*),\ not\ a\ pass$ ]]; then
    [ "$state" = error ] && kind=cancelled reason=${BASH_REMATCH[1]}
  elif [[ "$d" =~ ^superseded:\ PR\ \#([0-9]+)\ head\ is\ now\ ([0-9a-f]{7}),\ not\ run$ ]]; then
    [ "$state" = error ] && kind=superseded n=${BASH_REMATCH[1]} from=${BASH_REMATCH[2]}
  elif [[ "$d" =~ ^queued\ \#([0-9]+)\ pos\ ([0-9]+)\ since\ ([0-9:]+),\ pid\ ([0-9]+)@([^\ ]+)$ ]]; then
    [ "$state" = pending ] && kind=queued n=${BASH_REMATCH[1]} pos=${BASH_REMATCH[2]} since=${BASH_REMATCH[3]} \
      pid=${BASH_REMATCH[4]} host=${BASH_REMATCH[5]}
  elif [[ "$d" =~ ^running\ since\ ([0-9:]+),\ pid\ ([0-9]+)@([^\ ]+)$ ]]; then
    [ "$state" = pending ] && kind=running since=${BASH_REMATCH[1]} pid=${BASH_REMATCH[2]} host=${BASH_REMATCH[3]}
  elif [[ "$d" =~ ^running\ on\ ([^\ ]+)$ ]]; then
    [ "$state" = pending ] && kind=running host=${BASH_REMATCH[1]} legacy=1
  fi
  if [ "$kind" = unknown ]; then
    printf 'kind=unknown\nstate=%s\n' "$state"; return 0
  fi
  printf 'kind=%s\nstate=%s\nsecs=%s\nhost=%s\nfp=%s\nnarrowed=%s\nskipped=%s\nfrom=%s\nscope=%s\nreason=%s\nn=%s\npos=%s\nsince=%s\npid=%s\nminutes=%s\nlegacy=%s\nrerun=%s\n' \
    "$kind" "$state" "$secs" "$host" "$fp" "$narrowed" "$skipped" "$from" "$scope" "$reason" "$n" "$pos" "$since" "$pid" \
    "$minutes" "$legacy" "$rerun"
}

# ci_status_get <key> <state> <description>: one field of the parse.
ci_status_get() { ci_status_parse "$2" "$3" | sed -n "s/^$1=//p"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    format)
      form=${2:-}; shift 2 2>/dev/null || shift $#
      case "$form" in
        ran|reused|infra|notrun|timedout|cancelled|superseded|queued|running) "ci_status_$form" "$@"; echo ;;
        same-tree) ci_status_same_tree "$@"; echo ;;
        *) echo "ci-status-grammar: unknown form '$form'" >&2; exit 2 ;;
      esac ;;
    parse) [ $# -eq 3 ] || { echo "usage: ci-status-grammar.sh parse <state> <description>" >&2; exit 2; }
      ci_status_parse "$2" "$3" ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
fi
