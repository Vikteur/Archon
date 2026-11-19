#!/usr/bin/env bash
# Build the plan node's context pack (P2: a script, not a model): the facts every plan looked up on its own, read once.
#   plan-context.sh <ticket.md>
# Writes Markdown to stdout: the dependency tickets (title, status, final summary), the Gradle modules and what each one
# depends on, the build-feature nodes, the sections of docs/memory.md with their line numbers, the docs/code-maps
# leaves, every script's header line and test, the contract operations the ticket names with where they live in the
# code (scripts/portal-mcp/plan-ops.mjs, docs/mcp/plan.md C2), and the last 10 commits. Run from the root of the run's
# checkout. The operations need the portal-api server's node_modules and contract/dist/openapi.yaml (mcp-setup.sh); without
# them, or when the ticket names no operation, that section is left out.
# The section list is what 16 plan nodes read most (2026-10-18): build-feature.yaml in 15, the build files in 14,
# docs/memory.md in 13, and a script's header to learn its flags in most.
#
# The Backlog is read from the main checkout that holds backlog/, never from the run's worktree (as ticket.sh finds
# it). BACKLOG_CWD overrides. A ticket without dependencies, or no Backlog at all, leaves that section out.
set -euo pipefail

ticket="${1:?usage: plan-context.sh <ticket.md>}"
deps=$(sed -n 's/^Depends on: //p' "$ticket" 2>/dev/null | head -1 | grep -oE 'TASK-[0-9]+(\.[0-9]+)*' || true)

echo "# Plan context"
echo
echo "_Built by .archon/scripts/plan-context.sh from this checkout. Read a file only for what this does not say._"

