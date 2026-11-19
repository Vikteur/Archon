#!/usr/bin/env bash
# Tests for .archon/scripts/local-ci-status.sh against a throwaway repo and a stubbed gh.
# Usage: bash .archon/scripts/test/local-ci-status.test.sh   (exit 0 = all pass)
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/local-ci-status.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

# gh answers: the statuses call reads $STATUS_DIR/<sha> (the first file whose name starts with the asked ref), one status
# a line "<updated_at>|<id>|<context>|<state>|<description>", turns it into GitHub's JSON and applies the script's -q
# filter with jq; it fails for a ref in GH_FAIL. The contents call prints the file STUB_WORKFLOW (GitHub's copy of the
# commit's ci.yml), or fails when it is unset.
mkdir -p "$root/bin" "$root/st"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
q=""; prev=""
for a in "$@"; do [ "$prev" = -q ] && q=$a; prev=$a; done
case "$*" in
  *"/contents/"*) [ -n "${STUB_WORKFLOW:-}" ] && cat "$STUB_WORKFLOW" && exit 0; exit 1 ;;
  *"/statuses"*)
    ref=$(printf '%s' "$*" | sed -E 's#.*commits/([^/]+)/statuses.*#\1#')
    case " ${GH_FAIL:-} " in *" $ref "*) exit 1 ;; esac
    f=$(ls "$STATUS_DIR/$ref"* 2>/dev/null | head -1)
    jq -R -s 'split("\n") | map(select(length > 0) | split("|")
      | { updated_at: .[0], id: (.[1] | tonumber), context: .[2], state: .[3], description: .[4] })' "${f:-/dev/null}" \
      | jq -r "$q"
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$root/bin/gh"
# The queue: `state <sha>` prints $QUEUE_STATE (default a running entry) and logs the call; QUEUE_STATE=fail fails.
cat > "$root/queue.sh" <<'STUB'
echo "queue $*" >> "$GH_LOG"
[ "${QUEUE_STATE:-}" = fail ] && exit 1
echo "${QUEUE_STATE:-running #1 pid 1}"
STUB

# The checkout: main's ci.yml has the jobs build and lint. commit <name> <jobs...>: a commit on a side branch whose
# ci.yml has those jobs; sets sha. The checkout stays on main, as a main checkout does.
dir="$root/repo"; log="$root/gh.log"
git init -q -b main "$dir"
git -C "$dir" config user.name t; git -C "$dir" config user.email t@t
workflow() { printf 'jobs:\n'; for j in "$@"; do printf '  %s:\n    runs-on: x\n' "$j"; done; }
mkdir -p "$dir/.github/workflows"; workflow build lint > "$dir/.github/workflows/ci.yml"
git -C "$dir" add -A; git -C "$dir" commit -qm main
commit() {
  git -C "$dir" switch -qc "$1" main
  workflow "${@:2}" > "$dir/.github/workflows/ci.yml"
  git -C "$dir" commit -qam "$1"; sha=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" switch -q main
}
id=0
st() { # st <sha> <hh:mm> <job> <state> [<description>]: one status posted on <sha> at that time
  id=$((id+1)); printf '2026-10-20T%s:00Z|%s|local-ci/%s|%s|%s\n' "$2" "$id" "$3" "$4" "${5:-}" >> "$root/st/$1"
}
ran() { st "$1" "$2" "$3" success "success in 21s on host${4:+; fp=$4}"; }   # ran <sha> <hh:mm> <job> [<fp>]
reuse() { st "$1" "$2" "$3" success "reused from $4; fp=$5; scope=abc1234"; } # reuse <sha> <hh:mm> <job> <src12> <fp>
fpT=1111111111 fpL=2222222222 fpO=3333333333
clear() { rm -f "$root/st/"*; }
run() { # run <sha> [env...]: the script inside the checkout; sets out, rc
  : > "$log"
  out=$(cd "$dir" && env PATH="$root/bin:$PATH" GH_LOG="$log" STATUS_DIR="$root/st" CI_QUEUE="$root/queue.sh" "${@:2}" bash "$script" o/repo "$1" 2>&1); rc=$?
}
check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# 1. A head that renames build to test is held to its own jobs: green on test and lint, though main has build.
commit renamed test lint; renamed=$sha
ran "$renamed" 10:00 test; ran "$renamed" 10:00 lint
run "$renamed"
check "1 renamed job green" $([ "$out" = "green every job of ci.yml passed locally" ]; echo $?)
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)

# 2. The old name of the renamed job is not required of that head, and its own new name still is.
clear; ran "$renamed" 10:00 build; ran "$renamed" 10:00 lint
run "$renamed"
check "2 the new name is required" $([ "$out" = "pending local-ci/test=missing" ]; echo $?)

