#!/usr/bin/env bash
# Writes the pull request body of a build-feature-copilot run from a template (P2: a script, not a model). The model's
# part is the summary only: the pr-text node writes a few sentences on what changed and why into a file.
#   pr-body.sh <base branch> <ticket id or ""> <summary file> <body file>
# The body holds, in this order: the summary (a line that starts with "STOP items" left out: pr-refresh.sh writes that
# line), the ticket, the test commits of origin/<base>..HEAD (`test(...)` and `test:` subjects), the empty pr-refresh
# block that pr-refresh.sh fills after every CI round, the `## Merge` section and the footer. It writes no `## Decisions`
# section: pr-refresh.sh alone writes it, inside its block (owner decision 2026-11-20), so a body has one.
# A missing or empty summary file is no error: the body then says so, and the commits in the block say what changed.
# Prints nothing on stdout. Exit 0, 2 on a usage error.
set -uo pipefail
[ "$#" -eq 4 ] || { echo "usage: pr-body.sh <base branch> <ticket id or \"\"> <summary file> <body file>" >&2; exit 2; }
base=$1 ticket=$2 summary=$3 body=$4

range="origin/$base..HEAD"
git rev-parse -q --verify "origin/$base" >/dev/null || range="$base..HEAD"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{
  text=""
  [ -f "$summary" ] && text=$(grep -v '^STOP items' "$summary")
  if [ -n "${text//[[:space:]]/}" ]; then printf '%s\n' "$text"
  else echo "No summary was written: the commits below say what changed."; fi
  if [ -n "$ticket" ]; then
    echo
    echo "Backlog ticket: $ticket"
  fi
  echo
  echo "## Tests"
  echo
  tests=$(git log --reverse --format='- %s' "$range" 2>/dev/null | grep -E '^- test(\(|:)' || true)
  if [ -n "$tests" ]; then
    echo "The test commits, each written to fail before the code that follows it:"
    echo
    printf '%s\n' "$tests"
  else
    echo "No test commit on this branch."
  fi
  echo
  echo '<!-- pr-refresh:start -->'
  echo '<!-- pr-refresh:end -->'
  echo
  echo "## Merge"
  echo
  echo "A team member reviews and merges this pull request once CI on its head commit is green; the"
  echo "build-feature-copilot workflow never merges it itself. A reviewer holds the merge by requesting changes."
  echo
  echo "🤖 Generated with GitHub Copilot through Archon (build-feature-copilot)"
} > "$tmp"
mv "$tmp" "$body"
# stderr: the open-pr node chains this script before open-pr.sh, and its stdout must be that one JSON document.
echo "pr-body: wrote $body" >&2
