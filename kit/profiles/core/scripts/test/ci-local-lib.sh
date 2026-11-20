# Shared setup of the ci-local suites (ci-local.test.sh, ci-local-queue.test.sh, ci-local-watch.test.sh): a throwaway
# repo with its own ci.yml, a stubbed gh and java, and the helpers run, check and line. Sourced, never run as a suite
# (its name has no .test.sh, so the suite finders skip it). The caller has set `set -uo pipefail`.
# A local CI run that runs this suite passes its own run scope; the runner under test must not inherit it.
unset CI_LEDGER CI_REUSE CI_SCOPE CI_LOCAL_SLOTS CI_LOCAL_RUN CI_LOCAL_SLOT CI_LOCAL_XRUN
unset CI_LOCAL_LOOKUP_TRIES
export CI_LOCAL_LOOKUP_PAUSE=0
# Short waits for the watcher, the needs and the lock (each defaults to 1-2 s): about 100 runs here spent most of their
# time in those waits. A case that tests the lock wait sets its own CI_LOCAL_LOCK_POLL.
export CI_LOCAL_WATCH_POLL=0.1 CI_LOCAL_LOCK_POLL=0.1

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-local.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'git -C "$root/repo" worktree prune 2>/dev/null; rm -rf "$root"' EXIT

