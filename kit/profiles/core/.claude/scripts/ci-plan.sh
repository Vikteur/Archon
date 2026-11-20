#!/usr/bin/env bash
# The run-or-reuse classifier (CI plan 2026-10-20, C10; owner decisions D1, D2, D3): for each job of
# .github/workflows/ci.yml, either "run", or "reuse" the green run of another commit whose inputs had the same
# fingerprint. A reuse is not a skip: it names the SHA where the same inputs passed. Standalone in Phase 0; ci-local.sh
# calls it from Phase 1 on.
#   ci-plan.sh [--self-from <ref>] <repo> <sha> [--base <sha>] [--all|--audit] [--explain]
#   ci-plan.sh --audit-run <job> <worktree> [--base <sha>] [--record] [--report <file>] -- <command...>
#   ci-plan.sh --audit-trace <job> <worktree> <strace-file> [--base <sha>] [--record]
# Plan. Plans on the tested tree: with --base, <sha> merged into <base> as ci-local.sh tests a pull request (git
# merge-tree, nothing is checked out); without it, <sha>'s own tree. Prints to stdout a header "# ci-plan ..." and one
# line per job of ci.yml at the tested tree:
#   <job> run fp=<hex|->[ shadow=<source-sha>]
#   <job> reuse <source-sha> fp=<hex>
# and the reason for each job to stderr ("ci-plan: <job>: ..."; --explain adds the fingerprint's parts). Exit 0 with a
# plan, 2 on a usage error. Whatever goes wrong, the answer is "run": in doubt, run.
# Run the BASE's copy, never the head's (red team F1): a head that changes this file would otherwise plan itself. The
# caller runs `ci-plan.sh --self-from <base-sha> <repo> <sha> --base <base-sha>`, which executes the blob
# git show <base-sha>:.claude/scripts/ci-plan.sh (every job runs when the base has none). The executed blob is part of
# every fingerprint, and the tested tree's copy is an input of every job.
# Fingerprint, per job: sha256 over the salt (CI_PLAN_SALT, else the file CI_PLAN_SALT_FILE, default
# $CI_LOCAL_ROOT/ci-plan.salt; none = "none"), the runner class (CI_PLAN_RUNNER, else OS, bash, git, java, node, yq, jq
# and docker versions), the executed planner's blob, the job's manifest rule (.github/ci-inputs.yml) and the
# exclusions that held, the git ls-tree lines of its inputs at the tested tree, the contract commit the pin of
# gradle.properties resolves to (jobs with contract: true), the sorted mutation targets with their blobs (mutation),
# and the local ids of the Dockerfile's base images (docker-context).
# Reuse sources come from the ledger CI_LEDGER (default $HOME/ci-local/ledger.jsonl), one JSON object a line,
# read defensively (a line that does not parse, or lacks a field, is no source). A source is a record with
#   event   "verdict" or "end"              sha     the commit the job ran on (40 hex), not this <sha>
#   job     the ci.yml job name             status  "success" (or result/state)
#   fp      this job's fingerprint, equal   ts      epoch seconds or ISO-8601 UTC (or time), at most
#                                                   CI_PLAN_MAX_AGE seconds old (default 86400, D2: 24 h)
#   runner  the runner class hash, equal when present (the fp holds it anyway)
# that actually ran: no "source"/"reused_from" field and decision not "reused" (a reuse is never a source: never
# chained), and is the newest record of its sha and job (a later red or reuse of that commit wins). A record
#   {"event":"violation","job":<job>,"rule":<rule hash>}  (written by --audit-run --record)
# stops every reuse of that job until its manifest rule changes.
# Every job runs, and none reuses, when: --all or --audit; the kill switch is on (CI_SCOPE=all, or the file
# CI_PLAN_SCOPE_FILE, default $CI_LOCAL_ROOT/scope-all); the merge conflicts; the manifest is missing or invalid; the
# ledger is missing. A contract job runs when the pin does not resolve or is a branch pin; mutation runs when its
# targets cannot be computed (no base).
# Mode, CI_REUSE: shadow (the default) prints "run" and logs "would reuse" to stderr, with shadow=<sha> on the line;
# live prints "reuse". Going live is the owner's switch, not this file's: CI_REUSE unset and the file
# $CI_LOCAL_ROOT/reuse-live present is live too (owner decision 2026-10-23); ci-local.sh exports it as CI_REUSE=live.
# Audit. --audit-run runs <command...> in <worktree> under strace (open, openat, openat2) and reports every tracked
# file it opened outside the job's inputs ("violation <job> <path>"), and folders it listed that hold none of its inputs;
# exit status is the command's. Without strace, or under an outer trace (strace cannot attach to a traced process: a
# test that runs ci-local.sh --audit inside an audited job), it runs the command untraced and says so. A process the
# command leaves running (a Gradle daemon) is still traced and strace -f waits for it: when the command ends, its
# leftover traced processes are stopped (SIGTERM) and counted. --audit-trace reads a trace
# made with `strace -f -qq -y -e trace=open,openat,openat2 -e status=successful`. --record appends the violations to
# the ledger. Reads through git objects are invisible to strace.
# CI_LOCAL_ROOT defaults to $HOME/ci-local. Overrides for tests: CI_PLAN_NOW (epoch), CI_PLAN_CONTRACT_COMMIT,
# CI_PLAN_CONTRACT_REMOTE (default https://github.com/@@KIT_CONTRACT_REPO@@.git), CI_PLAN_BASE_IMAGES,
# CI_PLAN_MUTATION_BASE (default origin/main, without --base).
set -uo pipefail
export LC_ALL=C

