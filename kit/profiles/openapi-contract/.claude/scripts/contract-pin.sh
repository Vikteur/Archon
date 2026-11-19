#!/usr/bin/env bash
# Checks the rekord-contract checkout out at the one pin in gradle.properties (TASK-2.3; BR-OPS-02, RD-02): a tag vX.Y.Z,
# or, on a shared feature branch, that branch's own name. Every CI job that generates code or starts the application runs
# it, inside the job: the local CI runner (ci-local.sh) reproduces no needs/outputs/with.ref, so the pin cannot be passed
# between jobs or to actions/checkout (docs/memory.md, 2026-10-18).
# Usage: bash .claude/scripts/contract-pin.sh <contract-dir> [<properties-file>]   (properties default: gradle.properties)
# The branch comes from CONTRACT_PIN_BRANCH, GITHUB_HEAD_REF, GITHUB_REF_NAME or git, in that order.
# Prints "OK: ..." and exits 0, or prints a FAIL line and exits 1.
# .archon/kit.yaml (optional, KIT_* env wins) sets contract.tag_key (default @@KIT_CONTRACT_TAG_KEY@@), contract.repo (default
# @@KIT_CONTRACT_REPO@@, only named in messages) and contract.spec_path (default contract/dist/openapi.yaml; what follows its first
# folder is the bundle checked for under <contract-dir>).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
tag_key="$(kit_get contract.tag_key @@KIT_CONTRACT_TAG_KEY@@)"
repo_name="$(kit_get contract.repo @@KIT_CONTRACT_REPO@@)"; repo_name="${repo_name#*/}"
spec_path="$(kit_get contract.spec_path contract/dist/openapi.yaml)"

dir="${1:?usage: contract-pin.sh <contract-dir> [<properties-file>]}"
props="${2:-gradle.properties}"
bad() { echo "FAIL: $1"; exit 1; }

pin="$(grep -E "^${tag_key}=" "$props" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$pin" ] || bad "gradle.properties names no $tag_key"
[ "$pin" != "main" ] || bad "$tag_key must be a tag vX.Y.Z or the shared feature branch, never main"

if [[ "$pin" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  kind=tag
else
  kind=branch
  branch="${CONTRACT_PIN_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null)}}}"
  [ -n "$branch" ] || bad "the branch pin $pin needs the current branch (GITHUB_HEAD_REF, GITHUB_REF_NAME or git)"
  [ "$branch" = "$pin" ] || bad "the branch pin $pin is not this branch $branch"
fi

git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || bad "$dir is not a $repo_name checkout"

if [ "$kind" = tag ]; then
  git -C "$dir" fetch -q --depth 1 origin tag "$pin" >/dev/null 2>&1 || bad "$repo_name has no tag $pin"
  # The full ref name: a local branch named like the tag would win over a bare "$pin".
  git -C "$dir" checkout -q "refs/tags/$pin" >/dev/null 2>&1 || bad "cannot check out tag $pin in $dir"
else
  git -C "$dir" fetch -q --depth 1 origin "$pin" >/dev/null 2>&1 || bad "$repo_name has no branch $pin"
  git -C "$dir" checkout -q FETCH_HEAD >/dev/null 2>&1 || bad "cannot check out branch $pin in $dir"
fi

bundle="${spec_path#*/}"   # spec_path is <contract folder>/<bundle>
[ -f "$dir/$bundle" ] || bad "no contract bundle at $dir/$bundle"
echo "OK: $repo_name is at $kind $pin ($(git -C "$dir" rev-parse --short=7 HEAD))"
