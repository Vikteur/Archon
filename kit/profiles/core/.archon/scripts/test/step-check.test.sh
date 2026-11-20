#!/usr/bin/env bash
# Tests for .archon/scripts/step-check.js, the live check after one agent inside build-feature's build loop: the skills
# of its step (skill-check --live) and what the scaffold-check gate would refuse (since step-base.sha): a file by hand
# the plan does not name in a form that holds, and on the build side a `Hand-written:` line in neither form, against a throwaway repo, a code-map leaf, an audit trail and a run log under a throwaway ARCHON_HOME.
# Usage: bash .archon/scripts/test/step-check.test.sh   (exit 0 = all pass)
set -uo pipefail
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$here/step-check.js"
pass=0; fail=0
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export ARCHON_HOME="$root/archon"   # the real ~/.archon is never read
run=0123456789abcdef0123456789abcdef
logs="$ARCHON_HOME/workspaces/owner/repo/logs"
mkdir -p "$logs"
art="$root/artifacts"
w="$root/w"
F=x-domain/src/testFixtures/java/a/b/domain
D=x-domain/src/main/java/a/b/domain

ok() { # ok <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "    $out"; fi
}
live() { out=$(cd "$w" && node "$script" "$art" "$run" "$1" 2>/dev/null); rc=$?; }
plan() { # plan <box: ' ' or x> [<extra line>]
  rm -rf "$art"; mkdir -p "$art/red"
  printf '## Steps\n- [x] (verify only) **Step 0 — bundle.**\n- [%s] **Step 1 — Guest.**\n  Test skills: object-mother-builders\n  Build skills: domain-modeling\n%s\n' \
    "$1" "${2:-}" > "$art/plan.md"
  touch -d 2026-10-18T10:00:30Z "$art/red/step-2.log"
  git -C "$w" rev-parse HEAD > "$art/step-base.sha"
}
add() { # add <file>: a file written by hand, committed
  mkdir -p "$w/$(dirname "$1")"; printf 'class %s {}\n' "$(basename "$1" .java)" > "$w/$1"
  git -C "$w" add -A; git -C "$w" commit -qm "add $(basename "$1")"
}
reset() { git -C "$w" reset -q --hard "$start"; }

