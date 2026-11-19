#!/usr/bin/env bash
# The stop for a blocked plan (P2: a script, not a model). An agent that cannot go on without an answer writes one line
# `BLOCKED: <question>` in plan.md; this fails the node it runs in with that question, so the run stops at the step
# that asked, inside the build loop, and never reaches the gates after it (skill-check, tdd-check) with steps nobody
# built. It runs as a node of the loop body, so the failed node is the loop: `archon workflow resume` runs the loop
# again from the first open step once the owner has answered.
#   blocked-stop.sh <artifacts-dir> [<run id>]
# No `BLOCKED:` line: exit 0, silent. Otherwise the question goes to stderr and to <artifacts-dir>/blocked.md, with how
# to answer: replace each `BLOCKED:` line by `ANSWER: <the answer>` (the agents read it), then resume the run. Exit 1.
set -uo pipefail
art=${1:?usage: blocked-stop.sh <artifacts-dir> [<run id>]}
run=${2:-<run id>}
plan="$art/plan.md"
[ -f "$plan" ] || exit 0
questions=$(grep -E '^BLOCKED:' "$plan" | tr -d '\r')
[ -n "$questions" ] || exit 0

msg=$(cat <<EOF
The run stopped: an agent needs the owner's answer before it can go on.
$questions
To go on: in $plan, replace each BLOCKED: line by ANSWER: <your answer>, then run
  archon workflow resume $run
The build loop then takes the first open step again. To end the run instead: bash .archon/scripts/stop-run.sh $run <reason>
EOF
)
printf '# Blocked\n\n```\n%s\n```\n' "$msg" > "$art/blocked.md"
printf '%s\n' "$msg" >&2
exit 1
