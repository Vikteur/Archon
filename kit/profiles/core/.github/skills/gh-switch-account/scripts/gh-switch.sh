#!/usr/bin/env bash
# Switch the active gh account between the accounts of gh_accounts in .archon/kit.yaml (read with yq).
# Usage: gh-switch.sh            -> cycle to the next account
#        gh-switch.sh <account>  -> switch to that account (case-insensitive)
#        gh-switch.sh --status   -> print active account only
set -euo pipefail

ACCOUNTS=()
kit_yaml="${KIT_CONFIG:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.archon/kit.yaml}"
if [[ -f "$kit_yaml" ]] && command -v yq >/dev/null 2>&1; then
  while IFS= read -r a; do
    [[ -n "$a" && "$a" != null ]] && ACCOUNTS+=("$a")
  done < <(yq -r '.gh_accounts // [] | .[]' "$kit_yaml" 2>/dev/null)
fi
if [[ ${#ACCOUNTS[@]} -eq 0 ]]; then
  echo "error: no gh accounts: list them under gh_accounts in $kit_yaml (needs yq)" >&2
  exit 2
fi
HOST="github.com"

active=$(gh api user --jq .login 2>/dev/null || true)

if [[ "${1:-}" == "--status" ]]; then
  echo "active: ${active:-none}"
  exit 0
fi

target=""
if [[ -n "${1:-}" ]]; then
  for a in "${ACCOUNTS[@]}"; do
    [[ "${a,,}" == "${1,,}" ]] && target="$a"
  done
  if [[ -z "$target" ]]; then
    echo "error: unknown account '$1' (expected one of: ${ACCOUNTS[*]})" >&2
    exit 2
  fi
else
  target="${ACCOUNTS[0]}"
  for i in "${!ACCOUNTS[@]}"; do
    if [[ "${ACCOUNTS[$i],,}" == "${active,,}" ]]; then
      target="${ACCOUNTS[$(( (i + 1) % ${#ACCOUNTS[@]} ))]}"
    fi
  done
fi

if [[ "${active,,}" == "${target,,}" ]]; then
  echo "already active: $target"
  exit 0
fi

gh auth switch --hostname "$HOST" --user "$target" >/dev/null
now=$(gh api user --jq .login)
echo "switched: ${active:-none} -> $now"