# 3. A head that adds a job with no status yet is pending for that job.
commit added build lint e2e; added=$sha
ran "$added" 10:00 build; ran "$added" 10:00 lint
run "$added"
check "3 added job pending" $([ "$out" = "pending local-ci/e2e=missing" ]; echo $?)

# 4. A head that removes a job no longer needs it.
commit removed build
ran "$sha" 10:00 build
run "$sha"
check "4 removed job not required" $(echo "$out" | grep -q '^green'; echo $?)

# 5. A failed job of the head is red.
clear; st "$renamed" 10:00 test failure "failure in 30s on host"; ran "$renamed" 10:00 lint
run "$renamed"
check "5 red" $([ "$out" = "red local-ci/test=failure" ]; echo $?)

# 6. A head the clone does not have is read from GitHub, at that commit.
missing=0123456789abcdef0123456789abcdef01234567
workflow test lint > "$root/remote-ci.yml"
ran "$missing" 10:00 test; ran "$missing" 10:00 lint
run "$missing" STUB_WORKFLOW="$root/remote-ci.yml"
check "6 green from GitHub's copy" $(echo "$out" | grep -q '^green'; echo $?)
check "6 asked GitHub at the commit" $(grep -q "contents/.github/workflows/ci.yml?ref=$missing" "$log"; echo $?)

# 7. A head whose workflow neither the clone nor GitHub has stays pending, never green.
run "$missing"
check "7 unreadable workflow pending" $(echo "$out" | grep -q "^pending cannot read the jobs of .github/workflows/ci.yml at 0123456"; echo $?)

# 8. LOCAL_CI_WORKFLOW still names the workflow outright.
workflow only > "$root/override.yml"
clear; ran "$renamed" 10:00 only
run "$renamed" LOCAL_CI_WORKFLOW="$root/override.yml"
check "8 override wins" $([ "$out" = "green every job of override.yml passed locally" ]; echo $?)

# 9. No local-ci status on the commit: none.
clear; run "$renamed" QUEUE_STATE=none
check "9 none" $([ "$out" = "none no local-ci status on $renamed" ]; echo $?)

# 10. There is no off switch any more (D14, D21): LOCAL_CI=off and a past LOCAL_CI_UNTIL change nothing.
st "$renamed" 10:00 test failure "failure in 30s on host"; ran "$renamed" 10:00 lint
run "$renamed" LOCAL_CI=off LOCAL_CI_UNTIL=2026-01-01
check "10 no off switch: still red" $([ "$out" = "red local-ci/test=failure" ]; echo $?)

# 11. GitHub not answering for the commit is pending.
run "$renamed" GH_FAIL="$renamed"
check "11 gh failure pending" $(echo "$out" | grep -q "^pending GitHub did not answer"; echo $?)

# 12. The legacy ran form (no fp, a skipped-steps suffix) and the new ran form with an fp both pass.
clear; st "$renamed" 10:00 test success "success in 5s on host, 2 step(s) skipped locally"
ran "$renamed" 10:00 lint 1a2b3c4d5e
run "$renamed"
check "12 legacy and new ran forms green" $(echo "$out" | grep -q '^green'; echo $?)

# 13. A success the grammar does not know is red, never green: a skip must not read as a pass.
for d in "" "not required: docs only" "skipped: archon suites" "success" "reused 0123456: same inputs"; do
  clear; st "$renamed" 10:00 test success "$d"; ran "$renamed" 10:00 lint
  run "$renamed"
  check "13 unknown success '$d' is red" $(echo "$out" | grep -q '^red local-ci/test=unrecognised success'; echo $?)
done

# 14. A verified reuse passes: the source's newest status in the same context ran green with the same fp.
src=$added; s12=${src:0:12}
clear; ran "$src" 09:00 test $fpT; ran "$src" 09:00 lint $fpL
reuse "$renamed" 10:00 test "$s12" "$fpT"
reuse "$renamed" 10:00 lint "$s12" "$fpL"
run "$renamed"
check "14 verified reuse green" $(echo "$out" | grep -q '^green'; echo $?)
check "14 the source is fetched once for both jobs" $([ "$(grep -c "commits/$s12/statuses" "$log")" -eq 1 ]; echo $?)

# 15. A reuse whose fp differs from the source's is red.
clear; ran "$src" 09:00 test $fpO
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "15 fp mismatch red" $(echo "$out" | grep -q "^red local-ci/test=reuse not verified: .*ran with fp=$fpO, not $fpT"; echo $?)

