#!/usr/bin/env bash
# Tests that this repo's own scaffold templates (docs/scaffold-templates/project/) are wired into the kit's scaffold
# scripts, without rendering-and-compiling them all (that is scripts/scaffold/smoke.sh):
#   1. every template has a <name>.example.json with a "_target", is linked from a `## Scaffold` row (a docs/code-maps
#      leaf or docs/scaffold-templates/project/README.md, read by scripts/scaffold/targets.js, the matcher that
#      scripts/scaffold.sh --for, .archon/scripts/scaffold-step.js and the scaffold-check gate share), its row matches
#      that _target and no other row is more specific there, and no row links a missing file;
#   2. scripts/scaffold.sh --for <_target> names the template, for every example;
#   3. scaffold-step.js, the build workflow's plan renderer, renders `Scaffold: project/...` plan lines on both sides
#      and writes the SCAFFOLD records the scaffold-check gate counts;
#   4. with a "context" in docs/scaffold-templates/project/scaffold.json: scripts/scaffold/new-context.sh prints its
#      usage, and refuses a bad capability and an existing module without writing anything.
# "projectOnly": true in scaffold.json also fails a code-map row that links a kit template, and a --for answer that
# offers one: the repo renders only its own templates. A repo without templates of its own passes with nothing to check.
# Usage: bash scripts/test/scaffold-wiring.test.sh   (exit 0 = all pass)
set -uo pipefail

top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; out=""; rc=0
dir=docs/scaffold-templates/project
config="$dir/scaffold.json"

check() { # check <name> <condition exit code>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
  else fail=$((fail+1)); echo "FAIL - $1"; printf '%s\n' "$out" | sed 's/^/       | /'; fi
}
# cfg <js expression over c, the parsed scaffold.json ({} without one)>: its value, printed
cfg() { node -e 'const fs = require("fs"); const c = fs.existsSync(process.argv[1]) ? JSON.parse(fs.readFileSync(process.argv[1], "utf8")) : {};
  const v = ('"$1"'); if (v !== undefined) console.log(typeof v === "string" ? v : JSON.stringify(v));' "$config"; }

cd "$top" || exit 1
if [ -z "$(find "$dir" -name '*.mustache' 2> /dev/null | head -n 1)" ]; then
  echo "scaffold-wiring tests: no templates of the repo's own under $dir/, nothing to check"
  exit 0
fi
[ -d scripts/scaffold/node_modules/mustache ] || npm ci --prefix scripts/scaffold --silent --no-audit --no-fund >&2
out="$(cfg 'c' 2>&1)"
check "0 $config, when there is one, is valid JSON" "$?"
project_only="$(cfg 'c.projectOnly === true')"

# 1. Linking: one node pass over the templates, the examples and the rows.
out="$(node - "$top" "$project_only" << 'NODE'
const fs = require('fs'), path = require('path');
const [root, projectOnly] = process.argv.slice(2);
const { templateTargets } = require(path.join(root, 'scripts/scaffold/targets.js'));
const rows = templateTargets(root);
const base = path.join(root, 'docs/scaffold-templates');
const walk = d => fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
const templates = walk(path.join(base, 'project')).map(f => path.relative(base, f).split(path.sep).join('/'))
  .filter(f => f.endsWith('.mustache')).map(f => f.slice(0, -'.mustache'.length));
const literal = t => t.replace(/<[^>]+>|\*\*|\.\.\./g, '').length;
const problems = [];
for (const t of templates) {
  if (!rows.some(r => r.template === t)) problems.push(`unlinked: ${t}`);
  const ex = path.join(base, `${t}.example.json`);
  if (!fs.existsSync(ex)) { problems.push(`no example: ${t}`); continue; }
  let target;
  try { target = JSON.parse(fs.readFileSync(ex, 'utf8'))._target; } catch (e) { problems.push(`example not JSON: ${t}: ${e.message}`); continue; }
  if (!target) { problems.push(`no _target: ${t}`); continue; }
  const fits = rows.filter(r => r.re.test(target));
  const own = fits.find(r => r.template === t);
  if (!own) { if (rows.some(r => r.template === t)) problems.push(`row of ${t} does not match its _target ${target}`); continue; }
  const best = Math.max(...fits.map(r => literal(r.target)));
  if (literal(own.target) < best) problems.push(`${t} outranked at ${target} by ${fits.filter(r => literal(r.target) === best).map(r => r.template).join(', ')}`);
}
for (const r of rows) {
  if (projectOnly === 'true' && !r.template.startsWith('project/')) problems.push(`kit template linked: ${r.template} (${r.skill})`);
  if (!fs.existsSync(path.join(root, r.file))) problems.push(`dangling row: ${r.file} (${r.skill})`);
}
console.log(`templates=${templates.length} rows=${rows.length}`);
problems.forEach(p => console.log(p));
process.exit(problems.length ? 1 : 0);
NODE
)"; rc=$?
check "1 every template has an example with a _target, is linked, matches it and is not outranked there" \
  "$(! grep -qE '^(unlinked|no example|example not JSON|no _target|row of|.* outranked at)' <<< "$out"; echo $?)"
label="1 no row links a missing file"; [ "$project_only" = true ] && label+=" or a kit template"
check "$label" "$(! grep -qE '^(kit template linked|dangling row)' <<< "$out"; echo $?)"