SELF=${BASH_SOURCE[0]}
# D3 v1: the only folders a job may leave out, and the only jobs that may leave them out.
ALLOWED_EXCLUDE=" backlog/ docs/retro/ docs/tokenomics/daily-token-reports/ docs/tokenomics/ticket-token-reports/ "
EXCLUDE_JOBS=" test mutation image "
# The mutation gate: the tested tree's copy answers which changed paths are targets (--list-targets), the one rule.
GATE_PATH=.claude/scripts/mutation-gate.sh
MANIFEST=.github/ci-inputs.yml
WORKFLOW=.github/workflows/ci.yml
PLANNER_PATH=.claude/scripts/ci-plan.sh

ci_root=${CI_LOCAL_ROOT:-$HOME/ci-local}
ledger=${CI_LEDGER:-$HOME/ci-local/ledger.jsonl}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

note() { echo "ci-plan: $*" >&2; }
usage() { sed -n '6,8p' "$SELF" >&2; exit 2; }
hash() { sha256sum | cut -d' ' -f1; }
now() { echo "${CI_PLAN_NOW:-$(date +%s)}"; }

# --self-from <ref>: run <ref>'s copy of this script, the base's. No copy there: every job runs.
if [ "${1:-}" = --self-from ]; then
  [ $# -ge 4 ] || usage
  from=$2 repo=$3 sha=$4
  shift 2
  if git -C "$repo" cat-file -e "$from:$PLANNER_PATH" 2>/dev/null; then
    git -C "$repo" show "$from:$PLANNER_PATH" > "$tmp/ci-plan.sh"
    CI_PLAN_FROM=$from bash "$tmp/ci-plan.sh" "$@"
    exit $?
  fi
  note "no $PLANNER_PATH at ${from:0:12}: every job runs"
  echo "# ci-plan sha=$sha from=$from planner=none mode=all"
  git -C "$repo" show "$sha:$WORKFLOW" 2>/dev/null | yq '.jobs | keys | .[]' 2>/dev/null | tr -d '\r' \
    | while IFS= read -r j; do [ -n "$j" ] && echo "$j run fp=-"; done
  exit 0
fi

# pat_re <entry>: the anchored ERE of a manifest or .dockerignore entry.
pat_re() {
  local p=${1#./} dir="" re
  p=${p#/}
  if [ "$p" = . ] || [ -z "$p" ]; then echo '.*'; return; fi
  case "$p" in */) dir=1; p=${p%/} ;; esac
  re=$(printf '%s' "$p" | sed -e 's/[][\.^$(){}|+]/\\&/g' -e 's/\*\*/\x01/g' -e 's/\*/.*/g' -e 's/\x01/.*/g' -e 's/?/./g')
  if [ -n "$dir" ]; then echo "^$re/.*"; else echo "^$re(/.*)?\$"; fi
}

# select_inputs <patfile>: the ls-tree lines on stdin whose path is an input. Pattern lines: "A <re>" always in,
# "I <re>" in unless an "X <re>" matches.
select_inputs() {
  awk -v pf="$1" 'BEGIN { while ((getline l < pf) > 0) { t = substr(l, 1, 1); r = substr(l, 3)
      if (t == "A") a[++na] = r; else if (t == "I") inc[++ni] = r; else if (t == "X") ex[++nx] = r } }
    { p = $0; sub(/^[^\t]*\t/, "", p)
      for (k = 1; k <= na; k++) if (p ~ a[k]) { print; next }
      hit = 0; for (k = 1; k <= ni; k++) if (p ~ inc[k]) { hit = 1; break }
      if (!hit) next
      for (k = 1; k <= nx; k++) if (p ~ ex[k]) next
      print }'
}

