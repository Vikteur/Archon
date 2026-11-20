#!/usr/bin/env bash
# Checks the CI workflows (TASK-2.1; UD-15.e, RISK-51): the workflow that holds the gradle run is the job definition
# .claude/scripts/ci-local.sh reads, and GitHub never runs it on its own (owner decision D21, 2026-10-20: GitHub Actions
# is dropped), so its only event is workflow_dispatch; it runs the gradle tasks with none excluded, checks out the private
# @@KIT_CONTRACT_REPO@@ with the one CI secret CONTRACT_TOKEN in every workflow (the secret appears nowhere else, and
# the secrets context is never used as a whole), proves that token read-only right after the checkout, never skips
# either step, fails closed (no step runs after a failed checkout), sets up the Temurin of the Gradle toolchain in
# every setup-java, and pins every action by a 40-character commit SHA. Every job that runs ./gradlew
# (TASK-2.3) also checks out the contract, proves the token read-only, runs contract-pin.sh right after, and passes
# -Pcontract.spec=contract/dist/openapi.yaml to every ./gradlew run.
# The job rules of UD-31 (owner decision 2026-10-20, docs/memory.md: a job runs or is reused, never not-required), on
# the workflow that holds the gradle run, the job definition ci-local.sh reads:
#   N1 every job has a positive whole timeout-minutes;
#   N2 every action is pinned by a 40-character commit SHA (above, in every workflow);
#   N3 no event of the workflow filters by paths or ignores branches;
#   N4 no job may be skipped or let fail: no job-level if, no continue-on-error on any job or step, no [skip ci]-style
#      marker and no condition on the commit message;
#   N7 the job set equals the last "CI job set" recorded in <memory-file>, so the job set changes only together with a
#      decision entry there (append a new bullet that names the new set; the last one counts).
# Scope: the rules hold on the workflows the kit owns, the ones .archon/kit.lock.json tracks (all of them where there
# is no lock, as in the kit's source). A workflow the project wrote itself is checked by the same per-file rules, but a
# finding there is a BASELINE line that never fails: the project owns that file and its history (an action pinned by
# tag, its own use of the contract token), and only the kit's own workflow is the job definition ci-local.sh reads.
# The Java toolchain is the first JavaLanguageVersion.of(N) in the build file, else in a Gradle file under buildSrc/,
# else under build-logic/ (a convention plugin), the order kit add and class-version-check.sh read it in.
# The contract rules above (the contract checkout, its secret, the read-only proof, the pin, the spec argument) hold
# where the openapi-contract profile is installed: there is no .archon/kit.lock.json (the kit's own source), the lock
# tracks that profile's .claude/scripts/contract-pin.sh, that script is in the tree, or kit key profiles names
# openapi-contract. Any one of them is enough. A project installed without the profile gets the kit's ci.yml without
# contract steps, and the check holds that instead: no workflow names CONTRACT_TOKEN, and no job of the job definition
# checks out a contract, runs a contract script (contract-read-only-check.sh, contract-pin.sh,
# generated-untracked-check.sh: they ship with the profile) or passes -Pcontract.spec.
# The required gradle run is kit key ci.gradle_line (default ./gradlew test integrationTest build), the line the kit's
# ci.yml renders from the same key.
# The contract repo is kit key contract.repo (default @@KIT_CONTRACT_REPO@@); its checkout step is named
# "Check out <repo name>", or kit key contract.checkout_step.
# Usage: bash .claude/scripts/ci-workflow-check.sh [<workflow-dir>] [<build-file>] [<memory-file>]
# Prints every FAIL line and exits 1, or prints "ci-workflow: ok" and exits 0 (BASELINE lines never fail). Needs yq
# (mikefarah v4).
set -uo pipefail

dir="${1:-.github/workflows}"
build_file="${2:-build.gradle.kts}"
memory_file="${3:-docs/memory.md}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../.archon/scripts/kit-config.sh
. "$here/../../.archon/scripts/kit-config.sh" 2>/dev/null || kit_get() { local e="${3:-}"; printf '%s' "${!e:-$2}"; }
gradle_line="$(kit_get ci.gradle_line "./gradlew test integrationTest build" KIT_CI_GRADLE_LINE)"
contract_repo="$(kit_get contract.repo "@@KIT_CONTRACT_REPO@@" KIT_CONTRACT_REPO)"  # quoted: an empty default stays an argument
contract_name="${contract_repo#*/}"
checkout_name="$(kit_get contract.checkout_step "Check out $contract_name" KIT_CONTRACT_CHECKOUT_STEP)"
readonly_run="bash .claude/scripts/contract-read-only-check.sh contract"
token_expr='${{ secrets.CONTRACT_TOKEN }}'
fail=0
bad() { echo "FAIL: $1"; fail=1; }
baselines=0
baseline() { echo "BASELINE: $1 (a workflow the kit does not own: reported, not failed)"; baselines=$((baselines + 1)); }
report=bad   # what a per-file rule calls: bad on a kit-owned workflow, baseline on the project's own