# 16. A source without the fp token (the legacy form can never be a source) is red.
clear; ran "$src" 09:00 test
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "16 legacy source red" $(echo "$out" | grep -q '^red local-ci/test=reuse not verified: .*fp=none'; echo $?)

# 17. A red source is red, and so is a source with no status in that context.
clear; st "$src" 09:00 test failure "failure in 3s on host; fp=$fpT"
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "17 red source red" $(echo "$out" | grep -q '^red local-ci/test=reuse not verified: .* is failure'; echo $?)
clear; ran "$src" 09:00 lint $fpT
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "17b a source without the context red" $(echo "$out" | grep -q '^red local-ci/test=reuse not verified: .*has no local-ci/test status'; echo $?)

# 18. A chain (the source is itself a reuse) is red.
third=${missing:0:12}
clear; reuse "$src" 09:00 test "$third" "$fpT"; ran "$missing" 08:00 test $fpT
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "18 chain red" $(echo "$out" | grep -q '^red local-ci/test=reuse not verified: .*itself a reuse'; echo $?)

# 19. A reuse of the commit itself is red.
clear; reuse "$renamed" 10:00 test "${renamed:0:12}" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "19 self reuse red" $(echo "$out" | grep -q '^red local-ci/test=reused from itself'; echo $?)

# 20. GitHub not answering for the source is pending, never green or red.
clear; ran "$src" 09:00 test $fpT
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed" GH_FAIL="$s12"
check "20 unreadable source pending" $(echo "$out" | grep -q '^pending local-ci/test=pending'; echo $?)

# 21. The source's newest status counts: a green run that a later failure replaced is no source.
clear; ran "$src" 09:00 test $fpT; st "$src" 09:30 test failure "failure in 3s on host; fp=$fpT"
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "21 source turned red later: red" $(echo "$out" | grep -q '^red local-ci/test'; echo $?)

# 22. Only the newest status of each context counts, whatever order GitHub answers in.
clear; ran "$renamed" 10:30 test; st "$renamed" 10:00 test failure "failure in 3s on host"; ran "$renamed" 10:00 lint
run "$renamed"
check "22 an older failure under a newer run: green" $(echo "$out" | grep -q '^green'; echo $?)
clear; st "$renamed" 10:30 test failure "failure in 3s on host"; ran "$renamed" 10:00 test; ran "$renamed" 10:00 lint
run "$renamed"
check "22b a newer failure over an older run: red" $([ "$out" = "red local-ci/test=failure" ]; echo $?)
clear; ran "$renamed" 10:00 test; st "$renamed" 10:00 test pending "running on host"; ran "$renamed" 10:00 lint
run "$renamed"
check "22c same time: the higher id wins (pending)" $([ "$out" = "pending local-ci/test=pending" ]; echo $?)

# 23. Every reader goes through the grammar: a reuse without its scope, or a ran form with a stray token, is red.
clear; ran "$src" 09:00 test $fpT
st "$renamed" 10:00 test success "reused from $s12; fp=$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "23 reuse without scope: unrecognised, red" $(echo "$out" | grep -q '^red local-ci/test=unrecognised success'; echo $?)
clear; st "$renamed" 10:00 test success "success in 3s on host; not required"; ran "$renamed" 10:00 lint
run "$renamed"
check "23b ran form with a stray token: red" $(echo "$out" | grep -q '^red local-ci/test=unrecognised success'; echo $?)
clear; st "$renamed" 10:00 test success "failure in 3s on host"; ran "$renamed" 10:00 lint
run "$renamed"
check "23c a description contradicting its state: red" $(echo "$out" | grep -q '^red local-ci/test=unrecognised success'; echo $?)

# 24. D2: a reuse source posted over 24 h before the reuse is red; within 24 h it passes; CI_PLAN_MAX_AGE narrows it.
clear; st "$src" 09:00 test success "success in 21s on host; fp=$fpT"
sed -i 's/^2026-10-20T09:00/2026-10-19T09:00/' "$root/st/$src"
reuse "$renamed" 10:00 test "$s12" "$fpT"; ran "$renamed" 10:00 lint
run "$renamed"
check "24 source 25 h old: red" $(echo "$out" | grep -q '^red local-ci/test=reuse not verified: .* 25 h before the reuse, over the 24 h limit'; echo $?)
sed -i 's/^2026-10-19T09:00/2026-10-19T10:30/' "$root/st/$src"
run "$renamed"
check "24b source 23.5 h old: green" $(echo "$out" | grep -q '^green'; echo $?)
run "$renamed" CI_PLAN_MAX_AGE=3600
check "24c CI_PLAN_MAX_AGE=3600: red" $(echo "$out" | grep -q '^red local-ci/test=reuse not verified: .*over the 1 h limit'; echo $?)

