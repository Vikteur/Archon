#!/usr/bin/env bash
# Tests for .claude/scripts/ci-local.sh against a throwaway repo, its own ci.yml and a stubbed gh.
# Usage: bash scripts/test/ci-local.test.sh   (exit 0 = all pass)
set -uo pipefail
# A local CI run that runs this suite passes its own run scope; the runner under test must not inherit it.
unset CI_LEDGER CI_REUSE CI_SCOPE CI_LOCAL_SLOTS CI_LOCAL_RUN CI_LOCAL_SLOT CI_IMAGE_TAG IMAGE_CHECK_NAME IMAGE_CHECK_PORT
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

# 1. A whole run: every job, its steps, a summary, the exit code of the worst job.
run --keep "$sha"
check "1 exit 1 when a job fails" $([ "$rc" -eq 1 ]; echo $?)
check "1 good passes" $(grep -qE '^good +success' "$out_dir/summary.txt"; echo $?)
check "1 runs the step in its own worktree" $(grep -q "hello from wt-good base=origin/main ci=true" "$out_dir/good.log"; echo $?)
check "1 the CI-token step is skipped locally, not passed" $(line skipped-locally "Contract token is read-only"; echo $?)
check "1 actions/cache is skipped locally" $(line skipped-locally "actions/cache@0000000000000000000000000000000000000000"; echo $?)
check "1 git config --global stays in the job" $([ "$(cat "$out_dir/wt-good/global-name.txt")" = ci-local-test ]; echo $?)
check "1 the Archon git env (GIT_CONFIG_COUNT/KEY/VALUE) does not reach the job" $([ "$(cat "$out_dir/wt-good/git-env.txt")" = 0 ]; echo $?)
check "1 the real global config is untouched" $([ "$(git config --global user.name 2>/dev/null || true)" = "$before" ]; echo $?)
check "1 bad fails" $(grep -qE '^bad +failure' "$out_dir/summary.txt"; echo $?)
check "1 a step after a failure is skipped" $(line skipped "After the failure"; echo $?)
check "1 if: failure() runs after a failure" $(line success "Only on failure" && grep -q cleanup-ran "$out_dir/bad.log"; echo $?)
check "1 an unknown action fails" $(grep -qE '^odd +failure' "$out_dir/summary.txt" && grep -q "action not reproduced locally" "$out_dir/odd.log"; echo $?)
check "1 an unknown expression fails" $(grep -qE '^secret +failure' "$out_dir/summary.txt" && grep -q "expression not reproduced locally" "$out_dir/secret.log"; echo $?)
check "1 the .archon suites run when the change cannot be computed" $(line success "Every .archon test suite passes" && grep -q archon-ran "$out_dir/good.log"; echo $?)
check "1 nothing posted without --post" $([ ! -s "$root/gh.log" ]; echo $?)
check "1 --keep keeps the worktrees" $([ -d "$out_dir/wt-good" ]; echo $?)

# 2. --jobs runs only those; without --keep the worktrees go.
run --jobs good "$sha"
check "2 exit 0 when the jobs pass" $([ "$rc" -eq 0 ]; echo $?)
check "2 only good ran" $(! grep -q '^bad' "$out_dir/summary.txt"; echo $?)
check "2 worktrees removed" $([ ! -e "$out_dir/wt-good" ] && ! git -C "$root/repo" worktree list | grep -q wt-good; echo $?)

# 3. --post: pending for every job first (queued, then running), then each job's result, as local-ci/<job> on the
# commit, in the grammar of ci-status-grammar.sh.
run --post "$sha"
check "3 posts on the commit" $(grep -q "^gh api -X POST repos/.*/statuses/$sha" "$root/gh.log"; echo $?)
check "3 queued, then running, for every job" $([ "$(grep -c 'state=pending -f context=local-ci/[a-z]* -f description=queued #[0-9]* pos 1 since [0-9:]*, pid [0-9]*@' "$root/gh.log")" -eq 4 ] \
  && [ "$(grep -c 'state=pending -f context=local-ci/[a-z]* -f description=running since [0-9:]*, pid [0-9]*@' "$root/gh.log")" -eq 4 ] \
  && grep -n 'context=local-ci/good' "$root/gh.log" | sed -n 1p | grep -q 'description=queued'; echo $?)
check "3 good success" $(grep -q 'state=success -f context=local-ci/good' "$root/gh.log"; echo $?)
check "3 bad failure" $(grep -q 'state=failure -f context=local-ci/bad' "$root/gh.log"; echo $?)
check "3 a skipped step is named in the status" $(grep 'context=local-ci/good' "$root/gh.log" | grep -qE 'state=success -f context=local-ci/good -f description=success in [0-9]+s on [^ ;]+; skipped-locally 2$'; echo $?)
check "3 a full .archon run is not called narrowed" $(! grep 'context=local-ci/good' "$root/gh.log" | grep -q narrowed; echo $?)
check "3 a ran failure follows the grammar" $(grep -qE 'state=failure -f context=local-ci/bad -f description=failure in [0-9]+s on [^ ;]+$' "$root/gh.log"; echo $?)

# 4. --post reports whole runs only.
run --post --jobs good "$sha"
check "4 --post with --jobs refused" $([ "$rc" -eq 2 ]; echo $?)
run --jobs nope "$sha"
check "4 an unknown job refused" $([ "$rc" -eq 2 ]; echo $?)

# 4b. A job lookup that reads nothing is logged with what both commands returned, and tried again (the case-5 flake of
# 2026-10-22): a yq that answers nothing the first time.
mkdir -p "$root/yqflaky"
cat > "$root/yqflaky/yq" <<STUB
#!/usr/bin/env bash
if [ ! -e "$root/yqflaky/missed" ]; then : > "$root/yqflaky/missed"; cat > /dev/null; echo "yq stub: once empty" >&2; exit 0; fi
exec $(command -v yq) "\$@"
STUB
chmod +x "$root/yqflaky/yq"
PATH="$root/yqflaky:$PATH" run --jobs good "$sha"
check "4b a lookup that read nothing is tried again" $([ "$rc" -eq 0 ] && grep -qE '^good +success' "$out_dir/summary.txt"; echo $?)
check "4b the miss is logged with both commands, their exit codes and output" $(grep -qE "^ci-local: job lookup 1 of 3 at ${sha:0:7} missed \(no job read\) good: .*show ${sha:0:7}:\.github/workflows/ci\.yml\` exit 0, [0-9]+ bytes; .*yq .*exit 0, jobs: , stderr: yq stub: once empty" <<< "$out" && ! grep -q 'lookup 2 of 3' <<< "$out"; echo $?)
run --jobs nope "$sha"
check "4b a job that is not there is looked up 3 times, then refused" $([ "$rc" -eq 2 ] && [ "$(grep -c '^ci-local: job lookup [123] of 3 .* missed nope' <<< "$out")" -eq 3 ] && grep -q 'no job nope in ci.yml' <<< "$out"; echo $?)

