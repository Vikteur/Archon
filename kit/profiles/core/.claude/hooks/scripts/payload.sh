#!/usr/bin/env bash
# payload.sh — SOURCED helper for the hook scripts: one payload shape in, one decision shape out, so the same script
# runs under Claude Code and under the GitHub Copilot CLI (the kit's .github/hooks/dispatch.sh sources it too).
#   . "$here/payload.sh"
#   payload="$(hook_normalize_payload "$payload")"   # Copilot camelCase -> Claude names; a Claude payload comes back unchanged
#   hook_deny_json "reason"                          # a deny decision in BOTH shapes, one JSON line on stdout
#
# Copilot -> Claude:  toolName -> tool_name (mapped through .archon/copilot/tools.json: bash -> Bash, view -> Read, ...),
#   toolArgs (a JSON string or an object) -> tool_input (a path under another key is copied to the Claude key, view's
#   `path` -> `file_path`), agentType (a subagent's tool hook) or agentName (subagentStart/Stop) -> agent_type,
#   agentId -> agent_id, sessionId -> session_id, workingDirectory -> cwd. A Claude field already present always wins.
#   $KIT_AGENT names the agent when the payload names none: a root session (`copilot --agent <name>`) carries no agent
#   field, so a converted agent's own frontmatter hook sets it (kit/SPEC.md). A subagent's agentType wins over it; a
#   subagent call that names no type is fenced as the root agent (kit_root). A tool name is mapped wherever it sits
#   (toolName, or a lower-case native name in tool_name). A converted payload also carries kit_copilot:true, and
#   kit_root when $KIT_AGENT is set, so scope-guard can apply the Copilot-only rules. A payload with none of the
#   Copilot keys, and no $KIT_AGENT to add, is printed back byte for byte (no jq spawn).
# Deny shape: Claude's hookSpecificOutput.permissionDecision{,Reason} plus Copilot's top-level permissionDecision{,Reason}.
# $CLAUDE_PROJECT_DIR falls back to `git rev-parse --show-toplevel`, then $PWD. Unreadable (no jq, not a JSON object):
# the payload comes back unchanged, with exit 3 when it may name an agent (an agent key, or $KIT_AGENT set).
# A leading `rtk ` / `rtk proxy ` of a Bash command is dropped so the fence judges the command rtk rewrote (see
# hook_normalize_payload below). Keep this file bash-3.2-clean.

if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  CLAUDE_PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || CLAUDE_PROJECT_DIR=""
  [ -n "$CLAUDE_PROJECT_DIR" ] || CLAUDE_PROJECT_DIR="$PWD"
  export CLAUDE_PROJECT_DIR
fi

