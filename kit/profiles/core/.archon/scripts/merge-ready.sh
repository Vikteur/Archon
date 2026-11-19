#!/usr/bin/env bash
# Merge a ready run's pull request in one call (P2: a script, not a model; owner decision 2026-10-20, D7: it merges at
# once when no STOP item is unapproved). Only the delegator or the owner calls it; a workflow never does (TASK-58,
# workflow-contracts.test.sh).
#   merge-ready.sh <pr url|number>                    check it, then merge it
#   merge-ready.sh <pr url|number> --check            check it and report; no side effects: no merge, no queue
#                                                     change, no ping, no hold, no log line
#   merge-ready.sh <pr url|number> --hold --reason <text>
#                                                     put a hold marker on it (no merge until --unhold) and take it out of
#                                                     the merge queue, so it does not hold the turn
#   merge-ready.sh <pr url|number> --unhold           take the hold marker off
# The checks, in order: the pull request is open; no hold marker; the STOP verdict of stop-check.sh for it is `none` or
# `covered` (`owner` holds it: it leaves the merge queue and the owner is pinged); it is not a draft (the run marks it
# ready only once its last gates passed) and does not conflict. Then it waits for its merge turn (merge-turn.sh wait),
# checks the hold marker again and that the head is still the one the verdict was given for, and merges that head with
# auto-merge.sh --head (CI green by SHA, every review given, no thread open; a merge commit pinned to the head). Every
# merge gets an audit comment on the pull request. Every outcome is one JSON line on stdout
# {"state", "pr", "head", "verdict", "detail"} and the same line in $MERGE_QUEUE_DIR/merge-ready.log.
# Exit: 0 merged (also: merged by someone else; --check: would merge at its turn; --unhold done), 10 held (hold marker
# or STOP verdict `owner`), 3 behind its base at its turn (bring it up to date, CI runs, call again), 4 not ready (draft,
# conflict, CI red or missing, main's tip red (D9), reviews or threads still open after MERGE_READY_TIMEOUT, the head
# moved), 5 closed without a merge, 2 usage, 1 error (stop-check missing or unreadable, GitHub unreadable, a merged head
# that is not the checked one).
# Pings go through notify-owner.sh, each about its pull request or commit, so it stays open (no repeat) until that is
# merged, closed or green; a missing one or a failed ping is logged, never fatal (D9).
# A red tip of the base (auto-merge main-red) is triaged first (red-triage.sh: a red job that matches a listed flake
# gets its one rerun); still red, the owner gets one act ping per SHA (owner decision 2026-10-23). Exit 4 either way.
# Overrides: MERGE_QUEUE_DIR (as merge-turn.sh), STOP_CHECK, MERGE_TURN, AUTO_MERGE, NOTIFY_OWNER (the scripts to call),
# RED_TRIAGE, MERGE_READY_TIMEOUT (seconds auto-merge.sh may wait; 900).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "merge-ready: $*" >&2; echo "usage: merge-ready.sh <pr url|number> [--check | --hold --reason <text> | --unhold]" >&2; exit 2; }
stop_check=${STOP_CHECK:-$here/stop-check.sh}
merge_turn=${MERGE_TURN:-$here/merge-turn.sh}
auto_merge=${AUTO_MERGE:-$here/auto-merge.sh}
notify_owner=${NOTIFY_OWNER:-$here/notify-owner.sh}
red_triage=${RED_TRIAGE:-$here/red-triage.sh}
timeout_s=${MERGE_READY_TIMEOUT:-900}

pr="" mode=merge reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --hold) mode=hold ;;
    --unhold) mode=unhold ;;
    --reason) [ -n "${2:-}" ] || usage "--reason needs a text"; reason=$2; shift ;;
    -*) usage "unknown option $1" ;;
    *) [ -z "$pr" ] || usage "one pull request only"; pr=$1 ;;
  esac
  shift
done
[ -n "$pr" ] || usage "a pull request is needed"
[ "$mode" != hold ] || [ -n "$reason" ] || usage "--hold needs --reason <text>"
[ "$mode" = hold ] || [ -z "$reason" ] || usage "--reason goes with --hold"
if [[ "$pr" =~ ^[0-9]+$ ]]; then
  pr=$(gh pr view "$pr" --json url -q .url 2>/dev/null) || { echo "merge-ready: cannot find pull request $pr" >&2; exit 1; }
