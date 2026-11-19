#!/usr/bin/env bash
# Tests for .archon/scripts/recover-run.sh with the classify-failure corpus and stub scripts: each step it performs
# (resume, sync-relaunch, local CI on the head and on main, waits, rebase-and-resume and its refusals, cleanup-merged,
# tdd-shape-fix, park, ask), what it records, the pings (once, and a missing notifier never fails it), and --dry-run.
# Usage: bash .archon/scripts/test/recover-run.test.sh   (exit 0 = all pass)
set -uo pipefail
# The scripts' defaults, not the checkout's .archon/kit.yaml (an install's build_workflow differs).
export KIT_CONFIG=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../recover-run.sh"
fx="$here/fixtures/classify"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out=""
NOW=2026-10-20T12:00:00Z

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# Stubs: every script and archon log "<name> <args>" to $CASE/log and exit with $CASE/<name>.rc (default 0).
mkdir -p "$root/stubs"
for s in sync-main.sh rebase-and-resume.sh cleanup-merged.sh park-ticket.sh notify-owner.sh tdd-shape-fix.sh red-triage.sh ci-local.sh archon; do
  cat > "$root/stubs/$s" <<EOF
#!/usr/bin/env bash
echo "$s \$*" >> "\$CASE/log"
[ -f "\$CASE/$s.out" ] && cat "\$CASE/$s.out"
exit \$(cat "\$CASE/$s.rc" 2>/dev/null || echo 0)
EOF
  chmod +x "$root/stubs/$s"
done
export ARCHON="$root/stubs/archon" CI_LOCAL="$root/stubs/ci-local.sh"

# fresh <name> [state dir]: a case folder with its own scripts dir (a copy of the stubs), recovery state and main.
fresh() {
  export CASE="$root/$1"; mkdir -p "$CASE/scripts" "$CASE/main"
  cp "$root/stubs/"*.sh "$CASE/scripts/"; rm -f "$CASE/scripts/ci-local.sh"
  export RECOVER_SCRIPTS_DIR="$CASE/scripts" RECOVER_MAIN="$CASE/main" RECOVERY_DIR="$CASE/recovery"
  mkdir -p "$RECOVERY_DIR"; [ -z "${2:-}" ] || cp -r "$fx/$2/." "$RECOVERY_DIR/"
  : > "$CASE/log"
}
rr() { # rr <run fixture> <facts> [more args]: sets out (stdout), err, rc
  local f=$1 facts=$2; shift 2
  out=$(bash "$script" "$(jq -r '.id' "$fx/$f" 2>/dev/null || echo x)" --json-file "$fx/$f" --facts-file "$fx/$facts" --now "$NOW" "$@" 2>"$CASE/err"); rc=$?
}
f() { jq -r ".$1 // \"-\"" <<< "$out" 2>/dev/null; }
logged() { grep -qE "$1" "$CASE/log"; }
history() { node "$here/../recovery-state.js" show "$1" | jq -r '.history | length'; }
idof() { jq -r .id "$fx/$1"; }

