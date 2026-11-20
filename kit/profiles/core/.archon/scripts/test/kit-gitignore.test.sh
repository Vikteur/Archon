#!/usr/bin/env bash
# Tests for .archon/scripts/kit-gitignore.sh in throwaway git checkouts: it adds what .gitignore misses, once, under
# one comment line; --check names what is missing and changes nothing; a broader pattern counts, a negated one and a
# global or local exclude do not; a kit tool's node_modules/ is required only when that tool is there; the ticket node
# of build-feature-copilot runs --check before anything else.
# Usage: bash .archon/scripts/test/kit-gitignore.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/kit-gitignore.sh"
wf="$here/../workflows/build-feature-copilot.yaml"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL="$root/gitconfig"   # the machine's own excludes never count
: > "$GIT_CONFIG_GLOBAL"
audit=".apm-audit/"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
fresh() { # fresh <name>: a new checkout at $r
  r="$root/$1"; mkdir -p "$r"; git -C "$r" init -q
}
run() { out=$(bash "$script" "$@" 2>&1); rc=$?; }
has() { grep -qxF "$1" "$r/.gitignore"; }

# 1. No .gitignore: all three entries are added under one comment line; the file is new.
fresh one
run "$r"
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 every entry added" $(has "$audit" && has .codegraph/ && has .archon/mcp/; echo $?)
check "1 one comment line" $([ "$(grep -c '^# Archon kit' "$r/.gitignore")" -eq 1 ]; echo $?)
check "1 says what it added" $(grep -q 'added to .gitignore: .apm-audit/ .codegraph/ .archon/mcp/' <<< "$out"; echo $?)
mkdir -p "$r/.apm-audit/sessions" "$r/.codegraph" "$r/.archon/mcp"
touch "$r/.apm-audit/sessions/copilot-run.jsonl" "$r/.codegraph/db" "$r/.archon/mcp/build-tools.json"
check "1 the run state is ignored now" $([ "$(git -C "$r" status --porcelain --untracked-files=all)" = "?? .gitignore" ]; echo $?)

# 2. Run again: nothing added, the file unchanged.
before=$(cat "$r/.gitignore")
run "$r"
check "2 idempotent: exit 0, nothing added" $([ "$rc" -eq 0 ] && [ "$(cat "$r/.gitignore")" = "$before" ] && grep -q 'ignores the kit' <<< "$out"; echo $?)

# 3. --check: missing entries named, exit 1, nothing written; the fix named.
fresh three
printf 'build/\n.codegraph' > "$r/.gitignore"   # no newline at the end
run --check "$r"
check "3 --check exits 1" $([ "$rc" -eq 1 ]; echo $?)
check "3 --check names only the missing" $(grep -q 'does not ignore .*: .apm-audit/ .archon/mcp/$' <<< "$(head -1 <<< "$out")"; echo $?)
check "3 --check names the fix" $(grep -q 'Fix: bash .archon/scripts/kit-gitignore.sh' <<< "$out"; echo $?)
check "3 --check writes nothing" $([ "$(cat "$r/.gitignore")" = "$(printf 'build/\n.codegraph')" ]; echo $?)
run "$r"
check "3 adds after a last line without a newline, keeps the old lines" \
  $([ "$(sed -n 2p "$r/.gitignore")" = .codegraph ] && has "$audit" && has .archon/mcp/ && ! has .codegraph/; echo $?)
run --check "$r"
check "3 --check passes once added" $([ "$rc" -eq 0 ]; echo $?)

# 4. A broader pattern counts; a negation undoes it; info/exclude and a global excludes file do not count.
fresh four
printf '/.apm-audit\n.codegraph/**\n.archon/\n' > "$r/.gitignore"
run --check "$r"
check "4 broader and anchored patterns count" $([ "$rc" -eq 0 ]; echo $?)
# git never re-includes a path under an ignored folder (.archon/), so the negation goes under .archon/*.
printf '/.apm-audit\n.codegraph/**\n.archon/*\n!.archon/mcp/\n' > "$r/.gitignore"
run --check "$r"
check "4 a negated entry is missing" $([ "$rc" -eq 1 ] && grep -q ': .archon/mcp/$' <<< "$(head -1 <<< "$out")"; echo $?)
fresh four-b
printf '%s\n' "$audit" .codegraph/ .archon/mcp/ > "$r/.git/info/exclude"
printf '%s\n' "$audit" > "$root/global-ignore"; git config --global core.excludesFile "$root/global-ignore"
run --check "$r"
check "4 info/exclude and a global excludes file do not count" $([ "$rc" -eq 1 ] && grep -q ': .apm-audit/ .codegraph/ .archon/mcp/$' <<< "$(head -1 <<< "$out")"; echo $?)
: > "$GIT_CONFIG_GLOBAL"

# 5. A kit tool with a package.json needs its node_modules/ ignored; a folder without one does not.
fresh five
mkdir -p "$r/scripts/scaffold" "$r/scripts/contract-mcp" "$r/scripts/plain"
echo '{}' > "$r/scripts/scaffold/package.json"; echo '{}' > "$r/scripts/contract-mcp/package.json"
run "$r"
check "5 each tool's node_modules/ added" $(has scripts/scaffold/node_modules/ && has scripts/contract-mcp/node_modules/; echo $?)
check "5 none for a folder without package.json" $(! grep -q 'scripts/plain' "$r/.gitignore"; echo $?)
fresh five-b
mkdir -p "$r/scripts/scaffold"; echo '{}' > "$r/scripts/scaffold/package.json"
printf '%s\n' node_modules/ "$audit" .codegraph/ .archon/mcp/ > "$r/.gitignore"
run --check "$r"
check "5 a global node_modules/ pattern counts" $([ "$rc" -eq 0 ]; echo $?)

# 6. From a subfolder it fixes the checkout's root .gitignore; outside a checkout and on a bad option it exits 2.
fresh six
mkdir -p "$r/sub"
out=$(cd "$r/sub" && bash "$script" 2>&1); rc=$?
check "6 a subfolder fixes the root .gitignore" $([ "$rc" -eq 0 ] && has "$audit" && [ ! -e "$r/sub/.gitignore" ]; echo $?)
mkdir -p "$root/nogit"
out=$(cd "$root/nogit" && GIT_CEILING_DIRECTORIES="$root" bash "$script" 2>&1); rc=$?
check "6 not a checkout: exit 2" $([ "$rc" -eq 2 ]; echo $?)
run --bogus "$r"
check "6 unknown option: exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 7. The ticket node checks it first, so a run fails at once with the fix instead of at explore's checkout guard.
if [ -f "$wf" ]; then
  first=$(yq '.nodes[] | select(.id == "ticket") | .bash' "$wf" | grep -v '^[[:space:]]*#' | grep -m1 .)
  out="$first"
  check "7 ticket runs kit-gitignore.sh --check first and fails on it" \
    $(grep -qE '^bash \.archon/scripts/kit-gitignore\.sh --check( |$).*\|\| exit 1' <<< "$first"; echo $?)
fi

echo "kit-gitignore tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
