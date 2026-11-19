#!/usr/bin/env bash
# Read the Backlog ticket a build-feature request names and report its STOP labels (P2: a script, not a model).
# A ticket still To Do is set In Progress in the backlog checkout, so Backlog shows the run; the change stays
# uncommitted there, and whoever closes the ticket after the merge commits it.
#   ticket.sh "<request text>"
# Writes the ticket to $ARTIFACTS_DIR/ticket.md and prints one JSON line: {"task": "TASK-4.2", "stop": "stop-db-migration"}.
# A request without a TASK id prints {"task": "", "stop": ""}. A TASK id that Backlog cannot find fails the node.
#
# The Backlog lives in this repo. It is read from the main checkout of the repo the run is in, never from
# the run's worktree (whose copy of backlog/ is the branch's, not the live one), else from a sibling of that main
# checkout that has one. BACKLOG_CWD overrides.
set -euo pipefail

task=$(printf '%s' "${1:-}" | grep -oiE 'task-[0-9]+(\.[0-9]+)*' | head -1 | tr '[:lower:]' '[:upper:]' || true)
if [ -z "$task" ]; then
  echo '{"task": "", "stop": ""}'
  exit 0
fi

if [ -z "${BACKLOG_CWD:-}" ]; then
  main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
  for dir in "$main" "$main"/../*; do
    if [ -f "$dir/backlog/config.yml" ]; then BACKLOG_CWD=$(cd "$dir" && pwd); break; fi
  done
fi
if [ -z "${BACKLOG_CWD:-}" ]; then
  echo "No backlog/ found for $task; set BACKLOG_CWD to the checkout that holds backlog/." >&2
  exit 1
fi
export BACKLOG_CWD

json=$(backlog task view "$task" --json) || { echo "Backlog has no $task." >&2; exit 1; }
# The view's dependency graph (every transitive dependent, up to 70 KB) is dropped: every node reads ticket.md, and
# the direct dependencies are all a run needs. The full graph stays in Backlog (`backlog task view <id>`).
deps=$(printf '%s' "$json" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => console.log((JSON.parse(s).task.dependencies || []).join(", ") || "none"));')
backlog task view "$task" --plain \
  | awk -v deps="$deps" '/^Dependency Graph:/ { print "Depends on: " deps "\n"; skip = 1; next } /^Description:/ { skip = 0 } !skip' \
  > "${ARTIFACTS_DIR:-.}/ticket.md"
status=$(printf '%s' "$json" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => console.log(JSON.parse(s).task.status || ""));')
if [ "$status" = "To Do" ]; then
  backlog task edit "$task" --status "In Progress" > /dev/null
fi
printf '%s' "$json" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    const t = JSON.parse(s).task;
    const stop = (t.labels || []).filter(l => l.startsWith("stop-")).join(",");
    console.log(JSON.stringify({ task: t.id, stop }));
  });'
