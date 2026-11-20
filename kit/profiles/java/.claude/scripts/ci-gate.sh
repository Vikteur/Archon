#!/usr/bin/env bash
# ci-gate.sh — one CI gate that is report-only until the project switches it on (kit/SPEC.md, Report-only gates).
# Usage: bash .claude/scripts/ci-gate.sh <gate> [<command>...]   (from the repo root, as a step of .github/workflows/ci.yml)
#
# Gates, each with its kit key (.archon/kit.yaml; env KIT_GATES_<KEY>), report (the default) or block:
#   tests-ran      gates.tests_ran      the JUnit XML under */build/test-results/ counts more than zero tests, not all
#                                       skipped. Run it after the Gradle build: a green build that ran no test is no proof.
#   format         gates.format         runs <command> (./gradlew spotlessCheck ...) when the build applies Spotless.
#   coverage       gates.coverage       runs <command> (./gradlew jacocoTestReport ...) when the build applies JaCoCo,
#                                       then prints the line and branch coverage of each report. No threshold yet.
#   secrets        gates.secrets        gitleaks over the checkout, with --redact: it prints file, line and rule of a
#                                       finding, never the matched text.
#   contract-lint  gates.contract_lint  spectral lint of the contract spec (<command>'s first word, else kit key
#                                       contract.spec_path), with contract/.spectral.yaml, .spectral.yaml or spectral:oas.
# report: a finding, or a gate that is not set up (no Spotless, no gitleaks on PATH), prints a ::warning:: line and the
# step passes. block: the same exits 1 and fails the job. Any other value fails, so a typo never turns a gate off.
# Switching a gate to block is a gate change: it needs a dated docs/memory.md entry (gate-change-check.sh, kit-gates).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }

gate="${1:-}"; shift || true
case "$gate" in
  tests-ran | format | coverage | secrets | contract-lint) ;;
  *) echo "ci-gate: unknown gate '${gate}' (tests-ran, format, coverage, secrets, contract-lint)"; exit 2 ;;
esac
key="${gate//-/_}"
mode="$(kit_get "gates.$key" report "KIT_GATES_${key^^}")"
case "$mode" in
  report | block) ;;
  *) echo "ci-gate $gate: kit key gates.$key is '$mode', want report or block"; exit 1 ;;