# 25. A superseded commit gets no verdict: state superseded, naming the new head; a real failure still beats it.
clear; st "$renamed" 10:00 test error "superseded: PR #7 head is now abcdef1, not run"
st "$renamed" 10:00 lint error "superseded: PR #7 head is now abcdef1, not run"
run "$renamed"
check "25 superseded" $(echo "$out" | grep -q '^superseded local-ci/test=PR #7 head is now abcdef1 local-ci/lint=PR #7 head is now abcdef1; ask about the new head'; echo $?)
st "$renamed" 10:01 lint failure "failure in 3s on host"
run "$renamed"
check "25b a failure beats superseded" $([ "$out" = "red local-ci/lint=failure" ]; echo $?)
clear; st "$renamed" 10:00 test error "cancelled: test failed first, not a pass"; ran "$renamed" 10:00 lint
run "$renamed"
check "25c a cancelled job is red" $([ "$out" = "red local-ci/test=error" ]; echo $?)

# 26. A pending status of this host with no live run in the queue is stale, after one more read; with a live run, or a
# pending status of another host, or a queue that cannot be asked, it stays pending.
me=$(hostname)
clear; st "$renamed" 10:00 test pending "running since 10:00, pid 4242@$me"; ran "$renamed" 10:00 lint
run "$renamed" QUEUE_STATE="stale #3 pid 4242"
check "26 dead run: stale" $(echo "$out" | grep -q "^stale local-ci/test=pending; no live local CI run of ${renamed:0:7} (queue: stale #3 pid 4242): run it again"; echo $?)
check "26 the statuses were read twice" $([ "$(grep -c "commits/$renamed/statuses" "$log")" -eq 2 ]; echo $?)
check "26 the queue was asked for the full sha" $(grep -q "queue state $renamed" "$log"; echo $?)
run "$renamed" QUEUE_STATE=none
check "26b ended run: stale" $(echo "$out" | grep -q '^stale'; echo $?)
run "$renamed"
check "26c live run: pending" $([ "$out" = "pending local-ci/test=pending" ]; echo $?)
run "$renamed" QUEUE_STATE=fail
check "26d queue unreadable: pending" $([ "$out" = "pending local-ci/test=pending" ]; echo $?)
clear; st "$renamed" 10:00 test pending "queued #2 pos 1 since 10:00, pid 4242@otherbox"; ran "$renamed" 10:00 lint
run "$renamed" QUEUE_STATE=none
check "26e another host's run: pending" $([ "$out" = "pending local-ci/test=pending" ]; echo $?)
clear; ran "$renamed" 10:00 lint
run "$renamed" QUEUE_STATE=none
check "26f a job no live run will post: stale" $(echo "$out" | grep -q '^stale local-ci/test=missing'; echo $?)

# 27. No status yet while the queue has a live run of the commit: pending, not none.
clear; run "$renamed" QUEUE_STATE="queued #5 pos 2 pid 99"
check "27 queued, nothing posted: pending" $(echo "$out" | grep -q "^pending no local-ci status on $renamed yet; local CI of it is queued #5 pos 2"; echo $?)
run "$renamed" QUEUE_STATE="stale #5 pid 99"
check "27b stale, nothing posted: none" $([ "$out" = "none no local-ci status on $renamed" ]; echo $?)

# 28. Without the grammar no success can be accepted: red, said plainly.
ran "$renamed" 10:00 test; ran "$renamed" 10:00 lint
run "$renamed" CI_STATUS_GRAMMAR="$root/nope.sh"
check "28 grammar missing: red" $(echo "$out" | grep -q '^red the status grammar .*nope.sh cannot be read'; echo $?)

