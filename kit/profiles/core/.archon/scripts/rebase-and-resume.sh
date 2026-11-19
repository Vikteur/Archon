#!/usr/bin/env bash
# Rebase a failed build-feature run's own branch onto origin/main and resume the run (P2: a script, not a model; owner
# decision 2026-10-20, D13: self-repair is allowed, and a lease push of the run's own branch outside a conflict is
# approved). recover-run.sh calls it for S12 (the push lost a race), S13 (main was red, now green) and after a script
# fix (S15).
#   rebase-and-resume.sh <run id> [--dry-run] [--signature <Snn>] [--keep-launch-yaml]
# A resume keeps the YAML the run launched with (TASK-66): Archon pinned it under the run's workflow source. So before
# anything changes, the pinned build-feature.yaml is compared with origin/main's, node by node (a node is the block
# that starts at "  - id: "). It stops with exit 4 when a node the resume would run (any node not completed) changed,
# was removed from main, or uses an anchor (*name) defined in a changed block; when main added a node; or when the
# header before the nodes changed. A YAML change needs a new run, never a resume of this one, and this script never
# launches one (no `archon workflow run`): a person or the delegator decides. --keep-launch-yaml (owner decision
# 2026-10-23, TASK-7.3) accepts a drift where nodes to run only changed (none added, gone, in the header or through an
# anchor): the run rebases and resumes on its launch YAML, and the result says so. recover-run.sh passes it once a run.
# Refused (exit 1, nothing changed) unless: the run is build-feature and failed; its worktree exists and is clean; its
# branch is build-feature-<digits> (never main or master); and the run is not parked in the recovery state.
# Then rebase-main.sh (beside this script) runs in the worktree: the rebase, and a --force-with-lease push only when
# the branch has an upstream (an unpushed branch is never pushed). A conflict aborts the rebase, leaves the branch as it
# was, and exits 3. Last, `archon workflow resume --detach <run>`; the result goes in the run's recovery state.
# --dry-run checks everything, changes nothing and says what it would do. --signature is recorded with the result.
# Prints one JSON line {run, branch, signature, rebased, pushed, resumed, dry_run, reason}.
# Exit 0: resumed (or would be). Exit 1: refused, or a step failed (it says which). Exit 2: usage. Exit 3: the rebase
# conflicts. Exit 4: the YAML drifted; launch a new run instead.
# Overrides for the tests: ARCHON (the archon command), RECOVERY_DIR (see recovery-state.js).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$here/kit-config.sh" 2>/dev/null || kit_get() { printf '%s' "$2"; }
BUILD_WORKFLOW="$(kit_get build_workflow build-feature BUILD_WORKFLOW)"
archon=${ARCHON:-archon}
run="" dry=false sig="" keep=false
usage() { echo "rebase-and-resume: $1" >&2; echo "usage: rebase-and-resume.sh <run id> [--dry-run] [--signature <Snn>] [--keep-launch-yaml]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true ;;
    --keep-launch-yaml) keep=true ;;
    --signature) [ $# -ge 2 ] || usage "--signature needs a value"; sig=$2; shift ;;
    -*) usage "unknown option $1" ;;
    *) [ -z "$run" ] || usage "one run id only"; run=$1 ;;
  esac
  shift
done
[ -n "$run" ] || usage "a run id is required"
[[ "$run" =~ ^[A-Za-z0-9-]+$ ]] || usage "not a run id: $run"

branch="" rebased=false pushed=false resumed=false
emit() { # emit <reason>
  jq -cn --arg run "$run" --arg branch "$branch" --arg sig "$sig" --argjson rebased "$rebased" --argjson pushed "$pushed" \
    --argjson resumed "$resumed" --argjson dry "$dry" --arg reason "$1" \
    '{run: $run, branch: ($branch | if . == "" then null else . end), signature: ($sig | if . == "" then null else . end),
      rebased: $rebased, pushed: $pushed, resumed: $resumed, dry_run: $dry, reason: $reason}'
}
note() { $dry || node "$here/recovery-state.js" result "$run" "rebase-and-resume: $1" >/dev/null 2>&1 || true; }
refuse() { echo "rebase-and-resume: $1" >&2; emit "$1"; exit 1; }

json=$("$archon" workflow get "$run" --json --verbose 2>/dev/null) && jq -e . >/dev/null 2>&1 <<< "$json" \
  || refuse "cannot read run $run from archon"
json=$(jq -c '.run // .' <<< "$json")
case "$(jq -r '.workflow_name // ""' <<< "$json")" in build-feature|"$BUILD_WORKFLOW") ;; *) refuse "run $run is not a $BUILD_WORKFLOW run" ;; esac
status=$(jq -r '.status // ""' <<< "$json")
[ "$status" = failed ] || refuse "run $run is $status, not failed"
wt=$(jq -r '.working_path // ""' <<< "$json")
[ -n "$wt" ] && [ -d "$wt" ] || refuse "the run's worktree is gone"
branch=$(git -C "$wt" symbolic-ref --short -q HEAD || true)
case "$branch" in
  main|master|'') refuse "the worktree is on '${branch:-detached HEAD}', not the run's own branch" ;;