# runner_class: what the job's environment is made of; its hash is the runner class.
runner_class() {
  if [ -n "${CI_PLAN_RUNNER:-}" ]; then printf '%s\n' "$CI_PLAN_RUNNER"; return; fi
  local java=${JAVA_HOME_26_X64:-${JAVA_HOME_26:-${JAVA_HOME:-}}}
  uname -srm
  bash --version | head -n 1
  git --version
  { if [ -n "$java" ] && [ -x "$java/bin/java" ]; then "$java/bin/java" -version 2>&1; else java -version 2>&1; fi; } \
    | head -n 1 || echo "java absent"
  node --version 2>/dev/null || echo "node absent"
  yq --version 2>/dev/null || echo "yq absent"
  jq --version 2>/dev/null || echo "jq absent"
  timeout 5 docker version --format 'docker {{.Server.Version}}' 2>/dev/null || echo "docker absent"
}

# ---------------------------------------------------------------------------------------------------------------- plan

# job_rule <job>: the job's manifest entry as one JSON line ("null" when it has none).
job_rule() { yq -o=json -I0 ".jobs.\"$1\"" "$tmp/manifest" 2>/dev/null | tr -d '\r'; }
job_list() { yq ".jobs.\"$1\".\"$2\"[]" "$tmp/manifest" 2>/dev/null | tr -d '\r'; }
job_flag() { [ "$(yq ".jobs.\"$1\".\"$2\" // false" "$tmp/manifest" 2>/dev/null | tr -d '\r')" = true ]; }

# check_manifest: refuses a manifest that does not parse, has no job entries, or narrows beyond D3 v1.
check_manifest() {
  local j e
  [ "$(yq '.version' "$tmp/manifest" 2>/dev/null | tr -d '\r')" = 1 ] || { echo "no version: 1"; return 1; }
  [ "$(yq '.jobs | type' "$tmp/manifest" 2>/dev/null | tr -d '\r')" = '!!map' ] || { echo "no jobs map"; return 1; }
  for j in $(yq '.jobs | keys | .[]' "$tmp/manifest" | tr -d '\r'); do
    [ -n "$(job_list "$j" inputs)" ] || { echo "job $j has no inputs"; return 1; }
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      case "$EXCLUDE_JOBS" in *" $j "*) ;; *) echo "job $j may exclude nothing (D3 v1)"; return 1 ;; esac
      case "$ALLOWED_EXCLUDE" in *" $e "*) ;; *) echo "exclusion $e of $j is not in the D3 v1 list"; return 1 ;; esac
    done < <(job_list "$j" exclude)
  done
}

