#!/usr/bin/env bash
# Delete a branch and its worktree once all their content is merged (P2: a script, not a model; owner decision
# 2026-10-18, docs/memory.md, TASK-55: the delegator cleans up only through this script).
#   cleanup-merged.sh [--dry-run] <branch> [<worktree>]
# Run it from any checkout of the repo. The worktree defaults to the one that has <branch> checked out.
# It deletes nothing unless every check passes, and then deletes the worktree, the local branch and the branch on
# origin (whichever exist):
#   - origin is fetched (with --prune), and <branch> is not the base (BASE, default main), not main or master, and not
#     checked out in the checkout this runs from;
#   - the local branch tip and the branch tip on origin are both in origin/<base> (a merge or a fast-forward put them
#     there; a squash merge does not, and is refused);
#   - the worktree has no uncommitted change and no untracked file (ignored files, such as a build or a contract clone,
#     are not content), its HEAD is in origin/<base>, and no stash entry was made on <branch>.
# Exit 0: deleted (or, with --dry-run, would delete). Exit 1: refused, with the reason, nothing changed (or a delete
# failed part way, which it says). Exit 2: usage.
#   cleanup-merged.sh --sweep [--dry-run]
# Runs the same checks over every worktree of the repository and deletes only the fully merged ones (owner decision
# 2026-10-20: deleting a branch or worktree whose content is all in main is no STOP item, and a sweep may run this over
# every leftover worktree; deleting anything not fully merged stays one). It keeps, each with its reason on one line:
# the main checkout, the checkout this runs from, a worktree a live Archon run works in (`archon workflow runs --json`,
# any status but completed, failed, cancelled or rejected), a detached worktree (no branch to judge), and every worktree
# a check refuses. Each worktree's branch is passed with it, so a branch's checks run once per worktree.
# Exit 0: the sweep went over every worktree (kept ones included). Exit 1: it could not start (no fetch, the live runs
# unreadable: nothing deleted) or a delete stopped part way. Exit 2: usage. Override for the tests: CLEANUP_RUNS_JSON, a
# file that stands in for the archon run list.
set -uo pipefail

self="${BASH_SOURCE[0]}"
sweep=""
dry=""
case "${1:-} ${2:-}" in
  "--sweep "|"--sweep --dry-run"|"--dry-run --sweep")
    [ $# -le 2 ] || { echo "usage: cleanup-merged.sh --sweep [--dry-run]" >&2; exit 2; }
    sweep=1; [ "$*" != --sweep ] && dry=1; shift $# ;;
  --sweep*|*" --sweep") echo "usage: cleanup-merged.sh --sweep [--dry-run]" >&2; exit 2 ;;
esac
[ -z "$sweep" ] && [ "${1:-}" = --dry-run ] && { dry=1; shift; }

