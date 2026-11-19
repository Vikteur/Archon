#!/usr/bin/env bash
# The merge-path scenario harness (ROADMAP R21, T16; owner decisions 2026-10-20 D7 merge at once, D8 approvals (in chat since 2026-11-19), D14 push guard): the real scripts chained end to end against a bare origin, so the
# defects that sit at the seams between them (a quote between nodes, a merge commit nothing fetched, a renamed CI job, a
# rewritten branch, a token commit making a pull request behind, an unapproved STOP item) fail here, not in a live run.
# The unit tests stub each script's neighbours; this one stubs only what is outside the repo:
#   gh       a fake GitHub over the bare origin: pull requests are JSON files, the head is the origin branch, `pr merge
#            --match-head-commit` makes a --no-ff merge commit in the bare repo and refuses a moved head, `api compare`
#            and the commit statuses are computed from git and from the statuses the CI stub posted;
#   archon   `workflow get` (a run id or a prefix of one) and `complete --force` (removes the worktree and the branch);
#   backlog  `task view --json` and `task edit` over a JSON file per ticket, also rewriting the ticket's file;
#   ci-local the runner local-ci-run.sh calls: it posts one local-ci/<job> status per job of the commit's own ci.yml;
#   notify-owner, the token-report script, and sleep (capped, so the polls run fast).
# Real: open-pr, local-ci-run, local-ci-status, ci-by-sha, auto-merge, wait-merge, ready-runs, merge-turn, merge-ready,
# stop-check (+ stop-lib, the real policy, approvals recorded with stop-lib record), main-ci, close-out, commit-tickets,
# sync-main, park-ticket, and push-guard as the clone's pre-push hook. No network, temp dirs only.
# Scenarios (the numbers of the verification plan C7, then the extras):
#   1 no commit on main: merged, main-ci runs on the merge commit      9 a short run id finds the ready run
#   2 a backlog-only commit lands: not behind; main-ci runs on the merge  3 docs/retro: not behind; src/: behind
#   4 the merge commit is not local: main-ci fetches it                  5 a quoted pull request number
#   6 a renamed CI job (and its deploy approval: covered)                7 a head pushed after ready
#   8 a rewritten branch after a resume: the lease refuses               10 a duplicate CI request on one head
#   11 an unapproved STOP item is held                                   12 hold marker, 13 head change during the turn,
#   14 main-ci with no result and with --check, 15 close-out with a ticket and --flush-reports, 16 push-guard, 17 park-ticket.
# Usage: bash .archon/scripts/test/merge-path.test.sh   (exit 0 = all pass)
set -uo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$scripts/../.." && pwd)"
pass=0; fail=0
root="$(mktemp -d)"
trap 'jobs -p | xargs -r kill 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$root"' EXIT
REAL_SLEEP=$(command -v sleep)
# No Archon or user git settings leak in: the Archon env's core.hooksPath would skip the pre-push guard.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$root/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$root/bin"
export LOCAL_CI=on LOCAL_CI_UNTIL=2999-12-31 CI_GRACE_POLLS=2 LOCAL_CI_WAIT=0 LOCAL_CI_POLLS=2
export MERGE_TURN_POLL_SECONDS=1 AUTO_MERGE_POLL_SECONDS=1 MERGE_POLL_SECONDS=1 READY_POLL_SECONDS=1
export MAIN_CI_FETCH_SLEEP=0 MAIN_CI_GRACE_POLLS=1 MAIN_CI_PENDING_POLLS=1 MERGE_READY_TIMEOUT=60
# ci-queue.sh none-check waits CI_NONE_GRACE seconds by the clock (60 by default; the capped sleep does not shorten it)
# before ci-by-sha answers "none". It must stay far below MERGE_READY_TIMEOUT: at 60 the two deadlines raced, and under
# load merge-ready's timeout won (7a got "still open after 60s" instead of "auto-merge: none").
export CI_NONE_GRACE=2
export CI_LOCAL="$root/bin/ci-local" NOTIFY_OWNER="$root/bin/notify-owner" REAL_SLEEP
export PATH="$root/bin:$PATH"

# ---------------------------------------------------------------------------------------------------------------- stubs
cat > "$root/bin/sleep" <<'STUB'
#!/usr/bin/env bash
# Every poll of every script, capped at a tenth of a second.
exec "$REAL_SLEEP" 0.1
STUB

cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
# A fake GitHub for o/repo over the bare origin $FAKE_ORIGIN; pull requests are $FAKE/prs/<n>.json.
set -uo pipefail
echo "gh $*" >> "$FAKE/gh.log"
og() { git --git-dir="$FAKE_ORIGIN" "$@"; }
pos=() q="" json="" head_opt="" base_opt="" title="" bodyfile="" body="" state_opt="" match="" draft=false
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--jq) q=$2; shift ;;
    --json) json=$2; shift ;;
    --repo|-R|--limit|-H|--commit|-F|-f) shift ;;
    --head) head_opt=$2; shift ;;
    --base) base_opt=$2; shift ;;
    --title) title=$2; shift ;;
    --body-file) bodyfile=$2; shift ;;
    --body) body=$2; shift ;;
    --state) state_opt=$2; shift ;;
    --match-head-commit) match=$2; shift ;;
    --draft) draft=true ;;
    --merge|--paginate) ;;
    *) pos+=("$1") ;;
  esac
  shift
