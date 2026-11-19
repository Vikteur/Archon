#!/usr/bin/env bash
# The mutation gate (decision 2026-10-18, docs/memory.md; retro fault #1): runs PIT on the main classes the branch
# changes in the pure-Java modules (shared-domain, shared-usecase, *-domain, *-usecase) and, by the owner's decision of
# 2026-10-18, in every *-gateway module by that naming convention (their tests need no Quarkus and no container), and
# fails when a mutant in one of them survives or has no test covering it, unless config/mutation-accepted.txt accepts
# it. Adapters stay out.
#   - Targets: every src/main/java/**/*.java file of those modules that differs from the merge-base with the base ref,
#     untracked files included, deleted ones and package-info/module-info left out; nested classes come along.
#   - One Gradle run, `:<module>:pitest` for each module with a target, the targets in -PpitTargets. No target, no
#     Gradle: the gate passes at once (a push to main has no diff against origin/main).
#   - Accept file lines: `<class>:<line>:<mutator> # reason`, the mutator by its simple name as the gate prints it
#     (ConditionalsBoundaryMutator). A line without a reason is an error.
# Usage: bash .claude/scripts/mutation-gate.sh [--base <ref>] [--dry-run]
#        bash .claude/scripts/mutation-gate.sh --list-targets < paths
# --base defaults to origin/main. --dry-run prints the Gradle command without running it. Prints every surviving
# mutant (class:line mutator, method, description) and exits 1, or prints "mutation-gate: ok".
set -uo pipefail

# The target rule, its one copy (ci-plan.sh asks it through --list-targets): of the repo paths on stdin, print the
# ones that are mutation targets.
target_paths() {
  tr -d '\r' | grep -E '^(shared|[a-z][a-z0-9]*)-(domain|usecase|gateway)/src/main/java/.+\.java$' \
    | grep -vE '/(package|module)-info\.java$'
}

# --list-targets: the paths on stdin that are targets, as given, one per line; reads no repo and runs nothing.
if [ "${1:-}" = "--list-targets" ]; then
  [ "$#" -eq 1 ] || { echo "FAIL: --list-targets takes no other argument"; exit 2; }
  target_paths
  exit 0
fi

base_ref="origin/main"
dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) base_ref="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "FAIL: unknown argument $1"; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)" || exit 1
accept_file="config/mutation-accepted.txt"
base="$(git merge-base HEAD "$base_ref" 2>/dev/null)" || { echo "FAIL: no merge-base with $base_ref"; exit 1; }

changed="$( { git diff --name-only --diff-filter=d "$base"; git ls-files --others --exclude-standard; } | tr -d '\r' | sort -u)"

# "<module> <class>" for each changed main class of a gated module.
targets="$(printf '%s\n' "$changed" | target_paths | sed -E 's#^([^/]+)/src/main/java/(.+)\.java$#\1 \2#; s#/#.#g' | sort -u)"

if [ -z "$targets" ]; then
  echo "mutation-gate: no changed main class in a domain, usecase or gateway module since $base_ref, nothing to mutate"
  exit 0
fi

modules="$(printf '%s\n' "$targets" | cut -d' ' -f1 | sort -u)"
classes="$(printf '%s\n' "$targets" | cut -d' ' -f2 | paste -sd, -)"
tasks=""
for m in $modules; do tasks="$tasks :$m:pitest"; done
cmd="./gradlew$tasks -PpitTargets=$classes --console=plain"

echo "mutation-gate: targets"
printf '%s\n' "$targets" | sed 's/^/  /'
echo "run: $cmd"
[ "$dry" -eq 1 ] && exit 0

# A report left from an earlier run must not answer for this one.
for m in $modules; do rm -rf "$m/build/reports/pitest"; done
start=$(date +%s)
$cmd
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: $cmd (exit $rc)"
  exit "$rc"
fi
echo "mutation-gate: PIT took $(( $(date +%s) - start ))s"

# Accepted keys, "<class>:<line>:<mutator>", from the accept file; a line without a reason fails the gate.
accepted=""
fail=0
if [ -f "$accept_file" ]; then
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    key="$(printf '%s' "${line%%#*}" | tr -d '[:space:]')"
    reason="$(printf '%s' "${line#*#}" | tr -d '[:space:]')"
    if [ "$line" = "${line%%#*}" ] || [ -z "$reason" ]; then
      echo "FAIL: $accept_file: \"$line\" gives no reason (<class>:<line>:<mutator> # reason)"
      fail=1
    fi
    accepted="$accepted"$'\n'"$key"
  done < "$accept_file"
fi

total=0
detected=0
open=0
taken=0
for m in $modules; do
  xml="$m/build/reports/pitest/mutations.xml"
  [ -f "$xml" ] || continue # PIT found no mutable code in the targets
  n="$(grep -c '<mutation ' "$xml")"
  total=$((total + n))
  # status, class, method, line, mutator (simple name), description: one mutation per line in PIT's XML.
  while IFS=$'\t' read -r status cls method lineno mutator desc; do
    [ -n "$status" ] || continue
    case "$status" in
      SURVIVED|NO_COVERAGE) ;;
      *) detected=$((detected + 1)); continue ;;
    esac
    mutator="${mutator##*.}"
    key="$cls:$lineno:$mutator"
    if printf '%s\n' "$accepted" | grep -xF "$key" >/dev/null; then
      taken=$((taken + 1))
      echo "accepted:  $key ($method) $desc"
    else
      open=$((open + 1))
      echo "$status: $key ($method) $desc"
    fi
  done < <(sed -nE "s#.*status='([A-Z_]+)'.*<mutatedClass>([^<]*)</mutatedClass><mutatedMethod>([^<]*)</mutatedMethod>.*<lineNumber>([0-9]+)</lineNumber><mutator>([^<]*)</mutator>.*<description>([^<]*)</description>.*#\1\t\2\t\3\t\4\t\5\t\6#p" "$xml" \
    | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g')
done

echo "mutation-gate: $total mutants, $detected detected, $open not killed, $taken accepted"
if [ "$open" -gt 0 ]; then
  echo "FAIL: $open mutant(s) no test kills. Add the test that kills each; accept one only when it is equivalent, with"
  echo "      a line \`<class>:<line>:<mutator> # reason\` in $accept_file. Reports: <module>/build/reports/pitest/"
  fail=1
fi
[ "$fail" -eq 0 ] && echo "mutation-gate: ok"
exit "$fail"