if [ -n "$sweep" ]; then
  stop() { echo "cleanup-merged: sweep refused, nothing deleted: $*" >&2; exit 1; }
  git rev-parse --git-dir >/dev/null 2>&1 || stop "not in a git repository"
  git fetch -q --prune origin 2>/dev/null || stop "cannot fetch origin"
  if [ -n "${CLEANUP_RUNS_JSON:-}" ]; then runs=$(cat "$CLEANUP_RUNS_JSON" 2>/dev/null)
  else runs=$(archon workflow runs --json --limit 50 2>/dev/null); fi
  live=$(jq -r '(.runs // .)[] | select(.status | IN("completed", "failed", "cancelled", "rejected") | not)
    | "\(.working_path // "")\t\(.id)"' <<< "$runs" 2>/dev/null) || stop "cannot read the live Archon runs"
  real() { (cd "$1" 2>/dev/null && pwd -P); }
  here_wt=$(real "$(git rev-parse --show-toplevel)")
  main_wt=""
  deleted=0 kept=0 broken=0
  keep() { echo "kept $1: $2"; kept=$((kept + 1)); }
  while IFS=$'\t' read -r wt branch; do
    r=$(real "$wt")
    if [ -z "$main_wt" ]; then main_wt=${r:-$wt}; keep "$wt" "the main checkout"; continue; fi
    [ -n "$r" ] || { keep "$wt" "the folder is gone (git worktree prune clears it)"; continue; }
    [ "$r" = "$here_wt" ] && { keep "$wt" "the checkout this runs from"; continue; }
    run=""
    while IFS=$'\t' read -r path id; do
      [ -n "$path" ] && [ "$(real "$path")" = "$r" ] && run=$id
    done <<< "$live"
    [ -n "$run" ] && { keep "$wt" "a live run works in it ($run)"; continue; }
    [ -n "$branch" ] || { keep "$wt" "detached HEAD: no branch to judge"; continue; }
    res=$(bash "$self" ${dry:+--dry-run} "$branch" "$wt" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then echo "$res"; deleted=$((deleted + 1))
    else
      keep "$wt ($branch)" "$(sed 's/^cleanup-merged: //; s/^refused, nothing deleted: //' <<< "$res" | tr '\n' ' ' | sed 's/ $//')"
      grep -q 'stopped part way' <<< "$res" && broken=$((broken + 1))
    fi
  done < <(git worktree list --porcelain | awk '
    /^worktree /{ if (w != "") print w "\t" b; w = substr($0, 10); b = "" }
    /^branch refs\/heads\//{ b = substr($0, 19) }
    END { if (w != "") print w "\t" b }')
  echo "cleanup-merged: sweep $([ -n "$dry" ] && echo "would delete" || echo deleted) $deleted, kept $kept"
  [ "$broken" -eq 0 ]
  exit
fi

branch=${1:-}
wt=${2:-}
[ -n "$branch" ] && [ $# -le 2 ] || { echo "usage: cleanup-merged.sh [--dry-run] <branch> [<worktree>] | --sweep [--dry-run]" >&2; exit 2; }
base=${BASE:-main}

refuse() { echo "cleanup-merged: refused, nothing deleted: $*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || refuse "not in a git repository"
case "$branch" in main|master|"$base"|HEAD|origin/*|refs/*) refuse "'$branch' is not a branch this script deletes" ;; esac
git fetch -q --prune origin 2>/dev/null || refuse "cannot fetch origin"
target=$(git rev-parse -q --verify "refs/remotes/origin/$base^{commit}") || refuse "no origin/$base"
[ "$(git symbolic-ref -q --short HEAD)" = "$branch" ] && refuse "'$branch' is checked out here"

in_base() { git merge-base --is-ancestor "$1" "$target"; }

local_tip=$(git rev-parse -q --verify "refs/heads/$branch^{commit}") || local_tip=""
remote_tip=$(git rev-parse -q --verify "refs/remotes/origin/$branch^{commit}") || remote_tip=""
[ -n "$local_tip" ] && ! in_base "$local_tip" && refuse "local $branch (${local_tip:0:7}) has commits not in origin/$base"
[ -n "$remote_tip" ] && ! in_base "$remote_tip" && refuse "origin/$branch (${remote_tip:0:7}) has commits not in origin/$base"

if [ -z "$wt" ]; then
  wt=$(git worktree list --porcelain | awk -v ref="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0=="branch " ref {print w}')
fi
if [ -n "$wt" ]; then
  [ -d "$wt" ] || refuse "no worktree at $wt"
  real=$(cd "$wt" && pwd -P)
  [ "$real" = "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" ] && refuse "$wt is the checkout this runs from"
  known=""
  while IFS= read -r w; do [ -d "$w" ] && [ "$(cd "$w" && pwd -P)" = "$real" ] && known=1; done \
    < <(git worktree list --porcelain | sed -n 's/^worktree //p')
  [ -n "$known" ] || refuse "$wt is not a worktree of this repository"
  dirty=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null) || refuse "cannot read the status of $wt"
  [ -z "$dirty" ] || refuse "$wt has uncommitted or untracked changes: $(head -n 3 <<< "$dirty" | tr '\n' ' ')"
  head=$(git -C "$wt" rev-parse HEAD) || refuse "cannot read HEAD of $wt"
  in_base "$head" || refuse "$wt is at ${head:0:7}, which is not in origin/$base"
fi
git stash list | grep -qE "^stash@\{[0-9]+\}: (WIP on|On) $branch:" && refuse "a stash entry was made on $branch"
[ -z "$local_tip$remote_tip$wt" ] && refuse "no branch '$branch' here or on origin, and no worktree"

if [ -n "$dry" ]; then
  [ -n "$wt" ] && echo "would delete worktree $wt"
  [ -n "$local_tip" ] && echo "would delete branch $branch (${local_tip:0:7})"
  [ -n "$remote_tip" ] && echo "would delete origin/$branch (${remote_tip:0:7})"
  exit 0
fi
failed() { echo "cleanup-merged: stopped part way: $*" >&2; exit 1; }
# A CodeGraph MCP server outlives the session that started it (docs/mcp/plan.md, A5): stop each one that serves the
# worktree (its --path, or its working folder, is in it) before the folder goes. CLEANUP_PROC overrides /proc (tests).
stop_codegraph() {
  local proc="${CLEANUP_PROC:-/proc}" d pid args cwd
  for d in "$proc"/[0-9]*; do
    pid="${d##*/}"
    args="$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)" || continue
    case "$args" in *codegraph*" serve "*) ;; *) continue ;; esac
    cwd="$(readlink "$d/cwd" 2>/dev/null)"
    case "$cwd/ $args " in "$1/"*|*" --path $1 "*|*" --path $1/"*) kill "$pid" 2>/dev/null && echo "stopped codegraph server $pid" ;; esac
  done
}
# --force only for the ignored files left in it (a build, a contract clone): the checks above found no other content.
[ -n "$wt" ] && stop_codegraph "$wt"
[ -n "$wt" ] && { git worktree remove --force "$wt" || failed "git worktree remove $wt failed"; echo "deleted worktree $wt"; }
[ -n "$local_tip" ] && { git branch -D "$branch" >/dev/null || failed "git branch -D $branch failed (the worktree is gone)"; echo "deleted branch $branch (${local_tip:0:7})"; }
[ -n "$remote_tip" ] && { git push -q origin --delete "$branch" || failed "git push origin --delete $branch failed (the worktree and local branch are gone)"; echo "deleted origin/$branch (${remote_tip:0:7})"; }
exit 0
