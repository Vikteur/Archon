#!/usr/bin/env bash
# Tests for .claude/scripts/groma-delta.sh (CI plan C7): the real groma-check.sh, copied into throwaway repos, with a
# stub groma CLI, so it tests the delta and the fail-closed paths, not the real map or the real CLI.
# Usage: bash scripts/test/groma-delta.test.sh   (exit 0 = all pass)
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/.claude/scripts/groma-delta.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The cases need a missing description to be a FAIL line: groma_descriptions defaults to optional (a note).
export KIT_GROMA_DESCRIPTIONS=required

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$root/err" 2>/dev/null; fi
}
said() { grep -qF -- "$1" "$root/err"; }
# The stub CLI: --version answers unless STUB_NO_VERSION, agent-instructions says the map is curated, and scan writes
# nothing, or fails with STUB_SCAN_FAIL, or writes groma/scanned.md in a tree that has STUB_SCAN_WRITES as a file.
mkdir -p "$root/bin"
cat > "$root/bin/groma" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) [ -z "${STUB_NO_VERSION:-}" ] && echo 0.6.6 ;;
  agent-instructions) echo "Groma map is curated." ;;
  scan) [ -z "${STUB_SCAN_FAIL:-}" ] || exit 1; [ ! -f STUB_SCAN_WRITES ] || echo new > groma/scanned.md ;;
esac
STUB
chmod +x "$root/bin/groma"
export GROMA="$root/bin/groma"
delta() { (cd "$r" && bash "$script" "$@") >"$root/out" 2>"$root/err"; }

# repo <name>: a repo with origin, a clean curated map and the real check; sets r.
repo() {
  local d="$root/$1"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/w" 2>/dev/null
  r="$d/w"
  mkdir -p "$r/groma" "$r/.claude/scripts" "$r/backlog/tasks"
  cp "$repo_root/.claude/scripts/groma-check.sh" "$r/.claude/scripts/"
  echo '{"scanners": [{"id": "java"}]}' > "$r/groma/scanners.json"
  printf -- '---\ntype: C4\ndescription: The app\ngroma:\n  id: app\n---\n' > "$r/groma/app.md"
  echo '@AGENTS.md' > "$r/CLAUDE.md"
  printf 'Tickets live in the Backlog.md backlog.\nRun groma agent-instructions first.\n' > "$r/AGENTS.md"
  git -C "$r" add -A && git -C "$r" commit -qm base && git -C "$r" push -q origin main
}
# commit_file <path> <content>: commit one file on top of HEAD (not pushed).
commit_file() { mkdir -p "$(dirname "$r/$1")"; printf '%b' "$2" > "$r/$1"; git -C "$r" add -A && git -C "$r" commit -qm "$1"; }
undescribed() { printf -- '---\ntype: C4\ngroma:\n  id: %s\n---\n' "$1"; }

# 1. A clean commit on a clean base passes.
repo one; commit_file backlog/tasks/notes.txt "x\n"
delta; rc=$?
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 says no new FAIL" $(said "no new FAIL line"; echo $?)
check "1 nothing on stdout" $([ ! -s "$root/out" ]; echo $?)

# 2. A commit that adds an undescribed element is refused and names it.
repo two; commit_file groma/db.md "$(undescribed db)"
delta; rc=$?
check "2 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "2 the new FAIL line is printed" $(said "FAIL: groma/db.md has no description"; echo $?)

# 3. A FAIL line the base already has is inherited: printed, and the push is allowed.
repo three; commit_file groma/db.md "$(undescribed db)"; git -C "$r" push -q origin main
commit_file backlog/tasks/notes.txt "x\n"
delta; rc=$?
check "3 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "3 the inherited line is printed" $(said "inherited" && said "FAIL: groma/db.md has no description"; echo $?)

# 4. Inherited plus new: refused, and only the new line is listed as new.
commit_file groma/cache.md "$(undescribed cache)"
delta; rc=$?
check "4 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "4 the new line follows the refusal" $(sed -n '/refused/,$p' "$root/err" | grep -qF "groma/cache.md" \
  && ! sed -n '/refused/,$p' "$root/err" | grep -qF "groma/db.md"; echo $?)

