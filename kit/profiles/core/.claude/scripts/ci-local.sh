#!/usr/bin/env bash
# Local CI, the CI verdict of this repo (owner decisions 2026-10-18 and D14 2026-10-20, docs/memory.md): GitHub Actions
# runs no job, so this runs every step of every job of .github/workflows/ci.yml on this machine.
#   ci-local.sh [--post] [--force] [--keep] [--all] [--audit] [--rerun-failed] [--jobs a,b] [<sha>|<pr-number>|<pr-number>:<sha>]
# The workflow is read from the commit under test, so the runner follows CI as it changes. Each job gets its own
# clean, detached worktree of the commit (never the current checkout); a pull request is tested as CI tests it, merged
# into its base. All jobs run side by side, each job's steps in order (owner decision 2026-10-18); the jobs listed in
# CI_LOCAL_SERIAL (e.g. "test archon-scripts") run one after the other instead.
#   --post   post one GitHub commit status per job on the commit, context local-ci/<job> (pending at the start, then
#            success or failure): the result by SHA that ci-by-sha.sh reads. Needs every job.
#   --force  with --post, run even when the commit has a finished local CI run or a live one (queued behind it, never
#            attached).
#   --keep   keep the job worktrees (test reports stay in them); by default they are removed after the run.
#   --jobs   run only these jobs (a quick check; cannot be combined with --post).
#   --all    run the .archon test suites even when the change does not touch them (see below), and reuse nothing.
#   --audit  reuse nothing, and run each job's steps (not the WSL ones) under ci-plan.sh --audit-run --record: a read
#            outside the job's inputs is recorded as a violation and stops that job's reuse (<job>.audit.<i> reports).
#   --rerun-failed  (D4) on the same commit and the same tested tree as the latest run of it, keep that run's green
#            jobs (their status is posted again, a `kept` ledger event) and run only the red and missing ones.
#            With CI_LOCAL_RERUN_AFTER=<sig> (red-triage.sh), a rerun job that goes green says
#            `; green on rerun after <sig>` on its status (a pass; ci-status-grammar.sh parses it as rerun=<sig>).
# Writes <job>.log and summary.txt to $CI_LOCAL_ROOT/<sha7> (default: ci-local/ beside the main checkout). Exit 0 only
# when every job passed, or when a plain --post ran nothing (a finished or live commit, see below).
# A job with needs: waits for the result of each needed job and runs only when all succeeded; otherwise it fails with
# "not run: needed job <name> failed" and runs no step, so a skipped job posts failure. A need that can never be met
# fails the job at once: a job not in the workflow or not in this run, a cycle, or a serial job queued after it.
# Steps the runner cannot reproduce fail, so a new kind of step is noticed: an unknown action or ${{ }} expression.
# The ones it knowingly does not run are reported "skipped-locally", never "passed":
#   - "Contract token is read-only": checks the CI secret's scope; locally the contract is cloned with gh's own login.
#   - actions/cache, upload-artifact: the local caches (~/.gradle, the job's .gradle) stay, reports stay in the
#     worktree.
# One step runs only when the change needs it (owner decision 2026-10-18, narrowing UD-15.e for this step): "Every
# .archon test suite passes" runs when the change touches a path in ARCHON_SUITE_PATHS, the files those suites read
# from the checkout, or when the change cannot be computed; otherwise it is reported "SKIPPED", with the reason. The
# change is the commit against its merge base with the base branch; for a commit already on the base, its own change
# against its first parent (a merge brings in the pull request). When it runs, it runs only the suites
# .claude/scripts/archon-suites.sh selects for the change (the ones that run, or name, a file it touches); the summary
# names them, and when none is selected the step is "SKIPPED".
# setup-java uses the local JDK of that version (JAVA_HOME_<n>, the Adoptium, Linux or macOS install folders, SDKMAN's,
# else the java on PATH when its major is that version); setup-gradle and setup-node
# use the local Gradle home and node. git config --global and npm install -g go to the job's own folder.
# The jobs in CI_LOCAL_WSL (default "archon-scripts", owner decision 2026-10-18) run in WSL, distro CI_LOCAL_WSL_DISTRO
# (default Ubuntu): a clone of the job's worktree on the distro's own disk (~/ci-local/<sha7>/<job>), where the shell
# suites run about 20 times faster than in Git Bash and on Linux, as on ubuntu-latest. The distro needs bash, git, jq,
# yq and node. Without wsl.exe, the distro or one of those tools the job runs in Git Bash, and its summary says why;
# on a Linux or macOS host without wsl.exe there is no detour, and the job runs here with no such line.
# CI_LOCAL_WSL= (empty) runs every job in Git Bash.
# Runs queue (ci-queue.sh): a call joins one first-come-first-served queue at once; with --post every job's status then
# reads `queued #n pos p since hh:mm, pid N@host`, and `running since hh:mm, pid N@host` once its turn came.
# CI_LOCAL_SLOTS runs (default 1, owner decision 2026-10-22, after D18's two) go at a time; the others wait, a look every
# CI_LOCAL_LOCK_POLL seconds (default 2). Two runs, each with its jobs side by side, were more than this machine carries:
# archon-scripts took 829s of its 900 beside another run (2d1461f). CI_LOCAL_SLOTS=2 lets two go side by side again
# (the load average goes in the ledger's start and end lines).
# Two runs side by side never share a name or a folder: two commits with the same 7-character prefix never run
# side by side (ci-queue.sh), and everything a run owns is named by that prefix:
#   - its folder $CI_LOCAL_ROOT/<sha7>, its job worktrees in it, and its WSL clones ~/ci-local/<sha7>/<job>;
#   - every step gets CI_LOCAL_RUN=<sha7> and CI_LOCAL_SLOT=<k> (one per slot k); a variable the workflow sets on the
#     job or the step wins.
# The jobs in CI_LOCAL_XRUN (default none) run one at a time across runs, a run waiting (the wait counts with the
# needs: wait, not with the job's own time or its timeout): for a job whose steps hold something two runs cannot
# share. Gradle on the host needs no such lock: each job worktree has its own project cache (.gradle), its builds their
# own daemon, and a shared ~/.gradle is safe for Gradle. Testcontainers and the app tests take free ports (Spring RANDOM_PORT).
# A plain --post call (no --force, --rerun-failed, --all or --audit) runs nothing and exits 0 when the commit's local
# CI is finished (local-ci-status.sh reads green or red) or pending with its run alive (a live queue entry). It says
# which and names the folder. A pending one whose run is gone (stale: local-ci-status.sh finds no live queue entry of
# the commit, its pid is dead or it has no entry) is run again. --rerun-failed, --all and --audit skip the finished
# check and still wait for a live run. --force never skips and never attaches (TASK-68). A queued call whose process
# died is reaped as stale.
# Statuses follow the one grammar of ci-status-grammar.sh: `success in <s>s on <host>` (the job's own seconds, after
# its needs: wait), with `; narrowed: archon-suites` when the .archon step ran a subset or none of the suites and
# `; skipped-locally <n>` for the steps the runner does not run; `failure (infra: <reason>) on <host>` when the runner
# could not run the job; `failure (<reason>) on <host>` when it did not run (a needed job failed, a merge conflict).
# A second run of a commit keeps the first one's folder as <sha7>.r<n> (never deleted, owner decision D17); the run id
# <sha7>.r<k> names run k of the commit. Every run is recorded in the CI ledger (ci-ledger.sh, $CI_LEDGER, default
# ledger.jsonl in $CI_LOCAL_ROOT): request, queued, start, affected, verdict per job, end; caller and ticket come from
# CI_LOCAL_CALLER and CI_LOCAL_TICKET. A ledger that cannot be written never changes a status or the exit code.
# <pr>:<sha> runs that exact head of pull request <pr> (merged into its base); a bare <pr> resolves its head once, at
# the call, so the run tests the commit asked about; the base is read when the run's turn comes.
# Run or reuse (CI plan C12, owner decision D2): ci-plan.sh, the base's copy (--self-from: the PR's base, else the merge
# base with origin/main, for a commit on main its first parent), plans every job: a ran job's status carries
# `; fp=<fp10>` and its ledger verdict the full fp, status, runner and narrowed, the fields a later plan reads. Reuse is
# shadow by default: a job the planner would reuse runs, and a `decision` event logs "would reuse". With CI_REUSE=live,
# or CI_REUSE unset and the file $CI_LOCAL_ROOT/reuse-live present (the owner's switch, on since 2026-10-23; CI_REUSE=shadow
# overrides it), a reused job runs nothing: under the queue mutex it posts `reused from <sha12>;
# fp=<fp10>; scope=<planner blob7>` and logs a `reuse` event (never a source). --all, --audit and the kill switch
# (CI_SCOPE=all or $CI_LOCAL_ROOT/scope-all) reuse nothing. A planner that fails: every job runs, without an fp.
# Same tree (owner decision 2026-10-23): a merge commit on main whose tree is exactly the tree its pull request head's
# last green --post run tested (same ci.yml, same runner class) posts `reused from <head sha12>; same tree` on every job
# and runs nothing; see same_tree_source. The run's folder keeps its runner class (runner) beside sha and tree.
# The jobs are watched every second (CI plan C16): the first red is printed and logged (`first-red`) at once; a job
# over its ci.yml timeout-minutes is stopped and posts `timed out after <m> min`; CI_LOCAL_FAIL_FAST (D6) decides the
# rest of a red run: when-queued (default) stops its other jobs only while another run is queued, always stops them,
# never lets them finish. A stopped job posts error `cancelled: <red job> failed and run #<n> is queued, not a pass`.
set -uo pipefail

