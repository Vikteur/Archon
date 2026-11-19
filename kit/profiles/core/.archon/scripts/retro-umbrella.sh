# Sourced by the retro scripts: find_umbrella sets $umbrella to the docs home (the checkout with docs/retro/README.md:
# retros, ADRs, run archives and token reports live there), as a POSIX path, or returns 1. The name is historical: it
# was the umbrella repo weddingapp until its docs moved into wedding-portal (2026-10-17), so it is now this repo's own
# main checkout. UMBRELLA_CWD names it; otherwise it is searched in and beside the current repo's main checkout,
# because a retro is committed there, never in a run worktree.
find_umbrella() {
  local main dir
  umbrella=${UMBRELLA_CWD:-}
  if [ -z "$umbrella" ]; then
    main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    for dir in "$main" "$main"/../*; do
      if [ -n "$main" ] && [ -f "$dir/docs/retro/README.md" ]; then umbrella=$dir; break; fi
    done
  fi
  if [ -z "$umbrella" ]; then
    echo "No docs home (docs/retro/README.md) found in or beside ${main:-this repo}; set UMBRELLA_CWD to it." >&2
    return 1
  fi
  # A POSIX path: a workflow assigns this unquoted, which would eat the backslashes of C:\...
  umbrella=$(cd "$umbrella" && pwd)
}
