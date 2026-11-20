#!/usr/bin/env bash
# A gate changes only together with a decision entry (CI plan C11; owner decisions D1, D2 and UD-31 of 2026-10-20,
# docs/memory.md). P6: gates are never waived, only reordered or narrowed, and a narrowing is a decision someone took,
# not a side effect of a refactor. This script compares a change with its base and fails when it changes a gate without
# adding a decision entry to docs/memory.md in the same change. The gates:
#   ci.yml          .github/workflows/ci.yml: the job set, or the steps of a job (comments and other keys do not count)
#   ci-inputs.yml   .github/ci-inputs.yml: any change to its content (comments do not count)
#   ci-plan         .claude/scripts/ci-plan.sh: any change to its code (comment and blank lines do not count)
#   local-ci-status the accept rules of .archon/scripts/local-ci-status.sh, its functions parse, verify and accept,
#                   and the grammar's reader ci_status_parse in .claude/scripts/ci-status-grammar.sh (comment and blank
#                   lines do not count)
#   kit-gates       the gates map of .archon/kit.yaml or .archon/kit.defaults.yaml: a report-only gate of ci-gate.sh
#                   switched to block or back, or a gate added or removed (comments and other keys do not count)
# A decision entry: the change adds to docs/memory.md a dated heading `## <yyyy-mm-dd> — …` (or `### <yyyy-mm-dd> — …`,
# the entry level of a memory.md that groups its entries under `## Decisions`), and the lines it adds there
# name every gate it changes by the name in the first column above (ci-status-grammar counts for local-ci-status).
#   gate-change-check.sh [<base> [<head>]]
# compares <head> (a commit; default: the work tree, committed or not) with its merge-base with <base> (default
# origin/main; GATE_BASE overrides the default). Run it inside the repo. Prints one line per gate changed and
# "gate-change-check: ok" or a FAIL line per missing entry.
# Exit 0: no gate changed, or every changed gate has its entry. 1: a gate changed without one. 2: usage. 3: the check
# could not run (no merge-base, or yq missing while a YAML gate changed): it fails closed, never reads as ok.
set -uo pipefail

usage() { echo "usage: gate-change-check.sh [<base> [<head>]]" >&2; exit 2; }
cannot() { echo "gate-change-check: could not run: $*" >&2; exit 3; }
[ $# -le 2 ] || usage
case "${1:-}" in -*) usage ;; esac

base_ref="${1:-${GATE_BASE:-origin/main}}"
head="${2:-}"
git rev-parse --show-toplevel > /dev/null 2>&1 || cannot "not in a git repository"
cd "$(git rev-parse --show-toplevel)" || cannot "cannot enter the repository"
if [ -n "$head" ]; then
  git rev-parse -q --verify "$head^{commit}" > /dev/null || cannot "no commit $head"
fi
base="$(git merge-base "${head:-HEAD}" "$base_ref" 2>/dev/null)" || cannot "no merge-base of ${head:-HEAD} with $base_ref"

memory=docs/memory.md
ci=.github/workflows/ci.yml
inputs=.github/ci-inputs.yml
plan=.claude/scripts/ci-plan.sh
status=.archon/scripts/local-ci-status.sh
grammar=.claude/scripts/ci-status-grammar.sh
kit_config=.archon/kit.yaml
kit_defaults=.archon/kit.defaults.yaml

# at <side> <path>: the file at the base or the head side; empty when it does not exist there.
at() {
  if [ "$1" = base ]; then git show "$base:$2" 2>/dev/null
  elif [ -n "$head" ]; then git show "$head:$2" 2>/dev/null
  else cat "$2" 2>/dev/null
  fi
}
# changed <path>: did the path change between the two sides at all?
changed() {
  if [ -n "$head" ]; then ! git diff --quiet "$base" "$head" -- "$1"
  else ! git diff --quiet "$base" -- "$1" || [ -n "$(git ls-files --others --exclude-standard -- "$1")" ]
  fi
}
code() { grep -vE '^[[:space:]]*(#|$)' | sed -E 's/[[:space:]]+$//'; }       # shell text without comments and blanks
funcs() { # funcs <name>...: the named top-level shell functions, from `name() {` to the first `}` in column 1
  awk -v names=" $* " '
    !inside && match($0, /^[A-Za-z_][A-Za-z0-9_]*\(\)/) { n = substr($0, 1, RLENGTH - 2); if (index(names, " " n " ")) inside = 1 }
    inside { print } inside && /^}/ { inside = 0 }'
}
yq_of() { # yq_of <expr>: YAML on stdin → canonical JSON of the expression (comments are not data)
  yq -o=json -I0 "$1" - 2>/dev/null | tr -d '\r'
}
need_yq() { command -v yq > /dev/null 2>&1 || cannot "yq (mikefarah v4) is required to compare $1"; }