post="" force="" keep="" only="" all="" audit="" rerun_failed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --post) post=1 ;;
    --force) force=1 ;;
    --keep) keep=1 ;;
    --all) all=1 ;;
    --audit) audit=1 ;;
    --rerun-failed) rerun_failed=1 ;;
    --jobs) only=$2; shift ;;
    -h|--help) awk 'NR > 1 && /^set -uo/ { exit } NR > 1' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
if [ -n "$post" ] && [ -n "$only" ]; then
  echo "--post reports a whole run; it cannot be combined with --jobs" >&2; exit 2
fi
if [ -n "$force" ] && [ -z "$post" ]; then
  echo "--force applies to --post only" >&2; exit 2
fi
guard=""
[ -n "$post" ] && [ -z "$force$rerun_failed$all$audit" ] && guard=1
if [ -n "$rerun_failed" ] && { [ -n "$all" ] || [ -n "$audit" ]; }; then
  echo "--rerun-failed keeps green jobs; --all and --audit run every one" >&2; exit 2
fi

export CI_LOCAL_SLOTS=${CI_LOCAL_SLOTS:-1}
[[ "$CI_LOCAL_SLOTS" =~ ^[1-9][0-9]*$ ]] || { echo "CI_LOCAL_SLOTS must be a whole number of 1 or more, not $CI_LOCAL_SLOTS" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-status-grammar.sh
. "$here/ci-status-grammar.sh"
# shellcheck source=ci-ledger.sh
. "$here/ci-ledger.sh"
# shellcheck source=ci-queue.sh
. "$here/ci-queue.sh"

main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
root=${CI_LOCAL_ROOT:-$(dirname "$main")/ci-local}
# The owner's reuse switch (2026-10-23): the file reuse-live turns reuse live unless CI_REUSE says otherwise; exported, so
# the planner (the base's copy, which reads only CI_REUSE) and this script agree.
[ -z "${CI_REUSE:-}" ] && [ -e "$root/reuse-live" ] && export CI_REUSE=live
mkdir -p "$root"
export CI_LEDGER=${CI_LEDGER:-$root/ledger.jsonl}
host=$(hostname)
t_req=$(date -u +%s)
repo=$(git -C "$main" remote get-url origin | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')

fetch() { # fetch <git fetch args>: one fetch at a time in the main clone (concurrent fetches collide on its refs)
  if command -v flock > /dev/null; then
    ( flock -w 300 8 && git -C "$main" fetch -q "$@" ) 8>>"$root/.fetch.lock"
  else
    git -C "$main" fetch -q "$@"
  fi
}

# The commit under test is fixed at the call (CI plan C6: the exact SHA): a pull request's head as GitHub reports it
# now, or the <sha> of <pr>:<sha>. Its base is read once the run's turn comes (TASK-56).
arg=${1:-}
pr="" base_name="" merge_base=""
if [[ "$arg" =~ ^([0-9]+):([0-9a-f]{7,40})$ ]] && [ ${#BASH_REMATCH[1]} -lt 7 ]; then
  pr=${BASH_REMATCH[1]} sha=${BASH_REMATCH[2]}
  base_name=$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName) || { echo "cannot read pull request $pr" >&2; exit 1; }
elif [[ "$arg" =~ ^[0-9]+$ ]] && [ ${#arg} -lt 7 ]; then
  # A pull request: its head, merged into the base as the pull_request event does; the status goes on the head. The base
  # is the base branch as it is when the run starts, not the baseRefOid GitHub recorded, which can lag behind merges.
  pr=$arg
  read -r sha base_name < <(gh pr view "$arg" --repo "$repo" --json headRefOid,baseRefName -q '"\(.headRefOid) \(.baseRefName)"')
  [ -n "${sha:-}" ] || { echo "cannot read pull request $arg" >&2; exit 1; }
fi
if [ -n "$pr" ]; then
  git -C "$main" cat-file -e "$sha^{commit}" 2>/dev/null || fetch origin "pull/$pr/head" \
    || { echo "cannot fetch pull request $pr" >&2; exit 1; }
  sha=$(git -C "$main" rev-parse --verify "$sha^{commit}") || { echo "commit $sha of pull request $pr not found" >&2; exit 1; }
  base_ref=""
else
  # A name (HEAD, a branch, origin/main) or a short SHA may have moved on origin: fetch first. A full SHA the clone has
  # needs no fetch.
  if ! [[ "${arg:-HEAD}" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$main" cat-file -e "$arg^{commit}" 2>/dev/null; then
    fetch origin || { echo "git fetch origin failed" >&2; exit 1; }
  fi
  sha=$(git -C "$main" rev-parse --verify "${arg:-HEAD}^{commit}") || { echo "unknown commit ${arg:-HEAD}" >&2; exit 1; }
  base_ref=origin/main
fi
short=${sha:0:7}
# A commit that changes only backlog/, docs/retro/ or docs/tokenomics/ gets no local CI (owner decisions 2026-10-22,
# 2026-10-23, ci-skip.sh): refused here, where every caller ends, so no new caller brings it back. Its verdict is read
# past it.
if [ -z "$pr" ] && (cd "$main" && bash "$here/../../.archon/scripts/ci-skip.sh" check "$sha"); then
  echo "ci-local: $short changes only $(bash "$here/../../.archon/scripts/ci-skip.sh" paths | tr '\n' ' ')and gets no local CI (owner decisions 2026-10-22, 2026-10-23); its verdict is the one of the newest commit under it that changes anything else" >&2
  exit 0
fi

# A plain --post call refuses a commit whose local CI is finished, and says when a pending one is dead; a live run is
# caught atomically by q_enter below.
if [ -n "$guard" ]; then
  read -r st_state st_detail < <(cd "$main" && CI_LOCAL_ROOT="$root" LOCAL_CI_STATUS_FOR="$sha" \
    bash "$here/../../.archon/scripts/local-ci-status.sh" "$repo" "$sha")
  case "$st_state" in
    green|red)
      echo "ci-local: $short is finished: $st_state $st_detail; not run again; its folder is $root/$short (--force runs it anyway)" >&2
      exit 0 ;;
    stale) echo "ci-local: $short is pending, but its run is gone ($st_detail); running it again" >&2 ;;
  esac
fi

# The jobs of ci.yml at the commit. A lookup that reads no job, or misses one --jobs names, is tried again, up to
# CI_LOCAL_LOOKUP_TRIES times (default 3) CI_LOCAL_LOOKUP_PAUSE seconds apart (default 2): case 5 of ci-local.test.sh
# failed on "no job good in ci.yml" three times on 2026-10-22 with nothing else logged. The retry hides that symptom;
# the line each miss logs (both commands, their exit codes and output) is there to find its cause.
only_jobs=$(printf '%s\n' "${only//,/ }" | tr ' ' '\n' | grep -v '^$')
tries=${CI_LOCAL_LOOKUP_TRIES:-3}
lookup_err=$(mktemp)
for try in $(seq 1 "$tries"); do
  wf_text=$(git -C "$main" show "$sha:.github/workflows/ci.yml" 2> "$lookup_err"); show_rc=$?
  show_err=$(head -c 300 "$lookup_err" | tr '\n' ' ')
  all_jobs=$(printf '%s\n' "$wf_text" | yq '.jobs | keys | .[]' 2> "$lookup_err" | tr -d '\r'); yq_rc=$?
  yq_err=$(head -c 300 "$lookup_err" | tr '\n' ' ')
  missed=""
  { [ "$show_rc" -eq 0 ] && [ -n "$all_jobs" ]; } || missed=" (no job read)"
  for j in $only_jobs; do grep -qx "$j" <<< "$all_jobs" || missed="$missed $j"; done
  [ -z "$missed" ] && break
  echo "ci-local: job lookup $try of $tries at $short missed$missed: \`git -C $main show $short:.github/workflows/ci.yml\` exit $show_rc, ${#wf_text} bytes${show_err:+, stderr: $show_err}; \`yq '.jobs | keys | .[]'\` exit $yq_rc, jobs: ${all_jobs//$'\n'/ }${yq_err:+, stderr: $yq_err}" >&2
  [ "$try" -lt "$tries" ] && sleep "${CI_LOCAL_LOOKUP_PAUSE:-2}"
done
rm -f "$lookup_err"
[ "$show_rc" -eq 0 ] || { echo "no .github/workflows/ci.yml at $short" >&2; exit 1; }
jobs=$all_jobs
if [ -n "$only" ]; then
  jobs=$only_jobs
  for j in $jobs; do
    grep -qx "$j" <<< "$all_jobs" || { echo "no job $j in ci.yml" >&2; exit 2; }
  done
fi

status() { # status <job> <state> <description>
  [ -n "$post" ] || return 0
  gh api -X POST "repos/$repo/statuses/$sha" -f state="$2" -f context="local-ci/$1" \
    -f description="$(printf '%s' "$3" | cut -c1-140)" > /dev/null \
    || echo "could not post the local-ci/$1 status" >&2
}
ledger() { ci_ledger "$1" --arg sha "$sha" --arg run "${run_id:-}" --argjson pr "${pr:-null}" "${@:2}"; }
ledger request --arg mode "$([ -n "$post" ] && echo post || echo check)" --arg jobs "$(echo $jobs)" --argjson t_req "$t_req"

# The queue (ci-queue.sh) in front of the run locks. One local CI per slot on this machine (owner decisions 2026-10-18,
# TASK-56, and D18: two slots): the jobs of one run share its CPUs and Docker; two runs share no name or folder (see the
# header). A lock whose process is gone is taken over, a queue entry whose process is gone is reaped.
q_init "$root"
mode=$([ -n "$post" ] && echo post || echo check)
while :; do
  read -r how qn < <(q_locked q_enter "$sha" "$pr" "$mode" "${arg:-HEAD}" "$$" "$([ -n "$force" ] && echo new || echo attach)")
  [ -n "${qn:-}" ] || { echo "the local CI queue in $Q cannot be written" >&2; exit 1; }
  [ "$how" = new ] && break
  if [ -n "$guard" ]; then
    echo "ci-local: $short is pending, its run alive: #$qn $(q_get "$Q/$qn" state), pid $(q_get "$Q/$qn" pid); not run again; its folder is $root/$short (--force runs it anyway)" >&2
    ledger attach --argjson n "$qn" --argjson rc 0
    exit 0
  fi
  echo "local CI of $short is already queued or running as #$qn (pid $(q_get "$Q/$qn" pid)); waiting for its result" >&2
  final=$(q_wait "$qn"); rc=$?
  [ "$rc" = 75 ] && { echo "run #$qn of $short went stale; queueing again" >&2; continue; }
  echo "local CI of $short ended as $final (exit $rc); its result is on the commit" >&2
  ledger attach --argjson n "$qn" --argjson rc "$rc"
  exit "$rc"
done
run_id="" t_lock="" ended=""
on_exit() {
  local rc=$?
  [ -n "${Q_LOCK:-}" ] && rm -rf "$Q_LOCK"
  q_locked q_finish "$qn" "$([ -n "$ended" ] && echo "done" || echo aborted)" "$rc"
  ledger_end "$rc"
  exit "$rc"
}
ledger_end() { :; }  # replaced once the run has started
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
pos=$(q_pos "$qn")
since=$(date +%H:%M)
for j in $jobs; do status "$j" pending "$(ci_status_queued "$qn" "$pos" "$$" "$host" "$since")"; done
said=""
until q_may_start "$qn" && q_take_slot "$$" "${arg:-HEAD}"; do
  if [ -z "$said" ]; then
    if ahead=$(q_ahead "$qn") && ! q_may_start "$qn"; then
      echo "queued as #$qn at position $(q_pos "$qn"): waiting for #$ahead ($(q_get "$Q/$ahead" what), pid $(q_get "$Q/$ahead" pid))" >&2
    else
      echo "waiting for the local CI of ${Q_HOLDER_WHAT:-} (pid ${Q_HOLDER_PID:-?}) to end" >&2
    fi
    ledger queued --argjson n "$qn" --argjson pos "$(q_pos "$qn")"
    said=1
  fi
  sleep "${CI_LOCAL_LOCK_POLL:-2}"
  q_locked q_reap
done
t_lock=$(date -u +%s)
q_locked q_set "$qn" state running
# What this run owns, by its commit's 7-character prefix and its slot (D18): see the header.
run_env=(CI_LOCAL_RUN="$short" CI_LOCAL_SLOT="${Q_SLOT:-1}")

fetch origin || { echo "git fetch origin failed" >&2; exit 1; }
if [ -n "$pr" ]; then
  base_sha=$(git -C "$main" rev-parse --verify "origin/$base_name^{commit}") || { echo "unknown base branch $base_name" >&2; exit 1; }
  merge_base=$base_sha
  base_ref=$base_sha
fi

# The paths the .archon suites read from the checkout: the scripts and suites themselves, the scope guard and its
# policy (retro-fence, developer-fence), .gitignore (developer-fence checks the local policy is ignored) and the workflow that runs
# them. What else the scripts call (commit-reports.sh, backlog/, docs/retro/) the suites stub.
ARCHON_SUITE_PATHS=(.archon/ .claude/hooks/ .gitignore .github/workflows/ci.yml)
ARCHON_SUITE_GLOB='.archon/scripts/test/*.test.sh'
archon_skip="" archon_suites="" archon_note="" archon_change=""
if [ -z "$all" ]; then
  mb=$(git -C "$main" merge-base "$base_ref" "$sha" 2>/dev/null) || mb=""
  [ "$mb" = "$sha" ] && { mb=$(git -C "$main" rev-parse -q --verify "$sha^1" 2>/dev/null) || mb=""; }
  if [ -n "$mb" ] && changed=$(git -C "$main" diff --name-only "$mb" "$sha" 2>/dev/null); then
    archon_change="${mb:0:7}..$short"
    hits=""
    while IFS= read -r f; do
      for p in "${ARCHON_SUITE_PATHS[@]}"; do
        case "$f" in "$p"*) hits+="$f"$'\n'; break ;; esac
      done
    done <<<"$changed"
    if [ -z "$hits" ]; then
      archon_skip="the change ${mb:0:7}..$short touches none of ${ARCHON_SUITE_PATHS[*]}"
    else
      # Only the suites the change can affect (owner decision 2026-10-18); "all" or a failed selection runs every one.
      if sel=$(printf '%s' "$hits" | bash "$here/archon-suites.sh" "$main" "$sha") \
          && [ "$sel" != all ]; then
        if [ -z "$sel" ]; then
          archon_skip="no .archon suite runs or names a file the change ${mb:0:7}..$short touches"
        else
          archon_suites=$(printf '%s\n' "$sel" | tr '\n' ' ')
          archon_note="$(printf '%s\n' "$sel" | wc -l | tr -d ' ') of $(git -C "$main" ls-tree --name-only "$sha" .archon/scripts/test/ | grep -c '\.test\.sh$') suites, for the change ${mb:0:7}..$short: $(printf '%s\n' "$sel" | sed 's#.*/##; s#\.test\.sh$##' | tr '\n' ' ')"
        fi
      fi
    fi
  fi
fi

# Evidence is kept (CI plan C3, owner decision D17): the folder of an earlier run of this commit moves to <sha7>.r<n>
# (n: its own run number) and is never deleted. Only its job worktrees go, which exist only after --keep.
out=$root/$short
if [ -e "$out" ]; then
  for wt in "$out"/wt-*; do
    [ -d "$wt" ] && git -C "$main" worktree remove --force "$wt" 2>/dev/null
  done
  git -C "$main" worktree prune
  k=$(sed -n 's/.*\.r\([0-9][0-9]*\)$/\1/p' "$out/run-id" 2>/dev/null)
  if [ -z "$k" ] || [ -e "$out.r$k" ]; then k=1; while [ -e "$out.r$k" ]; do k=$((k + 1)); done; fi
  mv "$out" "$out.r$k" || { echo "cannot keep the earlier run's folder $out as $out.r$k" >&2; exit 1; }
fi
k=0
for d in "$out".r*; do [[ "$d" =~ \.r([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -gt "$k" ] && k=${BASH_REMATCH[1]}; done
run_id="$short.r$((k + 1))"
mkdir -p "$out"; echo "$run_id" > "$out/run-id"
printf '%s\n' "$wf_text" > "$out/ci.yml"
# The tested tree (a pull request: its merge into the base; empty on a conflict), for --rerun-failed: a run keeps the
# green jobs of the latest run of this commit only when that run tested the same tree.
prev=""; [ "$k" -gt 0 ] && prev="$out.r$k"
if [ -n "$merge_base" ]; then
  tested_tree=$(git -C "$main" merge-tree --write-tree "$merge_base" "$sha" 2>/dev/null | head -n 1)
  git -C "$main" merge-tree --write-tree "$merge_base" "$sha" > /dev/null 2>&1 || tested_tree=""
else
  tested_tree=$(git -C "$main" rev-parse -q --verify "$sha^{tree}" 2>/dev/null) || tested_tree=""
fi
echo "$sha" > "$out/sha"; echo "$tested_tree" > "$out/tree"

# The WSL side: wsl.sh check | node | checkout <bundle> <dir> <origin url> | step <dir> <script> [K=V...] | remove <dir>,
# where <dir> is relative to ~/ci-local in the distro.
wsl_jobs=" ${CI_LOCAL_WSL-archon-scripts} " distro=${CI_LOCAL_WSL_DISTRO:-Ubuntu} wsl_why=""
cat > "$out/wsl.sh" <<'WSL'
#!/usr/bin/env bash
set -uo pipefail
# WSL appends the Windows PATH, whose shims (npm, archon) the CI runner does not have.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd: -)
d="$HOME/ci-local/${2:-}"
case "$1" in
  check) for t in bash git jq yq node; do command -v "$t" > /dev/null || { echo "$t is not installed"; exit 1; }; done ;;
  node) node --version ;;
  checkout)
    rm -rf "$d"; mkdir -p "$d/home/npm"
    printf '[core]\n\tfsmonitor = false\n' > "$d/home/gitconfig"
    git -c advice.detachedHead=false clone -q "$3" "$d/wt" && git -C "$d/wt" remote set-url origin "$4" ;;
  step)
    script=$3; shift 3
    cd "$d/wt" && exec env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 "$@" CI=true GIT_CONFIG_GLOBAL="$d/home/gitconfig" NPM_CONFIG_PREFIX="$d/home/npm" \
      PATH="$d/home/npm/bin:$PATH" bash --noprofile --norc -eo pipefail "$script" ;;
  remove) rm -rf "$d" ;;
esac
WSL
wsl_path() { # the WSL path of a Windows one; unchanged where there is no cygpath
  local p
  command -v cygpath > /dev/null || { printf '%s' "$1"; return; }
  p=$(cygpath -m "$1")
  printf '/mnt/%s%s' "$(printf '%s' "${p:0:1}" | tr 'A-Z' 'a-z')" "${p:2}"
}
in_wsl() { # in_wsl <wsl.sh arguments>
  MSYS_NO_PATHCONV=1 wsl.exe -d "$distro" --exec bash "$(wsl_path "$out/wsl.sh")" "$@" < /dev/null
}
for j in $jobs; do
  [[ "$wsl_jobs" == *" $j "* ]] || continue
  if ! command -v wsl.exe > /dev/null; then
    # The detour is Git Bash's on Windows; on Linux or macOS the job runs here, as on ubuntu-latest, and says nothing.
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) wsl_why="no wsl.exe" ;; *) wsl_jobs=" " ;; esac
  elif ! why=$(in_wsl check 2>&1); then wsl_why="WSL $distro: $(printf '%s' "$why" | tr -d '\r\0' | tail -1)"
  fi
  break
