#!/usr/bin/env bash
# Close a merged ticket out (P2: a script, not a model): commit and push its Backlog files, pull main, and delete the
# run's branch and worktree.
#   close-out.sh <TASK id or empty> <pull request url> <backlog dir>
#   close-out.sh --finish <TASK id or empty> <pull request url> <backlog dir>
# Runs after `finalize` set the ticket Done. The merge was the approval for exactly these steps (UD-21.c; the GitHub agent's
# auto-merge since 2026-10-17):
# only the ticket's and its parent's Backlog files are committed, and only the pull request's own branch is deleted.
# Every step runs; a failed one is reported and fails the node at the end, so a later step is never skipped silently.
# Prints one JSON line {"backlog": "<commit or empty>", "branch": "deleted|kept", "worktree": "removed|kept"}.
# The result is judged by the STATE left behind (worktree list, branch refs, folder), never by `archon complete`'s exit
# code: it exits 0 on a half-removed or locked worktree. After archon, an empty or locked-empty worktree folder is
# removed (rmdir, a few short retries) and pruned, and the branch is deleted. A failure prints the exact `--finish`
# command; `--finish` redoes only this cleanup (no Backlog commit, no pull) and is safe to run again.
# No step stops any process outside the worktree being closed: a folder some process holds is reported, not unlocked.
# The token reports wait while another run's pull request is open (R14): a docs/tokenomics commit on main makes every
# open run pull request behind. The reports are cumulative, so the first close-out that finds no other run pull request
# open (a build-feature-* or task-build-feature-* head) commits them all; when gh cannot tell, they wait too.
#   close-out.sh --flush-reports
# does only that step, from the main checkout, for when no close-out comes after the last merge: prints
# {"reports": "committed|deferred|failed|none"}; exit 1 only when the report script failed.
# The Backlog commit is pushed only when .claude/scripts/groma-delta.sh finds no new Groma FAIL line in it against
# origin/main (CI plan C7; GROMA_DELTA names that script, tests stub it). A push rejected because main moved on is rebased
# once, checked again and pushed again (C1). A commit that does not land is undone (its change stays staged), so no
# local commit is left on main.
# Every main commit gets a local CI verdict (CI plan C13): once main is pulled, the Backlog commit and main's tip are each
# handed to local-ci-run.sh <sha> --no-wait (LOCAL_CI_RUN names it, tests stub it), which starts local CI in the
# background on a commit with no local-ci status yet and leaves one that has a status alone. Then the daily CI audit
# runs (.claude/scripts/ci-audit.sh daily --no-wait; CI_AUDIT names it): it checks reused statuses on main against the
# ledger and starts the daily full run of main without reuse when the last one is over 24 h old (D2). Both run from the
# main checkout, as this run's worktree is deleted below; neither ever fails this node, a failure is a warning.
# Each sub-step that runs logs `close-out: <step> took <n>s` on stderr (backlog, pull, local-ci, reports, cleanup; owner
# decision 2026-10-23, docs/memory.md: close-out took 4 to 19 min and nothing said where).
set -euo pipefail
# Only the JSON line goes to stdout (fd 3); everything else, git hooks' output included (the pre-push hook prints
# its Groma check), goes to stderr.
exec 3>&1 1>&2
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
t0=$SECONDS
took() { echo "close-out: $1 took $((SECONDS - t0))s" >&2; t0=$SECONDS; } # <step>: the time since the last one

run_prs_open() { # [<own pr number>]: prints the open run pull requests but that one; 0 = some, or gh failed; 1 = none
  local list
  list=$(gh pr list --state open --json number,headRefName \
    -q '.[] | select(.headRefName | test("^(task-)?build-feature-")) | .number' 2> /dev/null) \
    || { echo "unknown (gh pr list failed)"; return 0; }
  list=$(printf '%s\n' "$list" | grep -vx "${1:-}" | grep -E '^[0-9]+$' | sed 's/^/#/' | tr '\n' ' ' || true)
  [ -n "$list" ] || return 1
  echo "${list% }"
}

