#!/usr/bin/env bash
# Test-first gate (P2): proves the branch was built tests first.
#
#   tdd-check.sh <artifacts-dir> <base-branch>
#
# Fails unless
#   - plan.md has no step left `- [ ]`;
#   - every checked step that is not done by the workflow's own nodes and not marked `(verify only)` (it adds no
#     behaviour: it only runs checks or reads/updates docs) has red/step-<n>.log (n = the step's
#     position among the plan's checkbox lines) showing a failing test run;
#   - every commit since the base that changes code comes after a commit holding only tests, written since
#     the code commit before it (a commit may change tests and code together only after such a test commit).
# Docs (*.md, and a follow-up's JSON under docs/follow-ups/) need no test, and neither does a source file whose change in the commit is comment lines only (`//`,
# `/*`, `*`, `*/` or blank: a javadoc commit). Build files (*.gradle, *.gradle.kts, gradle/libs.versions.toml, gradle.properties,
# settings.gradle*, pom.xml, package.json, package-lock.json) are a fourth class: with tests and no code they
# belong to the test commit (test dependencies); alone they are a code commit; beside code they change nothing.
#
# Further rules:
#   - a build that fails is red too (a step whose test is a `docker build`): BuildKit's `ERROR:` line counts;
#   - a red log whose only failure evidence is dependency resolution (Gradle "Could not resolve" / "Could not find
#     group:artifact", maven-resolver errors, npm ERESOLVE / 404 Not Found) is refused, naming the step; a compile
#     error in the same log still counts as red;
#   - a feat/fix/refactor commit that changes a test source file (src/test/, src/integrationTest/, src/testFixtures/,
#     *.test.sh, *.test.ts, *Test.java, *Test.kt) is reported, unless its message body has a line starting `Test fix:`
#     that says why the test was wrong;
#   - a step marked `(folded into step <k>)`, k an earlier checkbox position, was built inside step k (an answer to a
#     BLOCKED question folded it): step k's red log stands for it;
#   - a step marked `- [x] (pin only) ...` pins existing behaviour with tests that pass at once: its red log must
#     show the test failing against a mutation and hold a line starting `MUTATION:` that names what was mutated; it
#     needs no code commit after its test commit.
#   - a code commit that repairs a regression needs no new test commit when its body has a line
#     `Regression: <log>` naming a log in the artifacts dir that shows the existing tests failing (the pipeline's
#     whole-suite run); it may not change tests itself, and it does not consume a test commit.
#
# Range mode: the gate can run again later over the commits after <sha> (fix rounds after review or CI). Only the
# commit order of those commits is checked (the plan and red-log checks still run), starting with no test commit
# credited. A feat/fix commit there needs a test commit before it within the range, except one that
#   - changes no behaviour files: only docs (as above), build files (listed above) or CI config (.github/, .gitlab-ci.yml,
#     Jenkinsfile), or
#   - carries a `Test fix:` body line (the rule above).
# Such exempt commits do not count as test commits and do not consume one.
# Only the branch's own line (first parent) is walked, so commits merged in from the base are never checked. When the
# branch was rebased after that pass (<sha> is no longer an ancestor), <sha> is mapped to the rebased commit with the
# same author, author date and subject. A <sha> that merged the base in, which a rebase drops, first stands for the
# branch's own commit before it.
#
# Staged mode, for a commit-msg hook (.archon/githooks/commit-msg; owner decision D12, 2026-10-20):
#   tdd-check.sh --staged <commit message file>
# Applies only the test-file rule above (a feat/fix/refactor commit that changes a test source file needs a `Test fix:`
# body line) to the staged paths and the message, with the same file classes as the gate, so a bad commit shape is
# refused while the agent that made it is still there. The test-before-code order stays the gate's: it needs the range.
# Lines starting `#` in the message are skipped. A replay (merge, cherry-pick, revert, rebase in progress) is not
# checked: those commits were checked already. Exit 0 pass, 1 refused, 2 bad usage (no message file, not a repo).
set -euo pipefail

# comment_only <commit> <path>: every line the commit adds or removes in the path is a comment line or blank.
comment_only() {
  git diff-tree -p -U0 --no-commit-id --no-renames "$1" -- "$2" |
    grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | cut -c2- |
    grep -qvE '^[[:space:]]*($|//|/\*|\*)' && return 1
  return 0
}

