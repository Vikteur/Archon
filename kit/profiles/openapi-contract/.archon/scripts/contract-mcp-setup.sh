#!/usr/bin/env bash
# Make a checkout ready for the @@KIT_CONTRACT_SERVER_NAME@@ MCP server (scripts/contract-mcp/server.mjs), which the analyst, developer,
# test-writer and debugger declare inline: its node_modules, the contract at the pin, and a readiness report of that
# contract. All three are git-ignored, so a fresh run worktree has none of them, and without them the server does not
# start and the agent simply runs without its `search` and `read`.
#   contract-mcp-setup.sh [<checkout>]   (default: the current directory)
# Each step is skipped when it is already done. Prints one "contract-mcp: ..." line per step; exits 1 on the first step
# that fails. The build-feature ticket node runs it and goes on when it fails: a run never stops for a docs tool.
# CONTRACT_REMOTE overrides where a missing contract/ is cloned from. .archon/kit.yaml (optional; KIT_* env wins) sets
# contract.repo (owner/repo of the contract, default @@KIT_CONTRACT_REPO@@) and contract.spec_path (default
# contract/dist/openapi.yaml; its first folder is where the contract is cloned). A spec in a folder that is not a git
# clone is the project's own contract, used as it is. So is an absolute spec_path naming an existing file (the contract
# kept outside the project): no clone, no pin; an absolute path to nothing is refused.
set -uo pipefail

dir="$(cd "${1:-.}" && pwd)" || exit 1
cd "$dir" || exit 1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$here/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
contract_repo="$(kit_get contract.repo @@KIT_CONTRACT_REPO@@)"
spec_path="$(kit_get contract.spec_path contract/dist/openapi.yaml)"
cdir="${spec_path%%/*}"
absolute=0
say() { echo "contract-mcp: $*"; }
fail() { say "FAIL: $*"; exit 1; }
# A relative spec lives in a folder of the project (contract/dist/openapi.yaml): a bare file name or a .. would make
# $cdir the file itself or a folder outside the project. An absolute path is the project's own contract, if it exists.
case "$spec_path" in
  /*) [ -f "$spec_path" ] || fail "contract.spec_path '$spec_path' is an absolute path to no file: put the contract there, or fix the path in .archon/kit.yaml"
      absolute=1 ;;
  ../*|*/../*|*/..) fail "contract.spec_path '$spec_path' must be a path inside the project (contract/dist/openapi.yaml)" ;;
  */*) ;;
  *) fail "contract.spec_path '$spec_path' must name a folder and the spec in it (contract/dist/openapi.yaml)" ;;
esac

if [ -d scripts/contract-mcp/node_modules/@modelcontextprotocol/sdk ]; then
  say "node_modules present"
else
  npm ci --prefix scripts/contract-mcp --silent >/dev/null 2>&1 || fail "npm ci in scripts/contract-mcp"
  say "node_modules installed"
fi

# A spec in a folder that is no clone is the project's own contract (kept in its tree): there is nothing to clone or pin.
# -e, not -d: a worktree or a submodule has a .git file, and it is a clone to pin.
if [ "$absolute" = 1 ]; then
  say "contract at $spec_path (outside the project: not cloned, not pinned)"
elif [ ! -e "$cdir/.git" ] && [ -f "$spec_path" ]; then
  say "contract in the project tree at $spec_path"
else
  if [ ! -e "$cdir/.git" ]; then
    [ -n "$contract_repo" ] || fail "no $spec_path and no contract.repo in .archon/kit.yaml to clone it from"
    git clone -q --depth 1 "${CONTRACT_REMOTE:-https://github.com/$contract_repo.git}" "$cdir" >/dev/null 2>&1 \
      || fail "cannot clone ${contract_repo#*/} into $cdir/"
  fi
  pin="$(bash .claude/scripts/contract-pin.sh "$cdir")" || fail "${pin#FAIL: }"
  say "${pin#OK: }"
fi

report=build/contract-agent-readiness/readiness-report.json
want="$(sed -n 's/^  version: *//p' "$spec_path" | head -n 1 | tr -d "\"' ")"
have="$(jq -r '.sources.version // empty' "$report" 2>/dev/null)"
if [ -n "$want" ] && [ "$have" = "$want" ]; then
  say "readiness report of v$want present"
else
  # The map (look-alikes, thresholds) is the project's own leaf; a project without one is checked on the defaults.
  map=docs/code-maps/contract-agent-readiness.map.json
  map_args=(); [ ! -f "$map" ] || map_args=(--map "$map")
  bash scripts/contract-agent-readiness.sh --spec "$spec_path" ${map_args[@]+"${map_args[@]}"} >/dev/null 2>&1 || fail "the readiness check"
  say "readiness report of v$want written"
fi
