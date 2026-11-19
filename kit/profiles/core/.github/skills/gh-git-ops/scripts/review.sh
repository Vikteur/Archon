#!/usr/bin/env bash
# Submit a PR review (comment or request changes) with optional inline line comments.
# Usage: review.sh [--pr <number>] [--event COMMENT|REQUEST_CHANGES] [--body <summary>]
#                  [--comment <path> <line | start-end> <text>]... [--as <account>] [--dry-run]
#   --pr       defaults to the open PR of the current branch
#   --comment  repeatable; line is the line number in the PR's new version of the file
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

pr="" event="COMMENT" body="" account="" dry_run=false
paths=() lines=() texts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) pr="${2:?--pr needs a number}"; shift 2 ;;
    --event) event="${2^^}"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --comment)
      [[ $# -ge 4 ]] || die "--comment needs <path> <line> <text>"
      paths+=("$2"); lines+=("$3"); texts+=("$4"); shift 4 ;;
    --as) account="${2:?--as needs an account}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$event" in
  COMMENT|REQUEST_CHANGES) ;;
  *) die "--event must be COMMENT or REQUEST_CHANGES" ;;
esac
[[ ${#paths[@]} -gt 0 || -n "$body" ]] || die "nothing to post: give --body and/or --comment"
[[ "$event" == "REQUEST_CHANGES" && -z "$body" ]] && die "REQUEST_CHANGES needs a --body summary"

[[ -n "$account" ]] && use_account "$account"

if [[ -z "$pr" ]]; then
  require_repo
  pr=$(gh pr view --json number --jq .number 2>/dev/null) || die "no PR for current branch; pass --pr <number>"
fi

args=(--method POST "repos/{owner}/{repo}/pulls/$pr/reviews" -f "event=$event")
[[ -n "$body" ]] && args+=(-f "body=$body")
for i in "${!paths[@]}"; do
  line="${lines[$i]}"
  args+=(-f "comments[][path]=${paths[$i]}")
  if [[ "$line" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    args+=(-F "comments[][start_line]=${BASH_REMATCH[1]}" -F "comments[][line]=${BASH_REMATCH[2]}")
  elif [[ "$line" =~ ^[0-9]+$ ]]; then
    args+=(-F "comments[][line]=$line")
  else
    die "invalid line '$line' for ${paths[$i]} (use N or START-END)"
  fi
  args+=(-f "comments[][side]=RIGHT" -f "comments[][body]=${texts[$i]}")
done

if $dry_run; then
  printf 'gh api'; printf ' %q' "${args[@]}"; echo
  exit 0
fi

url=$(gh api "${args[@]}" --jq .html_url)
echo "review posted ($event, ${#paths[@]} inline comment(s)) on PR #$pr: $url"
