#!/usr/bin/env bash
# Tests for .archon/scripts/pr-refresh.sh against a throwaway repo and a stubbed gh.
# Usage: bash .archon/scripts/test/pr-refresh.test.sh   (exit 0 = all pass)
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pr-refresh.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
STUB
chmod +x "$root/bin/gh"

check() { # check <name> <exit code of the condition>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "${out:-}" | sed 's/^/    /'; fi
}

# Origin with main, a clone on feat with two commits touching two files.
d="$root/r"; mkdir -p "$d"
git init -q --bare -b main "$d/origin.git"
git clone -q "$d/origin.git" "$d/w" 2>/dev/null
cd "$d/w" || exit 2
git config user.name t; git config user.email t@t
echo base > README.md; git add -A; git commit -qm base; git push -q origin main
git checkout -q -b feat
echo a > a.txt; git add -A; git commit -qm "feat: add a"
echo b > b.txt; git add -A; git commit -qm "fix: add b"
git fetch -q origin

art="$root/art"; mkdir -p "$art"
log="$root/gh.log"; : > "$log"
run() { out=$(PATH="$root/bin:$PATH" GH_LOG="$log" ARTIFACTS_DIR="$art" bash "$script" "$@" 2>&1); rc=$?; }

# 1. Body without a block: block appended before the final Generated-with line.
printf 'Summary\n\nWrong claim: 99 tests.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$root/body.md"
run 7 main "$root/body.md"
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 start marker" $(grep -qx '<!-- pr-refresh:start -->' "$root/body.md"; echo $?)
check "1 end marker" $(grep -qx '<!-- pr-refresh:end -->' "$root/body.md"; echo $?)
check "1 commit list" $(grep -qE '^- [0-9a-f]+ feat: add a$' "$root/body.md" && grep -qE '^- [0-9a-f]+ fix: add b$' "$root/body.md"; echo $?)
check "1 file count" $(grep -qE '(^|[^0-9])2 files? changed' "$root/body.md"; echo $?)
check "1 original text kept" $(grep -q 'Wrong claim: 99 tests.' "$root/body.md"; echo $?)
check "1 block before generated line" $([ "$(grep -n 'pr-refresh:end' "$root/body.md" | cut -d: -f1)" -lt "$(grep -n 'Generated with' "$root/body.md" | cut -d: -f1)" ]; echo $?)
check "1 gh pr edit called" $(grep -q "^gh pr edit 7 --body-file $root/body.md" "$log"; echo $?)
check "1 no owner decisions without plan" $(! grep -q 'Owner decisions' "$root/body.md"; echo $?)
first=$(cat "$root/body.md")

# 2. Idempotent.
run 7 main "$root/body.md"
check "2 identical on second run" $([ "$first" = "$(cat "$root/body.md")" ]; echo $?)
check "2 one block only" $([ "$(grep -c 'pr-refresh:start' "$root/body.md")" -eq 1 ]; echo $?)

# 3. A new commit and a plan with Owner decisions: block replaced, decisions copied, idempotent.
echo c > c.txt; git add -A; git commit -qm "test: add c"
printf '# Plan\n\n## Scope\nx\n\n## Owner decisions\n- D1: keep it small\n- D2: no cache\n\n## Other\ny\n' > "$art/plan.md"
run 7 main "$root/body.md"
check "3 new commit listed" $(grep -qE '^- [0-9a-f]+ test: add c$' "$root/body.md"; echo $?)
check "3 count updated" $(grep -qE '(^|[^0-9])3 files? changed' "$root/body.md"; echo $?)
check "3 decisions copied" $(grep -q 'D1: keep it small' "$root/body.md" && grep -q 'D2: no cache' "$root/body.md"; echo $?)
check "3 under exactly one Decisions heading, inside the block, word for word" \
  $([ "$(grep -cx '## Decisions' "$root/body.md")" -eq 1 ] && [ "$(grep -cx -- '- D1: keep it small' "$root/body.md")" -eq 1 ] \
    && awk '/pr-refresh:start/{on=1} /pr-refresh:end/{on=0} on && /^## Decisions$/{d=1} on && d && /^- D2: no cache$/{f=1} END{exit !f}' "$root/body.md"; echo $?)