done

# The local JDK for setup-java's version.
java_home() {
  local v=$1 var="JAVA_HOME_$1" d
  if [ -n "${!var:-}" ]; then echo "${!var}"; return; fi
  for d in "/c/Program Files/Eclipse Adoptium/jdk-$v"* "/usr/lib/jvm/temurin-$v"* "/usr/lib/jvm/java-$v"* \
      "/Library/Java/JavaVirtualMachines/temurin-$v"*.jdk/Contents/Home "${HOME:-}/.sdkman/candidates/java/$v"*; do
    [ -x "$d/bin/java" ] || [ -x "$d/bin/java.exe" ] && { echo "$d"; return; }
  done
  # The java on PATH (a team member's JDK installed elsewhere), when its major is v: its own java.home.
  command -v java > /dev/null || return 1
  [ "$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1)" = "$v" ] || return 1
  d=$(java -XshowSettings:properties -version 2>&1 | tr -d '\r' | sed -n 's/^ *java\.home = //p' | head -n 1)
  [ -n "$d" ] && echo "$d"
}

# expand <text>: the ${{ }} expressions the workflow uses, resolved; an unknown one fails the step.
expand() {
  local text=$1 expr
  while [[ "$text" =~ \$\{\{([^}]*)\}\} ]]; do
    expr=$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/^ *//; s/ *$//')
    case "$expr" in
      "github.event.pull_request.base.sha || 'origin/main'") text=${text/"${BASH_REMATCH[0]}"/$base_ref} ;;
      *) echo "expression not reproduced locally: \${{ $expr }}" >&2; return 1 ;;
    esac
  done
  printf '%s' "$text"
}

