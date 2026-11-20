#!/usr/bin/env bash
# Caps a test log before an agent reads it (P2: a script, not a model): the failure lines and the last lines, not a
# whole Gradle run. The review node reads review-tests.log this way; the full log stays beside it.
#   log-cap.sh <full-log> <capped-log> [<last-lines>]   (default 200 last lines)
# A log no longer than <last-lines> is copied whole. A longer one becomes: a line naming the full log, then
# `## Failure lines` (each line that reads as a failure, with its line number, at most <last-lines> of them), then
# `## Last <last-lines> lines`. A failure line is one that holds FAILED (a test, a Gradle task, BUILD FAILED), FAIL:,
# ::error::, error:, Error:, Exception or AssertionError. Exit 0, 2 on a usage error or a missing log.
set -uo pipefail
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo "usage: log-cap.sh <full-log> <capped-log> [<last-lines>]" >&2; exit 2; }
full=$1 capped=$2 last=${3:-200}
[[ "$last" =~ ^[1-9][0-9]*$ ]] || { echo "log-cap: <last-lines> must be a whole number, not $last" >&2; exit 2; }
[ -f "$full" ] || { echo "log-cap: no log at $full" >&2; exit 2; }

total=$(wc -l < "$full" | tr -d ' ')
if [ "$total" -le "$last" ]; then
  [ "$full" -ef "$capped" ] || cp "$full" "$capped"
  exit 0
fi
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{
  echo "log-cap: $total lines, cut to the failure lines and the last $last; the whole log is $full"
  echo
  echo "## Failure lines"
  grep -nE 'FAILED|FAIL:|::error::|[Ee]rror:|Exception|AssertionError' "$full" | head -n "$last"
  echo
  echo "## Last $last lines"
  tail -n "$last" "$full"
} > "$tmp"
mv "$tmp" "$capped"