# The examples: "<template>\t<_target>" for each <name>.example.json (variants included).
examples="$(node - "$top" << 'NODE'
const fs = require('fs'), path = require('path');
const base = path.join(process.argv[2], 'docs/scaffold-templates');
const walk = d => fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
for (const f of walk(path.join(base, 'project')).sort()) {
  if (!f.endsWith('.example.json')) continue;
  let t = path.relative(base, f).split(path.sep).join('/').slice(0, -'.example.json'.length);
  if (!fs.existsSync(path.join(base, `${t}.mustache`))) t = t.replace(/\.[^./]+$/, '');
  let target = '';
  try { target = JSON.parse(fs.readFileSync(f, 'utf8'))._target || ''; } catch {}
  if (target && fs.existsSync(path.join(base, `${t}.mustache`))) console.log(`${t}\t${target}`);
}
NODE
)"

# 2. --for on every example's target.
missed="" offered=""
while IFS=$'\t' read -r t target; do
  [ -n "$t" ] || continue
  o="$(bash scripts/scaffold.sh --for "$target" 2>&1)"
  grep -qF "$t (skill " <<< "$o" || missed+="$t at $target"$'\n'
  if [ "$project_only" = true ] && grep -E '^[^ ]+ \(skill ' <<< "$o" | grep -qvE '^project/'; then
    offered+="$target: $(grep -E '^[^ ]+ \(skill ' <<< "$o" | grep -vE '^project/' | head -n 1)"$'\n'
  fi
done <<< "$examples"
out="$missed"
check "2 --for names each template at its example's target" "$([ -z "$missed" ]; echo $?)"
if [ "$project_only" = true ]; then
  out="$offered"
  check "2 --for never offers a kit template" "$([ -z "$offered" ]; echo $?)"
fi

# 3. scaffold-step.js on one test-tree and one other plan line, in a throwaway repo that links docs/ and scripts/.
test_line="" build_line=""
while IFS=$'\t' read -r t target; do
  [ -n "$t" ] || continue
  [[ "$t" == *.* ]] && continue   # a variant: the template's own example is enough
  vars="$(node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); delete v._target; process.stdout.write(JSON.stringify(v))' \
    "docs/scaffold-templates/$t.example.json")"
  if [[ "$target" =~ (^|/)src/(test|testFixtures|integrationTest)/ ]]; then
    [ -n "$test_line" ] || test_line="  - Scaffold: $t $target $vars"
  else
    [ -n "$build_line" ] || build_line="  - Scaffold: $t $target $vars"
  fi
done <<< "$examples"
w="$tmp/w"; art="$tmp/art"; mkdir -p "$art"
git init -q -b main "$w"; git -C "$w" config user.name t; git -C "$w" config user.email t@t
ln -s "$top/docs" "$w/docs"; ln -s "$top/scripts" "$w/scripts"
echo x > "$w/README.md"; git -C "$w" add -A; git -C "$w" commit -qm init
printf '# Plan\n- [ ] **Step 1 — the templates.**\n%s\n%s\n' "$test_line" "$build_line" | grep -v '^$' > "$art/plan.md"
want=0
[ -n "$test_line" ] && want=$((want + 1))
[ -n "$build_line" ] && want=$((want + 1))
export SCAFFOLD_LOG="$tmp/scaffold.jsonl"
out="$(cd "$w" && node "$top/.archon/scripts/scaffold-step.js" "$art" test 2>&1; node "$top/.archon/scripts/scaffold-step.js" "$art" build 2>&1)"
check "3 scaffold-step renders a test-tree and another plan line, none failed" \
  "$( { [ -z "$test_line" ] || grep -qF 'test side: 1 rendered, 0 existing, 0 failed' <<< "$out"; } \
    && { [ -z "$build_line" ] || grep -qF 'build side: 1 rendered, 0 existing, 0 failed' <<< "$out"; }; echo $?)"
out="$(cat "$SCAFFOLD_LOG" 2> /dev/null)"
check "3 each render leaves the SCAFFOLD record the gate counts" "$([ "$(grep -c '"template":"project/' <<< "$out")" -eq "$want" ]; echo $?)"

# 4. new-context.sh, when the repo describes a context.
if [ -n "$(cfg 'c.context && "yes"')" ]; then
  out="$(bash scripts/scaffold/new-context.sh 2>&1)"; rc=$?
  check "4 new-context without arguments prints usage, exit 2" "$([ "$rc" -eq 2 ] && grep -qF 'Usage:' <<< "$out"; echo $?)"
  mapfile -t extra < <(cfg '(c.context.args || []).map(() => "x").join("\n")')
  out="$(bash scripts/scaffold/new-context.sh Bad Bad a.b "${extra[@]}" 2>&1)"; rc=$?
  check "4 new-context refuses a non-kebab capability" "$([ "$rc" -eq 1 ] && grep -qF 'capability must be kebab-case' <<< "$out"; echo $?)"
  first="$(cfg 'c.context.modules[0]')"
  existing="$(find . -maxdepth 1 -type d -name "*-$first" | sed 's#^\./##' | sort | head -n 1)"
  if [ -n "$existing" ]; then
    cap="${existing%-"$first"}"
    before="$(git status --porcelain 2>&1)"
    out="$(bash scripts/scaffold/new-context.sh "$cap" Existing a.b "${extra[@]}" 2>&1)"; rc=$?
    check "4 new-context refuses an existing module ($existing) and writes nothing" \
      "$([ "$rc" -eq 1 ] && grep -qF "module exists, refusing: $existing" <<< "$out" && [ "$(git status --porcelain 2>&1)" = "$before" ]; echo $?)"
  fi
fi

echo "scaffold-wiring tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