# cond <if>: Actions' step condition, for the forms the workflow uses. Reads failed and the outcome_<id> variables.
cond() {
  local c term ok=0 id want
  c=$(printf '%s' "$1" | sed 's/^ *\${{ *//; s/ *}} *$//')
  IFS=$'\n'
  for term in $(printf '%s' "$c" | sed 's/ *&& */\n/g'); do
    case "$term" in
      "failure()") [ "$failed" = 1 ] || ok=1 ;;
      "success()") [ "$failed" = 0 ] || ok=1 ;;
      "always()") ;;
      steps.*.outcome\ ==\ \'*\')
        id=${term#steps.}; id=${id%%.outcome*}; want=${term##*== \'}; want=${want%\'}
        local var="outcome_${id//-/_}"
        [ "${!var:-}" = "$want" ] || ok=1 ;;
      *) unset IFS; echo "condition not reproduced locally: $term" >&2; return 2 ;;
    esac
  done
  unset IFS
  # Without failure() or always(), a step runs only while the job has not failed.
  if [[ "$c" != *"failure()"* && "$c" != *"always()"* ]] && [ "$failed" = 1 ]; then ok=1; fi
  return $ok
}

# needs_of <job>: the jobs it needs, one per line (needs: is a name or a list).
needs_of() {
  yq -o=json ".jobs.\"$1\".needs // []" "$out/ci.yml" | jq -r 'if type == "array" then .[] else . end' | tr -d '\r'
}

