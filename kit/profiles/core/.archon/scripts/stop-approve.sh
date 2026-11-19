#!/usr/bin/env bash
# The owner's STOP approvals, given in chat and recorded by a script (owner decision 2026-11-19, the list round, which
# replaced the terminal signing of 2026-10-20 D8 and the evening round; docs/archon/stop-policy.md). One entry is one
# action for one ticket; it lasts until the ticket merges, at most 7 days.
#   stop-approve.sh draft <TASK-id> <category> <what is approved...> [--paths <glob>[,<glob>...]]   add one entry to the draft
#   stop-approve.sh show                                                the draft and the approvals files here
#   stop-approve.sh record --by <who> --words <the owner's chat words> [--until <iso>] [--only <n>[,<n>...]]
#   stop-approve.sh revoke <file id> [<entry n>]
# The draft lives in the git folder (<git common dir>/stop-drafts/draft.json), outside the work tree, so nothing commits
# it. A governance entry (a protected path) must name its paths with --paths; contract-push and secret-value cannot be
# drafted. `record` is run by the owner's chat session or the delegator, and only for what the owner approved in chat:
# --words carries the owner's own words, verbatim. It writes the drafted entries (all, or --only those draft numbers)
# as .archon/stop/approvals/<YYYY-MM-DD-HHMM>.json, each with a digest over its ticket, category, detail, paths and the
# file's grant, expiry, owner and recorder (an edit voids it), and commits that one file straight onto origin/main and
# pushes it: push-guard.sh exempts a commit that changes only .archon/stop/approvals/. The work tree is not touched
# (sync-main.sh brings the file in). `revoke` marks a file or one entry revoked and commits and pushes it the same way.
# The expiry is 7 days after recording, or --until (later than now, at most 7 days). stop-check.sh reads origin/main.
# Exit 0 ok, 1 error (also a failed push), 2 usage, 4 refused (unknown or never-covered category, governance without
# paths, no --words, bad expiry, nothing recorded).
# Overrides for the tests: STOP_DRAFT_DIR, STOP_NOW (ISO).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/stop-lib.js"
usage() { echo "usage: stop-approve.sh draft <TASK-id> <category> <what...> [--paths <globs>] | show | record --by <who> --words <text> [--until <iso>] [--only <n,...>] | revoke <id> [<n>]" >&2; exit 2; }
refuse() { echo "stop-approve: refused: $*" >&2; exit 4; }

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "stop-approve: not in a git repository" >&2; exit 1; }
policy="$top/.archon/stop/policy.json"
[ -f "$policy" ] || { echo "stop-approve: no $policy" >&2; exit 1; }
dir="$top/.archon/stop/approvals"
drafts=${STOP_DRAFT_DIR:-$(cd "$top" && cd "$(git rev-parse --git-common-dir)" && pwd)/stop-drafts}
draft="$drafts/draft.json"
now=${STOP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# Commit one file under .archon/stop/approvals/ (its new content in <src>) onto origin/main and push it; three tries
# when main moves. Prints the commit.
publish() {
  local src=$1 rel=$2 subject=$3 idx blob target commit try
  idx=$(mktemp); blob=$(git -C "$top" hash-object -w -- "$src") || { rm -f "$idx"; return 1; }
  for try in 1 2 3; do
    git -C "$top" fetch -q origin main 2>/dev/null || { echo "stop-approve: cannot fetch origin" >&2; break; }
    target=$(git -C "$top" rev-parse -q --verify "refs/remotes/origin/main^{commit}") || break
    GIT_INDEX_FILE=$idx git -C "$top" read-tree "$target" \
      && GIT_INDEX_FILE=$idx git -C "$top" update-index --add --cacheinfo "100644,$blob,$rel" \
      && commit=$(printf '%s\n' "$subject" | git -C "$top" commit-tree "$(GIT_INDEX_FILE=$idx git -C "$top" write-tree)" -p "$target") \
      || break
    if git -C "$top" push -q origin "$commit:refs/heads/main" 2>/dev/null; then
      rm -f "$idx"; echo "$commit"; return 0
    fi
    echo "stop-approve: origin/main moved during the push; building on it again ($try)" >&2
  done
  rm -f "$idx"; echo "stop-approve: the commit of $rel did not reach origin/main" >&2; return 1
}

cmd=${1:-}; [ -n "$cmd" ] || usage; shift
case "$cmd" in
  draft)
    [ $# -ge 3 ] || usage
    node "$lib" draft-add "$policy" "$draft" "$@" ;;
  show)
    [ $# -eq 0 ] || usage
    files=()
    [ -f "$draft" ] && files+=("$draft")
    for f in "$dir"/*.json; do [ -f "$f" ] && case "${f##*/}" in _*) ;; *) files+=("$f") ;; esac; done
    [ ${#files[@]} -gt 0 ] || { echo "no draft and no approvals"; exit 0; }
    node "$lib" show "$policy" "$now" "${files[@]}" ;;
  record)
    out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
    log=$(node "$lib" record "$policy" "$draft" "$out" "$now" "$@") || exit $?
    file=$(sed -n 's/^recorded [0-9]* of [0-9]*: //p' <<< "$log")
    rel=".archon/stop/approvals/${file##*/}"
    git -C "$top" cat-file -e "origin/main:$rel" 2>/dev/null && { echo "stop-approve: $rel exists on origin/main: record again in a minute" >&2; exit 4; }
    commit=$(publish "$file" "$rel" "stop: owner approvals ${file##*/} (in chat)") || exit 1
    echo "${log/$file/$rel}"
    echo "on origin/main as ${commit:0:8}" ;;
  revoke)
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    rel=".archon/stop/approvals/$1.json"
    git -C "$top" fetch -q origin main 2>/dev/null || true
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    git -C "$top" show "origin/main:$rel" > "$tmp" 2>/dev/null || refuse "no approvals file $1 on origin/main"
    node "$lib" revoke "$tmp" "$now" ${2:+"$2"} || exit $?
    commit=$(publish "$tmp" "$rel" "stop: revoke $1${2:+#$2}") || exit 1
    echo "on origin/main as ${commit:0:8}" ;;
  *) usage ;;
esac