# 5. The .archon suites run only for a change under the paths they read, and only the suites it touches; --all forces
# every one.
echo changed > "$root/repo/README.md"; git -C "$root/repo" commit -qam "docs only"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
run --jobs good "$sha"
check "5 a change elsewhere skips them" $(grep -qE '^ +SKIPPED +[0-9]+s +Every \.archon test suite passes -- the change [0-9a-f]{7}\.\.[0-9a-f]{7} touches none of \.archon/' "$out_dir/summary.txt" && ! grep -q archon-ran "$out_dir/good.log"; echo $?)
check "5 a skipped step does not fail the job" $([ "$rc" -eq 0 ]; echo $?)
check "5 the skip is recorded as narrowed and as affected in the ledger" $(tail -n 20 "$ledger" | jq -se --arg s "${sha:0:7}" \
  'any(.[]; .ev == "affected" and .scope == "archon-suites" and (.skip | test("touches none"))) and
   any(.[]; .ev == "end" and (.run | startswith($s)) and .jobs.good.narrowed == true)' > /dev/null; echo $?)
run --post "$sha"
check "5 a narrowed run posts narrowed: archon-suites, not a plain pass" $(grep -qE 'state=success -f context=local-ci/good -f description=success in [0-9]+s on [^ ;]+; narrowed: archon-suites; skipped-locally 2$' "$root/gh.log"; echo $?)
run --all --jobs good "$sha"
check "5 --all runs them" $(line success "Every .archon test suite passes" && grep -q archon-ran "$out_dir/good.log"; echo $?)
echo x >> "$root/repo/.archon/scripts/a.sh"; git -C "$root/repo" commit -qam "archon change"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
run --jobs good "$sha"
check "5 a change under .archon/ runs the suites it touches" $(line success "Every .archon test suite passes -- 1 of 2 suites, for the change [0-9a-f]{7}\.\.[0-9a-f]{7}: a " && grep -q ran-a "$out_dir/good.log"; echo $?)
check "5 a subset of the suites is narrowed too" $(read -r _ _ _ _ _ nw < "$out_dir/good.result"; [ "$nw" = 1 ]; echo $?)
check "5 and no other suite" $(! grep -q ran-b "$out_dir/good.log"; echo $?)
run --all --jobs good "$sha"
check "5 --all runs every suite" $(grep -q ran-a "$out_dir/good.log" && grep -q ran-b "$out_dir/good.log"; echo $?)
git -C "$root/repo" push -q origin main 2>/dev/null
echo z > "$root/repo/.archon/scripts/c.sh"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "unused script"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
run --jobs good "$sha"
check "5 a change no suite runs or names skips them" $(grep -qE '^ +SKIPPED +[0-9]+s +Every \.archon test suite passes -- no \.archon suite runs or names a file' "$out_dir/summary.txt" && ! grep -q archon-ran "$out_dir/good.log"; echo $?)
echo y > "$root/repo/.gitignore"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "ignore"
git -C "$root/repo" push -q origin main 2>/dev/null
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
run --jobs good "$sha"
check "5 a commit on the base is judged by its own change, .gitignore runs every suite" $(line success "Every .archon test suite passes" && grep -q ran-a "$out_dir/good.log" && grep -q ran-b "$out_dir/good.log"; echo $?)

# 6. A job in CI_LOCAL_WSL runs through wsl.exe, in its own clone; the stub runs the command here, with its own HOME,
#    and maps /mnt/<drive>/ back for Git Bash. WSL_BROKEN makes the distro unusable.
mkdir -p "$root/wslbin" "$root/wslhome"
cat > "$root/wslbin/wsl.exe" <<'STUB'
#!/usr/bin/env bash
echo "wsl $*" >> "$WSL_LOG"
[ "$1 $3" = "-d --exec" ] || exit 64
[ -n "${WSL_BROKEN:-}" ] && { echo "There is no distribution with the supplied name."; exit 1; }
shift 3
args=()
for a in "$@"; do
  command -v cygpath > /dev/null && [[ "$a" =~ ^/mnt/([a-z])(/.*)?$ ]] && a="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  args+=("$a")
done
unset MSYS_NO_PATHCONV  # set for the real wsl.exe; Git for Windows' own tools need their path conversion
HOME="$WSL_HOME" exec "${args[@]}"
STUB
chmod +x "$root/wslbin/wsl.exe"
wsl_run() { # wsl_run <args...>: run with the stub first on PATH
  : > "$root/wsl.log"
  out=$( (cd "$root/repo" && PATH="$root/wslbin:$root/bin:$PATH" GH_LOG="$root/gh.log" WSL_LOG="$root/wsl.log" \
    WSL_HOME="$root/wslhome" CI_LOCAL_WSL=good CI_LOCAL_ROOT="$root/out" bash "$script" "$@") 2>&1 ); rc=$?
}
wdir="$root/wslhome/ci-local/${sha:0:7}/good"
wsl_run --keep --jobs good "$sha"
check "6 the WSL job passes" $([ "$rc" -eq 0 ] && grep -qE '^good +success' "$out_dir/summary.txt"; echo $?)
check "6 its steps run through wsl.exe" $(grep -q "^wsl -d Ubuntu --exec bash .*/wsl.sh step ${sha:0:7}/good " "$root/wsl.log"; echo $?)
check "6 in the WSL clone of the commit" $(grep -q "hello from wt base=origin/main ci=true" "$out_dir/good.log" \
  && [ "$(git -C "$wdir/wt" rev-parse HEAD)" = "$sha" ]; echo $?)
check "6 the clone's origin is the repo's" $([ "$(git -C "$wdir/wt" remote get-url origin)" = "$(git -C "$root/repo" remote get-url origin)" ]; echo $?)
check "6 git config --global stays in the WSL job" $([ "$(cat "$wdir/wt/global-name.txt")" = ci-local-test ]; echo $?)
check "6 the summary says where it ran" $(grep -q "^    runs in WSL Ubuntu: ~/ci-local/${sha:0:7}/good$" "$out_dir/summary.txt"; echo $?)
wsl_run --jobs good "$sha"
check "6 without --keep the WSL clone goes" $([ "$rc" -eq 0 ] && [ ! -e "$wdir" ]; echo $?)
WSL_BROKEN=1 wsl_run --jobs good "$sha"
check "6 an unusable distro falls back to Git Bash" $([ "$rc" -eq 0 ] && grep -q "hello from wt-good" "$out_dir/good.log" \
  && grep -q "^    runs in Git Bash: WSL Ubuntu: There is no distribution" "$out_dir/summary.txt"; echo $?)
run --jobs good "$sha"
check "6 a job not listed never calls wsl.exe" $([ "$rc" -eq 0 ] && ! grep -q "runs in" "$out_dir/summary.txt"; echo $?)

# 7. One local CI at a time (CI_LOCAL_SLOTS=1, through section 11; section 18 covers two slots): a second run waits while
# the lock is held, goes once it is released, and takes over a lock whose process is gone; the lock goes with the run,
# also when the run stops early.
export CI_LOCAL_SLOTS=1
lock="$root/out/.running"
sleep 60 & holder=$!
mkdir -p "$lock"; echo "$holder" > "$lock/pid"; echo 99 > "$lock/what"
( cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_LOCK_POLL=1 \
    bash "$script" --jobs good "$sha" > "$root/wait.out" 2>&1; echo $? > "$root/wait.rc" ) &
sleep 3
check "7 waits while another local CI runs" $([ ! -e "$root/wait.rc" ] && grep -q "waiting for the local CI of 99 (pid $holder)" "$root/wait.out"; echo $?)
rm -rf "$lock"
for _ in $(seq 1 60); do [ -e "$root/wait.rc" ] && break; sleep 0.5; done
check "7 runs once the other ended" $([ "$(cat "$root/wait.rc" 2>/dev/null)" = 0 ] && grep -q "^good: success" "$root/wait.out"; echo $?)
check "7 the lock goes with the run" $([ ! -e "$lock" ]; echo $?)
kill "$holder"; wait "$holder" 2>/dev/null
mkdir -p "$lock"; echo "$holder" > "$lock/pid"
CI_LOCAL_LOCK_POLL=1 run --jobs good "$sha"
check "7 a lock whose process is gone is taken over" $([ "$rc" -eq 0 ] && grep -q "taking over" <<<"$out" && [ ! -e "$lock" ]; echo $?)
run --jobs nope "$sha"
check "7 the lock goes when the run stops early" $([ "$rc" -eq 2 ] && [ ! -e "$lock" ]; echo $?)

# 8. needs: (TASK-4.2): a job waits for the jobs it needs, runs only when each succeeded, and otherwise fails without
# running a step; a job without needs: runs as before. Its own commit holds the jobs, so sections 1-7 keep their counts.
marks="$root/marks"; mkdir -p "$marks"
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  good:
    runs-on: ubuntu-latest
    steps:
      - name: Slow success
        run: sleep 1 && touch $marks/good.done
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: Fails
        run: exit 3
  after_bad:
    needs: bad
    runs-on: ubuntu-latest
    steps:
      - name: Must not run
        run: touch $marks/after_bad.ran
  after_good:
    needs: [good]
    runs-on: ubuntu-latest
    steps:
      - name: Runs after good
        run: touch $marks/after_good.ran
  ghost:
    needs: nowhere
    runs-on: ubuntu-latest
    steps:
      - name: Must not run
        run: touch $marks/ghost.ran
YML
git -C "$root/repo" commit -qam "jobs with needs"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
run --post "$sha"
check "8 a job whose needed job failed does not run its step" $([ ! -e "$marks/after_bad.ran" ]; echo $?)
check "8 it fails, naming the needed job" $(grep -qE '^after_bad +failure' "$out_dir/summary.txt" \
  && grep -q "not run: needed job bad failed" "$out_dir/after_bad.log"; echo $?)
check "8 --post posts pending, then failure, for it" $(grep -n 'context=local-ci/after_bad' "$root/gh.log" | sed -n '2p' | grep -q 'state=pending' \
  && grep -n 'context=local-ci/after_bad' "$root/gh.log" | sed -n '3p' | grep -q 'state=failure -f context=local-ci/after_bad -f description=failure (not run: needed job bad failed) on '; echo $?)
check "8 a job runs after the needed job succeeded" $([ -e "$marks/after_good.ran" ] && grep -qE '^after_good +success' "$out_dir/summary.txt"; echo $?)
check "8 and only once that job had finished" $([ "$marks/after_good.ran" -nt "$marks/good.done" ] && [ "$marks/after_good.ran" -nt "$out_dir/good.result" ]; echo $?)
check "8 --post posts success for it" $(grep -q 'state=success -f context=local-ci/after_good' "$root/gh.log"; echo $?)
check "8 a job with no needs runs as before" $(grep -qE '^good +success' "$out_dir/summary.txt" && grep -qE '^bad +failure' "$out_dir/summary.txt"; echo $?)
check "8 a needed job missing from the workflow is a failure" $([ ! -e "$marks/ghost.ran" ] && grep -q "needed job nowhere is not in the workflow" "$out_dir/ghost.log" \
  && grep -qE '^ghost +failure' "$out_dir/summary.txt"; echo $?)
check "8 the status of a job not run names no skipped steps" $(grep 'context=local-ci/after_bad' "$root/gh.log" | grep 'state=failure' \
  | grep -qv 'skipped'; echo $?)
check "8 a job's seconds are its own, the needs: wait goes beside them" $(read -r r own _ k nw _ < "$out_dir/after_good.result"; [ "$r" = success ] \
  && [ "$own" -lt 2 ] && [ "$nw" -ge 1 ] && [ "$k" = ran ] && grep -qE '^after_good +success +[0-9]+s  \(\+[0-9]+s waiting for needs\)' "$out_dir/summary.txt"; echo $?)
check "8 the ledger's end line has own and needs seconds per job" $(tail -n 1 "$ledger" | jq -e '.ev == "end" and .jobs.after_good.needs >= 1
  and .jobs.after_good.own < 2 and .jobs.after_bad.kind == "notrun" and .jobs.after_bad.res == "failure"' > /dev/null; echo $?)

# 9. needs: that cannot be met fails the job instead of waiting forever: a needed job left out by --jobs, a cycle (a job
# that needs itself, directly or through another job), and a serial job that needs a serial job queued after it.
run --jobs after_good "$sha"
check "9 a needed job left out of the run fails the job" $([ "$rc" -ne 0 ] && grep -q "needed job good is not part of this run" "$out_dir/after_good.log" \
  && grep -qE '^after_good +failure' "$out_dir/summary.txt"; echo $?)
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  selfish:
    needs: selfish
    runs-on: ubuntu-latest
    steps:
      - run: touch $marks/selfish.ran
  ping:
    needs: pong
    runs-on: ubuntu-latest
    steps:
      - run: touch $marks/ping.ran
  pong:
    needs: [ping]
    runs-on: ubuntu-latest
    steps:
      - run: touch $marks/pong.ran
  first:
    needs: second
    runs-on: ubuntu-latest
    steps:
      - run: touch $marks/first.ran
  second:
    runs-on: ubuntu-latest
    steps:
      - run: touch $marks/second.ran
YML
git -C "$root/repo" commit -qam "needs that cannot be met"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
: > "$root/gh.log"
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_SERIAL="first second" \
  timeout 120 bash "$script" "$sha") 2>&1 ); rc=$?
