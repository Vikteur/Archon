#!/usr/bin/env bash
# tool-advice.sh — PreToolUse hook (Claude Code): point an agent that searches by hand at the CLI (or the MCP tool) that
# answers it.
# Usage: tool-advice.sh PreToolUse   (the tool call as JSON on stdin; settings.json runs it on Read|Grep|Glob and Bash)
#
# Who is covered:
#   - the analyst, developer, test-writer and debugger subagents, anywhere;
#   - every session in a build-feature run worktree (cwd under ${ARCHON_HOME:-~/.archon}/workspaces/*/*/worktrees/*):
#     the explore, plan and implement nodes carry no agent_type, so the folder tells them apart. There a rule fires only
#     when its tool answers in that run: its CLI is ready (codegraph: a .codegraph index and the codegraph command;
#     the contract: scripts/contract-mcp/cli.mjs with its node_modules), or its server is in the run's
#     .archon/mcp/build-tools.json (mcp-setup.sh lists only the ready ones). An organization's MCP registry can block
#     the servers while the CLIs still work, so the CLI is the first route the advice names.
#   The contract-agent owns the spec and is never covered; nor is a main session outside a run worktree.
# Two rules:
#   contract   a Read, Grep or Glob of contract/**, or a Bash search (grep, sed, cat, ... as the first stage of a
#              command) naming contract/, openapi.yaml or an operationId → "use `node scripts/contract-mcp/cli.mjs
#              search / read`, or mcp__<server>__search / read", the server being contract.server_name of
#              .archon/kit.yaml (kit-config.sh; default @@KIT_CONTRACT_SERVER_NAME@@).
#              TOOL_ADVICE_CONTRACT=report (default) adds the advice as context and lets the call run; =refuse denies
#              it with the same words. Report first, refuse once the runs show the advice is followed.
#   symbol     a Grep whose pattern is one Java symbol (CamelCase, optionally .member, no spaces or regex) over Java
#              main code, or a Bash grep/rg naming one outside docs and tests → "`codegraph callers` / `codegraph node`
#              (or codegraph_callers / codegraph_node) answers this". Advice only, never a refusal: grep stays the right
#              tool for strings.
#
# Contract: JSON on stdin, decision JSON on stdout, exit 0 always. No advice prints NOTHING (never "allow", which would
# skip the permission prompt). Fails open: no jq, an unparseable payload or an uncovered session is no advice. It
# decides nothing about scope; scope-guard.sh does.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=payload.sh
. "$here/payload.sh" 2>/dev/null || {
  hook_normalize_payload() { printf '%s' "$1"; }
  hook_deny_json() { jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; }
}
# kit_get from the project's kit-config.sh; without it, the default
. "$here/../../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
agents=" analyst developer test-writer debugger "
command -v jq >/dev/null 2>&1 || exit 0
payload="$(hook_normalize_payload "$(cat)")"
fields="$(printf '%s' "$payload" | jq -r '[.agent_type // "", .tool_name // "", .tool_input.file_path // .tool_input.path // "",
  .tool_input.pattern // "", .tool_input.glob // "", .tool_input.type // "", .cwd // ""] | map(gsub("\u001f"; " ")) | join("\u001f")' 2>/dev/null)" || exit 0
# A unit separator, not a tab: read collapses empty fields between whitespace separators.
IFS=$'\x1f' read -r agent tool path pattern glob type cwd <<<"$fields"
[ "$agent" = contract-agent ] && exit 0

# A path relative to the project, so an absolute path in any checkout (a run worktree) matches the same rules.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
rel="${path#"$root"/}"; [ "$path" = "$root" ] && rel=""

