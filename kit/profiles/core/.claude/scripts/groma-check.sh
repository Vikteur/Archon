#!/usr/bin/env bash
# Checks the Groma architecture map under groma/ (TASK-36): set up for the Java scanner, curated rather than a first
# scan, every element described, in sync with the source (a fresh scan changes nothing), and loaded into agent sessions
# beside this repo's own Backlog.md tickets. (The browser view, with the backlog attached, is
# scripts/web-uis.sh.)
# Needs the groma CLI (npm install -g groma.md) and a clean groma/ in the work tree, because it rescans. GROMA names
# the CLI (default: groma). Whatever the scan leaves in groma/ is undone when the script ends, however it ends.
# A repo without groma/ has not set Groma up: the script prints a notice (a GitHub Actions ::notice:: in Actions) and
# passes, so neither the pre-push hook nor CI blocks on a map the project does not keep. `backlog: false` in
# .archon/kit.yaml (else in kit.defaults.yaml beside it; env KIT_BACKLOG first) drops the two Backlog.md checks.
# Usage: groma-check.sh
set -euo pipefail

groma="${GROMA:-groma}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
failures=0

if [[ ! -d groma ]]; then
  notice="groma-check: not set up: run groma init (no groma/ folder, so the map checks are skipped)"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::notice::$notice"; else echo "$notice"; fi
  exit 0
fi

# Backlog.md is optional (as scripts/install-tools.sh reads it: sed, since yq may not be installed): off drops the
# ticket checks below.
use_backlog="${KIT_BACKLOG:-}"
for f in .archon/kit.yaml .archon/kit.defaults.yaml; do
  [[ -z "$use_backlog" ]] || break
  [[ -f "$f" ]] && use_backlog=$(sed -n 's/^backlog:[[:space:]]*["'"'"']\{0,1\}\([a-z01]*\).*/\1/p' "$f" | head -n 1)
done
case "$use_backlog" in false | 0 | no | off) use_backlog=0 ;; *) use_backlog=1 ;; esac

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

echo "Check: groma/ scans the Java source"
if [[ ! -f groma/scanners.json ]]; then
  fail "groma/scanners.json is missing; run groma init"
elif ! grep -q '"id": *"java"' groma/scanners.json; then
  fail "groma/scanners.json has no java scanner"
fi

echo "Check: the map is curated, not a first scan"
if [[ -d groma ]] && "$groma" agent-instructions 2>/dev/null | head -1 | grep -q 'still its first scan'; then
  fail "groma agent-instructions reports a first scan; curate the map"
fi

echo "Check: every element has a description"
while IFS= read -r file; do
  if ! sed -n '/^---$/,/^---$/p' "$file" | grep -qE '^description: *[^ ]'; then
    fail "$file has no description"
  fi
done < <(grep -rlE '^type: (C4|Person|External)' groma 2>/dev/null || true)

echo "Check: a fresh scan changes nothing under groma/"
if [[ -d groma ]]; then
  if [[ -n "$(git status --porcelain -- groma)" ]]; then
    fail "groma/ has uncommitted changes; commit or discard them before this check"
  else
    # groma/ is clean here, so putting it back to the committed state on exit only removes what the scan wrote: a scan
    # that fails or is interrupted (Ctrl-C) must not leave a half-written map for the next push to trip over.
    restore_groma() { git checkout -q -- groma 2>/dev/null && git clean -qfd -- groma 2>/dev/null || true; }
    trap restore_groma EXIT
    trap 'exit 1' INT TERM HUP
    if ! "$groma" scan >/dev/null; then
      fail "groma scan failed"
    elif [[ -n "$(git status --porcelain -- groma)" ]]; then
      fail "a fresh groma scan changed groma/: $(git status --porcelain -- groma | tr '\n' ' ')"
    fi
    restore_groma
  fi
fi

echo "Check: every open ticket is pinned to the map"
[[ "$use_backlog" == 1 ]] || echo "  skipped: backlog: false (Backlog.md is off)"
# The board shows a ticket only when its references name a map element id exactly; a ticket that names none is
# invisible there ("No mapped tasks"). Open means To Do or In Progress; epics (label epic) group tickets and need none.
if [[ "$use_backlog" == 1 && -d backlog/tasks ]]; then
  # A map with no element yet matches nothing: without `|| true`, set -e and pipefail ended the script here, silently.
  ids=" $({ grep -rh -A1 '^groma:' groma || true; } | sed -n 's/^ *id: *//p' | tr -d "\"'\r" | tr '\n' ' ')"
  # One awk reads every ticket's front matter itself (getline), and prints the open, non-epic ones whose references
  # name no map id. A shell loop per ticket started several processes each, which took half a minute on Windows.
  while IFS= read -r file; do
    fail "$file references no map element; add one with backlog task edit <id> --add-ref <element id>"
  done < <(find backlog/tasks -name '*.md' | sort | awk -v ids="$ids" '
    {
      file = $0; front = 0; open = 0; epic = 0; inrefs = 0; pinned = 0
      while ((getline line < file) > 0) {
        sub(/\r$/, "", line)
        if (!front) { if (line == "---") { front = 1; continue } else break }
        if (line == "---") break
        if (line ~ /^status: *(To Do|In Progress)/) open = 1
        if (line ~ /^ *- *epic *$/) epic = 1
        if (line ~ /^references:/) { inrefs = 1; continue }
        if (inrefs && line ~ /^[a-z_]*:/) inrefs = 0
        if (inrefs && line ~ /^ *- */) {
          ref = line; sub(/^ *- */, "", ref); sub(/ *$/, "", ref); gsub(/^["\047]|["\047]$/, "", ref)
          if (index(ids, " " ref " ")) pinned = 1
        }
      }
      close(file)
      if (open && !epic && !pinned) print file
    }')
fi

echo "Check: agent sessions load Groma's instructions and find the tickets"
if ! grep -qx '@AGENTS.md' CLAUDE.md 2>/dev/null; then
  fail "CLAUDE.md does not import AGENTS.md"
fi
if ! grep -q 'groma agent-instructions' AGENTS.md 2>/dev/null; then
  fail "AGENTS.md has no Groma block"
fi
if [[ "$use_backlog" == 1 ]] && ! grep -q 'Backlog.md backlog' AGENTS.md 2>/dev/null; then
  fail "AGENTS.md does not say the tickets live in this repo's Backlog.md backlog"
fi

if ((failures > 0)); then
  echo "groma-check: $failures failed" >&2
  exit 1
fi
echo "groma-check: all passed"
