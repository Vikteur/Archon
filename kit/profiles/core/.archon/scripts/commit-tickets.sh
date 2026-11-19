#!/usr/bin/env bash
# Commit the named tickets' files under backlog/ to main and push them (P2: a script, not a model; TASK-64). Tickets
# are created and edited in the main checkout (AGENTS.md); until one is on origin/main no run's worktree has it, and
# sync-main.sh has to set it aside whenever a pull request commits the same ticket.
#   commit-tickets.sh <TASK-id>... [-m <why>]
# Run it from the main checkout, on main. It takes every changed path under backlog/ (new, modified, deleted or moved)
# whose file name is a named ticket's (`task-<n> - …`), and nothing else: other tickets' edits and every file outside
# backlog/ stay as they are. The commit is built on origin/main in a temporary index, so the work tree is not touched,
# pushed to main (again on top of the new origin/main when another push came first), and then sync-main.sh
# fast-forwards this checkout. Subject `chore(backlog): <ids>`, body the -m text.
# Before every push the commit passes .claude/scripts/groma-delta.sh against the origin/main it goes on (CI plan C7):
# a FAIL line origin/main does not have, or a groma CLI error, refuses it. GROMA_DELTA names that script (tests stub it).
# Refused, nothing committed: not on main (BASE), main has commits not in origin/main, a named ticket has no changed
# file, or origin/main changed a named ticket's file since this checkout's HEAD (run sync-main.sh, then add the edits
# again with `backlog task edit`), or the Groma check refused the commit.
# Every commit it pushes gets a local CI verdict (CI plan C13): local-ci-run.sh <commit> --no-wait starts the run in
# the background (LOCAL_CI_RUN names that script, tests stub it); a start that fails is a warning, never a refusal.
# Prints {"commit": "<sha>", "files": <n>}. Exit 0: pushed. Exit 1: refused, or the push failed. Exit 2: usage.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
delta=${GROMA_DELTA:-$here/../../.claude/scripts/groma-delta.sh}
run_ci=${LOCAL_CI_RUN:-$here/local-ci-run.sh}
usage() { echo "usage: commit-tickets.sh <TASK-id>... [-m <why>]" >&2; exit 2; }
refuse() { echo "commit-tickets: refused, nothing committed: $*" >&2; exit 1; }

ids=() why=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) [ -n "${2:-}" ] || usage; why=$2; shift ;;
    *) [[ "$1" =~ ^[Tt][Aa][Ss][Kk]-[0-9]+(\.[0-9]+)*$ ]] || usage; ids+=("TASK-${1:5}") ;;
  esac
  shift
done
[ ${#ids[@]} -gt 0 ] || usage
base=${BASE:-main}

top=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not in a git repository"
cd "$top" || exit 1
[ "$(git symbolic-ref -q --short HEAD)" = "$base" ] || refuse "this checkout is not on $base"

# The changed paths under backlog/ of each named ticket; a ticket without one is refused.
files=()
for id in "${ids[@]}"; do
  prefix="task-${id:5} - "
  n=0
  while IFS= read -r -d '' entry; do
    p=${entry:3}
    case "${p##*/}" in "$prefix"*) files+=("$p"); n=$((n + 1)) ;; esac
  done < <(git status -z --porcelain=v1 --untracked-files=all --no-renames -- backlog/)
  [ "$n" -gt 0 ] || refuse "$id has no changed file under backlog/"
done

head=$(git rev-parse HEAD)
idx=$(mktemp)
trap 'rm -f "$idx"' EXIT
subject="chore(backlog): $(IFS=,; echo "${ids[*]}" | sed 's/,/, /g')"
for try in 1 2 3; do
  git fetch -q origin "$base" 2>/dev/null || refuse "cannot fetch origin"
  target=$(git rev-parse -q --verify "refs/remotes/origin/$base^{commit}") || refuse "no origin/$base"
  git merge-base --is-ancestor "$head" "$target" || refuse "$base has commits not in origin/$base; a person decides"
  for p in "${files[@]}"; do
    [ "$(git rev-parse -q --verify "$head:$p")" = "$(git rev-parse -q --verify "$target:$p")" ] \
      || refuse "origin/$base changed $p since this checkout's HEAD: run sync-main.sh, then add the edits again"
  done
  GIT_INDEX_FILE=$idx git read-tree "$target" || refuse "cannot read origin/$base"
  for p in "${files[@]}"; do
    if [ -e "$p" ]; then GIT_INDEX_FILE=$idx git update-index --add -- "$p"
    else GIT_INDEX_FILE=$idx git update-index --force-remove -- "$p"; fi || refuse "cannot stage $p"
  done
  tree=$(GIT_INDEX_FILE=$idx git write-tree) || refuse "cannot write the tree"
  [ "$tree" != "$(git rev-parse "$target^{tree}")" ] || refuse "the tickets' files already match origin/$base"
  if [ -n "$why" ]; then commit=$(printf '%s\n\n%s\n' "$subject" "$why" | git commit-tree "$tree" -p "$target")
  else commit=$(printf '%s\n' "$subject" | git commit-tree "$tree" -p "$target"); fi || refuse "cannot commit"
  bash "$delta" "$commit" "$target" >&2 || refuse "the Groma check refused the commit on origin/$base (see above)"
  if git push -q origin "$commit:refs/heads/$base" 2>/dev/null; then
    bash "$run_ci" "$commit" --no-wait >&2 \
      || echo "commit-tickets: warning: local CI was not started on ${commit:0:7}; run local-ci-run.sh $commit" >&2
    bash "$here/sync-main.sh" >&2 || echo "commit-tickets: pushed, but this checkout did not fast-forward; run sync-main.sh" >&2
    echo "{\"commit\": \"$commit\", \"files\": ${#files[@]}}"
    exit 0
  fi
  echo "commit-tickets: origin/$base moved during the push; building on it again ($try)" >&2
done
echo "commit-tickets: the push to $base failed 3 times" >&2
exit 1