check "9 the run ends instead of waiting forever" $([ "$rc" -ne 124 ] && [ -s "$out_dir/summary.txt" ]; echo $?)
check "9 a job that needs itself fails without running" $([ ! -e "$marks/selfish.ran" ] && grep -q "needs cycle" "$out_dir/selfish.log" \
  && grep -qE '^selfish +failure' "$out_dir/summary.txt"; echo $?)
check "9 two jobs that need each other both fail without running" $([ ! -e "$marks/ping.ran" ] && [ ! -e "$marks/pong.ran" ] \
  && grep -q "needs cycle" "$out_dir/ping.log" && grep -q "needs cycle" "$out_dir/pong.log"; echo $?)
check "9 a serial job that needs a later serial job fails, and the later one still runs" $([ ! -e "$marks/first.ran" ] \
  && grep -q "needed job second runs after it in CI_LOCAL_SERIAL" "$out_dir/first.log" && [ -e "$marks/second.ran" ]; echo $?)

# 10. Evidence is kept: a second run of a commit moves the first one's folder to <sha7>.r<n>, never deletes it; the run
# id names run k of the commit. A worktree the runner cannot create is an infrastructure failure, named as such.
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
run "$sha"
first=$(cat "$out_dir/run-id")
run "$sha"
check "10 the first run's id is <sha7>.r1" $([ "$first" = "${sha:0:7}.r1" ]; echo $?)
check "10 a second run keeps the first one's folder as .r1" $([ -s "$out_dir.r1/summary.txt" ] && [ "$(cat "$out_dir.r1/run-id")" = "$first" ] \
  && [ -s "$out_dir.r1/quick.log" ]; echo $?)
check "10 the second run is .r2, in <sha7>/" $([ "$(cat "$out_dir/run-id")" = "${sha:0:7}.r2" ] && [ -s "$out_dir/summary.txt" ]; echo $?)
run "$sha"
check "10 a third run keeps both" $([ -d "$out_dir.r1" ] && [ "$(cat "$out_dir.r2/run-id")" = "${sha:0:7}.r2" ] \
  && [ "$(cat "$out_dir/run-id")" = "${sha:0:7}.r3" ]; echo $?)
mkdir -p "$root/gitbin"
cat > "$root/gitbin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = add ] && [[ " \$* " == *" worktree add "* ]] && { echo "fatal: stubbed worktree failure" >&2; exit 128; }; done
exec $(command -v git) "\$@"
STUB
chmod +x "$root/gitbin/git"
: > "$root/gh.log"
out=$( (cd "$root/repo" && PATH="$root/gitbin:$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" bash "$script" --post "$sha") 2>&1 ); rc=$?
check "10 a worktree failure posts failure (infra: worktree)" $([ "$rc" -eq 1 ] \
  && grep -qE 'state=failure -f context=local-ci/quick -f description=failure \(infra: worktree\) on [^ ]+$' "$root/gh.log"; echo $?)

# 11. The queue: --post calls of one commit share one run; callers start in the order they asked; a queued status is
# posted before the run's turn; a queue entry whose process is gone is reaped as stale.
qs="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/scripts/ci-queue.sh"
bg() { # bg <name> <env...> -- <args...>: a run in the background; <name>.out and <name>.rc
  local name=$1; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ( cd "$root/repo" && env PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_LOCK_POLL=1 "${envs[@]}" \
      bash "$script" "$@" > "$root/$name.out" 2>&1; echo $? > "$root/$name.rc" ) &
}
waitfor() { local i; for i in $(seq 1 120); do eval "$1" && return 0; sleep 0.25; done; return 1; }
entries() { ls "$root/out/.queue" 2>/dev/null | grep -c '^[0-9]*$'; }
: > "$root/gh.log"; : > "$marks/order"; rm -f "$root"/dup*.rc; rm -rf "$root/st"
bg dup1 SLEEP=3 -- --post "$sha"
waitfor '[ "$(entries)" -ge 1 ]'
bg dup2 -- --post "$sha"
waitfor '[ -e "$root/dup2.rc" ]'
dup1_still_running=$([ ! -e "$root/dup1.rc" ]; echo $?)
waitfor '[ -e "$root/dup1.rc" ]'
check "11 two --post calls of one commit give one run" $([ "$(wc -l < "$marks/order")" -eq 1 ] \
  && [ "$(grep -c 'description=running since' "$root/gh.log")" -eq 1 ]; echo $?)
