#!/usr/bin/env bash
# Tests for .claude/scripts/ci-audit.sh (CI plan C14, D2): a reused status is checked against the ledger, a miss turns
# the kill switch on and reruns the commit in full, and main gets a full no-reuse run once a day. Throwaway origin and
# clone, a stubbed gh (statuses per commit) and a stubbed runner; the ledger is a file the test writes.
# Usage: bash scripts/test/ci-audit.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-audit.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$err" | sed 's/^/    /'; fi
}

# gh: `api ... repos/o/repo/commits/<sha>/statuses...` answers $root/st/<sha>.json through the -q filter (an empty list
# when missing); with $root/gh.fail present it fails. The runner logs "CI_SCOPE=<scope> <args>".
mkdir -p "$root/bin" "$root/st"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -e "$ROOT/gh.fail" ] && exit 1
q="" path=""
while [ $# -gt 0 ]; do case "$1" in -q) q=$2; shift ;; repos/*) path=$1 ;; esac; shift; done
sha=${path#repos/o/repo/commits/}; sha=${sha%%/*}
f="$ROOT/st/$sha.json"; [ -f "$f" ] || echo '[]' > "$f"
jq -r "$q" "$f"
STUB
cat > "$root/runner" <<'STUB'
echo "CI_SCOPE=${CI_SCOPE:-} $*" >> "$ROOT/runner.log"
STUB
chmod +x "$root/bin/gh"

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/w" 2>/dev/null
w="$root/w"; git -C "$w" config user.name t; git -C "$w" config user.email t@t
commit() { echo "$RANDOM$1" > "$w/f"; git -C "$w" add -A; git -C "$w" commit -qm "$1"; git -C "$w" push -q origin main; git -C "$w" rev-parse HEAD; }
SRC=$(commit source); DST=$(commit reuser)
FP=0123456789 NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# status <sha> <state> <description> [<epoch>]: adds a local-ci/test status to the commit's answer.
status() {
  local f="$root/st/$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq --arg s "$2" --arg d "$3" --arg at "$(iso "${4:-$NOW}")" --argjson id "$RANDOM" \
    '. + [{context: "local-ci/test", state: $s, description: $d, updated_at: $at, id: $id}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
verdict() { # verdict <sha> <state> <description> <epoch>: a ledger verdict line of job test
  jq -cn --arg sha "$1" --arg s "$2" --arg d "$3" --argjson t "$4" '{v:1, ev:"verdict", t:$t, sha:$sha, job:"test", state:$s, description:$d}' \
    >> "$root/ci/ledger.jsonl"
}
fresh() { rm -rf "$root/ci" "$root/st"/* "$root/runner.log" "$root/gh.fail"; mkdir -p "$root/ci"; : > "$root/ci/ledger.jsonl"; }
audit() { # audit <args...>: sets err, rc
  err=$(cd "$w" && PATH="$root/bin:$PATH" ROOT="$root" CI_LOCAL="$root/runner" CI_LOCAL_ROOT="$root/ci" CI_AUDIT_REPO=o/repo \
    CI_AUDIT_NOW="$NOW" bash "$script" "$@" 2>&1 >"$root/out"); rc=$?
}
ledger_has() { jq -e "$1" "$root/ci/ledger.jsonl" > /dev/null 2>&1; }
reused="reused from ${SRC:0:12}; fp=$FP; scope=abcdef0"

# 1. A reuse the ledger proves (a real success of the same job on the source, same fp, within 24 h): no miss.
fresh; verdict "$SRC" success "success in 30s on h; fp=$FP" $((NOW - 3600)); status "$DST" success "$reused"
audit check "$DST"
check "1 proved: exit 0" "$([ "$rc" -eq 0 ]; echo $?)"
check "1 no kill switch, no rerun" "$([ ! -e "$root/ci/scope-all" ] && [ ! -s "$root/runner.log" ]; echo $?)"
check "1 the audit is in the ledger" "$(ledger_has 'select(.ev == "audit" and .result == "ok" and .job == "test")'; echo $?)"

# 2..6. Each broken reuse is a miss: exit 1, the kill switch on with the reason, a full no-reuse rerun of the commit.
miss() { # miss <name> <expected reason fragment>
  audit check "$DST"
  check "$1 a miss: exit 1" "$([ "$rc" -eq 1 ]; echo $?)"
  check "$1 the reason ($2)" "$(echo "$err" | grep -q "$2" && grep -q "$2" "$root/ci/scope-all"; echo $?)"
  check "$1 rerun in full, no reuse" "$([ "$(cat "$root/runner.log")" = "CI_SCOPE=all --post --all $DST" ]; echo $?)"
  check "$1 the miss is in the ledger" "$(ledger_has 'select(.ev == "audit" and .result == "miss")'; echo $?)"
}
fresh; status "$DST" success "$reused"
miss 2 "no real run of test"
fresh; verdict "$SRC" success "success in 30s on h; fp=9999999999" $((NOW - 3600)); status "$DST" success "$reused"
miss 3 "fp=9999999999, the reuse fp=$FP"
fresh; verdict "$SRC" success "success in 30s on h; fp=$FP" $((NOW - 90000)); status "$DST" success "$reused"
miss 4 "over the 24 h limit"
fresh; verdict "$SRC" success "reused from aaaaaaaaaaaa; fp=$FP; scope=abcdef0" $((NOW - 3600)); status "$DST" success "$reused"
miss 5 "never chained"
fresh; verdict "$SRC" failure "failure in 30s on h; fp=$FP" $((NOW - 3600)); status "$DST" success "$reused"
miss 6 "is failure"
fresh; verdict "$SRC" success "success in 30s on h, 1 step(s) skipped locally" $((NOW - 3600)); status "$DST" success "$reused"
miss 6b "not a real run"
fresh; status "$DST" success "reused from nonsense"
miss 6c "does not parse"

# 7. An unreadable ledger cannot prove anything: a miss (fail closed).
fresh; rm "$root/ci/ledger.jsonl"; status "$DST" success "$reused"
audit check "$DST"
check "7 no ledger: a miss" "$([ "$rc" -eq 1 ] && grep -q "cannot be read" "$root/ci/scope-all"; echo $?)"

# 8. The kill switch is never removed or rewritten by the audit; real runs are not audited.
fresh; echo "set by the owner's test" > "$root/ci/scope-all"; status "$DST" success "$reused"
audit check "$DST"
check "8 an existing switch is kept as it was" "$([ "$(cat "$root/ci/scope-all")" = "set by the owner's test" ]; echo $?)"
fresh; status "$DST" success "success in 30s on h; fp=$FP"
audit check "$DST"
check "8 a real run is not audited" "$([ "$rc" -eq 0 ] && ! ledger_has 'select(.ev == "audit")'; echo $?)"

# 9. GitHub does not answer: exit 3, nothing decided, no switch.
fresh; touch "$root/gh.fail"
audit check "$DST"
check "9 cannot audit: exit 3, no switch" "$([ "$rc" -eq 3 ] && [ ! -e "$root/ci/scope-all" ]; echo $?)"

# 10. daily: the full run of main's tip with no reuse when there was none yet; the stamp and the ledger record it.
fresh; audit daily
check "10 daily: exit 0" "$([ "$rc" -eq 0 ]; echo $?)"
check "10 the full run of the tip, no reuse" "$([ "$(cat "$root/runner.log")" = "CI_SCOPE=all --post --all $DST" ]; echo $?)"
check "10 the stamp names the time and the tip" "$([ "$(cat "$root/ci/full-run.last")" = "$NOW $DST" ]; echo $?)"
check "10 the ledger has the full run" "$(ledger_has "select(.ev == \"full-run\" and .sha == \"$DST\")"; echo $?)"

# 11. Within 24 h of the last full run: nothing starts; over 24 h: it starts again.
rm -f "$root/runner.log"; echo "$((NOW - 3600)) $SRC" > "$root/ci/full-run.last"
audit daily
check "11 within 24 h nothing starts" "$([ "$rc" -eq 0 ] && [ ! -s "$root/runner.log" ]; echo $?)"
echo "$((NOW - 90000)) $SRC" > "$root/ci/full-run.last"
audit daily
check "11 over 24 h it starts" "$([ "$(cat "$root/runner.log")" = "CI_SCOPE=all --post --all $DST" ]; echo $?)"

# 12. daily audits main's recent commits: a miss on one turns the switch on and reruns it; the tip's full run is not
# started twice when the tip is the commit rerun.
fresh; status "$DST" success "$reused"
audit daily
check "12 daily finds the miss: exit 1" "$([ "$rc" -eq 1 ] && [ -e "$root/ci/scope-all" ]; echo $?)"
check "12 one full run of the tip" "$([ "$(grep -c "CI_SCOPE=all --post --all $DST" "$root/runner.log")" -eq 1 ]; echo $?)"

# 13. --no-wait starts the run in the background and returns; its log is under no-wait/.
fresh; audit daily --no-wait
for _ in $(seq 1 50); do [ -s "$root/runner.log" ] && break; sleep 0.1; done
check "13 --no-wait: exit 0, the run started" "$([ "$rc" -eq 0 ] && grep -q "CI_SCOPE=all --post --all $DST" "$root/runner.log" \
  && [ -f "$root/ci/no-wait/full-${DST:0:7}.log" ]; echo $?)"

# 14. last: the stamp and the switch, said plainly; usage.
audit last
check "14 last names the full run and the switch" "$(grep -q "last full run: .* on ${DST:0:7}" "$root/out" && grep -q "kill switch: off" "$root/out"; echo $?)"
audit bogus
check "14 usage exit 2" "$([ "$rc" -eq 2 ]; echo $?)"
audit check
check "14 check without a commit is usage" "$([ "$rc" -eq 2 ]; echo $?)"

# 15. Same tree (owner decision 2026-10-23): `reused from <head sha12>; same tree` on a merge commit is proved by a real
# green run of the job on the head, within 24 h, whose start line tested the merge commit's tree; any other tree, or no
# start line, is a miss.
git -C "$w" switch -qc same-head main; echo head > "$w/head"; git -C "$w" add -A; git -C "$w" commit -qm head
H=$(git -C "$w" rev-parse HEAD); git -C "$w" switch -q main
git -C "$w" merge -q --no-ff --no-edit same-head; git -C "$w" push -q origin main; M=$(git -C "$w" rev-parse HEAD)
start() { jq -cn --arg sha "$H" --arg tree "$1" '{v:1, ev:"start", t:1, sha:$sha, run:"h.r1", tree:$tree}' >> "$root/ci/ledger.jsonl"; }
hverdict() { jq -cn --arg sha "$H" --argjson t $((NOW - 3600)) '{v:1, ev:"verdict", t:$t, sha:$sha, run:"h.r1", job:"test", state:"success", description:"success in 30s on h; fp=0123456789"}' >> "$root/ci/ledger.jsonl"; }
same="reused from ${H:0:12}; same tree"
fresh; start "$(git -C "$w" rev-parse "$M^{tree}")"; hverdict; status "$M" success "$same"
audit check "$M"
check "15 same tree proved: exit 0, no switch, no rerun" "$([ "$rc" -eq 0 ] && [ ! -e "$root/ci/scope-all" ] && [ ! -s "$root/runner.log" ]; echo $?)"
fresh; start "$(git -C "$w" rev-parse "$SRC^{tree}")"; hverdict; status "$M" success "$same"
audit check "$M"
check "15 another tested tree: a miss, the switch on, a full rerun" "$([ "$rc" -eq 1 ] && echo "$err" | grep -q "tested the tree" \
  && grep -q "tested the tree" "$root/ci/scope-all" && [ "$(cat "$root/runner.log")" = "CI_SCOPE=all --post --all $M" ]; echo $?)"
fresh; hverdict; status "$M" success "$same"
audit check "$M"
check "15 no start line: a miss" "$([ "$rc" -eq 1 ] && echo "$err" | grep -q "tested the tree unknown"; echo $?)"
fresh; status "$M" success "$same"
audit check "$M"
check "15 no run of the head: a miss" "$([ "$rc" -eq 1 ] && echo "$err" | grep -q "no real run of test"; echo $?)"

echo "ci-audit tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