command -v yq >/dev/null 2>&1 || { echo "FAIL: yq is required"; exit 1; }

# q <yq expression> <file>: yq output without carriage returns (a CRLF checkout must not change a verdict).
q() { yq "$1" "$2" 2>/dev/null | tr -d '\r'; }
# events <file>: the workflow's events, one per line, from any form of on.
events() {
  case "$(q '.on | tag' "$1")" in
    '!!map') q '.on | keys | .[]' "$1" ;;
    '!!seq') q '.on[]' "$1" ;;
    '!!str') q '.on' "$1" ;;
  esac
}

toolchain_of() { grep -oE 'JavaLanguageVersion\.of\( *[0-9]+ *\)' "$1" 2>/dev/null | head -n 1 | grep -oE '[0-9]+'; }
version="$(toolchain_of "$build_file")" || true
for place in buildSrc build-logic; do
  [ -z "$version" ] && [ -d "$place" ] || continue
  while IFS= read -r gf; do
    version="$(toolchain_of "$gf")" && [ -n "$version" ] && break
  done < <(find "$place" \( -name build -o -name .gradle \) -prune -o -type f \( -name '*.gradle.kts' -o -name '*.gradle' -o -name '*.kt' \) -print | LC_ALL=C sort)
done
[ -n "$version" ] || bad "$build_file names no Java toolchain (nor does a Gradle file under buildSrc/ or build-logic/)"