check "11 the second exits 0 at once, naming the live run and its folder" $([ "$dup1_still_running" -eq 0 ] \
  && [ "$(cat "$root/dup1.rc")" = 0 ] && [ "$(cat "$root/dup2.rc")" = 0 ] \
  && grep -qE "is pending, its run alive: #[0-9]+ (queued|running), pid [0-9]+; not run again; its folder is $root/out/${sha:0:7} \(--force runs it anyway\)" "$root/dup2.out"; echo $?)
check "11 nothing is left in the queue" $([ "$(entries)" -eq 0 ] && [ ! -e "$root/out/.running" ]; echo $?)
shas=()
for n in 1 2 3; do echo "$n" > "$root/repo/q$n"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "q$n"; shas+=("$(git -C "$root/repo" rev-parse HEAD)"); done
: > "$marks/order"; rm -f "$root"/fifo*.rc
bg fifo1 SLEEP=2 -- "${shas[0]}"; waitfor '[ "$(entries)" -ge 1 ]'
bg fifo2 -- "${shas[1]}"; waitfor '[ "$(entries)" -ge 2 ]'
bg fifo3 -- "${shas[2]}"
waitfor '[ -e "$root/fifo1.rc" ] && [ -e "$root/fifo2.rc" ] && [ -e "$root/fifo3.rc" ]'
check "11 callers run in the order they asked" $([ "$(tr '\n' ' ' < "$marks/order")" = "${shas[0]:0:7} ${shas[1]:0:7} ${shas[2]:0:7} " ]; echo $?)
check "11 a waiting caller says where it is in the queue" $(grep -q "queued as #[0-9]* at position 2: waiting for #" "$root/fifo2.out"; echo $?)
sleep 60 & holder=$!
mkdir -p "$root/out/.running"; echo "$holder" > "$root/out/.running/pid"; echo other > "$root/out/.running/what"
: > "$root/gh.log"; rm -f "$root/held.rc"
bg held -- --post "${shas[2]}"
waitfor 'grep -q "waiting for the local CI of other" "$root/held.out"'
check "11 queued is posted before the run's turn, running only once it comes" $(grep -q 'context=local-ci/quick -f description=queued #[0-9]* pos 1 since' "$root/gh.log" \
  && ! grep -q 'description=running since' "$root/gh.log"; echo $?)
check "11 the queue shows the waiting entry" $(CI_LOCAL_ROOT="$root/out" bash "$qs" list | grep -qE "^#[0-9]+ queued ${shas[2]:0:7} [0-9]+@" \
  && CI_LOCAL_ROOT="$root/out" bash "$qs" state "${shas[2]}" | grep -q '^queued #[0-9]* pos 1 pid'; echo $?)
kill "$holder"; wait "$holder" 2>/dev/null
waitfor '[ -e "$root/held.rc" ]'
check "11 it runs once the lock is free" $([ "$(cat "$root/held.rc")" = 0 ] && grep -q 'description=running since' "$root/gh.log"; echo $?)
sleep 0.1 & dead=$!; wait "$dead"
printf 'n=900\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=queued\n' "$sha" "$dead" "$(hostname)" > "$root/out/.queue/900"
check "11 a queued entry whose process is gone reads stale" $(CI_LOCAL_ROOT="$root/out" bash "$qs" state "$sha" 2>/dev/null | grep -q "^stale #900 pid $dead"; echo $?)
printf 'n=901\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=queued\n' "$sha" "$dead" "$(hostname)" > "$root/out/.queue/901"
rm -rf "$root/st"
CI_LOCAL_LOCK_POLL=1 run --post "$sha"
check "11 and is reaped: the run does not wait for it or attach to it" $([ "$rc" -eq 0 ] && grep -q "entry #901 .* is stale" <<<"$out" \
  && ! grep -q "already queued" <<<"$out" && [ ! -e "$root/out/.queue/901" ]; echo $?)
check "11 none-check answers none when no entry comes" $(CI_LOCAL_ROOT="$root/out" CI_NONE_GRACE=1 CI_QUEUE_POLL=1 bash "$qs" none-check 0123456789012345678901234567890123456789 | grep -qx none; echo $?)

unset CI_LOCAL_SLOTS

# 12. The ledger: one line per event, start and end with the same run id; with a ledger that cannot be written, the
# statuses and the exit code are the same.
: > "$ledger"
: > "$root/gh.log"; rm -rf "$root/st"
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_CALLER=delegator CI_LOCAL_TICKET=TASK-9 \
  bash "$script" --post "$sha") 2>&1 ); rc=$?
id=$(cat "$out_dir/run-id")
check "12 request, start, verdict and end are recorded" $(jq -se --arg id "$id" --arg sha "$sha" '
  (map(.ev) | index("request") < index("start") and index("start") < index("end"))
  and all(.[]; .v == 1 and .sha == $sha and .caller == "delegator" and .ticket == "TASK-9" and (.t | type) == "number")
  and (map(select(.ev == "start" or .ev == "end" or .ev == "verdict") | .run) | unique == [$id])
  and any(.[]; .ev == "verdict" and .job == "quick" and .state == "success" and (.description | startswith("success in ")))
  and any(.[]; .ev == "end" and .rc == 0 and .aborted == false and .jobs.quick.res == "success")' "$ledger" > /dev/null; echo $?)
good_gh=$(sed -E 's/[0-9]+s on/Ns on/; s/(since|pid) [0-9:@A-Za-z.-]+/\1 X/g; s/#[0-9]+/#N/' "$root/gh.log"); good_rc=$rc
mkdir -p "$root/noledger"
: > "$root/gh.log"; rm -rf "$root/st"
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LEDGER="$root/noledger" \
  bash "$script" --post "$sha") 2>&1 ); rc=$?
check "12 an unwritable ledger changes no status and no exit code" $([ "$rc" = "$good_rc" ] && grep -q "ci-ledger: could not append" <<<"$out" \
  && [ "$(sed -E 's/[0-9]+s on/Ns on/; s/(since|pid) [0-9:@A-Za-z.-]+/\1 X/g; s/#[0-9]+/#N/' "$root/gh.log")" = "$good_gh" ]; echo $?)

# 13. Run or reuse (CI plan C12): the base's planner (ci-plan.sh --self-from) plans each job. A ran status carries
# fp=<fp10> and the ledger verdict the fields a later plan reads; shadow (the default) runs a job it would reuse and logs
# a decision; CI_REUSE=live posts `reused from` (the latest green source: the shadow twin) and runs nothing; --all and
# the kill switch reuse nothing.
here_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
echo b > "$root/repo/b.txt"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "b"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
: > "$marks/order"; : > "$ledger"
run --post "$sha"
fp=$(sed -nE 's/^quick run fp=([0-9a-f]{64})$/\1/p' "$out_dir/plan.txt")
check "13 the base's planner plans the job" $([ "$rc" -eq 0 ] && [ -n "$fp" ] && head -n 1 "$out_dir/plan.txt" | grep -q "^# ci-plan sha=$sha .* from=$p_base"; echo $?)
check "13 a ran status carries fp=<fp10>" $(grep -qE "state=success -f context=local-ci/quick -f description=success in [0-9]+s on [^ ;]+; fp=${fp:0:10}\$" "$root/gh.log"; echo $?)
runner=$(head -n 1 "$out_dir/plan.txt" | sed -nE 's/.* runner=([^ ]+).*/\1/p')
check "13 the verdict carries status, the full fp, the plan's runner class and narrowed" $([ -n "$runner" ] && jq -se --arg fp "$fp" --arg r "$runner" 'any(.[]; .ev == "verdict"
  and .job == "quick" and .state == "success" and .fp == $fp and .scope == $b and .runner == $r and .narrowed == false and .decision == "ran")' --arg b "$(git -C "$root/repo" rev-parse --short=7 "$p_base:.claude/scripts/ci-plan.sh")" "$ledger" > /dev/null; echo $?)
