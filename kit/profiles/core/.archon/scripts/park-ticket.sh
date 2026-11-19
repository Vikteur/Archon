#!/usr/bin/env bash
# Park a ticket by label, so a held ticket stops blocking its lane (P2: a script, not a model; owner decision D10,
# 2026-10-20: park by label, never demote, because a demote renames the id, 773c0d32).
#   park-ticket.sh <TASK-id> -m <why> [--run <run id>] [--pr <pr url>] [--no-commit]
#   park-ticket.sh --unpark <TASK-id> -m <why> [--no-commit]
# The reason may also follow the id as a plain argument (`park-ticket.sh TASK-6.1 "held: STOP item"`), not both.
# Park adds the label `parked` and appends a note "Parked <Brussels time>: <why>" (with the run and the pull request
# when given) to the ticket's implementation notes. pick-tickets.js then leaves a parked In Progress ticket out of busy
# and its run out of the cap, and skips a parked To Do ticket. With --pr it takes the pull request out of the merge
# queue (`merge-turn.sh drop`; not queued is fine); with --run it clears the run's ready record (`ready-runs.sh clear`),
# or `ready-runs.sh wait` would return at once on every call. --unpark removes the label and appends an "Unparked" note.
# Then the ticket's file is committed to main with commit-tickets.sh, unless --no-commit (the picker reads the main
# checkout, so the label works before it is on origin/main).
# It never changes the ticket's status or id, and never cancels, resumes or approves a run. A rerun is idempotent: the
# label and the note are added only when the label changes; the drop, the clear and a pending commit are repeated.
# Run it from any checkout: the backlog commands run in the main checkout (AGENTS.md).
# Exit 0: done. Exit 1: a step failed (it says which; the steps before it stay done). Exit 2: usage. Exit 3: parked
# (or unparked) in the main checkout, but the commit to main failed or was refused; run commit-tickets.sh <id> later.
# Override for the tests: PARK_SCRIPTS_DIR, the folder of merge-turn.sh, ready-runs.sh and commit-tickets.sh.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts=${PARK_SCRIPTS_DIR:-$here}
usage() {
  [ -n "${1:-}" ] && echo "park-ticket: $1" >&2
  echo "usage: park-ticket.sh [--unpark] <TASK-id> (-m <why> | <why>) [--run <run id>] [--pr <pr url>] [--no-commit]" >&2
  exit 2
}
fail() { echo "park-ticket: $*" >&2; exit 1; }

unpark="" id="" why="" pos_why="" run="" pr="" commit=1
while [ $# -gt 0 ]; do
  case "$1" in
    --unpark) unpark=1 ;;
    -m) [ -n "${2:-}" ] || usage "-m needs a reason"; why=$2; shift ;;
    --run) [[ "${2:-}" =~ ^[0-9a-f]{8,}$ ]] || usage "--run needs a run id"; run=$2; shift ;;
    --pr) [[ "${2:-}" =~ ^https://github\.com/.+/pull/[0-9]+$ ]] || usage "--pr needs a pull request url"; pr=$2; shift ;;
    --no-commit) commit="" ;;
    *) if [ -z "$id" ] && [[ "$1" =~ ^[Tt][Aa][Ss][Kk]-[0-9]+(\.[0-9]+)*$ ]]; then id="TASK-${1:5}"
       elif [ -n "$id" ] && [ -z "$pos_why" ] && [ -n "$1" ] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ ^[Tt][Aa][Ss][Kk]-[0-9] ]]; then pos_why=$1
       else usage "unexpected argument: $1"; fi ;;
  esac
  shift
done
[ -n "$why" ] && [ -n "$pos_why" ] && usage "give the reason once: -m or a plain argument"
why=${why:-$pos_why}
[ -n "$id" ] && [ -n "$why" ] || usage
[ -n "$unpark" ] && [ -n "$run$pr" ] && usage "--unpark takes no --run or --pr"

main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main" ] && cd "$main" || fail "not in a git checkout"

view() { backlog task view "$id" --json 2>/dev/null | jq -ce '.task // .' 2>/dev/null; }
before=$(view) || fail "cannot read $id with backlog task view"
status=$(jq -r '.status' <<< "$before")
has_label=$(jq -r '(.labels // []) | index("parked") != null' <<< "$before")
when=$(TZ=Europe/Brussels date '+%Y-%m-%d %H:%M %Z')

if [ -z "$unpark" ] && [ "$has_label" = false ]; then
  note="Parked $when: $why"
  [ -n "$run" ] && note+="; run $run"
  [ -n "$pr" ] && note+="; PR $pr"
  backlog task edit "$id" --add-label parked --append-notes "$note" >/dev/null 2>&1 || fail "backlog task edit $id (add the label) failed"
  echo "parked $id"
elif [ -n "$unpark" ] && [ "$has_label" = true ]; then
  backlog task edit "$id" --remove-label parked --append-notes "Unparked $when: $why" >/dev/null 2>&1 \
    || fail "backlog task edit $id (remove the label) failed"
  echo "unparked $id"
else
  echo "$id is already $([ -n "$unpark" ] && echo unparked || echo parked)"
fi

after=$(view) || fail "cannot read $id again after the edit"
[ "$(jq -r '.status' <<< "$after")" = "$status" ] && [ "$(jq -r '.id' <<< "$after")" = "$(jq -r '.id' <<< "$before")" ] \
  || fail "$id changed its status or id; a person checks it"

if [ -n "$pr" ]; then
  bash "$scripts/merge-turn.sh" drop "$pr" >/dev/null 2>&1; rc=$?
  case $rc in 0) echo "dropped $pr from the merge queue" ;; 1) echo "$pr was not in the merge queue" ;; *) fail "merge-turn.sh drop $pr failed ($rc)" ;; esac
fi
if [ -n "$run" ]; then
  bash "$scripts/ready-runs.sh" clear "$run" >/dev/null 2>&1 || fail "ready-runs.sh clear $run failed"
  echo "cleared the ready record of $run"
fi

[ -n "$commit" ] || exit 0
prefix="task-${id:5} - "
pending=""
while IFS= read -r -d '' entry; do
  p=${entry:3}
  case "${p##*/}" in "$prefix"*) pending=1 ;; esac
done < <(git status -z --porcelain=v1 --untracked-files=all --no-renames -- backlog/)
[ -n "$pending" ] || exit 0
if bash "$scripts/commit-tickets.sh" "$id" -m "$([ -n "$unpark" ] && echo unpark || echo park) $id: $why" >/dev/null; then
  echo "committed $id to main"
  exit 0
fi
echo "park-ticket: the label is set in the main checkout, but the commit to main failed; run commit-tickets.sh $id later" >&2
exit 3