# S07: resume. Recorded, archon resume --detach, result set.
fresh s07
rr run-078ca850.json facts-none.json
check "S07 exit 0, resumed" $([ "$rc" -eq 0 ] && [ "$(f result)" = resumed ] && [ "$(f done)" = true ]; echo $?)
check "S07 archon resume --detach" $(logged "^archon workflow resume --detach $(idof run-078ca850.json)$"; echo $?)
check "S07 recorded with its result" $([ "$(history "$(idof run-078ca850.json)")" = 1 ] && node "$here/../recovery-state.js" show "$(idof run-078ca850.json)" | jq -e '.history[0].result == "resumed"' >/dev/null; echo $?)
check "S07 one JSON line" $([ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && jq -e . <<< "$out" >/dev/null; echo $?)
check "S07 never launches" $(! logged '^archon workflow run'; echo $?)
echo 1 > "$CASE/archon.rc"
rr run-078ca850.json facts-none.json
check "S07 again with nothing changed parks (budget), no resume" $([ "$rc" -eq 0 ] && [ "$(f action)" = park ] && [ "$(grep -c 'workflow resume' "$CASE/log")" = 1 ]; echo $?)
check "S07 park through park-ticket.sh --no-commit" $(logged '^park-ticket.sh TASK-[0-9.]+ -m .* --run .* --no-commit'; echo $?)

# A failed resume: exit 1.
fresh s07fail; echo 1 > "$CASE/archon.rc"
rr run-078ca850.json facts-none.json
check "a failed resume: exit 1" $([ "$rc" -eq 1 ] && [[ "$(f result)" == failed* ]]; echo $?)

# S04: before its not_before, wait without a record; after it, resume.
fresh s04
rr syn-s04-overloaded.json facts-head-green.json
check "S04 before not_before: wait, no resume, no record" $([ "$rc" -eq 0 ] && [[ "$(f result)" == wait* ]] && ! logged 'workflow resume' && [ ! -e "$RECOVERY_DIR/runs/$(idof syn-s04-overloaded.json).json" ]; echo $?)
out=$(bash "$script" x --json-file "$fx/syn-s04-overloaded.json" --facts-file "$fx/facts-head-green.json" --now 2026-10-20T12:05:00Z 2>/dev/null); rc=$?
check "S04 after not_before: resumed" $([ "$rc" -eq 0 ] && [ "$(f result)" = resumed ] && logged 'workflow resume --detach x$'; echo $?)

# S01: sync-main in the main checkout, then a launch (archon workflow run, no launch-run.sh).
fresh s01
rr run-ac692960.json facts-none.json
check "S01 exit 0" $([ "$rc" -eq 0 ] && [ "$(f done)" = true ]; echo $?)
check "S01 sync-main, then a launch of the ticket" $(logged '^sync-main.sh' && logged '^archon workflow run build-feature --detach Build TASK-'; echo $?)
fresh s01launch; printf '#!/usr/bin/env bash\necho "launch-run.sh $*" >> "$CASE/log"\n' > "$CASE/scripts/launch-run.sh"
rr run-ac692960.json facts-none.json
check "S01 launch-run.sh when it exists" $(logged '^launch-run.sh TASK-' && ! logged 'workflow run'; echo $?)
fresh s01refused; echo 1 > "$CASE/sync-main.sh.rc"
rr run-ac692960.json facts-none.json
check "S01 sync-main refused: ask, exit 3, no launch" $([ "$rc" -eq 3 ] && ! logged 'workflow run'; echo $?)

# S05: no CI on the head starts local CI on the pull request, in the background; pending waits; then resume.
fresh s05
rr run-1341a8c0.json facts-head-none.json
for _ in 1 2 3 4 5 6 7 8 9 10; do logged '^ci-local.sh' && break; sleep 0.2; done
check "S05 ci-local.sh --post <pr number>" $([ "$rc" -eq 0 ] && logged '^ci-local.sh --post [0-9]+$'; echo $?)
check "S05 says wait" $([[ "$(f result)" == wait* ]]; echo $?)
rr run-1341a8c0.json facts-head-pending.json
check "S05 pending: wait, nothing run" $([ "$rc" -eq 0 ] && [[ "$(f result)" == wait* ]] && [ "$(grep -c ci-local "$CASE/log")" = 1 ]; echo $?)
rr run-1341a8c0.json facts-head-green.json
check "S05 green: resumed (the token changed)" $([ "$rc" -eq 0 ] && [ "$(f result)" = resumed ]; echo $?)

# S18: local CI on main-ci's sha.
fresh s18
rr run-4b33311d.json facts-none.json
for _ in 1 2 3 4 5 6 7 8 9 10; do logged '^ci-local.sh' && break; sleep 0.2; done
check "S18 ci-local.sh --post <merge sha>" $([ "$rc" -eq 0 ] && logged '^ci-local.sh --post 7b1cbbaa536aeb88f4dff007b4840be1921ac8c3$'; echo $?)

fresh s18done; export RECOVER_REPO=o/r
printf '#!/usr/bin/env bash\necho "local-ci-status.sh $*" >> "$CASE/log"; echo "green all jobs"\n' > "$CASE/scripts/local-ci-status.sh"
rr run-4b33311d.json facts-none.json
check "S18 local CI already green on the sha: no second run" $([ "$rc" -eq 0 ] && logged '^local-ci-status.sh o/r 7b1cbbaa' && ! logged '^ci-local.sh' && f result | grep -q 'already green'; echo $?)
unset RECOVER_REPO

# S13: main red waits (no record); the ping goes once main stayed red over 30 min, and only once.
fresh s13
rr syn-s13-red-from-main.json facts-main-red-overlap.json
check "S13 waits, no rebase" $([ "$rc" -eq 0 ] && [[ "$(f result)" == wait* ]] && ! logged rebase-and-resume; echo $?)
out=$(bash "$script" x --json-file "$fx/syn-s13-red-from-main.json" --facts-file "$fx/facts-main-red-overlap.json" --now 2026-10-20T13:00:00Z 2>/dev/null)
out=$(bash "$script" x --json-file "$fx/syn-s13-red-from-main.json" --facts-file "$fx/facts-main-red-overlap.json" --now 2026-10-20T13:05:00Z 2>/dev/null)
check "S13 red over 30 min pings once" $([ "$(grep -c '^notify-owner.sh warn' "$CASE/log")" = 1 ]; echo $?)

# S12: rebase-and-resume with the signature; its conflict and YAML drift ask.
fresh s12
rr syn-s12-nonff.json facts-head-green.json
check "S12 rebase-and-resume.sh <run> --signature S12" $([ "$rc" -eq 0 ] && logged '^rebase-and-resume.sh .* --signature S12$' && [ "$(f done)" = true ]; echo $?)
fresh s12c; echo 3 > "$CASE/rebase-and-resume.sh.rc"
rr syn-s12-nonff.json facts-head-green.json
check "S12 conflict: ask, exit 3, owner pinged" $([ "$rc" -eq 3 ] && [ "$(f action)" = ask ] && logged '^notify-owner.sh act'; echo $?)
# YAML drift (owner decision 2026-10-23, TASK-7.3): once per run, rebase and resume with the launch YAML kept; a drift
# that flag does not cover, or a second one, asks.
fresh s12d; echo 4 > "$CASE/rebase-and-resume.sh.rc"
cat > "$CASE/scripts/rebase-and-resume.sh" <<'EOF2'
#!/usr/bin/env bash
echo "rebase-and-resume.sh $*" >> "$CASE/log"
case " $* " in *" --keep-launch-yaml "*) exit 0 ;; esac
exit 4
EOF2
rr syn-s12-nonff.json facts-head-green.json
check "S12 YAML drift: rebase and resume with the launch YAML" $([ "$rc" -eq 0 ] && logged '^rebase-and-resume.sh .* --keep-launch-yaml$' && f result | grep -q 'launch YAML' && ! logged 'workflow run'; echo $?)
fresh s13d
cp "$root/s12d/scripts/rebase-and-resume.sh" "$CASE/scripts/"
rr syn-s13-red-from-main.json facts-head-green.json; rr syn-s13-red-from-main.json facts-main-green-head-red.json
check "S13 YAML drift a second time in one run: ask, exit 3" $([ "$rc" -eq 3 ] && [ "$(grep -c -- '--keep-launch-yaml' "$CASE/log")" = 1 ]; echo $?)
fresh s12e; echo 4 > "$CASE/rebase-and-resume.sh.rc"
rr syn-s12-nonff.json facts-head-green.json
check "S12 drift the flag does not cover: ask, exit 3, never a launch" $([ "$rc" -eq 3 ] && f result | grep -q 'new run' && ! logged 'workflow run'; echo $?)