# Update and commit the token and cost reports (TASK-41) in the docs home (see retro-umbrella.sh). Only a warning when it
# fails: it never fails a close-out, and its JSON line goes to stderr. Sets reports to committed, deferred, failed or none.
flush_reports() { # [<own pr number>]
  local open
  reports=none
  . "$(dirname "$self")/retro-umbrella.sh"
  find_umbrella 2> /dev/null && [ -f "$umbrella/scripts/tokenomics/commit-reports.sh" ] || return 0
  if open=$(run_prs_open "${1:-}"); then
    echo "token reports deferred: run pull requests $open are open; the last close-out (or close-out.sh --flush-reports) commits them." >&2
    reports=deferred
  elif bash "$umbrella/scripts/tokenomics/commit-reports.sh" "$umbrella" >&2; then
    reports=committed
  else
    echo "warning: the token reports were not committed." >&2
    reports=failed
  fi
}

if [ "${1:-}" = --flush-reports ]; then
  flush_reports
  node -e 'console.log(JSON.stringify({ reports: process.argv[1] }))' "$reports" >&3
  [ "$reports" != failed ]
  exit
fi

finish=0
if [ "${1:-}" = --finish ]; then finish=1; shift; fi
task=$1 pr=$2 home=$3
here=$(pwd)
main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
here_git=$(git -C "$here" rev-parse --show-toplevel)   # git's spelling of the path, as `worktree list` prints it
delta=${GROMA_DELTA:-$(dirname "$self")/../../.claude/scripts/groma-delta.sh}
run_ci=${LOCAL_CI_RUN:-$(dirname "$self")/local-ci-run.sh}
audit=${CI_AUDIT:-$(dirname "$self")/../../.claude/scripts/ci-audit.sh}
failed=""
left_empty=0

registered() { # <dir>: is it a worktree git still lists?
  git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p' | grep -qxF "$1"
}

has_files() { # <dir>: is it a directory that holds anything?
  [ -d "$1" ] && [ -n "$(ls -A "$1")" ]
}

remove_empty_dir() { # <dir>: rmdir an empty folder with a few short retries (a closing handle may still hold it)
  local i
  for i in 1 2 3 4; do
    [ -d "$1" ] || return 0
    rmdir "$1" 2> /dev/null && return 0
    sleep 0.2
  done
  [ ! -d "$1" ]
}

push_backlog() { # push the Backlog commit at HEAD of $home; sets why and undoes the commit when it does not land
  why=""
  if ! (cd "$home" && bash "$delta" HEAD origin/main); then
    why="the Groma check refused it (see above)"
  elif git -C "$home" push -q origin main; then
    return 0
  elif ! git -C "$home" pull -q --rebase --autostash origin main; then
    git -C "$home" rebase --abort 2> /dev/null || true
    why="the push was rejected and the commit could not be rebased onto origin/main"
  elif ! (cd "$home" && bash "$delta" HEAD origin/main); then
    why="the Groma check refused it after the rebase (see above)"
  elif git -C "$home" push -q origin main; then
    return 0
  else
    why="the push was rejected again after a rebase"
  fi
  git -C "$home" reset -q --soft HEAD~1 || why="$why; undoing the local commit failed, main has a commit not on origin"
  return 1
}

field() { # <task id> <field>: one field of a Backlog task, read through the CLI
  BACKLOG_CWD=$home backlog task view "$1" --json | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      const v = JSON.parse(s).task[process.argv[1]]; console.log(v == null ? "" : v);
    });' "$2"
}

number=$(gh pr view "$pr" --json number -q .number)
head=$(gh pr view "$pr" --json headRefOid -q .headRefOid)
branch=$(gh pr view "$pr" --json headRefName -q .headRefName)
repo=$(printf '%s' "$pr" | sed -E 's#^https://github.com/[^/]+/([^/]+)/pull/.*#\1#')