git init -q -b main "$w"
cd "$w" || exit 2
git config user.name t; git config user.email t@t
mkdir -p docs/code-maps .apm-audit/sessions
cat > docs/code-maps/object-mother-builders.md <<'EOF'
## Scaffold
| Template | Target | Variables | Left to you |
|---|---|---|---|
| [domain/mother](../scaffold-templates/domain/mother.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<Name>Mother.java` | `package` | x |
EOF
cat > docs/code-maps/domain-modeling.md <<'EOF'
## Scaffold
| Template | Target | Variables | Left to you |
|---|---|---|---|
| [domain/create-request](../scaffold-templates/domain/create-request.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/Create<Name>Request.java` | `package` | x |
EOF
echo '.apm-audit/' > .gitignore
echo base > README.md; git add -A; git commit -qm base
start=$(git rev-parse HEAD)

# The run log: the workflow start and one write-tests and one build-step window of step 2 (checkbox 2 = Step 1).
ev() { # ev <type> <path> <id> <utc time>
  echo "{\"type\":\"$1\",\"ts\":\"$4\",\"execution\":{\"path\":\"$2\",\"invocation\":{\"id\":\"$3\",\"loopPath\":[{\"groupId\":\"implement\",\"iteration\":1}]}}}"
}
{
  echo "{\"type\":\"workflow_start\",\"workflow_id\":\"$run\",\"ts\":\"2026-10-18T09:00:00Z\"}"
  ev node_start implement.write-tests w1 2026-10-18T10:00:00Z; ev node_complete implement.write-tests w1 2026-10-18T10:01:00Z
  ev node_start implement.build-step b1 2026-10-18T10:01:01Z; ev node_complete implement.build-step b1 2026-10-18T10:02:00Z
} > "$logs/$run.jsonl"
load() { # load <utc time> <skill>
  echo "{\"type\":\"TOOL\",\"loggedAt\":\"$1\",\"tool\":\"Skill\",\"arg\":\"{\\\"skill\\\":\\\"$2\\\"}\",\"ok\":true}" >> .apm-audit/sessions/s.jsonl
}
load 2026-10-18T10:00:10Z object-mother-builders
load 2026-10-18T10:01:10Z domain-modeling

# 1. Test side: a Mother written by hand where a loaded skill's template fits fails the check, leaves the plan open.
reset; plan ' '; add "$F/GuestMother.java"
live test
ok "test: exits 0 on a miss" "$rc"
ok "test: a hand-written Mother says ok false" $(grep -q '"ok":false,"n":2,"side":"test"' <<< "$out"; echo $?)
ok "test: names the file" $(grep -qF "\"scaffold\":[\"$F/GuestMother.java\"]" <<< "$out"; echo $?)
ok "test: scaffold-missing.md names the file and the template" $(grep -qF "$F/GuestMother.java" "$art/scaffold-missing.md" && grep -qF 'domain/mother' "$art/scaffold-missing.md"; echo $?)
ok "test: scaffold-missing.md says it is the test agent's" $(grep -qx '# Scaffold missing — step 2, test side' "$art/scaffold-missing.md"; echo $?)
ok "test: scaffold-missing.md says why and how" $(grep -qF 'a template targets it: domain/mother (object-mother-builders)' "$art/scaffold-missing.md" && grep -qF 'the command `scripts/scaffold.sh --test --for <path>` prints' "$art/scaffold-missing.md"; echo $?)
ok "test: the plan stays as it was" $(grep -q '^- \[ \] \*\*Step 1' "$art/plan.md"; echo $?)

# 1b. Test side: a test file no template targets, not named, is a miss too.
reset; plan ' '; add x-domain/src/test/java/a/b/domain/GuestHelper.java
live test
ok "test: an unnamed file no template targets says ok false" $(grep -qF '"scaffold":["x-domain/src/test/java/a/b/domain/GuestHelper.java"]' <<< "$out" && grep -qF 'no template targets it, and the plan does not name it: add `Hand-written: x-domain/src/test/java/a/b/domain/GuestHelper.java — no-template: <shape>`' "$art/scaffold-missing.md"; echo $?)

# 2. The plan names it in a form that holds: ok, and an earlier scaffold-missing.md goes; a form that does not hold for
# the file is a miss.
reset; plan ' ' "Hand-written: $F/GuestMother.java — no-template: mother"; add "$F/GuestMother.java"
live test
ok "named: no-template where a template targets it says ok false" $(grep -q '"ok":false' <<< "$out" && grep -qF 'says no-template, but domain/mother (object-mother-builders) targets it' "$art/scaffold-missing.md"; echo $?)
reset; plan ' ' "Hand-written: $F/GuestMother.java — template-misfit: domain/mother — the Mother builds a graph"; add "$F/GuestMother.java"
echo old > "$art/scaffold-missing.md"
live test
ok "named: a file the plan names says ok" $(grep -q '"ok":true' <<< "$out"; echo $?)
ok "named: an ok check removes scaffold-missing.md" $([ ! -e "$art/scaffold-missing.md" ]; echo $?)

# 3. Only files since step-base count: one added before the step began is the gate's after the loop.
reset; add "$F/GuestMother.java"; plan ' '
live test
ok "base: a file from before the step is not counted" $(grep -q '"ok":true' <<< "$out"; echo $?)

# 4. Build side: a main file by hand where a template fits reopens the step.
reset; plan x; add "$D/CreateGuestRequest.java"
live build
ok "build: a hand-written main file says ok false" $(grep -q '"ok":false,"n":2,"side":"build"' <<< "$out"; echo $?)
ok "build: opens the step again" $(grep -q '^- \[ \] \*\*Step 1' "$art/plan.md" && grep -q '^- \[x\] (verify only)' "$art/plan.md"; echo $?)
ok "build: scaffold-missing.md says it is the build agent's" $(grep -qx '# Scaffold missing — step 2, build side' "$art/scaffold-missing.md" && grep -qF 'the command `scripts/scaffold.sh --for <path>` prints' "$art/scaffold-missing.md"; echo $?)

# 4b. Build side: a main file no template targets passes once the plan names it, a directory glob included.
reset; plan x; add "$D/GuestKind.java"
live build
ok "build: an unnamed file no template targets says ok false" $(grep -qF "\"scaffold\":[\"$D/GuestKind.java\"]" <<< "$out"; echo $?)
reset; plan x "- Hand-written: $D/** — no-template: enum"; add "$D/GuestKind.java"
live build
ok "build: a glob names it" $(grep -q '"ok":true' <<< "$out" && grep -q '^- \[x\] \*\*Step 1' "$art/plan.md"; echo $?)

# 4c. A `Hand-written:` line in neither form is the build side's: it reopens the step; the test side leaves it.
reset; plan x "Hand-written: $D/GuestKind.java — an enum, no template"; add "$D/GuestKind.java"
live build
ok "build: a malformed line says ok false, with its line; the file it fails to name too" $(grep -qF "\"scaffold\":[\"$D/GuestKind.java\",\"plan.md:6\"]" <<< "$out" && grep -q '^- \[ \] \*\*Step 1' "$art/plan.md" && grep -qF -- "- \`plan.md:6\`: \`Hand-written: $D/GuestKind.java — an enum, no template\` is in neither form" "$art/scaffold-missing.md"; echo $?)
reset; plan ' ' "Hand-written: $F/GuestMother.java — the old free reason"
live test
ok "test: a malformed line is not the test side's" $(grep -q '"ok":true' <<< "$out"; echo $?)

# 5. Build side: a test-tree file is the test side's, not counted again.
reset; plan x; add "$F/GuestMother.java"
live build
ok "build: a test-tree file is not the build side's" $(grep -q '"ok":true' <<< "$out" && grep -q '^- \[x\] \*\*Step 1' "$art/plan.md"; echo $?)

# 6. A skill miss alone says ok false too, with the skills, and no scaffold file.
reset; plan x; sed -i 's/domain-modeling/persistence-repository/' "$art/plan.md"
live build
ok "skills: a build skill never loaded says ok false" $(grep -q '"ok":false,"n":2,"side":"build","missing":\["persistence-repository"\],"scaffold":\[\]' <<< "$out"; echo $?)
ok "skills: skills-missing.md is written" $([ -s "$art/skills-missing.md" ] && [ ! -e "$art/scaffold-missing.md" ]; echo $?)

# 7. Nothing to judge (no step-base.sha) is left to the gates after the loop.
reset; plan ' '; add "$F/GuestMother.java"; rm "$art/step-base.sha"
live test
ok "no base: left to the gates" $(grep -q '"ok":true' <<< "$out"; echo $?)

# The build loop of build-feature runs this check after each agent, behind blocked-stop, and its build agent waits on
# the test side.
out=$(yq -o=json '.nodes[] | select(.id == "implement") | .loop_group.nodes' "$here/../workflows/build-feature-copilot.yaml" | node -e '
  const b = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const after = (id, side) => b.find(n => (n.depends_on || []).includes(id)
    && /blocked-stop\.sh[\s\S]*&&[\s\S]*step-check\.js/.test(n.bash || "") && new RegExp(`step-check\\.js.* ${side}\\b`).test(n.bash || ""));
  const t = after("write-tests", "test");
  const s = after("build-step", "build");
  const build = b.find(n => n.id === "build-step") || {};
  if (!t) console.log("no blocked-stop && step-check.js test after write-tests");
  if (t && !(build.depends_on || []).includes(t.id)) console.log("build-step does not run after the test check");
  if (t && !(build.when || "").includes(`$${t.id}.output.ok`)) console.log("build-step does not wait on the test check");
  if (!s) console.log("no blocked-stop && step-check.js build after build-step");
  if (b.some(n => /skill-check\.js/.test(n.bash || ""))) console.log("the loop still runs skill-check.js itself");')
ok "workflow: build-feature runs the step check inside the loop, after each agent" $([ -z "$out" ]; echo $?)

echo "step-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
