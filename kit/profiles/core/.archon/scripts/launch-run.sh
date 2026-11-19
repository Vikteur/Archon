#!/usr/bin/env bash
# Start a build-feature run on one ticket, its request naming the ticket and what it builds:
# `TASK-7.4: sign in` (run-label.js), so the console's run list and run log show more than the bare id.
#   launch-run.sh <TASK-id>
# Runs `archon workflow run build-feature --detach "<request>"` from the current directory (the main checkout, where
# Backlog and the run's base live). A ticket Backlog cannot read starts as the bare `<TASK-id>`.
# The workflow is BUILD_WORKFLOW, else `build_workflow` of .archon/kit.yaml, else build-feature.
# Overrides: ARCHON (the archon CLI), BACKLOG_CWD (read by run-label.js), BUILD_WORKFLOW.
# Exit codes: archon's own; 2 bad usage or not a TASK id (nothing started).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$here/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }

[ $# -eq 1 ] || { echo "usage: launch-run.sh <TASK-id>" >&2; exit 2; }
[[ $1 =~ ^TASK-[0-9]+(\.[0-9]+)*$ ]] || { echo "launch-run: not a TASK id: $1" >&2; exit 2; }
request=$(node "$here/run-label.js" "$1") || request=$1
exec "${ARCHON:-archon}" workflow run "$(kit_get build_workflow build-feature BUILD_WORKFLOW)" --detach "$request"
