#!/usr/bin/env bash
# The .archon test suites a change can affect (owner decision 2026-10-18, docs/memory.md): ci-local.sh runs only these
# in the "Every .archon test suite passes" step.
#   archon-suites.sh <repo> <sha>   < changed files, one per line
# Prints "all", or the suites to run (.archon/scripts/test/<x>.test.sh, one per line), or nothing when none is affected.
# Reads the commit under test with git grep; nothing is checked out.
# A changed file is named by its stem (the file name up to its first dot; .gitignore as is). A name counts only as a
# whole word, never inside a longer file name ("retro" is not in "retro-fence"). Until nothing is added, every script
# that names one (.archon/scripts/*.sh|js, .claude/hooks/scripts/*) adds its own stem: it calls the changed file.
# A suite runs when it changed, when the script it is named after is named, or when its text names one of them or the
# folder of a changed file outside .archon/scripts (a suite that reads every workflow names .archon/workflows).
# Everything runs when the change touches the workflow that runs the suites, .gitignore (read through git check-ignore,
# never by name), a file of the suites that is not a suite (a shared helper), or this selector. An empty or unknown
# change is ci-local.sh's to judge: it runs everything.
# A file under the suites' fixtures/<name>/ runs the suites whose text names fixtures/<name>; when none does, every
# .archon suite runs, as for any other shared file of the suites (never the app's suites: those are not selected here).
# The contract suites that scan every script and workflow (script-calls, workflow-contracts: ROADMAP R17, T12) run
# when any script or workflow outside a test folder changes, as they name none of them by name.
set -uo pipefail

repo=$1 sha=$2
SUITES=.archon/scripts/test
CALLERS=(':(glob).archon/scripts/*.sh' ':(glob).archon/scripts/*.js' ':(glob).claude/hooks/scripts/*')

declare -A names=() dirs=() suites=() fixdirs=()
SCANNERS=("$SUITES/script-calls.test.sh" "$SUITES/workflow-contracts.test.sh")
stem() { local b=${1##*/}; if [ -n "${b%%.*}" ]; then echo "${b%%.*}"; else echo "$b"; fi; }

while IFS= read -r f; do
  f=${f%$'\r'}
  [ -n "$f" ] || continue
  case "$f" in
    .github/workflows/ci.yml|.gitignore|.claude/scripts/archon-suites.sh) echo all; exit 0 ;;
    "$SUITES"/*.test.sh) suites[$f]=1 ;;
    "$SUITES"/fixtures/*/*) fx=${f#"$SUITES"/fixtures/}; fixdirs[fixtures/${fx%%/*}]=1; continue ;;
    "$SUITES"/*) echo all; exit 0 ;;
  esac
  case "$f" in
    */test/*) ;;
    .archon/scripts/*|.archon/workflows/*|.archon/githooks/*|.claude/scripts/*|.claude/hooks/scripts/*|.github/skills/*/scripts/*|scripts/*)
      for t in "${SCANNERS[@]}"; do suites[$t]=1; done ;;
  esac
  names[$(stem "$f")]=1
  d=${f%/*}
  case "$d" in "$f"|.archon/scripts|.archon/scripts/*) ;; *) dirs[$d]=1 ;; esac
done

# grep_names [--dirs] <pathspec...>: the files at $sha whose text names a recorded name (with --dirs, also the folder
# of a changed file) as a whole word.
grep_names() {
  local alt="" n
  local -a words=("${!names[@]}")
  if [ "$1" = --dirs ]; then words+=("${!dirs[@]}"); shift; fi
  for n in "${words[@]}"; do alt+="${alt:+|}${n//./\\.}"; done
  [ -n "$alt" ] || return 0
  git -C "$repo" grep -l -E "(^|[^A-Za-z0-9_-])($alt)([^A-Za-z0-9_-]|\$)" "$sha" -- "$@" 2>/dev/null | sed "s#^$sha:##"
}

while :; do
  new=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(stem "$f")
    [ -n "${names[$n]:-}" ] || { names[$n]=1; new=1; }
  done < <(grep_names "${CALLERS[@]}")
  [ -n "$new" ] || break
done
[ -n "${DEBUG_NAMES:-}" ] && echo "names: ${!names[*]} dirs: ${!dirs[*]}" >&2

for fx in "${!fixdirs[@]}"; do
  users=$(git -C "$repo" grep -l -F "$fx" "$sha" -- ":(glob)$SUITES/*.test.sh" 2>/dev/null | sed "s#^$sha:##")
  [ -n "$users" ] || { echo all; exit 0; }
  while IFS= read -r t; do suites[$t]=1; done <<< "$users"
done
while IFS= read -r t; do [ -n "$t" ] && suites[$t]=1; done < <(grep_names --dirs ":(glob)$SUITES/*.test.sh")
# Only the suites that exist at $sha: a deleted one is not run.
while IFS= read -r t; do
  t=${t%$'\r'}
  n=${t##*/}; n=${n%.test.sh}
  if [ -n "${suites[$t]:-}" ] || [ -n "${names[$n]:-}" ]; then echo "$t"; fi
done < <(git -C "$repo" ls-tree --name-only "$sha" "$SUITES/" 2>/dev/null | grep '\.test\.sh$' | sort)
exit 0
