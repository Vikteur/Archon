#!/usr/bin/env bash
# The merge ledger (P2: a script, not a model; R22, owner decision D16 2026-10-20, docs/memory.md): every change that
# reached main since a date, and who put it there under which rule. It only reads; it is never committed per run.
#   merge-ledger.sh --since <date> [--until <date>] [--json] [--audit-dir <dir>]... [--window <min>] [--push-window <min>]
# Lists each merged pull request (gh pr list) and each direct push to main (a first-parent commit of origin/main that is
# no pull request's merge commit), oldest first. Each one is attributed from the record, first match wins:
#   1. an Archon build-feature run: its auto-merge gate answered {"state":"merged"} with this merge commit (the
#      self-merge of 2026-10-17 until TASK-58), or its close-out node answered {"backlog":"<sha>"} for this push;
#   2. a pull request comment with the marker  <!-- merge-ledger: by=<who>; rule=<rule> -->  (a merge script's own);
#   3. the audit trail (.apm-audit/sessions/*.jsonl): the nearest successful Bash call of auto-merge.sh <pr> (without
#      --no-merge), merge-ready.sh <pr> or `gh pr merge <pr>` within --window minutes (default 30) of mergedAt; for a
#      push, the nearest successful call of a pushing script (commit-tickets, close-out, retro-commit, stop-run,
#      commit-reports) or of a `git push` that can reach main (no other refspec, no --delete) up to --push-window
#      minutes (default 10) after the commit. A call counts only as a command segment of its own (split at && ; | ||), never as text
#      inside another command.
# Anything else is "unattributed": the script never guesses. A merge also shows the STOP items named in the pull
# request's `## Merge` section ("-" when it has none) and whether docs/retro/<TASK>/ exists on origin/main.
# Text output: one tab-separated row per change under a header, then a "# total" line. --json: one JSON array.
# Overrides: MERGE_LEDGER_NO_FETCH=1 (do not fetch origin first). gh, git and archon come from PATH; a missing or
# failing archon only drops source 1.
# Exit codes: 0 ok; 1 gh or git failed; 2 usage.
set -uo pipefail

usage() {
  echo "merge-ledger: $*" >&2
  echo "usage: merge-ledger.sh --since <date> [--until <date>] [--json] [--audit-dir <dir>]... [--window <min>] [--push-window <min>]" >&2
  exit 2
}
since="" until="" json=0 window=30 push_window=10 audit_dirs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage "--since needs a date"; since=$2; shift 2 ;;
    --until) [ $# -ge 2 ] || usage "--until needs a date"; until=$2; shift 2 ;;
    --json) json=1; shift ;;
    --audit-dir) [ $# -ge 2 ] || usage "--audit-dir needs a directory"; audit_dirs+=("$2"); shift 2 ;;
    --window) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "--window needs minutes"; window=$2; shift 2 ;;
    --push-window) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "--push-window needs minutes"; push_window=$2; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:]+Z?)?$'
