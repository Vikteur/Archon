#!/usr/bin/env bash
# Tests .claude/scripts/contract-read-only-check.sh (TASK-2.1): the guard that proves the CI contract token cannot push
# to example-contract. Each case asserts the exit code AND the exact message, so a script that fails for another reason
# never counts as a refusal. Real git covers a writable remote, a missing remote and a missing origin; a stub git on PATH
# plays GitHub's refusal text.
# Usage: bash scripts/test/contract-read-only-check.test.sh
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 1
script="$repo_root/.claude/scripts/contract-read-only-check.sh"
# The hub the messages name (kit key contract.repo), the same wherever the suite runs.
export KIT_CONTRACT_REPO=hub-owner/hub-contract
work="$repo_root/build/contract-read-only-check-test"
rm -rf "$work"
mkdir -p "$work/bin"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
real_git="$(command -v git)"
orig_path="$PATH"

pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/       | /'; }

# expect <case> <expected exit: zero|nonzero> <exact line> <args...>: runs the script with the given arguments.
expect() {
  local name="$1" want="$2" line="$3"
  shift 3
  local out rc
  out="$(bash "$script" "$@" 2>&1)"
  rc=$?
  if { [ "$want" = zero ] && [ "$rc" -eq 0 ]; } || { [ "$want" = nonzero ] && [ "$rc" -ne 0 ]; }; then
    if printf '%s\n' "$out" | grep -qF -- "$line"; then
      pass "$name"
    else
      fail "$name: exit $rc but the line is missing: $line" "$out"
    fi
  else
    fail "$name: exit $rc, wanted $want" "$out"
  fi
}

new_checkout() {
  local dir="$1"
  mkdir -p "$dir"
  "$real_git" -C "$dir" init -q -b main
  "$real_git" -C "$dir" config user.name ci
  "$real_git" -C "$dir" config user.email ci@example.invalid
  "$real_git" -C "$dir" commit -q --allow-empty -m probe
}

# stub_git <stdout text> <exit code>: a git that answers `push --dry-run` with the text and exit code, real git otherwise.
stub_git() {
  cat > "$work/bin/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = push ]; then
    echo "$1"
    exit $2
  fi
done
exec "$real_git" "\$@"
STUB
  chmod +x "$work/bin/git"
}

usage="usage: contract-read-only-check.sh <contract-checkout-dir>"

# C1: no argument, empty argument.
expect "C1 no argument prints the usage" nonzero "$usage"
expect "C1 an empty argument prints the usage" nonzero "$usage" ""

# C2: not a git checkout.
mkdir -p "$work/plain"
expect "C2 a directory that is not a git checkout is refused" nonzero "FAIL: $work/plain is not a git checkout" "$work/plain"

# C2b: a .git that names no repository (a broken checkout) is not a git checkout either.
mkdir -p "$work/broken"
echo "gitdir: $work/nowhere" > "$work/broken/.git"
expect "C2b a .git that names no repository is refused" nonzero "FAIL: $work/broken is not a git checkout" "$work/broken"

# C3: a writable origin means the token can push; the dry run must not leave a ref behind.
"$real_git" init -q --bare "$work/writable.git"
new_checkout "$work/c3"
"$real_git" -C "$work/c3" remote add origin "$work/writable.git"
expect "C3 a writable origin is refused" nonzero "FAIL: the contract token can push" "$work/c3"
if [ -z "$("$real_git" ls-remote "$work/writable.git" 2>/dev/null)" ]; then
  pass "C3 the dry run left no ref in the bare repo"
else
  fail "C3 the dry run left no ref in the bare repo" "$("$real_git" ls-remote "$work/writable.git")"
fi

# C4: an origin that does not exist fails, but not with a refusal.
new_checkout "$work/c4"
"$real_git" -C "$work/c4" remote add origin "$work/missing.git"
expect "C4 a missing origin is not accepted as a refusal" nonzero "FAIL: the push failed, but not with a refusal:" "$work/c4"

# C5: no origin remote.
new_checkout "$work/c5"
expect "C5 a checkout without origin is not accepted as a refusal" nonzero "FAIL: the push failed, but not with a refusal:" "$work/c5"

# C6-C8: GitHub's refusal text through a stub git.
new_checkout "$work/stubbed"
PATH="$work/bin:$orig_path"
stub_git "remote: Permission to hub-owner/hub-contract.git denied to ci." 128
expect "C6 a Permission denied refusal is accepted" zero "OK: push to hub-contract refused" "$work/stubbed"
stub_git "fatal: unable to access 'https://github.com/hub-owner/hub-contract/': The requested URL returned error: 403" 128
expect "C7 a 403 refusal is accepted" zero "OK: push to hub-contract refused" "$work/stubbed"
stub_git "fatal: unable to access 'https://github.com/hub-owner/hub-contract/': The requested URL returned error: 403" 0
expect "C8 a push that exits 0 is refused even with the 403 text" nonzero "FAIL: the contract token can push" "$work/stubbed"
PATH="$orig_path"

echo "contract-read-only-check tests: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
