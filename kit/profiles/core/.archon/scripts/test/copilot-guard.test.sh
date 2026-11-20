#!/usr/bin/env bash
# Tests for .archon/copilot/hooks/run-guard.sh (the Copilot-only PreToolUse guard) and its registration file
# .github/hooks/archon-run-guard.json: JSON samples in both field spellings (Claude: tool_name/tool_input.command,
# Copilot: toolName/toolArgs, and the batched toolCalls form) are fed to the guard from a real temp main checkout and a real run worktree under a
# /.archon/workspaces/ path. Inside a run the safety subset is refused (exit 2 + permissionDecision deny), ordinary
# commands pass; outside a run everything passes.
# Usage: bash .archon/scripts/test/copilot-guard.test.sh   (exit 0 = all pass)
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
guard="$repo/.archon/copilot/hooks/run-guard.sh"
pass=0; fail=0; out=""; rc=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi; }

main="$root/checkout"; run="$root/.archon/workspaces/o/r/worktrees/build-feature-1"
git init -q -b main "$main" && git -C "$main" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
mkdir -p "$(dirname "$run")" && git -C "$main" worktree add -q "$run" -b build-feature-1

feed() { # feed <cwd> <json>: runs the guard from <cwd>
  out=$(cd "$1" && printf '%s' "$2" | bash "$guard" 2>&1); rc=$?
}
claude() { jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' 2>/dev/null \
  || node -e 'console.log(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' "$1" "$2"; }
copilot() { node -e 'console.log(JSON.stringify({toolName:"bash",toolArgs:JSON.stringify({command:process.argv[1]}),workingDirectory:process.argv[2]}))' "$1" "$2"; }
denied()  { feed "$run" "$($1 "$2" "$run")"; [ "$rc" -eq 2 ] && grep -q '"permissionDecision":"deny"' <<< "$out"; }
allowed() { feed "$run" "$($1 "$2" "$run")"; [ "$rc" -eq 0 ] && [ -z "$out" ]; }

deny_cases=(
  'git commit --no-verify -m x'
  'git commit -m x --no-verify'
  'git commit -n -m x'
  'git commit -an -m x'
  'git push origin main'
  'git push origin HEAD:main'
  'git push origin :main'
  'git push origin HEAD:refs/heads/main'
  'git push --force-with-lease origin +main'
  'git add . && git push origin HEAD:main'
  "cd $main && git status"
  "cd $main; ls"
  "git -C $main status"
  'backlog task edit 12 -s Done'
)
for c in "${deny_cases[@]}"; do
  for who in claude copilot; do
    denied "$who" "$c"; check "deny ($who): $c" $?
  done
done
allow_cases=(
  'git push origin HEAD:refs/heads/feature-x'
  'git push -u origin build-feature-1'
  'git push'
  'git commit -m x'
  'git commit -am "fix main page"'
  'git status'
  "cd $run && ls"
  "git -C $run status"
  'git log origin/main..HEAD'
  'BACKLOG_CWD=/x backlog task view 12 --plain'
  'bash .github/skills/gh-git-ops/scripts/push.sh'
)
for c in "${allow_cases[@]}"; do
  for who in claude copilot; do
    allowed "$who" "$c"; check "allow in a run ($who): $c" $?
  done
done

# a tool that is not a shell is never judged
feed "$run" "$(node -e 'console.log(JSON.stringify({tool_name:"Read",tool_input:{file_path:"/x/--no-verify"},cwd:process.argv[1]}))' "$run")"
check "a Read of a path with --no-verify passes" "$([ "$rc" -eq 0 ]; echo $?)"

# the native Copilot preToolUse input: {timestamp, cwd, toolName, toolArgs (a JSON string)}; deny JSON on stdout
native=$(node -e 'console.log(JSON.stringify({timestamp:1700000000000,cwd:process.argv[1],toolName:"bash",toolArgs:JSON.stringify({command:"git push origin main"})}))' "$run")
out=$(cd "$run" && printf '%s' "$native" | bash "$guard" 2>/dev/null); rc=$?
check "native preToolUse input is denied with permissionDecision deny on stdout" "$([ "$rc" -eq 2 ] && node -e 'const o=JSON.parse(process.argv[1]);process.exit(o.permissionDecision==="deny"&&o.permissionDecisionReason?0:1)' "$out"; echo $?)" "$out"
native=$(node -e 'console.log(JSON.stringify({timestamp:1,cwd:process.argv[1],toolName:"view",toolArgs:"{\"path\":\"/x\"}"}))' "$run")
feed "$run" "$native"; check "native non-shell tool passes" "$([ "$rc" -eq 0 ]; echo $?)"

# the batched preToolUse input Copilot CLI 1.0.114 sends: exactly {cwd, sessionId, toolCalls: [{id, name, args}]}, args
# an object; one payload can hold several calls. Every call is judged; one refused call refuses the batch.
batch() { # batch <cwd> <command>...: one bash call per command, then a skill call
  node -e 'const [cwd,...cmds]=process.argv.slice(1);console.log(JSON.stringify({sessionId:"s",cwd,toolCalls:[...cmds.map((c,i)=>({id:"t"+i,name:"bash",args:{command:c,description:"d"}})),{id:"tk",name:"skill",args:{skill:"clean-code"}}]}))' "$@"; }
feed "$run" "$(batch "$run" 'git status' 'git push origin main')"
check "batch: a refused second call refuses the batch" "$([ "$rc" -eq 2 ] && grep -q 'git push to main' <<< "$out"; echo $?)"
feed "$run" "$(batch "$run" 'git commit --no-verify -m x' 'git status')"
check "batch: a refused first call refuses the batch" "$([ "$rc" -eq 2 ]; echo $?)"
feed "$run" "$(batch "$run" 'git status' 'git log -1')"
check "batch: ordinary calls pass" "$([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)"
feed "$run" "$(node -e 'console.log(JSON.stringify({sessionId:"s",cwd:process.argv[1],toolCalls:[]}))' "$run")"
check "batch: an empty toolCalls array passes" "$([ "$rc" -eq 0 ]; echo $?)"
feed "$run" "$(node -e 'console.log(JSON.stringify({sessionId:"s",cwd:process.argv[1],toolCalls:[{id:"a",name:"bash",args:{}}]}))' "$run")"
check "batch: a shell call without a command is refused" "$([ "$rc" -eq 2 ]; echo $?)"
feed "$main" "$(batch "$main" 'git push origin main')"
check "batch: outside a run it passes" "$([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)"

# the deny reason names the guard on stderr and has the Copilot JSON shape
feed "$run" "$(claude 'git push origin main' "$run")"
check "deny reason on stderr" "$(grep -q 'run-guard.sh: git push to main' <<< "$out"; echo $?)"
check "deny JSON has hookSpecificOutput too" "$(grep -q '"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"' <<< "$out"; echo $?)"

# unreadable input: a deny inside a run, an allow outside
feed "$run" 'not json'; check "garbage input inside a run is denied" "$([ "$rc" -eq 2 ]; echo $?)"
feed "$run" "$(node -e 'console.log(JSON.stringify({tool_name:"Bash",tool_input:{},cwd:process.argv[1]}))' "$run")"
check "a shell call without a command inside a run is denied" "$([ "$rc" -eq 2 ]; echo $?)"
# the session folder comes from the payload, not only from where the hook runs
feed "$main" "$(claude 'git push origin main' "$run")"; check "payload cwd inside a run is judged" "$([ "$rc" -eq 2 ]; echo $?)"

# outside a run (the owner's own chat in the main checkout): everything passes
for c in "${deny_cases[@]}"; do
  feed "$main" "$(claude "$c" "$main")"
  check "outside a run allowed: $c" "$([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)"
done
feed "$main" 'not json'; check "garbage input outside a run is allowed" "$([ "$rc" -eq 0 ]; echo $?)"
feed "$main" "$(copilot 'git push origin main' "$main")"; check "Copilot spelling outside a run is allowed" "$([ "$rc" -eq 0 ]; echo $?)"

# the main checkout is derived, never hard-coded: a different main path is protected the same way
main2="$root/other main"; run2="$root/.archon/worktrees/x/w2"
git init -q -b main "$main2" && git -C "$main2" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
mkdir -p "$(dirname "$run2")" && git -C "$main2" worktree add -q "$run2" -b w2
feed "$run2" "$(claude "git -C \"$main2\" status" "$run2")"; check "derived main checkout (path with a space, /.archon/worktrees/)" "$([ "$rc" -eq 2 ]; echo $?)"
feed "$run2" "$(claude "git -C $main status" "$run2")"; check "another repo's path is not the main checkout" "$([ "$rc" -eq 0 ]; echo $?)"
RUN_GUARD_PROTECTED=release feed "$run" "$(claude 'git push origin HEAD:release' "$run")"; check "RUN_GUARD_PROTECTED adds a branch" "$([ "$rc" -eq 2 ]; echo $?)"

# .archon/copilot/deny.json (Claude-style patterns): enforced in every session, run worktree or not
mkdir -p "$main/.archon/copilot"
printf '%s' '["Bash(*--no-verify*)","Bash(git push:*)","Read(./.env)","Edit(**/secrets/*)","WebFetch"]' > "$main/.archon/copilot/deny.json"
dfeed() { out=$(cd "$main" && printf '%s' "$1" | CLAUDE_PROJECT_DIR="$main" bash "$guard" 2>&1); rc=$?; }
dfeed "$(claude 'git commit --no-verify -m x' "$main")"; check "deny.json: Bash pattern denies outside a run (Claude)" "$([ "$rc" -eq 2 ] && grep -q 'deny.json' <<< "$out"; echo $?)"
dfeed "$(copilot 'git commit --no-verify -m x' "$main")"; check "deny.json: Bash pattern denies outside a run (Copilot)" "$([ "$rc" -eq 2 ]; echo $?)"
dfeed "$(claude 'git push origin feat' "$main")"; check "deny.json: prefix pattern git push:*" "$([ "$rc" -eq 2 ]; echo $?)"
dfeed "$(claude 'git status' "$main")"; check "deny.json: an ordinary command passes" "$([ "$rc" -eq 0 ] && [ -z "$out" ]; echo $?)"
dfeed "$(node -e 'console.log(JSON.stringify({toolName:"view",toolArgs:JSON.stringify({path:"/p/.env"}),cwd:process.argv[1]}))' "$main")"
check "deny.json: Read(./.env) matches a Copilot view of .env" "$([ "$rc" -eq 0 ]; echo $?)"
dfeed "$(node -e 'console.log(JSON.stringify({toolName:"view",toolArgs:JSON.stringify({path:".env"}),cwd:process.argv[1]}))' "$main")"
check "deny.json: Read(./.env) denies a Copilot view of .env" "$([ "$rc" -eq 2 ]; echo $?)"
dfeed "$(node -e 'console.log(JSON.stringify({tool_name:"Edit",tool_input:{file_path:"a/secrets/k"},cwd:process.argv[1]}))' "$main")"
check "deny.json: Edit glob denies" "$([ "$rc" -eq 2 ]; echo $?)"
dfeed "$(node -e 'console.log(JSON.stringify({tool_name:"WebFetch",tool_input:{url:"x"},cwd:process.argv[1]}))' "$main")"
check "deny.json: a bare tool name denies every call" "$([ "$rc" -eq 2 ]; echo $?)"
dfeed "$(node -e 'console.log(JSON.stringify({sessionId:"s",cwd:process.argv[1],toolCalls:[{id:"a",name:"view",args:{path:"src/A.java"}},{id:"b",name:"view",args:{path:".env"}}]}))' "$main")"
check "deny.json: a batch with one denied view of .env is denied" "$([ "$rc" -eq 2 ]; echo $?)"
dfeed 'not json'; check "deny.json: unreadable input outside a run still allows" "$([ "$rc" -eq 0 ]; echo $?)"
printf 'not json' > "$main/.archon/copilot/deny.json"; dfeed "$(claude 'git push origin x' "$main")"; check "deny.json: an unreadable list denies nothing" "$([ "$rc" -eq 0 ]; echo $?)"
printf '%s' '["Bash(*--no-verify*)"]' > "$main/.archon/copilot/deny.json"
feed "$run" "$(claude 'git push origin main' "$run")"; check "deny.json present: the run rules still apply" "$([ "$rc" -eq 2 ]; echo $?)"
rm -f "$main/.archon/copilot/deny.json"

# the registration file: Copilot-native shape (version 1, preToolUse, bash command, timeoutSec), runs the guard
reg="$repo/.github/hooks/archon-run-guard.json"
check "registration is native Copilot JSON: version 1, one preToolUse command hook for run-guard.sh, timeoutSec, no matcher" "$(node -e 'const h=JSON.parse(require("fs").readFileSync(process.argv[1]));const a=h.hooks.preToolUse;const c=a&&a[0];process.exit(h.version===1&&Object.keys(h.hooks).join()==="preToolUse"&&a.length===1&&c.type==="command"&&c.bash.includes(".archon/copilot/hooks/run-guard.sh")&&typeof c.timeoutSec==="number"&&!("matcher"in c)?0:1)' "$reg"; echo $?)"
check "guard script parses" "$(bash -n "$guard"; echo $?)"

echo "copilot-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
