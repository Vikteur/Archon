#!/usr/bin/env bash
# Fast-forward the main checkout to origin/main, clearing the local files that would block it (P2: a script, not a
# model; TASK-57). Archon fast-forwards this checkout before every run, and Backlog tickets are created and edited
# here (AGENTS.md) while a run's pull request commits the same ticket file, so once it merges git refuses the
# fast-forward over the local copy and every run fails while setting up its workspace.
#   sync-main.sh [--dry-run]
# Run it from the main checkout. A local file blocks when it is untracked, modified or staged and origin/main changed
# the same path. Each one is copied into <git dir>/sync-main-backup/<time>/ first, never just deleted:
#   - byte-identical to origin/main's copy: moved aside (untracked) or restored (tracked); nothing is lost;
#   - different, under backlog/: the same, and named "re-apply", so the local edits (ticket notes) can be added again
#     on top of origin's copy with `backlog task edit`;
#   - different, anywhere else: refused.
# Refused, with the reason, nothing changed: not on main (BASE), main has commits not in origin/main, or a blocking
# file outside backlog/ differs.
# After it fast-forwards (or finds main up to date) the tip of main gets a local CI verdict (CI plan C13): a commit
# someone else pushed to main is run too. local-ci-run.sh <tip> --no-wait starts it in the background and leaves a
# commit that already has a local-ci status alone (LOCAL_CI_RUN names that script, tests stub it); a start that fails
# is a warning, never a refusal. Not with --dry-run.
# Exit 0: fast-forwarded or up to date (with --dry-run: says what it would do). Exit 1: refused. Exit 2: usage.
set -uo pipefail

dry=""
[ "${1:-}" = --dry-run ] && { dry=1; shift; }
[ $# -eq 0 ] || { echo "usage: sync-main.sh [--dry-run]" >&2; exit 2; }
base=${BASE:-main}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_ci=${LOCAL_CI_RUN:-$here/local-ci-run.sh}

verdict() { # verdict <sha>: start local CI on the main tip in the background; never fails
  bash "$run_ci" "$1" --no-wait >&2 \
    || echo "sync-main: warning: local CI was not started on ${1:0:7}; run local-ci-run.sh $1" >&2
}

refuse() { echo "sync-main: refused, nothing changed: $*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || refuse "not in a git repository"
[ "$(git symbolic-ref -q --short HEAD)" = "$base" ] || refuse "this checkout is not on $base"
git fetch -q origin "$base" 2>/dev/null || refuse "cannot fetch origin"
target=$(git rev-parse -q --verify "refs/remotes/origin/$base^{commit}") || refuse "no origin/$base"
head=$(git rev-parse HEAD)
if [ "$head" = "$target" ]; then
  echo "sync-main: $base is up to date with origin/$base (${target:0:7})."
  [ -n "$dry" ] || verdict "$target"
  exit 0
fi
git merge-base --is-ancestor "$head" "$target" || refuse "$base has commits not in origin/$base; a person decides"

declare -A upstream=()
while IFS= read -r -d '' p; do upstream["$p"]=1; done < <(git diff -z --name-only --no-renames "$head" "$target")

# Local paths that differ from HEAD (staged, modified, deleted or untracked) and that origin also changed.
same=(); differ=(); refused=()
while IFS= read -r -d '' entry; do
  p=${entry:3}
  [ -n "${upstream[$p]:-}" ] || continue
  if [ -f "$p" ] && git cat-file -e "$target:$p" 2>/dev/null \
     && [ "$(git hash-object -- "$p")" = "$(git rev-parse "$target:$p")" ]; then same+=("$p")
  elif [[ $p == backlog/* ]]; then differ+=("$p")
  else refused+=("$p"); fi
done < <(git status -z --porcelain=v1 --untracked-files=all --no-renames)

[ ${#refused[@]} -eq 0 ] || refuse "local changes outside backlog/ differ from origin/$base: ${refused[*]}"

backup="$(git rev-parse --git-dir)/sync-main-backup/$(date -u +%Y%m%dT%H%M%SZ)"
clear() { # clear <path>: copy it into the backup, then make it what HEAD has (gone, when HEAD does not track it)
  if [ -n "$dry" ]; then echo "  would back up and clear $1"; return; fi
  if [ -e "$1" ]; then mkdir -p "$backup/$(dirname "$1")" && cp -p -- "$1" "$backup/$1" || return 1; fi
  if git cat-file -e "HEAD:$1" 2>/dev/null; then git checkout -q HEAD -- "$1"
  else git rm -q --cached --ignore-unmatch -- "$1" && rm -f -- "$1"; fi
}
for p in "${same[@]}"; do
  clear "$p" || refuse "cannot back up $p"
  echo "sync-main: backed up, same as origin/$base: $p"
done
for p in "${differ[@]}"; do
  clear "$p" || refuse "cannot back up $p"
  echo "sync-main: backed up, differs from origin/$base, re-apply: $p -> $backup/$p"
done

if [ -n "$dry" ]; then echo "sync-main: would fast-forward $base ${head:0:7}..${target:0:7}."; exit 0; fi
git merge -q --ff-only "$target" \
  || { echo "sync-main: the fast-forward failed after the backup; the backed-up files are in $backup" >&2; exit 1; }
echo "sync-main: $base fast-forwarded ${head:0:7}..${target:0:7}."
verdict "$target"