# is_data <path>: a data file (yaml, json, txt, a fixture): read for the exclusion proof, never followed, and it names
# a folder only in a path shape (backlog/, /backlog, "backlog"): a settings file's "Bash(backlog task edit *)" is a
# command, not a read of the folder. Code and the readers keep the word rule.
is_data() { case "$1" in *.yml|*.yaml|*.json|*.txt|*.lock|*.globs|*.env|*/fixtures/*) return 0 ;; esac; return 1; }

# closure <job>: the code files the job's run: lines name, and the code files those name, until nothing is added;
# each file's text, without its comment lines, goes to $tmp/code/<path> for the exclusion proof. Code is a tracked file
# under .claude/, scripts/, .archon/, .githooks/, .github/ or config/ that is not Markdown (prose names paths it never
# opens: docs/memory.md names every folder). It counts when its path, a tail of it of two parts or more, or its base
# name is a word. A data file (yaml, json, txt, a fixture) is read for the proof but not followed: ci.yml names every
# job's scripts. A comment line opens nothing, so it neither adds a file nor cancels an exclusion. Over-approximates
# otherwise, the safe direction for an exclusion proof.
closure() {
  local i f
  rm -rf "$tmp/code"; mkdir -p "$tmp/code"
  yq ".jobs.\"$1\".steps[].run // \"\"" "$tmp/ci.yml" 2>/dev/null > "$tmp/text"
  : > "$tmp/set"
  for i in $(seq 1 30); do
    grep -aoE '[A-Za-z0-9_.@+-][A-Za-z0-9_./@+-]*' "$tmp/text" | sed 's#^\./##; s#/$##' | sort -u > "$tmp/tok"
    awk 'NR == FNR { tok[$0] = 1; next }
      { p = $0; if (p !~ /^(\.claude|scripts|\.archon|\.githooks|\.github|config)\// || p ~ /\.md$/) next
        if (p in tok) { print p; next }
        n = split(p, c, "/"); s = c[n]
        if (s in tok) { print p; next }
        for (k = n - 1; k >= 1; k--) { s = c[k] "/" s; if (s in tok) { print p; next } } }' "$tmp/tok" "$tmp/files" \
      | sort -u > "$tmp/found"
    comm -13 "$tmp/set" "$tmp/found" > "$tmp/new"
    [ -s "$tmp/new" ] || break
    sort -u "$tmp/set" "$tmp/new" -o "$tmp/set"
    : > "$tmp/text"
    while IFS= read -r f; do
      mkdir -p "$tmp/code/$(dirname "$f")"
      git -C "$repo" cat-file blob "$tree:$f" 2>/dev/null | sed -E '/^[[:space:]]*(#|\/\/|\/?\*)/d' > "$tmp/code/$f"
      is_data "$f" || cat "$tmp/code/$f" >> "$tmp/text"
    done < "$tmp/new"
  done
  cat "$tmp/set"
}

# mutation_targets: "<path> <blob>" of each mutation target of the change, sorted; exit 1 when there is no base or
# the tree's gate cannot list them (no gate, or one without --list-targets): then the job runs. The tree's copy is the
# one that will run, and it is an input of the job, so a changed rule never reuses a run made under the old one.
mutation_targets() {
  local mb
  if [ -n "$base" ]; then mb=$base
  else
    mb=$(git -C "$repo" merge-base "$sha" "${CI_PLAN_MUTATION_BASE:-origin/main}" 2>/dev/null) || return 1
  fi
  git -C "$repo" -c core.quotePath=false diff --name-only --diff-filter=d "$mb" "$tree" 2>/dev/null > "$tmp/changed" \
    || return 1
  git -C "$repo" show "$tree:$GATE_PATH" > "$tmp/gate.sh" 2>/dev/null || return 1
  (cd "$tmp" && bash "$tmp/gate.sh" --list-targets < "$tmp/changed" > "$tmp/targets.raw" 2>/dev/null) || return 1
  sort -u "$tmp/targets.raw" > "$tmp/targets"
  while IFS= read -r p; do
    echo "$p $(git -C "$repo" rev-parse "$tree:$p" 2>/dev/null)"
  done < "$tmp/targets"
}

# kit_key <dotted key> <default>: the key of .archon/kit.yaml at the tested tree (env KIT_<KEY> first), else the default.
# Inline, not kit-config.sh: the planner runs as a blob of the base (git show), with no checkout beside it.
kit_key() {
  local env v=""
  env="KIT_$(printf '%s' "$1" | tr 'a-z.' 'A-Z_')"; v="${!env:-}"
  if [ -z "$v" ] && command -v yq >/dev/null 2>&1; then
    v=$(git -C "$repo" show "$tree:.archon/kit.yaml" 2>/dev/null | yq -r ".$1 // \"\"" 2>/dev/null) || v=""
    [ "$v" != null ] || v=""
  fi
  printf '%s' "${v:-$2}"
}

# contract_commit: the commit the pin resolves to; exit 1 with the reason when it cannot be trusted. The pin is the
# contract.tag_key line of gradle.properties, the hub contract.repo (kit.yaml; defaults @@KIT_CONTRACT_TAG_KEY@@ and
# @@KIT_CONTRACT_REPO@@).
contract_commit() {
  local pin refs c key hub
  key=$(kit_key contract.tag_key @@KIT_CONTRACT_TAG_KEY@@); hub=$(kit_key contract.repo @@KIT_CONTRACT_REPO@@)
  pin=$(git -C "$repo" show "$tree:gradle.properties" 2>/dev/null | grep -E "^${key}=" | head -n 1 \
    | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$pin" ] || { echo "no $key in gradle.properties"; return 1; }
  [[ "$pin" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the branch pin $pin depends on the branch name"; return 1; }
  if [ -n "${CI_PLAN_CONTRACT_COMMIT:-}" ]; then echo "$pin $CI_PLAN_CONTRACT_COMMIT"; return 0; fi
  refs=$(timeout 30 git ls-remote "${CI_PLAN_CONTRACT_REMOTE:-https://github.com/$hub.git}" \
    "refs/tags/$pin" "refs/tags/$pin^{}" 2>/dev/null) || { echo "the pin $pin did not resolve"; return 1; }
  c=$(printf '%s\n' "$refs" | awk -v t="refs/tags/$pin^{}" '$2 == t { print $1 }')
  [ -n "$c" ] || c=$(printf '%s\n' "$refs" | awk -v t="refs/tags/$pin" '$2 == t { print $1 }')
  [[ "$c" =~ ^[0-9a-f]{40}$ ]] || { echo "the pin $pin did not resolve"; return 1; }
  echo "$pin $c"
}

# docker_patterns: "I <re>" lines of the Docker context: the ! entries when .dockerignore denies by default.
docker_patterns() {
  local first e
  git -C "$repo" show "$tree:.dockerignore" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//' \
    | grep -vE '^(#|$)' > "$tmp/dockerignore"
  first=$(head -n 1 "$tmp/dockerignore")
  if [ "$first" != '*' ]; then echo "I .*"; return 1; fi
  sed -n 's/^!//p' "$tmp/dockerignore" | while IFS= read -r e; do echo "I $(pat_re "$e")"; done
}

base_images() {
  if [ -n "${CI_PLAN_BASE_IMAGES+x}" ]; then printf '%s\n' "$CI_PLAN_BASE_IMAGES"; return; fi
  git -C "$repo" show "$tree:Dockerfile" 2>/dev/null | tr -d '\r' \
    | awk 'toupper($1) == "FROM" { for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; break } }' | sort -u \
    | while IFS= read -r img; do
        echo "$img $(timeout 5 docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || echo absent)"
      done
}

# ledger_source <job> <fp> <runner>: the newest SHA that may be reused for the job, or "violation", or nothing.
ledger_source() {
  jq -nrR --arg job "$1" --arg fp "$2" --arg runner "$3" --arg sha "$sha" --arg rule "$rule_hash" \
    --argjson now "$(now)" --argjson max "${CI_PLAN_MAX_AGE:-86400}" '
    def ep: if type == "number" then .
      elif type == "string" then (try (sub("\\.[0-9]+"; "") | sub("[+]00:?00$"; "Z") | fromdateiso8601) catch null)
      else null end;
    def str: if type == "string" then . else "" end;
    [inputs | (try fromjson catch null) | select(type == "object") | select((.job | str) == $job)
     | .event = (.event // .ev) | .ts = (.ts // .time // .t)] as $all
    | if any($all[]; (.event | str) == "violation" and (.rule | str) == $rule) then "violation"
      else
        [$all[] | select((.event | str) as $e | $e == "verdict" or $e == "end" or $e == "reuse")
                | select((.sha | str) | test("^[0-9a-f]{40}$"))]
        | group_by(.sha) | map(last)
        | map(select((.event | str) != "reuse" and .narrowed != true
            and ((.status // .result // .state) | str) == "success"
            and (.fp | str) == $fp and .sha != $sha
            and ((.source // .reused_from // "") | str) == "" and (.decision | str) != "reused"
            and ((.runner // $runner) | str) == $runner
            and ((.ts | ep) as $t | $t != null and $t <= $now + 300 and $now - $t <= $max)))
        | sort_by(.ts | ep) | last | .sha // empty
      end' < "$ledger" 2>/dev/null
}

# plan_job <job>: sets fp, decision, source, why for one job.
plan_job() {
  local job=$1 rule e name re hit pins targets="" ctx="" contract="-" images="-" kept=""
  fp=- decision=run source="" why="" rule_hash=""
  if [ -n "$manifest_bad" ]; then why="manifest: $manifest_bad"; return; fi
  rule=$(job_rule "$job")
  if [ -z "$rule" ] || [ "$rule" = null ]; then why="no entry in $MANIFEST"; return; fi
  rule_hash=$(printf '%s' "$rule" | hash)
  : > "$tmp/pat"
  while IFS= read -r e; do [ -n "$e" ] && echo "A $(pat_re "$e")" >> "$tmp/pat"; done < <(yq '.always[]' "$tmp/manifest" | tr -d '\r')
  job_list "$job" inputs > "$tmp/inputs"
  if job_flag "$job" mutation-targets; then
    if ! targets=$(mutation_targets); then why="no base for the mutation targets, or $GATE_PATH cannot list them"; return; fi
    [ -z "$targets" ] || job_list "$job" when-targets > "$tmp/inputs"
  fi
  while IFS= read -r e; do [ -n "$e" ] && echo "I $(pat_re "$e")" >> "$tmp/pat"; done < "$tmp/inputs"
  if job_flag "$job" docker-context; then
    docker_patterns > "$tmp/dpat" || ctx="(.dockerignore does not deny by default: the whole tree)"
    cat "$tmp/dpat" >> "$tmp/pat"
    images=$(base_images)
  fi
  # An exclusion holds only when no reader names its folder as a word (a reader that names it may read it).
  job_list "$job" exclude > "$tmp/excl"
  if [ -s "$tmp/excl" ]; then
    closure "$job" > /dev/null
    job_list "$job" readers | sed 's/^/:(glob)/' > "$tmp/readers"
    while IFS= read -r e; do
      name=${e%/}; name=${name##*/}
      re="(^|[^A-Za-z0-9_-])${name//./\\.}([^A-Za-z0-9_-]|\$)"
      pre="(^|[^A-Za-z0-9_.-])${name//./\\.}/|/${name//./\\.}([^A-Za-z0-9_-]|\$)|[\"'\`]${name//./\\.}[\"'\`]"
      hit=$( { (cd "$tmp/code" && while IFS= read -r f; do
            if is_data "$f"; then grep -qIE "$pre" "$f" && echo "$f"; else grep -qIE "$re" "$f" && echo "$f"; fi
          done < "$tmp/set")
        xargs -d '\n' git -C "$repo" grep -I -l -E "$re" "$tree" -- < "$tmp/readers" | sed "s#^$tree:##"; } 2>/dev/null \
        | head -n 1)
      if [ -n "$hit" ]; then
        explain "$job: exclusion $e cancelled, $hit names $name"
      else
        echo "X $(pat_re "$e")" >> "$tmp/pat"; kept+="$e "
      fi
    done < "$tmp/excl"
  fi
  if job_flag "$job" contract; then
    if ! pins=$(contract_commit); then why="contract: $pins"; return; fi
    contract=$pins
  fi
  git -C "$repo" -c core.quotePath=false ls-tree -r --full-tree "$tree" | select_inputs "$tmp/pat" > "$tmp/in.$job"
  fp=$( {
    echo "ci-plan-fp v1"; echo "salt $salt"; echo "runner $runner"; echo "planner $planner"; echo "job $job"
    echo "rule $rule"; echo "kept-exclusions $kept"; echo "contract $contract"; echo "base-images $images"
    echo "mutation-targets"; printf '%s\n' "$targets"; echo "inputs"; cat "$tmp/in.$job"; } | hash)
  explain "$job: $(wc -l < "$tmp/in.$job" | tr -d ' ') input files${kept:+, excluding $kept}${ctx:+ $ctx}; contract $contract; targets $(printf '%s' "$targets" | grep -c .); fp=$fp"
  if [ -n "$force" ]; then why=$force; return; fi
  source=$(ledger_source "$job" "$fp" "$runner")
  case "$source" in
    violation) source=""; why="an audit found a read outside this rule; never reused until the rule changes" ;;
    "") why="no green run with this fingerprint in the last $(( ${CI_PLAN_MAX_AGE:-86400} / 3600 )) h" ;;
    *) decision=reuse; why="green on ${source:0:12} with the same fingerprint" ;;
  esac
}

