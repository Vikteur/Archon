#!/usr/bin/env bash
# Tests for build-feature's ready node: its own bash, read from .archon/workflows/build-feature.yaml, run in a
# throwaway repo whose .archon/scripts holds stubs of local-ci-run.sh, ci-by-sha.sh, rebase-main.sh, tdd-check.sh and
# pr-refresh.sh, with a stubbed gh on PATH.
# Usage: bash .archon/scripts/test/ready-node.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$here/../workflows/build-feature.yaml"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
node_bash=$(yq '.nodes[] | select(.id == "ready") | .bash' "$wf")

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" "$err" | sed 's/^/    /'; fi
}

# The stubs log their calls to $LOG. ci-by-sha.sh answers the next entry of CI_SEQ (";"-separated "<state>|<detail>",
# the last one repeats).
r="$root/repo"; mkdir -p "$r/.archon/scripts" "$root/bin" "$root/artifacts"
git -C "$r" init -q -b feat; git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$r" rev-parse HEAD > "$root/artifacts/tdd-checked.sha"
for s in local-ci-run rebase-main tdd-check pr-refresh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n' "$s" > "$r/.archon/scripts/$s.sh"
done
cat > "$r/.archon/scripts/ci-by-sha.sh" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$LOG.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$LOG.n"
IFS=';' read -ra seq <<< "$CI_SEQ"
[ "$n" -gt "${#seq[@]}" ] && n=${#seq[@]}
e=${seq[$((n-1))]}
echo "ci-by-sha" >> "$LOG"
node -e 'console.log(`{"state": ${JSON.stringify(process.argv[1])}, "sha": "abc", "detail": ${JSON.stringify(process.argv[2])}}`)' "${e%%|*}" "${e#*|}"
STUB
printf '#!/usr/bin/env bash\necho "gh $*" >> "$LOG"\n' > "$root/bin/gh"
chmod +x "$root/bin/gh"

ready() { # ready <CI_SEQ>: run the node's bash; sets out, err, rc, calls
  : > "$root/log"; rm -f "$root/log.n"
  local b=${node_bash//\$open-pr.output.pr/42}
  out=$(cd "$r" && PATH="$root/bin:$PATH" LOG="$root/log" CI_SEQ="$1" ARTIFACTS_DIR="$root/artifacts" BASE_BRANCH=main \
    bash -c "$b" 2> "$root/err"); rc=$?
  err=$(cat "$root/err"); calls=$(cat "$root/log")
}

# 1. Green: the gates run and the pull request turns ready.
ready "green|local CI: every job passed"
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 marked ready" $(grep -qx "gh pr ready 42" <<< "$calls"; echo $?)

# 2. Red: it stays a draft, exit 1 so a person sees it, and the message names the failing check.
ready "red|local CI: red local-ci/test=failure"
check "2 exit 1" $([ "$rc" -eq 1 ]; echo $?)
check "2 not marked ready" $(! grep -q "pr ready" <<< "$calls"; echo $?)
check "2 names the failing check" $(grep -q "CI is red (local CI: red local-ci/test=failure)" <<< "$err"; echo $?)

# 3. No verdict: the node fails and says why.
ready "none|local CI: no local-ci status on abc after 600s"
check "3 exit 1" $([ "$rc" -ne 0 ]; echo $?)
check "3 names why there is no verdict" $(grep -q "No CI verdict for this commit (local CI: no local-ci status on abc after 600s)" <<< "$err"; echo $?)
check "3 not marked ready" $(! grep -q "pr ready" <<< "$calls"; echo $?)

# 4. A conflict is rebased and CI asked again; green after that turns it ready.
ready "conflict|pull request #42 conflicts;green|local CI: every job passed"
check "4 rebased" $(grep -q "^rebase-main main" <<< "$calls"; echo $?)
check "4 marked ready after the rebase" $(grep -qx "gh pr ready 42" <<< "$calls"; echo $?)

# 5. A conflict that stays: a draft, exit 1.
ready "conflict|pull request #42 conflicts"
check "5 still conflicting: exit 1, not ready" $([ "$rc" -eq 1 ] && ! grep -q "pr ready" <<< "$calls" && grep -q "still conflicts" <<< "$err"; echo $?)

echo "ready-node tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