# in_cycle <job>: true when <job> needs itself, directly or through other jobs.
in_cycle() {
  local seen=" " todo j
  todo=$(needs_of "$1")
  while [ -n "$todo" ]; do
    j=${todo%%$'\n'*}
    if [ "$todo" = "$j" ]; then todo=""; else todo=${todo#*$'\n'}; fi
    [ "$j" = "$1" ] && return 0
    [[ "$seen" == *" $j "* ]] && continue
    seen+="$j "
    todo+="${todo:+$'\n'}$(needs_of "$j")"
    todo=$(printf '%s' "$todo" | grep -v '^$')
  done
  return 1
}

# job_at <job>: its place in the run's job list (the serial jobs run in that order).
job_at() { printf '%s\n' "$jobs" | grep -nx "$1" | cut -d: -f1; }

# result <job> <res> <own s> <skipped-locally n> <kind: ran|infra|notrun> <needs-wait s> <narrowed 0|1> [reason]: the
# job's .result line, read by the jobs that need it, finish_job, the summary and the ledger; the reason goes beside it.
result() {
  [ -n "${8:-}" ] && printf '%s\n' "$8" > "$out/$1.reason"
  # A clock stepped back (WSL resyncs its clock) never gives a negative time: the grammar has none.
  echo "$2 $(( $3 < 0 ? 0 : $3 )) $4 $5 $(( $6 < 0 ? 0 : $6 )) $7" > "$out/$1.result"
}

# xrun_lock <job>: in the job's process, waits for its CI_LOCAL_XRUN turn across runs, then holds it until the job's
# process ends (flock on fd 7, released by the kernel also when the job is stopped; without flock, a lock folder whose
# process is gone is taken over).
xrun=" ${CI_LOCAL_XRUN-} "
xrun_lock() {
  local job=$1 lock="$root/.xrun-$1" holder said=""
  if command -v flock > /dev/null; then
    exec 7>>"$lock.lock"
    if ! flock -n 7; then
      log "waits for the $job job of run $(cat "$lock.who" 2>/dev/null) to end: one at a time across runs (CI_LOCAL_XRUN)"
      flock 7
    fi
  else
    until mkdir "$lock.d" 2>/dev/null; do
      holder=$(cat "$lock.d/pid" 2>/dev/null)
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        [ "$(cat "$lock.d/pid" 2>/dev/null)" = "$holder" ] && rm -rf "$lock.d"; continue
      fi
      [ -z "$said" ] && { log "waits for the $job job of run $(cat "$lock.who" 2>/dev/null) to end: one at a time across runs (CI_LOCAL_XRUN)"; said=1; }
      sleep "${CI_LOCAL_LOCK_POLL:-2}"
    done
    echo "$BASHPID" > "$lock.d/pid"
  fi
  echo "$run_id" > "$lock.who"
}

run_job() {
  local job=$1
  local log="$out/$job.log" wt="$out/wt-$job" home="$out/home-$job"
  local n i step name uses run ifc id t0 t1 rc res steps_txt="" failed=0 skipped=0 narrowed=0 jstart jwait
  jwait=$(date +%s)
  exec 3>"$log"
  log() { echo "$*" >&3; }
  # needs: wait for every needed job, and run only when each one succeeded (as Actions does). A need that can never
  # be met (not in the run, a cycle, a serial job queued after this one) fails the job at once instead of waiting.
  local need nres
  for need in $(needs_of "$job"); do
    if ! printf '%s\n' "$all_jobs" | grep -qx "$need"; then
      log "needed job $need is not in the workflow"; result "$job" failure 0 0 notrun 0 0 "not run: needed job $need is not in the workflow"; return
    elif ! printf '%s\n' "$jobs" | grep -qx "$need"; then
      log "needed job $need is not part of this run"; result "$job" failure 0 0 notrun 0 0 "not run: needed job $need is not part of this run"; return
    elif in_cycle "$job"; then
      log "needs cycle: $job needs itself, directly or through another job"; result "$job" failure 0 0 notrun 0 0 "not run: needs cycle"; return
    elif [[ "$serial" == *" $job "* && "$serial" == *" $need "* ]] && [ "$(job_at "$need")" -gt "$(job_at "$job")" ]; then
      log "needed job $need runs after it in CI_LOCAL_SERIAL"; result "$job" failure 0 0 notrun 0 0 "not run: needed job $need runs after it in CI_LOCAL_SERIAL"; return
    fi
    until [ -s "$out/$need.result" ]; do sleep "${CI_LOCAL_WATCH_POLL:-1}"; done
    read -r nres _ < "$out/$need.result"
    if [ "$nres" != success ]; then
      log "not run: needed job $need failed"
      result "$job" failure 0 0 notrun $(( $(date +%s) - jwait )) 0 "not run: needed job $need failed"; return
    fi
  done
  [[ "$xrun" == *" $job "* ]] && xrun_lock "$job"
  # The job's own time starts here: the seconds spent waiting for its needs (and a CI_LOCAL_XRUN turn) go beside it,
  # not into it (CI plan C3).
  jstart=$(date +%s); jwait=$((jstart - jwait))
  echo "$jstart" > "$out/$job.started"   # the watcher's clock for timeout-minutes
  mkdir -p "$home/npm"
  # As on the CI runner: no file system monitor (Git for Windows turns one on system-wide), which made a test miss a
  # file change.
  printf '[core]\n\tfsmonitor = false\n' > "$home/gitconfig"
  # Jobs start side by side and git takes a lock on the shared repository for each worktree add: one retry after a
  # second keeps a lost race from reading as a broken runner.
  if ! git -C "$main" worktree add -q --detach "$wt" "$sha" >&3 2>&1 \
      && ! { sleep 1; rm -rf "$wt"; git -C "$main" worktree prune >&3 2>&1
             git -C "$main" worktree add -q --detach "$wt" "$sha" >&3 2>&1; }; then
    log "cannot create the worktree"; result "$job" failure $(( $(date +%s) - jstart )) 0 infra "$jwait" 0 worktree; return
  fi
  if [ -n "$merge_base" ]; then
    if ! git -C "$wt" -c user.name=ci-local -c user.email=ci-local@example.invalid merge -q --no-edit "$merge_base" >&3 2>&1; then
      log "the pull request does not merge cleanly into its base"
      result "$job" failure $(( $(date +%s) - jstart )) 0 notrun "$jwait" 0 "merge conflict with the base ${merge_base:0:7}"; return
    fi
  fi
  # --audit: right after the checkout every file is as new as the index ("racily clean"), so a step's first git diff or
  # git status opens each one to compare it, and the trace reads that as the step reading the whole tree. A refresh a
  # second later, before the steps, settles the index (1814 opens to 6 for a git diff in a fresh worktree).
  if [ -n "$audit" ]; then
    sleep 1; git -C "$wt" update-index -q --refresh >&3 2>&1; log "--audit: settled the worktree's git index"
  fi
  local wsl="" where=""
  if [[ "$wsl_jobs" == *" $job "* ]]; then
    if [ -n "$wsl_why" ]; then
      where="runs in Git Bash: $wsl_why"
    elif git -C "$wt" bundle create -q "$home/checkout.bundle" HEAD >&3 2>&1 \
        && in_wsl checkout "$short/$job" "$(wsl_path "$home/checkout.bundle")" "$(git -C "$main" remote get-url origin)" >&3 2>&1; then
      wsl=1; rm -f "$home/checkout.bundle"
      where="runs in WSL $distro: ~/ci-local/$short/$job"
    else
      log "cannot create the WSL checkout"; result "$job" failure $(( $(date +%s) - jstart )) 0 infra "$jwait" 0 wsl-checkout; return
    fi
    log "$where"; steps_txt="    $where"$'\n'
    [ -n "$audit" ] && [ -n "$wsl" ] && { log "--audit: the steps in WSL are not traced"; steps_txt+="    --audit: the steps in WSL are not traced"$'\n'; }
  fi
  n=$(yq ".jobs.\"$job\".steps | length" "$out/ci.yml")
  local jenv
  jenv=$(yq -o=json ".jobs.\"$job\".env // {}" "$out/ci.yml")
  for i in $(seq 0 $((n - 1))); do
    step=$(yq -o=json ".jobs.\"$job\".steps[$i]" "$out/ci.yml")
    uses=$(jq -r '.uses // ""' <<<"$step")
    run=$(jq -r '.run // ""' <<<"$step")
    ifc=$(jq -r '.if // ""' <<<"$step")
    id=$(jq -r '.id // ""' <<<"$step")
    name=$(jq -r '.name // ""' <<<"$step")
    [ -n "$name" ] || name=${uses:-$(printf '%s' "$run" | head -1)}
    t0=$(date +%s)
    log "::group::$name"
    res=""
    if [ -n "$ifc" ]; then
      cond "$ifc" 2>&3; rc=$?
      [ $rc = 2 ] && res=failure
      [ $rc = 1 ] && res=skipped
    elif [ "$failed" = 1 ]; then
      res=skipped
    fi
    if [ -z "$res" ]; then
      res=success
      case "$name" in
        "Contract token is read-only")
          res=skipped-locally; log "checks the scope of the CI secret; locally the contract is cloned with gh's login" ;;
        "Every .archon test suite passes")
          [ -n "$archon_skip" ] && { res=SKIPPED; narrowed=1; log "SKIPPED: $archon_skip (--all runs it)"; } ;;
      esac
    fi
    # A local JDK or a second clone would land on the Windows side, not in the WSL checkout.
    if [ "$res" = success ] && [ -n "$wsl" ] && { [ "${uses%@*}" = actions/setup-java ] \
        || { [ "${uses%@*}" = actions/checkout ] && [ -n "$(jq -r '.with.repository // ""' <<<"$step")" ]; }; }; then
      log "not reproduced in WSL: $uses with these inputs"; res=failure
    fi
    if [ "$res" = success ] && [ -n "$uses" ]; then
      case "${uses%@*}" in
        actions/checkout)
          local crepo cpath
          crepo=$(jq -r '.with.repository // ""' <<<"$step"); cpath=$(jq -r '.with.path // "."' <<<"$step")
          if [ -n "$crepo" ]; then
            # Read-only: a shallow clone, never pushed to. Its own config keeps gh's login, as actions/checkout keeps
            # its token: the job's GIT_CONFIG_GLOBAL hides the user's credential helper from a later fetch in it.
            gh repo clone "$crepo" "$wt/$cpath" -- --depth 1 -q >&3 2>&1 \
              && git -C "$wt/$cpath" config credential.https://github.com.helper '!gh auth git-credential' >&3 2>&1 \
              || res=failure
          fi ;;
        actions/setup-java)
          local v jh
          v=$(jq -r '.with["java-version"] // ""' <<<"$step")
          if jh=$(java_home "$v"); then command -v cygpath >/dev/null && jh=$(cygpath -m "$jh"); export JAVA_HOME="$jh"; log "JAVA_HOME=$jh"; else log "no local JDK $v"; res=failure; fi ;;
        gradle/actions/setup-gradle) log "the local Gradle home is used" ;;
        actions/setup-node)
          local nv
          if [ -n "$wsl" ]; then nv="WSL node $(in_wsl node 2>&1)"; else nv="local node $(node --version 2>&1)"; fi
          log "$nv (CI: $(jq -r '.with["node-version"] // ""' <<<"$step"))" ;;
        actions/cache|actions/upload-artifact)
          res=skipped-locally; log "the local caches stay; reports stay in the worktree" ;;
        *) log "action not reproduced locally: $uses"; res=failure ;;
      esac
    elif [ "$res" = success ] && [ -n "$run" ]; then
      local script envs
      if ! script=$(expand "$run" 2>&3); then res=failure
      elif ! envs=$(jq -r --argjson j "$jenv" '($j + (.env // {})) | to_entries[] | "\(.key)=\(.value)"' <<<"$step"); then res=failure
      else
        local -a envargs=()
        local kv
        while IFS= read -r kv; do
          [ -n "$kv" ] || continue
          kv=$(expand "$kv" 2>&3) || { res=failure; break; }
          envargs+=("$kv")
        done <<<"$envs"
        if [ "$res" = success ] && [ "$name" = "Every .archon test suite passes" ] && [ -n "$archon_suites" ]; then
          if [[ "$script" == *"$ARCHON_SUITE_GLOB"* ]]; then
            script=${script//"$ARCHON_SUITE_GLOB"/$archon_suites}; narrowed=1; log "runs $archon_note(--all runs every suite)"
          else
            log "the step does not list the suites as $ARCHON_SUITE_GLOB: every suite runs"; archon_note=""
          fi
        fi
        if [ "$res" = success ] && [ -n "$wsl" ]; then
          # Windows jq ends its lines in CR, which Git Bash ignores and Linux bash does not.
          printf '%s\n' "$script" | tr -d '\r' > "$home/step-$i.sh"
          in_wsl step "$short/$job" "$(wsl_path "$home/step-$i.sh")" "${run_env[@]}" "${envargs[@]%$'\r'}" >&3 2>&1 7>&- || res=failure
        elif [ "$res" = success ]; then
          printf '%s\n' "$script" > "$home/step-$i.sh"
          # --audit: the step runs under ci-plan.sh --audit-run, which keeps its exit status and records a violation.
          local -a audit_cmd=()
          [ -n "$audit" ] && audit_cmd=(bash "$here/ci-plan.sh" --audit-run "$job" "$wt" ${plan_base:+--base "$plan_base"} \
            --record --report "$out/$job.audit.$i" --)
          # fd 7 is the CI_LOCAL_XRUN lock: a process the step leaves behind (a daemon) must not keep holding it.
          # The runner's own ledger and slot count stay out of the step: a suite that runs ci-local in a throwaway
          # repo must not write to the real ledger or inherit this run's slots.
          ( cd "$wt" && env -u CI_LEDGER -u CI_LOCAL_SLOTS -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 "${run_env[@]}" "${envargs[@]}" CI=true GIT_CONFIG_GLOBAL="$home/gitconfig" \
              NPM_CONFIG_PREFIX="$home/npm" PATH="$home/npm:$home/npm/bin:$PATH" \
              "${audit_cmd[@]}" bash --noprofile --norc -eo pipefail "$home/step-$i.sh" ) >&3 2>&1 7>&- || res=failure
        fi
      fi
    fi
    t1=$(date +%s)
    log "::endgroup:: $res $((t1 - t0))s"
    if [ -n "$id" ]; then
      o=${res/skipped-locally/skipped}; printf -v "outcome_${id//-/_}" '%s' "${o/SKIPPED/skipped}"
    fi
    [ "$res" = failure ] && failed=1
    [ "$res" = skipped-locally ] && skipped=$((skipped + 1))
    [ "$res" = SKIPPED ] && name="$name -- $archon_skip"
    [ "$name" = "Every .archon test suite passes" ] && [ -n "$archon_note" ] && name="$name -- $archon_note"
    steps_txt+=$(printf '    %-16s %4ss  %s' "$res" "$((t1 - t0))" "$name")$'\n'
  done
  printf '%s' "$steps_txt" > "$out/$job.steps"
  # The seconds of each test set, from the JUnit XML the job left (the ledger's end line).
  [ -d "$wt" ] && ci_ledger_junit "$wt" > "$out/$job.tests.json"
  [ -n "$wsl" ] && [ -z "$keep" ] && in_wsl remove "$short/$job" >&3 2>&1
  if [ "$failed" = 1 ]; then res=failure; else res=success; fi
  result "$job" "$res" $(( $(date +%s) - jstart )) "$skipped" ran "$jwait" "$narrowed"
  exec 3>&-
}