twin=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin)
run --post "$twin"
check "13 shadow (default): the job runs" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 2 ]; echo $?)
check "13 shadow logs a decision would reuse, naming the source" $(jq -se --arg s "$sha" --arg t "$twin" 'any(.[]; .ev == "decision" and .sha == $t
  and .job == "quick" and .decision == "would reuse" and .source == $s and .taken == "run")' "$ledger" > /dev/null; echo $?)
twin2=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin2)
CI_REUSE=live run --post "$twin2"
blob=$(git -C "$root/repo" rev-parse "$p_base:.claude/scripts/ci-plan.sh")
check "13 live: the job runs nothing" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 2 ]; echo $?)
check "13 live: it posts reused from <sha12>; fp; scope=<planner blob7>" \
  $(grep -qE "state=success -f context=local-ci/quick -f description=reused from (${sha:0:12}|${twin:0:12}); fp=${fp:0:10}; scope=${blob:0:7}\$" "$root/gh.log" \
  && ! grep -q 'context=local-ci/quick -f description=running since' "$root/gh.log"; echo $?)
check "13 live: a reuse event, never a source" $(jq -se --arg s "$sha" --arg w "$twin" --arg t "$twin2" --arg fp "$fp" 'any(.[]; .ev == "reuse" and .sha == $t
  and .job == "quick" and (.source == $s or .source == $w) and .decision == "reused" and .fp == $fp and .scope == $b and .state == "success")' --arg b "${blob:0:7}" "$ledger" > /dev/null; echo $?)
twin3=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin3)
CI_REUSE=live run --post --all "$twin3"
check "13 --all reuses nothing" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 3 ]; echo $?)
check "13 --all: the ran status still carries fp=" $(grep -qE "state=success -f context=local-ci/quick -f description=success in [0-9]+s on [^ ;]+; fp=${fp:0:10}\$" "$root/gh.log"; echo $?)
touch "$root/out/scope-all"
twin4=$(git -C "$root/repo" commit-tree "$sha^{tree}" -p "$p_base" -m twin4)
CI_REUSE=live run --jobs quick "$twin4"
check "13 the scope-all kill switch reuses nothing" $([ "$rc" -eq 0 ] && [ "$(wc -l < "$marks/order")" -eq 4 ]; echo $?)
rm -f "$root/out/scope-all"
nobase=$(git -C "$root/repo" commit-tree "$sha^{tree}" -m orphan)
run --jobs quick "$nobase"
check "13 no base for the planner: the job runs, without an fp" $([ "$rc" -eq 0 ] && [ ! -s "$root/out/${nobase:0:7}/plan.txt" ] \
  && read -r _ f _ < "$root/out/${nobase:0:7}/quick.plan" && [ -z "$f" ]; echo $?)

# 14. --rerun-failed (D4): on the same commit and tested tree, the latest run's green jobs are kept (posted again, a
# kept event, not run) and only the red ones run.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  steady:
    runs-on: ubuntu-latest
    steps:
      - run: echo steady >> $marks/rerun
  flaky:
    runs-on: ubuntu-latest
    steps:
      - run: echo flaky >> $marks/rerun && test -e $marks/flaky.ok
YML
git -C "$root/repo" commit -qam "rerun jobs"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
: > "$marks/rerun"; rm -f "$marks/flaky.ok"
run --post "$sha"
first_status=$(grep 'state=success -f context=local-ci/steady' "$root/gh.log" | sed 's/.*description=//')
touch "$marks/flaky.ok"
run --post --rerun-failed "$sha"
check "14 the red job runs again and passes" $([ "$rc" -eq 0 ] && [ "$(grep -c flaky "$marks/rerun")" -eq 2 ]; echo $?)
check "14 the green job is kept, not run" $([ "$(grep -c steady "$marks/rerun")" -eq 1 ] && grep -qE '^steady +success .*\(kept from run' "$out_dir/summary.txt"; echo $?)
check "14 its earlier status is posted again" $([ -n "$first_status" ] && grep -qF "state=success -f context=local-ci/steady -f description=$first_status" "$root/gh.log" \
  && ! grep -q 'context=local-ci/steady -f description=running since' "$root/gh.log"; echo $?)
check "14 a kept event names the run" $(tail -n 30 "$ledger" | jq -se --arg s "$sha" 'any(.[]; .ev == "kept" and .sha == $s and .job == "steady"
  and (.from | endswith(".r1")))' > /dev/null; echo $?)
rm -f "$marks/flaky.ok"; run "$sha"; touch "$marks/flaky.ok"
CI_LOCAL_RERUN_AFTER=gradle-oom run --post --rerun-failed "$sha"
check "14 CI_LOCAL_RERUN_AFTER: the job green on rerun names the signature" $([ "$rc" -eq 0 ] \
  && grep -qE "state=success -f context=local-ci/flaky -f description=success in [0-9]+s on [^ ;]+; green on rerun after gradle-oom\$" "$root/gh.log" \
  && tail -n 10 "$ledger" | jq -se 'any(.[]; .ev == "verdict" and .job == "flaky" and .rerun_after == "gradle-oom")' > /dev/null; echo $?)
check "14 a kept job does not claim a rerun" $(! grep -q 'context=local-ci/steady -f description=.*green on rerun' "$root/gh.log"; echo $?)
echo other > "$out_dir/tree"; n_steady=$(grep -c steady "$marks/rerun")
run --rerun-failed "$sha"
check "14 another tested tree keeps nothing" $([ "$(grep -c steady "$marks/rerun")" -eq $((n_steady + 1)) ]; echo $?)
run --rerun-failed --all "$sha"
check "14 --rerun-failed with --all is refused" $([ "$rc" -eq 2 ]; echo $?)

# 15. The watcher (C16): timeout-minutes stops a job; the first red is reported at once; CI_LOCAL_FAIL_FAST stops the
# other jobs of a red run always, never, or (default) only while another run is queued.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  red:
    runs-on: ubuntu-latest
    steps:
      - run: sleep 1; exit 1
  slow:
    runs-on: ubuntu-latest
    timeout-minutes: \${SLOW_LIMIT}
    steps:
      - run: sleep \${SLOW:-4} && touch $marks/slow.done
YML
sed -i 's/\${SLOW_LIMIT}/1/' "$root/repo/.github/workflows/ci.yml"
git -C "$root/repo" commit -qam "watcher jobs"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
rm -f "$marks/slow.done"
CI_LOCAL_FAIL_FAST=always run --post "$sha"
check "15 always: the other job is cancelled, not run to its end" $([ "$rc" -eq 1 ] && [ ! -e "$marks/slow.done" ] && grep -qE '^slow +cancelled' "$out_dir/summary.txt"; echo $?)
check "15 a cancelled job posts error cancelled: ..., not a pass" $(grep -q 'state=error -f context=local-ci/slow -f description=cancelled: red failed (CI_LOCAL_FAIL_FAST=always), not a pass$' "$root/gh.log"; echo $?)
check "15 the cancelled status parses as kind cancelled" $(desc=$(grep -m1 'state=error -f context=local-ci/slow -f description=cancelled:' "$root/gh.log" | sed 's/.*description=//'); \
  grep -qx kind=cancelled <<<"$(bash "$here_repo/.claude/scripts/ci-status-grammar.sh" parse error "$desc")" || { sed 's/^/    gh.log: /' "$root/gh.log" >&2; false; }; echo $?)