if [ -n "$deps" ]; then
  if [ -z "${BACKLOG_CWD:-}" ]; then
    main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
    for dir in "$main" "$main"/../*; do
      if [ -f "$dir/backlog/config.yml" ]; then BACKLOG_CWD=$(cd "$dir" && pwd); break; fi
    done
  fi
  if [ -n "${BACKLOG_CWD:-}" ]; then
    export BACKLOG_CWD
    echo
    echo "## Dependencies"
    for id in $deps; do
      json=$(backlog task view "$id" --json 2>/dev/null) || json=""
      if [ -z "$json" ]; then printf '\n- **%s**: not in the Backlog\n' "$id"; continue; fi
      printf '%s' "$json" | node -e '
        let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
          const t = JSON.parse(s).task;
          const sum = String(t.finalSummary || "").replace(/\s+/g, " ").trim();
          console.log(`\n- **${t.id}** (${t.status}) ${t.title}`);
          if (sum) console.log(`  ${sum.length > 700 ? sum.slice(0, 700) + "…" : sum}`);
        });'
    done
  fi
fi

if [ -f settings.gradle.kts ]; then
  echo
  echo "## Gradle modules (settings.gradle.kts) and the modules each one depends on"
  echo
  # A module's own name (its testFixtures) and repeats are left out.
  mods=$(sed -n '/^include(/,/)/p' settings.gradle.kts | grep -oE '"[^"]+"' | tr -d '"' | sed 's/^://')
  for m in $mods; do if [ -f "$m/build.gradle.kts" ]; then echo "$m/build.gradle.kts"; fi; done | xargs -r awk '
    FNR == 1 { if (m != "") print "- " m (on != "" ? " → " on : ""); m = FILENAME; sub(/\/build\.gradle\.kts$/, "", m); on = ""; delete seen }
    { while (match($0, /project\("[^"]+"\)/)) { d = substr($0, RSTART + 9, RLENGTH - 11); $0 = substr($0, RSTART + RLENGTH)
        if (d != ":" m && !seen[d]++) on = on (on == "" ? "" : " ") d } }
    END { if (m != "") print "- " m (on != "" ? " → " on : "") }'
  for m in $mods; do if [ ! -f "$m/build.gradle.kts" ]; then echo "- $m"; fi; done
fi

wf=.archon/workflows/build-feature.yaml
if [ -f "$wf" ]; then
  echo
  echo "## build-feature nodes (id ← depends_on; indented: inside the node above), from $wf"
  echo
  awk '
    function flush() { if (id != "") print pad "- " id (dep != "" ? " ← " dep : ""); id = ""; dep = "" }
    /^ *- id: / { flush(); match($0, /^ */); pad = RLENGTH > 2 ? "  " : ""; sub(/^ *- id: */, ""); id = $0; next }
    /^ *depends_on: *\[/ && id != "" { d = $0; sub(/^[^[]*\[/, "", d); sub(/\].*$/, "", d); dep = d }
    END { flush() }' "$wf"
fi

if [ -f docs/memory.md ]; then
  echo
  echo "## docs/memory.md sections (line: heading), read with an offset"
  echo
  grep -nE '^##+ ' docs/memory.md | sed -E 's/^([0-9]+):#+ /- \1: /'
fi

if [ -d docs/code-maps ]; then
  echo
  echo "## docs/code-maps leaves"
  echo
  # shellcheck disable=SC2012
  ls docs/code-maps/*.md 2>/dev/null | sed 's#.*/##; s#\.md$##' | grep -v '^README$' | tr '\n' ' ' | sed 's/ $/\n/'
fi

echo
echo "## Scripts: what each one does (its header's first sentence), its usage line, its test"
files=()
for dir in .claude/scripts .archon/scripts scripts; do
  for f in "$dir"/*.sh "$dir"/*.js "$dir"/*.mjs; do if [ -f "$f" ]; then files+=("$f"); fi; done
done
# One awk pass over every script (a fork per script costs ~9 s on Windows): the header comment up to its first sentence,
# and the first comment line that starts with the script's own name or `Usage:`.
[ ${#files[@]} -eq 0 ] || awk '
  function out() { if (f != "") printf "%s\t%s\t%s\n", f, head, usage }
  FNR == 1 { out(); f = FILENAME; head = ""; usage = ""; done = 0; n = split(f, p, "/"); base = p[n]; sub(/\.[^.]*$/, "", base) }
  FNR > 25 { next }
  /^(#|\/\/) / {
    line = $0; sub(/^(#|\/\/) +/, "", line)
    if (usage == "" && (tolower(substr(line, 1, 6)) == "usage:" || index(line, base ".") == 1 || index(line, "/" base ".") > 0 && line !~ / /)) {
      u = line; sub(/^[Uu]sage: */, "", u); if (u ~ base "\\.") usage = u
    }
    if (!done) {
      head = head (head == "" ? "" : " ") line
      if (match(head, /[a-z)`][.] [A-Z(]/) || match(head, /[a-z)`][.]$/)) { head = substr(head, 1, RSTART + 1); done = 1 }
      else if (length(head) > 240) { head = substr(head, 1, 240) "…"; done = 1 }
    }
    next
  }
  head != "" { done = 1 }
  END { out() }' "${files[@]}" | while IFS=$'\t' read -r f head usage; do
  dir="${f%/*}"; base="${f##*/}"; base="${base%.*}"; test=""
  for t in "$dir/test/$base.test.sh" "scripts/test/$base.test.sh"; do if [ -f "$t" ]; then test="$t"; break; fi; done
  printf '\n- `%s`: %s\n' "$f" "$head"
  [ -z "$usage" ] || printf '  usage: `%s`\n' "$usage"
  [ -z "$test" ] || printf '  test: `%s`\n' "$test"
done

if [ -f "$ticket" ] && [ -f contract/dist/openapi.yaml ] && [ -d scripts/portal-mcp/node_modules ] \
  && [ -f scripts/portal-mcp/plan-ops.mjs ]; then
  if ops=$(node scripts/portal-mcp/plan-ops.mjs "$ticket" . 2>/dev/null) && [ -n "$ops" ]; then
    echo
    printf '%s\n' "$ops"
  fi
fi

echo
echo "## Last 10 commits"
echo
git log -10 --format='- %h %s' 2>/dev/null || true
