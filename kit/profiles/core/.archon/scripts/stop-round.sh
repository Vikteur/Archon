#!/usr/bin/env bash
# The list round's last step: turn the owner's chat answers on a ticket list's STOP items into recorded approvals,
# ticket notes and label edits (owner decision 2026-11-19, the list round replaces the evening round and the signing;
# docs/archon/stop-policy.md).
#   stop-round.sh [--apply --by <who> --words <the owner's chat words>] [<answers file>]   (no file: stdin)
# One answer per line, `#` starts a comment:
#   <TASK-id> <category> approve <what exactly is approved...>
#   <TASK-id> governance approve paths=<glob>[,<glob>...] <what...>     (governance names the protected paths it covers)
#   <TASK-id> <category> refuse <why...>
# Without --apply it changes nothing: it prints the entries it would record and the exact `backlog task edit` commands.
# An approved item loses its `stop-<category>` label (when it has it) and gets a note; a refused item gets the label
# (when it lacks it) and a note, and its ticket leaves the list.
# With --apply it drafts the approved items in a private draft, records them in one approvals file on origin/main
# (stop-approve.sh record --by --words: the owner's chat words are the approval), then runs the backlog edits.
# contract-push and secret-value are never covered in advance: such an answer is recorded in the notes only, its label
# stays, and stop-check still holds the merge for the owner.
# Exit 0 done, 1 a ticket could not be read, recording or a backlog edit failed, 2 usage, 4 refused (a bad answer line).
# Overrides for the tests: STOP_NOW (ISO), STOP_APPROVE (the stop-approve.sh to call); backlog is found on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
approve=${STOP_APPROVE:-$here/stop-approve.sh}
usage() { echo "usage: stop-round.sh [--apply --by <who> --words <text>] [<answers file>]" >&2; exit 2; }
apply=""; by=""; words=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
    --words) [ $# -ge 2 ] || usage; words=$2; shift 2 ;;
    --*) usage ;;
    *) break ;;
  esac
