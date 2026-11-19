#!/usr/bin/env bash
# What local CI cost, per day and per ticket, read from the CI ledger (CI plan C20; owner decision D17 of 2026-10-20,
# docs/memory.md: the ledger is kept forever, so this report can always be rebuilt). Local only: it reads the ledger
# file and the repo's own git objects, never GitHub. A report, never a gate on a commit (P5: statuses by SHA are the
# verdict); only --guard exits non-zero, for the Gradle growth guard.
#   ci-cost.sh [--ledger <file>] [--repo <dir>] [--since <yyyy-mm-dd>] [--json] [--guard]
# Per day (UTC, of the run's end) and per ticket (the run's CI_LOCAL_TICKET, "(none)" without one):
#   runs       the runs that ended (an end line), aborted ones included
#   lock-min   minutes each run held the CI lock: t_end - t_lock (t_start when no t_lock)
#   reuse      the share of job verdicts that were a reuse ("reused from <sha12>…", a verdict or a reuse or same-tree
#              line), and the jobs the planner would
#              have reused in shadow mode (a decision line "would reuse" whose job ran anyway, as ci-local writes it)
#   avoidable  the lock minutes of runs that need not have run, each run credited once, to the first class it is in:
#     same-tree   a green run of the same tree on the same base ran before it
#     rebase-only an earlier green run of the same PR had the same patch (git patch-id of base..sha), on another sha
#     bookkeeping every path the run's change touched is bookkeeping: backlog/, docs/retro/, docs/tokenomics/
#     red-tail    a red run's minutes after its first failing verdict (the rest of it was needed to learn it is red)
#   The first three need the commits in --repo (default: the repo around the working directory); a commit it does not
#   have puts the run in no class and is counted as "unknown".
# The Gradle growth guard: the median own seconds of the Gradle jobs (CI_COST_GRADLE_JOBS, default "test") that ran
# green, over the last 7 days of the ledger, against the median over its first 7 days; more than +20%
# (CI_COST_GROWTH, default 1.2) trips it. Each window needs CI_COST_GUARD_MIN samples (default 5), else it says so.
# Exit 0: the report (and, with --guard, the guard holds or has too few samples). 1: --guard and the guard tripped.
# 2: usage. 3: the report could not be built (jq missing, the ledger unreadable).
set -uo pipefail

usage() { echo "usage: ci-cost.sh [--ledger <file>] [--repo <dir>] [--since <yyyy-mm-dd>] [--json] [--guard]" >&2; exit 2; }
cannot() { echo "ci-cost: could not run: $*" >&2; exit 3; }

ledger=${CI_LEDGER:-$HOME/ci-local/ledger.jsonl}
repo="" since="" json="" guard=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) [ $# -ge 2 ] || usage; ledger=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --since) [ $# -ge 2 ] || usage; since=$2; shift 2 ;;
    --json) json=1; shift ;;
    --guard) guard=1; shift ;;
    *) usage ;;
  esac