gates=()
gate() { gates+=("$1"); echo "gate changed: $1 ($2)"; }

if changed "$ci"; then
  need_yq "$ci"
  if [ "$(at base "$ci" | yq_of '.jobs | keys')" != "$(at head "$ci" | yq_of '.jobs | keys')" ]; then
    gate ci.yml "$ci: the job set"
  elif [ "$(at base "$ci" | yq_of '.jobs | map_values(.steps)')" != "$(at head "$ci" | yq_of '.jobs | map_values(.steps)')" ]; then
    gate ci.yml "$ci: the steps of a job"
  fi
fi
if changed "$inputs"; then
  need_yq "$inputs"
  [ "$(at base "$inputs" | yq_of '.')" != "$(at head "$inputs" | yq_of '.')" ] && gate ci-inputs.yml "$inputs"
fi
if changed "$plan"; then
  [ "$(at base "$plan" | code)" != "$(at head "$plan" | code)" ] && gate ci-plan "$plan"
fi
accept_changed=""
if changed "$status"; then
  [ "$(at base "$status" | funcs parse verify accept | code)" != "$(at head "$status" | funcs parse verify accept | code)" ] \
    && accept_changed="$status: parse, verify or accept"
fi
if [ -z "$accept_changed" ] && changed "$grammar"; then
  [ "$(at base "$grammar" | funcs ci_status_parse | code)" != "$(at head "$grammar" | funcs ci_status_parse | code)" ] \
    && accept_changed="$grammar: ci_status_parse"
fi
[ -n "$accept_changed" ] && gate local-ci-status "$accept_changed"
for f in "$kit_config" "$kit_defaults"; do
  changed "$f" || continue
  need_yq "$f"
  if [ "$(at base "$f" | yq_of '.gates // {}')" != "$(at head "$f" | yq_of '.gates // {}')" ]; then
    gate kit-gates "$f: gates"; break
  fi
done

if [ "${#gates[@]}" -eq 0 ]; then
  echo "gate-change-check: no gate changed"
  exit 0
fi

# The lines the change adds to docs/memory.md (a merge=union file: only added lines count).
if [ -n "$head" ]; then added="$(git diff -U0 "$base" "$head" -- "$memory")"
else added="$(git diff -U0 "$base" -- "$memory")"
     [ -n "$(git ls-files --others --exclude-standard -- "$memory")" ] && added="$(sed 's/^/+/' "$memory")"
fi
added="$(printf '%s\n' "$added" | grep -E '^\+' | grep -vE '^\+\+\+ ' | sed 's/^+//' | tr -d '\r')"
fail=0
if ! grep -qE '^###? [0-9]{4}-[0-9]{2}-[0-9]{2} ' <<< "$added"; then
  for g in "${gates[@]}"; do
    echo "FAIL: $g changed, but the change adds no decision entry (a dated '## <yyyy-mm-dd> — …' or '### <yyyy-mm-dd> — …' heading) to $memory"
  done
  exit 1
fi
for g in "${gates[@]}"; do
  names="$g"
  [ "$g" = local-ci-status ] && names="local-ci-status ci-status-grammar"
  hit=""
  for n in $names; do grep -qF -- "$n" <<< "$added" && hit=1; done
  if [ -z "$hit" ]; then
    echo "FAIL: $g changed, but the decision entry this change adds to $memory does not name it ($g)"
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "gate-change-check: ok"
exit "$fail"
