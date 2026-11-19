#!/usr/bin/env bash
# payload.sh — SOURCED helper for the hook scripts: one payload shape in, one decision shape out, so the same script
# runs under Claude Code and under the GitHub Copilot CLI (the kit's .github/hooks/dispatch.sh sources it too).
#   . "$here/payload.sh"
#   payload="$(hook_normalize_payload "$payload")"   # Copilot camelCase -> Claude names; a Claude payload comes back unchanged
#   hook_deny_json "reason"                          # a deny decision in BOTH shapes, one JSON line on stdout
#
# Copilot -> Claude:  toolName -> tool_name (mapped through .archon/copilot/tools.json: bash -> Bash, view -> Read, ...),
#   toolArgs (a JSON string or an object) -> tool_input (a path under another key is copied to the Claude key, view's
#   `path` -> `file_path`), agentName -> agent_type, sessionId -> session_id, workingDirectory -> cwd. A Claude field
#   already present always wins. A payload with none of the Copilot keys is printed back byte for byte (no jq spawn).
# Deny shape: Claude's hookSpecificOutput.permissionDecision{,Reason} plus Copilot's top-level permissionDecision{,Reason}.
# $CLAUDE_PROJECT_DIR falls back to `git rev-parse --show-toplevel`, then $PWD. Fails soft: no jq = payload unchanged.
# Keep this file bash-3.2-clean.

if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  CLAUDE_PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || CLAUDE_PROJECT_DIR=""
  [ -n "$CLAUDE_PROJECT_DIR" ] || CLAUDE_PROJECT_DIR="$PWD"
  export CLAUDE_PROJECT_DIR
fi

hook_normalize_payload() { # hook_normalize_payload <json>
  local p="$1" tools="${COPILOT_TOOLS_JSON:-${CLAUDE_PROJECT_DIR:-$PWD}/.archon/copilot/tools.json}" out
  case "$p" in
    *'"toolName"'*|*'"toolArgs"'*|*'"agentName"'*|*'"sessionId"'*|*'"workingDirectory"'*) ;;
    *) printf '%s' "$p"; return 0 ;;
  esac
  command -v jq >/dev/null 2>&1 || { printf '%s' "$p"; return 0; }
  [ -f "$tools" ] || tools=/dev/null
  out="$(printf '%s' "$p" | jq -c --slurpfile map <(cat "$tools" 2>/dev/null; echo) '
    def builtin: {bash:"Bash", shell:"Bash", powershell:"Bash", run_shell_command:"Bash", run_in_terminal:"Bash",
                  view:"Read", create:"Write", edit:"Edit", str_replace_editor:"Edit", grep:"Grep", glob:"Glob", skill:"Skill"};
    (try ($map[0].tools // {}) catch {}) as $m
    | (if type == "object" then . else {} end) as $o
    | ($o.toolName // "") as $n
    | ($m[$n | ascii_downcase] // null) as $e
    | (if $e == null then null elif ($e | type) == "string" then $e else $e.as end) as $mapped
    | ($o.toolArgs // null) as $ta
    | (if ($ta | type) == "string" then (try ($ta | fromjson) catch {command: $ta}) elif $ta == null then {} else $ta end) as $args
    | ($args | if type == "object" then . else {} end) as $ti
    | (if ($e | type) == "object" and ($e.key // "") != "" and ($ti[$e.key] // null) == null
         then ([$e.from[]? | select($ti[.] != null)] | first // null) as $src
              | (if $src == null then $ti else $ti + {($e.key): $ti[$src]} end)
         else $ti end) as $ti2
    | $o
    + (if $o.tool_name == null and $n != "" then {tool_name: ($mapped // builtin[$n | ascii_downcase] // $n)} else {} end)
    + (if $o.tool_input == null and $ta != null then {tool_input: $ti2} else {} end)
    + (if $o.agent_type == null and ($o.agentName // "") != "" then {agent_type: $o.agentName} else {} end)
    + (if $o.session_id == null and ($o.sessionId // "") != "" then {session_id: $o.sessionId} else {} end)
    + (if $o.cwd == null and ($o.workingDirectory // "") != "" then {cwd: $o.workingDirectory} else {} end)
  ' 2>/dev/null)" || out=""
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$p"; fi
}

hook_deny_json() { # hook_deny_json <reason>: a deny in the Claude and the Copilot shape
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$1" '{permissionDecision:"deny",permissionDecisionReason:$r,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    local r="${1//\\/\\\\}"; r="${r//\"/\\\"}"; r="${r//$'\n'/ }"
    printf '{"permissionDecision":"deny","permissionDecisionReason":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$r" "$r"
  fi
}