check "15 the first red is reported at once and logged" $(grep -q '^first red: red (failure)' <<<"$out" \
  && tail -n 20 "$ledger" | jq -se 'any(.[]; .ev == "first-red" and .job == "red")' > /dev/null; echo $?)
sleep 5
check "15 the cancelled job's processes are gone" $([ ! -e "$marks/slow.done" ]; echo $?)
CI_LOCAL_FAIL_FAST=never run "$sha"
check "15 never: the other job runs to its end" $([ -e "$marks/slow.done" ] && grep -qE '^slow +success' "$out_dir/summary.txt"; echo $?)
rm -f "$marks/slow.done"
run "$sha"
check "15 when-queued, nothing queued: the other job runs to its end" $([ -e "$marks/slow.done" ] && grep -qE '^slow +success' "$out_dir/summary.txt"; echo $?)
rm -f "$marks/slow.done"; : > "$root/gh.log"; rm -rf "$root/st"
( cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" SLOW=8 bash "$script" --post "$sha" > "$root/wq.out" 2>&1; echo $? > "$root/wq.rc" ) &
waitfor '[ -s "$out_dir/slow.started" ] 2>/dev/null'
sleep 300 & qholder=$!
printf 'n=9990\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=queued\n' "${shas[0]}" "$qholder" "$(hostname)" > "$root/out/.queue/9990"
waitfor '[ -e "$root/wq.rc" ]'
check "15 when-queued, another run queued: the other job is cancelled" $([ "$(cat "$root/wq.rc")" = 1 ] && [ ! -e "$marks/slow.done" ] \
  && grep -q 'state=error -f context=local-ci/slow -f description=cancelled: red failed and run #9990 is queued, not a pass$' "$root/gh.log"; echo $?)
kill "$qholder"; wait "$qholder" 2>/dev/null; rm -f "$root/out/.queue/9990"
sed -i 's/timeout-minutes: 1$/timeout-minutes: 0.05/' "$root/repo/.github/workflows/ci.yml"
git -C "$root/repo" commit -qam "a short timeout"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
t0=$(date +%s)
out=$( (cd "$root/repo" && PATH="$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_ROOT="$root/out" CI_LOCAL_FAIL_FAST=never SLOW=40 \
  bash "$script" --post "$sha") 2>&1 ); rc=$?
check "15 a job over its timeout-minutes is stopped" $([ "$rc" -eq 1 ] && [ $(( $(date +%s) - t0 )) -lt 30 ] && grep -qE '^slow +failure' "$out_dir/summary.txt"; echo $?)
check "15 and posts timed out after <m> min" $(grep -q 'state=failure -f context=local-ci/slow -f description=timed out after 0.05 min (ci.yml timeout-minutes)$' "$root/gh.log"; echo $?)
check "15 its step process is gone" $(! pgrep -f 'sleep 40' > /dev/null; echo $?)

# 16. After a job: the run's own Docker leftovers of image-check (app-image-check-<sha7>-<pid>) whose process is gone
# go; a live one's stay, and so do another run's (another sha7), even when its process is gone. After the run, its own
# image tag goes, never another.
sleep 300 & live_pid=$!
sleep 0 & dead_pid=$!; wait "$dead_pid"
own="app-image-check-${sha:0:7}"
cat > "$root/bin/docker-stub" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$root/docker.log"
case "\$1 \$2" in
  "ps -a") printf '%s\n' $own-$dead_pid $own-$dead_pid-db $own-$live_pid app-image-check-0000000-$dead_pid app-image-check-$dead_pid other ;;
  "network ls") printf '%s\n' $own-$dead_pid app-image-check-0000000-$dead_pid ;;
  "ps --filter") echo $own-$live_pid ;;
esac
exit 0
STUB
chmod +x "$root/bin/docker-stub"; : > "$root/docker.log"
CI_LOCAL_DOCKER=docker-stub run --jobs red "$sha"
check "16 a leftover whose process is gone is removed" $(grep -qx "docker rm -f $own-$dead_pid" "$root/docker.log" \
  && grep -qx "docker rm -f $own-$dead_pid-db" "$root/docker.log" && grep -q "removed the leftover $own-$dead_pid" "$out_dir/red.log"; echo $?)
check "16 a live run's containers and others stay" $(! grep -q "rm -f $own-$live_pid" "$root/docker.log" && ! grep -q "rm -f other" "$root/docker.log"; echo $?)
check "16 another run's leftovers stay, also when their process is gone" $(grep -q -- "--filter name=$own-" "$root/docker.log" \
  && ! grep -q "rm -f app-image-check-0000000" "$root/docker.log" && ! grep -q "rm app-image-check-0000000" "$root/docker.log" \
  && ! grep -qx "docker rm -f app-image-check-$dead_pid" "$root/docker.log"; echo $?)
check "16 a held port of the run is noted" $(grep -q -- "--filter publish=18080" "$root/docker.log" \
  && grep -q "port 18080 is still held by the container $own-$live_pid" "$out_dir/red.log"; echo $?)
check "16 after the run, only its own image tag goes" $(grep -qx "docker image rm app:ci-${sha:0:7}" "$root/docker.log" \
  && [ "$(grep -c '^docker image rm' "$root/docker.log")" -eq 1 ]; echo $?)
kill "$live_pid"; wait "$live_pid" 2>/dev/null

# 17. --audit: no reuse, and each step runs under ci-plan.sh --audit-run --record (a report per step).
git -C "$root/repo" checkout -q "$p_base" -- .github/workflows/ci.yml; git -C "$root/repo" commit -qam "quick again"
sha=$(git -C "$root/repo" rev-parse HEAD); out_dir="$root/out/${sha:0:7}"
CI_REUSE=live run --audit --jobs quick "$sha"
check "17 the planner plans with --audit" $([ "$rc" -eq 0 ] && grep -q 'quick run fp=' "$out_dir/plan.txt" && grep -q 'audit never reuses' "$out_dir/plan.log"; echo $?)
check "17 the worktree's git index is settled before the steps" $(grep -q -- '--audit: settled the worktree.s git index' "$out_dir/quick.log"; echo $?)
check "17 the step runs under --audit-run" $(grep -qE '^audit quick: [0-9]+ tracked files read|strace not found|already traced' "$out_dir/quick.log"; echo $?)

# 18. Two slots (CI_LOCAL_SLOTS=2, owner decision D18; one is the default since 2026-10-22): runs of two commits go side by side and share no name, folder or port:
# each step gets the run's own CI_LOCAL_RUN, image tag, image-check name prefix and port (one per slot); the image job
# (CI_LOCAL_XRUN) still runs one at a time across runs, the later one waiting; each run removes only its own image tag.
# Unset, CI_LOCAL_SLOTS is one run at a time.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  side:
    runs-on: ubuntu-latest
    steps:
      - name: Records what the run owns
        run: |
          echo "\$CI_LOCAL_RUN \$CI_LOCAL_SLOT \$CI_IMAGE_TAG \$IMAGE_CHECK_NAME \$IMAGE_CHECK_PORT \$PWD" > $marks/side.\$CI_LOCAL_RUN
          date +%s.%N > $marks/side.\$CI_LOCAL_RUN.t0; sleep \${SIDE:-1}; date +%s.%N > $marks/side.\$CI_LOCAL_RUN.t1
  image:
    runs-on: ubuntu-latest
    steps:
      - name: Builds and checks the image
        run: date +%s.%N > $marks/image.\$CI_LOCAL_RUN.t0; sleep 2; date +%s.%N > $marks/image.\$CI_LOCAL_RUN.t1
YML
git -C "$root/repo" commit -qam "two slots"
two=()
for n in a b c d; do echo "$n" > "$root/repo/slot-$n"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "slot $n"; two+=("$(git -C "$root/repo" rev-parse HEAD)"); done
A=${two[0]:0:7} B=${two[1]:0:7}
overlap() { awk -v a0="$(cat "$marks/$1.$2.t0")" -v a1="$(cat "$marks/$1.$2.t1")" -v b0="$(cat "$marks/$1.$3.t0")" -v b1="$(cat "$marks/$1.$3.t1")" \
  'BEGIN { exit !(a0 < b1 && b0 < a1) }'; }