check "3 other plan sections not copied" $(! grep -q '^y$' "$root/body.md"; echo $?)
check "3 one block only" $([ "$(grep -c 'pr-refresh:start' "$root/body.md")" -eq 1 ]; echo $?)
second=$(cat "$root/body.md"); run 7 main "$root/body.md"
check "3 idempotent" $([ "$second" = "$(cat "$root/body.md")" ]; echo $?)
check "3 still one Decisions heading after a refresh" $([ "$(grep -cx '## Decisions' "$root/body.md")" -eq 1 ]; echo $?)
check "3 body text before block untouched" $(grep -q 'Wrong claim: 99 tests.' "$root/body.md"; echo $?)

# 3b. The scaffold report goes into the block without its title, replaced on the next refresh, idempotent.
check "3b no scaffold section without the report" $(! grep -q 'Scaffold check' "$root/body.md"; echo $?)
printf '# Scaffold check — title\n\nGate: **failed.** 1 by hand.\n\n## Written by hand where a template fits\n\n| File |\n|---|\n| `A.java` |\n' > "$art/scaffold-check.md"
run 7 main "$root/body.md"
check "3b scaffold section" $(grep -qx '### Scaffold check (generated)' "$root/body.md" && grep -qF '| `A.java` |' "$root/body.md"; echo $?)
check "3b report title not copied" $(! grep -qF '# Scaffold check — title' "$root/body.md"; echo $?)
check "3b inside the block" $(awk '/pr-refresh:start/{on=1} /pr-refresh:end/{on=0} on && /A\.java/{f=1} END{exit !f}' "$root/body.md"; echo $?)
printf '# Scaffold check — title\n\nGate: **passed.** 0 by hand.\n' > "$art/scaffold-check.md"
run 7 main "$root/body.md"
check "3b replaced on refresh" $(! grep -qF 'A.java' "$root/body.md" && grep -qF 'Gate: **passed.** 0 by hand.' "$root/body.md"; echo $?)
third=$(cat "$root/body.md"); run 7 main "$root/body.md"
check "3b idempotent" $([ "$third" = "$(cat "$root/body.md")" ]; echo $?)
rm -f "$art/scaffold-check.md"

# 3d. mcp-use-check.js's report goes into the block without its title, before the STOP line.
check "3d no MCP use section without the report" $(! grep -q 'MCP use' "$root/body.md"; echo $?)
printf '# MCP use per node\n\n| Node | @@KIT_CONTRACT_SERVER_NAME@@ |\n| --- | ---: |\n| explore | 3 |\n' > "$art/mcp-use.md"
run 7 main "$root/body.md"
check "3d MCP use section" $(grep -qx '### MCP use (generated)' "$root/body.md" && grep -qxF '| explore | 3 |' "$root/body.md"; echo $?)
check "3d report title not copied" $(! grep -qx '# MCP use per node' "$root/body.md"; echo $?)
fifth=$(cat "$root/body.md"); run 7 main "$root/body.md"
check "3d idempotent" $([ "$fifth" = "$(cat "$root/body.md")" ]; echo $?)
rm -f "$art/mcp-use.md"

# 3c. stop-route's stop-items.txt becomes the STOP line, the block's last line; idempotent.
check "3c no STOP line without the file" $(! grep -q '^STOP items' "$root/body.md"; echo $?)
printf '\n' > "$art/stop-items.txt"
run 7 main "$root/body.md"
check "3c empty file: no STOP item" $(grep -qx 'STOP items touched: the ticket touches no STOP item.' "$root/body.md"; echo $?)
check "3c last line of the block" $([ "$(grep -A1 '^STOP items' "$root/body.md" | tail -n 1)" = '<!-- pr-refresh:end -->' ]; echo $?)
printf 'ticket labels: stop-auth-access\n' > "$art/stop-items.txt"
run 7 main "$root/body.md"
check "3c named items" $(grep -qx 'STOP items touched: ticket labels: stop-auth-access' "$root/body.md" && [ "$(grep -c '^STOP items' "$root/body.md")" -eq 1 ]; echo $?)
fourth=$(cat "$root/body.md"); run 7 main "$root/body.md"
check "3c idempotent" $([ "$fourth" = "$(cat "$root/body.md")" ]; echo $?)
rm -f "$art/stop-items.txt"

# 4. Body without a Generated-with line: block appended at the end.
printf 'Just text\n' > "$root/b2.md"; run 7 main "$root/b2.md"
check "4 appended" $(grep -q 'pr-refresh:end' "$root/b2.md"; echo $?)

# 5. Usage error.
run 7 main
check "5 usage exit 2" $([ "$rc" -eq 2 ]; echo $?)

echo "pr-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
