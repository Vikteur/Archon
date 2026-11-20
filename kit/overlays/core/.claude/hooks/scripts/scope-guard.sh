#!/usr/bin/env bash
# scope-guard.sh — fail-closed PreToolUse hook (Claude Code): enforce each agent's write, read and
# command fence.
#
# The Copilot agents declared `allowedFilePaths` and `commandAllowlist` in their frontmatter. Claude
# Code subagents have no such fields, so the fences live in `.claude/hooks/agent-scopes.json` (keyed
# by agent name) and this hook enforces them on every Write/Edit/NotebookEdit/Bash call, and on
# Read/Grep/Glob for an agent that has a `readPaths` fence:
#
#   Write/Edit   target path must fall inside the agent's `allowedFilePaths`
#                (`dir/` = prefix, otherwise exact path or bash glob where `*` spans `/`).
#                `allowedFilePaths` absent = any path; `[]` = no writes at all.
#   Read/Grep/   the path read or searched must fall inside the agent's `readPaths` (`dir/` = prefix,
#   Glob         `~/dir/` = prefix under the home folder, otherwise exact path or glob). A Grep or
#                Glob must name its path. `readPaths` absent = read anything.
#   Bash         every command segment (split on ; && || | & and newlines, outside quotes; the & of a
#                `>&`/`<&` redirect such as 2>&1 splits nothing, and <( or >( is denied) must
#                start with an entry of the agent's `commandAllowlist`. `cd` is always allowed, and so is
#                `tail` or `head` with count options only right after a single | (`| tail -15`).
#                `git --no-pager <cmd>` is read as `git <cmd>`.
#                Command substitution outside single quotes is denied except the `$(cat <<'EOF' … )`
#                heredoc form used for commit/PR messages. Quotes and \ escapes are read as bash
#                reads them, so single-quoted text is free and an escaped quote opens no string.
#
# The project's additions: .claude/hooks/agent-scopes.local.json, beside the kit's agent-scopes.json, may only ADD
# command prefixes to agents agent-scopes.json already fences: {"agents": {"<agent>": {"commandAllowlist": [...]}}}
# (and a "_comment"). Its entries are added to the agent's list; nothing it holds removes or replaces one, so a kit
# update that adds an entry still reaches the agent. Anything else is refused: another key (allowedFilePaths,
# readPaths, hubRoot, a new top-level key), an agent agent-scopes.json does not fence, an entry that is empty, holds a
# shell operator, or starts with a wrapper or a bare interpreter that runs any code (env, xargs, sudo, bash -c,
# node -e, ...), or a file that is not JSON. A refused file denies every call of a fenced agent with the reason until it
# is fixed (fail closed): a typo never widens a fence, and it never passes unseen. No agent may write it (below).
#
# Who is fenced: the `agent_type` field Claude Code puts on every event fired inside a subagent (or a
# session started with `--agent`). No agent_type, or an agent with no entry → not this hook's
# business (exit 0, no output — normal permission flow applies).
#
# Inside an Archon workflow node (Copilot only): .github/hooks/dispatch.sh sets KIT_NODE to the node's id (from
# ARCHON_NODE_EXECUTION, which Archon sets for the node's CLI session). .archon/copilot/node-fences.json maps the node to
# an agent: every call of that session is fenced as that agent (deny reasons name "<agent> (node <id>)"), with what the
# file adds for that node only: commandAllowlist prefixes (checked as agent-scopes.local.json entries are),
# allowedFilePaths (the token $RUN_ARTIFACTS/ is the run's own artifacts folder,
# <ARCHON_HOME or ~/.archon>/workspaces/<owner>/<repo>/artifacts/runs/$WORKFLOW_ID/, an absolute path; an agent that may
# write any path keeps that), and env (names a command may assign in front of an allowed command, NAME=value cmd; a
# `$(cat <file in the run's artifacts folder>)` is read as plain text in such a command). A subagent of another fenced
# type is checked by its own fence as well. A node the file does not name (or KIT_NODE=?, a node path dispatch.sh could
# not read) gets the strictest common set: the commands every named node may run and only the paths every one of them
# may write ([] when none of them has a write fence), no env names. Fail closed: inside a node, a missing or invalid
# node-fences.json, a missing agent-scopes.json or a jq that cannot read the call denies every call. No fenced agent
# may write node-fences.json. CLAUDE_SCOPE_NODES overrides the file (tests). The tools that kit.json sends here by name
# are checked by those entries; a third entry ('*' --other-tools) checks every other tool inside a node only.
#
# Contract: JSON payload on stdin, decision JSON on stdout, exit 0. "No objection" prints NOTHING:
# in Claude Code `permissionDecision:"allow"` would skip the user's permission prompt.
# Failure direction: missing policy / unparseable payload → no objection (fail open, like
# guard-generated.sh); an error AFTER the agent was identified → deny with a reason (EXIT trap).
#
# RESIDUAL, stated plainly: this reads the command string. It does not see what a script the agent is
# allowed to run does, nor a redirect (`git log > file`) inside an allowed command.
# Keep this file bash-3.2-clean (no mapfile, no ${x,,}, no declare -A) — see README.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# payload.sh: Copilot camelCase payloads become Claude names, and a deny is printed in both shapes (a Claude payload is untouched).
# shellcheck source=payload.sh
. "$here/payload.sh" 2>/dev/null || {
  hook_normalize_payload() { printf '%s' "$1"; }
  hook_deny_json() { jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; }
}
policy="${CLAUDE_SCOPE_POLICY:-$here/../agent-scopes.json}"
policy_rel=".claude/hooks/agent-scopes.json"
# The project's additions (see the header). A test that names its policy names its additions too (CLAUDE_SCOPE_LOCAL),
# so the project's own file never changes a suite's verdict.
if [ -n "${CLAUDE_SCOPE_POLICY:-}" ]; then local_policy="${CLAUDE_SCOPE_LOCAL:-}"; else local_policy="$here/../agent-scopes.local.json"; fi
[ -n "$local_policy" ] && [ -f "$local_policy" ] || local_policy=/dev/null

