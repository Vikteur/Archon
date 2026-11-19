#!/usr/bin/env bash
# Tests for .archon/scripts/open-pr.sh against throwaway repos with a real bare origin and a stub gh.
# Usage: bash .archon/scripts/test/open-pr.test.sh   (exit 0 = all pass)
set -uo pipefail
# No automatic gc or maintenance in the throwaway repos: a background gc racing the next git call was the suspected
# cause of the temp-repo flakes (docs/memory.md 2026-10-20).
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=receive.autoGc GIT_CONFIG_VALUE_2=false

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/open-pr.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# Stub gh: no open pull request for the branch, and `gh pr create` answers a fixed URL.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") exit 0 ;;
  "pr create") echo "https://github.com/o/r/pull/7" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$root/bin/gh"
export PATH="$root/bin:$PATH"
printf 'body\n' > "$root/body.md"

# repo <name>: a bare origin, a feature clone ($dir) on feat/x with one commit, and a second clone ($other).
repo() {
  dir="$root/$1"; other="$root/$1-other"
  git init -q --bare -b main "$dir.git"
  git clone -q "$dir.git" "$dir" 2>/dev/null
  git -C "$dir" config user.name t; git -C "$dir" config user.email t@t
  echo base > "$dir/a.txt"; git -C "$dir" add -A; git -C "$dir" commit -qm base; git -C "$dir" push -q origin main 2>/dev/null
  git clone -q "$dir.git" "$other" 2>/dev/null
  git -C "$other" config user.name t; git -C "$other" config user.email t@t
  git -C "$dir" switch -qc feat/x
  echo feature > "$dir/f.txt"; git -C "$dir" add -A; git -C "$dir" commit -qm feature
}
main_moves() { # a new commit on origin's main, fetched by the feature clone
  echo more >> "$other/a.txt"; git -C "$other" commit -qam "main moves"; git -C "$other" push -q origin main 2>/dev/null
  git -C "$dir" fetch -q origin main
}
run() { # run: open-pr inside the feature clone; sets out, rc
  out=$( (cd "$dir" && bash "$script" main "title" "$root/body.md") 2>&1 ); rc=$?
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# 1. First push: the branch is not on origin yet. It is pushed, gets an upstream, and the pull request opens.
repo one
run
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 origin has the branch" $([ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir.git" rev-parse feat/x)" ]; echo $?)
check "1 upstream set" $(git -C "$dir" rev-parse -q --verify '@{upstream}' > /dev/null; echo $?)
check "1 prints the pull request" $(echo "$out" | grep -q '"pr": "https://github.com/o/r/pull/7"'; echo $?)

# 2. The branch is on origin and the run rebased it onto a newer main (TASK-4.2, run 4b33311d): the push goes through
#    with a lease against the origin head the run last saw, and origin holds the rebased branch.
repo two
git -C "$dir" push -q -u origin feat/x 2>/dev/null
main_moves
git -C "$dir" rebase -q origin/main
run
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 origin has the rebased branch" $([ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir.git" rev-parse feat/x)" ]; echo $?)
check "2 prints the pushed sha" $(echo "$out" | grep -q "\"sha\": \"$(git -C "$dir" rev-parse HEAD)\""; echo $?)

# 3. Someone else pushed to the branch since the run last saw it, and the run rebased: the lease refuses, the run fails
#    naming the branch, and the other push stays on origin.
repo three
git -C "$dir" push -q -u origin feat/x 2>/dev/null
git -C "$other" fetch -q origin feat/x; git -C "$other" switch -q feat/x
echo theirs > "$other/t.txt"; git -C "$other" add -A; git -C "$other" commit -qm theirs; git -C "$other" push -q origin feat/x 2>/dev/null
theirs=$(git -C "$other" rev-parse HEAD)
main_moves
git -C "$dir" rebase -q origin/main
run
check "3 exit non-zero" $([ "$rc" -ne 0 ]; echo $?)
check "3 names the branch" $(echo "$out" | grep -q 'feat/x'; echo $?)
check "3 their push stays on origin" $([ "$(git -C "$dir.git" rev-parse feat/x)" = "$theirs" ]; echo $?)
check "3 no pull request opened" $(! echo "$out" | grep -q '"pr":'; echo $?)

echo "open-pr: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
