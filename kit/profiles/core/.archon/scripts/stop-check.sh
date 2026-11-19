#!/usr/bin/env bash
# The STOP verdict, by a script (P2; owner decisions 2026-10-20 D4, D7, D8 and the STOP rule changes;
# docs/archon/stop-policy.md). Read-only: it changes nothing anywhere.
#   stop-check.sh [--json] <pr number or url>        a pull request: its ticket's stop-* labels, the plan's STOP text in
#                                                     the PR body ("STOP items ..." up to the next "## "), its files
#   stop-check.sh [--json] ticket <TASK-id>           a ticket before a run: its stop-* labels only
#   stop-check.sh [--json] cleanup <branch> [<worktree>]   a deletion: covered only when cleanup-merged.sh --dry-run
#                                                     finds all its content in main (standing rule merged-cleanup)
# Prints the verdict as the first word of the first line (none, covered or owner), then one line per item:
# "<category> (<source>): <covered|owner> — <reason>". With --json, the verdict JSON of stop-lib.js instead.
# Each item, first match wins: an unknown stop-* label or STOP text naming no category → owner (a sentence of
# the STOP text that only denies categories, each clause `no <item>` and nothing else, names no item); a category that is never
# covered (contract-push, secret-value) → owner; an active standing rule (no-production-db,
# pre-launch-production-config, merged-cleanup in cleanup mode) → covered; a valid entry of .archon/stop/approvals/
# for exactly this ticket and category (the owner's chat approval from the list round, recorded by
# stop-approve.sh record; ≤7 days) → covered; anything else → owner. A file on a protected path (policy.json) → covered
# only by a valid governance entry for this ticket whose paths name that file, else owner. No item → none.
# The policy and the approvals are read from origin/main after a fetch, never from a branch or the PR head; run it from
# the main checkout (the ticket labels come from `backlog task view`, which the list round edits there).
# Exit 0 none, 3 covered, 1 owner (also every error: it fails closed and prints "owner" with the reason), 2 usage.
# Overrides for the tests: STOP_REPO (the git checkout to read $STOP_REF from; default here), STOP_REF (default
# origin/main); both are refused unless the checkout lies under $TMPDIR (or /tmp); STOP_NO_FETCH=1, STOP_NOW (ISO time), CLEANUP_MERGED (the
# script to call); gh and backlog are found on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/stop-lib.js"
ref=${STOP_REF:-origin/main}
g() { git -C "${STOP_REPO:-.}" "$@"; }
json=""
[ "${1:-}" = --json ] && { json=1; shift; }
usage() { echo "usage: stop-check.sh [--json] <pr> | ticket <TASK-id> | cleanup <branch> [<worktree>]" >&2; exit 2; }
mode=pr
case "${1:-}" in
  "") usage ;;
  ticket) mode=ticket; [ $# -eq 2 ] || usage ;;
  cleanup) mode=cleanup; [ $# -ge 2 ] && [ $# -le 3 ] || usage ;;
  *) [ $# -eq 1 ] || usage ;;
esac

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
owner() { # fail closed
  if [ -n "$json" ]; then jq -n --arg r "$*" '{verdict: "owner", items: [], error: $r}'; else echo "owner"; echo "error: $*"; fi
  exit 1
}

# Only origin/main counts. Another ref (or another checkout) is honoured only for a throwaway test repo under the temp
# dir, so a local branch holding hand-made approvals can never be the source.
if [ "$ref" != origin/main ] || [ -n "${STOP_REPO:-}" ]; then
  tmpd=$(cd "${TMPDIR:-/tmp}" && pwd -P); repo=$(cd "${STOP_REPO:-.}" 2>/dev/null && pwd -P)
  case "$repo/" in "$tmpd"/?*) ;; *) owner "STOP_REF/STOP_REPO are for test repos under ${TMPDIR:-/tmp} only: the policy and approvals come from origin/main" ;; esac
fi
[ -n "${STOP_NO_FETCH:-}" ] || g fetch -q origin "${ref#origin/}" 2>/dev/null || owner "cannot fetch $ref"
g show "$ref:.archon/stop/policy.json" > "$tmp/policy.json" 2>/dev/null || owner "no .archon/stop/policy.json at $ref"