_hook_normalize_core() { # the shape conversion; hook_normalize_payload below wraps it
  local p="$1" tools="${COPILOT_TOOLS_JSON:-${CLAUDE_PROJECT_DIR:-$PWD}/.archon/copilot/tools.json}" out="" pass=1
  case "$p" in
    *'"toolName"'*|*'"toolArgs"'*|*'"agentName"'*|*'"agentType"'*|*'"agentId"'*|*'"sessionId"'*|*'"workingDirectory"'*) pass=0 ;;
  esac
  # A Copilot-native (lower-case) name in the Claude field, e.g. {"tool_name":"bash"}: map it too. mcp__ is Claude's own.
  case "$p" in
    *'"tool_name":"mcp__'*|*'"tool_name": "mcp__'*) ;;
    *'"tool_name":"'[a-z]*|*'"tool_name": "'[a-z]*) pass=0 ;;
  esac
  [ -z "${KIT_AGENT:-}" ] || case "$p" in *'"agent_type"'*) ;; *) pass=0 ;; esac
  [ "$pass" -eq 0 ] || { printf '%s' "$p"; return 0; }
  [ -f "$tools" ] || tools=/dev/null
  if command -v jq >/dev/null 2>&1; then
    # --rawfile, not --slurpfile: a tools.json that is not JSON must not abort jq before the filter (the built-ins still map).
    out="$(printf '%s' "$p" | jq -c --arg kit "${KIT_AGENT:-}" --rawfile maptext "$tools" '
      def builtin: {bash:"Bash", shell:"Bash", powershell:"Bash", run_shell_command:"Bash", run_in_terminal:"Bash",
                    view:"Read", create:"Write", edit:"Edit", str_replace_editor:"Edit", grep:"Grep", glob:"Glob", skill:"Skill"};
      (try ($maptext | fromjson | .tools) catch null) as $m0
      | (if ($m0 | type) == "object" then $m0 else {} end) as $m
      | (if type == "object" then . else error("not an object") end) as $o
      # An untyped call (a root session, or a subagent whose payload names no type) is fenced as KIT_AGENT.
      | ([$o.agent_type, $o.agentType, $o.agentName, $kit | select(type == "string" and . != "")] | first) as $agent
      | ([$o.tool_name, $o.toolName | select(type == "string" and . != "")] | first // "") as $n
      | ($n | ascii_downcase) as $lc
      | ($m[$lc] // null) as $e
      | (if $e == null then null elif ($e | type) == "string" then $e else $e.as end) as $mapped
      | ($o.toolArgs // null) as $ta
      | (if ($o.tool_input | type) == "object" then $o.tool_input
         elif ($ta | type) == "string" then (try ($ta | fromjson) catch {command: $ta})
         elif $ta == null then {} else $ta end) as $args
      | ($args | if type == "object" then . else {} end) as $ti
      | (if ($e | type) == "object" and ($e.key // "") != "" and ($ti[$e.key] // null) == null
           then ([$e.from[]? | select($ti[.] != null)] | first // null) as $src
                | (if $src == null then $ti else $ti + {($e.key): $ti[$src]} end)
           else $ti end) as $ti2
      | $o
      + {kit_copilot: true}
      + (if $kit != "" then {kit_root: $kit} else {} end)
      + (if $n != "" then {tool_name: ($mapped // builtin[$lc] // $n)} else {} end)
      + (if $o.tool_input != null or $ta != null then {tool_input: $ti2} else {} end)
      + (if $agent != null then {agent_type: $agent} else {} end)
      + (if $o.agent_id == null and ($o.agentId // "") != "" then {agent_id: $o.agentId} else {} end)
      + (if $o.session_id == null and ($o.sessionId // "") != "" then {session_id: $o.sessionId} else {} end)
      + (if $o.cwd == null and ($o.workingDirectory // "") != "" then {cwd: $o.workingDirectory} else {} end)
    ' 2>/dev/null)" || out=""
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  # Unreadable (no jq, or not a JSON object): back unchanged, and exit 3 when it may name an agent, so a guard denies
  # instead of seeing an unfenced call.
  printf '%s' "$p"
  case "$p" in *'"agentType"'*|*'"agentName"'*|*'"agentId"'*|*'"agent_type"'*) return 3 ;; esac
  [ -z "${KIT_AGENT:-}" ] || return 3
  return 0
}

# hook_normalize_payload <json>: the shape conversion, then the rtk prefix. rtk (a token-saving CLI proxy) has a Copilot
# hook that rewrites a Bash command `git status` into `rtk git status`; the fence must judge the real command, so ONE
# leading `rtk ` (or `rtk proxy `) is dropped from a Bash command here, in both payload shapes. Only the first word, and
# only when a command follows: a bare `rtk` stays `rtk` (denied for an agent whose allowlist lacks it), `rtk rtk git` is
# judged as `rtk git`, and `rtk` anywhere later in the command is left alone. Needs jq; without it nothing changes
# (and the guards fail closed without jq anyway). Exit 3 as _hook_normalize_core gives it.
hook_normalize_payload() { # hook_normalize_payload <json>
  local out rc stripped
  out="$(_hook_normalize_core "$1")"; rc=$?
  case "$out" in
    *rtk*)
      if command -v jq >/dev/null 2>&1 && stripped="$(printf '%s' "$out" | jq -c '
          # blanks only (no newline: `rtk` then a newline is two commands), and a real command word must follow
          if type == "object" and .tool_name == "Bash" and ((.tool_input.command // null) | type) == "string"
             and (.tool_input.command | test("^[ \\t]*rtk[ \\t]+[^ \\t\\r\\n;&|<>()]"))
             and (.tool_input.command | test("^[ \\t]*rtk[ \\t]+proxy[ \\t]*$") | not)
          then .tool_input.command |= (if test("^[ \\t]*rtk[ \\t]+proxy[ \\t]+[^ \\t\\r\\n;&|<>()]")
                                       then sub("^[ \\t]*rtk[ \\t]+proxy[ \\t]+"; "") else sub("^[ \\t]*rtk[ \\t]+"; "") end)
          else . end' 2>/dev/null)" && [ -n "$stripped" ]; then out="$stripped"; fi ;;
  esac
  printf '%s' "$out"
  return "$rc"
}

hook_deny_json() { # hook_deny_json <reason>: a deny in the Claude and the Copilot shape
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$1" '{permissionDecision:"deny",permissionDecisionReason:$r,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    local r="${1//\\/\\\\}"; r="${r//\"/\\\"}"; r="${r//$'\n'/ }"
    printf '{"permissionDecision":"deny","permissionDecisionReason":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$r" "$r"
  fi
}
