#!/usr/bin/env bash
# Tests for .claude/scripts/archon-suites.sh against a throwaway repo: which .archon suites a change selects.
# Usage: bash scripts/test/archon-suites.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/archon-suites.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
r=$root/repo
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false

# caller.sh calls callee.sh; retro and retro-fence are two scripts; flow reads every workflow; guard reads the hooks.
mkdir -p "$r/.archon/scripts/test" "$r/.archon/workflows" "$r/.claude/hooks/scripts"
s=$r/.archon/scripts t=$r/.archon/scripts/test
echo 'bash "$(dirname "$0")/callee.sh"' > "$s/caller.sh"
echo 'echo callee' > "$s/callee.sh"
echo 'console.log(1)' > "$s/retro.js"
echo 'echo fence' > "$s/retro-fence.sh"
echo 'echo alone' > "$s/alone.sh"
echo 'run: bash .archon/scripts/caller.sh' > "$r/.archon/workflows/w.yaml"
echo 'bash .claude/hooks/scripts/scope.sh' > "$r/.claude/hooks/scripts/guard.sh"
echo '{}' > "$r/.claude/hooks/policy.json"
echo 'echo scope; cat policy.json' > "$r/.claude/hooks/scripts/scope.sh"
echo 'bash .archon/scripts/caller.sh' > "$t/caller.test.sh"
echo 'node .archon/scripts/retro.js' > "$t/retro.test.sh"
echo 'bash .archon/scripts/retro-fence.sh' > "$t/retro-fence.test.sh"
echo 'for w in "$repo"/.archon/workflows/*.yaml; do :; done' > "$t/flow.test.sh"
echo 'bash .claude/hooks/scripts/guard.sh' > "$t/guard.test.sh"
echo 'helper() { :; }' > "$t/lib.sh"
git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm init
sha=$(git -C "$r" rev-parse HEAD)

sel() { printf '%s\n' "$@" | bash "$script" "$r" "$sha" | sed 's#^\.archon/scripts/test/##; s#\.test\.sh$##' | tr '\n' ' '; }
check() { # check <name> <got> <want>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: got '$2', want '$3'"; fi
}

check "a script runs its own suite" "$(sel .archon/scripts/caller.sh)" "caller "
check "a script it calls runs it too" "$(sel .archon/scripts/callee.sh)" "caller "
check "a name inside a longer file name does not count" "$(sel .archon/scripts/retro.js)" "retro "
check "a script no suite reaches selects none" "$(sel .archon/scripts/alone.sh)" ""
check "a workflow runs the suite that reads the workflow folder" "$(sel .archon/workflows/w.yaml)" "flow "
check "a hook config reaches the suite through the hook that reads it" "$(sel .claude/hooks/policy.json)" "guard "
check "a hook script called by another one" "$(sel .claude/hooks/scripts/scope.sh)" "guard "
check "a changed suite runs itself" "$(sel .archon/scripts/test/retro-fence.test.sh)" "retro-fence "
check "several changes, one list" "$(sel .archon/scripts/retro.js .archon/scripts/callee.sh)" "caller retro "
check "a deleted suite is not listed" "$(sel .archon/scripts/test/gone.test.sh)" ""
check "the CI workflow runs every suite" "$(sel .github/workflows/ci.yml)" "all "
check ".gitignore runs every suite" "$(sel .gitignore)" "all "
check "a shared file of the suites runs every suite" "$(sel .archon/scripts/test/lib.sh)" "all "
check "the selector itself runs every suite" "$(sel .claude/scripts/archon-suites.sh)" "all "
check "CRLF input is read" "$(printf '.archon/scripts/retro.js\r\n' | bash "$script" "$r" "$sha" | sed 's#.*/##')" "retro.test.sh"

echo "archon-suites tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