done
out() { # out <json>: as gh prints it: the -q filter applied (raw, a null prints nothing), or the JSON
  if [ -n "$q" ]; then printf '%s' "$1" | jq -r "$q" | grep -vx null; return 0; fi
  printf '%s\n' "$1"
}
num() { local a=${1:-}; a=${a%/}; echo "${a##*/}"; }
pr_obj() { # pr_obj <n>: the pull request as JSON, head, mergeable and files computed from the bare origin
  local f="$FAKE/prs/$1.json" st br h mergeable=UNKNOWN files mb
  [ -f "$f" ] || return 1
  st=$(jq -r .state "$f") br=$(jq -r .headRefName "$f")
  if [ "$st" = OPEN ]; then h=$(og rev-parse -q --verify "refs/heads/$br") || h=$(jq -r .headRefOid "$f")
  else h=$(jq -r .headRefOid "$f"); fi
  if [ "$st" = OPEN ]; then
    if og merge-tree --write-tree refs/heads/main "$h" >/dev/null 2>&1; then mergeable=MERGEABLE; else mergeable=CONFLICTING; fi
  fi
  mb=$(og merge-base refs/heads/main "$h" 2>/dev/null)
  files=$(og diff --name-only "$mb" "$h" 2>/dev/null | jq -R '{path: .}' | jq -s .)
  jq --arg h "$h" --arg m "$mergeable" --argjson files "${files:-[]}" \
    '. + {headRefOid: $h, mergeable: $m, files: $files, url: "https://github.com/o/repo/pull/\(.number)"}' "$f"
}
all_prs() { local f; for f in "$FAKE"/prs/*.json; do [ -f "$f" ] && pr_obj "$(basename "$f" .json)"; done | jq -s .; }
set_pr() { local f="$FAKE/prs/$1.json"; jq "$2" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
rev() { if [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then echo "$1"; else og rev-parse "refs/heads/$1"; fi; }

case "${pos[0]:-} ${pos[1]:-}" in
  "repo view") out '{"nameWithOwner": "o/repo"}' ;;
  "pr view") n=$(num "${pos[2]:-}"); o=$(pr_obj "$n") || { echo "no pull request $n" >&2; exit 1; }; out "$o" ;;
  "pr list")
    out "$(all_prs | jq --arg h "$head_opt" --arg s "${state_opt^^}" \
      '[.[] | select(($h == "" or .headRefName == $h) and ($s == "" or $s == "ALL" or .state == $s))]')" ;;
  "pr create")
    n=$(( $(ls "$FAKE"/prs/*.json 2>/dev/null | wc -l) + 7 ))
    [ -n "$bodyfile" ] && body=$(cat "$bodyfile")
    jq -n --argjson n "$n" --arg br "$head_opt" --arg base "${base_opt:-main}" --arg t "$title" --arg b "$body" \
      --argjson d "$draft" '{number: $n, headRefName: $br, baseRefName: $base, state: "OPEN", isDraft: $d, title: $t,
      body: $b, mergeCommit: null, reviewRequests: [], reviews: []}' > "$FAKE/prs/$n.json"
    echo "https://github.com/o/repo/pull/$n" ;;
  "pr ready") set_pr "$(num "${pos[2]}")" '.isDraft = false' ;;
  "pr comment") n=$(num "${pos[2]}"); printf '%s\n' "$body" >> "$FAKE/prs/$n.comments" ;;
  "pr merge")
    n=$(num "${pos[2]}"); o=$(pr_obj "$n") || exit 1
    h=$(jq -r .headRefOid <<< "$o") br=$(jq -r .headRefName <<< "$o")
    [ "$(jq -r .state <<< "$o")" = OPEN ] || { echo "pull request $n is not open" >&2; exit 1; }
    if [ -n "$match" ] && [ "$match" != "$h" ]; then
      echo "Head branch was modified. Review and try the merge again." >&2; echo "refused $n $match" >> "$FAKE/merges.log"; exit 1
    fi
    tree=$(og merge-tree --write-tree refs/heads/main "$h") || { echo "merge conflict" >&2; exit 1; }
    c=$(og commit-tree "$tree" -p refs/heads/main -p "$h" -m "Merge pull request #$n from o/$br")
    og update-ref refs/heads/main "$c"
    set_pr "$n" --arg h "$h" --arg c "$c" '.state = "MERGED" | .headRefOid = $h | .mergeCommit = {oid: $c}' 2>/dev/null \
      || { f="$FAKE/prs/$n.json"; jq --arg h "$h" --arg c "$c" '.state = "MERGED" | .headRefOid = $h | .mergeCommit = {oid: $c}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
    echo "merged $n $h $c" >> "$FAKE/merges.log" ;;
  "api graphql") echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  "run list") out '[]' ;;
  api\ *)
    path=${pos[1]}
    case "$path" in
      repos/o/repo/compare/*)
        spec=${path#repos/o/repo/compare/}; a=$(rev "${spec%%...*}") b=$(rev "${spec#*...}")
        mb=$(og merge-base "$a" "$b")
        files=$(og diff --name-status -M "$mb" "$b" | awk -F'\t' '{ if ($1 ~ /^R/) print $3 "\t" $2; else print $2 "\t" }' \
          | jq -R 'split("\t") | {filename: .[0]} + (if .[1] != "" then {previous_filename: .[1]} else {} end)' | jq -s .)
        jq -n --argjson ahead "$(og rev-list --count "$a..$b")" --argjson behind "$(og rev-list --count "$b..$a")" \
          --argjson files "$files" '{ahead_by: $ahead, behind_by: $behind, files: $files}' ;;
      repos/o/repo/commits/*/statuses*)
        # The list endpoint local-ci-status.sh reads: every status with its time, id and a description in the one
        # status grammar (a real run).
        sha=${path#repos/o/repo/commits/}; sha=${sha%%/*}
        out "$( (cat "$FAKE/status/$sha" 2>/dev/null || true) | jq -R 'split(" ") | {context: .[0], state: .[1],
          description: "\(.[1]) in 1s on fakehost", updated_at: "2026-10-20T00:00:00Z", id: 1}' | jq -s .)" ;;
      repos/o/repo/commits/*/status*)
        sha=${path#repos/o/repo/commits/}; sha=${sha%%/*}
        out "$( (cat "$FAKE/status/$sha" 2>/dev/null || true) | jq -R 'split(" ") | {context: .[0], state: .[1]}' | jq -s '{statuses: .}')" ;;
      repos/o/repo/commits/*)   # a branch's tip (auto-merge.sh asks main's before it merges, D9)
        ref=${path#repos/o/repo/commits/}; sha=$(og rev-parse -q --verify "refs/heads/$ref^{commit}" || og rev-parse -q --verify "$ref^{commit}") || exit 1
        out "$(jq -n --arg s "$sha" '{sha: $s}')" ;;
      *) exit 1 ;;
    esac ;;
  *) echo "gh stub: unhandled: ${pos[*]}" >&2; exit 1 ;;
esac
STUB

cat > "$root/bin/ci-local" <<'STUB'
#!/usr/bin/env bash
# ci-local.sh --post <pr number|sha>: one local-ci/<job> status per job of the commit's own ci.yml; the outcome is
# $FAKE/ci-outcome/<sha> (success when missing; "nothing" posts no status).
echo "ci-local $*" >> "$FAKE/gh.log"
t=$2
if [[ "$t" =~ ^[0-9]+$ ]] && [ ${#t} -lt 7 ]; then sha=$(gh pr view "$t" --json headRefOid -q .headRefOid); else sha=$t; fi
echo "$sha" >> "$FAKE/ci-runs.log"
outcome=$(cat "$FAKE/ci-outcome/$sha" 2>/dev/null || echo success)
[ "$outcome" = nothing ] && exit 0
: > "$FAKE/status/$sha"
for job in $(git show "$sha:.github/workflows/ci.yml" | yq '.jobs | keys | .[]'); do
  echo "local-ci/$job $outcome" >> "$FAKE/status/$sha"
done
STUB

cat > "$root/bin/archon" <<'STUB'
#!/usr/bin/env bash
echo "archon $*" >> "$FAKE/archon.log"
case "$1 ${2:-}" in
  "workflow get")
    m=$(grep -E "^$3" "$FAKE/runs" 2>/dev/null)
    if [ "$(printf '%s' "$m" | grep -c .)" -eq 1 ]; then
      read -r id st <<< "$m"; jq -n --arg id "$id" --arg st "$st" '{id: $id, status: $st}'
    else echo '{"error": "no run matches"}'; fi ;;
  "workflow runs") echo '{"runs": []}' ;;
  "complete --force")
    branch=$3
    wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=substr($0,10)} $1=="branch" && $2==b {print w}')
    [ -n "$wt" ] && git worktree remove --force "$wt"
    git branch -D "$branch" >/dev/null 2>&1
    git push -q origin --delete "$branch" 2>/dev/null
    exit 0 ;;
esac
STUB

cat > "$root/bin/backlog" <<'STUB'
#!/usr/bin/env bash
# task view <id> --json | task edit <id> [-s <status>] [--add-label l] [--remove-label l] [--append-notes n]
echo "backlog $*" >> "$FAKE/backlog.log"
f="$FAKE/tickets/$3.json"
[ -f "$f" ] || { echo "no task $3" >&2; exit 1; }
case "$1 $2" in
  "task view") jq '{task: .}' "$f" ;;
  "task edit")
    id=$3; shift 3
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) jq --arg v "$2" '.status = $v' "$f" > "$f.t" ;;
        --add-label) jq --arg v "$2" '.labels = ((.labels + [$v]) | unique)' "$f" > "$f.t" ;;
        --remove-label) jq --arg v "$2" '.labels -= [$v]' "$f" > "$f.t" ;;
        --append-notes) jq --arg v "$2" '.notes += $v + "\n"' "$f" > "$f.t" ;;
        *) echo "backlog stub: $1?" >&2; exit 1 ;;
      esac
      mv "$f.t" "$f"; shift 2
    done
    jq -r '"id: \(.id)\nstatus: \(.status)\nlabels: \(.labels | join(","))\n\(.notes)"' "$f" > "$(jq -r .path "$f")" ;;
esac
STUB

cat > "$root/bin/notify-owner" <<'STUB'
#!/usr/bin/env bash
echo "notify $*" >> "$FAKE/notify.log"
STUB
chmod +x "$root/bin/"*

# ------------------------------------------------------------------------------------------------------------- fixtures
check() { # check <name> <condition exit code> [<file to show>]
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"
    [ -n "${3:-}" ] && [ -f "$3" ] && sed 's/^/    /' "$3" | tail -n 25; fi
}
t() { "$@" >/dev/null 2>&1; echo $?; }   # t <command...>: its exit code, for check

world() { # world <name>: a bare origin o/repo.git with main seeded, the main checkout W, a fake GitHub FAKE
  D="$root/$1" W="$root/$1/main"
  export FAKE="$D/fake" FAKE_ORIGIN="$D/o/repo.git" MERGE_QUEUE_DIR="$D/merge-queue" READY_RUNS_DIR="$D/merge-queue/ready"
  mkdir -p "$FAKE/prs" "$FAKE/status" "$FAKE/tickets" "$FAKE/ci-outcome" "$D/o" "$MERGE_QUEUE_DIR"
  : > "$FAKE/gh.log"; : > "$FAKE/notify.log"; : > "$FAKE/ci-runs.log"; : > "$FAKE/merges.log"; : > "$FAKE/runs"
  git init -q --bare -b main "$FAKE_ORIGIN"
  git clone -q "$FAKE_ORIGIN" "$W" 2>/dev/null
  mkdir -p "$W/src" "$W/.github/workflows" "$W/backlog/tasks" "$W/docs/retro" "$W/docs/tokenomics" \
    "$W/scripts/tokenomics" "$W/.archon/stop/approvals"
  echo app > "$W/src/app.txt"
  printf 'name: ci\njobs:\n  build:\n    runs-on: x\n  test:\n    runs-on: x\n' > "$W/.github/workflows/ci.yml"
  echo 'project_name: t' > "$W/backlog/config.yml"
  echo retros > "$W/docs/retro/README.md"
  cp "$repo_root/.archon/stop/policy.json" "$W/.archon/stop/policy.json"
  # The token-report script: one cumulative report under docs/tokenomics/, committed and pushed to main.
  cat > "$W/scripts/tokenomics/commit-reports.sh" <<'EOF'
cd "$1" && mkdir -p docs/tokenomics && date +%s%N > docs/tokenomics/report.md && git add docs/tokenomics && git commit -qm "docs(tokenomics): reports" \
  && git push -q origin HEAD:main && echo reports >> "$FAKE/reports.log"
EOF
}
ticket() { # ticket <TASK-id> [<label>...]: a ticket file in backlog/tasks and its JSON for the backlog stub
  local id=$1; shift
  local p="$W/backlog/tasks/task-${id#TASK-} - Ticket ${id#TASK-}.md"
  jq -n --arg id "$id" --arg p "$p" --args '{id: $id, title: "Ticket", status: "In Progress", labels: $ARGS.positional,
    path: $p, parentTaskId: null, notes: ""}' "$@" > "$FAKE/tickets/$id.json"
  printf 'id: %s\nstatus: In Progress\n' "$id" > "$p"
}
approve() { # approve <TASK-id> <category>: an approvals file recorded with stop-lib record (the owner's chat yes), in the checkout
  local d="$D/draft.json"
  node "$scripts/stop-lib.js" draft-add "$W/.archon/stop/policy.json" "$d" "$1" "$2" "harness approval" >/dev/null
  node "$scripts/stop-lib.js" record "$W/.archon/stop/policy.json" "$d" "$W/.archon/stop/approvals" "$(date -u +%FT%TZ)" \
    --by harness --words "ja" >/dev/null
}
publish() { # publish: the seed commit on origin/main, then the push guard switched on as the clone's pre-push hook
  git -C "$W" add -A && git -C "$W" commit -qm seed && git -C "$W" push -q origin main
  printf '#!/usr/bin/env bash\nexec bash "%s/push-guard.sh" check "$@"\n' "$scripts" > "$W/.git/hooks/pre-push"
  chmod +x "$W/.git/hooks/pre-push"
}
run_branch() { # run_branch <name>: a run worktree on build-feature-<name> off origin/main; sets WT
  WT="$D/wt-$1"
  git -C "$W" fetch -q origin
  git -C "$W" worktree add -q -b "build-feature-$1" "$WT" origin/main 2>/dev/null
}
commit_in() { # commit_in <dir> <file> <text> <subject>
  mkdir -p "$(dirname "$1/$2")"; echo "$3" > "$1/$2"; git -C "$1" add -A; git -C "$1" commit -qm "$4"
}
open_pr() { # open_pr <TASK-id> [<STOP text>]: open-pr.sh from WT; sets PR, PRN, HEAD_SHA
  printf '## Summary\nwork\n\nSTOP items: %s\n' "${2:-touches no STOP item.}" > "$D/body.md"
  local o; o=$(cd "$WT" && bash "$scripts/open-pr.sh" main "feat: $1 harness work" "$D/body.md" 2>>"$D/open-pr.err")
  PR=$(jq -r .pr <<< "$o") PRN=${PR##*/} HEAD_SHA=$(jq -r .sha <<< "$o")
}
ci_head() { (cd "$WT" && bash "$scripts/local-ci-run.sh" "$(git rev-parse HEAD)" 2>>"$D/ci.err"); }
ready() { # ready: the run's auto-merge loop in --no-merge mode; sets READY_OUT, READY_RC
  READY_OUT=$(cd "$WT" && bash "$scripts/auto-merge.sh" "$PR" --no-merge 2>>"$D/am.err"); READY_RC=$?
}
merge_ready() { # merge_ready <args...>: from the main checkout; sets MR (stdout), MR_RC
  MR=$(cd "$W" && bash "$scripts/merge-ready.sh" "$@" 2>"$D/mr.err"); MR_RC=$?
  printf 'merge-ready exit %s, stdout: %s\n' "$MR_RC" "$MR" >> "$D/mr.err"   # a failed check shows the answer too
}
mr_field() { jq -r ".$1" <<< "$MR"; }
origin_main() { git --git-dir="$FAKE_ORIGIN" rev-parse refs/heads/main; }
pr_state() { jq -r .state "$FAKE/prs/$1.json"; }
queued() { grep -qxF "$1" "$MERGE_QUEUE_DIR/queue" 2>/dev/null; }
wait_for() { # wait_for <file> <text> [<seconds>]: until the file holds the text, by the clock (default 30 s)
  local end=$(( $(date +%s) + ${3:-30} ))
  until grep -qF -- "$2" "$1" 2>/dev/null; do [ "$(date +%s)" -ge "$end" ] && return 1; "$REAL_SLEEP" 0.1; done
}

