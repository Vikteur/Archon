#!/usr/bin/env bash
# The merge queue (P2: a script, not a model; owner decision 2026-10-18, docs/memory.md, TASK-56): runs that reach the
# merge gate together merge one by one, so each pull request is tested against the main the one before it merged into.
#   merge-turn.sh wait <pr url>         queue it (once) and wait for its turn; then, when it is behind its base, print
#                                       {"state": "behind", "sha": "<head>", "detail": "..."} and exit 3 (it keeps the
#                                       turn: bring it up to date, CI runs on the new head, then wait again). Exit 0 at
#                                       its turn when it is up to date, or when it is already merged or closed.
#                                       Commits it lacks that change only files under the exempt paths (backlog/,
#                                       docs/retro/, docs/tokenomics/: the list `push-guard.sh paths` prints, the
#                                       commits that may reach main without a pull request) and that it does not change
#                                       itself do not make it behind (TASK-73; owner decision 2026-10-20, D14), while
#                                       `rebase-behind.sh --policy` does not print behind-means-rebase; once it does
#                                       (reuse is live: D7, staged), only the paths that run no CI stay exempt
#                                       (ci-skip.sh: backlog/, docs/retro/, docs/tokenomics/; owner decisions
#                                       2026-10-22, 2026-10-23).
#   merge-turn.sh list                  the queue, first turn first
#   merge-turn.sh first <pr url>...     these get the next turns, in this order (the delegator's better order); the
#                                       one holding the turn keeps it, the rest keep their order
#   merge-turn.sh drop <pr url>         take it out (a run's pull request that will not merge)
#                                       At its turn, when main's tip (the base) has no local CI verdict (none, or a
#                                       run that died: stale), local CI is started on it in the background first, so it
#                                       queues before this pull request's own run (CI plan C14, owner decision D9:
#                                       auto-merge.sh merges only onto a green main tip). A red tip is said, not fixed.
# The order is arrival at the gate: first finished, first merged. A merged or closed pull request leaves the queue on its
# own when a `wait` looks at it; one that stays open holds the turn until it merges or is dropped. A `wait` whose pull
# request is dropped while it waits exits 1. first and drop exit 1 for a pull request not queued.
# The queue is one URL per line in $MERGE_QUEUE_DIR/queue (default: merge-queue/ beside the main checkout).
# The compare answers are read from files, never from command-line arguments (TASK-75); a main...head compare that
# cannot be read exits 1 with the reason, a head...main one counts as behind with the reason.
# Overrides: MERGE_QUEUE_DIR, MERGE_TURN_POLL_SECONDS (60), LOCAL_CI_STATUS, LOCAL_CI_RUN and REBASE_BEHIND (the
# scripts to call).
set -uo pipefail

usage() { echo "merge-turn: $*" >&2; echo "usage: merge-turn.sh wait <pr url> | list | first <pr url>... | drop <pr url>" >&2; exit 2; }
url_re='^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+)$'
POLL=${MERGE_TURN_POLL_SECONDS:-60}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
push_guard=$here/push-guard.sh
status=${LOCAL_CI_STATUS:-$here/local-ci-status.sh}
run_ci=${LOCAL_CI_RUN:-$here/local-ci-run.sh}
rebase_behind=${REBASE_BEHIND:-$here/rebase-behind.sh}
if [ -z "${MERGE_QUEUE_DIR:-}" ]; then
  main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$main" ] || { echo "merge-turn: not in a git checkout; set MERGE_QUEUE_DIR" >&2; exit 2; }
  MERGE_QUEUE_DIR=$(dirname "$main")/merge-queue
fi
q=$MERGE_QUEUE_DIR/queue lock=$MERGE_QUEUE_DIR/queue.lock
mkdir -p "$MERGE_QUEUE_DIR"; touch "$q"

