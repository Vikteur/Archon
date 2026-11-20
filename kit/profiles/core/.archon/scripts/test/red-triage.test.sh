#!/usr/bin/env bash
# Tests for .archon/scripts/red-triage.sh against a throwaway repo with a bare origin, a stubbed gh that serves commit
# statuses from files, a stubbed ci-local.sh, and job logs in a throwaway CI_LOCAL_ROOT.
# Usage: bash .archon/scripts/test/red-triage.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/red-triage.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# gh: `api …/commits/<sha>/statuses` reads $STATUS_DIR/<sha>, one status a line "<updated_at>|<id>|<context>|<state>|
# <description>", turns it into GitHub's JSON and applies the script's -q filter with jq.
mkdir -p "$root/bin" "$root/st"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
q=""; prev=""
for a in "$@"; do [ "$prev" = -q ] && q=$a; prev=$a; done
case "$*" in
  *"/statuses"*)
    ref=$(printf '%s' "$*" | sed -E 's#.*commits/([^/]+)/statuses.*#\1#')
    f="$STATUS_DIR/$ref"; [ -f "$f" ] || f=/dev/null
    jq -R -s 'split("\n") | map(select(length > 0) | split("|")
      | { updated_at: .[0], id: (.[1] | tonumber), context: .[2], state: .[3], description: .[4] })' "$f" | jq -r "$q"
    exit 0 ;;