finish_job() { # report a finished job's status, in the grammar of ci-status-grammar.sh
  local job=$1 res secs skipped kind needs narrowed reason desc state fp="" how="" arg=""
  read -r res secs skipped kind needs narrowed < "$out/$job.result"
  reason=$(cat "$out/$job.reason" 2>/dev/null)
  read -r _ fp _ < "$out/$job.plan" 2>/dev/null
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || fp=""
  [ -s "$out/$job.stop" ] && read -r how arg < "$out/$job.stop"
  state=$res
  case "$kind" in
    infra) desc=$(ci_status_infra "$reason" "$host") ;;
    notrun) desc=$(ci_status_notrun "$reason" "$host") ;;
    timedout) desc=$(ci_status_timedout "$arg") ;;
    cancelled) state=error; desc=$(ci_status_cancelled "$arg") ;;
    *) desc=$(ci_status_ran "$res" "$secs" "$host" "$fp" "${narrowed:-0}" "${skipped:-0}" \
         "$([ -n "$rerun_failed" ] && printf '%s' "${CI_LOCAL_RERUN_AFTER:-}")") ;;
  esac
  status "$job" "$state" "$desc"
  printf '%s\n' "$desc" > "$out/$job.status"
  # The fields a later plan and ci-audit.sh read: state, the full fp, its scope (planner blob7), runner class, narrowed.
  local -a extra=()
  [ -n "$fp" ] && extra+=(--arg fp "$fp"); [ -n "$fp" ] && [ -n "$plan_blob" ] && extra+=(--arg scope "$plan_blob")
  [ -n "$plan_runner" ] && extra+=(--arg runner "$plan_runner")
  [ -n "$rerun_failed" ] && [ -n "${CI_LOCAL_RERUN_AFTER:-}" ] && extra+=(--arg rerun_after "$CI_LOCAL_RERUN_AFTER")
  ledger verdict --arg job "$job" --arg state "$state" --arg kind "$kind" --arg decision ran \
    --arg description "$desc" --argjson narrowed "$([ "${narrowed:-0}" = 1 ] && echo true || echo false)" "${extra[@]}"
  echo "$job: $state (${secs}s)"
}

# ---- PLANNER HOOK (CI plan C10/C12) -----------------------------------------------------------------------------
# plan_job <job>: the planner's answer for one job of this run (ci-plan.sh, always the base's copy, never the head's),
# read from $out/plan.txt, one line:
#   run [<fp>] [shadow=<sha>]         run the job; <fp> goes on its status as `fp=<fp10>`; shadow names the green run
#                                     it would have reused (shadow mode logs a decision, the job runs)
#   reuse <sha> <fp> <blob7>          CI_REUSE=live: post `reused from <sha12>; fp=<fp10>; scope=<blob7>`, run nothing
# No plan line for the job: run, without an fp (in doubt, run).
plan_job() {
  local l fp shadow src
  l=$(awk -v j="$1" '$1 == j { $1 = ""; sub(/^ /, ""); print; exit }' "$out/plan.txt" 2>/dev/null)
  fp=$(printf '%s' "$l" | sed -nE 's/.* fp=([0-9a-f]{64})( .*)?$/\1/p')
  case "$l" in
    reuse\ *)
      src=$(printf '%s' "$l" | cut -d' ' -f2)
      if [[ "$src" =~ ^[0-9a-f]{40}$ ]] && [ -n "$fp" ] && [ -n "$plan_blob" ]; then echo "reuse $src $fp $plan_blob"
      else echo "run"; fi ;;
    run\ *)
      shadow=$(printf '%s' "$l" | sed -nE 's/.* shadow=([0-9a-f]{40})( .*)?$/\1/p')
      echo "run${fp:+ $fp}${shadow:+ shadow=$shadow}" ;;
    *) echo run ;;
  esac
}
# -----------------------------------------------------------------------------------------------------------------

# reuse_job <job> <source sha> <fp> <scope>: under the queue mutex, a live reuse: the status and the ledger's reuse
# event (a reuse is never a source: no chains), and a result the summary and the needs of other jobs read.
reuse_job() {
  local job=$1 desc
  desc=$(ci_status_reused "$2" "$3" "$4")
  status "$job" success "$desc"
  printf '%s\n' "$desc" > "$out/$job.status"
  ledger reuse --arg job "$job" --arg state success --arg fp "$3" --arg scope "$4" --arg source "$2" \
    --arg decision reused --arg runner "$plan_runner" --arg description "$desc"
  result "$job" success 0 0 reused 0 0 "reused from ${2:0:12}"
  echo "$job: reused from ${2:0:12}"
}