decided=0
armed=0
emit_fallback_deny() {
  [ "$decided" -eq 1 ] && return 0
  [ "$armed" -eq 1 ] || return 0                 # not yet identified as a fenced agent: no objection
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: the agent scope guard (.claude/hooks/scripts/scope-guard.sh) failed before it could decide, so it is denying. This is a bug in the hook, not a judgement about your call."}}'
  decided=1
}
trap 'emit_fallback_deny; exit 0' EXIT

allow() { decided=1; exit 0; }
deny() { decided=1
  hook_deny_json "$1"
  deny_record "$1"
  exit 0
}

# A denied call never reaches postToolUse, so audit-log.sh never records it: the guard appends a DENY record to the
# session's audit trail itself, in the form of audit-log.sh's TOOL record (tool, the arg cut to 200 bytes a line, the
# node) plus the deny reason. Only when <project>/.apm-audit/sessions exists (audit-log.sh made it at sessionStart): the
# guard creates no audit folder. It never changes the decision: every step is defensive, and a failure writes nothing.
# A subagent's own fence (the nested run below) writes its own record; the outer run only passes that deny on.
deny_record() {  # deny_record <reason>
  local d="${CLAUDE_PROJECT_DIR:-}/.apm-audit/sessions" rec sid
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$d" ] && command -v jq >/dev/null 2>&1 || return 0
  rec="$(printf '%s' "${payload:-}" | jq -c --arg r "$1" --arg ag "${agent:-}" --arg nd "${node:-}" '
    def cut: gsub("\r"; "") | split("\n") | map(if utf8bytelength > 200 then .[0:200] else . end) | join("\n");
    (.tool_input // {}) as $a
    | {type: "DENY", event: "preToolUse",
       session: ((.session_id // .sessionId // "") | tostring | gsub("[^A-Za-z0-9._-]"; "") | .[0:64]
                 | if . == "" then "unknown" else . end),
       agent: $ag, ts: ((.timestamp // "") | tostring), loggedAt: (now | todate)}
      + (if ($nd | test("^[A-Za-z0-9_-]+$")) then {node: $nd} else {} end)
      + {tool: ((.tool_name // "") | tostring),
         arg: (($a.command // $a.file_path // $a.notebook_path // $a.path // $a.pattern // ($a | tostring)) | tostring | cut),
         reason: $r}' 2>/dev/null)" || return 0
  [ -n "$rec" ] || return 0
  sid="$(printf '%s' "$rec" | jq -r .session 2>/dev/null)" || return 0
  [[ $sid =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  printf '%s\n' "$rec" >> "$d/$sid.jsonl" 2>/dev/null || true
}

node="${KIT_NODE:-}"
other_tools=0; [ "${2:-}" = "--other-tools" ] && other_tools=1
# the '*' entry of kit.json covers only the tools the named entries do not, and only inside a node
[ "$other_tools" -eq 0 ] || [ -n "$node" ] || allow
if [ -n "$node" ]; then
  node_file="${CLAUDE_SCOPE_NODES:-$here/../../../.archon/copilot/node-fences.json}"
  [ -f "$policy" ] || deny "BLOCKED: inside Archon node '$node' every call is fenced, and the agent fences ($policy_rel) are missing, so the scope guard denies. Reinstall the kit (archon kit add)."
else
  node_file=/dev/null
fi
[ -f "$policy" ] || allow
payload="$(cat 2>/dev/null || true)"
payload="$(hook_normalize_payload "$payload")" || deny "BLOCKED: the agent scope guard could not read this Copilot tool call (jq missing, or the payload is not a JSON object), and it may come from a fenced agent, so it denies. Install jq and retry."
# hubRoot: a scope may add {markers, allowedFilePaths}; see "Hub root" in README.md.
# Outside a subagent there is no agent_type and nothing to fence: skip the jq spawn (it runs on every read too).
case "$payload" in *'"agent_type"'*) ;; *) [ -n "$node" ] || allow ;; esac
nodes_text=""
if [ -n "$node" ]; then
  if [ -f "$node_file" ] && [ -r "$node_file" ]; then nodes_text="$(cat "$node_file" 2>/dev/null)" || nodes_text=""; fi
  [ -n "$nodes_text" ] || deny "BLOCKED: inside Archon node '$node' every call is fenced by .archon/copilot/node-fences.json, which is missing or empty, so the scope guard denies. Reinstall the kit (archon kit add)."
fi

# One jq spawn for everything (each spawn costs ~300ms on Windows). Fields joined by U+0001, list
# items by U+0002; trailing sentinel keeps "jq failed" distinguishable from "all empty".
if ! fields="$(printf '%s' "$payload" | jq -j --slurpfile pol "$policy" --rawfile loc "$local_policy" \
      --arg node "$node" --arg nf "$nodes_text" '
      # Why the projects agent-scopes.local.json is refused, or "" (no file, or a valid one); see the header.
      def wrapper: IN("env", "eval", "exec", "xargs", "sudo", "su", "doas", "command", "builtin", "nohup", "timeout",
        "time", "nice", "setsid", "script");
      def interpreter: IN("bash", "sh", "zsh", "dash", "ksh", "node", "deno", "bun", "npx", "python", "python3",
        "perl", "ruby", "php", "pwsh", "powershell");
      def entry_error($k):
        if type != "string" then "agents.\($k).commandAllowlist holds a value that is not a string"
        elif test("^\\s*$") then "agents.\($k).commandAllowlist holds an empty entry, which would allow every command"
        elif test("[;&|`$<>\n(){}]") then "agents.\($k).commandAllowlist entry \"\(.)\" holds a shell operator"
        else (sub("^\\s+"; "") | split(" ") | map(select(. != ""))) as $w
          | if ($w[0] | wrapper) or ($w[0] | startswith("-"))
              then "agents.\($k).commandAllowlist entry \"\(.)\" starts with \($w[0]), which runs any command"
            elif ($w[0] | interpreter) and (($w | length) == 1 or ($w[1] | startswith("-")))
              then "agents.\($k).commandAllowlist entry \"\(.)\" is a bare interpreter, which runs any code: name the script"
            else empty end
        end;
      def local_error:
        if $loc == "" then ""
        else (try ($loc | fromjson) catch "\u0000") as $l
          | if $l == "\u0000" then "it is not valid JSON"
            elif ($l | type) != "object" then "it is not a JSON object"
            elif ([$l | keys[] | select(. != "agents" and . != "_comment")] | length) > 0
              then "it may hold only \"agents\" (and \"_comment\"), not \"" + ([$l | keys[] | select(. != "agents" and . != "_comment")] | join("\", \"")) + "\""
            elif ($l.agents | type) != "object" then "\"agents\" must be an object"
            else [ $l.agents | to_entries[] | .key as $k | .value as $v
                | if $pol[0].agents[$k] == null
                    then "it adds the agent \"\($k)\", which agent-scopes.json does not fence: only a fenced agent can be given commands"
                  elif ($v | type) != "object" then "agents.\($k) must be an object"
                  elif ([$v | keys[] | select(. != "commandAllowlist")] | length) > 0
                    then "agents.\($k) may set only commandAllowlist, not \"" + ([$v | keys[] | select(. != "commandAllowlist")] | join("\", \"")) + "\": no other fence changes here"
                  elif ($v.commandAllowlist | type) != "array" then "agents.\($k).commandAllowlist must be a list of command prefixes"
                  else ($v.commandAllowlist[] | entry_error($k))
                  end ] | (.[0] // "")
            end
        end;
      # Why .archon/copilot/node-fences.json is refused, or "" (see the header).
      def dangerous_env: test("^(PATH|HOME|SHELL|IFS|ENV|BASH_ENV|CDPATH|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|TMPDIR|NODE_OPTIONS|NODE_PATH|PYTHONPATH|PYTHONSTARTUP|PYTHONHOME|PERL5OPT|PERL5LIB|RUBYOPT|RUBYLIB|JAVA_HOME|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|JAVA_OPTS|GRADLE_OPTS|GRADLE_USER_HOME|MAVEN_OPTS|WORKFLOW_ID)$")
        or test("^(LD_|DYLD_|GIT_|NPM_CONFIG_|KIT_|CLAUDE_|COPILOT_|ARCHON_|SCOPE_GUARD_|RUN_GUARD_|BACKLOG_|AFFECTED_CMD|SSH_|GH_|GITHUB_)");
      def node_entry_error($k; $v):
        if ($v | type) != "object" then "nodes.\($k) must be an object"
        elif ([$v | keys[] | select(IN("agent", "allowedFilePaths", "commandAllowlist", "env") | not)] | length) > 0
          then "nodes.\($k) may set only agent, allowedFilePaths, commandAllowlist and env, not \"" + ([$v | keys[] | select(IN("agent", "allowedFilePaths", "commandAllowlist", "env") | not)] | join("\", \"")) + "\""
        elif ($v.agent | type) != "string" or $pol[0].agents[$v.agent] == null
          then "nodes.\($k).agent must name an agent .claude/hooks/agent-scopes.json fences"
        elif ($v | has("commandAllowlist")) and ($v.commandAllowlist | type) != "array"
          then "nodes.\($k).commandAllowlist must be a list of command prefixes"
        elif ($v | has("allowedFilePaths")) and ($v.allowedFilePaths | type) != "array"
          then "nodes.\($k).allowedFilePaths must be a list of paths"
        elif ($v | has("env")) and ($v.env | type) != "array" then "nodes.\($k).env must be a list of variable names"
        else ([($v.commandAllowlist // [])[] | entry_error($k) | sub("^agents\\."; "nodes.")]
            + [($v.allowedFilePaths // [])[]
                | if type != "string" then "nodes.\($k).allowedFilePaths holds a value that is not a string"
                  elif . == "$RUN_ARTIFACTS/" then empty
                  elif test("^\\s*$") then "nodes.\($k).allowedFilePaths holds an empty entry"
                  elif test("^(/|~|[A-Za-z]:|\\\\)") or test("(^|/)\\.\\.(/|$)") or test("[$\\\\]")
                    then "nodes.\($k).allowedFilePaths entry \"\(.)\" is not a path inside the project (only $RUN_ARTIFACTS/ names a folder outside it)"
                  else empty end]
            + [($v.env // [])[]
                | if type != "string" or (test("^[A-Z][A-Z0-9_]*$") | not)
                    then "nodes.\($k).env entry \"\(.)\" is not an upper-case variable name"
                  elif dangerous_env then "nodes.\($k).env entry \"\(.)\" changes how a shell, an interpreter, git or this kit behaves"
                  else empty end]
          ) | (.[0] // "")
        end;
      def nodes_error:
        (try ($nf | fromjson) catch "\u0000") as $n
        | if $n == "\u0000" then "it is not valid JSON"
          elif ($n | type) != "object" then "it is not a JSON object"
          elif ([$n | keys[] | select(. != "nodes" and . != "_comment")] | length) > 0
            then "it may hold only \"nodes\" (and \"_comment\"), not \"" + ([$n | keys[] | select(. != "nodes" and . != "_comment")] | join("\", \"")) + "\""
          elif ($n.nodes | type) != "object" or ($n.nodes | length) == 0 then "\"nodes\" must be an object that names a node"
          else ([$n.nodes | to_entries[] | node_entry_error(.key; .value)] | .[0] // "") end;
      def common($lists): if ($lists | length) == 0 then []
        else reduce $lists[1:][] as $l ($lists[0] | unique; map(select(. as $x | any($l[]; . == $x)))) end;
      local_error as $lerr
      | (if $lerr == "" and $loc != "" then ($loc | fromjson | .agents) else {} end) as $adds
      # the fence of a node-fences.json entry: its agent, the project additions, then the node additions
      | def node_scope($v):
          ($pol[0].agents[$v.agent]) as $b
          | (if $adds[$v.agent] == null then $b
             else $b + {commandAllowlist: (($b.commandAllowlist // []) + $adds[$v.agent].commandAllowlist)} end) as $b2
          | $b2 + {commandAllowlist: (($b2.commandAllowlist // []) + ($v.commandAllowlist // [])), nodeEnv: ($v.env // [])}
            + (if ($b2 | has("allowedFilePaths")) then {allowedFilePaths: ($b2.allowedFilePaths + ($v.allowedFilePaths // []))}
               else {} end);
        (if $node == "" then "" else nodes_error end) as $nerr
      | (.agent_type // "") as $ag0
      | (if $ag0 == "" then null else $pol[0].agents[$ag0] end) as $own
      # Copilot only: a subagent of a fenced root session whose type has no policy entry (a built-in agent) is fenced
      # as that root agent (kit_root, from KIT_AGENT), so it cannot step outside the scope of that root.
      | (if $own == null and .kit_copilot == true and (.kit_root // "") != "" then .kit_root else $ag0 end) as $ag
      | (if $ag == "" then null else $pol[0].agents[$ag] end) as $s0
      # The project adds command prefixes; the kit list stays whole.
      | (if $s0 == null or $adds[$ag] == null then $s0
         else $s0 + {commandAllowlist: (($s0.commandAllowlist // []) + $adds[$ag].commandAllowlist)} end) as $s1
      # Inside a node: the node fence replaces the session agent; a subagent of another fenced type is checked by its
      # own fence too ($sub, by a second run of this guard outside node mode).
      | (if $node == "" or $nerr != "" then {s: $s1, ag: $ag, sub: ""}
         else ($nf | fromjson | .nodes) as $nodes
           | (if $ag0 != "" and $pol[0].agents[$ag0] != null then $ag0 else "" end) as $sub0
           | if $nodes[$node] != null then
               {s: node_scope($nodes[$node]), ag: "\($nodes[$node].agent) (node \($node))",
                sub: (if $sub0 != $nodes[$node].agent then $sub0 else "" end)}
             else
               ([$nodes[] | node_scope(.)]) as $all
               | {s: ({commandAllowlist: common([$all[] | .commandAllowlist]),
                       allowedFilePaths: common([$all[] | select(has("allowedFilePaths")) | .allowedFilePaths]),
                       nodeEnv: []}
                      + (if any($all[]; has("readPaths"))
                         then {readPaths: common([$all[] | select(has("readPaths")) | .readPaths])} else {} end)),
                  ag: "node \($node) (not in .archon/copilot/node-fences.json, so the strictest common set)", sub: $sub0}
             end end) as $nd
      | $nd.s as $s | $nd.ag as $ag
      | (.tool_input // {}) as $a
      | $ag + "\u0001" + (.tool_name // "") + "\u0001"
        + ($a.file_path // $a.notebook_path // $a.path // "") + "\u0001"
        + ($a.command // "") + "\u0001"
        + (.cwd // "") + "\u0001"
        + (if $s == null then "none" elif ($s | has("allowedFilePaths")) then "fenced" else "any" end) + "\u0001"
        + (if $s != null and ($s | has("readPaths")) then "readfenced" else "readany" end) + "\u0001"
        + (($s.readPaths // []) | join("\u0002")) + "\u0001"
        + (if .tool_name == "Glob" then ($a.pattern // "") else ($a.glob // "") end) + "\u0001"
        + (($s.allowedFilePaths // []) | join("\u0002")) + "\u0001"
        + (($s.commandAllowlist // []) | join("\u0002")) + "\u0001"
        + (($s.hubRoot.markers // []) | join("\u0002")) + "\u0001"
        + (($s.hubRoot.allowedFilePaths // []) | join("\u0002")) + "\u0001"
        + (if .kit_copilot == true then "copilot" else "" end) + "\u0001"
        + $lerr + "\u0001"
        + $nerr + "\u0001"
        + (($s.nodeEnv // []) | join("\u0002")) + "\u0001"
        + $nd.sub + "\u0001."' 2>/dev/null)"; then
  if ! command -v jq >/dev/null 2>&1; then       # no jq: fail CLOSED (PIN-17-0755), hand-built JSON
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is not on the PATH, so this guard cannot read the tool call and denies rather than failing open (PIN-17-0755). Install jq and retry."}}'
    decided=1; exit 0
  fi
  [ -z "$node" ] || deny "BLOCKED: inside Archon node '$node' every call is fenced, and the scope guard could not read this call or its fences (jq failed), so it denies."
  allow
fi

agent="${fields%%$'\001'*}";  fields="${fields#*$'\001'}"
tool="${fields%%$'\001'*}";   fields="${fields#*$'\001'}"
path="${fields%%$'\001'*}";   fields="${fields#*$'\001'}"
cmd="${fields%%$'\001'*}";    fields="${fields#*$'\001'}"
cwd="${fields%%$'\001'*}";    fields="${fields#*$'\001'}"
mode="${fields%%$'\001'*}";   fields="${fields#*$'\001'}"
rmode="${fields%%$'\001'*}";  fields="${fields#*$'\001'}"
rpaths="${fields%%$'\001'*}"; fields="${fields#*$'\001'}"
rglob="${fields%%$'\001'*}";  fields="${fields#*$'\001'}"
paths="${fields%%$'\001'*}";  fields="${fields#*$'\001'}"
cmds="${fields%%$'\001'*}";   fields="${fields#*$'\001'}"
hubm="${fields%%$'\001'*}";   fields="${fields#*$'\001'}"
hubp="${fields%%$'\001'*}";   fields="${fields#*$'\001'}"
origin="${fields%%$'\001'*}"; fields="${fields#*$'\001'}"
local_error="${fields%%$'\001'*}"; fields="${fields#*$'\001'}"
node_error="${fields%%$'\001'*}"; fields="${fields#*$'\001'}"
node_env="${fields%%$'\001'*}"; fields="${fields#*$'\001'}"
sub_agent="${fields%%$'\001'*}"

[ -z "$node_error" ] || deny "BLOCKED: .archon/copilot/node-fences.json is refused, so every call inside Archon node '$node' is denied until it is fixed: $node_error. A person fixes it; no agent may write it."
[ "$mode" = "none" ] && allow
armed=1
# A subagent of another fenced type inside a node: its own fence first (this guard outside node mode), then the node's.
if [ -n "$sub_agent" ]; then
  sub_out="$(printf '%s' "$payload" | KIT_NODE='' bash "$0" "${1:-PreToolUse}")"
  if [ -n "$sub_out" ]; then printf '%s\n' "$sub_out"; decided=1; exit 0; fi
fi
# Only tools no named kit.json entry checks (see the header): the named ones were checked there.
if [ "$other_tools" -eq 1 ]; then
  case "$tool" in Write|Edit|MultiEdit|NotebookEdit|Bash|Read|Grep|Glob) allow ;; esac
fi
[ -z "$local_error" ] || deny "BLOCKED: .claude/hooks/agent-scopes.local.json is refused, so every call of a fenced agent is denied until it is fixed: $local_error. It may only add command prefixes to the commandAllowlist of agents .claude/hooks/agent-scopes.json fences. A person fixes it; no agent may write it."

# ── Hub root (marker-based) ──────────────────────────────────────────────────────────────────────
# An agent whose scope carries `hubRoot` {markers, allowedFilePaths} may write inside any directory
# that holds every marker file (a "hub root", found by walking up from the target), at the
# hub-relative paths in hubRoot.allowedFilePaths. The rule is the markers, never a folder name.
find_hub() {  # find_hub <abs normalised path> — prints the nearest ancestor holding every marker
  local d="${1%/*}" nd m ok IFS
  while [ -n "$d" ]; do
    ok=1
    IFS=$'\002'
    set -f
    for m in $hubm; do [ -n "$m" ] && [ ! -f "$d/$m" ] && { ok=0; break; }; done
    set +f
    unset IFS
    if [ "$ok" -eq 1 ]; then printf '%s' "$d"; return 0; fi
    nd="${d%/*}"
    [ "$nd" = "$d" ] && break
    d="$nd"
  done
  return 1
}

hub_match() {  # hub_match <hub-relative path> — 0 when it matches hubRoot.allowedFilePaths
  local rel="$1" entry IFS
  IFS=$'\002'
  set -f
  for entry in $hubp; do
    [ -n "$entry" ] || continue
    case "$entry" in
      */) case "$rel" in "$entry"*) set +f; return 0 ;; esac ;;
      *)  # shellcheck disable=SC2053  # intentional glob match
          if [[ "$rel" == $entry ]]; then set +f; return 0; fi ;;
    esac
  done
  set +f
  return 1
}

# ── The run's own artifacts folder (node fences: $RUN_ARTIFACTS/) ───────────────────────────────────
run_artifacts_re() {  # prints the regex of <archon home>/workspaces/<owner>/<repo>/artifacts/runs/$WORKFLOW_ID/, or fails
  local wid="${WORKFLOW_ID:-}" home
  [[ $wid =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  home="${ARCHON_HOME:-${HOME:-}/.archon}"
  home="$(slashes "$home")"
  case "$home" in /*) ;; *) return 1 ;; esac
  # the home folder as a literal: every regex character escaped
  home="$(printf '%s' "$home" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  printf '^%s/workspaces/[^/]+/[^/]+/artifacts/runs/%s/' "$home" "$wid"
}
in_run_artifacts() {  # in_run_artifacts <path>: 0 for a file below the run's own artifacts folder (no '..', no '.' part)
  local p re
  p="$(slashes "$1")"
  case "/$p/" in */../*|*/./*) return 1 ;; esac
  re="$(run_artifacts_re)" || return 1
  [[ $p =~ $re.+ ]]
}
node_run_artifacts() {  # 0 when the fence holds $RUN_ARTIFACTS/
  case "$(printf '\002%s\002' "$paths")" in *$'\002$RUN_ARTIFACTS/\002'*) return 0 ;; esac
  return 1
}

# ── Write / Edit ─────────────────────────────────────────────────────────────────────────────────
check_path() {
  # The fences themselves are off limits to every fenced agent, also to one that may write anywhere.
  case "${path//\\//}" in
    *.claude/hooks/agent-scopes*.json) deny "BLOCKED: agent '$agent' may not change the agent fences ('$path')." ;;
    *.archon/copilot/node-fences.json|.archon/copilot/node-fences.json)
      deny "BLOCKED: agent '$agent' may not change the node fences ('$path')." ;;
  esac
  # Inside an Archon workflow node no agent changes a hook folder, in any case, also one that may write anywhere
  # (.archon/copilot/hooks/run-guard.sh refuses the shell writes into them). Reading them stays allowed.
  if [ -n "${node:-}" ] && [ -n "$path" ]; then
    local hp="/${path//\\//}/"
    while [ "$hp" != "${hp//\/\//\/}" ]; do hp="${hp//\/\//\/}"; done
    while [ "$hp" != "${hp//\/.\//\/}" ]; do hp="${hp//\/.\//\/}"; done
    shopt -s nocasematch
    case "$hp" in
      */.github/hooks/*|*/.archon/copilot/*|*/.claude/hooks/*|*/.archon/githooks/*|*/.githooks/*|*/.git/hooks/*)
        shopt -u nocasematch
        deny "BLOCKED: agent '$agent' in Archon node '$node' may not change a hook folder ('$path'): no node changes .github/hooks, .archon/copilot, .claude/hooks, .archon/githooks, .githooks or .git/hooks; reading them stays allowed, a person changes them." ;;
    esac
    shopt -u nocasematch
  fi
  [ "$mode" = "any" ] && allow
  [ -n "$path" ] || allow

  local p="${path//\\//}" root entry IFS
  while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done
  # Claude Code passes absolute paths: make them relative to the session cwd (a worktree, if the
  # agent runs in one), else to the project dir. Case-insensitive: Windows casing varies.
  shopt -s nocasematch
  for root in "$cwd" "${CLAUDE_PROJECT_DIR:-}"; do
    root="${root//\\//}"; root="${root%/}"
    [ -n "$root" ] || continue
    case "$p" in "$root"/*) p="${p:${#root}+1}"; break ;; esac
  done
  shopt -u nocasematch
  while [ "$p" != "${p//\/.\//\/}" ]; do p="${p//\/.\//\/}"; done
  p="${p#./}"

  if [ -n "$hubm" ]; then
    case "$p" in
      ../*|*/../*|*/..|..) deny "BLOCKED: agent '$agent' may not write via '..' paths ('$path')." ;;
    esac
    local ap="$p" hroot
    case "$ap" in /*|[A-Za-z]:/*) ;; *) [ -n "$cwd" ] && { hroot="${cwd//\\//}"; ap="${hroot%/}/${ap#./}"; } ;; esac
    case "$ap" in
      /*|[A-Za-z]:/*)
        if hroot="$(find_hub "$ap")"; then
          if hub_match "${ap:${#hroot}+1}"; then allow; fi
          deny "BLOCKED: agent '$agent' may only write inside a hub root (a directory holding $(printf '%s' "$hubm" | tr '\002' ' ')) under: $(printf '%s' "$hubp" | tr '\002' ' '). '${ap:${#hroot}+1}' is outside that fence ($policy_rel). Report it back to the orchestrator instead of widening your scope."
        fi ;;
    esac
  fi
  # Claude Code passes absolute paths: make them relative to the session cwd (a worktree, if the
  # agent runs in one), else to the project dir. Case-insensitive: Windows casing varies.
  shopt -s nocasematch
  for root in "$cwd" "${CLAUDE_PROJECT_DIR:-}"; do
    root="${root//\\//}"; root="${root%/}"
    [ -n "$root" ] || continue
    case "$p" in "$root"/*) p="${p:${#root}+1}"; break ;; esac
  done
  shopt -u nocasematch
  while [ "$p" != "${p//\/.\//\/}" ]; do p="${p//\/.\//\/}"; done
  p="${p#./}"

  # Inside a node whose fence holds $RUN_ARTIFACTS/: a file below the run's own artifacts folder.
  if [ -n "$node" ] && node_run_artifacts && in_run_artifacts "$path"; then allow; fi

  case "$p" in
    /*|[A-Za-z]:/*) deny "BLOCKED: agent '$agent' may only write inside its fence ($policy_rel), and '$path' is outside the project/worktree." ;;
    ../*|*/../*|..) deny "BLOCKED: agent '$agent' may not write via '..' paths ('$path')." ;;
  esac


  case "$p" in
    /*|[A-Za-z]:/*) deny "BLOCKED: agent '$agent' may only write inside its fence ($policy_rel), and '$path' is outside the project/worktree." ;;
    ../*|*/../*|..) deny "BLOCKED: agent '$agent' may not write via '..' paths ('$path')." ;;
  esac

  IFS=$'\002'
  set -f   # entries are globs, not file names: no pathname expansion when splitting
  for entry in $paths; do
    [ -n "$entry" ] || continue
    [ "$entry" != '$RUN_ARTIFACTS/' ] || continue   # a token, never a project path (above)
    case "$entry" in
      */) case "$p" in "$entry"*) allow ;; esac ;;
      *)  # shellcheck disable=SC2053  # intentional glob match
          if [[ "$p" == $entry ]]; then allow; fi ;;
    esac
  done
  set +f
  unset IFS
  if [ -n "$hubm" ]; then
    deny "BLOCKED: agent '$agent' may only write inside a hub root (a directory holding $(printf '%s' "$hubm" | tr '\002' ' ')), and '$p' is outside that fence ($policy_rel)."
  fi
  if [ -n "$node" ] && node_run_artifacts; then
    local shown; shown="$(printf '%s' "$paths" | tr '\002' ' ')"; shown="${shown//\$RUN_ARTIFACTS\//\$ARTIFACTS_DIR/ (the artifacts folder of this run)}"
    deny "BLOCKED: agent '$agent' may only write under: $shown. '$p' is outside that fence ($policy_rel, .archon/copilot/node-fences.json). Report it back instead of widening your scope."
  fi
  if [ -z "$paths" ]; then
    deny "BLOCKED: agent '$agent' is read-only (empty allowedFilePaths in $policy_rel) and may not write '$p'."
  fi
  deny "BLOCKED: agent '$agent' may only write under: $(printf '%s' "$paths" | tr '\002' ' '). '$p' is outside that fence ($policy_rel). Report it back to the orchestrator instead of widening your scope."
}

# ── Read / Grep / Glob ───────────────────────────────────────────────────────────────────────────
slashes() {  # slashes <path>: forward slashes, no doubles or trailing one, C:/x as /c/x (Windows and bash forms compare)
  local p="${1//\\//}" d
  while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done
  case "$p" in [A-Za-z]:/*|[A-Za-z]:) d="$(printf '%s' "${p:0:1}" | tr 'A-Z' 'a-z')"; p="/$d${p:2}" ;; esac
  [ "$p" = "/" ] || p="${p%/}"
  printf '%s' "$p"
}

check_read() {
  [ "$rmode" = "readfenced" ] || allow
  [ -n "$path" ] || deny "BLOCKED: agent '$agent' may only read under its readPaths ($policy_rel): name the path to search."
  case "${rglob//\\//}" in  # a Glob pattern or a Grep file filter must stay below the path it was given
    /*|[A-Za-z]:*|..|../*|*/..|*/../*) deny "BLOCKED: agent '$agent' may not leave the searched path with the pattern '$rglob'." ;;
  esac
  local p root entry home hit=0 IFS
  p="$(slashes "$path")"
  home="$(slashes "${HOME:-}")"
  shopt -s nocasematch
  for root in "$cwd" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$root" ] || continue
    root="$(slashes "$root")"
    if [ "$p" = "$root" ]; then p="."; break; fi
    case "$p" in "$root"/*) p="${p:${#root}+1}"; break ;; esac
  done
  while [ "$p" != "${p//\/.\//\/}" ]; do p="${p//\/.\//\/}"; done
  [ "$p" = "." ] || p="${p#./}"
  case "$p" in
    ../*|*/../*|..|*/..) shopt -u nocasematch; deny "BLOCKED: agent '$agent' may not read via '..' paths ('$path')." ;;
  esac
  IFS=$'\002'
  set -f
  for entry in $rpaths; do
    [ -n "$entry" ] || continue
    case "$entry" in "~/"*) [ -n "$home" ] || continue; entry="$home/${entry#"~/"}" ;; esac
    case "$entry" in
      # shellcheck disable=SC2053,SC2254  # entries are globs (`*` spans `/`), matched unquoted on purpose
      */) case "$p/" in $entry*) hit=1; break ;; esac ;;
      *)  if [[ "$p" == $entry ]]; then hit=1; break; fi ;;
    esac
  done
  set +f
  unset IFS
  shopt -u nocasematch
  [ "$hit" -eq 1 ] && allow
  deny "BLOCKED: agent '$agent' may only read under: $(printf '%s' "$rpaths" | tr '\002' ' '). '$path' is outside that fence ($policy_rel)."
}

# ── Bash ─────────────────────────────────────────────────────────────────────────────────────────
norm_cmd() {  # strip a leading interpreter and ./ so `bash ./scripts/x.sh` matches `scripts/x.sh`
  local s="$1"
  case "$s" in "bash "*|"sh "*) s="${s#* }"; s="${s#"${s%%[![:space:]]*}"}" ;; esac
  s="${s#./}"
  # `git --no-pager <cmd>` is `git <cmd>`: the flag only turns the pager off (owner, 2026-11-20)
  case "$s" in "git --no-pager "*) s="git ${s#git --no-pager }" ;; esac
  printf '%s' "$s"
}

# A read-only filter after a single pipe (owner, 2026-11-20): `| tail -15`, `| head -n 30`. Options only: no file
# operand (it would read a file outside the read fence), no -f/-F, no redirect, and never after || or alone.
pipe_filter() {  # pipe_filter <segment> — 0 for tail or head with only count options
  [[ $1 =~ ^(tail|head)([[:space:]]+(-[0-9]+|-[nc][[:space:]]*[+-]?[0-9]+|--(lines|bytes)=[+-]?[0-9]+))*[[:space:]]*$ ]]
}

seg_allowed() {  # seg_allowed <segment> — 0 when the segment starts with an allowlisted command
  local s entry e IFS name re
  s="$1"
  # Inside a node: NAME=value in front of the command, for a NAME of the node's env list (node-fences.json)
  re="^([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|[^[:space:]\"']*)[[:space:]]+(.*)$"
  while [ -n "$node_env" ] && [[ $s =~ $re ]]; do
    name="${BASH_REMATCH[1]}"
    case "$(printf '\002%s\002' "$node_env")" in *$'\002'"$name"$'\002'*) ;; *) return 1 ;; esac
    s="${BASH_REMATCH[3]}"
  done
  s="$(norm_cmd "$s")"
  [ -n "$s" ] || return 0
  case "$s" in cd|"cd "*) return 0 ;; esac
  IFS=$'\002'
  for entry in $cmds; do
    e="$(norm_cmd "$entry")"
    [ -n "$e" ] || continue
    if [ "$s" = "$e" ]; then return 0; fi
    case "$s" in "$e "*|"$e"$'\t'*) return 0 ;; esac
    # An entry ending in ':' (`./gradlew :`) is a raw prefix: `./gradlew :app:test` matches, `./gradlew test` does not.
    case "$e" in *:) case "$s" in "$e"[!\ $'\t']*) return 0 ;; esac ;; esac
  done
  return 1
}

check_cmd() {
  [ -n "$cmd" ] || allow
  [ -n "$cmds" ] || deny "BLOCKED: agent '$agent' has no commandAllowlist in $policy_rel, so it may not run shell commands."
  # The quote-aware pass below is quadratic in bash (about 5 s at 16 KB), and a hook that outlives its timeout fails
  # OPEN under Copilot CLI: a longer command is denied rather than read slowly.
  # The cap is deliberate, on both CLIs: the segment split below is quadratic in bash, and a hook that runs out of time
  # fails open on Claude Code as on Copilot, so a long enough command would otherwise pass unread.
  [ "${#cmd}" -le "${SCOPE_GUARD_MAX_CMD:-16384}" ] || deny "BLOCKED: agent '$agent' ran a ${#cmd}-character command; this guard reads at most ${SCOPE_GUARD_MAX_CMD:-16384}. Put long text in a file (git commit -F <file>, gh pr create --body-file <file>) and retry."

  # One pass that reads quotes as bash does (TASK-62): '…' is plain text; $'…' is text whose \ escapes the next
  # character; outside quotes and in "…" a \ escapes the next character, and $( or a backtick is command
  # substitution, which hides a second command inside an allowed one. Only the `$(cat <<…` heredoc used for commit
  # and PR bodies may substitute. Segments split on ; & | and newlines outside quotes; each is checked on its own.
  # Inside a node: `$(cat <file below the run's artifacts folder>)` (as in AFFECTED_BASE="$(cat "$ARTIFACTS_DIR/step-base.sha")")
  # reads a file of the run, so it is read as the plain word KIT_RUN_FILE; any other substitution is denied below.
  if [ -n "$node" ]; then
    local sub_re='[$][(]cat[[:space:]]+("?)(/[A-Za-z0-9._/-]+)("?)[[:space:]]*[)]' m
    while [[ $cmd =~ $sub_re ]]; do
      m="${BASH_REMATCH[0]}"
      [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ] && in_run_artifacts "${BASH_REMATCH[2]}" || break
      cmd="${cmd/"$m"/KIT_RUN_FILE}"
    done
  fi
  local i c q="" seg="" n=${#cmd} rd=0 po pp=0   # pp=1: this segment follows a single |
  i=0
  while [ "$i" -lt "$n" ]; do
    c="${cmd:$i:1}"
    po=$rd; rd=0   # po=1: the character before this one was a > or < outside quotes and not escaped
    case "$q" in
      "'") seg="$seg$c"; [ "$c" = "'" ] && q="" ;;
      "\$'")
        seg="$seg$c"
        if [ "$c" = "\\" ]; then i=$((i + 1)); seg="$seg${cmd:$i:1}"; elif [ "$c" = "'" ]; then q=""; fi ;;
      *)
        if [ "$c" = "\\" ]; then
          i=$((i + 1)); seg="$seg$c${cmd:$i:1}"
        elif [ "$c" = '`' ] || { [ "$c" = '$' ] && [ "${cmd:$((i + 1)):1}" = "(" ]; }; then
          [ "${cmd:$i:8}" = '$(cat <<' ] || deny "BLOCKED: agent '$agent' may not use command substitution (\$( ) or backticks) outside single quotes — it can hide a command outside the allowlist. Only \$(cat <<'EOF' … EOF) message heredocs are allowed."
          seg="$seg$c"
        elif [ "$q" = '"' ]; then
          seg="$seg$c"; [ "$c" = '"' ] && q=""
        else
          case "$c" in
            "'"|'"') q="$c"; seg="$seg$c" ;;
            '$') if [ "${cmd:$((i + 1)):1}" = "'" ]; then q="\$'"; i=$((i + 1)); seg="$seg\$'"; else seg="$seg$c"; fi ;;
            # `>&` and `<&` (2>&1, >&2) copy a file descriptor: the & starts no command, so it stays in the segment.
            '&') if [ "$po" -eq 1 ]; then seg="$seg$c"; else
                   seg="${seg#"${seg%%[![:space:]]*}"}"
                   { seg_allowed "$seg" || { [ "$pp" -eq 1 ] && pipe_filter "$seg"; }; } || deny "BLOCKED: agent '$agent' may not run '${seg%% *}…' — allowed commands: $(printf '%s' "$cmds" | tr '\002' ',' | sed 's/,/, /g') ($policy_rel)."
                   seg=""; pp=0; fi ;;
            # <( and >( run a command in a process substitution, which hides it like $( does.
            '(') [ "$po" -eq 1 ] && deny "BLOCKED: agent '$agent' may not use process substitution (<( or >( ) — it can hide a command outside the allowlist."
                 seg="$seg$c" ;;
            '>'|'<') rd=1; seg="$seg$c" ;;
            ';'|'|'|$'\n')
              seg="${seg#"${seg%%[![:space:]]*}"}"
              { seg_allowed "$seg" || { [ "$pp" -eq 1 ] && pipe_filter "$seg"; }; } || deny "BLOCKED: agent '$agent' may not run '${seg%% *}…' — allowed commands: $(printf '%s' "$cmds" | tr '\002' ',' | sed 's/,/, /g') ($policy_rel)."
              seg=""; pp=0
              # a single | (or |&) pipes into the next segment; || is one separator, after which nothing is piped
              if [ "$c" = '|' ]; then
                case "${cmd:$((i + 1)):1}" in '|') i=$((i + 1)) ;; '&') i=$((i + 1)); pp=1 ;; *) pp=1 ;; esac
              fi ;;
            *) seg="$seg$c" ;;
          esac
        fi ;;
    esac
    i=$((i + 1))
  done
  seg="${seg#"${seg%%[![:space:]]*}"}"
  { seg_allowed "$seg" || { [ "$pp" -eq 1 ] && pipe_filter "$seg"; }; } || deny "BLOCKED: agent '$agent' may not run '${seg%% *}…' — allowed commands: $(printf '%s' "$cmds" | tr '\002' ',' | sed 's/,/, /g') ($policy_rel)."
  allow
}

# Copilot only: a fenced agent may use only the tools this guard knows. A Copilot tool it cannot read (apply_patch,
# write_bash, a tool a newer CLI adds) is denied rather than let through; a Claude payload keeps `*) allow`.
copilot_tool_ok() {  # copilot_tool_ok <tool>: 0 for a harmless built-in or a tool of a configured MCP server
  case "$1" in
    Skill|Agent|Task|WebFetch|WebSearch|TodoWrite|task|read_bash|list_bash|stop_bash|report_intent|update_todo|\
    web_fetch|web_search|fetch_copilot_cli_documentation|ask_user|mcp__*) return 0 ;;
  esac
  local s f
  for f in "$CLAUDE_PROJECT_DIR/.github/mcp.json" "$CLAUDE_PROJECT_DIR/.mcp.json"; do
    [ -f "$f" ] || continue
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      case "$1" in "$s"/*|"$s"-*|"$s"__*) return 0 ;; esac
    done < <(jq -r '(.mcpServers // .servers // {}) | keys[]' "$f" 2>/dev/null)
  done
  return 1
}

case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit) check_path ;;
  Bash) check_cmd ;;
  Read|Grep|Glob) check_read ;;
  *) # A Claude payload: a tool name in another case (write, BASH) meets the check of its name, as every deny list
     # reads tool names in any case. A Copilot name in another case keeps the deny below: its arguments are not mapped.
     if [ "$origin" != copilot ]; then
       shopt -s nocasematch
       case "$tool" in
         write|edit|multiedit|notebookedit) shopt -u nocasematch; check_path ;;
         bash) shopt -u nocasematch; check_cmd ;;
         read|grep|glob) shopt -u nocasematch; check_read ;;
       esac
       shopt -u nocasematch
       allow
     fi
     copilot_tool_ok "$tool" || deny "BLOCKED: agent '$agent' may not use the Copilot tool '$tool': the scope guard cannot read what it does, so it denies it for a fenced agent. Use bash, view, create or edit; a new name for one of those belongs in .archon/copilot/tools.json."
     allow ;;
esac
allow
