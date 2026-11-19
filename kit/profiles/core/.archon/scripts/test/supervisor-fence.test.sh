#!/usr/bin/env bash
# Tests that every command the delegator supervisor can run is one of the shapes in .archon/scripts/supervisor-jobs.sh,
# with its arguments checked, and that each shape passes the scope guard as the delegator (owner decision 2026-10-20,
# D15; ROADMAP R20, T15: "every supervisor command passes scope-guard as the delegator"). Part 3 checks the repo's own
# agent-scopes.json; point SUPERVISOR_FENCE_POLICY at another policy file to check that one instead.
# Usage: bash .archon/scripts/test/supervisor-fence.test.sh   (exit 0 = all pass)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
jobs=$repo/.archon/scripts/supervisor-jobs.sh
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code> [<detail>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "${3:-}" ] && sed 's/^/    /' <<< "$3"; fi
}
RUN=bbbbbbbb00000000000000000000000b
PR=https://github.com/o/repo/pull/7
samples() { # one sample command per job
  bash "$jobs" cmd merge "$PR"; bash "$jobs" cmd hold "$PR" "an owner question is open"
  bash "$jobs" cmd recover "$RUN"; bash "$jobs" cmd recover-dry "$RUN"; bash "$jobs" cmd launch TASK-7.2
  bash "$jobs" cmd cleanup; bash "$jobs" cmd ping act merge-held-7 "PR #7 waits for you"
}
guard_says() { # guard_says <guard dir> <command> [<policy file>]: "allowed" or the deny reason
  local o
  o=$(jq -cn --arg c "$2" '{agent_type: "delegator", tool_name: "Bash", tool_input: {command: $c}}' \
    | (cd "$repo" && if [ -n "${3:-}" ]; then CLAUDE_SCOPE_POLICY=$3 bash "$1/scope-guard.sh"; else bash "$1/scope-guard.sh"; fi) 2>/dev/null)
  if [ -z "$o" ]; then echo allowed; else jq -r '.hookSpecificOutput.permissionDecisionReason // "denied"' <<< "$o"; fi
}

# 1. supervisor-jobs.sh: every kind listed, every argument checked, free text quoted.
check "1 list names the 7 jobs" $([ "$(bash "$jobs" list | cut -f1 | tr '\n' ' ')" = "merge hold recover recover-dry launch cleanup ping " ]; echo $?) "$(bash "$jobs" list)"
check "1 each job builds its command" $([ "$(samples | wc -l)" = 7 ]; echo $?) "$(samples)"
bad() { # bad <name> <args...>: exit 2, nothing on stdout
  local o rc; o=$(bash "$jobs" cmd "${@:2}" 2>/dev/null); rc=$?
  check "1 refused: $1" $([ "$rc" -eq 2 ] && [ -z "$o" ]; echo $?) "rc=$rc $o"
}
bad "merge with a shell tail" merge "$PR; rm -rf ~"
bad "merge of a run id" merge "$RUN"
bad "hold without a reason" hold "$PR"
bad "hold with a two-line reason" hold "$PR" $'one\ntwo'
bad "recover of a pr url" recover "$PR"
bad "recover with a tail" recover "$RUN && rm -rf ~"
bad "launch of no TASK id" launch 'TASK-1"; rm -rf ~; "'
bad "cleanup with an argument" cleanup extra
bad "ping at an unknown level" ping urgent k s
bad "ping with a key holding a space" ping act "a b" s
bad "ping with a subject over 300 characters" ping act k "$(printf 'a%.0s' $(seq 1 301))"
bad "an unknown job" deploy x
c=$(bash "$jobs" cmd ping act k "\$(touch $root/pwned) \`touch $root/pwned2\`; touch $root/pwned3")
mkdir -p "$root/run/.archon/scripts"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/args"\n' "$root" > "$root/run/.archon/scripts/notify-owner.sh"
(cd "$root/run" && bash -c "$c")
check "1 a ping subject is never evaluated" $([ ! -e "$root/pwned" ] && [ ! -e "$root/pwned2" ] && [ ! -e "$root/pwned3" ] && [ "$(wc -l < "$root/args")" = 3 ]; echo $?) "$c"
c=$(bash "$jobs" cmd hold "$PR" "\$(touch $root/pwned4)")
printf '#!/usr/bin/env bash\nexit 0\n' > "$root/run/.archon/scripts/merge-ready.sh"; (cd "$root/run" && bash -c "$c")
check "1 a hold reason is never evaluated" $([ ! -e "$root/pwned4" ]; echo $?) "$c"

