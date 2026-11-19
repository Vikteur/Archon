#!/usr/bin/env bash
# The audit hook (.claude/hooks/scripts/audit-log.sh) records the skills a subagent's frontmatter preloads: one
# SKILL_PRELOAD record per `skills:` entry at its subagentStart, right after AGENT_START, flagged found:false when the
# checkout has no such skill. skill-check.js reads them (skill-check.test.sh covers that side).
# Usage: bash .archon/scripts/test/audit-preload.test.sh   (AUDIT_HOOK=<path> tests another copy of the hook)
set -uo pipefail

top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
hook="${AUDIT_HOOK:-$top/.claude/hooks/scripts/audit-log.sh}"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}
command -v jq >/dev/null 2>&1 || { echo "audit-preload: jq is required"; exit 1; }

tree="$root/tree"
mkdir -p "$tree/.claude/hooks" "$tree/.claude/agents" "$tree/.claude/skills/tdd-loop" "$tree/.claude/skills/jvm-testing" \
  "$tree/.claude/skills/clean-code"
for s in tdd-loop jvm-testing clean-code; do echo "# $s" > "$tree/.claude/skills/$s/SKILL.md"; done
git -C "$tree" init -q
agent_file() { # agent_file <name> <frontmatter lines...>
  local name=$1; shift
  { echo '---'; echo "name: $name"; printf '%s\n' "$@"; echo '---'; echo 'skills: [in-the-body]'; } \
    > "$tree/.claude/agents/$name.md"
}
start() { # start <agent type> — one subagentStart event, as the CLI sends it
  (cd "$tree/.claude/hooks" && env -u CLAUDE_AUDIT_ROLE -u CLAUDE_AUDIT_SESSION bash "$hook" subagentStart \
    <<< "{\"session_id\":\"s\",\"agent_type\":\"$1\",\"agent_transcript_path\":\"t\"}" > /dev/null 2>&1)
}
log="$tree/.apm-audit/sessions/s.jsonl"
preloads() { # preloads <agent name> — "<skill> <found>" per SKILL_PRELOAD record of that agent, in order
  jq -r --arg a "$1" 'select(.type == "SKILL_PRELOAD" and .agentName == $a) | "\(.skill) \(.found)"' "$log" 2>/dev/null | tr -d '\r'
}

agent_file test-writer 'tools:' '  - Skill' 'skills:' '  - tdd-loop' '  - "jvm-testing"' "  - 'tdd-lop'" 'model: sonnet'
start test-writer
[ "$(preloads test-writer)" = $'tdd-loop true\njvm-testing true\ntdd-lop false' ]; check "block list: one record per skill, in order, quotes stripped" $?
[ "$(jq -r 'select(.agentName == "test-writer") | .type' "$log" | head -1)" = AGENT_START ]; check "AGENT_START comes first" $?
jq -e 'select(.type == "SKILL_PRELOAD") | (.loggedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and .agent == "test-writer" and .event == "subagentStart"' \
  "$log" > /dev/null; check "a record carries loggedAt, agent and event" $?
! preloads test-writer | grep -q in-the-body; check "only the frontmatter is read" $?

printf -- '---\r\nname: developer\r\nskills: [ clean-code , "hexagonal-usecase" ]\r\n---\r\n' > "$tree/.claude/agents/developer.md"
start developer
[ "$(preloads developer)" = $'clean-code true\nhexagonal-usecase false' ]; check "inline list, CRLF: trimmed, a missing skill is found:false" $?

agent_file reviewer 'model: sonnet'
start reviewer
[ -z "$(preloads reviewer)" ]; check "no skills: no record" $?
[ "$(jq -r 'select(.agentName == "reviewer") | .type' "$log")" = AGENT_START ]; check "no skills: AGENT_START still written" $?

start general-purpose
[ -z "$(preloads general-purpose)" ]; check "no agent file: no record" $?
start '../agents/test-writer'
[ -z "$(jq -r 'select(.type == "SKILL_PRELOAD" and (.agentName | contains("/"))) | .skill' "$log")" ]; check "a path in the agent name reads no file" $?

agent_file plugin 'skills:' '  - engineering:code-review' '  - clean-code' 'tools: [Read]'
start plugin
[ "$(preloads plugin)" = $'engineering:code-review false\nclean-code true' ]; check "a namespaced skill is kept whole and the list ends at the next key" $?

[ "$(wc -l < "$log")" -eq "$(jq -c . "$log" | wc -l)" ]; check "every line is one JSON record" $?

echo "audit-preload: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
