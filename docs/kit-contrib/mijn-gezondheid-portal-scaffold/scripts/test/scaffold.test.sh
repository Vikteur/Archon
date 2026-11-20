#!/usr/bin/env bash
# Tests that the project scaffold templates (docs/scaffold-templates/project/) are wired into the existing scaffold
# scripts, without rendering-and-compiling them all (that is scripts/scaffold/smoke.sh):
#   1. every template is linked from a docs/code-maps `## Scaffold` row (scripts/scaffold/targets.js, the matcher that
#      scripts/scaffold.sh --for, .archon/scripts/scaffold-step.js and the scaffold-check gate share), no row links a
#      kit template, and the row of each template matches its own example's `_target` and is not outranked there;
#   2. scripts/scaffold.sh --for names the project template, with package and Name prefilled from the path;
#   3. scaffold-step.js, the build workflow's plan renderer, renders `Scaffold: project/...` plan lines on both sides,
#      fills package and Name from the path, and writes the SCAFFOLD records the gate counts;
#   4. new-context.sh refuses an existing module and bad arguments without writing anything.
# Usage: bash scripts/test/scaffold.test.sh   (exit 0 = all pass)
set -uo pipefail

top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}

cd "$top" || exit 1
[ -d scripts/scaffold/node_modules/mustache ] || npm ci --prefix scripts/scaffold --silent --no-audit --no-fund >&2

# 1. Linking: one node pass over the templates, the examples and the code-map rows.
out="$(node - "$top" <<'NODE'
const fs = require('fs'), path = require('path');
const root = process.argv[2];
const { templateTargets } = require(path.join(root, 'scripts/scaffold/targets.js'));
const rows = templateTargets(root);
const dir = path.join(root, 'docs/scaffold-templates/project');
const walk = d => fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
const files = walk(dir).map(f => path.relative(path.join(root, 'docs/scaffold-templates'), f));
const templates = files.filter(f => f.endsWith('.mustache')).map(f => f.slice(0, -'.mustache'.length));
const literal = t => t.replace(/<[^>]+>|\*\*|\.\.\./g, '').length;
const problems = [];
for (const t of templates) {
  if (!rows.some(r => r.template === t)) problems.push(`unlinked: ${t}`);
  const ex = path.join(dir, '..', `${t}.example.json`);
  if (!fs.existsSync(ex)) { problems.push(`no example: ${t}`); continue; }
  const target = JSON.parse(fs.readFileSync(ex, 'utf8'))._target;
  if (!target) { problems.push(`no _target: ${t}`); continue; }
  const fits = rows.filter(r => r.re.test(target));
  const own = fits.find(r => r.template === t);
  if (!own) { problems.push(`row of ${t} does not match its _target ${target}`); continue; }
  const best = Math.max(...fits.map(r => literal(r.target)));
  if (literal(own.target) < best) problems.push(`${t} outranked at ${target}`);
}
for (const r of rows) {
  if (!r.template.startsWith('project/')) problems.push(`kit template linked: ${r.template} (${r.skill})`);
  if (!fs.existsSync(path.join(root, r.file))) problems.push(`dangling row: ${r.file} (${r.skill})`);
}
console.log(`templates=${templates.length} rows=${rows.length}`);
problems.forEach(p => console.log(p));
process.exit(problems.length ? 1 : 0);
NODE
)"; rc=$?
check "1 every project template is linked, matches its own example target and is not outranked" "$rc"
check "1 no code-map row links a kit template or a missing file" "$(! grep -qE '^(kit template linked|dangling row)' <<< "$out"; echo $?)"

# 2. --for.
p=report-domain/src/test/java/be/mijngezondheid/report/domain/collection/FooMother.java
out="$(bash scripts/scaffold.sh --for "$p" 2>&1)"; rc=$?
check "2 --for names the project Mother template first" "$([ "$rc" -eq 0 ] && grep -m1 -E '^project/' <<< "$out" | grep -qF 'project/domain/mother '; echo $?)"
check "2 --for prefills package and Name from the path" \
  "$(grep -qF '"package":"be.mijngezondheid.report.domain.collection","Name":"Foo"' <<< "$out"; echo $?)"