# S16: cleanup-merged with the run's branch and worktree; commit-tickets is only named, never run.
fresh s16
git init -q -b build-feature-7 "$CASE/wt"
jq --arg wt "$CASE/wt" '.working_path = $wt' "$fx/run-007d0b6e.json" > "$CASE/run.json"
out=$(bash "$script" x --json-file "$CASE/run.json" --facts-file "$fx/facts-none.json" --now "$NOW" 2>/dev/null); rc=$?
check "S16 cleanup-merged.sh <branch> <worktree>" $([ "$rc" -eq 0 ] && logged "^cleanup-merged.sh build-feature-7 $CASE/wt$"; echo $?)
check "S16 names commit-tickets in next, never runs it" $(f next | grep -q commit-tickets && ! logged commit-tickets; echo $?)
echo 1 > "$CASE/cleanup-merged.sh.rc"; rm -rf "$RECOVERY_DIR"
out=$(bash "$script" x --json-file "$CASE/run.json" --facts-file "$fx/facts-none.json" --now "$NOW" 2>/dev/null); rc=$?
check "S16 cleanup refused: ask" $([ "$rc" -eq 3 ]; echo $?)

# S09: the shape fix when it exists, else park.
fresh s09
rr run-7580dcb2.json facts-none.json
check "S09 tdd-shape-fix.sh <run>" $([ "$rc" -eq 0 ] && logged '^tdd-shape-fix.sh '; echo $?)
fresh s09none; rm "$CASE/scripts/tdd-shape-fix.sh"
rr run-7580dcb2.json facts-none.json
check "S09 no shape fix: parked" $([ "$rc" -eq 0 ] && logged '^park-ticket.sh' && [ "$(node "$here/../recovery-state.js" show "$(idof run-7580dcb2.json)" | jq -r .parked)" = true ]; echo $?)