# classify <path> [<commit>]: adds the path's class to the flags tests, testsrc, build, ci, code (docs set none). With a
# commit, a source file it changes in comment lines only is docs. <since> set means range mode, where CI config is its
# own class.
classify() {
  local f=$1
  if [[ "$f" =~ (^|/)src/(test|integrationTest|testFixtures)/|(^|/)tests?/|\.test\.[A-Za-z]+$|(Test|Tests|IT)\.(java|kt)$ ]]; then
    tests=1
    [[ "$f" =~ (^|/)src/(test|integrationTest|testFixtures)/|\.test\.(sh|ts)$|Test\.(java|kt)$ ]] && testsrc=1
  elif [[ "$f" == *.md || "$f" =~ (^|/)docs/follow-ups/.+\.json$ ]]; then
    :
  elif [[ "$f" =~ (^|/)(build\.gradle(\.kts)?|settings\.gradle(\.kts)?|[^/]+\.gradle(\.kts)?|libs\.versions\.toml|gradle\.properties|pom\.xml|package(-lock)?\.json)$ ]]; then
    build=1
  elif [ -n "${since:-}" ] && [[ "$f" =~ ^\.github/|^\.gitlab-ci\.yml$|^Jenkinsfile$ ]]; then
    ci=1
  elif [ -n "${2:-}" ] && comment_only "$2" "$f"; then
    :
  else
    code=1
  fi
  return 0
}

# test_edit_unexplained <subject> <testfix 0|1>: the test-file rule, on the flags classify set.
test_edit_unexplained() {
  [ "$testsrc" -eq 1 ] && [ "$2" -eq 0 ] && [[ "$1" =~ ^(feat|fix|refactor)(\(.*\))?!?: ]]
}

if [ "${1:-}" = --staged ]; then
  msg=${2:-}
  [ -n "$msg" ] && [ -f "$msg" ] || { echo "TDD: usage: tdd-check.sh --staged <commit message file>" >&2; exit 2; }
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || { echo "TDD: --staged needs a git repository" >&2; exit 2; }
  for replay in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ -e "$gitdir/$replay" ] && exit 0
  done
  body=$(grep -v '^#' "$msg" | tr -d '\r' || true)
  subject=$(head -n 1 <<< "$body")
  testfix=0
  tail -n +2 <<< "$body" | grep -q '^Test fix:' && testfix=1
  tests=0 testsrc=0 code=0 build=0 ci=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    classify "$f"
  done < <(git diff --cached --name-only --no-renames)
  if test_edit_unexplained "$subject" "$testfix"; then
    echo "TDD: commit refused: \"$subject\" changes a test file. Move the test files into a test(...) commit of their own (before the code commit), or, when you fixed a wrong test, add a body line \"Test fix: <why>\"." >&2
    exit 1
  fi
  exit 0
fi

usage="usage: tdd-check.sh <artifacts-dir> <base-branch> [--since <sha>] | tdd-check.sh --staged <message file>"
art="${1:?$usage}"
base="${2:?$usage}"
since=""
case "${3:-}" in
  '') ;;
  --since) since="${4:-}"; [ -n "$since" ] || { echo "TDD: --since needs a commit. $usage" >&2; exit 1; } ;;
  *) echo "TDD: unknown argument ${3}. $usage" >&2; exit 1 ;;
esac
[ -z "${5:-}" ] || { echo "TDD: too many arguments. $usage" >&2; exit 1; }
plan="$art/plan.md"
errors=0
err() { echo "TDD: $*" >&2; errors=$((errors + 1)); }

[ -f "$plan" ] || { echo "TDD: no plan at $plan" >&2; exit 1; }

# Dependency-resolution evidence (gradle, maven-resolver, npm) and the generic build-failure summary lines.
dep_re='Could not resolve|Could not find [^ ]+:[^ ]+|ERESOLVE|404 Not Found|E404|aether|ArtifactResolution|Could not transfer artifact|Failed to read artifact descriptor'
summary_re='FAILURE: Build failed|BUILD FAILED|What went wrong'

# pin_lines <n>: the `Pin:` lines under checkbox step n, up to the next checkbox (a bundled pin step, one mutation each).
pin_lines() {
  awk -v n="$1" '/^[[:space:]]*- \[[ xX]\]/ { k++ } k == n && /^[[:space:]]*- Pin:/ { c++ } END { print c + 0 }' "$plan"
}

