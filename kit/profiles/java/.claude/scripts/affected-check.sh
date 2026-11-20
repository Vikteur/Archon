#!/usr/bin/env bash
# The local check before a push (owner decision 2026-10-17): runs only the tests the branch's change touches, never the
# full suite; CI is the verdict (P5). First it fetches origin/main and, when the branch is behind, merges it
# (`chore: merge origin/main`), so the PR is not CONFLICTING on GitHub, which ignores docs/memory.md's merge=union; it
# refuses a dirty tree while behind, and aborts on a real conflict, naming the files, with the branch left as it was.
# --no-sync (or AFFECTED_NO_SYNC=1) skips that step. Then it diffs the work tree, untracked files included, against the merge-base with
# origin/main and maps each changed file to its tests:
#   - <module>/...: `:<module>:test` for that Gradle module and every module that depends on it. The slow sets are
#     chosen by JUnit tag, never by class name, with the shared tag rule (.archon/scripts/test-task.sh): a changed test file
#     tagged `integration` or `resource-test` runs its module's `integrationTest` or `resourceTest`; when an
#     *-adapter module or application changed, every affected module also runs the slow sets its tests are tagged
#     for. A root Gradle file (build.gradle.kts, settings.gradle.kts, gradle/, gradlew) changes every module.
#     The kit ships no gradle.properties: a project that turns the configuration cache on there
#     (org.gradle.configuration-cache=true) lets Gradle run one module's test sets side by side.
#   - .archon/scripts/X.sh, .archon/scripts/X/..., .archon/scripts/test/X.test.sh: .archon/scripts/test/X.test.sh.
#   - a path ci-local.sh's ARCHON_SUITE_PATHS names (.archon/, .claude/hooks/, .gitignore, ci.yml): also the .archon
#     suites .claude/scripts/archon-suites.sh selects for the change, as CI's archon-scripts job does ("all": every
#     one; a failed selection: every one).
#   - scripts/X(.sh), scripts/X/..., scripts/test/X.test.sh, scripts/test/fixtures/X/...: scripts/test/X.test.sh.
#   - .claude/scripts/X.sh: scripts/test/X.test.sh, when there is one.
#   - .github/workflows/..., gradle.properties, ci-workflow-check.sh, contract-pin.sh: the CI workflow check and the six
#     CI workflow tests (archon-scripts runs four; the test job runs codegen and generated-untracked-check, here only
#     with a contract checkout at contract/dist/openapi.yaml).
#   - a changed *.md file: a UTF-8 check, in the script itself (a stray Windows-1252 byte failed CI's test job).
#   - a gate file (ci.yml, ci-inputs.yml, ci-plan.sh, local-ci-status.sh, ci-status-grammar.sh): first
#     .claude/scripts/gate-change-check.sh <base>, which fails a gate change that adds no decision entry to docs/memory.md.
#   - an agent instruction text (CLAUDE.md, AGENTS.md, .claude/CLAUDE.md, rules, agents, SKILL.md, .archon/workflows):
#     scripts/test/agent-script-names.test.sh (every script it names exists).
#   - anything else (docs, skills): nothing, and the path is printed as "not checked locally: <path>
#     (<job>)", with the CI job that still checks it.
#   - backlog/, AGENTS.md, CLAUDE.md: nothing, and nothing is printed (no CI job checks them on their own). backlog/
#     only with backlog: true in .archon/kit.yaml (env KIT_BACKLOG, default true): without Backlog.md it is the
#     project's own folder, read as any other path (a .md in it nothing, anything else not checked locally).
# Usage: bash .claude/scripts/affected-check.sh [--dry-run] [--no-sync]
# Prints each command before it runs it, stops at the first failure with its exit code, or prints
# "affected-check: ok". --dry-run prints the commands without running them (and only says whether a merge is due). AFFECTED_BASE
# overrides origin/main.
set -uo pipefail

dry=0
no_sync="${AFFECTED_NO_SYNC:-0}"
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --no-sync) no_sync=1 ;;
    *) echo "usage: bash .claude/scripts/affected-check.sh [--dry-run] [--no-sync]"; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)" || exit 1
# shellcheck source=../../.archon/scripts/test-task.sh
. .archon/scripts/test-task.sh
# shellcheck source=../../.archon/scripts/kit-config.sh
. .archon/scripts/kit-config.sh 2> /dev/null || kit_get() { local e="KIT_${1^^}"; printf '%s' "${!e:-$2}"; }
backlog_on=1; [ "$(kit_get backlog true)" != false ] || backlog_on=0
base_ref="${AFFECTED_BASE:-origin/main}"

