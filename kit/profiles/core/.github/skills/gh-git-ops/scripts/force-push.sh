#!/usr/bin/env bash
# Force-push the current branch with --force-with-lease. Never allowed on protected branches.
# Usage: force-push.sh [--as <account>]
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

account=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) account="${2:?--as needs an account}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_repo
branch=$(current_branch)
is_protected "$branch" && die "refusing to force-push protected branch '$branch'"
[[ -n "$account" ]] && use_account "$account"

git push --force-with-lease --set-upstream origin "$branch"
echo "force-pushed: $branch"