# A run worktree covers every session in it, and only for the tools that answer there: a ready CLI or a server in
# build-tools.json.
server=""
server_name() { [ -n "$server" ] || server="$(kit_get contract.server_name @@KIT_CONTRACT_SERVER_NAME@@)"; }
contract=1; codegraph=1
case "$agents" in
  *" $agent "*) ;;
  *)
    case "${cwd:-$root}/" in "${ARCHON_HOME:-$HOME/.archon}"/workspaces/*/*/worktrees/*/*) ;; *) exit 0 ;; esac
    tools="$root/.archon/mcp/build-tools.json"
    contract=0; codegraph=0; server_name
    jq -e --arg s "$server" 'has($s)' "$tools" >/dev/null 2>&1 && contract=1
    jq -e 'has("codegraph")' "$tools" >/dev/null 2>&1 && codegraph=1
    [ -f "$root/scripts/contract-mcp/cli.mjs" ] && [ -d "$root/scripts/contract-mcp/node_modules" ] && contract=1
    [ -d "$root/.codegraph" ] && command -v codegraph >/dev/null 2>&1 && codegraph=1 ;;
esac

say() { # say <advice> [refuse]
  if [ "${2:-}" = refuse ]; then
    hook_deny_json "$1"
  else
    jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
  fi
  exit 0
}

contract_advice() { # contract_advice <what>
  [ "$contract" -eq 1 ] || return 0
  server_name
  local cli='node scripts/contract-mcp/cli.mjs'
  local msg="tool-advice: $1 of the contract by hand. \`$cli search <words>\` finds an operation by its words and \`$cli read <operationId>\` answers it in full with its verdict; \`$cli schema <name>\` answers a schema. mcp__${server}__search, mcp__${server}__read and mcp__${server}__schema answer the same when they are in your tool list. Read the contract file only for what they leave out."
  if [ "${TOOL_ADVICE_CONTRACT:-report}" = refuse ]; then say "BLOCKED: $msg" refuse; fi
  say "$msg"
}
symbol_advice() { # symbol_advice <symbols, comma-separated> <tool>
  [ "$codegraph" -eq 1 ] || return 0
  case "$1" in
    *", "*) say "tool-advice: $1 are Java symbols. \`codegraph explore \"<the names>\"\` takes them all in one call and answers their source and the calls between them; \`codegraph callers <name>\` who calls one (mcp__codegraph__codegraph_explore and codegraph_callers, when listed). $2 still runs, and stays right for strings." ;;
    *) say "tool-advice: $1 is a Java symbol. \`codegraph callers <name>\` answers who calls it, \`codegraph node <name>\` its source and line, \`codegraph impact <name>\` what a change reaches (mcp__codegraph__codegraph_callers, codegraph_node and codegraph_impact, when listed). $2 still runs, and stays right for strings." ;;
  esac
}
SYMBOL='^[A-Z][a-z0-9]+([A-Z][A-Za-z0-9]*)+(\.[a-z][A-Za-z0-9]*)?$'
# symbols <text>: the Java symbols of a plain alternation (A|B|c_d, no other regex), comma-separated, when it is one
# symbol alone or names two or more; fails otherwise (a file name such as A.java is not a symbol).
symbols() {
  local alt n=0 all=1 out="" alts
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.|-]+$' || return 1
  IFS='|' read -ra alts <<<"$1"
  for alt in "${alts[@]}"; do
    if [[ "$alt" != *.java ]] && printf '%s' "$alt" | grep -qE "$SYMBOL"; then out="$out${out:+, }$alt"; n=$((n+1)); else all=0; fi
  done
  [ "$n" -ge 2 ] || { [ "$n" -eq 1 ] && [ "$all" -eq 1 ]; } || return 1
  printf '%s' "$out"
}

# Bash: each command's first pipeline stage, without VAR= prefixes, as mcp-use-check.js counts them (`git log | grep`
# filters output and is not a search); a | ; & or newline inside quotes splits nothing. The contract rule first, then
# a grep naming symbols outside docs and tests.
if [ "$tool" = Bash ]; then
  stages="$(printf '%s' "$payload" | jq -r '(.tool_input.command // "")
    | [scan("\"[^\"]*\"|\u0027[^\u0027]*\u0027|[^\"\u0027]+|[\"\u0027]")]
    | map(if test("^[\"\u0027].") then gsub("\\|"; "\u0001") | gsub(";"; "\u0002") | gsub("&"; "\u0003") | gsub("\n"; " ") else . end)
    | join("") | [splits(";|&&|\\|\\||\n")]
    | map(split("|")[0] | gsub("\u0001"; "|") | gsub("\u0002"; ";") | gsub("\u0003"; "&")
        | gsub("^\\s+|\\s+$"; "") | sub("^([A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)+"; ""))
    | map(select(length > 0)) | .[]' 2>/dev/null)" || exit 0
  while IFS= read -r stage; do
    prog="${stage%% *}"; prog="${prog##*/}"
    case " grep egrep fgrep rg ag find sed awk cat head tail less " in *" $prog "*) ;; *) continue ;; esac
    if printf '%s' "$stage" | grep -qE "(^|[[:space:]/'\"=])contract(/|\$|[[:space:]])|openapi\.ya?ml|operationId"; then
      contract_advice "Bash $prog"
    fi
    case " grep egrep fgrep rg ag " in *" $prog "*) ;; *) continue ;; esac
    printf '%s' "$stage" | grep -qE "(^|[[:space:]/'\"=])docs/|\.md\b|src/test" && continue
    set -f; read -ra words <<<"$(printf '%s' "$stage" | tr -d "\"'")"; set +f
    for word in "${words[@]}"; do
      case "$word" in -*) continue ;; esac
      syms="$(symbols "$word")" && symbol_advice "$syms" "Bash $prog"
    done
  done <<<"$stages"
  exit 0
fi

# contract: the path, or a Glob's pattern when it has no path, under contract/.
target="$rel"; [ "$tool" = Glob ] && [ -z "$target" ] && target="$pattern"
case "$target" in contract|contract/*) contract_advice "$tool" ;; esac

# symbol: one CamelCase name, optionally Class.member, over Java main code (no path, a src/main path, or a Java filter).
[ "$tool" = Grep ] || exit 0
syms="$(symbols "$pattern")" || exit 0
java=0
case "$rel" in ""|src/main|src/main/*|*/src/main|*/src/main/*) java=1 ;; esac
case "$glob" in *.java*) java=1 ;; esac
[ "$type" = java ] && java=1
[ "$java" -eq 1 ] || exit 0
symbol_advice "$syms" Grep
