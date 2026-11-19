#!/usr/bin/env bash
# GO or NO-GO before an unattended night (P2: a script, not a model; owner decisions D1, D10 and D11, 2026-10-20). The
# owner runs it in the evening, after the approval round and before the delegator starts; it is no delegator tool.
#   night-preflight.sh [--list <file>] [--cap <1 to 3>] [--allow-running] [--allow-tooling]
#     --list           the night list (default docs/rewrite/night-list.txt in the main checkout)
#     --cap            the cap the night runs with (default 2), for the dry pick
#     --allow-running  a live build-feature run is no NO-GO (and its In Progress ticket counts as covered)
#     --allow-tooling  a listed ticket that changes the run tooling is no NO-GO
# NO-GO, each on its own line with the command that fixes it:
#   - a live build-feature run (`archon workflow runs --json --verbose`), or archon cannot be read;
#   - a pull request in the merge queue (`merge-turn.sh list`) or a ready record (`ready-runs.sh list`);
#   - the main checkout is not on main, has a change or an untracked file, or is not equal to origin/main after a fetch;
#   - an In Progress ticket with neither a live run nor the label `parked` (it would hold its lane all night);
#   - the list: unreadable, empty, or naming a ticket that is unknown, Done, an epic, parked, P4, `manual`, In Progress
#     without a live run, or one that changes the run tooling (`.archon/`, `.claude/scripts|hooks|agents/`, `ci-local`,
#     build-feature or the delegator in its title or references: a script every run uses that night);
#   - the dry first pick (`pick-tickets.js --list <file> --cap <n>` on the runs read above) picks nothing or fails;
#   - the recovery breaker (`recovery-state.js show`) is open, or cannot be read; half open with --cap above 1 (a half
#     open breaker allows exactly one canary launch);
#   - no notify-owner.sh, or `notify-owner.sh check` fails (the ntfy config is not ready; check sends nothing): fix
#     docs/archon/notify.md (owner decision D9).
# Shown, not NO-GO: the delegator session lock (`session.lock` in $DELEGATOR_STATE_DIR, default merge-queue/delegator/
# beside the main checkout; written by delegator-start.sh and delegator-session.sh), live or stale: a live one is
# tonight's own delegator, which is up while the owner runs this, and delegator-start.sh refuses a second one (a false
# NO-GO on 2026-10-22); the dry pick (ids, components, stop labels) and its skips, every listed ticket that still carries a
# `stop-*` label (skipped tonight unless a current approval covers it), every parked ticket, and warnings: no current
# approvals file under `.archon/stop/approvals/` at origin/main (judged by stop-lib.js against `.archon/stop/policy.json`
# there), no policy, no `recovery-state.js`, no `.claude/delegator.settings.json`. It never prunes
# the recovery records (`recovery-state.js prune` is the delegator's, once a night): it writes nothing.
# It changes nothing but the remote-tracking refs a fetch updates. It reads the backlog once (`backlog task list --json`).
# Exit 0: GO. Exit 1: NO-GO. Exit 2: usage.
# Overrides for the tests: PREFLIGHT_SCRIPTS_DIR, the folder of merge-turn.sh, ready-runs.sh, pick-tickets.js,
# stop-lib.js, recovery-state.js and notify-owner.sh; PREFLIGHT_NOW (epoch seconds), the time approvals are judged at
# (passed on to pick-tickets.js); DELEGATOR_STATE_DIR and RECOVERY_DIR as those scripts read them.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/kit-config.sh"
build_wf="$(kit_get build_workflow build-feature BUILD_WORKFLOW)"
scripts=${PREFLIGHT_SCRIPTS_DIR:-$here}
usage() {
  [ -n "${1:-}" ] && echo "night-preflight: $1" >&2
  echo "usage: night-preflight.sh [--list <file>] [--cap <1 to 3>] [--allow-running] [--allow-tooling]" >&2
  exit 2
}
list="" cap=2 allow_running="" allow_tooling=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) [ -n "${2:-}" ] || usage "--list needs a file"; list=$2; shift ;;
    --cap) [[ "${2:-}" =~ ^[1-3]$ ]] || usage "--cap is 1 to 3"; cap=$2; shift ;;
    --allow-running) allow_running=1 ;;
    --allow-tooling) allow_tooling=1 ;;
    *) usage "unknown argument: $1" ;;
  esac
  shift
done

main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main" ] || usage "not in a git checkout"
[ -n "$list" ] || list="$main/docs/rewrite/night-list.txt"
cd "$main" || exit 2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

