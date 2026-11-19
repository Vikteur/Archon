#!/usr/bin/env bash
# Tests for .archon/scripts/rebase-and-resume.sh against throwaway repos with a real bare origin and a stub archon: an
# unpushed branch is rebased and not pushed, a pushed one is lease-pushed, a conflict exits 3 with the branch unchanged,
# YAML drift exits 4 before anything changes, and the refusals (main, dirty, not failed, parked, not build-feature).
# It never launches a run.
# Usage: bash .archon/scripts/test/rebase-and-resume.test.sh   (exit 0 = all pass)
set -uo pipefail
# The scripts' defaults, not the checkout's .archon/kit.yaml (an install's build_workflow differs).
export KIT_CONFIG=/dev/null

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rebase-and-resume.sh"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
out=""

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}

# The stub archon: `workflow get` prints $root/<case>/run.json, every call is logged to $root/<case>/archon.log.
cat > "$root/archon" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CASE/archon.log"
case "$1 $2" in
  "workflow get") cat "$CASE/run.json" ;;
  "workflow resume") [ -f "$CASE/resume-fails" ] && exit 1; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$root/archon"
export ARCHON="$root/archon"

YAML_V1='name: build-feature
nodes:
  - id: ticket
    bash: echo ticket
  - id: implement
    prompt: &impl build it
  - id: open-pr
    bash: echo open
  - id: ci
    bash: echo ci
'

# setup <case> <pushed|unpushed>: a bare origin, a run worktree on build-feature-123 with one commit, main moved on by
# a second clone, the pinned YAML (= origin's), a failed run record whose completed nodes are ticket and implement.
setup() {
  export CASE="$root/$1"; mkdir -p "$CASE"
  dir="$CASE/wt"; other="$CASE/other"
  export RECOVERY_DIR="$CASE/recovery"
  git init -q --bare -b main "$CASE/origin.git"
  git clone -q "$CASE/origin.git" "$dir" 2>/dev/null
  for c in "$dir"; do git -C "$c" config user.name t; git -C "$c" config user.email t@t; done
  mkdir -p "$dir/.archon/workflows"; printf '%s' "$YAML_V1" > "$dir/.archon/workflows/build-feature.yaml"
  echo base > "$dir/a.txt"; git -C "$dir" add -A; git -C "$dir" commit -qm base; git -C "$dir" push -q origin main 2>/dev/null
  git clone -q "$CASE/origin.git" "$other" 2>/dev/null
  git -C "$other" config user.name t; git -C "$other" config user.email t@t
  git -C "$dir" switch -qc build-feature-123
  echo feature > "$dir/f.txt"; git -C "$dir" add -A; git -C "$dir" commit -qm feature
  [ "$2" = pushed ] && git -C "$dir" push -q -u origin build-feature-123 2>/dev/null
  echo main > "$other/m.txt"; git -C "$other" add -A; git -C "$other" commit -qm main; git -C "$other" push -q origin main 2>/dev/null
  mkdir -p "$CASE/src/project/.archon/workflows"; printf '%s' "$YAML_V1" > "$CASE/src/project/.archon/workflows/build-feature.yaml"
  jq -n --arg wt "$dir" --arg src "$CASE/src" '{id: "run1", workflow_name: "build-feature", status: "failed",
    working_path: $wt, metadata: {workflow_source: {root: $src}},
    nodes: [{nodeId: "ticket", state: "completed"}, {nodeId: "implement", state: "completed"}, {nodeId: "open-pr", state: "failed"}]}' > "$CASE/run.json"
  before=$(git -C "$dir" rev-parse HEAD)
}
main_yaml() { # main_yaml <yaml>: origin/main's build-feature.yaml becomes <yaml>
  git -C "$other" pull -q 2>/dev/null; printf '%s' "$1" > "$other/.archon/workflows/build-feature.yaml"
  git -C "$other" commit -qam yaml; git -C "$other" push -q origin main 2>/dev/null
}
run() { out=$(bash "$script" "$@" 2>&1); rc=$?; }
resumes() { grep -c '^workflow resume --detach run1$' "$CASE/archon.log" 2>/dev/null; }
launched() { grep -qE '^workflow run' "$CASE/archon.log" 2>/dev/null; }

