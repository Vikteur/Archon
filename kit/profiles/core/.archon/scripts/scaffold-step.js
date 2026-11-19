// Renders the scaffold templates the plan names for build-feature's current step, before the agent of one side starts
// (P2: the plan decides which template and which vars, a script renders them; docs/memory.md, 2026-10-24).
//   node scaffold-step.js <artifacts-dir> test|build
// The plan names each new file a scaffold template renders on a line under the step that adds it:
//   Scaffold: <template> <repo-relative path> <the template's vars as one JSON object on one line>
// The step is the first open checkbox of <artifacts-dir>/plan.md (n: its position among the checkbox lines, as in
// step-base); its lines run from its checkbox to the next checkbox or heading. Side test renders the lines whose path is
// under a test tree (src/test/, src/testFixtures/, src/integrationTest/), before the test agent; side build the others,
// after the step's tests are committed, so the red run never sees code. scripts/scaffold.sh renders each line and writes
// the SCAFFOLD record the scaffold-check gate counts; the vars go to it in a file, never through a shell: the plan is
// model text, and a value may hold an apostrophe (SQL). A var the JSON leaves out is filled from the path when the path
// says it for sure, as scaffold.sh --for does: `package` (the directory under src/<set>/java/ less the template's suffix)
// and each placeholder of the template's Target that the template reads (`<Name>`, ...).
// A line is not rendered when its path exists (the step changes that file) or when the same line was handled earlier in
// the run (scaffold-render/handled.jsonl keeps each line's first result), so a step going round again never renders over
// the agent's work or a file it deleted. A `(verify only)` step renders nothing and a `(pin only)` step nothing on the
// build side: they build no code. A line that cannot render (not in the form, no such template, a template whose Target does not match the path,
// JSON that is not an object, scaffold.sh refusing) is reported, never fatal (a line not in the form goes to the side
// its text names a test tree for, else to the build side): the agent renders that file itself with
// `scripts/scaffold.sh --for <path>`. Writes scaffold-render/step-<n>-<side>.md for the agent (each line's result, with
// scaffold.sh's message, and each top-level variable the template reads that the vars left empty) and prints one summary
// line. Exits 0 (2 on bad usage).
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { fitting, targetRegex } = require('../../scripts/scaffold/targets.js');
const { packageFor } = require('../../scripts/scaffold/for.js');