# The approvals at $ref, as [{name, text}] (a file whose name starts with _ is a template).
echo '[]' > "$tmp/approvals.json"
while IFS= read -r f; do
  case "${f##*/}" in _*|*[!a-zA-Z0-9._-]*) continue ;; *.json) ;; *) continue ;; esac
  g show "$ref:$f" > "$tmp/a" 2>/dev/null || continue
  jq --arg n "${f##*/}" --rawfile t "$tmp/a" '. + [{name: $n, text: $t}]' "$tmp/approvals.json" > "$tmp/b" && mv "$tmp/b" "$tmp/approvals.json"
done < <(g ls-tree --name-only "$ref" .archon/stop/approvals/ 2>/dev/null)

labels_of() { # labels_of <TASK-id>: the ticket's labels as a JSON array
  local v
  v=$(backlog task view "$1" --json 2>/dev/null) || return 1
  jq -ce '(.task // .) | .labels // [] | if type == "array" then . else error("no labels") end' <<< "$v"
}

ticket="" labels='[]' plan="" files='[]' cleanup='null'
case "$mode" in
  ticket)
    ticket=$2
    labels=$(labels_of "$ticket") || owner "cannot read $ticket with backlog task view" ;;
  cleanup)
    cm=${CLEANUP_MERGED:-$here/cleanup-merged.sh}
    shift
    if why=$(bash "$cm" --dry-run "$@" 2>&1); then ok=true; else ok=false; fi
    cleanup=$(jq -n --argjson ok "$ok" --arg r "$1: $(tail -n 1 <<< "$why")" '{ok: $ok, reason: $r}') ;;
  pr)
    pr=$1
    gh pr view "$pr" --json number,title,body,files,state > "$tmp/pr.json" 2>/dev/null || owner "cannot read pull request $pr"
    title=$(jq -r '.title // ""' "$tmp/pr.json")
    ticket=$(grep -oE 'TASK-[0-9]+(\.[0-9]+)*' <<< "$title" | head -n 1)
    [ -n "$ticket" ] || owner "no ticket id in the title of pull request $pr"
    labels=$(labels_of "$ticket") || owner "cannot read $ticket with backlog task view"
    files=$(jq -c '[.files[]?.path]' "$tmp/pr.json")
    # The plan's STOP answer, as pr-refresh.sh writes it: "STOP items <...>:" and what follows, up to the next "## ",
    # or the end marker of pr-refresh.sh's block, which holds the line.
    section=$(jq -r '.body // ""' "$tmp/pr.json" | tr -d '\r' | awk '
      /^STOP items/ { on = 1; sub(/^STOP items[^:]*:[ \t]*/, ""); }
      on && (/^## / || /^🤖/ || /^<!-- pr-refresh:end -->/) { exit }
      on { print }')
    [ -n "$(jq -r '.body // ""' "$tmp/pr.json" | grep -E '^STOP items')" ] || owner "no \"STOP items\" section in the body of pull request $pr"
    if grep -qiE 'touches no STOP item|^[[:space:]]*(none|-)[[:space:].]*$' <<< "$section" && \
       [ "$(grep -cvE '^[[:space:]]*$' <<< "$section")" -le 1 ]; then plan=""; else plan=$section; fi ;;
esac

now=${STOP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
jq -n --rawfile p "$tmp/policy.json" --arg ticket "$ticket" --arg mode "$mode" --arg now "$now" \
  --argjson labels "$labels" --arg plan "$plan" --argjson files "$files" --argjson cleanup "$cleanup" \
  --slurpfile approvals "$tmp/approvals.json" \
  '{policy_text: $p, ticket: $ticket, mode: $mode, now: $now,
    labels: $labels, plan_text: $plan, files: $files, cleanup: $cleanup, approvals: $approvals[0]}' > "$tmp/in.json" \
  || owner "cannot build the verdict input"
node "$lib" verdict "$tmp/in.json" > "$tmp/out.json" 2> "$tmp/err" || owner "stop-lib: $(tail -n 1 "$tmp/err")"

v=$(jq -r .verdict "$tmp/out.json")
if [ -n "$json" ]; then cat "$tmp/out.json"
else
  echo "$v${ticket:+ ($ticket)}"
  jq -r '.items[] | "\(.category) (\(.source)): \(.verdict) — " +
    (if (.covered_by // "") | startswith("rule:") then .covered_by elif .covered_by then "\(.covered_by): \(.reason)" else .reason end)' \
    "$tmp/out.json"
  jq -r '.approvals_ignored[] | "approvals ignored: \(.)"' "$tmp/out.json"
fi
case "$v" in none) exit 0 ;; covered) exit 3 ;; *) exit 1 ;; esac