# First bring the branch up to date with the base (retro fault: docs/memory.md appends turned PRs CONFLICTING, because
# GitHub ignores the merge=union driver while a local merge applies it). Merges, never rebases: nothing is pushed here.
# --no-sync or AFFECTED_NO_SYNC=1 skips it; --dry-run only says whether a merge is due.
sync_base() {
  case "$base_ref" in origin/*) ;; *) return 0 ;; esac
  local remote_branch="${base_ref#origin/}" branch files
  branch=$(git symbolic-ref --short -q HEAD || true)
  case "$branch" in
    ''|"$remote_branch"|main|master) echo "sync: skipped on '${branch:-detached HEAD}', only a feature branch is merged"; return 0 ;;
  esac
  git fetch -q origin "$remote_branch" || { echo "FAIL: git fetch origin $remote_branch"; return 1; }
  git merge-base --is-ancestor "$base_ref" HEAD && return 0
  if [ "$dry" -eq 1 ]; then echo "sync: would merge $base_ref"; return 0; fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "FAIL: the branch is behind $base_ref and the work tree has uncommitted changes; commit them, then run again"
    return 1
  fi
  echo "sync: merging $base_ref"
  if ! git merge -q --no-edit -m "chore: merge $base_ref" "$base_ref" > /dev/null 2>&1; then
    if git rev-parse -q --verify MERGE_HEAD > /dev/null; then
      files=$(git diff --name-only --diff-filter=U | tr -d '\r' | tr '\n' ' ')
      git merge --abort
      echo "FAIL: merging $base_ref conflicts in: ${files% }. Merge aborted; merge $base_ref by hand, then run again"
    else
      echo "FAIL: git merge $base_ref did not start (untracked files in the way?); merge it by hand, then run again"
    fi
    return 1
  fi
}
if [ "$no_sync" != 1 ]; then sync_base || exit 1; fi

base="$(git merge-base HEAD "$base_ref" 2>/dev/null)" || { echo "FAIL: no merge-base with $base_ref"; exit 1; }

changed="$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | tr -d '\r' | sort -u)"

# The Gradle modules, as settings.gradle.kts includes them.
modules="$(grep -oE '"[a-z][a-z0-9-]*"' settings.gradle.kts 2>/dev/null | tr -d '"' | while read -r m; do
  [ -f "$m/build.gradle.kts" ] && echo "$m"; done | sort -u)"

# Every module's dependencies, one "<module> <dependency>" line per project(":x") its build file names, comments left
# out, in one awk pass over all build files (a grep pipeline per module per round took ~25 s on Git Bash).
dep_edges="$(for m in $modules; do printf '%s\0' "$m/build.gradle.kts"; done | xargs -0 -r awk '
  /^[[:space:]]*\/\// { next }
  { m = FILENAME; sub(/\/build\.gradle\.kts$/, "", m); s = $0
    while (match(s, /project\(":[a-z0-9-]+"\)/)) { print m, substr(s, RSTART + 10, RLENGTH - 12); s = substr(s, RSTART + RLENGTH) } }')"
module_set=" $(printf '%s ' $modules)"

is_it_module() { case "$1" in *-adapter|application) return 0 ;; *) return 1 ;; esac; }

# slow_tasks <file...>: ":<module>:<task>" for each test file whose tag puts it in integrationTest or resourceTest.
slow_tasks() {
  local f t files=()
  for f in "$@"; do
    case "$f" in */src/test/*|*/src/integrationTest/*) ;; *) continue ;; esac
    [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  test_tasks_of "${files[@]}" | while read -r t f; do [ "$t" = test ] || echo ":${f%%/src/*}:$t"; done
}

direct=""
changed_files=()
tests=()
add_test() { local t; for t in "${tests[@]+"${tests[@]}"}"; do [ "$t" = "$1" ] && return; done; tests+=("$1"); }
add_suite() { [ -f "$1" ] && add_test "bash $1"; }
all_modules=0
workflows=0
archon_hits=""
md_files=()
gate_files=0
unchecked=()
# not_checked <path> <job>: a changed path no local command covers; CI's <job> still checks it.
not_checked() { unchecked+=("not checked locally: $1 ($2)"); }

while IFS= read -r f; do
  [ -n "$f" ] || continue
  # The paths CI's archon-scripts job selects its suites from (ARCHON_SUITE_PATHS in ci-local.sh).
  case "$f" in .archon/*|.claude/hooks/*|.gitignore|.github/workflows/ci.yml) archon_hits+="$f"$'\n' ;; esac
  case "$f" in *.md) [ -f "$f" ] && md_files+=("$f") ;; esac
  # A gate file: the change needs its decision entry (gate-change-check.sh). An agent instruction text: the script
  # names it gives must exist (agent-script-names.test.sh).
  case "$f" in
    .github/workflows/ci.yml|.github/ci-inputs.yml|.claude/scripts/ci-plan.sh|.archon/scripts/local-ci-status.sh|\
    .claude/scripts/ci-status-grammar.sh) gate_files=1 ;;
  esac
  case "$f" in
    CLAUDE.md|AGENTS.md|.claude/CLAUDE.md|.github/instructions/*.instructions.md|.github/agents/*.agent.md|.github/skills/*/SKILL.md|\
    .archon/workflows/*) add_suite scripts/test/agent-script-names.test.sh ;;
  esac
  case "$f" in
    gradle.properties) all_modules=1; workflows=1; continue ;;
    build.gradle.kts|settings.gradle.kts|gradle/*|gradlew|gradlew.bat) all_modules=1; continue ;;
    .github/workflows/*) workflows=1; continue ;;
    .claude/scripts/ci-workflow-check.sh|.claude/scripts/contract-pin.sh) workflows=1; continue ;;
    .archon/scripts/test/*.test.sh) add_suite "$f"; continue ;;
    .archon/scripts/test-task.sh)
      add_suite scripts/test/affected-check.test.sh; continue ;;
    .archon/scripts/*)
      x="${f#.archon/scripts/}"; x="${x%%/*}"; x="${x%.sh}"
      add_suite ".archon/scripts/test/$x.test.sh"; continue ;;
    scripts/test/*.test.sh) add_suite "$f"; continue ;;
    scripts/test/fixtures/*)
      x="${f#scripts/test/fixtures/}"; x="${x%%/*}"
      add_suite "scripts/test/$x.test.sh"; continue ;;
    scripts/*)
      x="${f#scripts/}"; x="${x%%/*}"; x="${x%.sh}"
      add_suite "scripts/test/$x.test.sh" || not_checked "$f" "every job"; continue ;;
    .claude/scripts/*.sh)
      x="${f#.claude/scripts/}"; x="${x%.sh}"
      add_suite "scripts/test/$x.test.sh" || not_checked "$f" "every job"; continue ;;
  esac
  m="${f%%/*}"
  if [ "$m" != "$f" ]; then
    case "$module_set" in *" $m "*) direct="$direct $m"; changed_files+=("$f"); continue ;; esac
  fi
  case "$f" in
    backlog/*) [ "$backlog_on" = 1 ] || case "$f" in *.md) ;; *) not_checked "$f" "every job" ;; esac ;;
    AGENTS.md|CLAUDE.md|.archon/*|.claude/hooks/*|.gitignore|*.md) ;;
    *) not_checked "$f" "every job" ;;
  esac
done <<< "$changed"

[ "$all_modules" -eq 1 ] && direct="$modules"
direct="$(printf '%s\n' $direct | sort -u)"

# The affected modules: the changed ones and, transitively, every module that depends on one of them.
affected="$(printf '%s\n' "$dep_edges" | AC_DIRECT="$direct" awk '
  NF == 2 { from[++n] = $1; to[n] = $2 }
  END { k = split(ENVIRON["AC_DIRECT"], d, "\n"); for (i = 1; i <= k; i++) if (d[i] != "") in_set[d[i]] = 1
        do { grew = 0
             for (e = 1; e <= n; e++) if ((to[e] in in_set) && !(from[e] in in_set)) { in_set[from[e]] = 1; grew = 1 }
        } while (grew)
        for (m in in_set) print m }' | sort -u)"

it=0
for m in $direct; do is_it_module "$m" && it=1; done
slow="$(slow_tasks "${changed_files[@]+"${changed_files[@]}"}")"
if [ "$it" -eq 1 ] && [ -n "$affected" ]; then
  paths=()
  for m in $affected; do paths+=("$m/src/test" "$m/src/integrationTest"); done
  mapfile -t files < <(git ls-files -- "${paths[@]}" | tr -d '\r')
  slow="$slow $(slow_tasks "${files[@]+"${files[@]}"}")"
fi
tasks=""
for m in $affected; do tasks="$tasks :$m:test"; done
for t in integrationTest resourceTest; do
  for s in $(printf '%s\n' $slow | grep ":$t\$" | sort -u); do tasks="$tasks $s"; done
done

# The .archon suites CI's archon-scripts job would select for this change (ci-local.sh does the same selection).
if [ -n "$archon_hits" ]; then
  if sel=$(printf '%s' "$archon_hits" | bash .claude/scripts/archon-suites.sh "$PWD" HEAD 2>/dev/null) && [ "$sel" != all ]; then
    while IFS= read -r t; do [ -n "$t" ] && add_suite "$t"; done <<< "$sel"
  else
    for t in .archon/scripts/test/*.test.sh; do add_suite "$t"; done
  fi
fi

cmds=()
# A gate change without its decision entry fails first: it costs a second and no test can make it pass.
[ "$gate_files" -eq 1 ] && [ -f .claude/scripts/gate-change-check.sh ] && cmds+=("bash .claude/scripts/gate-change-check.sh $base_ref")
[ -n "$tasks" ] && cmds+=("./gradlew$tasks")
cmds+=("${tests[@]+"${tests[@]}"}")
if [ "$workflows" -eq 1 ]; then
  # The CI workflow check and its suites: four in archon-scripts' "Every script suite passes", two in the test job.
  for c in "bash .claude/scripts/ci-workflow-check.sh" "bash scripts/test/contract-read-only-check.test.sh" \
           "bash scripts/test/ci-workflow-check.test.sh" "bash scripts/test/ci-workflow.test.sh" \
           "bash scripts/test/generated-untracked-check.test.sh" "bash scripts/test/codegen.test.sh" \
           "bash scripts/test/contract-pin.test.sh"; do
    [ -f "${c#bash }" ] || continue
    case "$c" in
      *codegen.test.sh|*generated-untracked-check.test.sh)
        # Both generate from the real bundle and fail without it.
        if [ ! -f contract/dist/openapi.yaml ]; then
          not_checked "${c#bash }, no contract checkout at contract/dist/openapi.yaml" "test"; continue
        fi ;;
    esac
    case " ${cmds[*]+"${cmds[*]}"} " in *" $c "*) ;; *) cmds+=("$c") ;; esac
  done
fi

# What CI still checks and this run does not: printed first, so a pass below is never read as covering it.
for u in "${unchecked[@]+"${unchecked[@]}"}"; do echo "$u"; done

# Every changed Markdown file is valid UTF-8 (CI's test job failed on a stray Windows-1252 byte in docs/memory.md).
if [ "${#md_files[@]}" -gt 0 ]; then
  echo "run: UTF-8 check of ${#md_files[@]} changed .md file(s)"
  if [ "$dry" -eq 0 ]; then
    for m in "${md_files[@]}"; do
      if ! iconv -f UTF-8 -t UTF-8 "$m" > /dev/null 2>&1; then
        echo "FAIL: $m is not valid UTF-8"
        exit 1
      fi
    done
  fi
fi

if [ "${#cmds[@]}" -eq 0 ]; then
  echo "affected-check: nothing to run for this change"
  exit 0
fi
# The .archon suites run SUITE_JOBS at a time (default 4) through run-suites.sh, after every other command, the way
# archon-scripts runs them in CI (owner decision 2026-10-22: side by side they never failed; one by one a change to
# .archon took about 20 minutes here). Every other command runs one by one, and the first failure stops the run.
serial=() suites=()
for c in "${cmds[@]}"; do
  if [ -f .claude/scripts/run-suites.sh ] && [[ "$c" =~ ^bash\ \.archon/scripts/test/[^\ ]+\.test\.sh$ ]]; then
    suites+=("${c#bash }")
  else
    serial+=("$c")
  fi
done
for c in "${serial[@]+"${serial[@]}"}"; do
  echo "run: $c"
  [ "$dry" -eq 1 ] && continue
  $c
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $c (exit $rc)"
    exit "$rc"
  fi
done
if [ "${#suites[@]}" -gt 0 ]; then
  for t in "${suites[@]}"; do echo "run: bash $t"; done
  if [ "$dry" -eq 0 ]; then
    echo "run-suites: ${#suites[@]} suites, ${SUITE_JOBS:-4} at a time"
    bash .claude/scripts/run-suites.sh "${suites[@]}" 2>&1 \
      | sed -uE '/^::endgroup::$/d; s/^::group::/--- /; s/^::error::(.+) failed$/FAIL: bash \1/'
    rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || exit "$rc"
  fi
fi
[ "$dry" -eq 1 ] || echo "affected-check: ok"
exit 0