# S10: park and ping now; park-ticket.sh missing asks; park-ticket exit 3 (commit failed) still parks.
fresh s10
rr run-51cdbaf1.json facts-none.json
check "S10 parked, owner pinged" $([ "$rc" -eq 0 ] && logged '^park-ticket.sh' && logged '^notify-owner.sh warn'; echo $?)
check "S10 next names commit-tickets" $(f next | grep -q commit-tickets; echo $?)
fresh s10nopark; rm "$CASE/scripts/park-ticket.sh"
rr run-51cdbaf1.json facts-none.json
check "S10 without park-ticket.sh: ask" $([ "$rc" -eq 3 ]; echo $?)
fresh s10three; echo 3 > "$CASE/park-ticket.sh.rc"
rr run-51cdbaf1.json facts-none.json
check "S10 park-ticket exit 3 still parks" $([ "$rc" -eq 0 ] && [ "$(f done)" = true ]; echo $?)

# The 2026-10-23 cases. S21: GitHub still shows an older head; pushed, the resume waits 10 min; never pushed, or a
# closed pull request, asks with its own step name, about the pull request.
fresh s21; rr syn-s21-github-head.json facts-head-stale.json --now 2026-10-20T12:10:00Z
check "S21 pushed: resumed" $([ "$rc" -eq 0 ] && [ "$(f result)" = resumed ]; echo $?)
fresh s21w; rr syn-s21-github-head.json facts-head-stale.json
check "S21 pushed: waits until 10 min after the end" $([ "$rc" -eq 0 ] && [[ "$(f result)" == wait* ]] && ! logged 'workflow resume'; echo $?)
fresh s21u; rr syn-s21-github-head.json facts-head-unpushed.json
check "S21 unpushed: ask push-head, about the pull request" $([ "$rc" -eq 3 ] && logged '^notify-owner.sh act recover-[^ ]+-S21-push-head .* --about pr:7$' && ! logged 'workflow resume'; echo $?)
fresh s21c; rr syn-s21-github-head.json facts-head-pr-closed.json
check "S21 closed pull request: ask reopen-pr" $([ "$rc" -eq 3 ] && logged 'S21 reopen-pr: needs you'; echo $?)
# S22: a red head with no fix commit is triaged first (a flake gets its one rerun), in the background.
fresh s22; rr syn-s22-no-commit.json facts-pr-head-red.json
check "S22 red head: red-triage started on the head, wait" $([ "$rc" -eq 0 ] && [[ "$(f result)" == wait* ]] && sleep 1 && logged '^red-triage.sh --pr 7 1111111111111111111111111111111111111111$'; echo $?)
rr syn-s22-no-commit.json facts-pr-head-red.json
check "S22 still red after its triage: parked" $([ "$rc" -eq 0 ] && [ "$(f action)" = park ] && logged '^park-ticket.sh'; echo $?)
fresh s22g; rr syn-s22-no-commit.json facts-pr-head-green.json
check "S22 green after the rerun: resumed" $([ "$rc" -eq 0 ] && [ "$(f result)" = resumed ]; echo $?)
# S23: a fold skill-check cannot see asks for its fold markers; S24: main-ci red after the merge waits without a ping.
fresh s23; rr syn-s23-skill-fold.json facts-blocked-stale.json
check "S23 fold: ask fold-markers, never answer-blocked" $([ "$rc" -eq 3 ] && logged 'S23 fold-markers: needs you'; echo $?)
fresh s24; rr syn-s24-main-ci.json facts-merged-main-red.json --now 2026-10-20T12:40:00Z
check "S24 main red: wait, no ping" $([ "$rc" -eq 0 ] && [[ "$(f result)" == wait* ]] && ! logged '^notify-owner.sh'; echo $?)
fresh s24g; rr syn-s24-main-ci.json facts-head-green.json
check "S24 main green: resumed" $([ "$rc" -eq 0 ] && [ "$(f result)" = resumed ]; echo $?)