esac
exit 1
STUB
# ci-local stub: logs its arguments and CI_LOCAL_RERUN_AFTER, then posts RERUN_POST ("<job>|<state>|<description>")
# on the commit, as a newer status.
cat > "$root/bin/ci-local.sh" <<'STUB'
#!/usr/bin/env bash
echo "ci-local $* after=${CI_LOCAL_RERUN_AFTER:-}" >> "$LOG"
sha=${!#}; sha=${sha#*:}
if [ -n "${RERUN_POST:-}" ]; then
  IFS='|' read -r job state desc <<< "$RERUN_POST"
  printf '2026-10-20T23:59:00Z|9%s|local-ci/%s|%s|%s\n' "$RANDOM" "$job" "$state" "$desc" >> "$STATUS_DIR/$sha"
fi
exit 1
STUB
chmod +x "$root/bin/"*

git init -q --bare -b main "$root/origin.git"
dir="$root/repo"
git clone -q "$root/origin.git" "$dir" 2>/dev/null
git -C "$dir" config user.name t; git -C "$dir" config user.email t@t
git -C "$dir" commit -q --allow-empty -m base; git -C "$dir" push -q origin main 2>/dev/null
tip=$(git -C "$dir" rev-parse HEAD)
git -C "$dir" switch -qc feat/x; git -C "$dir" commit -q --allow-empty -m feature
sha=$(git -C "$dir" rev-parse HEAD); short=${sha:0:7}
ci="$root/ci"

id=0
st() { # st <sha> <job> <state> <description>: one status on <sha>
  id=$((id+1)); printf '2026-10-20T10:%02d:00Z|%s|local-ci/%s|%s|%s\n' "$((id % 60))" "$id" "$2" "$3" "$4" >> "$root/st/$1"
}
green() { st "$1" "$2" success "success in 21s on host"; }
red() { st "$1" "$2" failure "failure in 30s on host"; }
joblog() { mkdir -p "$ci/$short"; printf '%s\n' "$2" > "$ci/$short/$1.log"; }
reset_all() { rm -rf "$root/st/"* "$ci"; mkdir -p "$ci"; }
run() { # run [env...] -- [args...]: the script in the repo; sets out, err, rc, log
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  : > "$root/log"
  out=$(cd "$dir" && env PATH="$root/bin:$PATH" STATUS_DIR="$root/st" LOG="$root/log" CI_LOCAL_ROOT="$ci" \
    CI_LOCAL="$root/bin/ci-local.sh" CI_LEDGER="$root/ledger.jsonl" RED_TRIAGE_REPO=o/r RED_TRIAGE_TODAY=2026-10-20 \
    RED_TRIAGE_FLAKY="$root/flaky.tsv" "${envs[@]}" bash "$script" "$@" 2> "$root/err"); rc=$?
  err=$(cat "$root/err"); log=$(cat "$root/log")
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; printf '%s\n%s\n%s\n' "$out" "$err" "$log" | sed 's/^/    /'; fi
}
field() { node -e 'console.log(JSON.parse(process.argv[1])[process.argv[2]])' "$out" "$1" 2>/dev/null; }
printf '# none\n' > "$root/flaky.tsv"

# 1. Every job green: class green, exit 0, no rerun.
reset_all; green "$sha" test; green "$sha" lint
run -- "$sha"
check "1 green, exit 0" $([ "$rc" -eq 0 ] && [ "$(field class)" = green ] && [ "$(field rerun)" = none ]; echo $?)
check "1 no rerun" $([ -z "$log" ]; echo $?)

# 2. A real test failure with no signature, green on main: own, exit 0, no rerun; the needs-follower gets no class.
reset_all; red "$sha" test; st "$sha" image failure "failure (not run: needed job test failed) on host"; green "$tip" test
joblog test "AssertionError: expected 3 but was 4"
run -- "$sha"
check "2 own, exit 0" $([ "$rc" -eq 0 ] && [ "$(field class)" = own ]; echo $?)
check "2 jobs named" $([[ "$(field jobs)" == *"test=own"* && "$(field jobs)" == *"image=follow"* ]]; echo $?)
check "2 no rerun" $([ -z "$log" ]; echo $?)

# 3. No log at all: unknown is own.
reset_all; red "$sha" test
run -- "$sha"
check "3 no log: own" $([ "$(field class)" = own ]; echo $?)

# 4. The same job red on main's tip: main-state.
reset_all; red "$sha" test; red "$tip" test; joblog test "AssertionError"
run -- "$sha"
check "4 main-state, exit 0" $([ "$rc" -eq 0 ] && [ "$(field class)" = main-state ]; echo $?)
check "4 names the tip" $([[ "$(field detail)" == *"${tip:0:7}"* ]]; echo $?)
# … but an infra red on main is not main-state.
reset_all; red "$sha" test; st "$tip" test failure "failure (infra: worktree) on host"; joblog test "AssertionError"
run -- "$sha"
check "4 main's infra red is not main-state" $([ "$(field class)" = own ]; echo $?)

# 5. A merge conflict: conflict, exit 0, never a rerun.
reset_all; st "$sha" test failure "failure (merge conflict with the base abc1234) on host"; st "$sha" lint failure "failure (merge conflict with the base abc1234) on host"
run -- "$sha"
check "5 conflict, exit 0" $([ "$rc" -eq 0 ] && [ "$(field class)" = conflict ] && [ -z "$log" ]; echo $?)

# 6. An infra signature in the log: one rerun of the red jobs only, on the same commit and pull request, green after it.
reset_all; green "$sha" lint; red "$sha" test; joblog test "Caused by: Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
run RERUN_POST="test|success|success in 40s on host; green on rerun after infra:docker-daemon" -- --pr https://github.com/o/r/pull/7 "$sha"
check "6 green after the rerun, exit 0" $([ "$rc" -eq 0 ] && [ "$(field class)" = green ]; echo $?)
check "6 rerun green-after the signature" $([ "$(field rerun)" = green-after:infra:docker-daemon ]; echo $?)
check "6 one ci-local call, --post --rerun-failed on pr:sha" $([ "$(grep -c ci-local <<< "$log")" -eq 1 ] && grep -qx "ci-local --post --rerun-failed 7:$sha after=infra:docker-daemon" <<< "$log"; echo $?)
check "6 marker written" $([ -s "$ci/$short.triage" ]; echo $?)
check "6 ledger has the triage" $(grep -q '"ev":"triage"' "$root/ledger.jsonl"; echo $?)
# 6b. A second triage of the same commit: the rerun is spent, exit 3, no second run.
reset_all; red "$sha" test; joblog test "Cannot connect to the Docker daemon"; printf 'x rerun\n' > "$ci/$short.triage"
run -- "$sha"
check "6b spent: exit 3, class infra, no ci-local" $([ "$rc" -eq 3 ] && [ "$(field class)" = infra ] && [ "$(field rerun)" = spent ] && [ -z "$log" ]; echo $?)

# 7. Infra and still red after the rerun: exit 3, class infra.
reset_all; red "$sha" test; joblog test "No space left on device"
run RERUN_POST="test|failure|failure in 5s on host" -- "$sha"
check "7 still infra: exit 3" $([ "$rc" -eq 3 ] && [ "$(field class)" = infra ] && [ "$(field rerun)" = red-after:infra:disk-full ]; echo $?)
check "7 ran on the bare sha" $(grep -qx "ci-local --post --rerun-failed $sha after=infra:disk-full" <<< "$log"; echo $?)

# 8. The runner itself could not run the job: infra from the status, without a log.
reset_all; st "$sha" archon-scripts failure "failure (infra: wsl-checkout) on host"
run RERUN_POST="archon-scripts|success|success in 9s on host" -- "$sha"
check "8 runner infra reruns, green" $([ "$(field class)" = green ] && [ "$(field rerun)" = green-after:infra:runner-wsl-checkout ]; echo $?)
check "8 warns when the status does not say green on rerun" $(grep -q "no status says 'green on rerun after" <<< "$err"; echo $?)

# 9. An infra job beside an own one: own, and no rerun.
reset_all; red "$sha" test; red "$sha" lint; joblog test "Address already in use"; joblog lint "3 lint problems"
run -- "$sha"
check "9 own beats infra; no rerun" $([ "$(field class)" = own ] && [ -z "$log" ]; echo $?)

# 10. Flaky: only a listed, unexpired signature for that job; green after the rerun.
printf '# list\nslow-clock\t2026-10-10\ttest\tClockTest > ticks FAILED\n' > "$root/flaky.tsv"
reset_all; red "$sha" test; joblog test "ClockTest > ticks FAILED"
run RERUN_POST="test|success|success in 40s on host" -- "$sha"
check "10 flaky reruns, green" $([ "$(field class)" = green ] && [ "$(field rerun)" = green-after:flaky:slow-clock ]; echo $?)
# 10b. Expired after 14 days: not flaky, own.
reset_all; red "$sha" test; joblog test "ClockTest > ticks FAILED"
run RED_TRIAGE_TODAY=2026-10-24 -- "$sha"
check "10b expired signature: own, no rerun" $([ "$(field class)" = own ] && [ -z "$log" ]; echo $?)
check "10b says it expired" $(grep -q 'expired on 2026-10-24' <<< "$err"; echo $?)
# 10c. Listed for another job: not flaky here.
reset_all; red "$sha" lint; mkdir -p "$ci/$short"; echo "ClockTest > ticks FAILED" > "$ci/$short/lint.log"
run -- "$sha"
check "10c other job's signature: own" $([ "$(field class)" = own ]; echo $?)
# 10d. Flaky still red after its rerun: own (the signature did not explain it), exit 0.
reset_all; red "$sha" test; joblog test "ClockTest > ticks FAILED"
run RERUN_POST="test|failure|failure in 41s on host" -- "$sha"
check "10d flaky still red: own, exit 0" $([ "$rc" -eq 0 ] && [ "$(field class)" = own ] && [ "$(field rerun)" = red-after:flaky:slow-clock ]; echo $?)
# 10e. Flaky with the rerun spent: own.
reset_all; red "$sha" test; joblog test "ClockTest > ticks FAILED"; printf 'x\n' > "$ci/$short.triage"
run -- "$sha"
check "10e flaky, rerun spent: own" $([ "$rc" -eq 0 ] && [ "$(field class)" = own ] && [ -z "$log" ]; echo $?)
printf '# none\n' > "$root/flaky.tsv"

# 11. --no-rerun: infra exits 3 with rerun off; nothing runs.
reset_all; red "$sha" test; joblog test "Could not resolve host: repo.maven.apache.org"
run -- --no-rerun "$sha"
check "11 --no-rerun: exit 3, off" $([ "$rc" -eq 3 ] && [ "$(field rerun)" = off ] && [ -z "$log" ]; echo $?)

# 12. Cannot triage: a job pending, no status at all. Exit 1.
reset_all; red "$sha" test; st "$sha" lint pending "running since 10:00, pid 1@host"
run -- "$sha"
check "12 pending: exit 1" $([ "$rc" -eq 1 ] && grep -q pending <<< "$err"; echo $?)
reset_all
run -- "$sha"
check "12 no status: exit 1" $([ "$rc" -eq 1 ] && grep -q 'no local-ci status' <<< "$err"; echo $?)

# 13. Only the newest status of a context counts: an older red under a newer green is green.
reset_all; red "$sha" test; green "$sha" test
run -- "$sha"
check "13 newest status wins" $([ "$(field class)" = green ]; echo $?)

# 14. --report writes the same line; usage errors exit 2.
reset_all; green "$sha" test
run -- --report "$root/report.json" "$sha"
check "14 report written" $([ "$(cat "$root/report.json")" = "$out" ]; echo $?)
run -- --bogus "$sha"
check "14 unknown option: exit 2" $([ "$rc" -eq 2 ]; echo $?)
run --
check "14 no sha: exit 2" $([ "$rc" -eq 2 ]; echo $?)

# 15. The shipped signature files parse: every infra line has an id and a regex grep accepts, every flaky line a date.
bad=$(awk -F'\t' '!/^#/ && NF > 0 && (NF != 2 || $1 == "" || $2 == "")' "$here/../red-triage/infra.tsv")
check "15 infra.tsv: <id><TAB><regex> per line" $([ -z "$bad" ]; echo $?)
while IFS=$'\t' read -r i re; do
  case "$i" in ''|'#'*) continue ;; esac
  echo x | grep -qE -- "$re"; [ $? -le 1 ] || { bad="$i"; }
done < "$here/../red-triage/infra.tsv"
check "15 infra.tsv regexes are valid" $([ -z "$bad" ]; echo $?)
bad=$(awk -F'\t' '!/^#/ && NF > 0 && (NF != 4 || $2 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)' "$here/../red-triage/flaky.tsv")
check "15 flaky.tsv: <id><TAB><date><TAB><job><TAB><regex> per line" $([ -z "$bad" ]; echo $?)
out=$(grep -v '^#' "$here/../red-triage/flaky.tsv" | grep -v '^[[:space:]]*$')
check "15 flaky.tsv ships with no signature: a flaky test is the project's own" $([ -z "$out" ]; echo $?)

echo "red-triage tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
