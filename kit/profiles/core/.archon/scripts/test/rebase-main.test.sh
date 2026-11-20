#!/usr/bin/env bash
# Tests for .archon/scripts/rebase-main.sh against throwaway repos with a real bare origin.
# Usage: bash .archon/scripts/test/rebase-main.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rebase-main.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# repo <name> <union|plain>: a bare origin plus a feature clone ($dir) and a second clone ($other) that plays main.
# docs/memory.md starts with two entries; "union" adds the .gitattributes line that makes appends from two branches merge.
# The feature branch feat/x is pushed, so it has an upstream.
repo() {
  dir="$root/$1"; other="$root/$1-other"
  git init -q --bare -b main "$dir.git"
  git clone -q "$dir.git" "$dir" 2>/dev/null
  git -C "$dir" config user.name t; git -C "$dir" config user.email t@t
  git -C "$dir" config core.autocrlf false
  printf '# Memory\n\n## Entry A\nfirst\n\n## Entry B\nsecond\n' > "$dir/docs-memory.tmp"
  mkdir -p "$dir/docs"; mv "$dir/docs-memory.tmp" "$dir/docs/memory.md"
  if [ "$2" = union ]; then echo 'docs/memory.md merge=union' > "$dir/.gitattributes"; fi
  git -C "$dir" add -A; git -C "$dir" commit -qm base; git -C "$dir" push -q origin main 2>/dev/null
  git clone -q "$dir.git" "$other" 2>/dev/null
  git -C "$other" config user.name t; git -C "$other" config user.email t@t
  git -C "$other" config core.autocrlf false
  git -C "$dir" switch -qc feat/x; git -C "$dir" push -q -u origin feat/x 2>/dev/null
}
commit_in() { # commit_in <clone> <file> <text to append>: append a line block to the file and commit it
  printf '%s\n' "$3" >> "$1/$2"; git -C "$1" add -A; git -C "$1" commit -qm "edit $2"
}
run() { # run <args...>: rebase-main inside the feature clone; sets out, rc
  out=$( (cd "$dir" && bash "$script" "$@") 2>&1 ); rc=$?
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# 1. Both sides append a section to docs/memory.md and the file is merge=union: the rebase succeeds, keeps both sections,
#    replays the feature on top of main (no merge commit) and force-pushes the rewritten branch.
repo one union
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
commit_in "$other" docs/memory.md $'\n## Entry M\nfrom main'
git -C "$other" push -q origin main 2>/dev/null
git -C "$dir" push -q origin feat/x 2>/dev/null
run
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 rebased true" $(echo "$out" | grep -q '"rebased": true'; echo $?)
check "1 pushed true" $(echo "$out" | grep -q '"pushed": true'; echo $?)
check "1 both sections present" $(grep -q 'Entry F' "$dir/docs/memory.md" && grep -q 'Entry M' "$dir/docs/memory.md"; echo $?)
check "1 existing entries keep their order" $([ "$(grep -n '^## Entry' "$dir/docs/memory.md" | head -2 | cut -d: -f2)" = "$(printf '## Entry A\n## Entry B')" ]; echo $?)
check "1 no conflict markers" $(! grep -qE '^(<<<<<<< |>>>>>>> |=======$)' "$dir/docs/memory.md"; echo $?)
check "1 work tree clean" $([ -z "$(git -C "$dir" status --porcelain)" ]; echo $?)
check "1 no merge commit" $([ -z "$(git -C "$dir" rev-list --merges origin/main..HEAD)" ]; echo $?)
check "1 feature sits on top of main" $(git -C "$dir" merge-base --is-ancestor origin/main HEAD; echo $?)
check "1 origin has the rebased branch" $([ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir.git" rev-parse feat/x)" ]; echo $?)

# 2. Same without the attribute: a real conflict. The rebase is aborted, the work tree is clean, the file is named.
repo two plain
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
commit_in "$other" docs/memory.md $'\n## Entry M\nfrom main'
git -C "$other" push -q origin main 2>/dev/null
git -C "$dir" push -q origin feat/x 2>/dev/null
before=$(git -C "$dir" rev-parse HEAD)
run
check "2 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "2 names the conflicted file" $(echo "$out" | grep -q 'docs/memory.md'; echo $?)
check "2 rebase aborted" $([ ! -d "$dir/.git/rebase-merge" ] && [ ! -d "$dir/.git/rebase-apply" ]; echo $?)
check "2 work tree clean" $([ -z "$(git -C "$dir" status --porcelain)" ]; echo $?)
check "2 head unchanged" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ]; echo $?)

# 3. Already up to date: nothing to do, nothing pushed.
repo three union
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
before=$(git -C "$dir" rev-parse HEAD)
run
check "3 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "3 rebased false" $(echo "$out" | grep -q '"rebased": false'; echo $?)
check "3 pushed false" $(echo "$out" | grep -q '"pushed": false'; echo $?)
check "3 head unchanged" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ]; echo $?)

# 4. A rebase that goes through but brings conflict markers in (committed on main) is refused and not pushed.
repo four union
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
printf '%s\n' 'broken' > "$other/notes.txt"
printf '<<<<<<< %s\n' HEAD >> "$other/notes.txt"; printf '%s\n' 'x' '=======' 'y' >> "$other/notes.txt"
printf '>>>>>>> %s\n' feat >> "$other/notes.txt"
git -C "$other" add -A; git -C "$other" commit -qm "marker file"; git -C "$other" push -q origin main 2>/dev/null
run
check "4 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "4 says markers" $(echo "$out" | grep -qi 'conflict marker'; echo $?)
check "4 not pushed" $([ "$(git -C "$dir" rev-parse origin/feat/x)" = "$(git -C "$dir.git" rev-parse feat/x)" ] && [ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir.git" rev-parse feat/x)" ]; echo $?)

