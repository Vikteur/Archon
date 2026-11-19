#!/usr/bin/env bash
# The plan node's one Gradle run (owner decision 2026-10-18; P2: a script, not a model): one task, offline, in a scratch
# copy of HEAD, for a design question the plan states. The plan node may not run Gradle itself (its denied_tools).
#   plan-spike.sh <artifacts-dir> <task> <question...>
# <task> is one Gradle task name (`compileJava`, `:shared-adapter:openApiGenerate`): no flags, no second task. Runs
# `./gradlew <task> --offline` in a copy of the committed HEAD under a temp dir, which is removed after; the checkout is
# never touched. Writes the question, the task, the exit code and the output's last 60 lines to
# <artifacts-dir>/plan-spike.md and prints the same. Once per run: a second call is refused, even after a failed one.
# Exit: Gradle's own exit code; 2 for a refused call. PLAN_SPIKE_TIMEOUT caps the run in seconds (default 900).
set -uo pipefail
art=${1:-}
task=${2:-}
shift 2 2>/dev/null || true
question=$*
if [ -z "$art" ] || [ ! -d "$art" ] || [ -z "$task" ] || [ -z "${question// /}" ]; then
  echo "usage: plan-spike.sh <artifacts-dir> <task> <question...>   (the question is required: it is why the run exists)" >&2
  exit 2
fi
if ! printf '%s' "$task" | grep -qxE ':?[A-Za-z][A-Za-z0-9_-]*(:[A-Za-z][A-Za-z0-9_-]*)*'; then
  echo "plan-spike: '$task' is not one Gradle task name (no flags, no second task)." >&2
  exit 2
fi
out="$art/plan-spike.md"
if [ -e "$out" ]; then
  echo "plan-spike: this run already had its one Gradle run ($out). Any other experiment is a @build plan step." >&2
  exit 2
fi
# Claimed before Gradle starts, so a killed or failed spike still counts as the one.
printf '# Plan spike\n\nQuestion: %s\nTask: `./gradlew %s --offline` at %s\n\n(running)\n' \
  "$question" "$task" "$(git rev-parse --short HEAD)" > "$out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive --format=tar HEAD | tar -x -C "$work" || { echo "plan-spike: could not copy HEAD" >&2; exit 1; }
start=$(date +%s)
(cd "$work" && timeout "${PLAN_SPIKE_TIMEOUT:-900}" ./gradlew "$task" --offline) > "$work/.spike.log" 2>&1
code=$?
secs=$(( $(date +%s) - start ))
{
  printf '# Plan spike\n\nQuestion: %s\nTask: `./gradlew %s --offline` at %s\nExit: %s after %ss\n\n```\n' \
    "$question" "$task" "$(git rev-parse --short HEAD)" "$code" "$secs"
  tail -n 60 "$work/.spike.log"
  printf '```\n'
} > "$out"
cat "$out"
exit "$code"