# S20 and S17 and S02 ask; S03 and S19 do nothing.
fresh s20
rr run-9297a329.json facts-none.json
check "S20 unknown: ask, exit 3, act ping" $([ "$rc" -eq 3 ] && logged '^notify-owner.sh act recover-'; echo $?)
fresh s17; rr run-1846c634.json facts-none.json
check "S17 held ticket: ask" $([ "$rc" -eq 3 ]; echo $?)
fresh s02; rr syn-s02-launch.json facts-none.json
check "S02 launch failed: ask, nothing launched" $([ "$rc" -eq 3 ] && ! logged 'workflow run'; echo $?)
fresh s03; rr run-69ebad90.json facts-none.json
check "S03 cancelled: nothing, exit 0" $([ "$rc" -eq 0 ] && [ "$(f action)" = none ] && ! grep -qv '^$' "$CASE/log"; echo $?)
fresh s19; rr run-725f38f6.json facts-none.json
check "S19 clean: nothing, exit 0" $([ "$rc" -eq 0 ] && [ "$(f done)" = true ]; echo $?)

# The breaker: open turns a resume into ask.
fresh open state-open
rr run-078ca850.json facts-none.json
check "breaker open: S07 asks, no resume" $([ "$rc" -eq 3 ] && ! logged 'workflow resume'; echo $?)

# Pings: a missing notifier or a failing one never fails the script; one ping per run, signature and step.
fresh noping; rm "$CASE/scripts/notify-owner.sh"
rr run-9297a329.json facts-none.json
check "no notifier: still exit 3, ping not delivered" $([ "$rc" -eq 3 ] && f ping_text | grep -q 'not delivered' && grep -q 'ping not delivered' "$CASE/err"; echo $?)
fresh failping; echo 1 > "$CASE/notify-owner.sh.rc"
rr run-9297a329.json facts-none.json
check "a failing notifier: still exit 3" $([ "$rc" -eq 3 ] && f ping_text | grep -q 'not delivered'; echo $?)
fresh oneping
rr run-9297a329.json facts-none.json; rr run-9297a329.json facts-none.json
check "the same ask pings once" $([ "$(grep -c '^notify-owner.sh' "$CASE/log")" = 1 ]; echo $?)

# The ping carries only ids and fixed words: a safe key, no reason text, no script output.
fresh pingtext
rr run-51cdbaf1.json facts-none.json
line=$(grep '^notify-owner.sh' "$CASE/log" | head -1)
check "ping key holds only safe characters" $(awk '{print $3}' <<< "$line" | grep -qE '^recover-[A-Za-z0-9._-]+$'; echo $?)
check "ping subject is ids and a fixed phrase only" $(grep -qE '^notify-owner.sh warn recover-[^ ]+ Run [0-9a-f]{8} TASK-[0-9.]+ S10 park: parked$' <<< "$line"; echo $?)
check "the reason stays out of the ping, in the log" $(! grep -q 'person judges' <<< "$line" && grep -q 'person judges' "$CASE/err"; echo $?)
fresh oddstep
jq '.user_message = "Build TASK-1; rm -rf x"' "$fx/run-9297a329.json" > "$CASE/run.json"
out=$(bash "$script" x --json-file "$CASE/run.json" --facts-file "$fx/facts-none.json" --now "$NOW" 2>/dev/null)
line=$(grep '^notify-owner.sh' "$CASE/log" | head -1)
check "an odd ticket text never reaches the ping" $(! grep -q 'rm -rf' <<< "$line"; echo $?)

# --dry-run: says what it would do; nothing recorded, run or pinged.
for c in "run-078ca850.json facts-none.json" "run-51cdbaf1.json facts-none.json" "run-9297a329.json facts-none.json" \
         "run-ac692960.json facts-none.json" "run-1341a8c0.json facts-head-none.json"; do
  fresh "dry-${c%%.*}"
  rr $c --dry-run
  check "dry run $c: would, nothing run or recorded" $([[ "$(f result)" == "dry run: would"* ]] && [ ! -s "$CASE/log" ] && [ -z "$(ls -A "$RECOVERY_DIR")" ]; echo $?)
done

# No home path leaks into the output.
fresh redact; rr run-007d0b6e.json facts-none.json
check "no home path in the output" $(! grep -qE '/home/|Users' <<< "$out"; echo $?)

# Usage and read errors.
out=$(bash "$script" 2>&1); rc=$?; check "no run id: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(bash "$script" x --bogus 2>&1); rc=$?; check "unknown option: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(bash "$script" 'x;y' 2>&1); rc=$?; check "a shell character in the run id: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(bash "$script" x --json-file "$root/missing.json" 2>&1); rc=$?; check "unreadable run: exit 1" $([ "$rc" -eq 1 ]; echo $?)

echo "recover-run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