# 5. A different base branch can be given.
repo five union
git -C "$other" switch -qc develop; commit_in "$other" other.txt "dev"; git -C "$other" push -q origin develop 2>/dev/null
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
run develop
check "5 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "5 rebased true" $(echo "$out" | grep -q '"rebased": true'; echo $?)
check "5 base file arrived" $([ -f "$dir/other.txt" ]; echo $?)

# 6. Never on the base branch itself.
repo six union
git -C "$dir" switch -q main
commit_in "$other" other.txt "m"; git -C "$other" push -q origin main 2>/dev/null
run
check "6 exit 1 on main" $([ "$rc" -eq 1 ]; echo $?)
check "6 says refusing" $(echo "$out" | grep -q 'Refusing'; echo $?)

# 7. Someone else pushed to the feature branch after our last fetch: the lease refuses to overwrite it.
repo seven union
commit_in "$dir" docs/memory.md $'
## Entry F
from the feature'
git -C "$dir" push -q origin feat/x 2>/dev/null
late="$root/seven-late"; git clone -q -b feat/x "$dir.git" "$late" 2>/dev/null
git -C "$late" config user.name t; git -C "$late" config user.email t@t; git -C "$late" config core.autocrlf false
commit_in "$late" late.txt "late"; git -C "$late" push -q origin feat/x 2>/dev/null
commit_in "$other" other.txt "m"; git -C "$other" push -q origin main 2>/dev/null
run
check "7 exit non-zero" $([ "$rc" -ne 0 ]; echo $?)
check "7 the other push survives" $([ -n "$(git -C "$dir.git" log --format=%s --grep='edit late.txt' feat/x)" ]; echo $?)

# 8. The fetch fails twice, then works: rebase-main tries again and the rebase goes through.
#    A git wrapper on PATH fails the first FETCH_FAILS fetches (counted in $root/fetches), then runs the real git.
realgit=$(command -v git)
mkdir -p "$root/bin"
cat > "$root/bin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    n=\$(cat "$root/fetches" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$root/fetches"
    if [ "\$n" -le "\${FETCH_FAILS:-0}" ]; then echo "fatal: unable to access origin (try \$n)" >&2; exit 128; fi
    break
  fi
done
exec "$realgit" "\$@"
STUB
chmod +x "$root/bin/git"
flaky() { # flaky <fails>: run with the wrapper; sets out, rc, fetches
  rm -f "$root/fetches"
  out=$( (cd "$dir" && PATH="$root/bin:$PATH" FETCH_FAILS=$1 REBASE_FETCH_WAIT=0 bash "$script") 2>&1 ); rc=$?
  fetches=$(cat "$root/fetches" 2>/dev/null || echo 0)
}
repo eight union
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
commit_in "$other" other.txt "m"; git -C "$other" push -q origin main 2>/dev/null
flaky 2
check "8 exit 0 after two failed fetches" $([ "$rc" -eq 0 ]; echo $?)
check "8 fetched three times" $([ "$fetches" -eq 3 ]; echo $?)
check "8 says it tries again" $(echo "$out" | grep -q 'try 2 of 3'; echo $?)
check "8 rebased true" $(echo "$out" | grep -q '"rebased": true'; echo $?)
check "8 base file arrived" $([ -f "$dir/other.txt" ]; echo $?)

# 9. The fetch fails 3 times: exit 3 (not 1, so no caller reads it as a conflict), nothing rebased, nothing pushed.
repo nine union
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
commit_in "$other" other.txt "m"; git -C "$other" push -q origin main 2>/dev/null
before=$(git -C "$dir" rev-parse HEAD); pushed=$(git -C "$dir.git" rev-parse feat/x)
flaky 9
check "9 exit 3" $([ "$rc" -eq 3 ]; echo $?)
check "9 fetched exactly three times" $([ "$fetches" -eq 3 ]; echo $?)
check "9 says it failed 3 times" $(echo "$out" | grep -q 'failed 3 times'; echo $?)
check "9 head unchanged" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ]; echo $?)
check "9 origin untouched" $([ "$(git -C "$dir.git" rev-parse feat/x)" = "$pushed" ]; echo $?)
check "9 base file absent" $([ ! -f "$dir/other.txt" ]; echo $?)

# 10. --no-push: the rebase goes through, but nothing is pushed; origin keeps the old head (the caller pushes).
repo ten union
commit_in "$dir" docs/memory.md $'\n## Entry F\nfrom the feature'
git -C "$dir" push -q origin feat/x 2>/dev/null
commit_in "$other" other.txt "m"; git -C "$other" push -q origin main 2>/dev/null
pushed=$(git -C "$dir.git" rev-parse feat/x)
run --no-push main
check "10 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "10 rebased true" $(echo "$out" | grep -q '"rebased": true'; echo $?)
check "10 pushed false" $(echo "$out" | grep -q '"pushed": false'; echo $?)
check "10 base file arrived" $([ -f "$dir/other.txt" ]; echo $?)
check "10 origin untouched" $([ "$(git -C "$dir.git" rev-parse feat/x)" = "$pushed" ]; echo $?)

echo "rebase-main tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
