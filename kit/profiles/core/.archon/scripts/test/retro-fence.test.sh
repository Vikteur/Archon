#!/usr/bin/env bash
# scope-guard.sh + agent-scopes.json: the retro agent reviews the workflow process only. It reads the workflow, its
# handoff files and the run artifacts, never source or test code, and runs no test or build command.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$root" || exit 2
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }
sg=.claude/hooks/scripts/scope-guard.sh
decision() { local o; o="$(cat)"; [ -n "$o" ] || { echo none; return; }; printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; }
sg_tool() { # sg_tool <agent> <tool> <tool_input json>
  jq -cn --arg a "$1" --arg t "$2" --argjson i "$3" --arg r "$root" '{agent_type:$a,tool_name:$t,cwd:$r,tool_input:$i}' \
    | CLAUDE_PROJECT_DIR="$root" CLAUDE_SCOPE_POLICY="$root/.claude/hooks/agent-scopes.json" bash "$sg" PreToolUse
}
read_() { sg_tool "$1" Read "$(jq -cn --arg p "$2" '{file_path:$p}')" | decision; }
grep_() { sg_tool "$1" Grep "$(jq -cn --arg p "$2" --arg g "${3:-}" '{pattern:"x"} + (if $p == "" then {} else {path:$p} end) + (if $g == "" then {} else {glob:$g} end)')" | decision; }
glob_() { sg_tool "$1" Glob "$(jq -cn --arg p "$2" --arg g "$3" '{pattern:$g} + (if $p == "" then {} else {path:$p} end)')" | decision; }
cmd_()  { sg_tool "$1" Bash "$(jq -cn --arg c "$2" '{command:$c}')" | decision; }
case_() { # case_ <label> <want> <decision>
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "decision=$3, want $2"; fi
}
home_win="$(cygpath -w "$HOME" 2>/dev/null || printf '%s' "$HOME")"

# Reads it may make: the workflow, the handoff and docs files, the run artifacts and logs.
case_ "retro reads the workflow" none "$(read_ retro "$root/.archon/workflows/build-feature-copilot.yaml")"
case_ "retro reads a docs leaf (relative path)" none "$(read_ retro docs/memory.md)"
case_ "retro reads the ticket" none "$(read_ retro "$root/backlog/tasks/task-1.md")"
case_ "retro reads a run's plan.md in the artifacts" none \
  "$(read_ retro "$HOME/.archon/workspaces/example-org/example-app/artifacts/runs/abc/plan.md")"
case_ "retro reads the artifacts by their Windows path" none \
  "$(read_ retro "$home_win\\.archon\\workspaces\\example-org\\example-app\\artifacts\\runs\\abc\\review\\round-1\\r.md")"
case_ "retro reads an Archon log" none "$(read_ retro "$HOME/.archon/logs/detached-run-1.log")"
case_ "retro greps the artifacts of a run" none \
  "$(grep_ retro "$HOME/.archon/workspaces/example-org/example-app/artifacts/runs/abc")"
case_ "retro globs the handoff files under docs" none "$(glob_ retro docs '**/*.md')"

# Code it may not read.
case_ "retro may not read main code" deny "$(read_ retro "$root/src/main/java/app/A.java")"
case_ "retro may not read test code" deny "$(read_ retro src/test/java/app/ATest.java)"
case_ "retro may not read the build file" deny "$(read_ retro "$root/pom.xml")"
case_ "retro may not read a run worktree's code" deny \
  "$(read_ retro "$HOME/.archon/workspaces/example-org/example-app/worktrees/x/src/main/java/A.java")"
case_ "retro may not read code via .." deny "$(read_ retro "docs/../src/main/java/A.java")"
case_ "retro may not grep without a path (the whole repo)" deny "$(grep_ retro '')"
case_ "retro may not grep the repo root" deny "$(grep_ retro "$root")"
case_ "retro may not grep src" deny "$(grep_ retro "$root/src")"
case_ "retro may not leave docs with a Grep file filter" deny "$(grep_ retro docs '../src/**')"
case_ "retro may not glob without a path" deny "$(glob_ retro '' '**/*.java')"
case_ "retro may not leave docs with a Glob pattern" deny "$(glob_ retro docs '../src/**/*.java')"
case_ "retro may not glob an absolute pattern" deny "$(glob_ retro docs "$root/src/**")"

# Commands: process evidence only, no tests, no build, no diffs.
case_ "retro may list commits" none "$(cmd_ retro 'git log --oneline main..HEAD')"
case_ "retro may read a CI run" none "$(cmd_ retro 'gh run view 123 --log-failed')"
case_ "retro may read the node timeline" none "$(cmd_ retro 'archon workflow get abc --verbose')"
case_ "retro may not run the tests" deny "$(cmd_ retro './mvnw test')"
case_ "retro may not run gradle" deny "$(cmd_ retro './gradlew check')"
case_ "retro may not show a commit's code" deny "$(cmd_ retro 'git show HEAD')"
case_ "retro may not diff code" deny "$(cmd_ retro 'git diff main')"
case_ "retro may not cat a source file" deny "$(cmd_ retro 'cat src/main/java/A.java')"
case_ "retro writes only under docs/retro" deny \
  "$(sg_tool retro Write "$(jq -cn --arg p "$root/docs/memory.md" '{file_path:$p}')" | decision)"

# Agents without readPaths, and the main session, read as before.
case_ "the developer still reads code" none "$(read_ developer "$root/src/main/java/A.java")"
case_ "the main session still greps anything" none \
  "$(jq -cn '{tool_name:"Grep",tool_input:{pattern:"x"}}' | CLAUDE_PROJECT_DIR="$root" bash "$sg" PreToolUse | decision)"

echo "retro-fence: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
