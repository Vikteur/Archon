#!/usr/bin/env bash
# Tests .github/hooks/dispatch.sh, the bridge that runs a Claude Code hook script under the GitHub Copilot CLI
# (.github/hooks/kit.json calls it once per hook): it normalizes a Copilot payload (toolName/toolArgs) to the Claude
# shape with payload.sh, skips the hook when the anchored Claude matcher misses the tool, turns a Claude deny (exit 2
# with the reason on stderr, or hookSpecificOutput.permissionDecision) into Copilot's top-level permissionDecision on
# PreToolUse, is a no-op for a missing script, passes the script's stderr through and always exits 0. One tool call per
# payload. Each case runs a probe hook in a throwaway project that holds this checkout's dispatch.sh and payload.sh.
# Usage: bash .archon/scripts/test/dispatch.test.sh   (exit 0 = all pass; needs jq)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }
expect() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "got $3, want $2"; fi; }
command -v jq >/dev/null 2>&1 || { echo "dispatch: needs jq"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
proj="$tmp/proj"; mkdir -p "$proj/.github/hooks" "$proj/.claude/hooks/scripts" "$proj/.archon/copilot"
cp "$root/.github/hooks/dispatch.sh" "$proj/.github/hooks/"
cp "$root/.claude/hooks/scripts/payload.sh" "$proj/.claude/hooks/scripts/"
cp "$root/.archon/copilot/tools.json" "$proj/.archon/copilot/"   # the tool map payload.sh reads (view's path -> file_path)
# The probe hook: writes what it got (its args and its stdin) to $PROBE_LOG, then acts as $PROBE says.
cat > "$proj/.claude/hooks/scripts/probe.sh" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
printf '%s\n' "args=$*" "$in" > "$PROBE_LOG"
case "${PROBE:-}" in
  deny2)  echo "probe: not this file" >&2; exit 2 ;;
  deny2q) echo 'probe: say "no"' >&2; exit 2 ;;
  claude) echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"probe says no"}}' ;;
  advice) echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"use the MCP tool"}}' ;;
  noisy)  echo "probe: a note on stderr" >&2 ;;
  crash)  echo "probe: broke" >&2; exit 1 ;;
esac
exit 0
EOF
export PROBE_LOG="$tmp/probe.log"
dispatch() { # dispatch <event> <matcher> <script> [args...] < payload → stdout; rc in $tmp/rc; stderr in $tmp/err
  rm -f "$PROBE_LOG"
  ( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash .github/hooks/dispatch.sh "$@" 2>"$tmp/err" ); echo $? > "$tmp/rc"
}
ran() { [ -f "$PROBE_LOG" ] && echo yes || echo no; }
copilot_bash='{"toolName":"bash","toolArgs":"{\"command\":\"ls docs\"}","sessionId":"s1"}'
copilot_view='{"toolName":"view","toolArgs":{"path":"docs/memory.md"}}'
probe=.claude/hooks/scripts/probe.sh

# 1. The matcher (anchored regex over the normalized tool name).
dispatch PreToolUse 'Read|Grep|Glob' "$probe" <<< "$copilot_bash" >/dev/null
expect "a Copilot bash call skips a Read|Grep|Glob hook" no "$(ran)"
out="$(dispatch PreToolUse 'Bash' "$probe" PreToolUse extra <<< "$copilot_bash")"
expect "a Copilot bash call runs a Bash hook" yes "$(ran)"
expect "... and the hook gets the Claude shape: tool_name Bash, the command from the toolArgs string" "Bash|ls docs|s1" \
  "$(sed -n 2p "$PROBE_LOG" | jq -r '[.tool_name, .tool_input.command, .session_id] | join("|")')"
expect "... and its arguments" "args=PreToolUse extra" "$(sed -n 1p "$PROBE_LOG")"
expect "... and a hook that decides nothing prints nothing" "" "$out"
dispatch PreToolUse 'Read' "$probe" <<< "$copilot_view" >/dev/null
expect "a Copilot view call is Read, its path is file_path" "Read|docs/memory.md" \
  "$(sed -n 2p "$PROBE_LOG" | jq -r '[.tool_name, .tool_input.file_path] | join("|")')"
dispatch PreToolUse 'Bas' "$probe" <<< "$copilot_bash" >/dev/null
expect "the matcher is anchored: Bas does not match Bash" no "$(ran)"
dispatch PreToolUse '*' "$probe" <<< "$copilot_view" >/dev/null
expect "matcher * runs on every tool" yes "$(ran)"
dispatch SessionStart '' "$probe" <<< '{"sessionId":"s1"}' >/dev/null
expect "an empty matcher runs on every payload" yes "$(ran)"
dispatch PreToolUse 'Bash' "$probe" <<< '{"tool_name":"Bash","tool_input":{"command":"ls"}}' >/dev/null
expect "a Claude payload matches as it is" yes "$(ran)"

# 2. A missing script, too few arguments.
out="$(dispatch PreToolUse 'Bash' .claude/hooks/scripts/gone.sh <<< "$copilot_bash")"
expect "a missing script is a no-op: nothing printed" "" "$out"
expect "... and exit 0" 0 "$(cat "$tmp/rc")"
out="$(dispatch PreToolUse 'Bash' <<< "$copilot_bash")"
expect "too few arguments: nothing printed, exit 0" "|0" "$out|$(cat "$tmp/rc")"

# 3. Deny on PreToolUse, in both shapes.
out="$(PROBE=deny2 dispatch PreToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "exit 2 is a deny at Copilot's top level, with stderr as the reason" "deny|probe: not this file" \
  "$(printf '%s' "$out" | jq -r '[.permissionDecision, (.permissionDecisionReason | sub(" +$"; ""))] | join("|")')"
expect "... and in Claude's hookSpecificOutput" deny "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
expect "... and dispatch.sh still exits 0" 0 "$(cat "$tmp/rc")"
expect "... and the reason also passes through on stderr" yes "$(grep -qF 'probe: not this file' "$tmp/err" && echo yes || echo no)"
out="$(PROBE=deny2q dispatch PreToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "a reason with quotes stays one JSON object" 'probe: say "no"' \
  "$(printf '%s' "$out" | jq -r '.permissionDecisionReason | sub(" +$"; "")')"
out="$(PROBE=claude dispatch PreToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "a Claude hookSpecificOutput deny gets Copilot's top-level fields" "deny|probe says no|deny" \
  "$(printf '%s' "$out" | jq -r '[.permissionDecision, .permissionDecisionReason, .hookSpecificOutput.permissionDecision] | join("|")')"
out="$(PROBE=advice dispatch PreToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "advice without a decision passes as it is" 'use the MCP tool|null' \
  "$(printf '%s' "$out" | jq -r '[.hookSpecificOutput.additionalContext, (.permissionDecision // "null")] | join("|")')"
out="$(PROBE=deny2 dispatch PostToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "exit 2 outside PreToolUse is no deny" "" "$out"

# 4. stderr and exit codes.
out="$(PROBE=noisy dispatch PreToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "the script's stderr passes through" yes "$(grep -qF 'probe: a note on stderr' "$tmp/err" && echo yes || echo no)"
expect "... and stdout stays empty" "" "$out"
out="$(PROBE=crash dispatch PreToolUse 'Bash' "$probe" <<< "$copilot_bash")"
expect "a crashing hook is no deny and dispatch.sh exits 0" "|0" "$out|$(cat "$tmp/rc")"

echo "dispatch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
