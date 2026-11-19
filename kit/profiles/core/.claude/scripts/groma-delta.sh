#!/usr/bin/env bash
# Groma check of a bookkeeping push to main, against its base (P2: a script, not a model; CI plan C7). It runs
# groma-check.sh on the commit to be pushed and on the base it goes on top of, each in its own throwaway checkout, and
# compares their FAIL lines:
#   - a FAIL line the base does not have is new: the push is refused and the new lines are printed;
#   - a FAIL line the base has too is inherited: it is printed, but does not stop the push (main is already red there,
#     and a ticket or retro commit cannot fix that).
# Both trees are checked by the same rules: the commit's own groma-check.sh (the one beside this script when the commit
# has none) is copied over the base's. groma is never narrowed: every check runs on both trees.
# It fails closed. The groma CLI missing or not answering, a groma scan that fails, or a check that stops without a
# FAIL line refuses the push, whatever the base says: a CLI error is never taken for "no new FAIL".
#   groma-delta.sh [<commit> [<base>]]   (defaults: HEAD and origin/main; BASE names main)
# Run it inside the repo the commits are in. GROMA names the CLI (default: groma), as for groma-check.sh. The work tree
# is not touched. Everything is printed on stderr.
# Exit 0: no new FAIL line. 1: new FAIL lines, refused. 2: usage. 3: the check could not run, refused.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
groma="${GROMA:-groma}"
usage() { echo "usage: groma-delta.sh [<commit> [<base>]]" >&2; exit 2; }
cannot() { echo "groma-delta: refused, the check could not run: $*" >&2; exit 3; }

[ $# -le 2 ] || usage
case "${1:-}" in -*) usage ;; esac
top=$(git rev-parse --show-toplevel 2>/dev/null) || cannot "not in a git repository"
commit=$(git -C "$top" rev-parse -q --verify "${1:-HEAD}^{commit}") || cannot "no commit ${1:-HEAD}"
base=$(git -C "$top" rev-parse -q --verify "${2:-origin/${BASE:-main}}^{commit}") || cannot "no base ${2:-origin/${BASE:-main}}"

# The CLI must answer before anything is compared: groma-check.sh hides some of its errors (agent-instructions).
command -v "$groma" >/dev/null 2>&1 || cannot "the groma CLI ('$groma') is not installed (npm install -g groma.md@<the pin in .github/workflows/ci.yml>)"
"$groma" --version >/dev/null 2>&1 || cannot "the groma CLI ('$groma') does not answer --version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 3' INT TERM HUP

# checkout <name> <sha>: a throwaway clone at <sha> that shares the repo's objects, so nothing is registered in the repo
# (no worktree entry is left behind when this is killed) and an unreferenced commit (commit-tickets' commit-tree) is found.
checkout() {
  git clone -q --shared --no-checkout "$top" "$tmp/$1" 2>/dev/null \
    && git -C "$tmp/$1" -c advice.detachedHead=false checkout -q --detach "$2" 2>/dev/null \
    || cannot "cannot check out $2"
}
checkout commit "$commit"
checkout base "$base"

checker=.claude/scripts/groma-check.sh
src="$tmp/commit/$checker"
[ -f "$src" ] || src="$here/groma-check.sh"
[ -f "$src" ] || cannot "no $checker in $commit or beside this script"
cp "$src" "$tmp/checker.sh"
for t in commit base; do
  mkdir -p "$tmp/$t/$(dirname "$checker")" && cp "$tmp/checker.sh" "$tmp/$t/$checker" || cannot "cannot place the check in the $t tree"
done

# run <name> <sha>: run the check in that tree; its FAIL lines go to $tmp/<name>.fail, sorted. Refuses when the check
# could not judge the tree.
run() {
  local out="$tmp/$1.out" rc
  (cd "$tmp/$1" && GROMA="$groma" bash "$checker") >"$out" 2>&1
  rc=$?
  grep '^FAIL: ' "$out" | sort -u > "$tmp/$1.fail"
  if grep -qx 'FAIL: groma scan failed' "$tmp/$1.fail"; then
    sed 's/^/  /' "$out" >&2
    cannot "groma scan failed on the $1 tree (${2:0:12}): a groma CLI error, not a map finding"
  fi
  if [ "$rc" -ne 0 ] && [ ! -s "$tmp/$1.fail" ]; then
    sed 's/^/  /' "$out" >&2
    cannot "the check stopped on the $1 tree (${2:0:12}) with exit $rc and no FAIL line"
  fi
  if [ "$rc" -eq 0 ] && [ -s "$tmp/$1.fail" ]; then
    sed 's/^/  /' "$out" >&2
    cannot "the check passed the $1 tree (${2:0:12}) but printed FAIL lines"
  fi
}
run commit "$commit"
run base "$base"

new=$(comm -23 "$tmp/commit.fail" "$tmp/base.fail")
inherited=$(comm -12 "$tmp/commit.fail" "$tmp/base.fail")
if [ -n "$inherited" ]; then
  echo "groma-delta: inherited from the base ${base:0:12}, not counted against this push:" >&2
  printf '%s\n' "$inherited" | sed 's/^/  /' >&2
fi
if [ -n "$new" ]; then
  echo "groma-delta: refused, ${commit:0:12} adds FAIL lines its base ${base:0:12} does not have:" >&2
  printf '%s\n' "$new" | sed 's/^/  /' >&2
  exit 1
fi
echo "groma-delta: no new FAIL line in ${commit:0:12} against ${base:0:12}" >&2
exit 0
