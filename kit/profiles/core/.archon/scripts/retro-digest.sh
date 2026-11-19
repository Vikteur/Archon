#!/usr/bin/env bash
# The nightly retro digest (P2: a script gathers, a model only reads; R22, owner decision D16 2026-10-20,
# docs/memory.md): one Markdown page per night that lists what reached main, who put it there under which rule
# (merge-ledger.sh), every build-feature run in the window with its outcome, and what needs a person: the incidents
# that get a full retro (a failed run, a stall, a fix verdict that failed), and the changes to review after the fact
# (unattributed, STOP items named, a cancelled run with no stopped section). Per-ticket retros are not made any more (D16),
# so a merge without one is only shown in the merges table.
#   retro-digest.sh [--since <date>] [--until <date>] [--out <file>] [--title <text>] [--stall <min>] [--audit-dir <dir>]...
# The window defaults to the 24 hours before now; the page to docs/retro/digest/<until date>.md in this checkout.
# It writes that one file and prints its path. It commits nothing: the digest is committed once a night, by the session,
# when no pull request is open and no run is live (it says on stderr when that is not so yet).
# Optional sources, each noted in the page when missing: archon (the runs), the audit trail (via merge-ledger.sh),
# verify-fixes.js <run> (R18: exit 1 = a fix failed, 3 = no valid canary) and run-log.js <run> (R18: the true clock)
# in RETRO_DIGEST_TOOLS (default: this script's folder).
# When the digest names an incident it pings the owner through notify-owner.sh (D9); a missing or failing notifier is
# logged as "ping not delivered" and never fails the digest.
# Exit codes: 0 written; 1 merge-ledger.sh or git failed (nothing written); 2 usage.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tools="${RETRO_DIGEST_TOOLS:-$here}"
usage() {
  echo "retro-digest: $*" >&2
  echo "usage: retro-digest.sh [--since <date>] [--until <date>] [--out <file>] [--title <text>] [--stall <min>] [--audit-dir <dir>]..." >&2
  exit 2
}
since="" until="" out="" title="" stall=20 ledger_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage "--since needs a date"; since=$2; shift 2 ;;
    --until) [ $# -ge 2 ] || usage "--until needs a date"; until=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage "--out needs a file"; out=$2; shift 2 ;;
    --title) [ $# -ge 2 ] || usage "--title needs a text"; title=$2; shift 2 ;;
    --stall) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "--stall needs minutes"; stall=$2; shift 2 ;;
    --audit-dir) [ $# -ge 2 ] || usage "--audit-dir needs a directory"; ledger_args+=(--audit-dir "$2"); shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:]+Z?)?$'
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[ -n "$until" ] || until=$now
[[ "$until" =~ $date_re ]] && until=$(iso "$until") || usage "--until <YYYY-MM-DD[THH:MM:SSZ]>"
[ -n "$since" ] || since=$(iso "$until - 24 hours")
[[ "$since" =~ $date_re ]] && since=$(iso "$since") || usage "--since <YYYY-MM-DD[THH:MM:SSZ]>"
[[ "$since" < "$until" ]] || usage "--since must be before --until"

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "retro-digest: not in a git checkout" >&2; exit 1; }
[ -n "$out" ] || out="$top/docs/retro/digest/${until%%T*}.md"
[ -n "$title" ] || title="Retro digest ${since%%T*} to ${until%%T*}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# What reached main (fetches origin first unless MERGE_LEDGER_NO_FETCH=1).
bash "$here/merge-ledger.sh" --since "$since" --until "$until" --json "${ledger_args[@]}" > "$tmp/ledger.json" 2> "$tmp/ledger.err" \
  || { echo "retro-digest: merge-ledger.sh failed: $(head -c 300 "$tmp/ledger.err")" >&2; exit 1; }
missing=()
grep -q "archon unavailable" "$tmp/ledger.err" && missing+=("archon: build-feature runs were not consulted, so no merge or push is attributed to a run")

