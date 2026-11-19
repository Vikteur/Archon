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
#   Bash         every command segment (split on ; && || | & and newlines, outside quotes) must
#                start with an entry of the agent's `commandAllowlist`. `cd` is always allowed.
#                Command substitution outside single quotes is denied except the `$(cat <<'EOF' … )`
#                heredoc form used for commit/PR messages. Quotes and \ escapes are read as bash
#                reads them, so single-quoted text is free and an escaped quote opens no string.
#
# Who is fenced: the `agent_type` field Claude Code puts on every event fired inside a subagent (or a
# session started with `--agent`). No agent_type, or an agent with no entry → not this hook's
# business (exit 0, no output — normal permission flow applies).
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
# A local policy may narrow the fences: agent-scopes.local.json (gitignored) wins while it exists. Its one writer,
# agent-feature's test-ban.sh, was removed 2026-10-20 (owner decision D19); developer-fence.test.sh keeps it tested.
policy_rel=".claude/hooks/agent-scopes.json"
if [ -z "${CLAUDE_SCOPE_POLICY:-}" ] && [ -f "$here/../agent-scopes.local.json" ]; then
  policy="$here/../agent-scopes.local.json"; policy_rel=".claude/hooks/agent-scopes.local.json"
fi

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
  exit 0
}

[ -f "$policy" ] || allow
payload="$(cat 2>/dev/null || true)"
payload="$(hook_normalize_payload "$payload")"
# hubRoot: a scope may add {markers, allowedFilePaths}; see "Hub root" in README.md.
# Outside a subagent there is no agent_type and nothing to fence: skip the jq spawn (it runs on every read too).
case "$payload" in *'"agent_type"'*) ;; *) allow ;; esac

# One jq spawn for everything (each spawn costs ~300ms on Windows). Fields joined by U+0001, list
# items by U+0002; trailing sentinel keeps "jq failed" distinguishable from "all empty".
if ! fields="$(printf '%s' "$payload" | jq -j --slurpfile pol "$policy" '
      (.agent_type // "") as $ag
      | (if $ag == "" then null else $pol[0].agents[$ag] end) as $s
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
        + (($s.hubRoot.allowedFilePaths // []) | join("\u0002")) + "\u0001."' 2>/dev/null)"; then
  if ! command -v jq >/dev/null 2>&1; then       # no jq: fail CLOSED (PIN-17-0755), hand-built JSON
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is not on the PATH, so this guard cannot read the tool call and denies rather than failing open (PIN-17-0755). Install jq and retry."}}'
    decided=1; exit 0
  fi
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
hubp="${fields%%$'\001'*}"

[ "$mode" = "none" ] && allow
armed=1

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

# ── Write / Edit ─────────────────────────────────────────────────────────────────────────────────
check_path() {
  # The fences themselves are off limits to every fenced agent, also to one that may write anywhere.
  case "${path//\\//}" in
    *.claude/hooks/agent-scopes*.json) deny "BLOCKED: agent '$agent' may not change the agent fences ('$path')." ;;
  esac
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
  printf '%s' "$s"
}

seg_allowed() {  # seg_allowed <segment> — 0 when the segment starts with an allowlisted command
  local s entry e IFS
  s="$(norm_cmd "$1")"
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

  # One pass that reads quotes as bash does (TASK-62): '…' is plain text; $'…' is text whose \ escapes the next
  # character; outside quotes and in "…" a \ escapes the next character, and $( or a backtick is command
  # substitution, which hides a second command inside an allowed one. Only the `$(cat <<…` heredoc used for commit
  # and PR bodies may substitute. Segments split on ; & | and newlines outside quotes; each is checked on its own.
  local i c q="" seg="" n=${#cmd}
  i=0
  while [ "$i" -lt "$n" ]; do
    c="${cmd:$i:1}"
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
            ';'|'&'|'|'|$'\n')
              seg="${seg#"${seg%%[![:space:]]*}"}"
              seg_allowed "$seg" || deny "BLOCKED: agent '$agent' may not run '${seg%% *}…' — allowed commands: $(printf '%s' "$cmds" | tr '\002' ',' | sed 's/,/, /g') ($policy_rel)."
              seg="" ;;
            *) seg="$seg$c" ;;
          esac
        fi ;;
    esac
    i=$((i + 1))
  done
  seg="${seg#"${seg%%[![:space:]]*}"}"
  seg_allowed "$seg" || deny "BLOCKED: agent '$agent' may not run '${seg%% *}…' — allowed commands: $(printf '%s' "$cmds" | tr '\002' ',' | sed 's/,/, /g') ($policy_rel)."
  allow
}

case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit) check_path ;;
  Bash) check_cmd ;;
  Read|Grep|Glob) check_read ;;
  *) allow ;;
esac
allow