# 1. Commit and push the ticket's Backlog files on the backlog checkout's main. That checkout is often this repo's own
# main checkout, which the merge just moved on: it is pulled first, so the push is not rejected.
backlog_commit="" backlog_sha=""
if [ -n "$task" ] && [ "$finish" -eq 0 ]; then
  status=$(field "$task" status)
  if [ "$status" != Done ]; then
    echo "finalize left $task at '$status': nothing is committed or deleted." >&2
    exit 1
  fi
  files=("$(field "$task" path)")
  parent=$(field "$task" parentTaskId)
  subject="backlog: $task done"
  if [ -n "$parent" ]; then
    files+=("$(field "$parent" path)")
    [ "$(field "$parent" status)" = Done ] && subject="backlog: $task and epic $parent done"
  fi
  if [ "$(git -C "$home" symbolic-ref --short HEAD)" != main ]; then
    failed="$failed; the backlog checkout $home is not on main, so the Backlog change is not committed"
  elif ! git -C "$home" pull -q --ff-only origin main; then
    failed="$failed; pulling main in $home failed, so the Backlog change is not committed"
  elif git -C "$home" diff --quiet HEAD -- "${files[@]}"; then
    echo "No Backlog change to commit for $task." >&2
  elif ! git -C "$home" commit -q -m "$subject ($repo PR #$number merged, CI green on ${head:0:7})" -- "${files[@]}"; then
    failed="$failed; the Backlog commit in $home failed"
  elif push_backlog; then
    backlog_commit=$(git -C "$home" rev-parse --short HEAD)
    backlog_sha=$(git -C "$home" rev-parse HEAD)
  else
    failed="$failed; the Backlog change in $home is not pushed: $why; it is staged, not committed"
  fi
fi
[ "$finish" -eq 1 ] || took backlog

# 2. Bring the main checkout up to date with the merge.
if [ "$finish" -eq 1 ]; then
  :
elif [ "$(git -C "$main" symbolic-ref --short HEAD)" = main ]; then
  git -C "$main" pull -q --ff-only origin main || failed="$failed; pulling main in $main failed"
else
  echo "$main is not on main; not pulled." >&2
fi
[ "$finish" -eq 1 ] || took pull

# 2b. A local CI verdict on every main commit this close-out made or brought in (C13), then the daily audit (D2). The
# Backlog commit counts only when the backlog checkout is this repository (its git dir is the main checkout's).
if [ "$finish" -eq 0 ]; then
  shas=()
  if [ -n "$backlog_sha" ] \
      && [ "$(cd "$home" && cd "$(git rev-parse --git-common-dir)" && pwd)" = "$(cd "$main" && cd "$(git rev-parse --git-common-dir)" && pwd)" ]; then
    shas+=("$backlog_sha")
  fi
  tip=$(git -C "$main" rev-parse -q --verify origin/main 2> /dev/null || true)
  [ -n "$tip" ] && [ "$tip" != "$backlog_sha" ] && shas+=("$tip")
  for s in "${shas[@]}"; do
    (cd "$main" && bash "$run_ci" "$s" --no-wait >&2) \
      || echo "warning: local CI was not started on ${s:0:7}; run local-ci-run.sh $s" >&2
  done
  (cd "$main" && bash "$audit" daily --no-wait >&2) || echo "warning: the daily CI audit did not run; run ci-audit.sh daily" >&2
  took local-ci
fi

# The token and cost reports (TASK-41), unless another run's pull request is open (flush_reports above).
flush_reports "$number"
took reports