# The build-feature runs that overlap the window, with the retro section each has on origin/main.
echo '[]' > "$tmp/runs.json"
if command -v archon >/dev/null 2>&1 && archon workflow runs --json --limit 1000 > "$tmp/runs.raw" 2>/dev/null; then
  jq --arg s "$since" --arg u "$until" '[.runs[]? | select(.workflow_name == "build-feature")
      | {id, status, request: (.user_message // "" | split("\n")[0] | .[0:80]), started: ((.started_at // "") | sub("\\.[0-9]+Z$"; "Z")),
         completed: ((.completed_at // "") | sub("\\.[0-9]+Z$"; "Z")), last: ((.last_activity_at // "") | sub("\\.[0-9]+Z$"; "Z"))}
      | select(.started != "" and .started < $u and (.completed == "" or .completed >= $s))] | sort_by(.started)' \
    "$tmp/runs.raw" > "$tmp/runs.json" 2>/dev/null || echo '[]' > "$tmp/runs.json"
else
  missing+=("archon: the runs in the window could not be listed")
fi
: > "$tmp/sections.txt"
git -C "$top" grep -h -o '^## Run [0-9a-f]\{8\}' origin/main -- 'docs/retro/*/lessons-learned.md' 2>/dev/null \
  | sed 's/.*## Run //' > "$tmp/sections.txt"
jq -R -s 'split("\n") | map(select(length > 0))' "$tmp/sections.txt" > "$tmp/sections.json"

# Fix verdicts per run (R18), when the tool exists: verify-fixes.js prints one {fix, verdict, evidence} line per fix and
# exits 0 no fail, 1 a fix failed, 3 the run's capture lacks a fix (no valid canary), 2 unreadable.
echo '{}' > "$tmp/verdicts.json"
if [ -f "$tools/verify-fixes.js" ]; then
  for id in $(jq -r '.[].id' "$tmp/runs.json"); do
    node "$tools/verify-fixes.js" "$id" > "$tmp/vf.out" 2>/dev/null; rc=$?
    fails=$(jq -R -c 'fromjson? | select(.verdict == "fail") | .fix' "$tmp/vf.out" 2>/dev/null | jq -s -c 'map(tostring)' 2>/dev/null) || fails='[]'
    jq --arg id "$id" --argjson rc "$rc" --argjson f "${fails:-[]}" '. + {($id): {rc: $rc, fails: $f}}' "$tmp/verdicts.json" > "$tmp/v.json" \
      && mv "$tmp/v.json" "$tmp/verdicts.json"
  done
else
  missing+=("verify-fixes.js: no fix verdicts (R18 not landed)")
fi

# The true clock per run (R18): run-log.js reads the event log, since archon resets started_at on every resume. Exit 1:
# the run has no log (runs before 2026-10-18 16:09); its duration then stays archon's.
echo '{}' > "$tmp/clocks.json"
if [ -f "$tools/run-log.js" ]; then
  nolog=0
  for id in $(jq -r '.[].id' "$tmp/runs.json"); do
    if node "$tools/run-log.js" "$id" > "$tmp/rl.out" 2>/dev/null \
      && jq -e '.true_min != null' "$tmp/rl.out" >/dev/null 2>&1; then
      jq --arg id "$id" --slurpfile c "$tmp/rl.out" '. + {($id): {min: $c[0].true_min, resumes: ($c[0].resumes // 0)}}' \
        "$tmp/clocks.json" > "$tmp/c.json" && mv "$tmp/c.json" "$tmp/clocks.json"
    else
      nolog=$((nolog + 1))
    fi
  done
  [ "$nolog" -gt 0 ] && missing+=("run-log.js: no event log for $nolog runs; their duration is archon's, short after a resume")
else
  missing+=("run-log.js: no true clock; durations are archon's, short after a resume")
fi

open_prs=$(gh pr list --state open --json number --jq length 2>/dev/null) || open_prs="?"
live_runs=$(jq '[.runs[]? | select(.status == "running" or .status == "paused" or .status == "pending")] | length' "$tmp/runs.raw" 2>/dev/null) || live_runs="?"
printf '%s\n' "${missing[@]}" | jq -R -s 'split("\n") | map(select(length > 0))' > "$tmp/missing.json"

mkdir -p "$(dirname "$out")"
jq -r -n --slurpfile l "$tmp/ledger.json" --slurpfile r "$tmp/runs.json" --slurpfile sec "$tmp/sections.json" \
  --slurpfile v "$tmp/verdicts.json" --slurpfile ck "$tmp/clocks.json" --slurpfile miss "$tmp/missing.json" --arg title "$title" --arg since "$since" \
  --arg until "$until" --arg now "$now" --argjson stall $((stall * 60)) --arg prs "$open_prs" --arg live "$live_runs" '
  def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
  def t: if . == "" then null else fromdateiso8601 end;
  def mins: if . == null then "-" else ((. / 60) | floor | tostring) + " min" end;
  def tid: (capture("(?<t>TASK-[0-9]+(\\.[0-9]+)?)") | .t) // "-";
  def vcell: if . == null then "-" elif .rc == 0 then "pass" elif .rc == 1 then "fail \(.fails | join(","))"
    elif .rc == 3 then "no valid canary" else "unreadable (exit \(.rc))" end;
  ($l[0]) as $rows | ($r[0]) as $runs | ($v[0]) as $ver | ($ck[0]) as $clk
  | ($rows | map(select(.kind == "merge"))) as $merges | ($rows | map(select(.kind == "push"))) as $pushes
  | ($runs | map(.id[0:8] as $i | . + {id8: $i, ticket: (.request | tid),
        gap: (if .completed != "" and .last != "" then ((.completed | t) - (.last | t))
              elif .completed == "" and .last != "" then (($now | t) - (.last | t)) else null end),
        dur: (if $clk[.id] != null then $clk[.id].min * 60 elif .completed != "" then ((.completed | t) - (.started | t)) else null end),
        clock: (if $clk[.id] != null then "true clock\(if $clk[.id].resumes > 0 then ", \($clk[.id].resumes) resumes" else "" end)" else "archon" end),
        verdict: ($ver[.id] // null), retro: ($sec[0] | index($i) != null)})) as $runs
  | [ $runs[] | select(.status == "failed") | {run: .id8, ticket, why: "the run failed", retro} ]
    + [ $runs[] | select(.gap != null and .gap >= $stall) | {run: .id8, ticket, why: "stalled \(.gap | mins) before its end", retro} ]
    + [ $runs[] | select(.verdict != null and .verdict.rc == 1) | {run: .id8, ticket, why: "fix \(.verdict.fails | join(", ")) failed (verify-fixes.js)", retro} ]
    | group_by(.run) | map(.[0] + {why: (map(.why) | join("; "))}) | sort_by(.run as $i | $runs | map(.id8) | index($i))
    | . as $incidents
  | [ $rows[] | select(.who == "unattributed") | {ref, why: "unattributed \(.kind)", title} ]
    + [ $merges[] | select(.stop != "-") | {ref, why: "STOP items named: \(.stop)", title} ]
    + [ $runs[] | select(.status == "cancelled" and (.retro | not)) | {ref: .id8, why: "cancelled run with no stopped section (retro-stopped.sh)", title: .request} ]
    | . as $review
  | "# \($title)\n",
    "Generated by `.archon/scripts/retro-digest.sh` at \($now) for \($since) to \($until) (owner decision D16, 2026-10-20).",
    "Committed once, by the session, with no pull request open and no run live; this page changes nothing else.\n",
    "## Summary\n",
    "- \($merges | length) merges (\($merges | map(select(.who == "unattributed")) | length) unattributed), \($pushes | length) direct pushes to main (\($pushes | map(select(.who == "unattributed")) | length) unattributed).",
    "- \($runs | length) build-feature runs: \($runs | group_by(.status) | map("\(length) \(.[0].status)") | join(", ") | if . == "" then "none" else . end).",
    "- \($incidents | length) incidents that need a full retro; \($review | length) changes to review after the fact.",
    "- At generation: \($prs) open pull requests, \($live) live runs.\n",
    "## Incidents (a full retro each)\n",
    (if ($incidents | length) == 0 then "None.\n" else
      ("| Run | Ticket | Why | Retro section |", "|---|---|---|---|",
       ($incidents[] | "| \(.run) | \(.ticket) | \(.why | cell) | \(if .retro then "yes" else "missing" end) |"), "") end),
    "## Review after the fact\n",
    (if ($review | length) == 0 then "None.\n" else
      ("| Change | Why | Title |", "|---|---|---|", ($review[] | "| \(.ref) | \(.why | cell) | \(.title | cell) |"), "") end),
    "## Merges\n",
    (if ($merges | length) == 0 then "None.\n" else
      ("| PR | Merge commit | At | Who | Rule | STOP items | Retro |", "|---|---|---|---|---|---|---|",
       ($merges[] | "| \(.ref) | \(.sha) | \(.at) | \(.who | cell) | \(.rule | cell) | \(.stop | cell) | \(.retro) |"), "") end),
    "## Direct pushes to main\n",
    (if ($pushes | length) == 0 then "None.\n" else
      ("| Commit | At | Who | Rule | Subject |", "|---|---|---|---|---|",
       ($pushes[] | "| \(.sha) | \(.at) | \(.who | cell) | \(.rule | cell) | \(.title | cell) |"), "") end),
    "## Runs\n",
    (if ($runs | length) == 0 then "None.\n" else
      ("| Run | Ticket | Status | Started | Duration | Clock | Idle before end | Fix verdicts |", "|---|---|---|---|---|---|---|---|",
       ($runs[] | "| \(.id8) | \(.ticket) | \(.status) | \(.started) | \(.dur | mins) | \(.clock) | \(.gap | mins) | \(.verdict | vcell) |"),
       "", "Clock archon: archon resets a run'"'"'s start on resume, so a resumed run'"'"'s duration reads short (R18).", "") end),
    (if ($miss[0] | length) == 0 then empty else ("## Evidence missing\n", ($miss[0][] | "- \(.)"), "") end)
  ' > "$tmp/digest.md" 2> "$tmp/jq.err" || { echo "retro-digest: could not write the page: $(head -c 300 "$tmp/jq.err")" >&2; exit 1; }
mv "$tmp/digest.md" "$out"
echo "$out"

incidents=$(grep -c '^| [0-9a-f]\{8\} |' <(sed -n '/^## Incidents/,/^## Review/p' "$out"))
if [ "$open_prs" != 0 ] || [ "$live_runs" != 0 ]; then
  echo "retro-digest: $open_prs open pull requests, $live_runs live runs: commit the digest once both are 0" >&2
fi
if [ "$incidents" -gt 0 ]; then
  notify="$top/.archon/scripts/notify-owner.sh"
  if [ ! -f "$notify" ] || ! bash "$notify" warn "retro-digest-${until%%T*}" "Retro digest: $incidents incidents need a full retro" >/dev/null 2>&1; then
    echo "retro-digest: ping not delivered ($incidents incidents)" >&2
  fi
fi
exit 0