[[ "$since" =~ $date_re ]] || usage "--since <YYYY-MM-DD[THH:MM:SSZ]> is required"
[ -z "$until" ] || [[ "$until" =~ $date_re ]] || usage "--until <YYYY-MM-DD[THH:MM:SSZ]>"

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "merge-ledger: not in a git checkout" >&2; exit 1; }
main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
[ ${#audit_dirs[@]} -gt 0 ] || audit_dirs=("$main/.apm-audit/sessions")
slug=$(git -C "$top" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
[ "${MERGE_LEDGER_NO_FETCH:-0}" = 1 ] || git -C "$top" fetch -q origin main 2>/dev/null \
  || echo "merge-ledger: fetch failed; using the local origin/main" >&2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
epoch() { date -u -d "$1" +%s 2>/dev/null; }
from=$(epoch "$since") || usage "--since: not a date: $since"
to=4102444800 # 2100-01-01
[ -z "$until" ] || to=$(epoch "$until") || usage "--until: not a date: $until"

# Merged pull requests.
search="merged:>=${since%%T*}"
gh pr list --state merged --search "$search" --limit 1000 \
  --json number,title,mergedAt,headRefName,body,mergeCommit,comments > "$tmp/prs.json" 2> "$tmp/gh.err" \
  || { echo "merge-ledger: gh pr list failed: $(head -c 300 "$tmp/gh.err")" >&2; exit 1; }

# First-parent commits of origin/main in the window (merge commits included: a pushed local merge is a push too).
git -C "$top" log --first-parent --since="$(date -u -d "@$from" +%Y-%m-%dT%H:%M:%SZ)" --format='%H%x09%ct%x09%s' origin/main > "$tmp/log.tsv" 2> "$tmp/git.err" \
  || { echo "merge-ledger: git log origin/main failed: $(head -c 300 "$tmp/git.err")" >&2; exit 1; }
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {sha: .[0], t: (.[1] | tonumber), subject: (.[2:] | join("\t"))})' \
  "$tmp/log.tsv" > "$tmp/log.json"

# The ticket folders that have a retro on origin/main.
git -C "$top" ls-tree -d --name-only origin/main docs/retro/ 2>/dev/null | sed 's#^docs/retro/##' \
  | jq -R -s 'split("\n") | map(select(length > 0))' > "$tmp/retros.json"

# Archon runs (source 1): the gate and close-out answers of each build-feature run.
echo '[]' > "$tmp/runs.json"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit-config.sh"
build_wf="$(kit_get build_workflow build-feature BUILD_WORKFLOW)"
if command -v archon >/dev/null 2>&1 && archon workflow runs --json --verbose --limit 1000 > "$tmp/runs.raw" 2>/dev/null; then
  jq --arg wf "$build_wf" '[.runs[]? | select(.workflow_name == "build-feature" or .workflow_name == $wf) | {id, nodes: [.nodes[]? | select(.nodeId == "auto-merge.gate"
      or .nodeId == "close-out") | {node: .nodeId, out: (.outputPreview // "")}]}]' "$tmp/runs.raw" > "$tmp/runs.json" 2>/dev/null \
    || echo '[]' > "$tmp/runs.json"
else
  echo "merge-ledger: archon unavailable; build-feature runs not consulted" >&2
fi

# The audit trail (source 3): successful Bash calls that could merge or push, as {t, session, agent, arg}.
cmds='auto-merge\.sh|merge-ready\.sh|gh pr merge|git push|commit-tickets\.sh|close-out\.sh|retro-commit\.sh|stop-run\.sh|commit-reports\.sh'
: > "$tmp/audit.jsonl"
for d in "${audit_dirs[@]}"; do
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] || continue
    jq -c --arg re "$cmds" 'select(.type == "TOOL" and .tool == "Bash" and .ok == true and (.loggedAt // "") != "" and ((.arg // "") | test($re)))
      | {t: (.loggedAt | fromdateiso8601), session: (.session // "" | .[0:8]), agent: (.agent // "?"), arg}' "$f" \
      >> "$tmp/audit.jsonl" 2>/dev/null
  done
done
jq -s '.' "$tmp/audit.jsonl" > "$tmp/audit.json"

jq -n --slurpfile prs "$tmp/prs.json" --slurpfile log "$tmp/log.json" --slurpfile runs "$tmp/runs.json" \
  --slurpfile audit "$tmp/audit.json" --slurpfile retros "$tmp/retros.json" --arg slug "$slug" \
  --argjson from "$from" --argjson to "$to" --argjson win $((window * 60)) --argjson pwin $((push_window * 60)) '
  def segments: gsub("\\s+"; " ") | [splits(" *(&&|\\|\\||;|\\|) *")] | map(sub("^ +"; "") | sub("^cd [^ ]+ *"; ""));
  def prnum: if test("/pull/[0-9]+$") then (capture("github\\.com/(?<s>[^/]+/[^/]+)/pull/(?<n>[0-9]+)$")
                | if .s == $slug then (.n | tonumber) else null end)
             elif test("^[0-9]+$") then tonumber else null end;
  # the pull request a merge call names, and the script it used
  def merge_call: [segments[]
      | (capture("^(bash )?(\\./)?([^ ]*/)?(?<cmd>auto-merge|merge-ready)\\.sh (?<rest>.*)$")
          | select(.rest | test("--no-merge") | not) | {cmd: (.cmd + ".sh"), n: (.rest | split(" ") | map(select(startswith("-") | not))[0] // "" | prnum)}),
        (capture("^gh pr merge (?<rest>.*)$")
          | select(((.rest | test("--repo ")) | not) or (.rest | test("--repo " + $slug + "( |$)")))
          | {cmd: "gh pr merge", n: (.rest | split(" ")[0] | prnum)})
    ] | map(select(.n != null)) | first;
  # a git push that can reach main: no --delete, no quoted text, and every refspec (if any) names main
  # ("HEAD:" with nothing after it is a refspec the audit trail cut off at the end of a line)
  def main_push: sub(" *[0-9]?>&?[0-9]+$"; "") | split(" ")[2:] as $a
    | ($a | map(select(test("^-") | not))) as $p
    | (($a | index("--delete")) == null) and ($a | all(test("[\"\\u0027\\\\]") | not))
      and ($p[1:] | all(test("^\\+?((HEAD|main):)?(refs/heads/)?main$|^HEAD:$")));
  def push_call: [segments[]
      | (capture("^(bash )?(\\./)?([^ ]*/)?(?<cmd>commit-tickets\\.sh|close-out\\.sh|retro-commit\\.sh|stop-run\\.sh|commit-reports\\.sh)( |$)") | .cmd),
        (select(test("^git push( |$)") and main_push) | "git push")] | first;
  def rule_for($cmd; $agent):
    if $cmd == "auto-merge.sh" and $agent == "delegator" then "TASK-55: the delegator merges through auto-merge.sh"
    elif $cmd == "merge-ready.sh" then "D7: merge-ready.sh merges when no STOP item is unapproved"
    elif $cmd == "commit-tickets.sh" then "TASK-64: commit-tickets.sh pushes ticket files"
    elif $cmd == "close-out.sh" then "UD-21.c/g: close-out commits the ticket files"
    elif $cmd == "retro-commit.sh" or $cmd == "stop-run.sh" then "docs/retro: retro-commit.sh commits the retro"
    elif $cmd == "commit-reports.sh" then "docs map: commit-reports.sh commits the token reports"
    else "none recorded" end;
  def ticket: (capture("(?<t>TASK-[0-9]+(\\.[0-9]+)?)") | .t) // null;
  def stop_items: ((capture("(?s)(^|\\n)## Merge\\n(?<m>.*?)(\\n## |$)") | .m) // null) as $m
    | if $m == null then "-" else ($m | capture("(?s)STOP items[^:\\n]*:\\s*(?<s>.*)") | .s
        | sub("(?s)\\s*🤖 Generated.*$"; "") | gsub("\\s+"; " ") | sub("^- "; "")) // "-" end
    | if . == "" or test("^none\\b|^(the (ticket|pull request|change) touches )?no STOP item"; "i") then "-" else . end;
  def nearest($cands; $t): $cands | sort_by((.t - $t) | fabs) | first;
  ($prs[0] | map(.mergeCommit.oid // empty)) as $mcs
  | ($audit[0] | map(. + {m: (.arg | merge_call), p: (.arg | push_call)})) as $calls
  | [ $prs[0][] | (.mergedAt | fromdateiso8601) as $t | select($t >= $from and $t < $to)
      | . as $pr | ($pr.mergeCommit.oid // "") as $oid
      | ([$runs[0][] | . as $r | .nodes[] | select(.node == "auto-merge.gate" and $oid != ""
            and (.out | test("\"state\": *\"merged\", *\"sha\": *\"" + $oid))) | $r.id[0:8]] | first) as $run
      | ([$pr.comments[]? | .body | capture("<!-- merge-ledger: by=(?<by>[^;]+); rule=(?<rule>.*?) -->")] | last) as $mark
      | nearest([$calls[] | select(.m != null and .m.n == $pr.number and ((.t - $t) | fabs) <= $win)]; $t) as $call
      | ([$pr.title, $pr.headRefName, ($pr.body // "")] | map(ticket) | map(select(. != null)) | first) as $task
      | { kind: "merge", ref: ("#" + ($pr.number | tostring)), sha: $oid[0:8], at: $pr.mergedAt, t: $t,
          who: (if $run then "build-feature run \($run) (auto-merge gate)"
                elif $mark then $mark.by
                elif $call then "\($call.agent) session \($call.session) (\($call.m.cmd))"
                else "unattributed" end),
          rule: (if $run then "2026-10-17: build-feature merges by itself (ended by TASK-58)"
                 elif $mark then $mark.rule
                 elif $call then rule_for($call.m.cmd; $call.agent)
                 else "-" end),
          stop: (($pr.body // "") | stop_items),
          ticket: $task,
          retro: (if $task == null then "-" elif ($retros[0] | index($task)) then "yes" else "no" end),
          title: $pr.title } ]
  + [ $log[0][] | select(.t >= $from and .t < $to) | . as $c | select(($mcs | index($c.sha)) | not)
      | ([$runs[0][] | . as $r | .nodes[] | select(.node == "close-out")
            | (.out | capture("\"backlog\": *\"(?<s>[0-9a-f]{7,40})\"") | .s) as $s | select($c.sha | startswith($s))
            | $r.id[0:8]] | first) as $run
      | nearest([$calls[] | select(.p != null and (.t - $c.t) >= 0 and (.t - $c.t) <= $pwin)]; $c.t) as $call
      | { kind: "push", ref: $c.sha[0:8], sha: $c.sha[0:8], at: ($c.t | todateiso8601), t: $c.t,
          who: (if $run then "build-feature run \($run) (close-out)"
                elif $call then "\($call.agent) session \($call.session) (\($call.p))"
                else "unattributed" end),
          rule: (if $run then "UD-21.c/g: close-out commits the ticket files"
                 elif $call then rule_for($call.p; $call.agent) else "-" end),
          stop: "-", ticket: ($c.subject | ticket), retro: "-", title: $c.subject } ]
  | sort_by(.t) | map(del(.t))' > "$tmp/rows.json" 2> "$tmp/jq.err" \
  || { echo "merge-ledger: could not join the sources: $(head -c 300 "$tmp/jq.err")" >&2; exit 1; }

if [ "$json" = 1 ]; then cat "$tmp/rows.json"; exit 0; fi
printf 'kind\tref\tat\twho\trule\tstop\tretro\ttitle\n'
jq -r '.[] | [.kind, .ref, .at, .who, .rule, (if .stop == "-" then "-" else "named" end), .retro, .title] | @tsv' "$tmp/rows.json"
jq -r '"# total: \(map(select(.kind == "merge")) | length) merges (\(map(select(.kind == "merge" and .who == "unattributed")) | length) unattributed), \(map(select(.kind == "push")) | length) direct pushes (\(map(select(.kind == "push" and .who == "unattributed")) | length) unattributed)"' "$tmp/rows.json"