# 1. Unpushed branch: rebased onto origin/main, not pushed, resumed once, result recorded.
setup unpushed unpushed
node "$(dirname "$script")/recovery-state.js" record - >/dev/null <<< '{"run":"run1","signature":"S12","action":"repair","step":"rebase-and-resume","breaker":"exempt"}'
run run1 --signature S12
check "1 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "1 one JSON line, rebased, not pushed, resumed" $([ "$(tail -1 <<< "$out" | jq -c '[.rebased,.pushed,.resumed]')" = '[true,false,true]' ]; echo $?)
check "1 branch sits on origin/main" $(git -C "$dir" merge-base --is-ancestor origin/main HEAD; echo $?)
check "1 nothing pushed" $(! git -C "$CASE/origin.git" rev-parse -q --verify build-feature-123 >/dev/null; echo $?)
check "1 resumed once" $([ "$(resumes)" = 1 ]; echo $?)
check "1 never launches" $(! launched; echo $?)
out=$(node "$(dirname "$script")/recovery-state.js" show run1)
check "1 result recorded" $(jq -r '.history[-1].result' <<< "$out" | grep -q 'resumed (S12)'; echo $?)

# 2. Pushed branch: lease-pushed after the rebase.
setup pushed pushed
run run1
check "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
check "2 pushed" $([ "$(tail -1 <<< "$out" | jq -r .pushed)" = true ]; echo $?)
check "2 origin has the rebased branch" $([ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$CASE/origin.git" rev-parse build-feature-123)" ]; echo $?)

# 3. Conflict: exit 3, the branch unchanged, no resume.
setup conflict pushed
echo mine > "$dir/m.txt"; git -C "$dir" add -A; git -C "$dir" commit -qm conflicting; before=$(git -C "$dir" rev-parse HEAD)
run run1
check "3 exit 3" $([ "$rc" -eq 3 ]; echo $?)
check "3 branch unchanged" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ] && [ -z "$(git -C "$dir" status --porcelain)" ]; echo $?)
check "3 not resumed" $([ "$(resumes)" = 0 ]; echo $?)

# 4. YAML drift on a node still to run: exit 4, nothing changed, no resume, no launch.
setup drift pushed
main_yaml "${YAML_V1/echo ci/echo ci2}"
run run1
check "4 exit 4" $([ "$rc" -eq 4 ]; echo $?)
check "4 names the node" $(grep -q 'node ci changed' <<< "$out"; echo $?)
check "4 branch unchanged" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ]; echo $?)
check "4 not resumed, never launched" $([ "$(resumes)" = 0 ] && ! launched; echo $?)

# 4b. --keep-launch-yaml (owner decision 2026-10-23, TASK-7.3): a node to run that only changed keeps its launch YAML,
# the branch is rebased and the run resumed; a node main added still drifts.
setup keep pushed
main_yaml "${YAML_V1/echo ci/echo ci2}"
run run1 --keep-launch-yaml
check "4b changed node, --keep-launch-yaml: exit 0, rebased and resumed" $([ "$rc" -eq 0 ] && [ "$(resumes)" = 1 ] && git -C "$dir" merge-base --is-ancestor origin/main HEAD; echo $?)
check "4b says the launch YAML is kept" $(grep -q 'launch YAML kept' <<< "$out"; echo $?)
setup keepadded unpushed
main_yaml "$YAML_V1  - id: extra
    bash: echo x
"
run run1 --keep-launch-yaml
check "4b an added node still drifts with --keep-launch-yaml" $([ "$rc" -eq 4 ] && [ "$(resumes)" = 0 ]; echo $?)