explain() { [ -n "$verbose" ] && note "$*"; return 0; }

plan() {
  local job
  [ $# -ge 2 ] || usage
  repo=$1 sha=$2 base="" all="" audit="" verbose=""
  local asked=$2 hdr_mode
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base=${2:-}; shift ;;
      --all) all=1 ;;
      --audit) audit=1 ;;
      --explain) verbose=1 ;;
      *) note "unknown option $1"; usage ;;
    esac
    shift
  done
  sha=$(git -C "$repo" rev-parse --verify -q "$sha^{commit}") || { note "unknown commit $asked"; exit 2; }
  if [ -n "$base" ]; then
    base=$(git -C "$repo" rev-parse --verify -q "$base^{commit}") || { note "unknown base"; exit 2; }
  fi
  mode=${CI_REUSE:-shadow}
  [ -z "${CI_REUSE:-}" ] && [ -e "$ci_root/reuse-live" ] && mode=live
  case "$mode" in shadow|live) ;; *) note "CI_REUSE=$mode is neither shadow nor live: shadow"; mode=shadow ;; esac
  force=""
  [ -n "$all" ] && force="--all never reuses"
  [ -n "$audit" ] && force="--audit never reuses"
  if [ "${CI_SCOPE:-}" = all ] || [ -e "${CI_PLAN_SCOPE_FILE:-$ci_root/scope-all}" ]; then force="kill switch scope-all is on"; fi
  [ -n "$force" ] || [ -f "$ledger" ] || force="no ledger at $ledger"
  if [ -n "$base" ]; then
    if ! tree=$(git -C "$repo" merge-tree --write-tree "$base" "$sha" 2>/dev/null | head -n 1) \
        || ! [[ "$tree" =~ ^[0-9a-f]{40}$ ]]; then
      note "${sha:0:12} does not merge cleanly into ${base:0:12}: every job runs"
      echo "# ci-plan sha=$sha base=$base tree=conflict mode=all"
      git -C "$repo" show "$sha:$WORKFLOW" 2>/dev/null | yq '.jobs | keys | .[]' 2>/dev/null | tr -d '\r' \
        | while IFS= read -r j; do [ -n "$j" ] && { echo "$j run fp=-"; note "$j: merge conflict"; }; done
      return 0
    fi
  else
    tree=$(git -C "$repo" rev-parse "$sha^{tree}")
  fi
  git -C "$repo" -c core.quotePath=false ls-tree -r --name-only --full-tree "$tree" > "$tmp/files"
  git -C "$repo" show "$tree:$WORKFLOW" > "$tmp/ci.yml" 2>/dev/null || { note "no $WORKFLOW at the tested tree"; exit 2; }
  manifest_bad=""
  if ! git -C "$repo" show "$tree:$MANIFEST" > "$tmp/manifest" 2>/dev/null; then manifest_bad="no $MANIFEST"
  elif ! manifest_bad=$(check_manifest); then manifest_bad=${manifest_bad:-does not parse}
  else manifest_bad=""
  fi
  salt=${CI_PLAN_SALT:-}
  if [ -z "$salt" ] && [ -r "${CI_PLAN_SALT_FILE:-$ci_root/ci-plan.salt}" ]; then
    salt=$(tr -d '\r\n' < "${CI_PLAN_SALT_FILE:-$ci_root/ci-plan.salt}")
  fi
  salt=${salt:-none}
  runner=$(runner_class | hash)
  planner=$(git hash-object "$SELF")
  hdr_mode=$mode; [ -n "$force" ] && hdr_mode=all
  echo "# ci-plan sha=$sha${base:+ base=$base} tree=$tree planner=$planner${CI_PLAN_FROM:+ from=$CI_PLAN_FROM} runner=$runner mode=$hdr_mode"
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    plan_job "$job"
    if [ "$decision" = reuse ] && [ "$mode" = live ]; then
      echo "$job reuse $source fp=$fp"; note "$job: reuse, $why"
    elif [ "$decision" = reuse ]; then
      echo "$job run fp=$fp shadow=$source"; note "$job: run (shadow: would reuse ${source:0:12} fp=${fp:0:10}, $why)"
    else
      echo "$job run fp=$fp"; note "$job: run, $why"
    fi
  done < <(yq '.jobs | keys | .[]' "$tmp/ci.yml" | tr -d '\r')
}