: > "$root/docker.log"; rm -f "$root"/slot*.rc
bg slota CI_LOCAL_SLOTS=2 SIDE=6 CI_LOCAL_DOCKER=docker-stub -- "${two[0]}"; waitfor '[ "$(entries)" -ge 1 ]'
bg slotb CI_LOCAL_SLOTS=2 SIDE=6 CI_LOCAL_DOCKER=docker-stub -- "${two[1]}"
waitfor '[ -e "$root/slota.rc" ] && [ -e "$root/slotb.rc" ]'; waitfor '[ -e "$root/slota.rc" ] && [ -e "$root/slotb.rc" ]'
out="$(cat "$root/slota.out" "$root/slotb.out" 2>/dev/null)"
check "18 two runs of two commits both pass" $([ "$(cat "$root/slota.rc")" = 0 ] && [ "$(cat "$root/slotb.rc")" = 0 ]; echo $?)
check "18 their jobs run side by side" $(overlap side "$A" "$B"; echo $?)
read -r ra sa ta na pa wa < "$marks/side.$A"; read -r rb sb tb nb pb wb < "$marks/side.$B"
check "18 each run has its own slot and port" $([ "$(printf '%s\n' "$sa $pa" "$sb $pb" | sort | tr '\n' ' ')" = "1 18080 2 18081 " ]; echo $?)
check "18 each run has its own image tag, image-check names and folder" $([ "$ta" = "app:ci-$A" ] && [ "$tb" = "app:ci-$B" ] \
  && [ "$na" = "app-image-check-$A" ] && [ "$nb" = "app-image-check-$B" ] \
  && [ "$wa" = "$root/out/$A/wt-side" ] && [ "$wb" = "$root/out/$B/wt-side" ]; echo $?)
check "18 the ledger names both slots" $(jq -se --arg a "$A" --arg b "$B" '[.[] | select(.ev == "start" and ((.run | startswith($a)) or (.run | startswith($b)))) | .slot] | sort == [1, 2]' "$ledger" > /dev/null; echo $?)
check "18 the image job runs one at a time across runs" $(! overlap image "$A" "$B" \
  && grep -q "waits for the image job of run [0-9a-f]\{7\}\.r[0-9]* to end: one at a time across runs (CI_LOCAL_XRUN)" "$root/out/$A/image.log" "$root/out/$B/image.log"; echo $?)
check "18 each run removes its own image tag only" $(grep -qx "docker image rm app:ci-$A" "$root/docker.log" \
  && grep -qx "docker image rm app:ci-$B" "$root/docker.log" && [ "$(grep -c '^docker image rm' "$root/docker.log")" -eq 2 ]; echo $?)
C=${two[2]:0:7} D=${two[3]:0:7}
bg slotc SIDE=2 -- "${two[2]}"; waitfor '[ "$(entries)" -ge 1 ]'
bg slotd SIDE=2 -- "${two[3]}"
waitfor '[ -e "$root/slotc.rc" ] && [ -e "$root/slotd.rc" ]'; waitfor '[ -e "$root/slotc.rc" ] && [ -e "$root/slotd.rc" ]'
out="$(cat "$root/slotc.out" "$root/slotd.out" 2>/dev/null)"
check "18 unset: one run at a time, on port 18080" $([ "$(cat "$root/slotc.rc")" = 0 ] && [ "$(cat "$root/slotd.rc")" = 0 ] \
  && ! overlap side "$C" "$D" && [ "$(cut -d' ' -f2,5 "$marks/side.$C")" = "1 18080" ] && [ "$(cut -d' ' -f2,5 "$marks/side.$D")" = "1 18080" ]; echo $?)
CI_LOCAL_SLOTS=0 run --jobs side "${two[0]}"
check "18 CI_LOCAL_SLOTS must be 1 or more" $([ "$rc" -eq 2 ] && grep -q "CI_LOCAL_SLOTS must be a whole number" <<<"$out"; echo $?)

# 19. Same tree (owner decision 2026-10-23): a merge commit on main whose tree is exactly the tree its pull request
# head's last --post run tested, green on every job with the same ci.yml and runner class, posts `reused from <head
# sha12>; same tree` on every job and runs nothing. Anything else runs in full.
unset CI_LOCAL_SLOTS
git -C "$root/repo" switch -q main 2>/dev/null; git -C "$root/repo" reset -q --hard
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - run: echo one >> $marks/same
  two:
    runs-on: ubuntu-latest
    steps:
      - run: echo two >> $marks/same && test ! -e $marks/two.red
YML
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "same tree jobs"; git -C "$root/repo" push -q origin HEAD:main 2>/dev/null
pr_head() { # pr_head <name>: a pull request head off main and its --post run (PR 7); sets H
  git -C "$root/repo" switch -qc "pr-$1" main; echo "$1" > "$root/repo/pr-$1"
  git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "pr $1"; H=$(git -C "$root/repo" rev-parse HEAD)
  git -C "$root/repo" switch -q main; run --post "7:$H"
}
merge_it() { # merge_it <name> [--no-commit]: the merge commit of that head on main, pushed; sets M
  git -C "$root/repo" merge -q --no-ff --no-edit "${@:2}" "pr-$1" > /dev/null
  M=$(git -C "$root/repo" rev-parse HEAD); git -C "$root/repo" push -q origin main 2>/dev/null
}
ran_jobs() { wc -l < "$marks/same"; }
pr_head a; merge_it a
check "19 the head's run is green and keeps its runner class" $([ "$rc" -eq 0 ] && [ -n "$(cat "$root/out/${H:0:7}/runner")" ]; echo $?)
: > "$marks/same"; : > "$ledger"
run --post "$M"
check "19 same tree: nothing runs, exit 0" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 0 ]; echo $?)
check "19 same tree: every job posts reused from <head sha12>; same tree" \
  $(grep -qF "state=success -f context=local-ci/one -f description=reused from ${H:0:12}; same tree" "$root/gh.log" \
  && grep -qF "state=success -f context=local-ci/two -f description=reused from ${H:0:12}; same tree" "$root/gh.log"; echo $?)
check "19 same tree: a same-tree ledger event per job, naming the head and the tree" $(jq -se --arg m "$M" --arg h "$H" --arg t "$(git -C "$root/repo" rev-parse "$M^{tree}")" \
  '[.[] | select(.ev == "same-tree" and .sha == $m and .source == $h and .tree == $t and .state == "success") | .job] | sort == ["one", "two"]' "$ledger" > /dev/null; echo $?)
check "19 the start line carries the tested tree" $(jq -se --arg m "$M" 'any(.[]; .ev == "start" and .sha == $m and (.tree | length) == 40)' "$ledger" > /dev/null; echo $?)
check "19 the status parses as kind same-tree" $([ "$(bash "$here_repo/.claude/scripts/ci-status-grammar.sh" parse success "reused from ${H:0:12}; same tree" | head -n 1)" = kind=same-tree ]; echo $?)

pr_head b; echo moved > "$root/repo/moved"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm moved; merge_it b
: > "$marks/same"; run --post "$M"
check "19 main moved between the head's run and the merge: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

touch "$marks/two.red"; pr_head c; rm -f "$marks/two.red"; merge_it c
: > "$marks/same"; run --post "$M"
check "19 a red job in the head's run: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

pr_head d; sed -i '/local-ci\/two/d' "$root/st/$H"; merge_it d
: > "$marks/same"; run --post "$M"
check "19 a job missing in the head's run: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

pr_head e; merge_it e; touch "$root/out/scope-all"
: > "$marks/same"; run --post "$M"
check "19 the kill switch on: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)
rm -f "$root/out/scope-all"
: > "$marks/same"; run --post --all "$M"
check "19 --all: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)

