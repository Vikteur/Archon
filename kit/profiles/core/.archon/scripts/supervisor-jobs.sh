#!/usr/bin/env bash
# The jobs the delegator supervisor may run, as exact commands (P2; owner decision 2026-10-20, D15: a supervisor
# timer, shadow first; ROADMAP R20). supervisor-tick.sh and supervisor-judge.sh build every command through this
# script, so a command is always one of these shapes, its arguments are checked before they go into it, and
# supervisor-fence.test.sh can check each shape against the scope guard as the delegator. Nothing here runs a job.
#   supervisor-jobs.sh list                       every job: "<kind><TAB><command shape>"
#   supervisor-jobs.sh cmd merge <pr url>         bash .archon/scripts/merge-ready.sh <pr url>
#   supervisor-jobs.sh cmd hold <pr url> <reason> bash .archon/scripts/merge-ready.sh <pr url> --hold --reason <reason>
#   supervisor-jobs.sh cmd recover <run id>       bash .archon/scripts/recover-run.sh <run id>
#   supervisor-jobs.sh cmd recover-dry <run id>   bash .archon/scripts/recover-run.sh <run id> --dry-run
#   supervisor-jobs.sh cmd launch <TASK-id>       bash .archon/scripts/sync-main.sh && bash .archon/scripts/launch-run.sh
#                                                 <TASK-id>   (the run starts as "<TASK-id>: <label>")
#   supervisor-jobs.sh cmd cleanup                bash .archon/scripts/cleanup-merged.sh --sweep
#   supervisor-jobs.sh cmd ping <info|warn|act> <key> <subject>
#                                                 bash .archon/scripts/notify-owner.sh <level> <key> <subject>
# Arguments: a pr url is https://github.com/<owner>/<repo>/pull/<n>; a run id is 8 to 64 hex digits; a TASK id is
# TASK-<n>[.<n>...]; a key is letters, digits and . _ : -. A reason or subject is free text, at most 300 characters,
# shell-quoted into the command, never evaluated.
# Exit codes: 0 printed, 2 usage or an argument that fails its check (nothing printed).
set -uo pipefail

die() { echo "supervisor-jobs: $*" >&2; exit 2; }
pr_ok() { [[ $1 =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || die "not a pull request url: $1"; }
run_ok() { [[ $1 =~ ^[0-9a-f]{8,64}$ ]] || die "not a run id: $1"; }
task_ok() { [[ $1 =~ ^TASK-[0-9]+(\.[0-9]+)*$ ]] || die "not a TASK id: $1"; }
key_ok() { [[ $1 =~ ^[A-Za-z0-9._:-]{1,200}$ ]] || die "not a key: $1"; }
text_ok() { [ -n "$1" ] && [ "${#1}" -le 300 ] && [[ $1 != *$'\n'* ]] || die "text must be one line of 1 to 300 characters"; }
argc() { [ "$1" -eq "$2" ] || die "$3 takes $(( $2 )) argument(s)"; }

case "${1:-}" in
  list)
    printf '%s\t%s\n' \
      merge 'bash .archon/scripts/merge-ready.sh <pr url>' \
      hold 'bash .archon/scripts/merge-ready.sh <pr url> --hold --reason <reason>' \
      recover 'bash .archon/scripts/recover-run.sh <run id>' \
      recover-dry 'bash .archon/scripts/recover-run.sh <run id> --dry-run' \
      launch 'bash .archon/scripts/sync-main.sh && bash .archon/scripts/launch-run.sh <TASK-id>' \
      cleanup 'bash .archon/scripts/cleanup-merged.sh --sweep' \
      ping 'bash .archon/scripts/notify-owner.sh <level> <key> <subject>'
    ;;
  cmd)
    shift; kind=${1:-}; shift || true
    case "$kind" in
      merge) argc $# 1 merge; pr_ok "$1"; echo "bash .archon/scripts/merge-ready.sh $1" ;;
      hold) argc $# 2 hold; pr_ok "$1"; text_ok "$2"; echo "bash .archon/scripts/merge-ready.sh $1 --hold --reason $(printf '%q' "$2")" ;;
      recover) argc $# 1 recover; run_ok "$1"; echo "bash .archon/scripts/recover-run.sh $1" ;;
      recover-dry) argc $# 1 recover-dry; run_ok "$1"; echo "bash .archon/scripts/recover-run.sh $1 --dry-run" ;;
      launch) argc $# 1 launch; task_ok "$1"; echo "bash .archon/scripts/sync-main.sh && bash .archon/scripts/launch-run.sh $1" ;;
      cleanup) argc $# 0 cleanup; echo "bash .archon/scripts/cleanup-merged.sh --sweep" ;;
      ping) argc $# 3 ping
        case "$1" in info|warn|act) ;; *) die "ping level is info, warn or act: $1" ;; esac
        key_ok "$2"; text_ok "$3"
        echo "bash .archon/scripts/notify-owner.sh $1 $(printf '%q' "$2") $(printf '%q' "$3")" ;;
      *) die "unknown job: ${kind:-none} (see: supervisor-jobs.sh list)" ;;
    esac ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "usage: supervisor-jobs.sh list | cmd <kind> <args...>" ;;
esac