# --------------------------------------------------------------------------------------------------------------- audit

# audit_setup <job> <worktree>: plans the job at the worktree's HEAD; its input paths go to inputs.all, sorted.
audit_setup() {
  local job=$1 wt=$2
  repo=$wt sha=$(git -C "$wt" rev-parse HEAD) || { note "$wt is not a git worktree"; exit 2; }
  tree=$(git -C "$wt" rev-parse "HEAD^{tree}")
  verbose="" force="" ledger=/dev/null salt=- runner=- planner=-
  git -C "$repo" -c core.quotePath=false ls-tree -r --name-only --full-tree "$tree" > "$tmp/files"
  git -C "$repo" show "$tree:$WORKFLOW" > "$tmp/ci.yml" 2>/dev/null
  manifest_bad=""
  if ! git -C "$repo" show "$tree:$MANIFEST" > "$tmp/manifest" 2>/dev/null; then manifest_bad="no $MANIFEST"
  elif ! manifest_bad=$(check_manifest); then manifest_bad=${manifest_bad:-does not parse}
  else manifest_bad=""
  fi
  CI_PLAN_CONTRACT_COMMIT=${CI_PLAN_CONTRACT_COMMIT:-audit} CI_PLAN_BASE_IMAGES=${CI_PLAN_BASE_IMAGES:-audit} plan_job "$job"
  if [ -f "$tmp/in.$job" ]; then sed 's/^[^\t]*\t//' "$tmp/in.$job" | sort -u > "$tmp/inputs.all"
  else
    note "audit $job: no input set ($why); every read is reported"; : > "$tmp/inputs.all"
  fi
}