# 1. Every step done, and every step the agents built has a red run.
n=0
while IFS= read -r line; do
  case "$line" in
    *'- [ ]'*) n=$((n + 1)); err "step $n is not done: $line" ;;
    *'- [x]'*|*'- [X]'*)
      n=$((n + 1))
      case "$line" in *'(done by the workflow'*|*'(verify only)'*) continue ;; esac
      log="$art/red/step-$n.log"
      if [[ "$line" =~ \(folded\ into\ step\ ([0-9]+)\) ]] && [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -lt "$n" ]; then
        log="$art/red/step-${BASH_REMATCH[1]}.log"
      fi
      if [ ! -s "$log" ]; then
        err "step $n has no red test run ($log)"
      elif ! grep -qE 'FAIL|not ok|AssertionError|error:|^ERROR:' "$log"; then
        err "step $n: $log shows no failing test"
      elif [[ "$line" == *'(pin only)'* ]] && ! grep -q '^MUTATION:' "$log"; then
        err "step $n is (pin only): $log has no line starting \"MUTATION:\" naming what was mutated"
      elif [[ "$line" == *'(pin only)'* ]] && [ "$(grep -c '^MUTATION:' "$log")" -lt "$(pin_lines "$n")" ]; then
        err "step $n is (pin only) with $(pin_lines "$n") Pin: lines: $log has only $(grep -c '^MUTATION:' "$log") MUTATION lines, one each"
      elif grep -qE "$dep_re" "$log" &&
        ! grep -vE "$dep_re|$summary_re" "$log" | grep -qE 'FAIL|not ok|AssertionError|error:|^ERROR:'; then
        err "step $n: $log fails only on dependency resolution, not on a test or a compile error"
      fi
      ;;
  esac
done < <(grep -E '^[[:space:]]*- \[[ xX]\]' "$plan")

# 2. Tests are committed before the code they drive.
if [ -n "$since" ]; then
  from="$(git rev-parse --verify --quiet "$since^{commit}")" || { echo "TDD: --since $since is not a commit" >&2; exit 1; }
  if ! git merge-base --is-ancestor "$from" HEAD && [ -n "$(git rev-parse --verify --quiet "$from^2")" ]; then
    # A merge of the base: a rebase drops it, so stand in the branch's own commit before it (first parent, no merge).
    from="$(git rev-list --first-parent --no-merges -1 "$from")"
  fi
  if ! git merge-base --is-ancestor "$from" HEAD; then
    # The branch was rebased onto the base since that pass: the same commit now has a new id. Find it by its author,
    # author date and subject, which a rebase keeps. (No pipe into a loop: under pipefail a loop that ends on a
    # failed test exits the script with no message.)
    key="$(git log -1 --format='%ae %at %s' "$from")"
    fork="$(git merge-base HEAD "origin/$base" 2>/dev/null || git merge-base HEAD "$base")"
    own="$(git log --first-parent --format='%H %ae %at %s' "$fork..HEAD")"
    from="$(awk -v k="$key" 'f == "" && substr($0, index($0, " ") + 1) == k { f = $1 } END { print f }' <<< "$own")"
    [ -n "$from" ] || { echo "TDD: --since $since is not on this branch and no rebased commit matches it ($key)" >&2; exit 1; }
  fi
else
  from="$(git merge-base HEAD "origin/$base" 2>/dev/null || git merge-base HEAD "$base")"
fi
red=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  tests=0; code=0; build=0; testsrc=0; ci=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    classify "$f" "$c"
  done < <(git diff-tree --no-commit-id --name-only -r "$c")
  subject="$(git log -1 --format=%s "$c")"
  testfix=0
  git log -1 --format=%b "$c" | grep -q '^Test fix:' && testfix=1
  if test_edit_unexplained "$subject" "$testfix"; then
    err "commit ${c:0:7} \"$subject\" changes a test file; put the test in a test commit, or explain in a body line starting \"Test fix:\""
  fi
  if [ -n "$since" ]; then
    # Range mode: no behaviour files, or an explained test fix, need no test commit before them.
    [ "$tests" -eq 0 ] && [ "$code" -eq 0 ] && continue
    [ "$testfix" -eq 1 ] && continue
  fi
  [ "$build" -eq 1 ] && [ "$tests" -eq 0 ] && code=1
  regression="$(git log -1 --format=%b "$c" | sed -n 's/^Regression:[[:space:]]*//p' | head -1 | tr -d '\r')"
  if [ -n "$regression" ] && [ "$code" -eq 1 ]; then
    if [ "$tests" -eq 0 ] && [ -f "$art/$regression" ] && grep -qE 'FAILED|error:' "$art/$regression"; then
      continue
    fi
    err "commit ${c:0:7} \"$subject\" names Regression: $regression, but that log (in the artifacts dir) shows no failing test, or the commit also changes tests"
    continue
  fi
  if [ "$code" -eq 0 ]; then
    [ "$tests" -eq 1 ] && red=1
  elif [ "$red" -eq 1 ]; then
    red=0
  else
    err "commit ${c:0:7} \"$subject\" changes code with no test commit before it"
  fi
done < <(git rev-list --reverse --no-merges --first-parent "$from..HEAD")

if [ "$errors" -gt 0 ]; then
  echo "TDD: $errors problem(s): write the failing test first, commit it alone, then the code." >&2
  exit 1
fi
echo "TDD: tests came first on every step and every code commit"