esac
[[ "$branch" =~ ^build-feature-[0-9]+$ ]] || refuse "branch $branch is not a build-feature run branch"
[ -z "$(git -C "$wt" status --porcelain)" ] || refuse "the worktree has uncommitted changes"
parked=$(node "$here/recovery-state.js" show "$run" 2>/dev/null | jq -r '.parked // false')
[ "$parked" = true ] && refuse "run $run is parked"

# The YAML drift check, before anything changes.
src=$(jq -r '.metadata.workflow_source.root // ""' <<< "$json")
pinned="$src/project/.archon/workflows/build-feature.yaml"
[ -n "$src" ] && [ -f "$pinned" ] || refuse "the run's pinned build-feature.yaml is missing; cannot tell the YAML drift"
git -C "$wt" fetch -q origin main 2>/dev/null || refuse "cannot fetch origin main"
current=$(mktemp); trap 'rm -f "$current"' EXIT
git -C "$wt" show origin/main:.archon/workflows/build-feature.yaml > "$current" 2>/dev/null \
  || refuse "origin/main has no .archon/workflows/build-feature.yaml"
done_nodes=$(jq -c '[(.nodes // [])[] | select(.state == "completed") | .nodeId]' <<< "$json")
drift=$(node - "$pinned" "$current" "$done_nodes" <<'EOF'
const fs = require('fs');
const [pinnedFile, currentFile, doneJson] = process.argv.slice(2);
const done = new Set(JSON.parse(doneJson));
const split = text => {
  const parts = text.split(/^(?=  - id: )/m);
  const head = parts[0];
  const nodes = new Map(parts.slice(1).map(b => [b.match(/^  - id: *([^\s#]+)/)[1], b]));
  return { head, nodes };
};
const strip = b => b.replace(/\s+$/, '');
const p = split(fs.readFileSync(pinnedFile, 'utf8'));
const c = split(fs.readFileSync(currentFile, 'utf8'));
const why = [];
if (strip(p.head) !== strip(c.head)) why.push('the header before the nodes changed');
for (const id of c.nodes.keys()) if (!p.nodes.has(id)) why.push(`main added node ${id}`);
const changed = [...p.nodes.keys()].filter(id => !c.nodes.has(id) || strip(c.nodes.get(id)) !== strip(p.nodes.get(id)));
const anchors = new Set();
for (const id of changed) for (const m of p.nodes.get(id).matchAll(/&([\w-]+)/g)) anchors.add(m[1]);
for (const id of changed) for (const m of (c.nodes.get(id) || '').matchAll(/&([\w-]+)/g)) anchors.add(m[1]);
for (const [id, block] of p.nodes) {
  if (done.has(id)) continue;
  if (!c.nodes.has(id)) why.push(`node ${id} is gone from main`);
  else if (changed.includes(id)) why.push(`node ${id} changed`);
  else for (const m of block.matchAll(/\*([\w-]+)/g)) if (anchors.has(m[1])) why.push(`node ${id} uses *${m[1]}, which changed`);
}
process.stdout.write(why.join('; '));
EOF
) || refuse "the YAML drift check failed"
kept=""
if [ -n "$drift" ] && $keep && ! sed 's/; /\n/g' <<< "$drift" | grep -qvE '^node [^ ]+ changed$'; then
  echo "rebase-and-resume: YAML drift accepted, launch YAML kept ($drift)" >&2
  kept=", launch YAML kept ($drift)"
  drift=""
fi
if [ -n "$drift" ]; then
  echo "rebase-and-resume: the run's YAML differs from origin/main where the resume would run: $drift. A resume keeps its launch YAML (TASK-66): launch a new run instead; this script never does." >&2
  note "YAML drift, not resumed ($drift)"
  emit "YAML drift: $drift"
  exit 4
fi

if $dry; then
  behind=$(git -C "$wt" rev-list --count HEAD..origin/main)
  emit "would rebase $branch onto origin/main ($behind commit(s) behind) and resume run $run$kept"
  exit 0
fi

out=$(cd "$wt" && bash "$here/rebase-main.sh" main 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  echo "rebase-and-resume: $out" >&2
  note "rebase conflict, not resumed"
  emit "the rebase stopped: $(tail -1 <<< "$out")"
  exit 3
fi
line=$(tail -1 <<< "$out")
rebased=$(jq -r '.rebased // false' <<< "$line" 2>/dev/null || echo false)
pushed=$(jq -r '.pushed // false' <<< "$line" 2>/dev/null || echo false)

if ! "$archon" workflow resume --detach "$run" >/dev/null 2>&1; then
  note "rebased (pushed: $pushed), the resume failed"
  echo "rebase-and-resume: archon workflow resume $run failed" >&2
  emit "rebased, but the resume failed"
  exit 1
fi
resumed=true
note "rebased: $rebased, pushed: $pushed, resumed${sig:+ ($sig)}$kept"
emit "resumed$kept"
exit 0