done
[ $# -le 1 ] || usage
if [ -n "$apply" ]; then
  [ -n "$by" ] && [ -n "${words//[[:space:]]/}" ] || { echo "stop-round: --apply needs --by <who> and the owner's chat words in --words" >&2; exit 2; }
elif [ -n "$by$words" ]; then usage; fi
input=${1:-/dev/stdin}
[ -r "$input" ] || { echo "stop-round: cannot read $input" >&2; exit 2; }

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "stop-round: not in a git repository" >&2; exit 1; }
policy="$top/.archon/stop/policy.json"
now=${STOP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
day=$(TZ=$(jq -r '.timezone // "UTC"' "$policy") date -d "$now" +%Y-%m-%d)

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$input" | tr -d '\r' > "$tmp/answers"
[ -s "$tmp/answers" ] || { echo "stop-round: no answers" >&2; exit 2; }

coverable() { jq -e --arg c "$1" '.categories[] | select(.id == $c) | .coverable' "$policy" >/dev/null; }
needs_paths() { jq -e --arg c "$1" '.categories[] | select(.id == $c) | .needs_paths // false' "$policy" >/dev/null; }

# Check every line before anything is drafted or edited.
bad=0
while read -r t c v rest; do
  ok=1
  [[ "$t" =~ ^TASK-[0-9]+(\.[0-9]+)*$ ]] || ok=""
  jq -e --arg c "$c" '.categories[] | select(.id == $c)' "$policy" >/dev/null || ok=""
  case "$v" in approve|refuse) ;; *) ok="" ;; esac
  [ -n "$rest" ] || ok=""
  if [ -n "$ok" ] && [ "$v" = approve ] && needs_paths "$c"; then
    p=${rest%% *}; what=${rest#"$p"}
    [[ "$p" == paths=?* ]] && [ -n "${what// /}" ] || { ok=""; echo "stop-round: a $c approval names its paths: $t $c approve paths=<glob>[,<glob>...] <what>" >&2; }
  fi
  [ -n "$ok" ] || { echo "stop-round: bad answer line: $t $c $v $rest (want: <TASK-id> <category> approve|refuse <text>)" >&2; bad=1; }
done < "$tmp/answers"
[ "$bad" -eq 0 ] || exit 4

labels_of() { backlog task view "$1" --json 2>/dev/null < /dev/null | jq -ce '(.task // .) | .labels // []'; }
q() { printf '%q' "$1"; }

: > "$tmp/cmds"; : > "$tmp/leave"; : > "$tmp/stay"; : > "$tmp/record"; n=0
while read -r t c v rest; do
  labels=$(labels_of "$t") || { echo "stop-round: cannot read $t with backlog task view" >&2; exit 1; }
  label="stop-$c"
  has=$(jq -r --arg l "$label" 'index($l) != null' <<< "$labels")
  if [ "$v" = approve ]; then
    echo "$t" >> "$tmp/stay"
    if coverable "$c"; then
      paths=""; what=$rest
      if needs_paths "$c"; then p=${rest%% *}; paths=${p#paths=}; what=${rest#"$p"}; what=${what# }; fi
      n=$((n+1))
      printf '%s\t%s\t%s\t%s\n' "$t" "$c" "$what" "$paths" >> "$tmp/record"
      note="Owner $day list round: STOP item $c approved in chat — $what${paths:+ (paths: $paths)}. Entry @ENTRY@#$n (.archon/stop/approvals/), valid until the merge, at most 7 days."
      [ "$has" = true ] && echo "backlog task edit $t --remove-label $label" >> "$tmp/cmds"
    else
      note="Owner $day list round: STOP item $c answered yes — $rest. $c is never covered in advance: the label stays and the merge still waits for the owner."
    fi
  else
    echo "$t" >> "$tmp/leave"
    [ "$has" = true ] || echo "backlog task edit $t --add-label $label" >> "$tmp/cmds"
    note="Owner $day list round: STOP item $c refused — $rest. Off the list."
  fi
  echo "backlog task edit $t --append-notes $(q "$note")" >> "$tmp/cmds"
done < "$tmp/answers"

if [ -z "$apply" ]; then
  echo "# Entries to record (stop-round.sh --apply --by <who> --words <the owner's chat words>):"
  if [ -s "$tmp/record" ]; then
    awk -F'\t' '{ printf "#   %d %s %s: %s%s\n", NR, $1, $2, $3, ($4 == "" ? "" : " (paths: " $4 ")") }' "$tmp/record"
  else echo "#   none"; fi
  echo "# Ticket edits:"
  sed 's/@ENTRY@/approval:<file>/' "$tmp/cmds"
  echo
  sort -u "$tmp/leave" > "$tmp/l"
  echo "# List (no refused item): $(sort -u "$tmp/stay" | comm -23 - "$tmp/l" | paste -sd ' ' -)"
  echo "# Leave the list: $(paste -sd ' ' "$tmp/l")"
  exit 0
fi

entry="approval:none"
if [ -s "$tmp/record" ]; then
  export STOP_DRAFT_DIR="$tmp/draft"
  while IFS=$'\t' read -r t c what paths; do
    args=(draft "$t" "$c" "$what"); [ -z "$paths" ] || args+=(--paths "$paths")
    bash "$approve" "${args[@]}" >&2 < /dev/null || { echo "stop-round: could not draft $t $c: nothing recorded, nothing changed" >&2; exit 1; }
  done < "$tmp/record"
  log=$(STOP_NOW=$now bash "$approve" record --by "$by" --words "$words" < /dev/null) || { echo "stop-round: recording failed: nothing changed" >&2; exit 1; }
  echo "$log"
  file=$(sed -n 's|^recorded [0-9]* of [0-9]*: .*/||p' <<< "$log"); file=${file%.json}
  [ -n "$file" ] || { echo "stop-round: could not read the recorded file's name" >&2; exit 1; }
  entry="approval:$file"
fi
while IFS= read -r cmd; do
  cmd=${cmd//@ENTRY@/$entry}
  echo "+ $cmd"
  eval "$cmd" >/dev/null < /dev/null || { echo "stop-round: failed: $cmd" >&2; exit 1; }
done < "$tmp/cmds"
echo "Applied. Commit the ticket edits with commit-tickets.sh before the first launch."