pr_head f; merge_it f --no-commit; echo "# changed in the merge" >> "$root/repo/.github/workflows/ci.yml"
git -C "$root/repo" commit -qam "Merge pr-f, ci.yml changed"; M=$(git -C "$root/repo" rev-parse HEAD); git -C "$root/repo" push -q origin main 2>/dev/null
: > "$marks/same"; run --post "$M"
check "19 ci.yml changed in the merge commit: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)
check "19 ci.yml changed: the run says why" $(grep -qF "same tree: not used, the head's run tested another tree" <<< "$out"; echo $?)

pr_head g; merge_it g
: > "$marks/same"; CI_PLAN_RUNNER=another-runner run --post "$M"
check "19 another runner class: a full run" $([ "$rc" -eq 0 ] && [ "$(ran_jobs)" -eq 2 ] && ! grep -q "same tree" "$root/gh.log"; echo $?)
check "19 another runner class: the run says why, also in its folder" $(grep -qF "same tree: not used, another runner class" <<< "$out" \
  && [ "$(cat "$root/out/${M:0:7}/same-tree.why")" = "another runner class" ]; echo $?)

# 20. A plain --post call on a commit whose local CI is already running exits 0 at once and names the run and its folder
# (TASK-68); --force runs anyway, queued behind the live run, never attached; --force without --post is a usage error.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  quick:
    runs-on: ubuntu-latest
    steps:
      - name: Quick
        run: sleep \${SLEEP:-0} && git rev-parse --short HEAD >> $marks/order
YML
echo live > "$root/repo/t68-live"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "t68 live"
c=$(git -C "$root/repo" rev-parse HEAD)
: > "$marks/order"; rm -f "$root"/live1.rc "$root"/forced.rc; : > "$root/gh.log"
bg live1 SLEEP=5 -- --post "$c"
waitfor 'grep -q "description=running since" "$root/gh.log"'
run --post "$c"
check "20 a live pending commit is not run again and the call does not wait" $([ "$rc" -eq 0 ] && [ ! -e "$root/live1.rc" ] \
  && grep -qE "is pending, its run alive: #[0-9]+ (queued|running), pid [0-9]+; not run again; its folder is $root/out/${c:0:7} \(--force runs it anyway\)" <<<"$out"; echo $?)
check "20 the call that ran nothing records an attach with exit 0 in the ledger" $(jq -se --arg c "$c" \
  'any(.[]; .ev == "attach" and .sha == $c and .rc == 0)' "$ledger" > /dev/null; echo $?)
bg forced -- --post --force "$c"
waitfor '[ -e "$root/live1.rc" ] && [ -e "$root/forced.rc" ]'
check "20 --force runs anyway on a live commit, queued behind it" $([ "$(cat "$root/forced.rc")" = 0 ] \
  && ! grep -q "not run again" "$root/forced.out" && [ "$(grep -c "^${c:0:7}\$" "$marks/order")" -eq 2 ] \
  && [ "$(wc -l < "$marks/order")" -eq 2 ] && [ -s "$root/out/${c:0:7}.r1/summary.txt" ] \
  && grep -q "waiting for" "$root/forced.out"; echo $?)
run --force "$sha"
check "20 --force needs --post" $([ "$rc" -eq 2 ] && grep -q -- "--force applies to --post only" <<<"$out"; echo $?)

# 20 (TASK-68, continued). A plain --post call on a finished commit (green or red) runs nothing and exits 0; a pending
# commit whose run is gone (dead pid, or no queue entry) runs again; --force, --all and --rerun-failed run regardless.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  quick:
    runs-on: ubuntu-latest
    steps:
      - name: Quick
        run: sleep \${SLEEP:-0} && git rev-parse --short HEAD >> $marks/order
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: Fails
        run: exit 3
YML
git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "t68 jobs"
t68_commit() { # t68_commit <name>: a new commit; sets C
  echo "$1" > "$root/repo/t68-$1"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "t68 $1"
  C=$(git -C "$root/repo" rev-parse HEAD)
}
t68_status() { # t68_status <sha> <state> <description>: that status on every job, as the gh stub stores it
  local j n
  mkdir -p "$root/st"
  for j in quick bad; do
    n=$(( $(cat "$root/st/.id" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$root/st/.id"
    jq -nc --arg s "$2" --arg c "local-ci/$j" --arg d "$3" --argjson id "$n" --arg t "$(date -u +%FT%TZ)" \
      '{state: $s, context: $c, description: $d, id: $id, updated_at: $t}' >> "$root/st/$1"
  done
}
requests() { jq -s --arg c "$1" '[.[] | select(.ev == "request" and .sha == $c)] | length' "$ledger"; }
finished_msg() { grep -qE "ci-local: ${1:0:7} is finished: $2 .*; not run again; its folder is $root/out/${1:0:7} \(--force runs it anyway\)" <<<"$out"; }

t68_commit finished; c1=$C
run --post "$c1"
req_before=$(requests "$c1")
run --post "$c1"
check "20 a finished commit is not run again (red, exit 0)" $([ "$rc" -eq 0 ] && finished_msg "$c1" red \
  && ! grep -q 'state=pending' "$root/gh.log" && [ ! -e "$root/out/${c1:0:7}.r1" ] \
  && [ "$(requests "$c1")" -eq "$req_before" ]; echo $?)

t68_commit green; c2=$C
t68_status "$c2" success "success in 1s on $(hostname)"
run --post "$c2"
check "20 a green finished commit is not run again" $([ "$rc" -eq 0 ] && finished_msg "$c2" green \
  && ! grep -q 'description=running since' "$root/gh.log" && [ ! -e "$root/out/${c2:0:7}/summary.txt" ]; echo $?)

run --post --force "$c1"
check "20 --force runs a finished commit" $(grep -q 'description=running since' "$root/gh.log" \
  && [ -d "$root/out/${c1:0:7}.r1" ] && ! grep -q "not run again" <<<"$out"; echo $?)

run --post --all "$c1"
check "20 --post --all runs a finished commit" $(grep -q 'description=running since' "$root/gh.log" && ! grep -q "not run again" <<<"$out"; echo $?)

run --post --audit "$c1"
check "20 --post --audit runs a finished commit" $(grep -q 'description=running since' "$root/gh.log" && ! grep -q "not run again" <<<"$out"; echo $?)

t68_commit superseded; c5=$C
t68_status "$c5" error "superseded: PR #7 head is now abcdef1, not run"
run --post "$c5"
check "20 a superseded commit is run (a new --post starts a run on it)" $(grep -q 'description=running since' "$root/gh.log" \
  && ! grep -q "not run again" <<<"$out" && [ -s "$root/out/${c5:0:7}/summary.txt" ]; echo $?)

t68_commit dead; c3=$C
sleep 0.1 & dead=$!; wait "$dead"
t68_status "$c3" pending "running since 09:00, pid $dead@$(hostname)"
mkdir -p "$root/out/.queue" "$root/out/.running"
printf 'n=950\nsha=%s\npr=\nmode=post\nwhat=x\npid=%s\npstart=\nhost=%s\nt=1\nstate=running\n' "$c3" "$dead" "$(hostname)" > "$root/out/.queue/950"
echo "$dead" > "$root/out/.running/pid"
run --post "$c3"
check "20 dead pending: its pid is gone, so it runs again" $(grep -q 'description=running since' "$root/gh.log" \
  && [ -s "$root/out/${c3:0:7}/summary.txt" ] && ! grep -q "not run again" <<<"$out" \
  && grep -qE "ci-local: ${c3:0:7} is pending, but its run is gone \(.*\); running it again" <<<"$out"; echo $?)

rm -rf "$root/out/.running"
t68_commit nolock; c4=$C
t68_status "$c4" pending "running since 09:00, pid $dead@$(hostname)"
run --post "$c4"
check "20 dead pending: no queue entry and no lock for that commit, so it runs again" $(grep -q 'description=running since' "$root/gh.log" \
  && [ -s "$root/out/${c4:0:7}/summary.txt" ] && ! grep -q "not run again" <<<"$out" \
  && grep -qE "ci-local: ${c4:0:7} is pending, but its run is gone \(.*\); running it again" <<<"$out"; echo $?)

echo "ci-local tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
