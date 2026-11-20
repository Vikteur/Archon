#!/usr/bin/env bash
# Tests .claude/hooks/scripts/audit-log.sh, the hook that writes the TOOL records of .apm-audit/sessions/<id>.jsonl.
#
# Regression for the audit-trail gap of run 100ec772 (docs/memory.md 2026-10-18): no record was lost, but a TOOL record
# could not say which file a call wrote. esc() strips control characters, so a heredoc's lines are glued into one; the
# arg is cut at 200 bytes, so a long Windows worktree path loses its file name; and a NotebookEdit falls through to the
# whole tool input as text. The cut can also split a UTF-8 character.
#
# Two kinds of check:
#   check   what the hook does today and must keep doing: one TOOL record per call, valid JSON, tool, ok and loggedAt
#           set, no tool result stored, at most 200 bytes of each command line (the fix must not log more payload).
#   expect  what the fix must give: line breaks kept as \n, a path argument kept whole, an argCut flag when a line was
#           cut, the cut on a character boundary, a NotebookEdit logged by its path. The hook lives under
#           .claude/hooks/, which only a human may edit (guard-generated.sh rule 1), so until that edit lands an
#           expect that fails is reported as PENDING and does not fail the suite. AUDIT_LOG_STRICT=1 makes every
#           expect a check, to prove a patched hook: AUDIT_LOG_SCRIPT=<patched copy> AUDIT_LOG_STRICT=1 bash ...
# Usage: bash scripts/test/audit-log-args.test.sh   (exit 0 = every check passes). Needs jq and node.
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="${AUDIT_LOG_SCRIPT:-$repo_root/.claude/hooks/scripts/audit-log.sh}"
strict="${AUDIT_LOG_STRICT:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0; failed=0; pending=0; holds=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_AUDIT_ROLE CLAUDE_AUDIT_TICKET CLAUDE_AUDIT_PROMPTS COPILOT_AUDIT_ROLE COPILOT_AUDIT_TICKET 2>/dev/null
unset KIT_NODE ARCHON_NODE_EXECUTION 2>/dev/null  # section 8 sets them per call

check() { # check <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then passed=$((passed + 1)); echo "ok   - $name"
  else failed=$((failed + 1)); echo "FAIL - $name"; printf '%s\n' "${rec:-}" | sed 's/^/       | /'; fi
}
expect() { # expect <name> <command...>: a check once the hook fix lands, PENDING until then
  local name="$1"; shift
  if [ -n "$strict" ]; then check "$name" "$@"; return; fi
  if "$@" >/dev/null 2>&1; then holds=$((holds + 1)); echo "ok   - $name (expect: holds, make it a check)"
  else pending=$((pending + 1)); echo "PENDING - $name (needs the hook fix)"; fi
}

command -v jq >/dev/null 2>&1 || { echo "audit-log: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "audit-log: node is required"; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/.claude/hooks"
git init -q "$repo"
log="$repo/.apm-audit/sessions/s1.jsonl"
calls=0

# fire <event> <tool> <tool_input json>: run the hook as the CLI does (cwd .claude/hooks, payload on stdin); rec is
# the record it appended.
fire() {
  local before=0
  [ -f "$log" ] && before=$(wc -l < "$log")
  jq -cn --arg t "$2" --argjson i "$3" \
    '{session_id: "s1", hook_event_name: "PostToolUse", cwd: ".", tool_name: $t, tool_input: $i,
      tool_response: {stdout: "RESULT-MARKER the tool output is never stored"}}' \
    | (cd "$repo/.claude/hooks" && bash "$hook" "$1") >/dev/null 2>&1
  calls=$((calls + 1))
  rec="$(tail -n +"$((before + 1))" "$log" 2>/dev/null)"
}
arg() { printf '%s' "$rec" | jq -r 'select(.type == "TOOL") | .arg'; }
field() { printf '%s' "$rec" | jq -r --arg k "$1" 'select(.type == "TOOL") | .[$k] | tostring'; }
utf8_ok() { node -e 'new TextDecoder("utf-8", {fatal: true}).decode(require("fs").readFileSync(process.argv[1]))' "$1"; }
max_line_bytes() { arg | LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }

# 1. A heredoc that writes a file: the record names the target on its own line.
fire postToolUse Bash "$(jq -cn '{command: "mkdir -p src\ncat > src/GuestMother.java <<'"'"'EOF'"'"'\nclass GuestMother {}\nEOF"}')"
check "1 one TOOL record" test "$(printf '%s\n' "$rec" | jq -r .type | grep -c '^TOOL$')" -eq 1
check "1 tool, ok, loggedAt" test "$(field tool) $(field ok) $(field loggedAt | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" = "Bash true 1"
check "1 the tool result is not stored" bash -c '! grep -q RESULT-MARKER "$1"' _ "$log"
expect "1 line breaks kept: the heredoc target is its own line" test "$(arg | grep -cxF "cat > src/GuestMother.java <<'EOF'")" -eq 1
check "1 nothing cut, no argCut" test "$(field argCut)" != true

