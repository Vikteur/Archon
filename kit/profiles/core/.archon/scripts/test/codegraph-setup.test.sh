#!/usr/bin/env bash
# Tests for .archon/scripts/codegraph-setup.sh on a throwaway checkout: with a stand-in codegraph that logs its calls,
# and once with the real one when it is on PATH.
# Usage: bash .archon/scripts/test/codegraph-setup.test.sh   (exit 0 = all pass)
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$repo/.archon/scripts/codegraph-setup.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"; else fail=$((fail+1)); echo "FAIL - $1"; sed 's/^/    /' "$root/out" 2>/dev/null; fi
}

# The stand-in: logs each call; `init` makes .codegraph/; FAKE_FAIL=<verb> makes that verb fail.
mkdir -p "$root/bin" "$root/co/a/src/main/java"
cat >"$root/bin/codegraph" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
[ "${FAKE_FAIL:-}" = "$1" ] && exit 3
[ "$1" = init ] && mkdir -p .codegraph
exit 0
FAKE
chmod +x "$root/bin/codegraph"
export CALLS="$root/calls" CODEGRAPH="$root/bin/codegraph"

bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -d "$root/co/.codegraph" ] && grep -qx "codegraph: index built" "$root/out" && grep -qx "init -y" "$CALLS"
check "the first run builds the index" $?

: >"$CALLS"
bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -qx "codegraph: index synced" "$root/out" && grep -q "^sync " "$CALLS" && ! grep -q "^init" "$CALLS"
check "a second run syncs it instead" $?

FAKE_FAIL=sync bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$(grep -c FAIL "$root/out")" -eq 1 ] && grep -q "FAIL: codegraph sync" "$root/out"
check "a failed sync is one FAIL line and exit 1" $?

rm -rf "$root/co/.codegraph"
FAKE_FAIL=init bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q "FAIL: codegraph init" "$root/out"
check "a failed init is one FAIL line and exit 1" $?

CODEGRAPH="$root/bin/nothing" bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$(wc -l <"$root/out")" -eq 1 ] && grep -q "FAIL: no .*nothing on PATH" "$root/out"
check "a missing binary is one FAIL line and exit 1" $?

bash "$script" "$root/none" >"$root/out" 2>&1; rc=$?
[ "$rc" -eq 1 ]; check "a checkout that does not exist exits 1" $?

if command -v codegraph >/dev/null 2>&1; then
  printf 'package a;\npublic class A { void f() { } }\n' >"$root/co/a/src/main/java/A.java"
  CODEGRAPH=codegraph bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$root/co/.codegraph/codegraph.db" ]; check "the real codegraph builds an index" $?
  CODEGRAPH=codegraph bash "$script" "$root/co" >"$root/out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && grep -qx "codegraph: index synced" "$root/out"; check "the real codegraph syncs it" $?
else echo "skip - no codegraph on PATH, the real binary is untested"; fi

echo "codegraph-setup tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
