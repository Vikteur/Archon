#!/usr/bin/env bash
# Tests for .archon/scripts/run-metrics.js against stubbed archon and gh CLIs: which runs a pull request is credited
# with, the PR outcome records, and the per-run spend records.
# Usage: bash .archon/scripts/test/run-metrics.test.sh   (exit 0 = all pass)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/run-metrics.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
# q <js expression over `d`, the printed document>: prints its value.
q() { echo "$out" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const d=JSON.parse(s);console.log(JSON.stringify(eval(process.argv[1])))})' "$1"; }

mkdir -p "$root/bin" "$root/get"
cat > "$root/bin/archon" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "workflow runs") cat "$STUB_RUNS" ;;
  "workflow get") f="$STUB_GET/$3.json"; [ -f "$f" ] && cat "$f" || echo '{"nodes":[]}' ;;
  *) exit 1 ;;
esac
STUB
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_GH_FAIL:-}" ] && { echo "gh: not logged in" >&2; exit 1; }
cat "$STUB_PRS"
STUB
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" STUB_RUNS="$root/runs.json" STUB_GET="$root/get" STUB_PRS="$root/prs.json"
# The build workflow is the kit's default (build-feature-copilot) unless a case configures one: no project kit.yaml and
# no BUILD_WORKFLOW from the caller's environment.
unset BUILD_WORKFLOW
export KIT_CONFIG="$root/no-kit.yaml"

run() { # run <id> <workflow> <message> <started> [cost]
  local cost=${5:-}
  printf '{"id":"%s","workflow_name":"%s","user_message":"%s","started_at":"%s","metadata":{%s}}' \
    "$1" "$2" "$3" "$4" "${cost:+\"total_cost_usd\":$cost}"
}
opened() { # opened <run id> <pr number>: the run's open-pr node returned that pull request
  printf '{"nodes":[{"nodeId":"open-pr","state":"completed","outputPreview":"{\\"pr\\":\\"https://github.com/o/r/pull/%s\\",\\"sha\\":\\"abc\\"}"}]}' \
    "$2" > "$root/get/$1.json"
}
R=https://github.com/o/r/pull
a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb c=cccccccccccccccccccccccccccccccc
d=dddddddddddddddddddddddddddddddd e=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee f=ffffffffffffffffffffffffffffffff
cat > "$root/runs.json" <<EOF
{"total":6,"runs":[
 $(run $a build-feature-copilot "Build TASK-7" 2026-10-01T10:00:00.000Z 2.5),
 $(run $b build-feature-copilot "Build TASK-7" 2026-10-01T12:00:00.000Z 4),
 $(run $c build-feature-copilot "Build TASK-8" 2026-10-02T10:00:00.000Z 1),
 $(run $d archon-comprehensive-pr-review "Review PR #2 of o/r" 2026-10-03T10:00:00.000Z 0.5),
 $(run $e build-feature-copilot "Build TASK-9" 2026-10-04T10:00:00.000Z),
 $(run $f run-metrics "" 2026-10-05T10:00:00.000Z)
]}
EOF
opened $b 2; opened $c 3
cat > "$root/prs.json" <<EOF
[{"url":"$R/2","state":"MERGED","createdAt":"2026-10-01T13:00:00Z","mergedAt":"2026-10-01T15:00:00Z","closedAt":"2026-10-01T15:00:00Z"},
 {"url":"$R/3","state":"CLOSED","createdAt":"2026-10-02T11:00:00Z","mergedAt":null,"closedAt":"2026-10-02T12:00:00Z"}]
EOF

out="$(node "$script" 2>&1 >"$root/out.json")"; status=$?
check "exits 0 on a full listing" $status
out="$(cat "$root/out.json")"

# A failed earlier run of the same ticket, and a review naming the PR, are credited to it; newest last.
[ "$(q 'd.metrics.find(m=>m.name==="sdlc.prs_merged"&&m.subject.endsWith("/2")).runs')" = "[\"$a\",\"$b\",\"$d\"]" ]
check "PR 2 carries its ticket's earlier run and its review run" $?
[ "$(q 'd.metrics.filter(m=>m.subject.endsWith("/2")).map(m=>m.name+"="+m.value).join()')" = \
  '"sdlc.prs_opened=1,sdlc.prs_merged=1,sdlc.prs_abandoned=0,sdlc.pr_merge_rate=1"' ]