# audit_report <job> <worktree> <trace>: the report lines; sets violations.
audit_report() {
  local job=$1 wt trace=$3 n m
  wt=$(cd "$2" && pwd -P)
  # "= 3</abs/path>" is the opened file (strace -y); paths in the worktree, without its .git.
  sed -nE 's#.*\) = [0-9]+<([^>]*)>$#\1#p' "$trace" | awk -v w="$wt/" 'index($0, w) == 1 { print substr($0, length(w) + 1) }' \
    | grep -vE '^\.git(/|$)' | sort -u > "$tmp/opened"
  sort -u "$tmp/files" > "$tmp/tracked"
  comm -12 "$tmp/opened" "$tmp/tracked" > "$tmp/read"
  comm -23 "$tmp/read" "$tmp/inputs.all" > "$tmp/outside"
  # A listed folder that holds tracked files and none of the inputs: the job walked something it does not declare.
  comm -23 "$tmp/opened" "$tmp/tracked" > "$tmp/other"
  awk 'function dirs(p, arr,   n, c, k, s) { n = split(p, c, "/"); s = ""
         for (k = 1; k < n; k++) { s = s (k > 1 ? "/" : "") c[k]; arr[s] = 1 } }
    FILENAME == ARGV[1] { dirs($0, td); next }
    FILENAME == ARGV[2] { dirs($0, id); next }
    ($0 in td) && !($0 in id) { print $0 "/" }' "$tmp/tracked" "$tmp/inputs.all" "$tmp/other" > "$tmp/walks"
  n=$(wc -l < "$tmp/read" | tr -d ' ')
  m=$(( $(wc -l < "$tmp/outside") + $(wc -l < "$tmp/walks") ))
  echo "audit $job: $n tracked files read, $m outside its inputs"
  sed "s#^#violation $job #" "$tmp/outside" "$tmp/walks"
  violations=$m
}

audit_record() {
  local job=$1 p
  mkdir -p "$(dirname "${CI_LEDGER:-$HOME/ci-local/ledger.jsonl}")"
  {
    flock 9
    cat "$tmp/outside" "$tmp/walks" | while IFS= read -r p; do
      jq -nc --arg job "$job" --arg rule "$rule_hash" --arg sha "$sha" --arg path "$p" --argjson ts "$(now)" \
        '{event: "violation", ts: $ts, sha: $sha, job: $job, rule: $rule, path: $path}'
    done >> "${CI_LEDGER:-$HOME/ci-local/ledger.jsonl}"
  } 9>> "${CI_LEDGER:-$HOME/ci-local/ledger.jsonl}.lock"
}

