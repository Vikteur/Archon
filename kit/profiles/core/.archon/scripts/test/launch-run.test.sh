#!/usr/bin/env bash
# Tests for .archon/scripts/run-label.js and .archon/scripts/launch-run.sh: the short label cut from a ticket title,
# and the build-feature request a launch starts with, against stubbed backlog and archon CLIs.
# Usage: bash .archon/scripts/test/launch-run.test.sh   (exit 0 = all pass)
set -uo pipefail
# The scripts' defaults, not the checkout's .archon/kit.yaml (an install's build_workflow differs).
export KIT_CONFIG=/dev/null
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code> [<detail>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "${3:-}" ] && sed 's/^/    /' <<< "$3"; fi
}
label() { node "$here/run-label.js" --title "$1"; }
is() { # is <title> <expected label>
  local got; got=$(label "$1")
  check "label of \"$1\" is \"$2\"" $([ "$got" = "$2" ]; echo $?) "got: $got"
}

# 1. The label: two or three words of the title, without tags, articles, possessives and what follows a linking word.
is "[P1] Create a order with its partners, team, song lists and couple project link" "create order"
is "[P1] Sign in with e-mail address and password" "sign in"
is "[P1] Change my password and sign out every other device" "change password"
is "[P1] Switch a member's access off and end all their sessions" "switch member access"
is "[P0] Epic: Contract pinning, code generation and CI" "contract pinning"
is "P0-E02-T04a Harden the breaking-change gate" "harden breaking-change gate"
is "[P2] Link a DJ member to a DJ vendor" "link DJ member"
is "Archon workflow fixes from the TASK-3.2 and TASK-5.1 retros" "archon workflow fixes"
is "Rename \"x\"; rm -rf ~ \`id\` \$(id)" "rename x"
is "[P1]" ""

# 2. The request: the bare id when Backlog cannot read the ticket; the label after it when it can.
mkdir -p "$root/bin"
cat > "$root/bin/backlog" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_BACKLOG_FAIL:-}" ] && exit 1
printf 'File: /x/task-7.4.md\n\nTask %s - [P1] Sign in with e-mail address and password\n=====\n' "$3"
STUB
cat > "$root/bin/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGS"
echo "Workflow run started: 0123abcd"
STUB
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" ARGS="$root/args"
check "a readable ticket gives <id>: <label>" $([ "$(node "$here/run-label.js" TASK-7.4)" = "TASK-7.4: sign in" ]; echo $?)
check "an unreadable ticket gives the bare request" $([ "$(STUB_BACKLOG_FAIL=1 node "$here/run-label.js" TASK-7.4)" = "TASK-7.4" ]; echo $?)
node "$here/run-label.js" 'TASK-1; id' >/dev/null 2>&1; check "run-label refuses what is not a TASK id (exit 2)" $([ $? -eq 2 ]; echo $?)

# 3. The launch: one detached build-feature run with that request as one argument; archon's output passes through.
out=$(bash "$here/launch-run.sh" TASK-7.4); rc=$?
check "launch-run exits with archon's code" "$rc"
check "launch-run starts build-feature detached with the labelled request" \
  $([ "$(cat "$ARGS")" = "$(printf 'workflow\nrun\nbuild-feature\n--detach\nTASK-7.4: sign in')" ]; echo $?) "$(cat "$ARGS")"
check "launch-run prints archon's output" $([ "$out" = "Workflow run started: 0123abcd" ]; echo $?) "$out"
rm -f "$ARGS"; bash "$here/launch-run.sh" 'TASK-1"; id; "' >/dev/null 2>&1; rc=$?
check "launch-run refuses what is not a TASK id, starting nothing" $([ $rc -eq 2 ] && [ ! -e "$ARGS" ]; echo $?)
BUILD_WORKFLOW=build-feature-copilot bash "$here/launch-run.sh" TASK-7.4 >/dev/null 2>&1
check "launch-run starts the workflow named by BUILD_WORKFLOW" $([ "$(sed -n 3p "$ARGS")" = build-feature-copilot ]; echo $?) "$(cat "$ARGS")"

echo "launch-run.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
