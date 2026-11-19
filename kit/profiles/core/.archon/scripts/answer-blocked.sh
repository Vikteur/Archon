#!/usr/bin/env bash
# Answer a blocked build-feature run (P2: a script, not a model; owner decision 2026-10-18, docs/memory.md, TASK-55).
#   answer-blocked.sh <run's plan.md> <answer...>
# blocked-stop.sh failed the run on a `BLOCKED: <question>` line and named its plan.md. This replaces the first such
# line by `ANSWER: <answer> (to: <question>)`, which the agents read, and leaves the rest of the plan as it was. Call it
# once per BLOCKED line; once none is left, `archon workflow resume <run id>` goes on.
# Exit 0: answered (it says how many BLOCKED lines are left). Exit 1: the plan has no BLOCKED line. Exit 2: usage, a
# file that is not a plan.md, or an empty or multi-line answer.
set -uo pipefail
plan=${1:-}
shift || true
answer=$*
usage() { echo "answer-blocked: $*" >&2; echo "usage: answer-blocked.sh <run's plan.md> <answer...>" >&2; exit 2; }
[ -n "$plan" ] || usage "no plan given"
[ "$(basename "$plan")" = plan.md ] && [ -f "$plan" ] || usage "$plan is not a run's plan.md"
[ -n "${answer//[[:space:]]/}" ] || usage "the answer is empty"
case "$answer" in *$'\n'*|*$'\r'*) usage "the answer must be one line" ;; esac
grep -qE '^BLOCKED:' "$plan" || { echo "answer-blocked: $plan has no BLOCKED line" >&2; exit 1; }

tmp=$(mktemp "$plan.XXXXXX") || exit 1
ANSWER=$answer awk '!done && /^BLOCKED:/ { q = $0; sub(/^BLOCKED:[ \t]*/, "", q); print "ANSWER: " ENVIRON["ANSWER"] " (to: " q ")"; done = 1; next } { print }' \
  "$plan" > "$tmp" && mv "$tmp" "$plan" || { rm -f "$tmp"; echo "answer-blocked: cannot write $plan" >&2; exit 1; }
left=$(grep -cE '^BLOCKED:' "$plan")
if [ "$left" -gt 0 ]; then echo "answered; $left BLOCKED line left in $plan"
else echo "answered; no BLOCKED line left: archon workflow resume <run id>"; fi
