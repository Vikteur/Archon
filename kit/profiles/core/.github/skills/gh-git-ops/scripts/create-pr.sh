#!/usr/bin/env bash
# Push the current branch if needed, then open a PR with gh.
# Usage: create-pr.sh [--as <account>] [--title T] [--body B | --body-file F] [--base BRANCH] [--draft] [-- extra gh pr create args]
# Without --title, gh fills title/body from the commits (--fill).
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

account="" title="" body="" body_file="" base="" draft=false extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) account="${2:?--as needs an account}"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --draft) draft=true; shift ;;
    --) shift; extra=("$@"); break ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_repo
branch=$(current_branch)
is_protected "$branch" && die "on protected branch '$branch'; create a feature branch first"
[[ -n "$account" ]] && use_account "$account"

existing=$(gh pr view "$branch" --json url,state --jq 'select(.state == "OPEN") | .url' 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  echo "PR already open: $existing"
  exit 0
fi

if ! has_upstream; then
  git push --set-upstream origin "$branch"
elif [[ -n "$(git log "@{u}..HEAD" --oneline)" ]]; then
  git push
fi

args=(--head "$branch")
[[ -n "$base" ]] && args+=(--base "$base")
$draft && args+=(--draft)
if [[ -n "$title" ]]; then
  args+=(--title "$title")
  if [[ -n "$body_file" ]]; then args+=(--body-file "$body_file"); else args+=(--body "$body"); fi
else
  args+=(--fill)
fi

gh pr create "${args[@]}" "${extra[@]}"