# 2. A Write with a long Windows worktree path: the record keeps the file name.
long='C:\Users\Pascal\.archon\workspaces\example-org\example-app\worktrees\archon\task-100ec772-print-billing-documents\planning-domain\src\testFixtures\java\app\example\planning\domain\billing\BillingDocumentViewMother.java'
fire postToolUse Write "$(jq -cn --arg p "$long" '{file_path: $p, content: "class BillingDocumentViewMother {}"}')"
check "2 path is over 200 bytes" test "${#long}" -gt 200
check "2 the file content is not stored" bash -c '! grep -q "class BillingDocumentViewMother" "$1"' _ "$log"
expect "2 path kept whole" test "$(arg)" = "$long"
check "2 no argCut" test "$(field argCut)" != true

# 3. A command line over 200 bytes: still cut at 200 bytes a line (no more payload than before), and flagged.
wide="echo $(printf 'x%.0s' $(seq 1 300))"
fire postToolUse Bash "$(jq -cn --arg c "$wide" '{command: ($c + "\necho done")}')"
check "3 no more payload than before: at most 200 bytes a command line" test "$(arg | LC_ALL=C wc -c)" -le 402
expect "3 no line over 200 bytes" test "$(max_line_bytes)" -le 200
expect "3 argCut true" test "$(field argCut)" = true
expect "3 the uncut line kept" test "$(arg | tail -n 1)" = "echo done"

# 4. CRLF and a multibyte character across the 200-byte cut: valid JSON and valid UTF-8, no carriage return.
pad="$(printf 'a%.0s' $(seq 1 199))"
fire postToolUse Bash "$(jq -cn --arg c "echo ${pad:5}é漢字 end" '{command: ($c + "\r\necho ok\r\n")}')"
check "4 valid JSON" jq -e . "$log"
expect "4 valid UTF-8 after the cut" utf8_ok "$log"
check "4 no carriage return in arg" bash -c '! printf "%s" "$1" | grep -q $'"'"'\r'"'"'' _ "$(arg)"
expect "4 second line kept" test "$(arg | tail -n 1)" = "echo ok"

# 5. A NotebookEdit is logged by its path, not by its cell source.
fire postToolUse NotebookEdit "$(jq -cn '{notebook_path: "docs/n.ipynb", new_source: "SOURCE-MARKER print(1)"}')"
expect "5 notebook path is the arg" test "$(arg)" = "docs/n.ipynb"
expect "5 cell source not stored" bash -c '! grep -q SOURCE-MARKER "$1"' _ "$log"

# 6. A failed call: ok false.
fire postToolUseFailure Edit '{"file_path":"src/A.java","old_string":"a","new_string":"b"}'
check "6 ok false on failure" test "$(field ok)" = false
check "6 the edit strings are not stored" bash -c '! grep -q "old_string" "$1"' _ "$log"

# 7. No call is dropped: one TOOL record per call, every line valid JSON.
check "7 one TOOL record per call" test "$(jq -r 'select(.type == "TOOL") | .type' "$log" | wc -l | tr -d ' ')" -eq "$calls"
check "7 every line is JSON" test "$(jq -c . "$log" | wc -l | tr -d ' ')" -eq "$(wc -l < "$log" | tr -d ' ')"

# 8. Inside an Archon workflow node the record names the node: KIT_NODE, else the last segment of the path in
# ARCHON_NODE_EXECUTION; outside a node the record is as before ("main", no node key).
nx='{"runId":"r1","path":"implement.build-step","invocation":1,"attempt":1}'
ARCHON_NODE_EXECUTION="$nx" fire postToolUse Bash '{"command":"git status"}'
check "8 ARCHON_NODE_EXECUTION alone: agent is the node" test "$(field agent)" = build-step
check "8 ARCHON_NODE_EXECUTION alone: node field" test "$(field node)" = build-step
KIT_NODE=review ARCHON_NODE_EXECUTION="$nx" fire postToolUse Bash '{"command":"git status"}'
check "8 KIT_NODE wins over ARCHON_NODE_EXECUTION" test "$(field agent) $(field node)" = "review review"
KIT_NODE='?' ARCHON_NODE_EXECUTION='{"path":"plan"}' fire postToolUse Read '{"file_path":"a"}'
check "8 KIT_NODE ? falls back to the node path" test "$(field node)" = plan
CLAUDE_AUDIT_ROLE=developer ARCHON_NODE_EXECUTION="$nx" fire postToolUse Bash '{"command":"ls"}'
check "8 a launcher role keeps the agent, the node is its own field" test "$(field agent) $(field node)" = "developer build-step"
ARCHON_NODE_EXECUTION='{"path":"implement.bad node"}' fire postToolUse Bash '{"command":"ls"}'
check "8 a node name that is not a plain word is no node" test "$(field agent) $(field node)" = "main null"
KIT_NODE='a"b' fire postToolUse Bash '{"command":"ls"}'
check "8 a KIT_NODE that is not a plain word is no node" test "$(field agent) $(field node)" = "main null"
fire postToolUse Bash '{"command":"ls"}'
check "8 outside a node: agent main" test "$(field agent)" = main
check "8 outside a node: no node key" bash -c 'printf "%s" "$1" | jq -e "select(.type == \"TOOL\") | has(\"node\") | not"' _ "$rec"
check "8 every line is still JSON" test "$(jq -c . "$log" | wc -l | tr -d ' ')" -eq "$(wc -l < "$log" | tr -d ' ')"

echo "audit-log: $passed passed, $failed failed, $pending pending the hook fix, $holds expect(s) already holding"
[ "$failed" -eq 0 ]