# ------------------------------------------------------------------------------------------------------------ scenarios
# 1, 4, 9 and part of 15/16: the whole chain on a `none` pull request with no commit on main in between.
world one; ticket TASK-101; publish
run_branch one; commit_in "$WT" src/feature.txt one "feat: one"; open_pr TASK-101
check "1 open-pr opened a draft pull request" $([ "$PRN" = 7 ] && [ "$(jq -r .isDraft "$FAKE/prs/7.json")" = true ]; echo $?) "$D/open-pr.err"
ci_head
ready
check "1 auto-merge --no-merge: ready on the head, no merge" $([ "$READY_RC" -eq 0 ] && [ "$(jq -r .state <<< "$READY_OUT")" = ready ] \
  && [ "$(jq -r .sha <<< "$READY_OUT")" = "$HEAD_SHA" ] && [ "$(pr_state 7)" = OPEN ] && [ ! -s "$FAKE/merges.log" ]; echo $?) "$D/am.err"
check "1 the draft was marked ready" $([ "$(jq -r .isDraft "$FAKE/prs/7.json")" = false ]; echo $?)
RUN=a1b2c3d4e5f60718293a4b5c6d7e8f90; echo "$RUN running" > "$FAKE/runs"
(cd "$WT" && RUN_ID=$RUN BACKLOG_CWD="$W" bash "$scripts/wait-merge.sh" "$PR" > "$D/wm.out" 2> "$D/wm.err") & wm=$!
rr=$(cd "$W" && timeout 30 bash "$scripts/ready-runs.sh" wait "${RUN:0:8}" --timeout 20 2>"$D/rr.err")
check "9 ready-runs wait <short id> finds the ready run" $([ "$(jq -r .state <<< "$rr")" = ready ] && [ "$(jq -r .run <<< "$rr")" = "$RUN" ] \
  && [ "$(jq -r .pr <<< "$rr")" = "$PR" ]; echo $?) "$D/rr.err"