shopt -s nullglob
all_files=("$dir"/*.yml "$dir"/*.yaml)
shopt -u nullglob
if [ "${#all_files[@]}" -eq 0 ]; then
  bad "no workflow file in $dir"
  exit 1
fi

# The workflows the kit owns: the lock's paths. No lock: every workflow is the kit's.
lock=.archon/kit.lock.json
owned=""
[ -f "$lock" ] && owned="$(yq -p json '.files | keys | .[]' "$lock" 2>/dev/null | tr -d '\r')"
owns() { [ ! -f "$lock" ] || grep -qxF -- "${1#./}" <<< "$owned"; }
# The contract rules hold where the openapi-contract profile is installed (see the header); without it, the rules of a
# workflow with no contract steps.
contract_ci=0
if [ ! -f "$lock" ] || grep -qxF .claude/scripts/contract-pin.sh <<< "$owned" || [ -f .claude/scripts/contract-pin.sh ] \
    || { declare -F kit_list >/dev/null && kit_list profiles | tr -d '\r' | grep -qxF openapi-contract; }; then
  contract_ci=1
fi
# Every contract rule names the hub repo: with the profile in and kit key contract.repo unset, the rendered ci.yml checks
# out an empty repository, and that is a FAIL of its own, named before the rules it breaks.
if [ "$contract_ci" -eq 1 ] && [ -z "$contract_repo" ]; then
  bad "kit key contract.repo is not set (owner/repo of the contract hub, or env KIT_CONTRACT_REPO): the openapi-contract profile's contract checkout has no repository"
fi
contract_scripts_re='\.claude/scripts/(contract-read-only-check|contract-pin|generated-untracked-check)\.sh'

files=()
for f in "${all_files[@]}"; do
  owns "$f" && report=bad || report=baseline
  if yq '.' "$f" >/dev/null 2>&1; then
    files+=("$f")
  else
    "$report" "$f is not valid YAML"
  fi
done

pin_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$'
gradle_files=()
for f in "${files[@]}"; do
  owns "$f" && report=bad || report=baseline
  # every uses: (step and job level) is pinned, except local ones
  while IFS= read -r use; do
    [ -n "$use" ] || continue
    case "$use" in ./*) continue ;; esac
    [[ "$use" =~ $pin_re ]] || "$report" "$f: $use is not pinned by a 40-character commit SHA"
  done < <(q '.. | select(tag == "!!map" and has("uses")) | .uses' "$f")

  ! events "$f" | grep -qxF pull_request_target || "$report" "$f: pull_request_target is never used"
  if grep -qE 'github\.token|secrets\.GITHUB_TOKEN' "$f"; then
    "$report" "$f: the workflow's own token is never used (github.token, secrets.GITHUB_TOKEN)"
  fi
  # toJSON(secrets) and the like hand out every secret, CONTRACT_TOKEN included, without naming it.
  if grep -oE '\$\{\{[^}]*\}\}' "$f" | grep -qE '(^|[^A-Za-z0-9_.])secrets([^A-Za-z0-9_.[]|$)'; then
    "$report" "$f: secrets are named one by one, never as a whole"
  fi

  # Every contract checkout, in any job of any workflow, uses the CI secret; the secret appears nowhere else.
  # Without the openapi-contract profile there is no contract checkout, so the secret appears nowhere.
  good_checkouts=0
  if [ "$contract_ci" -eq 1 ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if [ "$t" = "$token_expr" ]; then
        good_checkouts=$((good_checkouts + 1))
      else
        "$report" "$f: the $contract_name checkout must use token $token_expr and nothing else"
      fi
    done < <(q '.. | select(tag == "!!map" and has("uses")) | select(.uses | test("^actions/checkout@")) | select(.with.repository == "'"$contract_repo"'") | (.with.token | tostring)' "$f")
    [ "$(grep -o 'CONTRACT_TOKEN' "$f" | wc -l | tr -d ' ')" -eq "$good_checkouts" ] \
      || "$report" "$f: CONTRACT_TOKEN may appear only as the token of the $contract_name checkout"
  elif grep -q 'CONTRACT_TOKEN' "$f"; then
    "$report" "$f: CONTRACT_TOKEN is the CI secret of the openapi-contract profile, which is not installed: no workflow uses it"
  fi

  # Only a kit-owned workflow can be the job definition ci-local.sh reads.
  if [ "$report" = bad ] && q '.jobs[].steps[].run' "$f" | grep -qF "$gradle_line"; then
    gradle_files+=("$f")
  fi
done

case "${#gradle_files[@]}" in
  0) bad "no workflow runs $gradle_line$([ -f "$lock" ] && echo ' (of the workflows the kit owns)')"; exit 1 ;;
  1) ci="${gradle_files[0]}" ;;
  *) bad "more than one workflow runs $gradle_line: ${gradle_files[*]}"; exit 1 ;;
esac

# Triggers (D21): workflow_dispatch and nothing else, in the map, list or scalar form of on. A push, pull_request or
# schedule event would let GitHub run the jobs again beside ci-local.
events="$(events "$ci" | sort -u | tr '\n' ' ')"
[ "$events" = "workflow_dispatch " ] \
  || { events="${events% }"; bad "$ci: on must hold workflow_dispatch only, it holds ${events:-nothing} (D21: GitHub Actions is dropped, ci-local.sh runs the jobs)"; }

# N3: no event filters by paths or ignores branches.
for ev in $(q '.on | select(tag == "!!map") | keys | .[]' "$ci"); do
  if [ "$(q "(.on[\"$ev\"] // {}) | select(tag == \"!!map\") | (has(\"paths\") or has(\"paths-ignore\") or has(\"branches-ignore\"))" "$ci")" = "true" ]; then
    bad "$ci: on.$ev may not filter by paths or ignore branches (N3)"
  fi
done

# N1 and N4: every job has a timeout and can neither be skipped nor fail softly. The build job's continue-on-error is
# reported below, with its step names.
build_job_name=""
for j in $(q '.jobs | keys | .[]' "$ci"); do
  if q ".jobs[\"$j\"].steps[].run" "$ci" | grep -qF "$gradle_line"; then build_job_name="$j"; break; fi
done
for j in $(q '.jobs | keys | .[]' "$ci"); do
  t="$(q ".jobs[\"$j\"][\"timeout-minutes\"]" "$ci")"
  [[ "$t" =~ ^[1-9][0-9]*$ ]] || bad "$ci: job $j must set a positive whole timeout-minutes (N1)"
  [ "$(q ".jobs[\"$j\"] | has(\"if\")" "$ci")" = "false" ] || bad "$ci: job $j may not have an if: every job runs (N4)"
  [ "$j" = "$build_job_name" ] && continue
  coe="$(q "[.jobs[\"$j\"], (.jobs[\"$j\"].steps // [])[]] | map(select(.[\"continue-on-error\"] != null and .[\"continue-on-error\"] != false)) | length" "$ci")"
  [ "$coe" = 0 ] || bad "$ci: job $j may not continue on error (N4)"
done
# Comments left out, so a comment may name a marker; the YAML itself may not.
if q '... comments = ""' "$ci" | grep -qiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|skip-checks|head_commit\.message|commits\[[^]]*\]\.message'; then
  bad "$ci: no job or step may depend on a [skip ci] marker or the commit message (N4)"
fi

# N7: the job set is the one the decision record names last.
want_jobs="$(grep -oE 'CI job set[^`]*`[^`]+`' "$memory_file" 2>/dev/null | tail -n 1 | sed -E 's/.*`([^`]+)`$/\1/' | tr ' ,' '\n\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
have_jobs="$(q '.jobs | keys | .[]' "$ci" | sort -u | tr '\n' ' ')"
if [ -z "$want_jobs" ]; then
  bad "$memory_file records no CI job set (N7)"
elif [ "$want_jobs" != "$have_jobs" ]; then
  bad "$ci: the jobs are ${have_jobs% }, but $memory_file records ${want_jobs% }: a job set change needs a decision entry (N7)"
fi

# The build job: the one holding the gradle step.
job=""
for j in $(q '.jobs | keys | .[]' "$ci"); do
  if q ".jobs[\"$j\"].steps[].run" "$ci" | grep -qF "$gradle_line"; then job="$j"; break; fi
done

# The gradle run runs every task it names.
if q ".jobs[\"$job\"].steps[].run" "$ci" | grep -F "$gradle_line" | grep -qE '(^|[[:space:]])(-x|--exclude-task)([[:space:]=]|$)'; then
  bad "$ci: the gradle run may not exclude a task (-x, --exclude-task)"
fi

# Temurin of the toolchain, in every setup-java of the job.
setups=0
setups_ok=0
while IFS= read -r setup; do
  setups=$((setups + 1))
  [ "$setup" = "temurin $version" ] && setups_ok=$((setups_ok + 1))
done < <(q ".jobs[\"$job\"].steps[] | select(has(\"uses\")) | select(.uses | test(\"^actions/setup-java@\")) | (.with.distribution | tostring) + \" \" + (.with[\"java-version\"] | tostring)" "$ci")
[ "$setups" -gt 0 ] && [ "$setups_ok" -eq "$setups" ] || bad "$ci: job $job must set up Temurin $version, the toolchain of $build_file"

[ "$(q ".jobs[\"$job\"][\"continue-on-error\"]" "$ci")" != "true" ] || bad "$ci: job $job may not continue on error (job)"

# Steps of the build job, one TSV line each: index name uses repository path token persist-credentials run if
# continue-on-error id ("null" for an absent value). A tab or newline in a value (a multi-line path: or run: block) is
# a space, so each step stays one line.
names=(); uses=(); repos=(); paths=(); persists=(); runs=(); ifs_=(); ids=()
while IFS=$'\t' read -r idx name use repo path token persist run iff coe id; do
  names[idx]="$name"; uses[idx]="$use"; repos[idx]="$repo"; paths[idx]="$path"
  persists[idx]="$persist"; runs[idx]="$run"; ifs_[idx]="$iff"; ids[idx]="$id"
  if [ "$coe" = "true" ]; then bad "$ci: job $job may not continue on error ($name)"; fi
done < <(q ".jobs[\"$job\"].steps | to_entries | .[] | [.key, (.value.name | tostring), (.value.uses | tostring), (.value.with.repository | tostring), (.value.with.path | tostring), (.value.with.token | tostring), (.value.with[\"persist-credentials\"] | tostring), (.value.run | tostring), (.value[\"if\"] | tostring), (.value[\"continue-on-error\"] | tostring), (.value.id | tostring)] | map(tostring | sub(\"[\\t\\n]\"; \" \")) | @tsv" "$ci")

label() { [ "${names[$1]}" != "null" ] && echo "${names[$1]}" || echo "${uses[$1]}"; }

checkout=""
for i in "${!uses[@]}"; do
  case "${uses[$i]}" in actions/checkout@*) ;; *) continue ;; esac
  [ "${repos[$i]}" = "$contract_repo" ] || continue
  [ -n "$checkout" ] || checkout="$i"
done

if [ "$contract_ci" -eq 0 ]; then
  :   # no contract checkout to hold to its rules: the jobs below are checked for contract steps instead
elif [ -z "$checkout" ]; then
  bad "$ci: job $job has no step that checks out $contract_repo"
else
  [ "${names[$checkout]}" = "$checkout_name" ] || bad "$ci: the $contract_name checkout step must be named \"$checkout_name\""
  [ "${persists[$checkout]}" != "false" ] || bad "$ci: the $contract_name checkout must keep its credentials for the read-only check"
  [ "${paths[$checkout]}" = "contract" ] || bad "$ci: the $contract_name checkout must go to path contract"
  readonly_at=$((checkout + 1))
  [ "${runs[$readonly_at]:-}" = "$readonly_run" ] || bad "$ci: the step after the $contract_name checkout must run $readonly_run"
  # Both steps run on every event: an if could skip the checkout or the read-only proof.
  for i in "$checkout" "$readonly_at"; do
    [ -n "${names[$i]:-}" ] || continue
    [ "${ifs_[$i]}" = "null" ] || bad "$ci: step $(label "$i") may not have an if"
  done

  # After the checkout, a step that uses always()/failure()/cancelled() must have exactly the if
  # `failure() && steps.<id>.outcome == 'failure'` with <id> a step after the read-only step, so it runs only when that
  # later step ran and failed.
  gate_re='^(\$\{\{ *)?failure\(\) && steps\.([A-Za-z0-9_-]+)\.outcome == '\''failure'\''( *\}\})?$'
  for i in "${!uses[@]}"; do
    [ "$i" -gt "$checkout" ] || continue
    expr="${ifs_[$i]}"
    [ "$expr" != "null" ] || continue
    printf '%s' "$expr" | grep -Eq 'always\(\)|failure\(\)|cancelled\(\)' || continue
    gated=0
    if [[ "$expr" =~ $gate_re ]]; then
      gate="${BASH_REMATCH[2]}"
      for k in "${!ids[@]}"; do
        if [ "${ids[$k]}" = "$gate" ] && [ "$k" -gt "$readonly_at" ]; then gated=1; fi
      done
    fi
    [ "$gated" -eq 1 ] || bad "$ci: step $(label "$i") runs after a failed contract checkout (if: $expr)"
  done
fi

# Every job that runs ./gradlew generates code or starts the application (TASK-2.3): it checks out the
# contract, proves the token read-only, checks out the pin right after, and passes the spec to every ./gradlew run.
pin_run="bash .claude/scripts/contract-pin.sh contract"
spec_arg="-Pcontract.spec=contract/dist/openapi.yaml"
# Without the openapi-contract profile no job has a contract step: its scripts and its secret are not installed.
if [ "$contract_ci" -eq 0 ]; then
  for j in $(q '.jobs | keys | .[]' "$ci"); do
    [ "$(q "[.jobs[\"$j\"].steps[] | select((.with.path // \"\") == \"contract\" or ((.with.repository // \"\") != \"\" and .with.repository == \"$contract_repo\"))] | length" "$ci")" = 0 ] \
      || bad "$ci: job $j checks out a contract, but the openapi-contract profile is not installed"
    q ".jobs[\"$j\"].steps[].run" "$ci" | grep -qE "$contract_scripts_re" \
      && bad "$ci: job $j runs a script of the openapi-contract profile, which is not installed: $(q ".jobs[\"$j\"].steps[].run" "$ci" | grep -oE "$contract_scripts_re" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    q ".jobs[\"$j\"].steps[].run" "$ci" | grep -qF -e "-Pcontract.spec" \
      && bad "$ci: job $j passes -Pcontract.spec, but the openapi-contract profile is not installed"
  done
fi
for j in $(q '.jobs | keys | .[]' "$ci"); do
  [ "$contract_ci" -eq 1 ] || break
  q ".jobs[\"$j\"].steps[].run" "$ci" | grep -qE '\./gradlew' || continue
  jruns=(); jrepos=(); jnames=()
  while IFS=$'\t' read -r idx repo run; do
    jrepos[idx]="$repo"; jruns[idx]="$run"
  done < <(q ".jobs[\"$j\"].steps | to_entries | .[] | [.key, (.value.with.repository | tostring), (.value.run | tostring | sub(\"\\n.*\"; \"\"))] | @tsv" "$ci")
  jco=""
  for i in "${!jrepos[@]}"; do
    [ "${jrepos[$i]}" = "$contract_repo" ] && { jco="$i"; break; }
  done
  if [ -z "$jco" ]; then
    bad "$ci: job $j generates code or starts the application but does not check out @@KIT_CONTRACT_REPO@@"
  else
    [ "${jruns[$((jco + 1))]:-}" = "$readonly_run" ] \
      || bad "$ci: job $j: the step after the $contract_name checkout must run $readonly_run"
    [ "${jruns[$((jco + 2))]:-}" = "$pin_run" ] \
      || bad "$ci: job $j: the step after the read-only check must run $pin_run"
  fi
  if q ".jobs[\"$j\"].steps[].run" "$ci" | grep -F "./gradlew" | grep -vqF -e "$spec_arg"; then
    bad "$ci: job $j: every ./gradlew run must pass $spec_arg"
  fi
done

[ "$baselines" -eq 0 ] || echo "ci-workflow: $baselines baseline finding(s) in workflows the kit does not own, not failed"
[ "$fail" -eq 0 ] && echo "ci-workflow: ok"
exit "$fail"