esac
findings=0
finding() { # finding <text>: one finding of this gate
  findings=$((findings + 1))
  if [ "$mode" = block ]; then echo "::error::ci-gate $gate: $1"
  else echo "::warning::ci-gate $gate: $1 (report-only; kit key gates.$key: block fails the job)"; fi
}
finish() { # the verdict: block fails on a finding, report never does
  if [ "$findings" -eq 0 ]; then echo "ci-gate $gate: ok"; exit 0; fi
  echo "ci-gate $gate: $findings finding(s), mode $mode"
  [ "$mode" = block ] && exit 1
  exit 0
}
build_files() { # the build files a plugin is applied in
  { ls ./*.gradle.kts ./*.gradle gradle/*.toml 2>/dev/null
    find buildSrc build-logic -type f \( -name '*.gradle.kts' -o -name '*.gradle' -o -name '*.kt' -o -name '*.toml' \) \
      -not -path '*/build/*' 2>/dev/null
    find . -mindepth 2 -maxdepth 2 \( -name 'build.gradle.kts' -o -name 'build.gradle' \) -not -path './build*' 2>/dev/null
  } | sort -u
}
applies() { # applies <word>: a build file names the plugin
  local f
  while IFS= read -r f; do grep -qi -- "$1" "$f" 2>/dev/null && return 0; done < <(build_files)
  return 1
}
run_command() { # run_command <what>: runs the gate's command; a non-zero exit is a finding
  [ "$#" -gt 1 ] || { finding "no command given for $1"; return 1; }
  local what="$1"; shift
  echo "ci-gate $gate: $*"
  "$@"; local rc=$?
  [ "$rc" -eq 0 ] || { finding "$what failed (exit $rc)"; return 1; }
}

case "$gate" in
  tests-ran)
    # Per test set (module:task): tests and skipped, from each TEST-*.xml's first <testsuite> tag.
    total=0; skipped=0
    while IFS=$'\t' read -r set n sk; do
      [ -n "$set" ] || continue
      echo "ci-gate tests-ran: $set ran $n test(s), $sk skipped"
      total=$((total + n)); skipped=$((skipped + sk))
    done < <(find . -path '*/build/test-results/*' -name 'TEST-*.xml' -not -path '*/node_modules/*' 2>/dev/null \
      | while IFS= read -r f; do
          rel="${f#./}"
          if [[ "$rel" == build/test-results/* ]]; then mod=.; else mod="${rel%%/build/test-results/*}"; fi
          task="${rel#*build/test-results/}"; task="${task%%/*}"
          tr '\n' ' ' < "$f" | grep -o '<testsuite [^>]*>' | head -1 | awk -v k="$mod:$task" '
            function attr(n,   m) { return match($0, " " n "=\"[^\"]*\"") ? substr($0, RSTART + length(n) + 3, RLENGTH - length(n) - 4) + 0 : 0 }
            { print k "\t" attr("tests") "\t" attr("skipped") }'
        done | awk -F '\t' '{ n[$1] += $2; s[$1] += $3 } END { for (k in n) print k "\t" n[k] "\t" s[k] }' | sort)
    # A test task kit key ci.gradle_line names that left no results: a note, since a module may hold no such tests yet.
    for t in $(kit_get ci.gradle_line "./gradlew test integrationTest build" KIT_CI_GRADLE_LINE); do
      case "$t" in test | *Test | *:test) ;; *) continue ;; esac
      t="${t##*:}"
      find . -path "*/build/test-results/$t/TEST-*.xml" -print -quit 2>/dev/null | grep -q . \
        || echo "ci-gate tests-ran: note: task $t (kit key ci.gradle_line) left no JUnit XML"
    done
    echo "ci-gate tests-ran: $total test(s), $skipped skipped"
    if [ "$total" -eq 0 ]; then finding "the build ran no test: no JUnit XML under */build/test-results/ counts one"
    elif [ "$skipped" -ge "$total" ]; then finding "every one of the $total test(s) was skipped"; fi
    ;;
  format)
    if applies spotless; then run_command "the format check" "$@" || true
    else finding "not set up: no build file applies Spotless (com.diffplug.spotless)"; fi
    ;;
  coverage)
    if applies jacoco; then
      if run_command "the coverage report" "$@"; then
        reports="$(find . -path '*/build/reports/jacoco/*' -name '*.xml' -not -path '*/node_modules/*' 2>/dev/null | sort)"
        if [ -z "$reports" ]; then finding "no JaCoCo XML report under */build/reports/jacoco/ (enable reports.xml)"; fi
        while IFS= read -r r; do
          [ -n "$r" ] || continue
          # The report's own counters follow its last </package>: LINE and BRANCH, missed and covered.
          tr '\n' ' ' < "$r" | sed 's#.*</package>##' | grep -oE '<counter type="(LINE|BRANCH)" missed="[0-9]+" covered="[0-9]+"' \
            | awk -v r="${r#./}" -F '"' '{ m = $4; c = $6; p = (m + c) ? sprintf("%.1f%%", 100 * c / (m + c)) : "n/a"
                out = out sprintf(" %s %s (%d/%d)", tolower($2), p, c, m + c) } END { print "ci-gate coverage: " r ":" (out ? out : " no counters") }'
        done <<< "$reports"
      fi
    else finding "not set up: no build file applies JaCoCo (the jacoco plugin)"; fi
    ;;
  secrets)
    if command -v gitleaks >/dev/null 2>&1; then
      tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
      # dir mode (gitleaks 8.19+) scans the files of the checkout; older builds take detect --no-git. --redact keeps the
      # matched text out of the report, and only file, line and rule are printed.
      args=(--redact --no-banner --exit-code 0 --report-format json --report-path "$tmp/report.json")
      gitleaks dir "${args[@]}" . > "$tmp/log" 2>&1 || gitleaks detect --no-git --source . "${args[@]}" > "$tmp/log" 2>&1
      rc=$?
      if [ "$rc" -ne 0 ] || [ ! -f "$tmp/report.json" ]; then finding "gitleaks did not run (exit $rc): $(tail -n 1 "$tmp/log")"
      else
        while IFS=$'\t' read -r file line rule; do
          [ -n "$file" ] || continue
          finding "$file:$line matches rule $rule"
        done < <(jq -r '.[]? | [.File, (.StartLine | tostring), .RuleID] | @tsv' "$tmp/report.json" 2>/dev/null)
      fi
    else finding "not set up: gitleaks is not on PATH"; fi
    ;;
  contract-lint)
    spec="${1:-$(kit_get contract.spec_path contract/dist/openapi.yaml KIT_CONTRACT_SPEC_PATH)}"
    spectral=""
    if command -v spectral >/dev/null 2>&1; then spectral=spectral
    elif [ -x node_modules/.bin/spectral ]; then spectral=node_modules/.bin/spectral; fi
    if [ -z "$spectral" ]; then finding "not set up: spectral (@stoplight/spectral-cli) is not on PATH"
    elif [ ! -f "$spec" ]; then finding "no contract spec at $spec"
    else
      ruleset=""; label=""
      for r in contract/.spectral.yaml contract/.spectral.yml .spectral.yaml .spectral.yml; do
        [ -f "$r" ] && { ruleset="$r"; label="$r"; break; }
      done
      if [ -z "$ruleset" ]; then
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        ruleset="$tmp/spectral.yaml"; label="spectral:oas"; printf 'extends: ["spectral:oas"]\n' > "$ruleset"
      fi
      echo "ci-gate contract-lint: $spectral lint $spec (ruleset $label)"
      "$spectral" lint --ruleset "$ruleset" "$spec"; rc=$?
      [ "$rc" -eq 0 ] || finding "spectral found errors in $spec (exit $rc)"
    fi
    ;;
esac
finish
