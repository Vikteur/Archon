#!/usr/bin/env bash
# Make a checkout ready for the CodeGraph MCP server (`codegraph serve --mcp`): its index, `.codegraph/`, is per folder
# and git-ignored, so a fresh run worktree has none, and without it the codegraph_* tools answer nothing.
#   codegraph-setup.sh [<checkout>]   (default: the current directory)
# Builds the index when there is none (`codegraph init -y`, about 5 s on this repo) and brings it up to date when there
# is one (`codegraph sync`). Prints one "codegraph: ..." line per step; exits 1 on the first step that fails. The
# build-feature ticket node runs it through mcp-setup.sh and goes on when it fails: a run never stops for a docs tool.
# CODEGRAPH overrides the binary (the tests).
set -uo pipefail

dir="$(cd "${1:-.}" && pwd)" || exit 1
cd "$dir" || exit 1
cg="${CODEGRAPH:-codegraph}"
say() { echo "codegraph: $*"; }
fail() { say "FAIL: $*"; exit 1; }

command -v "$cg" >/dev/null 2>&1 || fail "no $cg on PATH (npm install -g @colbymchenry/codegraph)"
if [ -d .codegraph ]; then
  "$cg" sync -q . >/dev/null 2>&1 || fail "codegraph sync in $dir"
  say "index synced"
else
  "$cg" init -y >/dev/null 2>&1 || fail "codegraph init in $dir"
  [ -d .codegraph ] || fail "codegraph init wrote no .codegraph/ in $dir"
  say "index built"
fi