# gh records every call; `api -X POST` is the status post, kept per commit in st/ beside the log, which
# `api --paginate .../statuses` answers through its -q filter; `pr view` answers the base branch main.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
st=$(dirname "$GH_LOG")/st; mkdir -p "$st"
case "$1 $2" in
  "pr view") echo main ;;
  "api -X")
    # One post at a time: jobs post side by side, and a read while another post rewrote the counter restarted it at 1,
    # which put a job's success below its own pending of the same second (PR 195's run, section 19).
    exec 9>> "$st/.id.lock"; flock 9
    n=$(( $(cat "$st/.id" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$st/.id"
    jq -nc --arg s "${6#state=}" --arg c "${8#context=}" --arg d "${10#description=}" --argjson id "$n" \
      --arg t "$(date -u +%FT%TZ)" '{state: $s, context: $c, description: $d, id: $id, updated_at: $t}' >> "$st/${4##*/}" ;;
  "api --paginate")
    s=${3%/statuses*}; s=${s##*/}
    [ -s "$st/$s" ] && jq -s . "$st/$s" | jq -r "$5" ;;
esac
STUB
chmod +x "$root/bin/gh"
# A java on PATH of major 97, installed outside the folders the runner knows (setup-java's last resort).
cat > "$root/bin/java" <<'STUB'
#!/usr/bin/env bash
echo 'openjdk version "97.0.1" 2031-01-01' >&2
[ "$1" = -XshowSettings:properties ] && echo '    java.home = /opt/stub-jdk-97' >&2
exit 0
STUB
chmod +x "$root/bin/java"

git init -q --bare -b main "$root/origin.git"
git clone -q "$root/origin.git" "$root/repo" 2>/dev/null
git -C "$root/repo" config user.name t; git -C "$root/repo" config user.email t@t
mkdir -p "$root/repo/.github/workflows"
cat > "$root/repo/.github/workflows/ci.yml" <<'YML'
jobs:
  good:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - name: Contract token is read-only
        run: exit 1
      - uses: actions/cache@0000000000000000000000000000000000000000
      - name: Says hello
        env:
          BASE: ${{ github.event.pull_request.base.sha || 'origin/main' }}
        run: |
          echo "hello from $(basename "$PWD") base=$BASE ci=$CI"
          git config --global user.name ci-local-test
          git config --global user.name > global-name.txt
          env | grep -cE '^GIT_CONFIG_(COUNT|KEY_|VALUE_)' > git-env.txt || true
      - name: Every .archon test suite passes
        run: |
          echo archon-ran
          for t in .archon/scripts/test/*.test.sh; do bash "$t"; done
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: Fails
        id: f
        run: exit 3
      - name: After the failure
        run: echo never
      - name: Only on failure
        if: failure() && steps.f.outcome == 'failure'
        run: echo cleanup-ran
  odd:
    runs-on: ubuntu-latest
    steps:
      - uses: some/unknown-action@0000000000000000000000000000000000000000
  jdk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-java@0000000000000000000000000000000000000000
        with:
          java-version: '97'
      - name: Shows JAVA_HOME
        run: echo "jdk at $JAVA_HOME"
  nojdk:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-java@0000000000000000000000000000000000000000
        with:
          java-version: '98'
  oldimage:
    runs-on: ubuntu-latest
    steps:
      - uses: reproducible-containers/buildkit-cache-dance@0000000000000000000000000000000000000000
  secret:
    runs-on: ubuntu-latest
    steps:
      - name: Uses a secret
        run: echo ${{ secrets.NOPE }}
YML
echo base > "$root/repo/README.md"
# Two suites: a runs a.sh, b runs b.sh.
mkdir -p "$root/repo/.archon/scripts/test"
for n in a b; do
  echo "echo $n" > "$root/repo/.archon/scripts/$n.sh"
  echo "bash .archon/scripts/$n.sh; echo ran-$n" > "$root/repo/.archon/scripts/test/$n.test.sh"
done
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm base; git -C "$root/repo" push -q origin main 2>/dev/null
sha=$(git -C "$root/repo" rev-parse HEAD)
out_dir="$root/out/${sha:0:7}"
before=$(git config --global user.name 2>/dev/null || true)

run() { # run <args...>: ci-local inside the repo; sets out, rc
  : > "$root/gh.log"
  out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=.archon/githooks bash "$script" "$@") 2>&1 ); rc=$?
}
ledger="$root/out/ledger.jsonl"
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
line() { grep -E "^ +$1 +[0-9]+s +$2\$" "$out_dir/summary.txt" > /dev/null; }

# Helpers that sections of more than one suite use.
marks="$root/marks"; mkdir -p "$marks"
here_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
qs="$here_repo/.claude/scripts/ci-queue.sh"
bg() { # bg <name> <env...> -- <args...>: a run in the background; <name>.out and <name>.rc
  local name=$1; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ( cd "$root/repo" && env PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_LOCK_POLL=1 "${envs[@]}" \
      bash "$script" "$@" > "$root/$name.out" 2>&1; echo $? > "$root/$name.rc" ) &
}
waitfor() { local i; for i in $(seq 1 120); do eval "$1" && return 0; sleep 0.25; done; return 1; }
entries() { ls "$root/out/.queue" 2>/dev/null | grep -c '^[0-9]*$'; }
commit_quick_job() { # a one-job ci.yml and its commit on the repo (sections 10, 11 and 20); sets sha and out_dir
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  quick:
    runs-on: ubuntu-latest
    steps:
      - name: Quick
        run: sleep \${SLEEP:-0} && git rev-parse --short HEAD >> $marks/order
YML
git -C "$root/repo" commit -qam "quick job"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
}
setup_planner() { # the base's planner and its inputs, committed and pushed; sets p_base (section 13, section 19)
export CI_PLAN_RUNNER=runner-test CI_PLAN_SALT=salt-test
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  quick:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Quick
        run: git rev-parse --short HEAD >> $marks/order
YML
mkdir -p "$root/repo/.claude/scripts"
cp "$here_repo/.claude/scripts/ci-plan.sh" "$root/repo/.claude/scripts/ci-plan.sh"
cat > "$root/repo/.github/ci-inputs.yml" <<'YML'
version: 1
always: [.github/ci-inputs.yml, .github/workflows/ci.yml, .claude/scripts/ci-plan.sh]
jobs:
  quick:
    inputs: [.]
YML
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "planner"; git -C "$root/repo" push -q origin main 2>/dev/null
p_base=$(git -C "$root/repo" rev-parse HEAD)
}