nogo=0
no() { echo "NO-GO: $1"; echo "       fix: $2"; nogo=$((nogo + 1)); }
info() { echo "  $*"; }
warn() { echo "warn: $*"; }

# 1. Live runs.
echo "== runs"
if archon workflow runs --json --verbose --limit 50 > "$tmp/all.json" 2>/dev/null \
  && jq -e '(.runs // .) | type == "array"' "$tmp/all.json" >/dev/null 2>&1; then
  jq --arg wf "$build_wf" '{runs: [(.runs // .)[] | select(.workflow_name == "build-feature" or .workflow_name == $wf)
    | select(.status | IN("completed", "failed", "cancelled", "rejected") | not)]}' "$tmp/all.json" > "$tmp/runs.json"
  live=$(jq -r '.runs[] | (([.nodes[]? | select(.nodeId == "ticket") | .outputPreview | (try fromjson catch {}) | .task?] | map(select(.)) | first)
    // ((.user_message // "") | capture("(?<t>TASK-[0-9]+(\\.[0-9]+)*)"; "i").t) // "?") as $t | "\(.id) \($t | ascii_upcase) \(.status)"' "$tmp/runs.json")
  if [ -z "$live" ]; then info "no live build-feature run"
  else
    while read -r id task status; do
      if [ -n "$allow_running" ]; then info "live run $id ($task, $status), allowed"
      else no "live build-feature run $id ($task, $status)" "let it finish, or bash .archon/scripts/stop-run.sh $id; or pass --allow-running"; fi
    done <<< "$live"
  fi
else
  echo '{"runs": []}' > "$tmp/runs.json"; live=""
  no "cannot read the archon runs" "start archon (archon serve) and run this again"
fi

# 2. Merge queue and ready records.
echo "== merge queue"
queue=$(bash "$scripts/merge-turn.sh" list 2>/dev/null) || { no "cannot read the merge queue" "bash .archon/scripts/merge-turn.sh list"; queue=""; }
while read -r pr; do [ -n "$pr" ] && no "pull request in the merge queue: $pr" "merge it, or bash .archon/scripts/merge-turn.sh drop $pr"; done <<< "$queue"
ready=$(bash "$scripts/ready-runs.sh" list 2>/dev/null) || { no "cannot read the ready records" "bash .archon/scripts/ready-runs.sh list"; ready=""; }
while read -r rec; do
  [ -n "$rec" ] || continue
  run=$(jq -r '.run // "?"' <<< "$rec" 2>/dev/null)
  no "ready record of run $run ($(jq -r '.pr // "?"' <<< "$rec" 2>/dev/null))" "merge it, or bash .archon/scripts/ready-runs.sh clear $run"
done <<< "$ready"
[ -z "$queue$ready" ] && info "empty, no ready record"

# 3. The main checkout.
echo "== main checkout ($main)"
branch=$(git symbolic-ref -q --short HEAD)
[ "$branch" = main ] || no "the main checkout is on '${branch:-detached HEAD}', not main" "git -C $main switch main"
dirty=$(git status --porcelain --untracked-files=all 2>/dev/null)
[ -z "$dirty" ] || no "the main checkout has changes: $(head -n 3 <<< "$dirty" | tr '\n' ' ')" \
  "commit them (backlog/: bash .archon/scripts/commit-tickets.sh <ids>), or move them away"
if git fetch -q origin main 2>/dev/null; then
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || no "the main checkout is not equal to origin/main" "bash .archon/scripts/sync-main.sh (or push what main has: a person decides)"
else no "cannot fetch origin" "check the network and git remote -v"; fi
info "on ${branch:-detached HEAD} at $(git rev-parse --short HEAD)"

# 3b. The delegator session, and the recovery breaker.
echo "== delegator session and recovery breaker"
lock=${DELEGATOR_STATE_DIR:-$(dirname "$main")/merge-queue/delegator}/session.lock
if [ -f "$lock" ]; then
  read -r lsess lpid lsince < "$lock" 2>/dev/null || true
  if [ -n "${lpid:-}" ] && kill -0 "$lpid" 2>/dev/null; then
    info "a delegator session is live (session ${lsess:-?}, pid $lpid, since ${lsince:-?}): tonight's; delegator-start.sh refuses a second"
  else info "a stale session lock (pid ${lpid:-?} is gone): delegator-start.sh removes it"; fi
else info "no delegator session"; fi
if [ ! -f "$scripts/recovery-state.js" ]; then warn "no recovery-state.js: no breaker check"
elif ! node "$scripts/recovery-state.js" show > "$tmp/breaker.json" 2>"$tmp/breaker.err" \
     || ! bstate=$(jq -er '.state' "$tmp/breaker.json" 2>/dev/null); then
  no "cannot read the recovery breaker: $(tail -n 1 "$tmp/breaker.err" 2>/dev/null)" "node .archon/scripts/recovery-state.js show"
else
  breason=$(jq -r '.reason // "no reason given"' "$tmp/breaker.json")
  case "$bstate" in
    closed) info "breaker closed" ;;
    open) no "the recovery breaker is open: $breason" \
      "fix the cause; then node .archon/scripts/recovery-state.js half-open (one canary launch), or the owner resets it (reset-breaker)" ;;
    half_open) if [ "$cap" -gt 1 ]; then
        no "the recovery breaker is half open ($breason): it allows exactly one canary launch" "night-preflight.sh --cap 1, and run the night with --cap 1 until the canary is clean"
      else info "breaker half open: one canary launch ($breason)"; fi ;;
    *) no "the recovery breaker is in an unknown state '$bstate'" "node .archon/scripts/recovery-state.js show" ;;
  esac
