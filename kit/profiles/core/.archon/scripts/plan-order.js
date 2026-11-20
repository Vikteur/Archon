// Step-order gate on the plan (P2: a script, not a model; owner decision 2026-10-23, docs/memory.md): a step that adds
// a port also delivers its adapter. A use case is a bean, so a port injected with no implementation fails every test
// that boots the app's DI container (UnsatisfiedDependencyException, no qualifying bean) until the adapter's step
// (TASK-7.4, TASK-48.8), and the run blocks mid-loop.
//   node plan-order.js <plan.md>
// A port is a name ending in Repository or Gateway, or the file of a `-usecase/src/main/java/**/repository/<Name>.java`
// path, that a step names and no tracked file holds yet (git ls-files, from the checkout). Its adapter is
// `Default<Name>`. It fails when the first step that names the port comes before the first step that names the
// adapter, and the adapter is not tracked yet either. A step marked `(folded into step <k>)` counts as step k. Only the
// checkbox steps are read; a port whose adapter the plan never names is not this check's.
// Pins (owner decision 2026-10-23): a plan has at most one `(pin only)` step (one folded into another counts as that
// one), and it names each behaviour it pins on a `Pin:` line, since tdd-check wants one mutation per line. Every pin
// step was its own loop iteration of ~5.5 min, most of it one affected-check run.
// Exit 0 ok, 1 a plan to fix (or no plan), with one line per problem.
const fs = require('fs');
const { execFileSync } = require('child_process');

const PORT_NAME = /\b(?!Default)([A-Z]\w*(?:Repository|Gateway))\b/g;
const PORT_PATH = /[\w.-]+-usecase\/src\/main\/java\/\S*?\/repository\/([A-Z]\w*)\.java/g;
const ADAPTER = /\bDefault([A-Z]\w*)\b/g;

// [{ n, at, text }]: at is the step it counts as (its fold target, or itself)
function steps(text) {
  const out = [];
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*- \[[ xX]\]/.test(line)) {
      const n = out.length + 1;
      const k = Number((/\(folded into step (\d+)\)/i.exec(line) || [])[1] || 0);
      out.push({ n, at: k > 0 && k < n ? k : n, text: '' });
    }
    if (out.length) out[out.length - 1].text += line + '\n';
  }
  return out;
}

function tracked() {
  try {
    return new Set(execFileSync('git', ['ls-files', '*.java'], { encoding: 'utf8' }).split('\n')
      .map(f => f.replace(/^.*\//, '').replace(/\.java$/, '')).filter(Boolean));
  } catch { return new Set(); }
}

function pinProblems(all) {
  const pins = all.filter(s => s.at === s.n && /^\s*- \[[ xX]\].*\(pin only\)/.test(s.text));
  const out = pins.filter(s => !/^\s*- Pin:/m.test(s.text)).map(s => `step ${s.n} is (pin only) but names no \`Pin:\` line ` +
    'for the behaviour it pins: add one `  - Pin: <class>: <behaviour>` line under it for each');
  if (pins.length > 1) out.push(`steps ${pins.map(s => s.n).join(' and ')} are both (pin only): put every pin in one ` +
    '(pin only) step, a `Pin:` line each');
  return out;
}

function check(text, have = tracked()) {
  const port = new Map();
  const adapter = new Map();
  const first = (map, name, s) => { if (!map.has(name) || map.get(name).at > s.at) map.set(name, s); };
  for (const s of steps(text)) {
    for (const m of s.text.matchAll(PORT_NAME)) first(port, m[1], s);
    for (const m of s.text.matchAll(PORT_PATH)) first(port, m[1], s);
    for (const m of s.text.matchAll(ADAPTER)) first(adapter, m[1], s);
  }
  const problems = pinProblems(steps(text));
  for (const [name, p] of port) {
    const a = adapter.get(name);
    if (!a || have.has(name) || have.has(`Default${name}`) || a.at <= p.at) continue;
    problems.push(`step ${p.n} adds the port ${name}, but its adapter Default${name} comes only in step ${a.n}: ` +
      `deliver the adapter (or a stub) in step ${p.n}, or move the port to step ${a.n}`);
  }
  return problems;
}

if (require.main === module) {
  const file = process.argv[2];
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { console.error(`plan-order: no plan at ${file}`); process.exit(1); }
  const problems = check(text);
  for (const p of problems) console.error(`plan-order: ${p}`);
  if (problems.length) process.exit(1);
  console.log('plan-order: every port comes with its adapter, and the pins are in one step');
}

module.exports = { check };