# keep_job <job>: --rerun-failed: the latest run's green result of the job, when that run tested this commit's tree.
keep_job() {
  local job=$1 res kind rest
  [ -n "$prev" ] && [ -n "$tested_tree" ] || return 1
  [ "$(cat "$prev/sha" 2>/dev/null)" = "$sha" ] && [ "$(cat "$prev/tree" 2>/dev/null)" = "$tested_tree" ] || return 1
  [ -s "$prev/$job.result" ] && [ -s "$prev/$job.status" ] || return 1
  read -r res _ _ kind rest < "$prev/$job.result"
  [ "$res" = success ] || return 1
  local f
  for f in result steps plan tests.json status; do [ -e "$prev/$job.$f" ] && cp "$prev/$job.$f" "$out/$job.$f"; done
  printf '%s\n' "kept from run $(cat "$prev/run-id" 2>/dev/null)" > "$out/$job.reason"
  status "$job" success "$(cat "$out/$job.status")"
  ledger kept --arg job "$job" --arg state success --arg from "$(cat "$prev/run-id" 2>/dev/null)" \
    --arg description "$(cat "$out/$job.status")"
  echo "$job: kept, green in run $(cat "$prev/run-id" 2>/dev/null)"
}

# The planner. Its base: the pull request's base, else the merge base with origin/main (for a commit on main, its
# first parent). No base, or a planner that fails: every job runs, without an fp.
plan_from="" plan_base=""
if [ -n "$pr" ]; then
  plan_from=$base_sha plan_base=$merge_base
else
  plan_from=$(git -C "$main" merge-base origin/main "$sha" 2>/dev/null) || plan_from=""
  [ "$plan_from" = "$sha" ] && { plan_from=$(git -C "$main" rev-parse -q --verify "$sha^1" 2>/dev/null) || plan_from=""; }
fi
: > "$out/plan.txt"
if [ -n "$plan_from" ]; then
  plan_args=(--self-from "$plan_from" "$main" "$sha")
  [ -n "$plan_base" ] && plan_args+=(--base "$plan_base")
  [ -n "$all" ] && plan_args+=(--all)
  [ -n "$audit" ] && plan_args+=(--audit)
  CI_LOCAL_ROOT=$root timeout "${CI_LOCAL_PLAN_TIMEOUT:-600}" bash "$here/ci-plan.sh" "${plan_args[@]}" \
    > "$out/plan.txt" 2> "$out/plan.log" || { echo "the planner failed (see $out/plan.log): every job runs" >&2; : > "$out/plan.txt"; }
else
  echo "no base to take the planner from: every job runs" > "$out/plan.log"
fi
plan_head=$(sed -n '1{/^# ci-plan /p}' "$out/plan.txt")
plan_blob=$(printf '%s' "$plan_head" | sed -nE 's/.* planner=([0-9a-f]{7})[0-9a-f]*( .*)?$/\1/p')
plan_runner=$(printf '%s' "$plan_head" | sed -nE 's/.* runner=([^ ]+)( .*)?$/\1/p')
[ "$plan_runner" = - ] && plan_runner=""
printf '%s\n' "$plan_runner" > "$out/runner"
# Live only by the owner's switch, never under --all, --audit or the kill switch (the planner says so too).
reuse_live=""
[ "${CI_REUSE:-shadow}" = live ] && [ -z "$all" ] && [ -z "$audit" ] && [ "${CI_SCOPE:-}" != all ] \
  && [ ! -e "$root/scope-all" ] && reuse_live=1

# Same tree (owner decision 2026-10-23, narrowing D9; D2 unchanged): a merge commit on main takes the result of its pull
# request head H (its second parent) when H's last --post run tested exactly this tree (its merge into the base, by tree
# hash), with the same ci.yml and runner class, and every job of it is a real green run (the newest local-ci/<job> status
# on H, kind ran, equal to that run's own status, at most CI_PLAN_MAX_AGE seconds old). Then every job posts `reused from
# <H sha12>; same tree` and a `same-tree` ledger event, and nothing runs. In any other case, and under --all, --audit,
# --rerun-failed or the kill switch, every job runs. ci-audit.sh checks these statuses like any reused one.
# not_same <why>: a merge commit that does not take its head's result says why, on stderr and in the run's folder.
not_same() { echo "same tree: not used, $1" >&2; echo "$1" > "$out/same-tree.why"; }
same_tree_source() {
  local h hout lines line j state desc at
  [ -z "$pr" ] && [ -n "$post" ] && [ -z "$all" ] && [ -z "$audit" ] && [ -z "$rerun_failed" ] || return 1
  h=$(git -C "$main" rev-parse -q --verify "$sha^2^{commit}" 2>/dev/null) || return 1
  [ "${CI_SCOPE:-}" != all ] && [ ! -e "${CI_PLAN_SCOPE_FILE:-$root/scope-all}" ] || { not_same "the scope-all kill switch"; return 1; }
  [ -n "$tested_tree" ] || { not_same "no tested tree"; return 1; }
  [ -n "$plan_runner" ] || { not_same "no runner class from the planner (see $out/plan.log)"; return 1; }
  hout=$root/${h:0:7}
  [ "$(cat "$hout/sha" 2>/dev/null)" = "$h" ] || { not_same "no run of the head ${h:0:7} here"; return 1; }
  [ "$(cat "$hout/tree" 2>/dev/null)" = "$tested_tree" ] || { not_same "the head's run tested another tree"; return 1; }
  [ "$(cat "$hout/runner" 2>/dev/null)" = "$plan_runner" ] || { not_same "another runner class"; return 1; }
  cmp -s "$hout/ci.yml" "$out/ci.yml" || { not_same "another ci.yml"; return 1; }
  # The newest status of each context, by time then id (as local-ci-status.sh picks it).
  lines=$(gh api --paginate "repos/$repo/commits/$h/statuses?per_page=100" \
    -q '.[] | select(.context | startswith("local-ci/")) | [.updated_at, (.id | tostring), .context, .state, (.description // "")] | @tsv') \
    || { not_same "cannot read the head's statuses"; return 1; }
  lines=$(printf '%s\n' "$lines" | tr -d '\r' | sed '/^$/d' | sort -t$'\t' -k1,1r -k2,2nr)
  for j in $jobs; do
    line=$(printf '%s\n' "$lines" | awk -F'\t' -v c="local-ci/$j" '$3 == c { print; exit }')
    IFS=$'\t' read -r at _ _ state desc <<<"$line"
    [ "$state" = success ] && [ -n "$desc" ] && [ "$desc" = "$(cat "$hout/$j.status" 2>/dev/null)" ] \
      || { not_same "$j: the head's newest status is ${state:-none} '$desc', its run posted '$(cat "$hout/$j.status" 2>/dev/null)'"; return 1; }
    [ "$(ci_status_get kind success "$desc")" = ran ] && [ "$(ci_status_get legacy success "$desc")" = 0 ] \
      || { not_same "$j: '$desc' is not a real run"; return 1; }
    at=$(date -u -d "$at" +%s 2>/dev/null) && [ $(( $(date -u +%s) - at )) -le "${CI_PLAN_MAX_AGE:-86400}" ] \
      || { not_same "$j: the head's status is older than ${CI_PLAN_MAX_AGE:-86400} s"; return 1; }
  done
  echo "$h"
}
# same_tree_job <job> <head sha>: under the queue mutex, the job takes the head's result (never a reuse source).
same_tree_job() {
  local job=$1 desc
  desc=$(ci_status_same_tree "$2")
  status "$job" success "$desc"
  printf '%s\n' "$desc" > "$out/$job.status"
  ledger same-tree --arg job "$job" --arg state success --arg source "$2" --arg tree "$tested_tree" \
    --arg decision reused --arg runner "$plan_runner" --arg description "$desc"
  result "$job" success 0 0 reused 0 0 "reused from ${2:0:12}; same tree"
  echo "$job: reused from ${2:0:12}; same tree"
}
same_src=$(same_tree_source) || same_src=""

