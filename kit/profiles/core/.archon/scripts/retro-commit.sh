#!/usr/bin/env bash
# Check and commit a run's retro on the docs home's main (P2: a script, not a model).
#   retro-commit.sh <docs home> <retro folder, e.g. docs/retro/TASK-7> <run id>
# The gate: lessons-learned.md has a "## Run <id8> — <date> — <outcome>" section with every heading of the retro skill's
# template filled in, and every adr/ADR-NN-<slug>.md has its "# ADR-NN: <title>" line and every section, and is linked
# from lessons-learned.md. Then it regenerates the index in docs/retro/README.md and commits only the retro folder and
# that index; anything else changed in the docs home is left alone. The commit is pushed only when
# .claude/scripts/groma-delta.sh finds no new Groma FAIL line in it against origin/main (CI plan C7; GROMA_DELTA names
# that script, tests stub it). A push rejected because main moved on is rebased once, checked again and pushed again.
# A commit that does not land is undone, its files left staged, so main keeps no local commit and a resumed run commits
# it again. A failed gate commits nothing: fix the files and resume the run.
# After its own commit it refreshes the token reports (bash scripts/tokenomics/commit-reports.sh, TASK-41; through bash,
# as git checks it out without the execute bit, TASK-74): only a warning
# when that fails, its JSON line goes to stderr so that the line printed below stays the last one on stdout.
# A pushed retro commit gets a local CI verdict (CI plan C13): local-ci-run.sh <commit> --no-wait starts local CI in the
# background, from the docs home, when the docs home is the repository it runs in (LOCAL_CI_RUN names it, tests stub it); a start
# that fails is a warning only.
# Prints one JSON line {"commit": "<short sha, or empty when there was nothing to commit>"}.
set -euo pipefail
home=$1 dir=$2 run=$3
id8=${run:0:8}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
index=docs/retro/README.md
delta=${GROMA_DELTA:-$here/../../.claude/scripts/groma-delta.sh}
run_ci=${LOCAL_CI_RUN:-$here/local-ci-run.sh}

common() { (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd) 2>/dev/null; }

push_retro() { # push the retro commit at HEAD of $home; sets why when it does not land
  why=""
  if ! (cd "$home" && bash "$delta" HEAD origin/main); then
    why="the Groma check refused it (see above)"
  elif git -C "$home" push -q origin main 2>/dev/null; then
    return 0
  elif ! git -C "$home" pull -q --rebase --autostash origin main; then
    git -C "$home" rebase --abort 2>/dev/null || true
    why="it could not be rebased onto origin/main"
  elif ! (cd "$home" && bash "$delta" HEAD origin/main); then
    why="the Groma check refused it after the rebase (see above)"
  elif git -C "$home" push -q origin main; then
    return 0
  else
    why="the push was rejected again after a rebase"
  fi
  return 1
}

if [ "$(git -C "$home" symbolic-ref --short HEAD 2>/dev/null || true)" != main ]; then
  echo "The docs checkout $home is not on main, so the retro is not committed." >&2
  exit 1
fi
node "$here/retro.js" gate "$home" "$dir" "$id8"
node "$here/retro.js" index "$home"

git -C "$home" add -- "$dir" "$index"
commit=""
if git -C "$home" diff --cached --quiet -- "$dir" "$index"; then
  echo "No retro change to commit in $dir." >&2
else
  git -C "$home" commit -q -m "retro: ${dir#docs/retro/} lessons learned and ADRs (run $id8)" -- "$dir" "$index"
  if ! push_retro; then
    if git -C "$home" reset -q --soft HEAD~1; then
      echo "The retro is not pushed: $why. It is not committed either; its files stay staged." >&2
    else
      echo "The retro is not pushed: $why. Undoing the local commit failed: main has a commit not on origin." >&2
    fi
    exit 1
  fi
  commit=$(git -C "$home" rev-parse --short HEAD)
  if [ "$(common "$home")" = "$(common "$PWD")" ]; then
    sha=$(git -C "$home" rev-parse HEAD)
    (cd "$home" && bash "$run_ci" "$sha" --no-wait >&2) \
      || echo "warning: local CI was not started on ${sha:0:7}; run local-ci-run.sh $sha" >&2
  fi
fi
if [ -f "$home/scripts/tokenomics/commit-reports.sh" ]; then
  bash "$home/scripts/tokenomics/commit-reports.sh" "$home" >&2 || echo "warning: the token reports were not committed." >&2
fi
node -e 'console.log(JSON.stringify({ commit: process.argv[1] }))' "$commit"