# 2. The real scope guard with a policy of exactly the delegator entries the jobs need: every job is allowed, and
# taking one entry out denies exactly its jobs.
G=$root/guard; mkdir -p "$G"; cp "$repo/.claude/hooks/scripts/scope-guard.sh" "$G/"
NEED='["bash .archon/scripts/merge-ready.sh","bash .archon/scripts/recover-run.sh","bash .archon/scripts/sync-main.sh",
 "bash .archon/scripts/launch-run.sh","bash .archon/scripts/cleanup-merged.sh","bash .archon/scripts/notify-owner.sh"]'
pol() { jq -n --argjson a "$1" '{agents: {delegator: {allowedFilePaths: [], commandAllowlist: $a}}}' > "$G/policy.json"; }
pol "$NEED"
while IFS= read -r c; do
  check "2 allowed with the needed entries: ${c:0:70}" $([ "$(guard_says "$G" "$c" "$G/policy.json")" = allowed ]; echo $?) "$(guard_says "$G" "$c" "$G/policy.json")"
done < <(samples)
pol "$(jq -c 'map(select(. != "bash .archon/scripts/merge-ready.sh"))' <<< "$NEED")"
check "2 without merge-ready.sh the merge is denied" $([ "$(guard_says "$G" "$(bash "$jobs" cmd merge "$PR")" "$G/policy.json")" != allowed ]; echo $?)
check "2 without merge-ready.sh the hold is denied" $([ "$(guard_says "$G" "$(bash "$jobs" cmd hold "$PR" r)" "$G/policy.json")" != allowed ]; echo $?)
check "2 without merge-ready.sh a ping is still allowed" $([ "$(guard_says "$G" "$(bash "$jobs" cmd ping act k s)" "$G/policy.json")" = allowed ]; echo $?)
pol "$(jq -c 'map(select(. != "bash .archon/scripts/launch-run.sh"))' <<< "$NEED")"
check "2 without launch-run.sh the launch is denied (both halves of && are fenced)" \
  $([ "$(guard_says "$G" "$(bash "$jobs" cmd launch TASK-1)" "$G/policy.json")" != allowed ]; echo $?)

# 3. The policy in this repo (or SUPERVISOR_FENCE_POLICY) allows every job for the delegator.
P=${SUPERVISOR_FENCE_POLICY:-}
while IFS= read -r c; do
  r=$(guard_says "$repo/.claude/hooks/scripts" "$c" "$P")
  check "3 the delegator's policy${P:+ ($P)} allows: ${c:0:70}" $([ "$r" = allowed ]; echo $?) "$r"
done < <(samples)

# 4. The tick and the judge build their commands only through supervisor-jobs.sh: no job command is written out in
# their code (comments aside).
for f in supervisor-tick.sh supervisor-judge.sh; do
  hits=$(grep -nE 'bash \.archon/scripts/(merge-ready|cleanup-merged|notify-owner|sync-main|recover-run)\.sh [^-]|archon workflow run' "$repo/.archon/scripts/$f" | grep -vE '^[0-9]+:\s*#')
  check "4 $f writes no job command itself" $([ -z "$hits" ]; echo $?) "$hits"
done
check "4 the tick fences every command before it acts" $(grep -q 'fz=$(fence "$3")' "$repo/.archon/scripts/supervisor-tick.sh" \
  && grep -q 'jf=$(fence "$jcmd")' "$repo/.archon/scripts/supervisor-tick.sh"; echo $?)

echo "supervisor-fence: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
