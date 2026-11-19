#!/usr/bin/env bash
# The CI ledger (CI plan 2026-10-20, C4): one append-only JSON-lines file of what local CI did and why, for the cost
# report and the reuse audit. Never a gate: no script answers "is this commit green" from it (P5, statuses by SHA do),
# and a write that fails never fails the run that makes it. Kept forever (owner decision D17): pruning it is a STOP item.
#   File: $CI_LEDGER (default $HOME/ci-local/ledger.jsonl), appended under flock on the file itself.
#   Source it and call   ci_ledger <event> [--arg k v | --argjson k json]...
#   or run it:           ci-ledger.sh <event> [k=v | k:=json]...
#                        ci-ledger.sh junit <dir>     the per-test-set seconds of the JUnit XML under <dir>, as JSON
# Every line: {"v":1,"ev":<event>,"t":<epoch s UTC>,"host":…,"caller":$CI_LOCAL_CALLER,"ticket":$CI_LOCAL_TICKET,…}
# plus the named fields (v, ev, t and host are the helper's own). Events: request, queued, start, end, verdict, reuse, affected (and
# whatever later writers add: decision, enqueue, drop, cancel). It holds SHAs, PR and ticket ids, host names and
# durations; never a person's name or e-mail address.
# One field style: ev, t and state. A writer's event/ts are dropped and its status becomes state (when no state is
# given); readers still accept both styles for the lines written before (`.ev // .event`, `.t // .ts`, `.state // .status`).

ci_ledger() { # ci_ledger <event> [jq --arg/--argjson pairs]...
  local ev=$1 file=${CI_LEDGER:-$HOME/ci-local/ledger.jsonl} line
  shift
  line=$(jq -cn --arg ev "$ev" --argjson t "$(date -u +%s)" --arg host "$(hostname 2>/dev/null)" \
    --arg caller "${CI_LOCAL_CALLER:-}" --arg ticket "${CI_LOCAL_TICKET:-}" "$@" \
    '({v: 1} + $ARGS.named)
     | if has("status") and (has("state") | not) then .state = .status else . end | del(.event, .ts, .status)
     | .ev = $ev | .t = $t
     | .caller |= (if . == "" then null else . end) | .ticket |= (if . == "" then null else . end)' \
    2>/dev/null) || { echo "ci-ledger: could not build the $ev line (not recorded)" >&2; return 0; }
  mkdir -p "$(dirname "$file")" 2>/dev/null
  if command -v flock > /dev/null; then
    { flock -w 10 9 && printf '%s\n' "$line" >&9; } 2>/dev/null 9>>"$file"
  else
    printf '%s\n' "$line" 2>/dev/null >> "$file"   # one short line per write: an append of it is not interleaved
  fi || echo "ci-ledger: could not append the $ev line to $file (not recorded)" >&2
  return 0
}

# ci_ledger_junit <dir>: {"<module>:<task>": {"secs":…, "tests":…, "failures":…, "skipped":…}} summed over the
# TEST-*.xml files under <module>/build/test-results/<task>/ (Gradle's layout; "." is the root project), {} if none.
ci_ledger_junit() {
  local dir=${1%/}
  { find "$dir" -path '*/build/test-results/*' -name 'TEST-*.xml' -not -path '*/node_modules/*' 2>/dev/null || true; } \
    | while IFS= read -r f; do
        rel=${f#"$dir"/}
        if [[ "$rel" == build/test-results/* ]]; then mod=.
        else mod=${rel%%/build/test-results/*}; [ "$mod" = "$rel" ] && continue
        fi
        task=${rel#*build/test-results/}; task=${task%%/*}
        # The first <testsuite ...> tag: its tests, failures, errors, skipped and time attributes.
        tr '\n' ' ' < "$f" | grep -o '<testsuite [^>]*>' | head -1 | awk -v key="$mod:$task" '
          function attr(n,   m) { return match($0, " " n "=\"[^\"]*\"") ? substr($0, RSTART + length(n) + 3, RLENGTH - length(n) - 4) : 0 }
          { printf "%s\t%s\t%s\t%s\t%s\n", key, attr("time") + 0, attr("tests") + 0, attr("failures") + attr("errors"), attr("skipped") + 0 }'
      done \
    | jq -cRn '[inputs | split("\t") | {k: .[0], s: (.[1] | tonumber), n: (.[2] | tonumber), f: (.[3] | tonumber), sk: (.[4] | tonumber)}]
        | group_by(.k) | map({key: .[0].k, value: {secs: (map(.s) | add * 1000 | round / 1000), tests: (map(.n) | add),
          failures: (map(.f) | add), skipped: (map(.sk) | add)}}) | from_entries' 2>/dev/null || echo '{}'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    ""|-h|--help) sed -n '2,13p' "$0"; exit 2 ;;
    junit) ci_ledger_junit "${2:-.}" ;;
    *)
      ev=$1; shift
      args=()
      for kv in "$@"; do
        case "$kv" in
          *:=*) args+=(--argjson "${kv%%:=*}" "${kv#*:=}") ;;
          *=*) args+=(--arg "${kv%%=*}" "${kv#*=}") ;;
          *) echo "ci-ledger: '$kv' is not k=v or k:=json (ignored)" >&2 ;;
        esac
      done
      ci_ledger "$ev" "${args[@]}" ;;
  esac
  exit 0
fi
