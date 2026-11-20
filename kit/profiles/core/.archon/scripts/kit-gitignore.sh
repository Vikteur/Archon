#!/usr/bin/env bash
# The kit's run state stays out of git: the project's .gitignore must ignore what the kit's hooks and scripts write in a
# checkout, or a node declared `mutates_checkout: false` (explore) fails on a file it never wrote (the audit hook's
# session log), and a commit can pick that state up.
#   kit-gitignore.sh [--check] [<checkout>]
# Without --check it appends every entry the checkout's .gitignore files do not ignore yet to <checkout>/.gitignore
# (default: the current directory), under one comment line, and says which; run again, it adds nothing. With --check
# it changes nothing and exits 1 naming each entry not ignored, with the fix. Exit 2: not a git checkout, or usage.
# The entries: .apm-audit/ (the audit hooks' session logs), .codegraph/ (the CodeGraph index), .archon/mcp/ (the MCP
# config mcp-setup.sh writes per run), and scripts/<tool>/node_modules/ for each kit tool with a package.json
# (scripts/scaffold, scripts/contract-mcp, ...). Only .gitignore files count: a global excludes file or
# .git/info/exclude ignores nothing on another machine or in a fresh clone.
set -uo pipefail

check=false dir=.
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=true ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "kit-gitignore: unknown option $1" >&2; exit 2 ;;
    *) dir=$1 ;;
  esac
  shift
done
git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "kit-gitignore: $dir is not a git checkout" >&2; exit 2; }
top=$(git -C "$dir" rev-parse --show-toplevel) || exit 2

entries=(.apm-audit/ .codegraph/ .archon/mcp/)
for p in "$top"/scripts/*/package.json; do
  [ -f "$p" ] || continue
  t=${p#"$top"/}; entries+=("${t%/package.json}/node_modules/")
done

# ignored <entry>: a path inside it is ignored, and by a .gitignore file (not a global or local exclude).
ignored() {
  local probe="${1%/}/kit-gitignore-probe" src
  git -C "$top" -c core.excludesFile=/dev/null check-ignore -q --no-index "$probe" 2>/dev/null || return 1
  src=$(git -C "$top" -c core.excludesFile=/dev/null check-ignore -v --no-index "$probe" 2>/dev/null | cut -d: -f1)
  [[ "$src" == *.gitignore ]]
}

missing=()
for e in "${entries[@]}"; do ignored "$e" || missing+=("$e"); done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "kit-gitignore: .gitignore ignores the kit's run state (${entries[*]})"
  exit 0
fi
if $check; then
  echo "kit-gitignore: .gitignore does not ignore the kit's run state: ${missing[*]}" >&2
  echo "kit-gitignore: a run would see it as a change to the checkout. Fix: bash .archon/scripts/kit-gitignore.sh, then commit .gitignore on the base branch." >&2
  exit 1
fi
gi="$top/.gitignore"
{
  [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ] && echo
  echo "# Archon kit: run state, never committed (added by bash .archon/scripts/kit-gitignore.sh)"
  printf '%s\n' "${missing[@]}"
} >> "$gi" || { echo "kit-gitignore: cannot write $gi" >&2; exit 1; }
echo "kit-gitignore: added to .gitignore: ${missing[*]}"
