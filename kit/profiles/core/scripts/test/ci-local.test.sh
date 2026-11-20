#!/usr/bin/env bash
# Tests for .claude/scripts/ci-local.sh against a throwaway repo, its own ci.yml and a stubbed gh: a whole run, --jobs, --post, WSL, the lock, needs:, kept evidence and two slots (sections 1-10, 18).
# Usage: bash scripts/test/ci-local.test.sh   (exit 0 = all pass)
# One of three suites that split the one 89 s ci-local suite, so that a render waits for the longest part (about 30 s);
# the shared setup is in ci-local-lib.sh, the section numbers are the old ones.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/ci-local-lib.sh"

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
check "1 buildkit-cache-dance (an image job's, which the kit has none of) is unknown: it fails" $(grep -qE '^oldimage +failure' "$out_dir/summary.txt" && grep -q "action not reproduced locally" "$out_dir/oldimage.log"; echo $?)
check "1 setup-java takes the java on PATH when its major is the version" $(grep -qE '^jdk +success' "$out_dir/summary.txt" \
  && grep -q "jdk at /opt/stub-jdk-97" "$out_dir/jdk.log"; echo $?)
check "1 setup-java with no local JDK of the version fails" $(grep -qE '^nojdk +failure' "$out_dir/summary.txt" && grep -q "no local JDK 98" "$out_dir/nojdk.log"; echo $?)
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
check "3 queued, then running, for every job" $([ "$(grep -c 'state=pending -f context=local-ci/[a-z]* -f description=queued #[0-9]* pos 1 since [0-9:]*, pid [0-9]*@' "$root/gh.log")" -eq 7 ] \
  && [ "$(grep -c 'state=pending -f context=local-ci/[a-z]* -f description=running since [0-9:]*, pid [0-9]*@' "$root/gh.log")" -eq 7 ] \
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
nowsl_run() { # nowsl_run <bin dir first on PATH> <args...>: CI_LOCAL_WSL=good, no wsl.exe on PATH
  local b=$1; shift
  out=$( (cd "$root/repo" && PATH="$b:$root/bin:$PATH" GH_LOG="$root/gh.log" CI_LOCAL_WSL=good CI_LOCAL_ROOT="$root/out" \
    bash "$script" "$@") 2>&1 ); rc=$?
}
mkdir -p "$root/linuxbin" "$root/winbin"
printf '#!/usr/bin/env bash\necho Linux\n' > "$root/linuxbin/uname"
printf '#!/usr/bin/env bash\necho MINGW64_NT-10.0-26100\n' > "$root/winbin/uname"
chmod +x "$root/linuxbin/uname" "$root/winbin/uname"
nowsl_run "$root/linuxbin" --jobs good "$sha"
check "6 a Linux host without wsl.exe runs the WSL job here, with no Git Bash line" $([ "$rc" -eq 0 ] \
  && grep -qE '^good +success' "$out_dir/summary.txt" && ! grep -q "runs in" "$out_dir/summary.txt"; echo $?)
nowsl_run "$root/winbin" --jobs good "$sha"
check "6 Git Bash on Windows without wsl.exe says so" $([ "$rc" -eq 0 ] \
  && grep -q "^    runs in Git Bash: no wsl.exe$" "$out_dir/summary.txt"; echo $?)

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
commit_quick_job
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

unset CI_LOCAL_SLOTS

# 18. Two slots (CI_LOCAL_SLOTS=2, owner decision D18; one is the default since 2026-10-22): runs of two commits go side by side and share no name or folder:
# each step gets the run's own CI_LOCAL_RUN and slot; a job in CI_LOCAL_XRUN still runs one at a time across runs, the
# later one waiting.
# Unset, CI_LOCAL_SLOTS is one run at a time.
cat > "$root/repo/.github/workflows/ci.yml" <<YML
jobs:
  side:
    runs-on: ubuntu-latest
    steps:
      - name: Records what the run owns
        run: |
          echo "\$CI_LOCAL_RUN \$CI_LOCAL_SLOT \$PWD" > $marks/side.\$CI_LOCAL_RUN
          date +%s.%N > $marks/side.\$CI_LOCAL_RUN.t0; sleep \${SIDE:-1}; date +%s.%N > $marks/side.\$CI_LOCAL_RUN.t1
  serial:
    runs-on: ubuntu-latest
    steps:
      - name: Holds what two runs cannot share
        run: date +%s.%N > $marks/serial.\$CI_LOCAL_RUN.t0; sleep 2; date +%s.%N > $marks/serial.\$CI_LOCAL_RUN.t1
YML
git -C "$root/repo" commit -qam "two slots"
two=()
for n in a b c d; do echo "$n" > "$root/repo/slot-$n"; git -C "$root/repo" add -A; git -C "$root/repo" commit -qm "slot $n"; two+=("$(git -C "$root/repo" rev-parse HEAD)"); done
A=${two[0]:0:7} B=${two[1]:0:7}
overlap() { awk -v a0="$(cat "$marks/$1.$2.t0")" -v a1="$(cat "$marks/$1.$2.t1")" -v b0="$(cat "$marks/$1.$3.t0")" -v b1="$(cat "$marks/$1.$3.t1")" \
  'BEGIN { exit !(a0 < b1 && b0 < a1) }'; }
rm -f "$root"/slot*.rc
bg slota CI_LOCAL_SLOTS=2 SIDE=6 CI_LOCAL_XRUN=serial -- "${two[0]}"; waitfor '[ "$(entries)" -ge 1 ]'
bg slotb CI_LOCAL_SLOTS=2 SIDE=6 CI_LOCAL_XRUN=serial -- "${two[1]}"
waitfor '[ -e "$root/slota.rc" ] && [ -e "$root/slotb.rc" ]'; waitfor '[ -e "$root/slota.rc" ] && [ -e "$root/slotb.rc" ]'
out="$(cat "$root/slota.out" "$root/slotb.out" 2>/dev/null)"
check "18 two runs of two commits both pass" $([ "$(cat "$root/slota.rc")" = 0 ] && [ "$(cat "$root/slotb.rc")" = 0 ]; echo $?)
check "18 their jobs run side by side" $(overlap side "$A" "$B"; echo $?)
read -r ra sa wa < "$marks/side.$A"; read -r rb sb wb < "$marks/side.$B"
check "18 each run has its own slot" $([ "$(printf '%s\n' "$sa" "$sb" | sort | tr '\n' ' ')" = "1 2 " ]; echo $?)
check "18 each run has its own run id and folder" $([ "$ra" = "$A" ] && [ "$rb" = "$B" ] \
  && [ "$wa" = "$root/out/$A/wt-side" ] && [ "$wb" = "$root/out/$B/wt-side" ]; echo $?)
check "18 the ledger names both slots" $(jq -se --arg a "$A" --arg b "$B" '[.[] | select(.ev == "start" and ((.run | startswith($a)) or (.run | startswith($b)))) | .slot] | sort == [1, 2]' "$ledger" > /dev/null; echo $?)
check "18 a CI_LOCAL_XRUN job runs one at a time across runs" $(! overlap serial "$A" "$B" \
  && grep -q "waits for the serial job of run [0-9a-f]\{7\}\.r[0-9]* to end: one at a time across runs (CI_LOCAL_XRUN)" "$root/out/$A/serial.log" "$root/out/$B/serial.log"; echo $?)
C=${two[2]:0:7} D=${two[3]:0:7}
bg slotc SIDE=2 -- "${two[2]}"; waitfor '[ "$(entries)" -ge 1 ]'
bg slotd SIDE=2 -- "${two[3]}"
waitfor '[ -e "$root/slotc.rc" ] && [ -e "$root/slotd.rc" ]'; waitfor '[ -e "$root/slotc.rc" ] && [ -e "$root/slotd.rc" ]'
out="$(cat "$root/slotc.out" "$root/slotd.out" 2>/dev/null)"
check "18 unset: one run at a time, in slot 1" $([ "$(cat "$root/slotc.rc")" = 0 ] && [ "$(cat "$root/slotd.rc")" = 0 ] \
  && ! overlap side "$C" "$D" && [ "$(cut -d' ' -f2 "$marks/side.$C")" = 1 ] && [ "$(cut -d' ' -f2 "$marks/side.$D")" = 1 ]; echo $?)
CI_LOCAL_SLOTS=0 run --jobs side "${two[0]}"
check "18 CI_LOCAL_SLOTS must be 1 or more" $([ "$rc" -eq 2 ] && grep -q "CI_LOCAL_SLOTS must be a whole number" <<<"$out"; echo $?)

echo "ci-local tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