done
[ -z "$since" ] || [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
command -v jq > /dev/null || cannot "jq is required"
if [ ! -e "$ledger" ]; then
  echo "ci-cost: no ledger at $ledger (nothing recorded yet)"
  exit 0
fi
[ -r "$ledger" ] || cannot "cannot read $ledger"
[ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || repo=""

tmp=$(mktemp -d) || cannot "no temp dir"
trap 'rm -rf "$tmp"' EXIT

# The ledger's lines that parse (a torn or foreign line is skipped, and counted).
jq -c 'select(type == "object" and (.ev | type) == "string")' "$ledger" 2> /dev/null > "$tmp/lines" \
  || jq -cR 'fromjson? | select(type == "object" and (.ev | type) == "string")' "$ledger" > "$tmp/lines" \
  || cannot "cannot parse $ledger"
skipped=$(( $(grep -c '' "$ledger") - $(grep -c '' "$tmp/lines") ))

# One row per ended run: key, sha, base, pr, green. The key is sha + run id: a run id is per commit.
jq -rs '
  (map(select(.ev == "start")) | map({key: "\(.sha):\(.run)", value: .base}) | from_entries) as $base
  | map(select(.ev == "end")) | .[]
  | [ "\(.sha):\(.run)", .sha, ($base["\(.sha):\(.run)"] // ""), (.pr // "" | tostring),
      (if .rc == 0 and (.aborted | not) then 1 else 0 end) ] | @tsv' "$tmp/lines" > "$tmp/runs" \
  || cannot "cannot read the runs in $ledger"

# The git facts per run: its tree, its patch-id against the base, and whether its change is bookkeeping only.
bookkeeping='^(backlog/|docs/retro/|docs/tokenomics/)'
{
  echo '{'
  first=1
  while IFS=$'\t' read -r key sha base _pr _green; do
    tree="" patch="" book=""
    if [ -n "$repo" ] && git -C "$repo" cat-file -e "$sha^{commit}" 2> /dev/null; then
      tree=$(git -C "$repo" rev-parse "$sha^{tree}" 2> /dev/null)
      if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2> /dev/null; then
        mb=$(git -C "$repo" merge-base "$base" "$sha" 2> /dev/null || echo "$base")
        patch=$(git -C "$repo" diff "$mb" "$sha" 2> /dev/null | git -C "$repo" patch-id --stable 2> /dev/null | cut -d' ' -f1)
        names=$(git -C "$repo" diff --name-only "$mb" "$sha" 2> /dev/null)
        if [ -n "$names" ] && ! grep -qvE "$bookkeeping" <<< "$names"; then book=1; else book=0; fi
      fi
    fi
    [ -n "$first" ] || echo ','
    first=""
    jq -cn --arg k "$key" --arg tree "$tree" --arg patch "$patch" --arg book "$book" \
      '{($k): {tree: $tree, patch: $patch, book: (if $book == "" then null else $book == "1" end)}}' | sed 's/^{//; s/}$//'
  done < "$tmp/runs"
  echo '}'
} > "$tmp/facts" || cannot "cannot read the commits"

growth=${CI_COST_GROWTH:-1.2}
guard_min=${CI_COST_GUARD_MIN:-5}
gradle_jobs=${CI_COST_GRADLE_JOBS:-test}

jq -s --slurpfile facts "$tmp/facts" --arg since "$since" --argjson growth "$growth" --argjson gmin "$guard_min" \
  --arg gjobs "$gradle_jobs" --argjson skipped "$skipped" '
  def day: (. | floor | strftime("%Y-%m-%d"));
  def r1: (. * 10 | round / 10);
  def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor]
              else (.[length / 2 - 1] + .[length / 2]) / 2 end;
  $facts[0] as $f
  | . as $all
  | ($all | map(select(.ev == "start")) | map({key: "\(.sha):\(.run)", value: .}) | from_entries) as $starts
  # A reused job writes a reuse or same-tree line instead of a verdict (live since 2026-10-23); both count as one.
  | ($all | map(select(.ev == "verdict" or .ev == "reuse" or .ev == "same-tree")) | group_by("\(.sha):\(.run)")
      | map({key: "\(.[0].sha):\(.[0].run)", value: .}) | from_entries) as $verdicts
  | ($all | map(select(.ev == "decision" and ((.decision // "") == "would reuse" or ((.plan // "") | startswith("reuse"))) and .taken == "run"))
      | group_by("\(.sha):\(.run)") | map({key: "\(.[0].sha):\(.[0].run)", value: length}) | from_entries) as $shadow
  # The ended runs, in end order, each with what the classes need.
  | [ $all[] | select(.ev == "end") | . as $e | "\(.sha):\(.run)" as $k
      | ($starts[$k] // {}) as $s
      | {key: $k, sha, pr, ticket: (.ticket // "(none)"), t_end, day: (.t_end | day),
         lock: (((.t_end // 0) - (.t_lock // .t_start // $s.t_lock // $s.t_start // .t_end // 0)) | if . < 0 then 0 else . end),
         base: ($s.base // ""), green: (.rc == 0 and (.aborted | not)),
         tree: ($f[$k].tree // ""), patch: ($f[$k].patch // ""), book: ($f[$k].book),
         verdicts: ($verdicts[$k] // []), shadow: ($shadow[$k] // 0), jobs: (.jobs // {})} ]
  | sort_by(.t_end)
  # Credit each run once, to the first class it is in, against the green runs that ended before it.
  | reduce .[] as $r ({seen: [], out: []};
      .seen as $seen
      | ([$r.verdicts[] | select(.state == "failure" or .state == "error") | .t] | min) as $ff
      | (if $r.tree != "" and ($seen | any(.tree == $r.tree and .base == $r.base)) then "same-tree"
         elif $r.patch != "" and $r.pr != null
              and ($seen | any(.pr == $r.pr and .patch == $r.patch and .sha != $r.sha)) then "rebase-only"
         elif $r.book == true then "bookkeeping"
         elif ($r.green | not) and $ff != null then "red-tail"
         elif $r.tree == "" then "unknown"
         else null end) as $class
      | (if $class == "red-tail" then ($r.t_end - $ff | if . < 0 then 0 elif . > $r.lock then $r.lock else . end)
         elif $class == null or $class == "unknown" then 0
         else $r.lock end) as $avoid
      | .out += [$r + {class: $class, avoid: $avoid}]
      | if $r.green then .seen += [{tree: $r.tree, base: $r.base, pr: $r.pr, patch: $r.patch, sha: $r.sha}] else . end)
  | .out as $runs
  | ($runs | map(select($since == "" or .day >= $since))) as $sel
  | def summary: . as $rows |
      { runs: ($rows | length),
        lock_min: ($rows | map(.lock) | add // 0 | . / 60 | r1),
        verdicts: ($rows | map(.verdicts | length) | add // 0),
        reused: ($rows | map([.verdicts[] | select((.description // "") | startswith("reused from"))] | length) | add // 0),
        shadow_reusable: ($rows | map(.shadow) | add // 0),
        avoidable_min: (reduce ("same-tree", "rebase-only", "bookkeeping", "red-tail") as $c ({};
          .[$c] = ($rows | map(select(.class == $c) | .avoid) | add // 0 | . / 60 | r1))),
        unknown_runs: ($rows | map(select(.class == "unknown")) | length) }
      | .reuse_share = (if .verdicts == 0 then 0 else (.reused / .verdicts * 1000 | round / 10) end)
      | .avoidable_total_min = ([.avoidable_min[]] | add | r1);
  # The Gradle growth guard over the whole ledger.
  ($gjobs | split(" ") | map(select(. != ""))) as $gj
  | [ $runs[] | . as $r | $gj[] as $j | ($r.jobs[$j] // empty)
      | select(.kind == "ran" and .res == "success" and ((.own // 0) > 0)) | {t: $r.t_end, own} ] as $g
  | (if ($g | length) == 0 then {state: "no samples"} else
      ($g | map(.t) | min) as $t0 | ($g | map(.t) | max) as $t1
      | ($g | map(select(.t < $t0 + 7 * 86400) | .own)) as $first
      | ($g | map(select(.t > $t1 - 7 * 86400) | .own)) as $last
      | if $t1 - $t0 < 7 * 86400 or ($first | length) < $gmin or ($last | length) < $gmin
        then {state: "too few samples", first_n: ($first | length), last_n: ($last | length), min: $gmin}
        else ($first | median) as $a | ($last | median) as $b
          | {state: (if $b > $a * $growth then "tripped" else "holds" end), first_median_s: $a, last_median_s: $b,
             first_n: ($first | length), last_n: ($last | length), limit: $growth}
        end end) as $guard
  | { since: (if $since == "" then null else $since end), skipped_lines: $skipped,
      total: ($sel | summary),
      by_day: ($sel | group_by(.day) | map({key: .[0].day, value: summary}) | from_entries),
      by_ticket: ($sel | group_by(.ticket) | map({key: .[0].ticket, value: summary}) | from_entries),
      guard: $guard }' "$tmp/lines" > "$tmp/report" || cannot "cannot build the report"

if [ -n "$json" ]; then
  cat "$tmp/report"
else
  table() { if command -v column > /dev/null; then column -t -s $'\t'; else cat; fi; }
  jq -r '"ci-cost: local CI from the ledger" + (if .since then " since \(.since)" else "" end)
      + (if .skipped_lines > 0 then " (\(.skipped_lines) unreadable line(s) skipped)" else "" end)' "$tmp/report"
  for section in by_day:day by_ticket:ticket; do
    echo
    jq -r --arg s "${section%%:*}" --arg h "${section#*:}" '
        def row(k): [k, .runs, .lock_min, "\(.reuse_share)% (\(.reused)/\(.verdicts))", .shadow_reusable,
          .avoidable_min["same-tree"], .avoidable_min["rebase-only"], .avoidable_min.bookkeeping, .avoidable_min["red-tail"],
          .avoidable_total_min, .unknown_runs] | map(tostring) | join("\t");
        ([$h, "runs", "lock-min", "reuse", "shadow", "same-tree", "rebase-only", "bookkeeping", "red-tail", "avoidable",
          "unknown"] | join("\t")),
        (.[$s] | to_entries[] | .key as $k | .value | row($k)),
        (.total | row("total"))' "$tmp/report" | table
  done
  echo
  jq -r '.guard | "gradle growth guard: " + .state
      + (if .state == "tripped" or .state == "holds"
         then ": median \(.last_median_s)s over the last 7 days against \(.first_median_s)s over the first 7 (limit x\(.limit))"
         elif .state == "too few samples" then " (\(.first_n) and \(.last_n) of \(.min) needed, over at least 7 days)"
         else "" end)' "$tmp/report"
fi

if [ -n "$guard" ] && [ "$(jq -r '.guard.state' "$tmp/report")" = tripped ]; then
  echo "ci-cost: FAIL: the Gradle jobs grew more than the guard allows" >&2
  exit 1
fi
exit 0