# 5. An open ticket that names no map element is a new FAIL line (the bookkeeping push the plan is about).
repo five; commit_file "backlog/tasks/task-9 - Nine.md" "---\nstatus: To Do\nreferences:\n  - nothing\n---\n"
delta; rc=$?
check "5 exit 1 on an unpinned ticket" $([ "$rc" -eq 1 ] && said "task-9 - Nine.md references no map element"; echo $?)
commit_file "backlog/tasks/task-9 - Nine.md" "---\nstatus: To Do\nreferences:\n  - app\n---\n"
delta; rc=$?
check "5 exit 0 once it is pinned" $([ "$rc" -eq 0 ]; echo $?)

# 6. A fresh scan that changes groma/ is caught on the commit, and the clone is left alone (the work tree is untouched).
repo six; commit_file STUB_SCAN_WRITES "1\n"
echo dirty > "$r/dirty.txt"
delta; rc=$?
check "6 exit 1 when the scan changes the map" $([ "$rc" -eq 1 ] && said "a fresh groma scan changed groma/"; echo $?)
check "6 the work tree is untouched" $([ "$(git -C "$r" status --porcelain)" = "?? dirty.txt" ] && [ ! -e "$r/groma/scanned.md" ]; echo $?)
check "6 no worktree is registered" $([ "$(git -C "$r" worktree list | wc -l)" -eq 1 ]; echo $?)

# 7. An unreferenced commit (commit-tickets builds one with commit-tree) is checked against an explicit base.
repo seven
c=$(git -C "$r" commit-tree "$(git -C "$r" rev-parse HEAD^{tree})" -p HEAD -m bookkeeping)
delta "$c" origin/main; rc=$?
check "7 an unreferenced commit passes" $([ "$rc" -eq 0 ] && said "${c:0:12}"; echo $?)

# 8. Both trees are judged by the commit's check: a base without one is still compared.
repo eight; git -C "$r" rm -q .claude/scripts/groma-check.sh; git -C "$r" commit -qm "no check"
git -C "$r" push -q origin main
mkdir -p "$r/.claude/scripts"; cp "$repo_root/.claude/scripts/groma-check.sh" "$r/.claude/scripts/"; git -C "$r" add -A; git -C "$r" commit -qm "check back"
delta; rc=$?
check "8 a base without the check is compared" $([ "$rc" -eq 0 ]; echo $?)

# 9. Fail closed on every groma CLI error, even when the base fails the same way.
repo nine; commit_file backlog/tasks/notes.txt "x\n"
(cd "$r" && GROMA="$root/nowhere/groma" bash "$script") >"$root/out" 2>"$root/err"; rc=$?
check "9 exit 3 without the CLI" $([ "$rc" -eq 3 ] && said "not installed"; echo $?)
(cd "$r" && STUB_NO_VERSION=1 bash "$script") >"$root/out" 2>"$root/err"; rc=$?
check "9 exit 3 when the CLI does not answer" $([ "$rc" -eq 3 ] && said "does not answer"; echo $?)
(cd "$r" && STUB_SCAN_FAIL=1 bash "$script") >"$root/out" 2>"$root/err"; rc=$?
check "9 exit 3 when the scan fails on both trees" $([ "$rc" -eq 3 ] && said "groma CLI error"; echo $?)

# 10. A check that stops without a FAIL line is not taken for a pass.
repo ten; printf '#!/usr/bin/env bash\necho broken >&2\nexit 7\n' > "$r/.claude/scripts/groma-check.sh"
git -C "$r" commit -qam "broken check"
delta; rc=$?
check "10 exit 3 on a crashed check" $([ "$rc" -eq 3 ] && said "exit 7 and no FAIL line"; echo $?)

# 11. Usage and bad refs.
repo eleven
delta a b c; rc=$?
check "11 three arguments are usage" $([ "$rc" -eq 2 ]; echo $?)
delta deadbeefdeadbeef; rc=$?
check "11 an unknown commit is refused" $([ "$rc" -eq 3 ] && said "no commit"; echo $?)
delta HEAD nosuchbase; rc=$?
check "11 an unknown base is refused" $([ "$rc" -eq 3 ] && said "no base"; echo $?)

echo "groma-delta: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