const TEST_TREE = /(^|\/)src\/(test|testFixtures|integrationTest)\//;
const CHECKBOX = /^\s*- \[[ xX]\]/;
const OPEN = /^\s*- \[ \]/;
const SCAFFOLD = /^\s*(?:[-*]\s+)?Scaffold:/;
const FORM = /^\s*(?:[-*]\s+)?Scaffold:\s+`?([^\s`]+)`?\s+`?([^\s`]+)`?\s+`?(\{.*\})`?\s*$/;

// The first open step: { n, head, lines: [{ text, at }] } with its checkbox line and the lines under it, or null when
// every step is done
function currentStep(plan) {
  const lines = plan.split(/\r?\n/);
  let n = 0;
  for (let i = 0; i < lines.length; i++) {
    if (!CHECKBOX.test(lines[i])) continue;
    n++;
    if (!OPEN.test(lines[i])) continue;
    // A fenced block in the step (a snippet, a quoted form) neither ends it at a `# comment` nor holds Scaffold lines.
    // Checkboxes still end it, fenced or not, so n and the step agree with step-base's count.
    const body = [];
    let fenced = false;
    for (let j = i + 1; j < lines.length && !CHECKBOX.test(lines[j]) && (fenced || !/^#/.test(lines[j])); j++) {
      if (/^\s*(```|~~~)/.test(lines[j])) { fenced = !fenced; continue; }
      body.push({ text: lines[j], at: j + 1, fenced });
    }
    return { n, head: lines[i], lines: body };
  }
  return null;
}

// The step's Scaffold lines: { at, text, template, target, json } or, for a line not in the form, { at, text, error }
function scaffoldLines(step) {
  return step.lines.filter(l => !l.fenced && SCAFFOLD.test(l.text)).map(l => {
    const m = FORM.exec(l.text);
    if (!m) return { at: l.at, text: l.text.trim(), error: 'not in the form `Scaffold: <template> <repo-relative path> <vars as one JSON object>`' };
    return { at: l.at, text: l.text.trim(), template: m[1], target: m[2].replace(/\\/g, '/').replace(/^\.\//, ''), json: m[3] };
  });
}

const sideOf = target => (TEST_TREE.test(target) ? 'test' : 'build');

// The mustache module scaffold.sh renders with, installed the way scaffold.sh installs it; null when it cannot be had
function mustacheModule(root) {
  const dir = path.join(root, 'scripts', 'scaffold');
  const load = () => { try { return require(path.join(dir, 'node_modules', 'mustache')); } catch { return null; } };
  const m = load();
  if (m || !fs.existsSync(path.join(dir, 'package.json'))) return m;
  spawnSync('npm', ['ci', '--prefix', dir, '--silent', '--no-audit', '--no-fund'], { stdio: 'ignore' });
  return load();
}

// The vars the path gives for sure, limited to the names the template reads, and the plain top-level tags it reads
function fromPath(root, line, text, mustache) {
  const known = {};
  if (!mustache) return { known, plain: [] };
  const tokens = mustache.parse(text).filter(t => String(t[1]).split('.')[0] !== '');
  const read = new Set(tokens.filter(t => ['name', '&', '#', '^'].includes(t[0])).map(t => String(t[1]).split('.')[0]));
  const pkg = packageFor(line.target, text);
  if (pkg !== null && read.has('package')) known.package = pkg;
  for (const t of fitting(root, line.target).filter(f => f.template === line.template)) {
    const groups = (targetRegex(t.target, { capture: true }).exec(line.target) || {}).groups || {};
    for (const [k, v] of Object.entries(groups)) if (v !== undefined && read.has(k) && !(k in known)) known[k] = v;
  }
  const plain = [...new Set(tokens.filter(t => t[0] === 'name' || t[0] === '&').map(t => String(t[1]).split('.')[0]))];
  return { known, plain };
}

// Why the line cannot render, or null
function refusal(root, line) {
  if (line.error) return line.error;
  if (/(^|\/)\.\.(\/|$)/.test(line.template) || path.isAbsolute(line.template)) return `\`${line.template}\` is not a template name`;
  if (!fs.existsSync(path.join(root, 'docs', 'scaffold-templates', `${line.template}.mustache`))) return `no template \`${line.template}\` under docs/scaffold-templates/`;
  if (/^([A-Za-z]:)?\//.test(line.target) || /(^|\/)\.\.(\/|$)/.test(line.target)) return 'the path must be relative to the repo root, without `..`';
  const fits = fitting(root, line.target).map(t => t.template);
  if (!fits.includes(line.template)) {
    return fits.length ? `\`${line.template}\` does not target this path; the templates that do: ${fits.map(t => `\`${t}\``).join(', ')}`
      : `no template targets this path: write it by hand with its \`Hand-written: ${line.target} — no-template: <shape>\` line`;
  }
  let vars;
  try { vars = JSON.parse(line.json); } catch (e) { return `the vars are not JSON (${e.message})`; }
  if (!vars || typeof vars !== 'object' || Array.isArray(vars)) return 'the vars are not one JSON object';
  return null;
}

function render(root, art, n, line, mustache, k) {
  const text = fs.readFileSync(path.join(root, 'docs', 'scaffold-templates', `${line.template}.mustache`), 'utf8');
  const { known, plain } = fromPath(root, line, text, mustache);
  const vars = { ...known, ...JSON.parse(line.json) };
  const file = path.join(art, 'scaffold-render', `step-${n}-${k}.json`);
  fs.writeFileSync(file, JSON.stringify(vars));
  const r = spawnSync('bash', [path.join(root, 'scripts', 'scaffold.sh'), line.template, file, line.target], { cwd: root, encoding: 'utf8' });
  if (r.status !== 0) return { result: 'failed', why: (r.stderr || r.stdout || r.error?.message || `scaffold.sh exited ${r.status}`).trim().split('\n').pop() };
  const empty = plain.filter(v => vars[v] === undefined || vars[v] === null || vars[v] === '');
  return { result: 'rendered', filled: Object.keys(known).filter(v => !(v in JSON.parse(line.json))), empty };
}

function scaffoldStep(art, root, side) {
  let plan;
  try { plan = fs.readFileSync(path.join(art, 'plan.md'), 'utf8'); } catch { return { summary: 'scaffold-step: no plan.md, nothing to render' }; }
  const step = currentStep(plan);
  if (!step) return { summary: 'scaffold-step: no open step, nothing to render' };
  const dir = path.join(art, 'scaffold-render');
  fs.mkdirSync(dir, { recursive: true });
  const ledger = path.join(dir, 'handled.jsonl');
  const handled = new Map((fs.existsSync(ledger) ? fs.readFileSync(ledger, 'utf8').split('\n').filter(Boolean) : [])
    .map(l => { try { const h = JSON.parse(l); return [h.key, h]; } catch { return [null, null]; } }).filter(([k]) => k));
  const lines = scaffoldLines(step).filter(l => sideOf(l.error ? l.text : l.target) === side);
  // a (verify only) step writes no file from a template, and a (pin only) step only tests
  const idle = /\(verify only\)/.test(step.head) ? 'a `(verify only)` step renders nothing'
    : /\(pin only\)/.test(step.head) && side === 'build' ? 'a `(pin only)` step builds no code' : '';
  const mustache = !idle && lines.some(l => !l.error) ? mustacheModule(root) : null;
  const rows = lines.map((line, i) => {
    if (idle) return { line, result: 'skipped', why: idle };
    if (line.error) return { line, result: 'failed', why: line.error };
    const key = crypto.createHash('sha1').update(`${line.template}\t${line.target}\t${line.json}`).digest('hex');
    if (handled.has(key)) return { line, result: 'earlier', first: handled.get(key) };
    let row;
    try {
      // a path outside the repo is refused before it is looked up, so no file outside it is called existing
      const outside = /^([A-Za-z]:)?\//.test(line.target) || /(^|\/)\.\.(\/|$)/.test(line.target);
      if (!outside && fs.existsSync(path.join(root, line.target))) row = { line, result: 'existing' };
      else {
        const why = refusal(root, line);
        row = why ? { line, result: 'failed', why } : { line, ...render(root, art, step.n, line, mustache, i + 1) };
      }
    } catch (e) {
      // one line that throws is reported as failed; the step's other lines still run and the report is still written
      row = { line, result: 'failed', why: `scaffold-step could not render it (${e.message})` };
    }
    fs.appendFileSync(ledger, `${JSON.stringify({ key, target: line.target, result: row.result, why: row.why || '' })}\n`);
    return row;
  });
  const forCmd = `scripts/scaffold.sh${side === 'test' ? ' --test' : ''} --for <path>`;
  const show = r => {
    const what = r.line.error ? `plan.md:${r.line.at} \`${r.line.text}\`` : `\`${r.line.target}\` (${r.line.template})`;
    if (r.result === 'rendered') {
      const notes = [...(r.filled.length ? [`filled from the path: ${r.filled.join(', ')}`] : []),
        ...(r.empty.length ? [`the template reads ${r.empty.join(', ')}, which the vars left empty: check those spots`] : [])];
      return `- rendered: ${what}${notes.length ? `; ${notes.join('; ')}` : ''}`;
    }
    if (r.result === 'existing') return `- existing, not rendered: ${what}: the step changes this file, edit it`;
    if (r.result === 'earlier') {
      return `- handled earlier in this run, not rendered again: ${what} (then: ${r.first.result}${r.first.why ? `: ${r.first.why}` : ''})`;
    }
    if (r.result === 'skipped') return `- not rendered: ${what}: ${r.why}`;
    return `- failed, nothing written: ${what}: ${r.why}`;
  };
  const count = res => rows.filter(r => r.result === res).length;
  fs.writeFileSync(path.join(dir, `step-${step.n}-${side}.md`), [`# Scaffold renders — step ${step.n}, ${side} side`, '',
    rows.length ? `The scaffold-${side === 'test' ? 'tests' : 'build'} node ran this step's \`Scaffold:\` lines for ${side === 'test' ? 'test-tree files' : 'files outside the test trees'} before you started:`
      : `No \`Scaffold:\` line of step ${step.n} names a ${side === 'test' ? 'test-tree file' : 'file outside the test trees'}.`, '',
    ...rows.map(show), ...(rows.length ? ['',
      '- A rendered file is its template\'s base case, not committed yet. Fill in what the template leaves out with Edit; ' +
      'never Write over it or redirect into it (scaffold-check counts that as written by hand). When its vars were wrong, ' +
      `delete it and render it again with the command \`${forCmd}\` prints. Delete a rendered file the step does not need.`,
      `- A failed line is yours: run \`${forCmd}\` and render the file, or write it by hand with its \`Hand-written:\` line.`] : []),
    ''].join('\n'));
  for (const r of rows.filter(x => x.result === 'failed')) console.error(`SCAFFOLD-STEP: step ${step.n}: ${r.line.target || `plan.md:${r.line.at}`}: ${r.why}`);
  return { summary: `scaffold-step: step ${step.n}, ${side} side: ${count('rendered')} rendered, ${count('existing')} existing, ` +
    `${count('failed')} failed, ${count('earlier')} handled earlier, ${count('skipped')} skipped` };
}

if (require.main === module) {
  const [art, side] = process.argv.slice(2);
  if (!art || !['test', 'build'].includes(side)) { console.error('usage: node scaffold-step.js <artifacts-dir> test|build'); process.exit(2); }
  try { console.log(scaffoldStep(path.resolve(art), process.cwd(), side).summary); }
  catch (e) { console.error(`scaffold-step: ${e.message}; the agent renders the step's files itself`); }
}

module.exports = { currentStep, scaffoldLines, scaffoldStep };