# Runs "$@" (after the job name and the exit-status file), writes its exit status to that file, then stops every process
# the same strace still traces: builtins only, so the scan itself starts no traced process. Untraced (TracerPid 0) it
# scans nothing, or it would stop every untraced process of the user.
# shellcheck disable=SC2016
audit_reap='job=$1 rcf=$2; shift 2; echo $$ > "$rcf.pid"; "$@"; rc=$?; echo "$rc" > "$rcf"; tp="" n=0
while read -r k v; do [ "$k" = TracerPid: ] && { tp=$v; break; }; done < /proc/$$/status
case $tp in ""|0) exit "$rc" ;; esac
for s in /proc/[0-9]*/status; do
  p=${s#/proc/}; p=${p%/status}; [ "$p" = "$$" ] && continue
  while read -r k v; do [ "$k" = TracerPid: ] && { [ "$v" = "$tp" ] && kill "$p" 2> /dev/null && n=$((n + 1)); break; }
  done < "$s" 2> /dev/null
done
[ "$n" -eq 0 ] || echo "audit $job: stopped $n process(es) the command left running" >&2
exit "$rc"'

audit_run() {
  local job wt record="" report="" rc trace
  [ $# -ge 2 ] || usage
  job=$1 wt=$2; shift 2
  base=""
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
      --base) base=$2; shift ;;
      --record) record=1 ;;
      --report) report=$2; shift ;;
      *) note "unknown option $1"; usage ;;
    esac
    shift
  done
  [ "${1:-}" = -- ] && shift
  [ $# -gt 0 ] || usage
  if ! command -v strace > /dev/null 2>&1; then
    note "audit $job: strace not found, the command runs without read tracing (no audit)"
    (cd "$wt" && "$@"); return $?
  fi
  if [ "$(awk '/^TracerPid:/ { print $2 }' /proc/self/status 2> /dev/null)" != 0 ]; then
    note "audit $job: already traced, the command runs without read tracing (no audit)"
    (cd "$wt" && "$@"); return $?
  fi
  trace=$tmp/trace
  (cd "$wt" && strace -f -qq -y -e trace=open,openat,openat2 -e status=successful -o "$trace" -- \
    bash -c "$audit_reap" audit-run "$job" "$tmp/rc" "$@"); rc=$?
  # The command's own exit status is the verdict: strace can end 1 on a ptrace race of its own, a PTRACE_LISTEN on a
  # stopped tracee that has just gone (ci-local.sh's kill_tree stops, then kills), seen on 737aeaf and c2f9df7 with
  # every suite green. strace then quits while the command runs on untraced: wait for it. Only without an exit status
  # of the command does strace's count.
  if [ ! -s "$tmp/rc" ] && [ -s "$tmp/rc.pid" ] && kill -0 "$(cat "$tmp/rc.pid")" 2> /dev/null; then
    note "audit $job: strace ended $rc before the command, which runs on untraced (the audit misses its later reads)"
    while kill -0 "$(cat "$tmp/rc.pid")" 2> /dev/null; do sleep 1; done
  fi
  if [ -s "$tmp/rc" ] && [ "$(cat "$tmp/rc")" != "$rc" ]; then
    note "audit $job: strace ended $rc, the command $(cat "$tmp/rc"): the command's exit status counts"
    rc=$(cat "$tmp/rc")
  fi
  audit_setup "$job" "$wt"
  audit_report "$job" "$wt" "$trace" > "$tmp/report"
  cat "$tmp/report" >&2
  [ -n "$report" ] && cp "$tmp/report" "$report"
  [ -n "$record" ] && [ "$violations" -gt 0 ] && audit_record "$job"
  return "$rc"
}

audit_trace() {
  local job wt trace record=""
  [ $# -ge 3 ] || usage
  job=$1 wt=$2 trace=$3; shift 3
  base=""
  while [ $# -gt 0 ]; do
    case "$1" in --base) base=$2; shift ;; --record) record=1 ;; *) note "unknown option $1"; usage ;; esac
    shift
  done
  [ -r "$trace" ] || { note "no trace $trace"; exit 2; }
  audit_setup "$job" "$wt"
  audit_report "$job" "$wt" "$trace"
  [ -n "$record" ] && [ "$violations" -gt 0 ] && audit_record "$job"
  [ "$violations" -eq 0 ]
}

case "${1:-}" in
  ""|-h|--help) usage ;;
  --audit-run) shift; audit_run "$@" ;;
  --audit-trace) shift; audit_trace "$@" ;;
  *) plan "$@" ;;
esac
