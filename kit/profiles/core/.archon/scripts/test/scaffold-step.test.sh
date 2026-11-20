#!/usr/bin/env bash
# Tests for .archon/scripts/scaffold-step.js, which renders the plan's `Scaffold:` lines of build-feature's current step
# for one side before that side's agent starts: the side split (test trees before the test agent, the rest after), the
# vars the path fills in, a value with apostrophes rendered as written (no shell), the lines it refuses and reports
# (no such template, a template that does not target the path, bad JSON, a line not in the form), an existing file left
# alone, a line handled once per run, the report for the agent and the SCAFFOLD record the scaffold-check gate counts,
# a fenced block in a step, a path outside the repo, and one line that throws without stopping the others.
# Runs the real scripts/scaffold.sh and its Target matcher (scripts/ is linked) on fixture templates and a fixture
# code-map leaf in a throwaway repo, so the repo's own leaves and templates never change the result: a repo may link
# only its own templates in docs/scaffold-templates/project/, or have changed a kit template.
# Usage: bash .archon/scripts/test/scaffold-step.test.sh   (exit 0 = all pass)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
top="$(cd "$here/../.." && pwd)"
script="$here/scaffold-step.js"
pass=0; fail=0; out=""
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
w="$root/w"; art="$root/art"
D=x-domain/src/main/java/a/b/x/domain
F=x-domain/src/testFixtures/java/a/b/x/domain
M=application/src/main/resources/db/migration

ok() { # ok <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; fi
}
step() { out=$(cd "$w" && node "$script" "$art" "$1" 2>&1); rc=$?; }
report() { cat "$art/scaffold-render/step-$1-$2.md" 2>/dev/null; }

[ -d "$top/scripts/scaffold/node_modules/mustache" ] || npm ci --prefix "$top/scripts/scaffold" --silent --no-audit --no-fund >&2
git init -q -b main "$w"
git -C "$w" config user.name t; git -C "$w" config user.email t@t
ln -s "$top/scripts" "$w/scripts"
# The fixture: one leaf whose `## Scaffold` table links five templates, each as small as the cases need.
mkdir -p "$w/docs/code-maps" "$w/docs/scaffold-templates/domain" "$w/docs/scaffold-templates/adapter"
cat > "$w/docs/code-maps/fixture.md" <<'MD'
# fixture

