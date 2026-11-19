#!/usr/bin/env bash
# Make a run worktree's MCP servers ready, and tell the workflow nodes which ones are: runs contract-mcp-setup.sh and
# codegraph-setup.sh, then writes .archon/mcp/build-tools.json (git-ignored) with only the servers whose setup passed.
# The nodes that use the servers declare that file as an optional `mcp:` (docs/mcp/plan.md, A3): Archon fails a node
# whose declared server cannot start, and `optional: true` only covers a missing file, so a server that is not ready
# must not be in it. With neither ready it removes the file, and the nodes run without the tools.
#   mcp-setup.sh [--status <file>] [<checkout>]   (default: the current directory)
# Prints the setup scripts' lines, then one "mcp: <contract server> up|down, codegraph up|down" line (the contract server
# is contract.server_name of .archon/kit.yaml, default @@KIT_CONTRACT_SERVER_NAME@@); with --status it also
# appends them all to <file> (build-feature: $ARTIFACTS_DIR/mcp-status.txt, which the tokenomics report reads). Exits 0
# when it could judge both servers, up or down; 1 only when the checkout or the file cannot be written.
# MCP_CONTRACT_SETUP and MCP_CODEGRAPH_SETUP override the two setup scripts (the tests).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$here/kit-config.sh"
# CodeGraph 1.6 lists only codegraph_explore unless told otherwise; the agents' routing tables also name these. The
# agent manifests' inline codegraph servers carry the same list (mcp-setup.test.sh holds them equal).
CODEGRAPH_TOOLS="explore,node,search,callers,callees,impact"
status=""
if [ "${1:-}" = --status ]; then status="${2:?--status needs a file}"; shift 2; fi
dir="$(cd "${1:-.}" && pwd)" || exit 1
cd "$dir" || exit 1
server="$(kit_get contract.server_name @@KIT_CONTRACT_SERVER_NAME@@)"   # the checkout's .archon/kit.yaml, else the default
log() { printf '%s\n' "$1"; [ -z "$status" ] || printf '%s\n' "$1" >>"$status"; }

run() { # run <script>: its lines through log, and its exit code
  local out rc
  out="$(bash "$1" "$dir" 2>&1)"; rc=$?
  while IFS= read -r l; do [ -n "$l" ] && log "$l"; done <<<"$out"
  return "$rc"
}
contract=down; run "${MCP_CONTRACT_SETUP:-$here/contract-mcp-setup.sh}" && contract=up
codegraph=down; run "${MCP_CODEGRAPH_SETUP:-$here/codegraph-setup.sh}" && codegraph=up

file=.archon/mcp/build-tools.json
if [ "$contract" = down ] && [ "$codegraph" = down ]; then
  rm -f "$file" || exit 1
else
  mkdir -p "$(dirname "$file")" || exit 1
  jq -n --arg dir "$dir" --arg server "$server" --arg contract "$contract" --arg codegraph "$codegraph" --arg tools "$CODEGRAPH_TOOLS" '
    {}
    + (if $contract == "up" then {($server): {command: "node", args: ["\($dir)/scripts/contract-mcp/server.mjs"],
        env: {CLAUDE_PROJECT_DIR: $dir}}} else {} end)
    + (if $codegraph == "up" then {codegraph: {command: "codegraph", args: ["serve", "--mcp", "--path", $dir],
        env: {CODEGRAPH_MCP_TOOLS: $tools}}} else {} end)
  ' >"$file" || exit 1
fi
log "mcp: $server $contract, codegraph $codegraph"