# 29. A main commit that changes only backlog/, docs/retro/ or docs/tokenomics/ runs no CI (owner decisions 2026-10-22,
# 2026-10-23): its
# verdict is the newest commit under it that changes anything else, named in the detail. A commit that also changes
# anything else, or one that is not on origin/main, is read as itself.
git init -q --bare "$root/origin.git"; git -C "$dir" remote add origin "$root/origin.git"
on_main() { # on_main <name> <file>...: a commit on main changing those files; sets sha
  local f; for f in "${@:2}"; do mkdir -p "$dir/$(dirname "$f")"; echo "$1" >> "$dir/$f"; done
  git -C "$dir" add -A; git -C "$dir" commit -qm "$1"; sha=$(git -C "$dir" rev-parse HEAD)
}
on_main code src/App.java; code=$sha
on_main retro docs/retro/TASK-9/lessons-learned.md; retro=$sha
on_main tokens docs/tokenomics/daily-token-reports/2026-10-22.md; tokens=$sha
git -C "$dir" push -q origin main
clear; st "$code" 10:00 build failure "failure in 30s on host"; ran "$code" 10:00 lint
run "$retro"
check "29 a retro-only tip over a red code commit is red" $(echo "$out" | grep -q "^red .*(the verdict of ${code:0:7}: ${retro:0:7} changes only backlog/ docs/retro/ docs/tokenomics/ and runs no CI)$"; echo $?)
run "$tokens"
check "29 a token-report tip over a retro over a red code commit is red" $(echo "$out" | grep -q "^red .*(the verdict of ${code:0:7}: ${tokens:0:7} changes only"; echo $?)
clear; ran "$code" 10:00 build; ran "$code" 10:00 lint
run "$tokens"
check "29 the same tip over a green code commit is green" $([ "$out" = "green every job of ci.yml passed locally (the verdict of ${code:0:7}: ${tokens:0:7} changes only backlog/ docs/retro/ docs/tokenomics/ and runs no CI)" ]; echo $?)
on_main mixed docs/retro/TASK-9/lessons-learned.md src/App.java; mixed=$sha; git -C "$dir" push -q origin main
run "$mixed" QUEUE_STATE="stale #5 pid 99"
check "29 a retro plus code commit is read as itself" $([ "$out" = "none no local-ci status on $mixed" ]; echo $?)
on_main ticket "backlog/tasks/task-9 - x.md"; ticket=$sha; git -C "$dir" push -q origin main
clear; ran "$mixed" 10:00 build; ran "$mixed" 10:00 lint
run "$ticket"
check "29 a ticket-only tip over a green code commit is green" $([ "$out" = "green every job of ci.yml passed locally (the verdict of ${mixed:0:7}: ${ticket:0:7} changes only backlog/ docs/retro/ docs/tokenomics/ and runs no CI)" ]; echo $?)
git -C "$dir" switch -qc side main; on_main side docs/retro/side.md; side=$sha; git -C "$dir" switch -q main
run "$side" QUEUE_STATE="stale #5 pid 99" GIT_TERMINAL_PROMPT=0
check "29 a retro-only commit that is not on origin/main is read as itself" $([ "$out" = "none no local-ci status on $side" ]; echo $?)

# 30. Same tree (owner decision 2026-10-23): a merge commit's `reused from <head sha12>; same tree` passes when that head
# is its second parent and ran green there in the same context; a red or reused source, or a source that is not the
# second parent, is red; a commit with no second parent is red.
git -C "$dir" switch -qc samehead main; echo head > "$dir/head"; git -C "$dir" add -A; git -C "$dir" commit -qm samehead
head=$(git -C "$dir" rev-parse HEAD); h12=${head:0:12}; git -C "$dir" switch -q main
git -C "$dir" merge -q --no-ff --no-edit samehead; merge=$(git -C "$dir" rev-parse HEAD)
same() { st "$merge" 10:00 "$1" success "reused from $2; same tree"; } # same <job> <src12>
clear; ran "$head" 09:00 build $fpT; ran "$head" 09:00 lint $fpL; same build "$h12"; same lint "$h12"
run "$merge"
check "30 same tree, green head: green" $(echo "$out" | grep -q '^green'; echo $?)
clear; ran "$head" 09:00 build $fpT; st "$head" 09:00 lint failure "failure in 9s on host"; same build "$h12"; same lint "$h12"
run "$merge"
check "30 a red job on the head: red" $(echo "$out" | grep -q '^red local-ci/lint=reuse not verified'; echo $?)
clear; ran "$head" 09:00 build $fpT; reuse "$head" 09:00 lint "$s12" "$fpL"; same build "$h12"; same lint "$h12"
run "$merge"
check "30 a reused job on the head is no source: red" $(echo "$out" | grep -q '^red local-ci/lint=reuse not verified'; echo $?)
clear; ran "$src" 09:00 build $fpT; ran "$src" 09:00 lint $fpL; same build "$s12"; same lint "$s12"
run "$merge"
check "30 a source that is not the second parent: red" $(echo "$out" | grep -q 'is not the second parent'; echo $?)
clear; ran "$head" 09:00 build $fpT; ran "$head" 09:00 lint $fpL
st "$head" 10:00 build success "reused from $h12; same tree"; st "$head" 10:00 lint success "reused from $h12; same tree"
run "$head"
check "30 same tree on a commit that is no merge: red" $(echo "$out" | grep -q 'is not a merge commit'; echo $?)

echo "local-ci-status: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