before=$(origin_main)
merge_ready "$PR"
check "1 merge-ready: exit 0, merged, verdict none" $([ "$MR_RC" -eq 0 ] && [ "$(mr_field state)" = merged ] && [ "$(mr_field verdict)" = none ] \
  && [ "$(mr_field head)" = "$HEAD_SHA" ]; echo $?) "$D/mr.err"
merge=$(jq -r .mergeCommit.oid "$FAKE/prs/7.json")
check "1 a --no-ff merge commit of the checked head on origin main" $([ "$(origin_main)" = "$merge" ] \
  && [ "$(git --git-dir="$FAKE_ORIGIN" rev-parse "$merge^1")" = "$before" ] && [ "$(git --git-dir="$FAKE_ORIGIN" rev-parse "$merge^2")" = "$HEAD_SHA" ]; echo $?)
check "1 the audit comment names the head, the merge and the verdict" $(grep -q "merged head $HEAD_SHA as $merge" "$FAKE/prs/7.comments" \
  && grep -q 'STOP verdict: none' "$FAKE/prs/7.comments" && grep -q 'merge-ledger: by=merge-ready.sh' "$FAKE/prs/7.comments"; echo $?)
check "1 the merge-ready.log line" $([ "$(tail -n 1 "$MERGE_QUEUE_DIR/merge-ready.log" | jq -r .state)" = merged ]; echo $?)
wait "$wm"; wm_rc=$?
check "1 wait-merge: merged, the merge and head, CI green by the local statuses" $([ "$wm_rc" -eq 0 ] && [ "$(jq -r .state "$D/wm.out")" = merged ] \
  && [ "$(jq -r .merge "$D/wm.out")" = "$merge" ] && [ "$(jq -r .head "$D/wm.out")" = "$HEAD_SHA" ] && [ "$(jq -r .ci "$D/wm.out")" = green ]; echo $?) "$D/wm.err"
check "1 wait-merge cleared the ready record and the queue" $([ ! -f "$READY_RUNS_DIR/$RUN.json" ] && ! queued "$PR"; echo $?)
check "4 the run worktree does not have the merge commit yet" $(git -C "$WT" cat-file -e "$merge^{commit}" 2>/dev/null; [ $? -ne 0 ]; echo $?)
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" "$merge" "$HEAD_SHA" 2>"$D/mc.err"); mc_rc=$?
check "4 main-ci fetched the merge commit (no 'not in the clone')" $([ "$mc_rc" -eq 0 ] && git -C "$WT" cat-file -e "$merge^{commit}" \
  && ! grep -q 'not in the clone\|cannot tell' "$D/mc.err" <<< "$mc"; echo $?) "$D/mc.err"
check "1 main-ci runs local CI on the merge commit, even with the head's tree (C13), green" $([ "$(jq -r .state <<< "$mc")" = green ] \
  && [ "$(jq -r .sha <<< "$mc")" = "$merge" ] && grep -qx "$merge" "$FAKE/ci-runs.log"; echo $?) "$D/mc.err"