# 3. Delete the pull request's own branch and the run's worktree. This node runs inside the still-running workflow, so
# plain `archon complete` always refuses ("running workflow"); `--force` is needed, but it also skips archon's other
# checks (commits not pushed, commits unique to the branch, uncommitted changes). So this script does its own guard
# first and only forces when the local branch tip is exactly the merged PR head and the run worktree is clean
# (UD-21.c as amended 2026-10-09); otherwise archon is not called and the branch and worktree are kept and reported.
# `git branch -D` below is likewise only reached after that tip guard proved the branch equals the merged head (a
# squash merge leaves the branch unmerged in git's eyes, so the lowercase -d would refuse).
# First sweep the empty directories earlier runs left in the worktrees parent (rmdir only: a non-empty directory or a
# registered worktree is never touched).
# Skipped when this runs from the main checkout: its siblings are not worktrees.
wtdir=$(git -C "$main" worktree list --porcelain \
  | awk -v b="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $1=="branch" && $2==b {print w}')
if [ -z "$wtdir" ] && [ "$here_git" != "$main" ]; then
  wtdir=$here_git
fi
[ "$wtdir" = "$main" ] && wtdir=""
if [ -n "$wtdir" ] && [ "$here_git" != "$main" ]; then
  for leftover in "$(dirname "$wtdir")"/*/; do
    leftover=${leftover%/}
    [ "$leftover" = "$wtdir" ] && continue
    registered "$leftover" || rmdir "$leftover" 2> /dev/null || true
  done
fi
case "$branch" in
  main|master|"") failed="$failed; refusing to delete branch '$branch'" ;;
  *)
    tip=$(git -C "$main" rev-parse --verify -q "refs/heads/$branch" || true)
    if [ -z "$tip" ]; then
      tip=$(git -C "$main" ls-remote origin "refs/heads/$branch" 2> /dev/null | cut -f1 || true)
    fi
    if [ -z "$tip" ] && [ -n "$wtdir" ] && has_files "$wtdir"; then
      tip=$(git -C "$wtdir" rev-parse HEAD || true)
    fi
    dirty=""
    if [ -n "$wtdir" ] && has_files "$wtdir"; then
      dirty=$(git -C "$wtdir" status --porcelain 2> /dev/null || echo "status failed")
    fi
    if [ -n "$tip" ] && [ "$tip" != "$head" ]; then
      failed="$failed; branch tip $tip is not the merged head $head"
    elif [ -n "$dirty" ]; then
      failed="$failed; worktree $wtdir has uncommitted changes"
    else
      cd "$main"
      if [ "$finish" -eq 0 ] && { [ -n "$tip" ] || { [ -n "$wtdir" ] && registered "$wtdir"; }; }; then
        # The exit code is not trusted: only the state below counts.
        archon complete --force "$branch" >&2 || true
      fi
      # Finish what archon may have left: an empty (or locked-empty) folder, a registration, the branch.
      if [ -n "$wtdir" ]; then
        if [ -d "$wtdir" ] && ! has_files "$wtdir"; then
          remove_empty_dir "$wtdir" || true
        fi
        git -C "$main" worktree prune >&2 || true
        if registered "$wtdir"; then
          if has_files "$wtdir"; then
            failed="$failed; worktree $wtdir is still registered and holds files"
          else
            failed="$failed; worktree $wtdir is still registered (its empty folder is locked)"
          fi
        elif has_files "$wtdir"; then
          failed="$failed; $wtdir is no longer a worktree but still holds files"
        elif [ -d "$wtdir" ]; then
          echo "warning: git no longer lists $wtdir; the empty directory $wtdir is left behind (a process still holds it): it is not unlocked here; delete it once that process ends." >&2
          left_empty=1
        fi
      fi
      if [ -z "$failed" ] || [ -z "$wtdir" ] || { ! registered "$wtdir" && ! has_files "$wtdir"; }; then
        if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
          git -C "$main" branch -D "$branch" >&2 || failed="$failed; deleting local branch $branch failed"
        fi
        if git -C "$main" ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
          git -C "$main" push -q origin --delete "$branch" || failed="$failed; deleting origin/$branch failed"
        fi
      fi
    fi
    ;;
esac
branch_state=deleted worktree_state=removed
if git -C "$main" ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1 \
    || git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
  branch_state=kept
fi
if [ -n "$wtdir" ] && [ -d "$wtdir" ] && [ "$left_empty" -eq 0 ]; then
  worktree_state=kept
fi
took cleanup

node -e 'const [backlog, branch, worktree] = process.argv.slice(1);
  console.log(JSON.stringify({ backlog, branch, worktree }));' "$backlog_commit" "$branch_state" "$worktree_state" >&3

if [ -n "$failed" ] || [ "$branch_state" = kept ] || [ "$worktree_state" = kept ]; then
  echo "Close-out incomplete${failed:+:${failed#;}}. Run the cleanup again: $(printf '%q ' bash "$self" --finish "$task" "$pr" "$home")" >&2
  exit 1
fi