# 5. A change to a completed node only is no drift.
setup donechange unpushed
main_yaml "${YAML_V1/echo ticket/echo ticket2}"
run run1 --dry-run
check "5 a completed node's change is no drift" $([ "$rc" -eq 0 ]; echo $?)

# 6. Drift through an anchor: implement (completed) changes &impl, a node still to run uses *impl.
setup anchor unpushed
yaml_a="${YAML_V1/bash: echo ci/prompt: *impl}"
printf '%s' "$yaml_a" > "$CASE/src/project/.archon/workflows/build-feature.yaml"
main_yaml "${yaml_a/&impl build it/&impl build it well}"
run run1
check "6 a changed anchor used by a node to run: exit 4" $([ "$rc" -eq 4 ] && grep -q 'uses \*impl' <<< "$out"; echo $?)

# 7. Main added a node, and the header changed: both drift.
setup added unpushed
main_yaml "$YAML_V1  - id: extra
    bash: echo x
"
run run1; check "7 an added node: exit 4" $([ "$rc" -eq 4 ] && grep -q 'added node extra' <<< "$out"; echo $?)
setup header unpushed
main_yaml "${YAML_V1/name: build-feature/name: build-feature
env: x}"
run run1; check "7 a changed header: exit 4" $([ "$rc" -eq 4 ]; echo $?)

# 8. Dry run: says what it would do, changes nothing, no resume.
setup dry unpushed
run run1 --dry-run
check "8 dry run exit 0" $([ "$rc" -eq 0 ] && grep -q 'would rebase' <<< "$out"; echo $?)
check "8 dry run changes nothing" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ] && [ "$(resumes)" = 0 ] && [ ! -e "$RECOVERY_DIR/runs/run1.json" ]; echo $?)

# 9. Refusals: exit 1, nothing changed.
setup refuse unpushed
refused() { # refused <name>: exit 1, the branch unchanged, no resume
  check "9 $1: exit 1" $([ "$rc" -eq 1 ]; echo $?)
  check "9 $1: nothing changed" $([ "$(git -C "$dir" rev-parse HEAD)" = "$before" ] && [ "$(resumes)" = 0 ] && ! launched; echo $?)
}
jq '.status = "running"' "$CASE/run.json" > "$CASE/r" && mv "$CASE/r" "$CASE/run.json"; run run1; refused "a running run"
jq '.status = "failed" | .workflow_name = "other"' "$CASE/run.json" > "$CASE/r" && mv "$CASE/r" "$CASE/run.json"; run run1; refused "another workflow"
jq '.workflow_name = "build-feature"' "$CASE/run.json" > "$CASE/r" && mv "$CASE/r" "$CASE/run.json"
echo dirt > "$dir/dirt.txt"; run run1; refused "a dirty worktree"; rm "$dir/dirt.txt"
node "$(dirname "$script")/recovery-state.js" park run1 held >/dev/null; run run1; refused "a parked run"; rm -rf "$RECOVERY_DIR"
git -C "$dir" switch -q main; before=$(git -C "$dir" rev-parse HEAD); run run1; refused "the main branch"
git -C "$dir" switch -qc feat/x; run run1; refused "a branch that is not build-feature-<n>"
git -C "$dir" switch -q build-feature-123; before=$(git -C "$dir" rev-parse HEAD)
rm "$CASE/src/project/.archon/workflows/build-feature.yaml"; run run1; refused "no pinned YAML"

# 10. The resume fails after the rebase: exit 1, said so.
setup resumefail unpushed
touch "$CASE/resume-fails"; run run1
check "10 a failed resume: exit 1" $([ "$rc" -eq 1 ] && grep -q 'resume failed' <<< "$out"; echo $?)

# 11. Usage.
run; check "11 no run id: exit 2" $([ "$rc" -eq 2 ]; echo $?)
run run1 --bogus; check "11 unknown option: exit 2" $([ "$rc" -eq 2 ]; echo $?)
run 'a;b'; check "11 a run id with a shell character: exit 2" $([ "$rc" -eq 2 ]; echo $?)

echo "rebase-and-resume: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
