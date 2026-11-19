#!/usr/bin/env bash
# Make a checkout ready for the portal-api MCP server (scripts/portal-mcp/server.mjs), which the analyst, developer,
# test-writer and debugger declare inline: its node_modules, the contract at the pin, and a readiness report of that
# contract. All three are git-ignored, so a fresh run worktree has none of them, and without them the server does not
# start and the agent simply runs without its `search` and `read`.
#   portal-mcp-setup.sh [<checkout>]   (default: the current directory)
# Each step is skipped when it is already done. Prints one "portal-mcp: ..." line per step; exits 1 on the first step
# that fails. The build-feature ticket node runs it and goes on when it fails: a run never stops for a docs tool.
# CONTRACT_REMOTE overrides where a missing contract/ is cloned from. .archon/kit.yaml (optional; KIT_* env wins) sets
# contract.repo (owner/repo of the contract, default @@KIT_CONTRACT_REPO@@) and contract.spec_path (default
# contract/dist/openapi.yaml; its first folder is where the contract is cloned).
set -uo pipefail

dir="$(cd "${1:-.}" && pwd)" || exit 1
cd "$dir" || exit 1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$here/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
contract_repo="$(kit_get contract.repo @@KIT_CONTRACT_REPO@@)"
spec_path="$(kit_get contract.spec_path contract/dist/openapi.yaml)"
cdir="${spec_path%%/*}"
say() { echo "portal-mcp: $*"; }
fail() { say "FAIL: $*"; exit 1; }

if [ -d scripts/portal-mcp/node_modules/@modelcontextprotocol/sdk ]; then
  say "node_modules present"
else
  npm ci --prefix scripts/portal-mcp --silent >/dev/null 2>&1 || fail "npm ci in scripts/portal-mcp"
  say "node_modules installed"
fi

if [ ! -d "$cdir/.git" ]; then
  git clone -q --depth 1 "${CONTRACT_REMOTE:-https://github.com/$contract_repo.git}" "$cdir" >/dev/null 2>&1 \
    || fail "cannot clone ${contract_repo#*/} into $cdir/"
fi
pin="$(bash .claude/scripts/contract-pin.sh "$cdir")" || fail "${pin#FAIL: }"
say "${pin#OK: }"

report=build/contract-agent-readiness/readiness-report.json
want="$(sed -n 's/^  version: *//p' "$spec_path" | head -n 1 | tr -d "\"' ")"
have="$(jq -r '.sources.version // empty' "$report" 2>/dev/null)"
if [ -n "$want" ] && [ "$have" = "$want" ]; then
  say "readiness report of v$want present"
else
  bash scripts/contract-agent-readiness.sh --spec "$spec_path" \
    --map docs/code-maps/contract-agent-readiness.map.json >/dev/null 2>&1 || fail "the readiness check"
  say "readiness report of v$want written"
fi