## Scaffold

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [domain/create-request](../scaffold-templates/domain/create-request.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/Create<Name>Request.java` | `package`, `basePackage`, `Name`, `fields[type, name]` | validation |
| [domain/id](../scaffold-templates/domain/id.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<Name>Id.java` | `package`, `Name` | nothing |
| [domain/record](../scaffold-templates/domain/record.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<Name>.java` | `package`, `Name`, `fields[type, name, last]` | imports |
| [domain/mother](../scaffold-templates/domain/mother.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<Name>Mother.java` | `package`, `Name`, `fixture`, `upsert`, `fields[type, name, example]` | edge cases |
| [adapter/flyway-migration](../scaffold-templates/adapter/flyway-migration.mustache) | `application/src/main/resources/db/migration/V1.<NNN>__<snake_case_description>.sql` | `purpose`, `statements` | the rollback note |
MD
T="$w/docs/scaffold-templates"
printf 'package {{package}}.domain;\n\nimport {{basePackage}}.shared.Request;\n\npublic record Create{{Name}}Request({{#fields}}{{type}} {{name}}{{/fields}}) implements Request {}\n' > "$T/domain/create-request.mustache"
printf 'package {{package}}.domain;\n\npublic record {{Name}}Id(java.util.UUID value) {}\n' > "$T/domain/id.mustache"
printf 'package {{package}}.domain;\n\npublic record {{Name}}({{#fields}}{{type}} {{name}}{{^last}}, {{/last}}{{/fields}}) {}\n' > "$T/domain/record.mustache"
printf 'package {{package}}.domain;\n\n// {{fixture}}, upsert {{upsert}}\npublic class {{Name}}Mother {\n{{#fields}}  {{type}} {{name}} = {{example}};\n{{/fields}}}\n' > "$T/domain/mother.mustache"
printf -- '-- {{purpose}}\n{{statements}}\n' > "$T/adapter/flyway-migration.mustache"
mkdir -p "$w/$D" "$art"
printf 'package a.b.x.domain;\nrecord Existing() {}\n' > "$w/$D/Existing.java"
git -C "$w" add -A; git -C "$w" commit -qm init

# 1. Bad usage exits 2; no plan and no open step render nothing and exit 0.
out=$(node "$script" 2>&1); rc=$?
ok "1 no arguments: exit 2" $([ "$rc" -eq 2 ]; echo $?)
out=$(node "$script" "$art" both 2>&1); rc=$?
ok "1 an unknown side: exit 2" $([ "$rc" -eq 2 ]; echo $?)
step build
ok "1 no plan: exit 0, says so" $([ "$rc" -eq 0 ] && grep -q 'no plan.md' <<< "$out"; echo $?)

cat > "$art/plan.md" <<EOF
# Plan
- [x] **Step 1 — done.**
  - Scaffold: domain/id x-domain/src/main/java/a/b/x/domain/DoneId.java {}
- [ ] **Step 2 — Guest.**
  Test skills: object-mother-builders
  Build skills: domain-modeling
  - Scaffold: domain/id $D/GuestId.java {}
  - Scaffold: domain/mother $F/GuestMother.java {"fixture":"emma","upsert":false,"fields":[{"type":"String","name":"name","example":"\"Emma\""}]}
  - Scaffold: adapter/flyway-migration $M/V1.900__guests.sql {"purpose":"guests","statements":"INSERT INTO guest_kinds (kind) VALUES ('ALL');"}
  - Scaffold: domain/create-request $D/CreateGuestRequest.java {"fields":[{"type":"String","name":"name"}]}
  - Scaffold: domain/nope $D/Nope.java {}
  - Scaffold: domain/id $D/Guest.java {}
  - Scaffold: domain/record $D/Seat.java {"Name": }
  - Scaffold: domain/record
  - Scaffold: domain/record $D/Existing.java {"fields":[]}
- [ ] **Step 3 — later.**
  - Scaffold: domain/id $D/LaterId.java {}
EOF

# 2. The build side renders the step's lines outside the test trees, fills package and Name from the path, and reports
#    each line; the test-tree line, another step's lines and an existing file are left alone.
step build
ok "2 exit 0" $([ "$rc" -eq 0 ]; echo $?)
ok "2 summary counts" $(grep -qF 'scaffold-step: step 2, build side: 3 rendered, 1 existing, 4 failed, 0 handled earlier' <<< "$out"; echo $?)
ok "2 GuestId rendered with package and Name from the path" \
  $(grep -q '^package a\.b\.x\.domain;' "$w/$D/GuestId.java" && grep -q 'GuestId' "$w/$D/GuestId.java"; echo $?)
ok "2 apostrophes in a value are rendered as written" $(grep -qF "VALUES ('ALL');" "$w/$M/V1.900__guests.sql"; echo $?)
ok "2 the test-tree line waits for the test side" $([ ! -e "$w/$F/GuestMother.java" ]; echo $?)
ok "2 another step's lines are not rendered" $([ ! -e "$w/$D/LaterId.java" ] && [ ! -e "$w/$D/DoneId.java" ]; echo $?)
ok "2 an existing file is left alone" $(grep -q 'record Existing() {}' "$w/$D/Existing.java"; echo $?)
ok "2 a refused line writes nothing" $([ ! -e "$w/$D/Nope.java" ] && [ ! -e "$w/$D/Guest.java" ] && [ ! -e "$w/$D/Seat.java" ]; echo $?)
out=$(report 2 build)
ok "2 report: rendered, with the vars filled from the path" $(grep -qF "rendered: \`$D/GuestId.java\` (domain/id); filled from the path: package, Name" <<< "$out"; echo $?)
ok "2 report: a var the template reads and the vars left empty" $(grep -qF "the template reads basePackage, which the vars left empty" <<< "$out"; echo $?)
ok "2 report: no such template" $(grep -qF 'no template `domain/nope` under docs/scaffold-templates/' <<< "$out"; echo $?)
ok "2 report: a template that does not target the path names those that do" \
  $(grep -F "\`$D/Guest.java\` (domain/id)" <<< "$out" | grep -qF '`domain/id` does not target this path; the templates that do:'; echo $?)
ok "2 report: bad JSON" $(grep -F 'Seat.java' <<< "$out" | grep -qF 'the vars are not JSON'; echo $?)
ok "2 report: a line not in the form" $(grep -qF 'plan.md:14 `- Scaffold: domain/record`: not in the form' <<< "$out"; echo $?)
ok "2 report: the existing file is the step's to edit" $(grep -qF "existing, not rendered: \`$D/Existing.java\`" <<< "$out"; echo $?)
ok "2 report: what to do with a failed line" $(grep -qF 'A failed line is yours: run `scripts/scaffold.sh --for <path>`' <<< "$out"; echo $?)
out=$(cat "$w/.apm-audit/scaffold.jsonl" 2>/dev/null)
ok "2 one SCAFFOLD record per rendered file, the gate's evidence" \
  $([ "$(grep -c '"type":"SCAFFOLD"' <<< "$out")" -eq 3 ] && grep -qF "\"target\":\"$D/GuestId.java\"" <<< "$out"; echo $?)

# 3. The test side renders the test-tree line, with its own report and the --test form of --for.
step test
ok "3 test side: the Mother is rendered" $([ "$rc" -eq 0 ] && grep -q 'class GuestMother' "$w/$F/GuestMother.java"; echo $?)
ok "3 test side: summary counts" $(grep -qF 'step 2, test side: 1 rendered, 0 existing, 0 failed' <<< "$out"; echo $?)
out=$(report 2 test)
ok "3 test report names the --test form" $(grep -qF 'scripts/scaffold.sh --test --for <path>' <<< "$out"; echo $?)

# 4. The step going round again renders nothing twice: a rendered file the agent deleted stays deleted.
rm "$w/$D/GuestId.java"
step build
ok "4 a handled line is not rendered again" $([ ! -e "$w/$D/GuestId.java" ] && grep -qF '0 rendered, 0 existing, 1 failed, 7 handled earlier' <<< "$out"; echo $?)
ok "4 the report says so, with the first result" \
  $(report 2 build | grep -qF "handled earlier in this run, not rendered again: \`$D/GuestId.java\` (domain/id) (then: rendered)"; echo $?)
ok "4 a line refused earlier keeps its reason" \
  $(report 2 build | grep -F 'Nope.java' | grep -qF '(then: failed: no template `domain/nope` under docs/scaffold-templates/)'; echo $?)

# 5. A line the owner corrects is a new line: it renders.
sed -i "s#domain/id $D/GuestId.java {}#domain/id $D/GuestId.java {\"Name\":\"Guest\"}#" "$art/plan.md"
step build
ok "5 a corrected line renders" $([ -e "$w/$D/GuestId.java" ] && grep -qF '1 rendered' <<< "$out"; echo $?)

# 6. A step without Scaffold lines for the side gets a report that says so; no open step renders nothing.
sed -i 's/^- \[ \] \*\*Step 2/- [x] **Step 2/' "$art/plan.md"
step test
ok "6 no line for the side: the report says so" \
  $([ "$rc" -eq 0 ] && report 3 test | grep -qF 'No `Scaffold:` line of step 3 names a test-tree file.'; echo $?)
sed -i 's/^- \[ \]/- [x]/' "$art/plan.md"
step build
ok "6 no open step: exit 0, says so" $([ "$rc" -eq 0 ] && grep -q 'no open step' <<< "$out"; echo $?)

# 7. A (verify only) step renders nothing; a (pin only) step renders its tests, never code.
cat > "$art/plan.md" <<EOF
- [ ] (verify only) **Step 1 — docs.**
  - Scaffold: domain/id $D/VerifyId.java {}
EOF
step build
ok "7 verify only: nothing rendered, the report says why" $([ ! -e "$w/$D/VerifyId.java" ] && grep -qF '1 skipped' <<< "$out" \
  && report 1 build | grep -qF 'a `(verify only)` step renders nothing'; echo $?)
cat > "$art/plan.md" <<EOF
- [ ] (pin only) **Step 1 — pins.**
  - Scaffold: domain/id $D/PinId.java {}
  - Scaffold: domain/mother $F/PinMother.java {"fixture":"pin","upsert":false,"fields":[{"type":"String","name":"name","example":"\"Pin\""}]}
EOF
step build
ok "7 pin only: no code on the build side" $([ ! -e "$w/$D/PinId.java" ] && grep -qF '1 skipped' <<< "$out"; echo $?)
step test
ok "7 pin only: its tests render on the test side" $([ -e "$w/$F/PinMother.java" ] && grep -qF '1 rendered' <<< "$out"; echo $?)

# 8. A fenced block in the step neither ends it at a `# comment` nor renders the Scaffold line it quotes.
rm -rf "$art/scaffold-render"
cat > "$art/plan.md" <<EOF
- [ ] **Step 1 — fenced.**
  \`\`\`bash
# a comment in a snippet
  - Scaffold: domain/id $D/QuotedId.java {}
  \`\`\`
  - Scaffold: domain/id $D/AfterFenceId.java {}
EOF
step build
ok "8 a line after a fenced # comment still renders" $([ -e "$w/$D/AfterFenceId.java" ]; echo $?)
ok "8 a Scaffold line inside a fence is not rendered" \
  $([ ! -e "$w/$D/QuotedId.java" ] && grep -qF '1 rendered, 0 existing, 0 failed' <<< "$out"; echo $?)

# 9. A path outside the repo is refused, never reported as an existing file to edit, even when that file exists.
rm -rf "$art/scaffold-render"
mkdir -p "$root/outside"; echo keep > "$root/outside/OutsideId.java"
cat > "$art/plan.md" <<EOF
- [ ] **Step 1 — outside.**
  - Scaffold: domain/id ../outside/OutsideId.java {}
EOF
step build
ok "9 a path outside the repo is refused, not existing" $(grep -qF '0 existing, 1 failed' <<< "$out" \
  && report 1 build | grep -qF 'relative to the repo root' && grep -qx keep "$root/outside/OutsideId.java"; echo $?)

# 10. A line that throws while it renders is reported as failed; the step's other lines still render and the report
#     is still written.
rm -rf "$art/scaffold-render"; mkdir -p "$art/scaffold-render/step-1-1.json"
cat > "$art/plan.md" <<EOF
- [ ] **Step 1 — one throws.**
  - Scaffold: domain/id $D/ThrowsId.java {}
  - Scaffold: domain/id $D/StillId.java {}
EOF
step build
ok "10 a throwing line fails alone" $([ "$rc" -eq 0 ] && grep -qF '1 rendered, 0 existing, 1 failed' <<< "$out" \
  && [ -e "$w/$D/StillId.java" ] && report 1 build | grep -qF 'could not render it'; echo $?)

echo "scaffold-step: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