check "2 --for never offers a kit template" "$(! grep -qE '^(domain|usecase|adapter)/' <<< "$out"; echo $?)"
p=vaccination-adapter/src/main/resources/db/migration/ddl/V1.999__create_foo.sql
out="$(bash scripts/scaffold.sh --for "$p" 2>&1)"
check "2 --for resolves a migration path" "$(grep -qF 'project/adapter/flyway-migration ' <<< "$out"; echo $?)"

# 3. scaffold-step.js on project plan lines, in a throwaway repo that links docs/ and scripts/.
w="$tmp/w"; art="$tmp/art"; mkdir -p "$art"
git init -q -b main "$w"; git -C "$w" config user.name t; git -C "$w" config user.email t@t
ln -s "$top/docs" "$w/docs"; ln -s "$top/scripts" "$w/scripts"
echo x > "$w/README.md"; git -C "$w" add -A; git -C "$w" commit -qm init
D=demo-domain/src/main/java/be/mijngezondheid/demo/domain/gizmo
T=demo-domain/src/test/java/be/mijngezondheid/demo/domain/gizmo
F='[{"type":"String","name":"label","Cap":"Label","example":"\"Lamp /a&b\"","notBlank":true}]'
cat > "$art/plan.md" <<EOF
# Plan
- [ ] **Step 1 — Gizmo.**
  Test skills: object-mother-builders
  Build skills: domain-modeling
  - Scaffold: project/domain/entity $D/Gizmo.java {"fields":$F}
  - Scaffold: project/domain/exception $D/GizmoNotFoundException.java {}
  - Scaffold: project/domain/factory-test $T/GizmoFactoryTest.java {"name":"gizmo","fields":$F}
EOF
export SCAFFOLD_LOG="$tmp/scaffold.jsonl"
out="$(cd "$w" && node "$top/.archon/scripts/scaffold-step.js" "$art" test 2>&1; node "$top/.archon/scripts/scaffold-step.js" "$art" build 2>&1)"
check "3 scaffold-step renders the test line and both build lines" \
  "$(grep -qF 'test side: 1 rendered, 0 existing, 0 failed' <<< "$out" && grep -qF 'build side: 2 rendered, 0 existing, 0 failed' <<< "$out"; echo $?)"
out="$(cat "$art"/scaffold-render/step-1-*.md 2>/dev/null)"
check "3 package and Name come from the path" "$(grep -qF "\`$D/Gizmo.java\` (project/domain/entity); filled from the path: package, Name" <<< "$out"; echo $?)"
out="$(cat "$w/$D/GizmoNotFoundException.java" "$w/$T/GizmoFactoryTest.java" 2>/dev/null)"
check "3 the rendered files declare the path's package and the Name" \
  "$(grep -qF 'package be.mijngezondheid.demo.domain.gizmo;' <<< "$out" && grep -qF 'class GizmoNotFoundException extends RuntimeException' <<< "$out" \
     && grep -qF 'class GizmoFactoryTest' <<< "$out"; echo $?)"
check "3 values are written unescaped" "$(grep -qF '.label("Lamp /a&b")' <<< "$out" && ! grep -qE '&(#x?[0-9A-Fa-f]+|quot|amp|lt|gt);' <<< "$out"; echo $?)"
out="$(cat "$SCAFFOLD_LOG" 2>/dev/null)"
check "3 each render leaves the SCAFFOLD record the gate counts" "$([ "$(grep -c '"template":"project/domain/' <<< "$out")" -eq 3 ]; echo $?)"

# 4. new-context.sh refuses without writing.
out="$(bash scripts/scaffold/new-context.sh report Report be.mijngezondheid.report X y 2>&1)"; rc=$?
check "4 new-context refuses an existing module" "$([ "$rc" -eq 1 ] && grep -qF 'module exists, refusing: report-domain' <<< "$out" \
  && git diff --quiet -- settings.gradle.kts application/build.gradle.kts; echo $?)"
out="$(bash scripts/scaffold/new-context.sh Bad Report be.mijngezondheid.x X y 2>&1)"; rc=$?
check "4 new-context refuses a non-kebab capability" "$([ "$rc" -eq 1 ] && grep -qF 'capability must be kebab-case' <<< "$out"; echo $?)"
out="$(bash scripts/scaffold/new-context.sh 2>&1)"; rc=$?
check "4 new-context without arguments prints usage, exit 2" "$([ "$rc" -eq 2 ] && grep -qF 'Usage:' <<< "$out"; echo $?)"

echo "scaffold tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