fi

# 4. The backlog: In Progress tickets and parked ones.
echo "== backlog"
if ! backlog task list --json > "$tmp/tasks.json" 2>/dev/null || ! jq -e '(.tasks // .) | type == "array"' "$tmp/tasks.json" >/dev/null 2>&1; then
  no "cannot read the backlog" "backlog task list --json"; echo '[]' > "$tmp/tasks.json"
fi
tasks='(.tasks // .)'
running=" $(awk '{print $2}' <<< "$live" | tr '\n' ' ') "
while IFS=$'\t' read -r id labels; do
  [ -n "$id" ] || continue
  case ",$labels," in *,parked,*) continue ;; esac
  case "$running" in *" $id "*) info "$id In Progress with a live run" ;; *)
    no "$id is In Progress with no live run and no parked label (it holds its lane all night)" \
      "bash .archon/scripts/park-ticket.sh $id -m \"<why>\", or resume its run" ;; esac
done < <(jq -r "$tasks[] | select(.status == \"In Progress\") | [.id, ((.labels // []) | join(\",\"))] | @tsv" "$tmp/tasks.json")
parked=$(jq -r "$tasks[] | select(.status != \"Done\" and ((.labels // []) | index(\"parked\"))) | \"\(.id) (\(.status)): \(.title)\"" "$tmp/tasks.json")
if [ -n "$parked" ]; then info "parked:"; sed 's/^/    /' <<< "$parked"; else info "nothing parked"; fi

# 5. The list.
echo "== night list ($list)"
tooling='\.archon/|\.claude/(scripts|hooks|agents)/|ci-local|build-feature|delegator'
if [ ! -r "$list" ]; then
  no "cannot read the night list $list" "write it: one TASK id per line (see docs/rewrite/night-list.txt)"
else
  ids=$(sed 's/#.*//' "$list" | tr -d ' \t\r' | grep -v '^$' | tr '[:lower:]' '[:upper:]')
  [ -n "$ids" ] || no "the night list names no ticket" "add tonight's ticket ids to $list"
  n=0
  for id in $ids; do
    n=$((n + 1))
    [[ "$id" =~ ^TASK-[0-9]+(\.[0-9]+)*$ ]] || { no "'$id' in the list is not a ticket id" "fix the line in $list"; continue; }
    t=$(jq -c --arg id "$id" "$tasks[] | select((.id | ascii_upcase) == \$id)" "$tmp/tasks.json" | head -n 1)
    [ -n "$t" ] || { no "$id is not in the backlog (unknown, archived or a draft)" "take it off $list"; continue; }
    status=$(jq -r '.status' <<< "$t")
    labels=$(jq -r '(.labels // []) | join(",")' <<< "$t")
    title=$(jq -r '.title // ""' <<< "$t")
    has() { case ",$labels," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
    off="take it off $list"
    if [ "$status" = Done ]; then no "$id is Done" "$off"; continue; fi
    if [ "$status" = "In Progress" ]; then
      case "$running" in *" $id "*) info "$id is In Progress with a live run" ;; *) no "$id is In Progress with no live run" "$off, or resume its run" ;; esac
      continue
    fi
    if has epic || [[ "$title" == *"Epic:"* ]]; then no "$id is an epic" "$off (list its tickets)"; continue; fi
    has parked && { no "$id is parked" "$off, or bash .archon/scripts/park-ticket.sh --unpark $id -m \"<why>\""; continue; }
    has P4 && { no "$id is P4 (not for an unattended night)" "$off"; continue; }
    has manual && { no "$id is manual (needs a person)" "$off"; continue; }
    if [ -z "$allow_tooling" ] && jq -e --arg re "$tooling" '([.title] + (.references // []) | map(tostring) | join(" ")) | test($re)' <<< "$t" >/dev/null; then
      no "$id changes the run tooling ($title): every run uses it tonight" "$off, or pass --allow-tooling"; continue
    fi
    stops=$(tr ',' '\n' <<< "$labels" | grep '^stop-' | tr '\n' ' ')
    [ -n "$stops" ] && info "$id still carries ${stops% }: skipped tonight unless a current approval covers it"
  done
  info "$n ticket(s) listed"
