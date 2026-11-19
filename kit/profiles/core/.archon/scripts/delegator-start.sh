#!/usr/bin/env bash
# Start the delegator session (P2: a script; R2, owner decision 2026-10-20 D3). The session runs in auto mode with the
# checked-in allow rules of .claude/delegator.settings.json, which mirror the delegator's `tools` (never
# `archon workflow *`), and with Remote Control, so a night asks for no click and the owner can follow from the phone.
#   delegator-start.sh [<claude args>...]   from the main checkout, on main
# Exit codes: it execs claude, so a started session exits with claude's code. Before that:
#   2  not the main checkout, or the main checkout is not on main (the backlog is read and edited there, AGENTS.md)
#   3  a live delegator session holds the lock (merge-queue/delegator/session.lock); two delegators double every action.
#      A lock whose process is gone is removed, with a line saying so, and the start goes on.
#   1  claude or the settings file is missing
# The lock is "<session> <pid> <since>"; this script writes it with its own pid (exec keeps it), and the session's
# SessionStart hook (delegator-session.sh) rewrites it with the session id.
# AGENT_CLI (or agent_cli in .archon/kit.yaml, default claude): `copilot` starts `copilot --agent delegator --allow-all-tools`
# (no settings file, permission mode or remote control there; the delegator's tools come from its agent file).
# Overrides: DELEGATOR_STATE_DIR, CLAUDE_BIN (claude), AGENT_CLI.
set -uo pipefail

die() { echo "delegator-start: $2" >&2; exit "$1"; }
top=$(git rev-parse --show-toplevel 2>/dev/null) || die 2 "not in a git checkout"
main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$main" && pwd -P)" ] \
  || die 2 "run it from the main checkout ($main), not from $top"
branch=$(git -C "$main" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$branch" = main ] || die 2 "the main checkout is on '$branch', not main"

state=${DELEGATOR_STATE_DIR:-$(dirname "$main")/merge-queue/delegator}
mkdir -p "$state" || die 1 "cannot create $state"
lock=$state/session.lock
if [ -f "$lock" ]; then
  read -r lsess lpid lsince < "$lock" 2>/dev/null || true
  if [ -n "${lpid:-}" ] && kill -0 "$lpid" 2>/dev/null; then
    die 3 "a delegator session is live (session ${lsess:-?}, pid $lpid, since ${lsince:-?}); end it first"
  fi
  echo "delegator-start: removed a stale lock (session ${lsess:-?}, pid ${lpid:-?} is gone)" >&2
  rm -f "$lock"
fi

settings=$main/.claude/delegator.settings.json
[ -f "$settings" ] || die 1 "missing $settings"
agent_cli=$(bash -c '. "$1"; kit_get agent_cli claude AGENT_CLI' _ "$(dirname "${BASH_SOURCE[0]}")/kit-config.sh" 2>/dev/null || echo claude)
if [ "$agent_cli" = copilot ]; then claude=${COPILOT_BIN:-copilot}; else claude=${CLAUDE_BIN:-claude}; fi
command -v "$claude" >/dev/null 2>&1 || die 1 "$claude is not on the PATH"
echo "starting $$ $(date '+%Y-%m-%d %H:%M:%S')" > "$lock"
cd "$main" || die 1 "cannot enter $main"
if [ "$agent_cli" = copilot ]; then exec "$claude" --agent delegator --allow-all-tools "$@"; fi
exec "$claude" --agent delegator --settings "$settings" --permission-mode auto --remote-control delegator "$@"