fi
url_re='^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+)$'
[[ "$pr" =~ $url_re ]] || usage "not a pull request url: $pr"
number=${BASH_REMATCH[3]}

if [ -z "${MERGE_QUEUE_DIR:-}" ]; then
  main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$main" ] || { echo "merge-ready: not in a git checkout; set MERGE_QUEUE_DIR" >&2; exit 2; }
  MERGE_QUEUE_DIR=$(dirname "$main")/merge-queue
fi
export MERGE_QUEUE_DIR
mkdir -p "$MERGE_QUEUE_DIR/holds"
marker="$MERGE_QUEUE_DIR/holds/${BASH_REMATCH[1]}_${BASH_REMATCH[2]}_$number"
log="$MERGE_QUEUE_DIR/merge-ready.log"

head="" verdict=""
finish() { # finish <exit code> <state> <detail>: the JSON line on stdout and in the log, then exit
  local line
  line=$(node -e 'const [state, pr, head, verdict, detail] = process.argv.slice(1);
    console.log(JSON.stringify({ time: new Date().toISOString(), state, pr, head, verdict, detail }));' \
    "$2" "$pr" "$head" "$verdict" "$3")
  echo "$line"
  [ "$mode" = check ] || echo "$line" >> "$log" || echo "merge-ready: could not write $log" >&2
  exit "$1"
}
ping_owner() { # ping_owner <info|warn|act> <key> <subject>: a missing script or a failed ping is logged only (D9)
  if [ -f "$notify_owner" ] && bash "$notify_owner" "$@" >&2; then return 0; fi
  echo "merge-ready: ping not delivered ($1 $2): $3" >&2
}
leave_queue() { bash "$merge_turn" drop "$pr" >/dev/null 2>&1 || true; }
held_by() { sed -n 's/^reason: //p' "$marker" 2>/dev/null; }

case "$mode" in
  hold)
    printf 'reason: %s\ntime: %s\nby: %s\n' "$reason" "$(date -u +%FT%TZ)" "${USER:-unknown}" > "$marker" \
      || finish 1 error "could not write the hold marker $marker"
    leave_queue
    finish 10 held "hold marker set: $reason" ;;
  unhold)
    [ -f "$marker" ] || finish 1 error "no hold marker on $pr"
    rm -f "$marker"
    finish 0 unheld "hold marker removed (was: $(held_by))" ;;
esac

facts() { gh pr view "$pr" --json state,headRefOid,isDraft,mergeable -q '"\(.state) \(.headRefOid) \(.isDraft) \(.mergeable)"'; }
read -r state head draft mergeable < <(facts 2>/dev/null) || true
[ -n "${state:-}" ] || finish 1 error "cannot read $pr from GitHub"
case "$state" in
  MERGED) finish 0 merged "already merged, not by this script: no audit comment" ;;
  CLOSED) finish 5 closed "closed without a merge" ;;
esac
[ -f "$marker" ] && finish 10 held "hold marker: $(held_by)"

# The STOP verdict for this head. Anything but none, covered or owner as the first word is an error: no merge.
[ -f "$stop_check" ] || finish 1 error "no $stop_check: no merge without a STOP verdict"
errf=$(mktemp); trap 'rm -f "$errf"' EXIT
verdict_out=$(bash "$stop_check" "$pr" 2> "$errf")
said=$(tail -n 3 "$errf" | tr '\n' ' ')
verdict=$(printf '%s\n' "$verdict_out" | head -n 1 | awk '{print $1}')
reasons=$(printf '%s\n' "$verdict_out" | sed '1s/^[^ ]* *//' | sed '/^$/d' | paste -sd ';' - | sed 's/;/; /g')
case "$verdict" in
  none|covered) ;;
  owner)
    [ "$mode" = check ] && finish 10 held "STOP verdict owner: ${reasons:-no reason given} (--check: nothing changed, no ping)"
    leave_queue
    # The ping carries only the PR number, the verdict and the category ids, never free text (ticket names could reach
    # the phone); the full reasons stay in the log line.
    cats=$(printf '%s\n' "$verdict_out" | sed '1d' | awk '{print $1}' | grep -E '^[a-z][a-z0-9-]{0,40}$' | sort -u | paste -sd ',' -)
    ping_owner act "merge-held-$number" "PR #$number: STOP verdict owner (${cats:-uncategorised}); bash .archon/scripts/merge-ready.sh $pr --check" --about "pr:$number"
    finish 10 held "STOP verdict owner: ${reasons:-no reason given}; out of the merge queue, the owner decides" ;;
  *) verdict=""; finish 1 error "stop-check gave no verdict (${said:-no output}): no merge" ;;