fi

# 6. The dry first pick.
echo "== dry pick (cap $cap)"
if [ ! -r "$list" ]; then info "no list, no pick"
elif env ${PREFLIGHT_NOW:+PICK_NOW=$(date -u -d "@$PREFLIGHT_NOW" +%Y-%m-%dT%H:%M:%SZ)} PICK_RUNS_JSON="$tmp/runs.json" node "$scripts/pick-tickets.js" --list "$list" --cap "$cap" > "$tmp/pick.json" 2>"$tmp/pick.err"; then
  jq -r '.picked[] | "  pick \(.id): \(.title) [\(.components | join(", "))]\(if (.stop | length) > 0 then " stop: \(.stop | join(", "))" else "" end)"' "$tmp/pick.json"
  jq -r '.skipped[] | "  skip \(.id): \(.reason)"' "$tmp/pick.json"
  jq -e '.picked | length > 0' "$tmp/pick.json" >/dev/null \
    || no "the dry pick picks nothing (room $(jq -r .room "$tmp/pick.json"))" "read the skips above; fix the list, the approvals or the live runs"
else
  no "the dry pick failed: $(tail -n 1 "$tmp/pick.err" 2>/dev/null)" "node .archon/scripts/pick-tickets.js --list $list --cap $cap"
fi

# 7. Warnings owned by other parts.
echo "== warnings"
w=0
now=${PREFLIGHT_NOW:-$(date +%s)}
if ! git show origin/main:.archon/stop/policy.json > "$tmp/policy.json" 2>/dev/null; then
  warn "no .archon/stop/policy.json at origin/main: every stop-* ticket is skipped"; w=$((w + 1))
else
  mkdir -p "$tmp/appr"
  while read -r f; do
    case "${f##*/}" in _*|'') continue ;; esac
    git show "origin/main:$f" > "$tmp/appr/${f##*/}" 2>/dev/null || rm -f "$tmp/appr/${f##*/}"
  done < <(git ls-tree --name-only origin/main .archon/stop/approvals/ 2>/dev/null | grep '\.json$')
  current=$(node -e '
    const lib = require(process.argv[1]); const fs = require("fs"); const path = require("path");
    const policy = lib.loadPolicy(fs.readFileSync(process.argv[2], "utf8")); const now = Number(process.argv[4]) * 1000;
    let n = 0;
    for (const f of fs.readdirSync(process.argv[3])) {
      try { if (!lib.fileProblem(JSON.parse(fs.readFileSync(path.join(process.argv[3], f), "utf8")), policy, now)) n++; } catch (e) {}
    }
    console.log(n);' "$scripts/stop-lib.js" "$tmp/policy.json" "$tmp/appr" "$now" 2>/dev/null) || current=0
  if [ "${current:-0}" -eq 0 ]; then
    warn "no current approvals file under .archon/stop/approvals/ at origin/main: a stop-* ticket is skipped unless a standing rule covers it"; w=$((w + 1))
  else info "$current current approvals file(s)"; fi
fi
if [ ! -f "$scripts/notify-owner.sh" ]; then no "no notify-owner.sh: no phone ping tonight" "set up ntfy: docs/archon/notify.md"
elif ! bash "$scripts/notify-owner.sh" check > /dev/null 2>&1; then
  no "notify-owner.sh is not set up (bash .archon/scripts/notify-owner.sh check fails): no phone ping tonight" "set up ntfy: docs/archon/notify.md"
fi
[ -f "$main/.claude/delegator.settings.json" ] || { warn "no .claude/delegator.settings.json: the delegator will meet permission prompts"; w=$((w + 1)); }
[ "$w" -eq 0 ] && info "none"

echo
if [ "$nogo" -eq 0 ]; then echo "GO"; exit 0; fi
echo "NO-GO ($nogo reason(s))"
exit 1
