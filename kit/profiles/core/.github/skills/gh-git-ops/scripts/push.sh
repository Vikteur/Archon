#!/usr/bin/env bash
# Push the current branch to origin, setting upstream if missing.
# Usage: push.sh [--as <account>] [--allow-protected]
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

account="" allow_protected=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) account="${2:?--as needs an account}"; shift 2 ;;
    --allow-protected) allow_protected=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_repo
branch=$(current_branch)
if is_protected "$branch" && ! $allow_protected; then
  die "refusing to push protected branch '$branch' (pass --allow-protected if intended)"
fi
[[ -n "$account" ]] && use_account "$account"

if has_upstream; then
  git push
else
  git push --set-upstream origin "$branch"
fi
echo "pushed: $branch"