esac

[ "$draft" = true ] && finish 4 not-ready "still a draft: the run's last gates have not passed"
[ "$mergeable" = CONFLICTING ] && finish 4 not-ready "conflicts with its base: rebase it, push, call again"
[ "$mode" = check ] && finish 0 ready "would merge at its merge turn (CI, reviews and threads are checked then)"

out=$(bash "$merge_turn" wait "$pr"); rc=$?
case "$rc" in
  0) ;;
  3) finish 3 behind "$(printf '%s' "$out" | node -e 'try { console.log(JSON.parse(require("fs").readFileSync(0, "utf8")).detail) } catch { console.log("behind its base") }')" ;;
  *) finish 1 error "merge-turn.sh wait exited $rc" ;;
esac

# Waiting for the turn can take long: look again before the merge.
checked=$head
read -r state head _ _ < <(facts 2>/dev/null) || true
case "${state:-}" in
  MERGED) finish 0 merged "merged meanwhile, not by this script: no audit comment" ;;
  CLOSED) finish 5 closed "closed without a merge" ;;
  OPEN) ;;
  *) head=$checked; finish 1 error "cannot read $pr from GitHub" ;;
esac
[ -f "$marker" ] && finish 10 held "hold marker: $(held_by)"
[ "$head" = "$checked" ] || finish 4 not-ready "the head moved from $checked to $head after the STOP verdict: call again"

out=$(timeout "$timeout_s" bash "$auto_merge" "$pr" --head "$checked"); rc=$?
[ "$rc" -eq 124 ] && finish 4 not-ready "reviews, threads or CI still open after ${timeout_s}s: call again later"
merge_state=$(printf '%s' "$out" | node -e 'try { const j = JSON.parse(require("fs").readFileSync(0, "utf8").trim().split("\n").pop()); console.log(j.state + "\t" + j.sha + "\t" + j.detail) } catch { console.log("") }')
IFS=$'\t' read -r am_state am_sha am_detail <<< "$merge_state"
case "${am_state:-}" in
  merged) ;;
  closed) finish 5 closed "closed without a merge" ;;
  main-red)
    triage=$(bash "$red_triage" --base main "$am_sha" 2>/dev/null | tail -1)
    t_class=$(printf '%s' "$triage" | jq -r '.class // ""' 2>/dev/null) t_rerun=$(printf '%s' "$triage" | jq -r '.rerun // ""' 2>/dev/null)
    [ "$t_class" = green ] && finish 4 not-ready "auto-merge: main-red: $am_detail; green after a rerun ($t_rerun): call again"
    ping_owner act "main-red-${am_sha:0:7}" "main is red at ${am_sha:0:7} (${t_class:-not triaged}): bash .archon/scripts/local-ci-run.sh --logs $am_sha" \
      --about "sha:$am_sha"
    finish 4 not-ready "auto-merge: main-red: $am_detail" ;;
  conflict|red|moved|none) finish 4 not-ready "auto-merge: $am_state: $am_detail" ;;
  *) finish 1 error "auto-merge.sh exited $rc without a known state" ;;
esac

# Merged: the merged head must be the one checked (auto-merge pins it; someone else may have merged another head).
merged_head=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null)
if [ "$merged_head" != "$checked" ]; then
  head=${merged_head:-$checked}
  ping_owner act "merge-head-$number" "PR #$number merged at $head, not at the checked head $checked"
  finish 1 error "merged as $am_sha at head $head, not at the checked head $checked (merged by someone else?)"
fi
body="merge-ready: merged head $checked as $am_sha at $(date -u +%FT%TZ). STOP verdict: $verdict${reasons:+ ($reasons)}. CI green by SHA, every review given, no thread open (auto-merge.sh). Owner decision 2026-10-20, D7."
# The marker merge-ledger.sh attributes the merge by (R22).
body="$body
<!-- merge-ledger: by=merge-ready.sh; rule=D7: no unapproved STOP item -->"
if gh pr comment "$pr" --body "$body" >&2; then
  finish 0 merged "merged as $am_sha; audit comment posted"
fi
ping_owner warn "merge-audit-$number" "PR #$number merged, but its audit comment was not posted"
finish 0 merged "merged as $am_sha; the audit comment was NOT posted (the log line stands)"