check "a merged PR records opened, merged, not abandoned and a merge rate of 1" $?
[ "$(q 'd.metrics.filter(m=>m.subject.endsWith("/3")).map(m=>m.name+"="+m.value+"@"+m.at).join()')" = \
  '"sdlc.prs_opened=1@2026-10-02T11:00:00Z,sdlc.prs_abandoned=1@2026-10-02T12:00:00Z,sdlc.pr_merge_rate=0@2026-10-02T12:00:00Z"' ]
check "a PR closed unmerged is abandoned at its close" $?

# Every run but this workflow's own counts once, with its recorded cost, 0 when it recorded none.
[ "$(q 'd.metrics.filter(m=>m.name==="runs.started").length')" = 5 ]
check "runs.started counts every run except run-metrics runs" $?
[ "$(q 'd.metrics.filter(m=>m.name==="runs.spend_usd").reduce((s,m)=>s+m.value,0)')" = 8 ]
check "runs.spend_usd sums the recorded costs" $?
[ "$(q 'd.metrics.find(m=>m.name==="runs.spend_usd"&&m.subject==="'$e'")')" = \
  "{\"kind\":\"count\",\"subject\":\"$e\",\"at\":\"2026-10-04T10:00:00.000Z\",\"runs\":[\"$e\"],\"name\":\"runs.spend_usd\",\"unit\":\"usd\",\"value\":0}" ]
check "a run without a recorded cost spends 0, at its start, as its own producing run" $?

# A PR gh does not list is skipped, not counted.
echo '[]' > "$root/prs.json"
out="$(node "$script" 2>/dev/null)"
[ "$(q 'd.skipped.length+":"+d.metrics.filter(m=>m.name.startsWith("sdlc.")).length')" = '"2:0"' ]
check "a PR gh does not list is reported in skipped" $?

# An incomplete run listing, or a failing gh, fails rather than undercounting.
sed -i 's/"total":6/"total":7/' "$root/runs.json"
out="$(node "$script" 2>&1)"; [ $? -eq 1 ] && echo "$out" | grep -q "listed 6 of 7 runs"
check "an incomplete run listing exits 1" $?
sed -i 's/"total":7/"total":6/' "$root/runs.json"
out="$(STUB_GH_FAIL=1 node "$script" 2>&1)"; [ $? -eq 1 ] && echo "$out" | grep -q "gh pr list"
check "a failing gh exits 1 and names the command" $?

# The build runs are the ones of the configured build_workflow: a run of that workflow is credited with the PR it
# opened, a run of any other workflow (the kit's default here) is not looked up, so its PR is credited to nobody.
g=11111111111111111111111111111111 h=22222222222222222222222222222222
printf 'build_workflow: my-build\n' > "$root/kit.yaml"
cat > "$root/runs.json" <<EOF
{"total":2,"runs":[
 $(run $g my-build "Build TASK-10" 2026-10-06T10:00:00.000Z 1),
 $(run $h build-feature-copilot "Build TASK-11" 2026-10-06T12:00:00.000Z 1)
]}
EOF
opened $g 4; opened $h 5
cat > "$root/prs.json" <<EOF
[{"url":"$R/4","state":"OPEN","createdAt":"2026-10-06T11:00:00Z","mergedAt":null,"closedAt":null},
 {"url":"$R/5","state":"OPEN","createdAt":"2026-10-06T13:00:00Z","mergedAt":null,"closedAt":null}]
EOF
out="$(KIT_CONFIG="$root/kit.yaml" node "$script" 2>/dev/null)"
[ "$(q 'd.metrics.find(m=>m.name==="sdlc.prs_opened"&&m.subject.endsWith("/4")).runs')" = "[\"$g\"]" ]
check "a run of the configured build_workflow is credited with the PR it opened" $?
[ "$(q 'd.metrics.filter(m=>m.subject.endsWith("/5")).length')" = 0 ]
check "a run of another workflow is not taken for a build run" $?

echo "run-metrics.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