co=$(cd "$WT" && bash "$scripts/close-out.sh" "" "$PR" "$W" 2>"$D/co.err"); co_rc=$?
check "1 close-out: branch deleted, worktree removed, exit 0" $([ "$co_rc" -eq 0 ] && [ "$(jq -r .branch <<< "$co")" = deleted ] \
  && [ "$(jq -r .worktree <<< "$co")" = removed ] && [ ! -d "$WT" ] \
  && ! git --git-dir="$FAKE_ORIGIN" show-ref --verify -q refs/heads/build-feature-one; echo $?) "$D/co.err"
check "15 close-out with no other run PR open commits the token reports through the guard (exempt)" $(grep -q reports "$FAKE/reports.log" 2>/dev/null \
  && [ "$(git --git-dir="$FAKE_ORIGIN" diff-tree --no-commit-id -r --name-only refs/heads/main)" = docs/tokenomics/report.md ] \
  && grep -q 'push-guard: .* is exempt' "$D/co.err"; echo $?) "$D/co.err"
check "1 the main checkout is pulled to origin main" $([ "$(git -C "$W" rev-parse HEAD)" = "$(origin_main)" ]; echo $?)

# 2 and 17: a backlog-only commit lands while the pull request waits (park-ticket on another ticket, through
# commit-tickets.sh and the guard): not behind (TASK-73); main-ci runs local CI on the merge commit (TASK-72 AC2).
world two; ticket TASK-201; ticket TASK-202; publish
run_branch two; commit_in "$WT" src/two.txt two "feat: two"; open_pr TASK-201; ci_head; ready
RUN2=b2c3d4e5f6071829a3b4c5d6e7f8091a; echo "$RUN2 running" > "$FAKE/runs"
(cd "$W" && bash "$scripts/ready-runs.sh" mark "$RUN2" "https://github.com/o/repo/pull/99" >/dev/null 2>&1)
(cd "$W" && bash "$scripts/merge-turn.sh" wait https://github.com/o/repo/pull/99 >/dev/null 2>&1) || true   # not a known PR: leaves at once
echo "https://github.com/o/repo/pull/99" >> "$MERGE_QUEUE_DIR/queue"
pk=$(cd "$WT" && bash "$scripts/park-ticket.sh" TASK-202 -m "held: harness" --run "$RUN2" --pr https://github.com/o/repo/pull/99 2>&1); pk_rc=$?
check "17 park-ticket: exit 0, label parked, status unchanged" $([ "$pk_rc" -eq 0 ] && [ "$(jq -r '.labels | index("parked") != null' "$FAKE/tickets/TASK-202.json")" = true ] \
  && [ "$(jq -r .status "$FAKE/tickets/TASK-202.json")" = "In Progress" ]; echo $?)
check "17 park-ticket dropped the pull request from the queue and cleared the run's ready record" $(! queued https://github.com/o/repo/pull/99 \
  && [ ! -f "$READY_RUNS_DIR/$RUN2.json" ]; echo $?)
check "17/16 the park commit reached origin main through the guard (backlog/ only: exempt)" $(git --git-dir="$FAKE_ORIGIN" log -1 --format=%s refs/heads/main | grep -q 'chore(backlog): TASK-202' \
  && [ "$(git --git-dir="$FAKE_ORIGIN" diff-tree --no-commit-id -r --name-only refs/heads/main)" = "backlog/tasks/task-202 - Ticket 202.md" ]; echo $?)
check "17 the main checkout fast-forwarded (sync-main)" $([ "$(git -C "$W" rev-parse HEAD)" = "$(origin_main)" ]; echo $?)
merge_ready "$PR"
check "2 a backlog-only commit on main: not behind, merged" $([ "$MR_RC" -eq 0 ] && [ "$(mr_field state)" = merged ]; echo $?) "$D/mr.err"
merge=$(jq -r .mergeCommit.oid "$FAKE/prs/7.json")
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" "$merge" "$HEAD_SHA" 2>"$D/mc.err"); mc_rc=$?
check "2 main-ci runs local CI on the merge commit, green (C13)" $([ "$mc_rc" -eq 0 ] && [ "$(jq -r .state <<< "$mc")" = green ] \
  && grep -qx "$merge" "$FAKE/ci-runs.log"; echo $?) "$D/mc.err"

# 3: a docs/retro commit lands (retro-commit.sh's path, exempt at the guard): merge-turn.sh skips the guard's exempt
# paths (`push-guard.sh paths`: backlog/, docs/retro/, docs/tokenomics/), so it is not behind and merges. A commit
# outside those paths (src/) still makes the next pull request behind: exit 3, and it keeps its merge turn.
world three; ticket TASK-301; publish
run_branch three; commit_in "$WT" src/three.txt three "feat: three"; open_pr TASK-301; ci_head; ready
# 3a: the token reports wait while this run's pull request is open (R14): no docs/tokenomics commit, so not behind.
before=$(origin_main)
fl=$(cd "$W" && bash "$scripts/close-out.sh" --flush-reports 2>"$D/fl.err"); fl_rc=$?
check "3a/15 --flush-reports with a run PR open: deferred, main unchanged" $([ "$fl_rc" -eq 0 ] && [ "$fl" = '{"reports":"deferred"}' ] \
  && [ "$(origin_main)" = "$before" ] && grep -q "#$PRN" "$D/fl.err"; echo $?) "$D/fl.err"
commit_in "$W" docs/retro/2026-10-20-x.md retro "docs(retro): a retro"
git -C "$W" push -q origin main 2>"$D/push.err"
check "3/16 the docs/retro commit passed the guard (exempt)" $([ "$(origin_main)" = "$(git -C "$W" rev-parse HEAD)" ]; echo $?) "$D/push.err"
merge_ready "$PR"
check "3 a docs/retro commit on main: not behind, exit 0, merged" $([ "$MR_RC" -eq 0 ] && [ "$(mr_field state)" = merged ] \
  && [ "$(pr_state 7)" = MERGED ]; echo $?) "$D/mr.err"
run_branch three-b; commit_in "$WT" src/three-b.txt b "feat: three b"; open_pr TASK-301; ci_head; ready
# A code commit on main (by a clone without the guard: the guard would refuse it, scenario 16).
other="$D/other"; git clone -q "$FAKE_ORIGIN" "$other" 2>/dev/null
commit_in "$other" src/app.txt elsewhere "feat: elsewhere"; git -C "$other" push -q origin HEAD:main 2>/dev/null
before=$(origin_main)
merge_ready "$PR"
check "3 a src/ commit on main: behind, exit 3, nothing merged" $([ "$MR_RC" -eq 3 ] && [ "$(mr_field state)" = behind ] \
  && [ "$(pr_state "$PRN")" = OPEN ] && [ "$(origin_main)" = "$before" ]; echo $?) "$D/mr.err"
check "3 the behind pull request keeps its merge turn" $(queued "$PR"; echo $?)

# 5 and 10: a quoted pull request number between nodes (TASK-65), and the same CI request twice on one head (TASK-68).
world five; ticket TASK-501; publish
run_branch five; commit_in "$WT" src/five.txt five "feat: five"; open_pr TASK-501
(cd "$WT" && bash "$scripts/local-ci-run.sh" "'$PRN'" 2>"$D/lc.err"); lc_rc=$?
check "5 local-ci-run unwraps one pair of quotes around the number and runs CI on the head" $([ "$lc_rc" -eq 0 ] \
  && [ "$(grep -c . "$FAKE/ci-runs.log")" -eq 1 ] && grep -qx "$HEAD_SHA" "$FAKE/ci-runs.log"; echo $?) "$D/lc.err"
check "5 a double-quoted number is refused (exit 2)" $([ "$(cd "$WT" && t bash "$scripts/local-ci-run.sh" "\"$PRN\"")" -eq 2 ]; echo $?)
(cd "$WT" && bash "$scripts/local-ci-run.sh" "$PRN" 2>"$D/lc2.err"); lc_rc=$?
check "10 a second CI request on the same head starts nothing" $([ "$lc_rc" -eq 0 ] && [ "$(grep -c . "$FAKE/ci-runs.log")" -eq 1 ] \
  && grep -q 'already has a local run' "$D/lc2.err"; echo $?) "$D/lc2.err"
ready
merge_ready "$PRN"
check "5 merge-ready takes a bare number and merges" $([ "$MR_RC" -eq 0 ] && [ "$(mr_field pr)" = "$PR" ] && [ "$(mr_field state)" = merged ]; echo $?) "$D/mr.err"

# 6: a pull request renames a CI job (TASK-71): its CI is judged by its own job list. A ci.yml change is a deploy item
# (policy.json), so the ticket carries a chat approval for it: the verdict is covered and it merges at once (D7).
world six; ticket TASK-601; approve TASK-601 deploy; publish
run_branch six
printf 'name: ci\njobs:\n  build:\n    runs-on: x\n  unit:\n    runs-on: x\n' > "$WT/.github/workflows/ci.yml"
git -C "$WT" commit -qam "ci: rename test to unit"; open_pr TASK-601; ci_head
check "6 the CI stub posted the renamed job, not the old one" $(grep -q 'local-ci/unit success' "$FAKE/status/$HEAD_SHA" \
  && ! grep -q 'local-ci/test' "$FAKE/status/$HEAD_SHA"; echo $?)
ready
check "6 green by the commit's own job list (no local-ci/test=missing)" $([ "$(jq -r .state <<< "$READY_OUT")" = ready ] \
  && ! grep -q 'missing' "$D/am.err"; echo $?) "$D/am.err"
sc=$(cd "$W" && bash "$scripts/stop-check.sh" "$PR" 2>&1); sc_rc=$?
check "6 stop-check: covered by the deploy approval (exit 3)" $([ "$sc_rc" -eq 3 ] && [ "$(head -n 1 <<< "$sc" | awk '{print $1}')" = covered ] \
  && grep -q 'deploy (diff): covered' <<< "$sc"; echo $?)
merge_ready "$PR"
check "6 merge-ready merges a covered pull request at once" $([ "$MR_RC" -eq 0 ] && [ "$(mr_field verdict)" = covered ] && [ "$(pr_state 7)" = MERGED ]; echo $?) "$D/mr.err"
merge=$(jq -r .mergeCommit.oid "$FAKE/prs/7.json")
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" "$merge" "$HEAD_SHA" 2>"$D/mc.err")
check "6 main-ci on the merge with the renamed job: green" $([ "$(jq -r .state <<< "$mc")" = green ]; echo $?) "$D/mc.err"

# 7: a head pushed after ready. (a) merge-ready checks the new head: no CI on it, so not ready, nothing merged.
# (b) a push between auto-merge's last look and its merge: --match-head-commit refuses the merge.
world seven; ticket TASK-701; publish
run_branch seven; commit_in "$WT" src/seven.txt seven "feat: seven"; open_pr TASK-701; ci_head; ready
(cd "$WT" && bash "$scripts/local-ci-run.sh" "$(origin_main)" 2>>"$D/ci.err")   # main's tip green, so only the head decides (D9)
h1=$HEAD_SHA
commit_in "$WT" src/seven.txt seven-b "feat: seven b"; git -C "$WT" push -q origin HEAD 2>/dev/null
before=$(origin_main)
merge_ready "$PR"
check "7a a head pushed after ready: exit 4, the new head has no CI, nothing merged" $([ "$MR_RC" -eq 4 ] && [ "$(mr_field state)" = not-ready ] \
  && [ "$(mr_field head)" != "$h1" ] && grep -q 'auto-merge: none' <<< "$MR" && [ "$(origin_main)" = "$before" ] && [ "$(pr_state 7)" = OPEN ]; echo $?) "$D/mr.err"
ci_head
pre="cd '$WT' && echo c > src/seven.txt && git commit -qam 'feat: seven c' && git push -q origin HEAD"
am=$(cd "$WT" && bash "$scripts/auto-merge.sh" "$PR" --pre "$pre" 2>"$D/am7.err"); am_rc=$?
check "7b a push between the last look and the merge: the merge is refused (match-head-commit)" $(grep -q '^refused 7' "$FAKE/merges.log" \
  && [ "$(origin_main)" = "$before" ] && [ "$(pr_state 7)" = OPEN ]; echo $?) "$D/am7.err"
check "7b auto-merge then finds no CI on the new head: none, exit 1" $([ "$am_rc" -eq 1 ] && [ "$(jq -r .state <<< "$am")" = none ] \
  && [ "$(jq -r .sha <<< "$am")" = "$(git -C "$WT" rev-parse HEAD)" ]; echo $?) "$D/am7.err"

# 8: a rewritten branch after a resume (TASK-70): someone else pushed the branch meanwhile; open-pr's lease refuses.
world eight; ticket TASK-801; publish
run_branch eight; commit_in "$WT" src/eight.txt eight "feat: eight"; open_pr TASK-801
other="$D/other"; git clone -q "$FAKE_ORIGIN" "$other" 2>/dev/null; git -C "$other" checkout -q build-feature-eight
commit_in "$other" src/eight.txt theirs "fix: theirs"; git -C "$other" push -q origin HEAD 2>/dev/null; theirs=$(git -C "$other" rev-parse HEAD)
git -C "$WT" commit -q --amend -m "feat: eight, rewritten"
o8=$(cd "$WT" && bash "$scripts/open-pr.sh" main "feat: TASK-801 harness work" "$D/body.md" 2>"$D/op8.err"); op_rc=$?
check "8 the lease refuses to overwrite the branch, exit 1" $([ "$op_rc" -eq 1 ] && grep -q 'Refusing to overwrite' "$D/op8.err" \
  && [ "$(git --git-dir="$FAKE_ORIGIN" rev-parse refs/heads/build-feature-eight)" = "$theirs" ]; echo $?) "$D/op8.err"

# 11: an unapproved STOP item (a stop-auth-access label, no approval): held at once, out of the queue, the owner pinged;
# the owner's chat approval then goes to main past the guard: a commit of approvals files only is exempt (2026-11-19).
world eleven; ticket TASK-1101 stop-auth-access; publish
run_branch eleven; commit_in "$WT" src/auth.txt auth "feat: auth"; open_pr TASK-1101; ci_head; ready
sc=$(cd "$W" && bash "$scripts/stop-check.sh" "$PR" 2>&1); sc_rc=$?
check "11 stop-check: owner (exit 1), naming the label" $([ "$sc_rc" -eq 1 ] && [ "$(head -n 1 <<< "$sc" | awk '{print $1}')" = owner ] \
  && grep -q 'auth-access (label): owner' <<< "$sc"; echo $?)
echo "$PR" >> "$MERGE_QUEUE_DIR/queue"
before=$(origin_main)
merge_ready "$PR"
check "11 merge-ready: held, exit 10, nothing merged" $([ "$MR_RC" -eq 10 ] && [ "$(mr_field state)" = held ] && [ "$(mr_field verdict)" = owner ] \
  && [ "$(origin_main)" = "$before" ] && [ "$(pr_state 7)" = OPEN ] && [ ! -s "$FAKE/merges.log" ]; echo $?) "$D/mr.err"
check "11 out of the merge queue, the owner pinged (act merge-held-7)" $(! queued "$PR" && grep -q '^notify act merge-held-7 ' "$FAKE/notify.log"; echo $?)
approve TASK-1101 auth-access; git -C "$W" add -A; git -C "$W" commit -qm "approvals"
git -C "$W" push -q origin main 2>"$D/push.err"; ap_rc=$?
check "11/16 an approvals-only commit passes the guard (exempt)" $([ "$ap_rc" -eq 0 ] && [ "$(origin_main)" != "$before" ]; echo $?) "$D/push.err"
sc=$(cd "$W" && bash "$scripts/stop-check.sh" "$PR" 2>&1); sc_rc=$?
check "11 once the approval is on main: covered (exit 3)" $([ "$sc_rc" -eq 3 ] && grep -q 'auth-access (label): covered — approval:' <<< "$sc"; echo $?)

# 12: the hold marker. --hold takes it out of the queue and holds; a plain call holds; --unhold; then it merges.
world twelve; ticket TASK-1201; publish
run_branch twelve; commit_in "$WT" src/twelve.txt twelve "feat: twelve"; open_pr TASK-1201; ci_head; ready
echo "$PR" >> "$MERGE_QUEUE_DIR/queue"
merge_ready "$PR" --hold --reason "the owner looks first"
check "12 --hold: exit 10, out of the queue" $([ "$MR_RC" -eq 10 ] && ! queued "$PR"; echo $?) "$D/mr.err"
merge_ready "$PR"
check "12 a held pull request is not merged" $([ "$MR_RC" -eq 10 ] && grep -q 'the owner looks first' <<< "$MR" && [ "$(pr_state 7)" = OPEN ]; echo $?) "$D/mr.err"
merge_ready "$PR" --check
check "12 --check on a held one: held" $([ "$MR_RC" -eq 10 ]; echo $?)
merge_ready "$PR" --unhold
check "12 --unhold: exit 0" $([ "$MR_RC" -eq 0 ] && [ "$(mr_field state)" = unheld ]; echo $?) "$D/mr.err"
merge_ready "$PR"
check "12 after --unhold it merges" $([ "$MR_RC" -eq 0 ] && [ "$(pr_state 7)" = MERGED ]; echo $?) "$D/mr.err"

# 13: the head changes while merge-ready waits for its turn: it looks again before the merge and does not merge.
world thirteen; ticket TASK-1301; ticket TASK-1302; publish
run_branch thirteen-a; commit_in "$WT" src/a.txt a "feat: a"; open_pr TASK-1301; PRA=$PR; WTA=$WT
run_branch thirteen-b; commit_in "$WT" src/b.txt b "feat: b"; open_pr TASK-1302; ci_head; ready
(cd "$W" && bash "$scripts/merge-turn.sh" wait "$PRA" >/dev/null 2>&1)   # A is up to date: it holds the turn
(cd "$W" && bash "$scripts/merge-ready.sh" "$PR" > "$D/mr13.out" 2> "$D/mr13.err") & mr13=$!
wait_for "$D/mr13.err" "holds the merge turn"; held_rc=$?
check "13 merge-ready waits behind the pull request holding the turn" $([ "$held_rc" -eq 0 ]; echo $?) "$D/mr13.err"
commit_in "$WT" src/b.txt b2 "feat: b2"; git -C "$WT" push -q origin HEAD 2>/dev/null
jq '.state = "CLOSED"' "$FAKE/prs/7.json" > "$FAKE/prs/7.t" && mv "$FAKE/prs/7.t" "$FAKE/prs/7.json"
wait "$mr13"; mr13_rc=$?
check "13 the head moved during the wait: exit 4, nothing merged" $([ "$mr13_rc" -eq 4 ] && grep -q 'the head moved' "$D/mr13.out" \
  && [ "$(pr_state 8)" = OPEN ] && [ ! -s "$FAKE/merges.log" ]; echo $?) "$D/mr13.out"

# 14: main-ci with no result (C13: every merge commit gets its own run; it never waits for a status that will not
# come). The merge commit's local run posts nothing: none, exit 0, and with --check exit 1; an unknown merge commit
# answers none at once; a result answers green.
world fourteen; ticket TASK-1401; ticket TASK-1402; publish
run_branch fourteen; commit_in "$WT" src/x.txt x "feat: x"; open_pr TASK-1401; ci_head; ready
(cd "$WT" && bash "$scripts/park-ticket.sh" TASK-1402 -m "moves main" >/dev/null 2>&1)
merge_ready "$PR"; merge=$(jq -r .mergeCommit.oid "$FAKE/prs/7.json")
echo nothing > "$FAKE/ci-outcome/$merge"
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" "$merge" "$HEAD_SHA" 2>"$D/mc.err"); mc_rc=$?
check "14 no result: none, exit 0" $([ "$mc_rc" -eq 0 ] && [ "$(jq -r .state <<< "$(tail -n 1 <<< "$mc")")" = none ]; echo $?) "$D/mc.err"
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" --check "$merge" "$HEAD_SHA" 2>"$D/mc.err"); mc_rc=$?
check "14 --check, no result: none, exit 1" $([ "$mc_rc" -ne 0 ] && [ "$(jq -r .state <<< "$(tail -n 1 <<< "$mc")")" = none ]; echo $?) "$D/mc.err"
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" 0123456789abcdef0123456789abcdef01234567 "$HEAD_SHA" 2>"$D/mc.err"); mc_rc=$?
check "14 an unknown merge commit: none at once, naming that local CI could not run" $([ "$(jq -r .state <<< "$(tail -n 1 <<< "$mc")")" = none ] \
  && grep -q 'could not run' <<< "$mc"; echo $?) "$D/mc.err"
rm -f "$FAKE/ci-outcome/$merge" "$FAKE/status/$merge"
mc=$(cd "$WT" && bash "$scripts/main-ci.sh" --check "$merge" "$HEAD_SHA" 2>"$D/mc.err"); mc_rc=$?
check "14 with a result: green, exit 0" $([ "$mc_rc" -eq 0 ] && [ "$(jq -r .state <<< "$(tail -n 1 <<< "$mc")")" = green ]; echo $?) "$D/mc.err"

# 15: close-out with a ticket while another run's pull request is open: the ticket commit goes to main (backlog/:
# exempt), the token reports wait; the second pull request is then not behind (TASK-73) and its close-out commits them.
world fifteen; ticket TASK-1501; ticket TASK-1502; publish
run_branch fifteen-a; commit_in "$WT" src/a.txt a "feat: a"; open_pr TASK-1501; ci_head; ready; PRA=$PR; WTA=$WT; HA=$HEAD_SHA
run_branch fifteen-b; commit_in "$WT" src/b.txt b "feat: b"; open_pr TASK-1502; ci_head; ready; PRB=$PR; WTB=$WT
merge_ready "$PRA"
check "15 the first pull request merges" $([ "$MR_RC" -eq 0 ]; echo $?) "$D/mr.err"
# B takes A's merge in (as a resumed run does), so only the coming ticket commit can put it behind.
git -C "$WTB" fetch -q origin; git -C "$WTB" merge -q --no-edit origin/main; git -C "$WTB" push -q origin HEAD 2>/dev/null
WT=$WTB; ci_head; ready
check "15 the updated second pull request is ready on its new head" $([ "$(jq -r .state <<< "$READY_OUT")" = ready ]; echo $?) "$D/am.err"
(cd "$W" && backlog task edit TASK-1501 -s Done >/dev/null)   # finalize: the ticket file changes in the main checkout
co=$(cd "$WTA" && bash "$scripts/close-out.sh" TASK-1501 "$PRA" "$W" 2>"$D/co.err"); co_rc=$?
printf 'close-out exit %s, stdout: %s\n' "$co_rc" "$co" >> "$D/co.err"   # a failed check shows the answer too
bl=$(jq -r .backlog <<< "$co")
# No `git log | grep -q` here: git flushes per commit into a pipe, grep -q exits at the first match, and under load git's
# next write died of SIGPIPE, which pipefail turned into a failed check with the commit on main.
check "15 close-out with a ticket: the ticket commit reached origin main through the guard" $([ "$co_rc" -eq 0 ] && [ -n "$bl" ] \
  && grep -q '^backlog: TASK-1501 done' <<< "$(git --git-dir="$FAKE_ORIGIN" log --format=%s refs/heads/main)" \
  && git --git-dir="$FAKE_ORIGIN" merge-base --is-ancestor "$bl" refs/heads/main; echo $?) "$D/co.err"
check "15 the token reports wait while the other run PR is open" $(grep -q "token reports deferred: run pull requests #8" "$D/co.err" \
  && [ ! -s "$FAKE/reports.log" ]; echo $?) "$D/co.err"
merge_ready "$PRB"
check "15 the second pull request is not behind by the ticket commit: merged" $([ "$MR_RC" -eq 0 ] && [ "$(pr_state 8)" = MERGED ]; echo $?) "$D/mr.err"
co=$(cd "$WTB" && bash "$scripts/close-out.sh" "" "$PRB" "$W" 2>"$D/co.err"); co_rc=$?
check "15 the last close-out commits the reports" $([ "$co_rc" -eq 0 ] && [ "$(grep -c . "$FAKE/reports.log")" -eq 1 ]; echo $?) "$D/co.err"
fl=$(cd "$W" && bash "$scripts/close-out.sh" --flush-reports 2>"$D/fl.err"); fl_rc=$?
check "15 --flush-reports with no run PR open: committed" $([ "$fl_rc" -eq 0 ] && [ "$fl" = '{"reports":"committed"}' ] \
  && [ "$(git --git-dir="$FAKE_ORIGIN" diff-tree --no-commit-id -r --name-only refs/heads/main)" = docs/tokenomics/report.md ]; echo $?) "$D/fl.err"

# 16: the push guard refuses what is not exempt: a code commit, a commit mixing backlog/ with code, a push from a run
# worktree to main, a look-alike folder.
world sixteen; ticket TASK-1601; publish
before=$(origin_main)
commit_in "$W" src/app.txt changed "feat: direct"
check "16 a code commit pushed to main is refused" $([ "$(t git -C "$W" push -q origin main)" -ne 0 ] && [ "$(origin_main)" = "$before" ]; echo $?)
git -C "$W" reset -q --hard origin/main
echo x >> "$W/backlog/tasks/task-1601 - Ticket 1601.md"; echo y > "$W/src/y.txt"; git -C "$W" add -A; git -C "$W" commit -qm "mixed"
check "16 a commit mixing backlog/ and code is refused" $([ "$(t git -C "$W" push -q origin main)" -ne 0 ] && [ "$(origin_main)" = "$before" ]; echo $?)
git -C "$W" reset -q --hard origin/main
commit_in "$W" backlogx/a.md x "look-alike"
check "16 a look-alike folder (backlogx/) is refused" $([ "$(t git -C "$W" push -q origin main)" -ne 0 ] && [ "$(origin_main)" = "$before" ]; echo $?)
git -C "$W" reset -q --hard origin/main
run_branch sixteen; commit_in "$WT" src/z.txt z "feat: z"
check "16 a run worktree pushing HEAD to main is refused (the hook is the clone's)" $([ "$(cd "$WT" && t git push -q origin HEAD:main)" -ne 0 ] \
  && [ "$(origin_main)" = "$before" ]; echo $?)
check "16 the run's own branch pushes fine" $([ "$(cd "$WT" && t git push -q origin HEAD)" -eq 0 ]; echo $?)
echo x >> "$W/backlog/tasks/task-1601 - Ticket 1601.md"; git -C "$W" commit -qam "backlog only"
check "16 a backlog-only commit passes (exempt)" $([ "$(t git -C "$W" push -q origin main)" -eq 0 ] && [ "$(origin_main)" != "$before" ]; echo $?)

echo "merge-path: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
