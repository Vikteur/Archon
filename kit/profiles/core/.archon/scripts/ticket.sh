#!/usr/bin/env bash
# Read the ticket a build-feature request names, write it to the run's ticket.md and report its STOP labels (P2: a
# script, not a model). Two sources, by `backlog` of .archon/kit.yaml (env KIT_BACKLOG, default true):
#   - a Backlog ticket: with backlog: true, a request that names a TASK id. A ticket still To Do is set In Progress in
#     the backlog checkout, so Backlog shows the run; the change stays uncommitted there, and whoever closes the
#     ticket after the merge commits it. A TASK id that Backlog cannot find fails the node.
#   - the request text itself: with backlog: false (no Backlog.md: the ticket is pasted, from Jira or elsewhere), or a
#     request that names no TASK id. Its first line is the title, a `Labels:` line in it (comma or space separated)
#     names the labels, and the text is written unchanged under Description, so every node reads one ticket.md either way.
#   ticket.sh "<request text>"
# Writes the ticket to $ARTIFACTS_DIR/ticket.md and prints one JSON line:
#   {"task": "TASK-4.2", "stop": "stop-db-migration", "title": "<the ticket's title>", "pr_note": "<a sentence>"}
# task is the Backlog id, empty without a Backlog ticket; stop the labels that start with stop- (from the request text,
# only those of letters, digits and dashes); pr_note the sentence the pr-text node adds to its prompt, which names the
# Backlog ticket, and is empty without one (no "Backlog ticket" line in the pull request).
#
# The Backlog lives in this repo. It is read from the main checkout of the repo the run is in, never from
# the run's worktree (whose copy of backlog/ is the branch's, not the live one), else from a sibling of that main
# checkout that has one. BACKLOG_CWD overrides.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=kit-config.sh
. "$here/kit-config.sh"
request="${1:-}"
out="${ARTIFACTS_DIR:-.}/ticket.md"

task=""
if [ "$(kit_get backlog true)" != false ]; then
  task=$(printf '%s' "$request" | grep -oiE 'task-[0-9]+(\.[0-9]+)*' | head -1 | tr '[:lower:]' '[:upper:]' || true)
fi

if [ -z "$task" ]; then
  # The request is the ticket. node words the file and the JSON line (a title or a label may hold any character).
  REQUEST="$request" OUT="$out" node -e '
    const fs = require("fs");
    const text = process.env.REQUEST || "";
    const first = text.split(/\r?\n/).map(l => l.trim()).find(l => l !== "") || "";
    let title = first.replace(/^#+\s*/, "").replace(/^\**(title|summary)\**\s*:\s*\**\s*/i, "").replace(/\*+$/, "").trim();
    if (title.length > 120) title = title.slice(0, 119) + "…";
    const line = text.split(/\r?\n/).find(l => /^\s*[-*]?\s*\**labels\**\s*:/i.test(l));
    const labels = line ? line.replace(/^[^:]*:\s*\**\s*/, "").split(/[\s,]+/).map(l => l.replace(/[*`]/g, "")).filter(Boolean) : [];
    const stop = labels.filter(l => /^stop-[A-Za-z0-9-]+$/.test(l));
    const bar = "-".repeat(50);
    fs.writeFileSync(process.env.OUT, [
      `Ticket - ${title || "(no title)"}`, "=".repeat(50), "",
      "Source: the build request (no Backlog ticket)",
      ...(labels.length ? [`Labels: ${labels.join(", ")}`] : []), "",
      "Description:", bar, text.replace(/\s+$/, ""), ""].join("\n"));
    console.log(JSON.stringify({ task: "", stop: stop.join(","), title, pr_note: "" }));'
  exit 0
fi

if [ -z "${BACKLOG_CWD:-}" ]; then
  main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
  for dir in "$main" "$main"/../*; do
    if [ -f "$dir/backlog/config.yml" ]; then BACKLOG_CWD=$(cd "$dir" && pwd); break; fi
  done
fi
if [ -z "${BACKLOG_CWD:-}" ]; then
  echo "No backlog/ found for $task; set BACKLOG_CWD to the checkout that holds backlog/, or set backlog: false in .archon/kit.yaml to take the ticket from the request text." >&2
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
  > "$out"
status=$(printf '%s' "$json" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => console.log(JSON.parse(s).task.status || ""));')
if [ "$status" = "To Do" ]; then
  backlog task edit "$task" --status "In Progress" > /dev/null
fi
printf '%s' "$json" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    const t = JSON.parse(s).task;
    const stop = (t.labels || []).filter(l => l.startsWith("stop-")).join(",");
    const title = String(t.title || "");
    console.log(JSON.stringify({ task: t.id, stop, title, pr_note: `Name its Backlog ticket, ${t.id} (${title}).` }));
  });'
