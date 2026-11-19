#!/usr/bin/env bash
# Delete a branch locally and/or on origin. Never deletes protected or checked-out branches.
# Usage: delete-branch.sh <branch> [--local-only | --remote-only] [--force] [--as <account>]
#   --force  delete the local branch even if unmerged (git branch -D)
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

branch="" account="" do_local=true do_remote=true force=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) account="${2:?--as needs an account}"; shift 2 ;;
    --local-only) do_remote=false; shift ;;
    --remote-only) do_local=false; shift ;;
    --force) force=true; shift ;;
    -*) die "unknown argument: $1" ;;
    *) [[ -z "$branch" ]] || die "only one branch at a time"; branch="$1"; shift ;;
  esac
done

[[ -n "$branch" ]] || die "usage: delete-branch.sh <branch> [--local-only|--remote-only] [--force] [--as <account>]"
require_repo
is_protected "$branch" && die "refusing to delete protected branch '$branch'"
[[ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$branch" ]] && die "'$branch' is checked out; switch branches first"
[[ -n "$account" ]] && use_account "$account"

if $do_local; then
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    if $force; then git branch -D "$branch"; else git branch -d "$branch"; fi
  else
    echo "no local branch: $branch"
  fi
fi

if $do_remote; then
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git push origin --delete "$branch"
  else
    echo "no remote branch: origin/$branch"
  fi
fi