locked() { # locked <command...>: run it holding the queue lock (held for a moment only; a lock older than 60 s is stale)
  local n=0
  until mkdir "$lock" 2>/dev/null; do
    n=$((n+1))
    [ "$n" -gt 600 ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && { rmdir "$lock" 2>/dev/null; n=0; }
    sleep 0.1
  done
  "$@"; local rc=$?
  rmdir "$lock"
  return $rc
}
queued() { grep -qxF "$1" "$q"; }
add() { queued "$1" || echo "$1" >> "$q"; }
remove() { grep -vxF "$1" "$q" > "$q.tmp"; mv "$q.tmp" "$q"; }
front() { # front <pr url>...: these next, in this order, after the one holding the turn (unless it is named)
  local holder; holder=$(head -n 1 "$q")
  printf '%s\n' "$@" | grep -qxF "$holder" && holder=""
  { [ -n "$holder" ] && echo "$holder"; printf '%s\n' "$@"; grep -vxF -f <(printf '%s\n' "$@" "$holder") "$q"; } > "$q.tmp"
  mv "$q.tmp" "$q"
}
facts() { gh pr view "$1" --json state,headRefOid,baseRefName -q '"\(.state) \(.headRefOid) \(.baseRefName)"'; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  list) cat "$q" ;;
  drop)
    [[ "${1:-}" =~ $url_re ]] || usage "drop needs a pull request url"
    queued "$1" || { echo "merge-turn: $1 is not queued" >&2; exit 1; }
    locked remove "$1"; echo "merge-turn: dropped $1" >&2 ;;
  first)
    [ $# -gt 0 ] || usage "first needs a pull request url"
    for p in "$@"; do
      [[ "$p" =~ $url_re ]] || usage "not a pull request url: $p"
      queued "$p" || { echo "merge-turn: $p is not queued" >&2; exit 1; }
    done
    locked front "$@"; echo "merge-turn: first now: $*" >&2 ;;
  wait)
    pr=${1:-}
    [[ "$pr" =~ $url_re ]] || usage "wait needs a pull request url"
    owner=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
    locked add "$pr"
    said=""
    while :; do
      # The pull requests before this one: a merged or closed one leaves; the first open one holds the turn.
      holder=""
      while IFS= read -r p; do
        [ "$p" = "$pr" ] && break
        read -r state _ _ < <(facts "$p") || state=""
        case "$state" in
          MERGED|CLOSED) locked remove "$p"; echo "merge-turn: $p is ${state,,}; it left the queue" >&2 ;;
          *) holder=$p; break ;;
        esac
      done < "$q"
      queued "$pr" || { echo "merge-turn: $pr was dropped from the queue" >&2; exit 1; }
      [ -z "$holder" ] && break
      [ "$said" = "$holder" ] || { echo "merge-turn: waiting; $holder holds the merge turn" >&2; said=$holder; }
      sleep "$POLL"
    done
    read -r state head base < <(facts "$pr") || { echo "merge-turn: cannot read $pr" >&2; exit 1; }
    case "$state" in
      MERGED|CLOSED) locked remove "$pr"; echo "merge-turn: $pr is already ${state,,}" >&2; exit 0 ;;
    esac
    # The compare answers go to files and node reads those: one command-line argument is capped at 131072 bytes and a
    # compare with patches is bigger (TASK-75, PR #180).
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    gh api "repos/$owner/$name/compare/$base...$head" > "$tmp/ahead.json" || { echo "merge-turn: cannot compare $head with $base" >&2; exit 1; }
    behind=$(node -e '
        try {
          const b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).behind_by;
          if (!Number.isInteger(b) || b < 0) throw new Error("behind_by is missing or not a count");
          console.log(b);
        } catch (e) { console.error(e.message); process.exit(2); }' "$tmp/ahead.json" 2> "$tmp/why") \
      || { echo "merge-turn: cannot read the compare of $head with $base: $(cat "$tmp/why")" >&2; exit 1; }
    # The behind policy is rebase-behind.sh's (D7, staged), so the two never disagree: the TASK-73 exemption below holds
    # until it says behind-means-rebase (reuse is live), and then behind always means rebase.
    policy=$(bash "$rebase_behind" --policy 2>/dev/null) || policy=""
    if [ "$behind" -gt 0 ]; then
      # Behind only by changes under the exempt paths that this pull request does not touch (a close-out, the
      # delegator's ticket commit, a retro, the token reports): the code under test is the same, so it does not count
      # (TASK-73). The paths are push-guard.sh's exempt list, so the two cannot drift; without it, backlog/ only.
      # Once the policy is behind-means-rebase, only the paths that run no CI stay exempt (ci-skip.sh: backlog/,
      # docs/retro/, docs/tokenomics/; owner decisions 2026-10-22, 2026-10-23). Over 300 files GitHub cuts the list.
      if [ "$policy" = behind-means-rebase ]; then
        exempt=$(bash "$here/ci-skip.sh" paths 2>/dev/null) && [ -n "$exempt" ] || exempt=docs/retro/
        echo "merge-turn: policy behind-means-rebase: only $(echo $exempt) stay exempt from behind" >&2
      else
        exempt=$(bash "$push_guard" paths 2>/dev/null) && [ -n "$exempt" ] || exempt=backlog/
      fi
      if ! gh api "repos/$owner/$name/compare/$head...$base" > "$tmp/missing.json"; then
        echo "merge-turn: cannot read the files $base changed since $head; counted as behind" >&2
      else
        node -e '
          try {
            const read = f => JSON.parse(require("fs").readFileSync(f, "utf8")).files || [];
            const names = l => l.flatMap(f => [f.filename, f.previous_filename].filter(Boolean));
            const missing = read(process.argv[2]), ours = new Set(names(read(process.argv[1])));
            const prefixes = process.argv[3].split("\n").filter(Boolean);
            const cut = missing.length >= 300;
            process.exit(!cut && names(missing).every(f => prefixes.some(p => f.startsWith(p)) && !ours.has(f)) ? 0 : 1);
          } catch (e) { console.error(e.message); process.exit(2); }' \
          "$tmp/ahead.json" "$tmp/missing.json" "$exempt" 2> "$tmp/why"
        case $? in
          0)
            echo "merge-turn: $pr is $behind commit(s) behind $base, which change only exempt files ($(echo $exempt)) it does not touch; not behind" >&2
            behind=0 ;;
          2) echo "merge-turn: cannot read the compare of $base since $head: $(cat "$tmp/why"); counted as behind" >&2 ;;
        esac
      fi
    fi
    if [ "$behind" -gt 0 ]; then
      node -e 'console.log(JSON.stringify({ state: "behind", sha: process.argv[1], detail: process.argv[2] }))' "$head" \
        "the merge turn is this pull request's, but it is $behind commit(s) behind $base: rebase it onto origin/$base and push; CI then runs on the new head"
      exit 3
    fi
    # Main's tip gets a verdict before this one merges onto it (D9): with none yet, its local CI is started now. The
    # compare's base_commit is the base's tip; nothing here ever fails the turn.
    tip=$(node -e 'console.log((JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).base_commit || {}).sha || "")' "$tmp/ahead.json" 2>/dev/null) \
      || echo "merge-turn: warning: cannot read $base's tip from the compare" >&2
    if [ -n "$tip" ]; then
      tip_state=$(bash "$status" "$owner/$name" "$tip" 2>/dev/null | cut -d' ' -f1)
      case "$tip_state" in
        none|stale)
          if bash "$run_ci" "$tip" --no-wait >&2; then
            echo "merge-turn: $base's tip ${tip:0:7} has no CI verdict ($tip_state): local CI started on it first (D9)" >&2
          else
            echo "merge-turn: warning: $base's tip ${tip:0:7} has no CI verdict and local CI did not start on it" >&2
          fi ;;
        red) echo "merge-turn: warning: $base's tip ${tip:0:7} is red: auto-merge.sh does not merge onto a red main (D9)" >&2 ;;
      esac
    fi
    echo "merge-turn: $pr has the merge turn" >&2 ;;
  *) usage "unknown command '${cmd}'" ;;
esac