serial=" ${CI_LOCAL_SERIAL:-} "
start=$(date +%s)
echo "local CI of $short ($repo)${merge_base:+, merged into base ${merge_base:0:7}}: $out (run $run_id)"
torun=""
for j in $jobs; do
  if [ -n "$same_src" ]; then q_locked same_tree_job "$j" "$same_src"; continue; fi
  if [ -n "$rerun_failed" ] && keep_job "$j"; then continue; fi
  plan=$(plan_job "$j") || plan=run
  case "$plan" in
    reuse\ *)
      read -r _ src fp blob <<<"$plan"
      if [ -n "$reuse_live" ]; then
        echo "reuse $fp" > "$out/$j.plan"
        q_locked reuse_job "$j" "$src" "$fp" "$blob"
        continue
      fi
      ledger decision --arg job "$j" --arg decision "would reuse" --arg source "$src" --arg fp "$fp" --arg scope "$plan_blob" --arg taken run
      echo "run $fp" > "$out/$j.plan" ;;
    run\ *shadow=*)
      ledger decision --arg job "$j" --arg decision "would reuse" --arg source "${plan##*shadow=}" \
        --arg fp "$(cut -d' ' -f2 <<<"$plan")" --arg scope "$plan_blob" --arg taken run
      printf '%s\n' "$plan" > "$out/$j.plan" ;;
    run|run\ *) printf '%s\n' "$plan" > "$out/$j.plan" ;;
    *) echo run > "$out/$j.plan" ;;
  esac
  torun+="$j "
done
ledger_end() { # the end line: every job's result, own and needs seconds, reason and test sets
  local rc=$1 j res secs skipped kind needs narrowed jobs_json="{}" one
  for j in $jobs; do
    res="" secs=0 skipped=0 kind="" needs=0 narrowed=0
    [ -s "$out/$j.result" ] && read -r res secs skipped kind needs narrowed < "$out/$j.result"
    one=$(jq -cn --arg res "${res:-none}" --argjson own "${secs:-0}" --argjson needs "${needs:-0}" --arg kind "${kind:-}" \
      --arg reason "$(cat "$out/$j.reason" 2>/dev/null)" --argjson skipped "${skipped:-0}" --argjson narrowed "${narrowed:-0}" \
      --argjson tests "$(cat "$out/$j.tests.json" 2>/dev/null || echo '{}')" \
      '{res: $res, own: $own, needs: $needs, kind: $kind, reason: $reason, skipped_locally: $skipped,
        narrowed: ($narrowed == 1), tests: $tests}' 2>/dev/null) || one='{}'
    jobs_json=$(jq -c --arg j "$j" --argjson o "$one" '. + {($j): $o}' <<<"$jobs_json" 2>/dev/null || echo "$jobs_json")
  done
  ledger end --argjson rc "$rc" --argjson t_req "$t_req" --argjson t_lock "${t_lock:-null}" --argjson t_start "$start" \
    --argjson t_end "$(date -u +%s)" --argjson aborted "$([ -n "$ended" ] && echo false || echo true)" \
    --argjson load "$(load)" --argjson jobs "$jobs_json"
}
load() { awk '{ printf "[%s,%s]", $1, $2 }' /proc/loadavg 2>/dev/null || echo null; }
ledger start --arg base "${merge_base:-$base_ref}" --arg tree "$tested_tree" --arg jobs "$(echo $jobs)" --argjson slot "${Q_SLOT:-1}" \
  --argjson t_req "$t_req" --argjson t_lock "$t_lock" --argjson t_start "$start" --argjson load "$(load)"
if [ -n "$archon_change" ] || [ -n "$all" ]; then
  ledger affected --arg scope archon-suites --arg change "$archon_change" --arg skip "$archon_skip" \
    --arg suites "$archon_suites" --argjson all "$([ -n "$all" ] && echo true || echo false)"
fi
running="$(ci_status_running "$$" "$host")"
for j in $torun; do status "$j" pending "$running"; done

# kill_tree <pid>: stops the process and everything under it (stopped first, so none starts the next step meanwhile).
kill_tree() {
  local p=$1 k
  kill -STOP "$p" 2>/dev/null
  for k in $(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$p" '$2 == p { print $1 }'); do kill_tree "$k"; done
  kill -KILL "$p" 2>/dev/null
}

# stop_result <job>: the result of a job the watcher stopped (.stop: "timedout <min>" or "cancelled <why>").
stop_result() {
  local job=$1 how arg t0 secs
  read -r how arg < "$out/$job.stop"
  t0=$(cat "$out/$job.started" 2>/dev/null || date +%s); secs=$(( $(date +%s) - t0 ))
  case "$how" in
    timedout) result "$job" failure "$secs" 0 timedout 0 0 "timed out after $arg min" ;;
    *) result "$job" cancelled "$secs" 0 cancelled 0 0 "cancelled: $arg" ;;
  esac
}

# launch_job <job>: runs the job in its own process, which the watcher may stop, then reports it.
launch_job() {
  local job=$1 pid
  if [ -s "$out/$job.stop" ]; then stop_result "$job"; finish_job "$job"; return; fi
  ( run_job "$job" ) &
  pid=$!; echo "$pid" > "$out/$job.pid"
  wait "$pid"
  if [ -s "$out/$job.stop" ]; then stop_result "$job"
  elif [ ! -s "$out/$job.result" ]; then result "$job" failure 0 0 infra 0 0 "the job ended without a result"
  fi
  finish_job "$job"
}

# stop_job <job> <timedout|cancelled> <arg>: once per job; a job not started yet (needs, serial) never starts.
stop_job() {
  [ -e "$out/$1.stop" ] || [ -s "$out/$1.result" ] && return 0
  echo "$2 $3" > "$out/$1.stop"
  [ -s "$out/$1.pid" ] && kill_tree "$(cat "$out/$1.pid")"
  echo "$1: stopped, $2${3:+ ($3)}" >&2
}

# The watcher (CI plan C16): every second, the first red at once, timeout-minutes, and fail-fast (D6).
fail_fast=${CI_LOCAL_FAIL_FAST:-when-queued}
case "$fail_fast" in when-queued|always|never) ;; *) fail_fast=when-queued ;; esac
declare -A limit=()
for j in $torun; do
  limit[$j]=$(yq ".jobs.\"$j\".\"timeout-minutes\" // 360" "$out/ci.yml" 2>/dev/null | tr -d '\r')
  [[ "${limit[$j]}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || limit[$j]=360
done
pids=()
( for j in $torun; do
    [[ "$serial" == *" $j "* ]] || continue
    launch_job "$j"
  done ) &
pids+=($!)
for j in $torun; do
  [[ "$serial" == *" $j "* ]] && continue
  launch_job "$j" &
  pids+=($!)
done
first_red="" cancelled=""
while :; do
  alive=""
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
  now=$(date +%s)
  for j in $torun; do
    if [ -s "$out/$j.result" ]; then
      read -r res _ <<<"$(cat "$out/$j.result")"
      if [ -z "$first_red" ] && [ "$res" != success ] && [ "$res" != cancelled ]; then
        first_red=$j
        echo "first red: $j ($res$([ -s "$out/$j.reason" ] && echo ", $(cat "$out/$j.reason")")) after $((now - start))s" >&2
        ledger first-red --arg job "$j" --arg state "$res" --argjson after "$((now - start))"
      fi
    elif [ -s "$out/$j.started" ] && [ ! -e "$out/$j.stop" ]; then
      if awk -v n="$now" -v s="$(cat "$out/$j.started")" -v m="${limit[$j]}" 'BEGIN { exit !(n - s >= m * 60) }'; then
        stop_job "$j" timedout "${limit[$j]}"
      fi
    fi
  done
  if [ -n "$first_red" ] && [ -z "$cancelled" ] && [ "$fail_fast" != never ]; then
    why=""
    if [ "$fail_fast" = always ]; then why="$first_red failed (CI_LOCAL_FAIL_FAST=always)"
    elif other=$(q_locked q_queued_other "$qn") && [ -n "$other" ]; then why="$first_red failed and run #$other is queued"
    fi
    if [ -n "$why" ]; then
      cancelled=1
      ledger fail-fast --arg job "$first_red" --arg mode "$fail_fast" --arg why "$why"
      for j in $torun; do stop_job "$j" cancelled "$why"; done
    fi
  fi
  [ -n "$alive" ] || break
  sleep "${CI_LOCAL_WATCH_POLL:-1}"
done
wait

total=$(( $(date +%s) - start ))
ok=0
{
  echo "local CI of $sha${merge_base:+ merged into $merge_base}: wall time ${total}s"
  for j in $jobs; do
    read -r res secs _ _ needs _ < "$out/$j.result"
    [ "$res" = success ] || ok=1
    printf '%-16s %-8s %4ss%s%s\n' "$j" "$res" "$secs" "${needs:+$([ "${needs:-0}" -gt 0 ] && echo "  (+${needs}s waiting for needs)")}" \
      "$([ -s "$out/$j.reason" ] && echo "  ($(cat "$out/$j.reason"))")"
    cat "$out/$j.steps" 2>/dev/null
  done
} > "$out/summary.txt"
cat "$out/summary.txt"

if [ -z "$keep" ]; then
  for j in $jobs; do git -C "$main" worktree remove --force "$out/wt-$j" 2>/dev/null; done
  git -C "$main" worktree prune
fi
ended=1
exit $ok
