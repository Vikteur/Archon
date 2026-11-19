// scripts/scaffold.sh --for <path>: which scaffold template renders a new file at <path>, and the command that does.
//   node for.js <repo root> <repo-relative path> [<path as the caller gave it>]
// For each template whose `## Scaffold` Target matches, the most specific Target first (the most literal text): its
// skill and Target, the `Vars:` lines of its header comment
// word for word, the leaf's Left to you cell, and a scripts/scaffold.sh command whose JSON holds what the path says for
// sure (`package`: the target's directory under src/<set>/java/ less the suffix the template appends; each `<Name>` or
// `<capability>` placeholder the template also reads), with the template's other top-level variables named for the
// caller to add; the command writes to the path as the caller gave it, the plan line names it from the repo root.
// When none matches: the plan line for a hand-written file. Exits 0 either way (2 on bad usage): it advises, the
// scaffold-check gate judges.
const fs = require('fs');
const path = require('path');
const { templateTargets, targetRegex } = require('./targets.js');

// the names the template reads at its top level (plain tags and sections), in order of first use
function topNames(tokens) {
  const names = [];
  for (const [type, name] of tokens) {
    if (!['name', '&', '#', '^'].includes(type) || name === '.') continue;
    const key = String(name).split('.')[0];
    if (!names.includes(key)) names.push(key);
  }
  return names;
}

// the header comment's `Vars:` line and the lines that continue it
function varsLines(text) {
  const head = (/^\{\{!([\s\S]*?)\}\}/.exec(text) || [])[1] || '';
  const lines = head.split(/\r?\n/);
  const at = lines.findIndex(l => /^\s*Vars:/.test(l));
  if (at < 0) return [];
  const out = [lines[at].trim()];
  for (const l of lines.slice(at + 1)) {
    if (!/^\s{4,}\S/.test(l)) break;
    out.push('      ' + l.trim());
  }
  return out;
}

// "package" for the target: its directory under src/<set>/java/, less the suffix the template appends itself
function packageFor(file, text) {
  const m = /(?:^|\/)src\/[^/]+\/java\/(.+)\/[^/]+\.java$/.exec(file);
  if (!m) return null;
  const dir = m[1].replace(/\//g, '.');
  const suffix = (/^\s*package\s+\{\{package\}\}([A-Za-z0-9_.]*)\s*;/m.exec(text) || [])[1] || '';
  return suffix && dir.endsWith(suffix) ? dir.slice(0, -suffix.length) : dir;
}

// the Target's literal text, without its placeholders: the longer, the more specific
const literal = target => target.replace(/<[^>]+>|\*\*|\.\.\./g, '').length;

function advice(root, t, file, shown) {
  const text = fs.readFileSync(path.join(root, t.file), 'utf8');
  const mustache = require(path.join(root, 'scripts', 'scaffold', 'node_modules', 'mustache'));
  const names = topNames(mustache.parse(text));
  const known = {};
  const pkg = packageFor(file, text);
  if (pkg !== null && names.includes('package')) known.package = pkg;
  const groups = (targetRegex(t.target, { capture: true }).exec(file) || {}).groups || {};
  for (const [k, v] of Object.entries(groups)) if (names.includes(k) && v !== undefined) known[k] = v;
  const rest = names.filter(n => !(n in known));
  const json = JSON.stringify(known).replace(/\}$/, rest.length ? `${Object.keys(known).length ? ', ' : ''}<${rest.join(', ')}>}` : '}');
  const test = /(^|\/)src\/(test|testFixtures|integrationTest)\//.test(file) ? '--test ' : '';
  return [...varsLines(text).map(l => '  ' + l), ...(t.left ? [`  Left to you: ${t.left}`] : []),
    `  Render: scripts/scaffold.sh ${test}${t.template} '${json}' ${shown}`];
}

function main(argv) {
  const [rootArg, raw, given] = argv;
  if (!rootArg || !raw) { console.error('usage: node for.js <repo root> <repo-relative path> [<path as given>]'); return 2; }
  const root = path.resolve(rootArg);
  const norm = p => p.replace(/\\/g, '/').replace(/^\.\//, '');
  const file = norm(raw);
  const shown = given ? norm(given) : file;
  const fits = templateTargets(root).filter(t => t.re.test(file))
    .map((t, i) => ({ t, i })).sort((a, b) => literal(b.t.target) - literal(a.t.target) || a.i - b.i).map(x => x.t);
  const out = [];
  if (!fits.length) {
    out.push(`[scaffold] no template targets ${file}.`,
      'Write it by hand, and add this line under the step that adds it in the plan:',
      `  Hand-written: ${file} — no-template: <shape>`,
      '<shape> says what the file is, in kebab-case (enum, exception, schema-test, ...): use the word an earlier plan',
      'used for the same kind of file, so the scaffold-check gate can count it.');
  } else {
    out.push(`[scaffold] ${fits.length} template(s) target ${file}${fits.length > 1 ? ', the most specific first' : ''}:`);
    for (const t of fits) {
      out.push('', `${t.template} (skill ${t.skill}): target \`${t.target}\``);
      try { out.push(...advice(root, t, file, shown)); } catch (e) { out.push(`  Render: scripts/scaffold.sh ${t.template} '<json on one line>' ${shown} (${e.message})`); }
    }
    out.push('', 'Put the variables in <...> into the JSON (the Vars lines say what each is), render it, then edit the',
      'file for what the template leaves out. Only when no template above fits what the file needs, write it by hand',
      'and add this line under the step in the plan:',
      `  Hand-written: ${file} — template-misfit: ${fits.length > 1 ? '<the template that came closest>' : fits[0].template} — <why it does not fit>`);
  }
  console.log(out.join('\n'));
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { topNames, varsLines, packageFor };
