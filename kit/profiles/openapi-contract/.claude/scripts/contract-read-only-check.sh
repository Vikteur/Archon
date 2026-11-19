#!/usr/bin/env bash
# Proves the CI token for rekord-contract is read-only (TASK-2.1, UD-15.e, RISK-51).
# A dry-run push over HTTPS still asks GitHub for git-receive-pack, which a read-only token is refused; a dry run never
# writes a ref. The script passes only when that push is refused by GitHub, and fails closed on anything else: a push
# that succeeds, a missing remote, a missing origin. It never prints the token or `git config` (the token sits in an
# extraheader of the checkout).
# Usage: bash .claude/scripts/contract-read-only-check.sh <contract-checkout-dir>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: contract-read-only-check.sh <contract-checkout-dir>" >&2
  exit 1
fi
dir="$1"

# .git must sit in the directory itself: a plain directory inside another repo would otherwise probe that repo.
if [ ! -e "$dir/.git" ] || ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FAIL: $dir is not a git checkout" >&2
  exit 1
fi

rc=0
out="$(git -C "$dir" push --dry-run origin HEAD:refs/heads/ci-read-only-probe 2>&1)" || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "FAIL: the contract token can push" >&2
  exit 1
fi

if printf '%s\n' "$out" | grep -Eq 'Permission to [^ ]+ denied|The requested URL returned error: 403'; then
  echo "OK: push to rekord-contract refused"
  exit 0
fi

echo "FAIL: the push failed, but not with a refusal:" >&2
printf '%s\n' "$out" >&2
exit 1
