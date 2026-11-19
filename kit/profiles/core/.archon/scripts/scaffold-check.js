// Scaffold report (P2: a script, not a model): for every source file the branch added, was its first version rendered
// by scripts/scaffold.sh, or written by hand? And for a file written by hand: does a scaffold template target that kind
// of path, and does the plan say why the file was written by hand?
//   node scaffold-check.js <artifacts-dir> [<run-id>] [<base>] [<head>] [--follow-ups]
// Writes <artifacts-dir>/scaffold-check.md. A GATE (owner decisions 2026-10-18 and 2026-10-23, docs/memory.md): every
// source file written by hand needs a line in <artifacts-dir>/plan.md, in one of two forms:
//   Hand-written: <path> — no-template: <shape>[ — <note>]       no template targets the path; <shape> is a kebab-case
//                                                                 word for what the file is (enum, exception, ...)
//   Hand-written: <path> — template-misfit: <template> — <why>   a template targets the path but does not fit
// (the dash may be —, – or -). A <path> ending in `/**` names every file under that directory for which its form
// holds; a line for the file itself beats it, and of two lines for one file the last counts. It exits 1 when
//   - a file written by hand has no such line;
//   - a line says no-template for a file a template targets (loaded skill or not), or template-misfit with a template
//     that does not target the file;
//   - a `Hand-written:` line is in neither form.
// The reviewer checks that each template-misfit reason holds. It fails closed: no merge base, no plan.md, no Archon log
// for the run, or a check that cannot run exits 1 too. A missing <artifacts-dir> argument exits 2.
// --follow-ups (the workflow's scaffold-check node), only when the gate passes: writes and commits a follow-up
// (docs/follow-ups/agentic/script/, source kind `gate`) for each template a file was a misfit for, and for each
// no-template shape that the plans of three tickets or more name (this run's, and those of the other runs beside
// <artifacts-dir>), unless a follow-up of that template or shape exists already, whatever its status. A run with no
// ticket in <artifacts-dir>/ticket.md writes none.
// Added files: `git diff --diff-filter=A -M` from the merge base of origin/<base> (else <base>; default main) and
// <head> (default HEAD), so a moved file is not new.
// Source files only: .java .kt .kts .groovy .scala .ts .tsx .js .jsx .mjs .cjs .sql under a src/ directory, except
// what sits under resources/ (a Flyway migration under resources/db/migration/ counts). Everything else is listed as
// not counted.
// Scaffolded: the file is the target of
//   - a SCAFFOLD record in .apm-audit/scaffold.jsonl (scripts/scaffold.sh writes one per file it renders; records
//     before the run started are ignored), or
//   - a `[scaffold] <target>` line in the output of a run's Bash call that ran scripts/scaffold.sh (the run's Archon
//     log keeps every tool call whole, with its output; runs before the SCAFFOLD record have only this).
// Written by hand otherwise, and also when the run's log shows a Write call or a whole-file Bash redirect (`>`, `tee`)
// that wrote the rendered file over after its render: then "Created by" names that call and the row says so. Else
// "Created by" names the first Write call or Bash redirect (`>`, `>>`, `tee`) that names it.
// A template targets the file when the path matches the Target cell of a row in a docs/code-maps leaf's `## Scaffold`
// table (scripts/scaffold/targets.js, which scripts/scaffold.sh --for uses too). A skill counts as loaded when the run's
// Archon log or the audit trail (.apm-audit/sessions) has a Skill call for it; the report says which fits were loaded.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { findLog } = require('./run-trace.js');
const { templateTargets, targetRegex } = require('../../scripts/scaffold/targets.js');

const SOURCE_EXT = /\.(java|kts?|groovy|scala|tsx?|jsx?|mjs|cjs|sql)$/;
const FOLLOW_UPS = 'docs/follow-ups/agentic/script';

function isSource(p) {
  if (!/(^|\/)src\//.test(p) || !SOURCE_EXT.test(p)) return false;
  return !/\/resources\//.test(p) || /\/resources\/db\/migration\//.test(p);
}

function git(args) {
  return execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
}

// { base, added: [paths] } or { problem }
function addedFiles(base, head) {
  let mb = '';
  for (const b of [`origin/${base}`, base]) {
    try { mb = git(['merge-base', b, head]).trim(); break; } catch { /* try the next */ }
  }
  if (!mb) return { problem: `no merge base of origin/${base} (or ${base}) and ${head}` };
  const out = git(['diff', '--diff-filter=A', '-M', '--name-only', '-z', mb, head]);
  return { base: mb, added: out.split('\0').filter(Boolean) };
}

const norm = p => String(p || '').replace(/\\/g, '/').replace(/^\.\//, '');
const endsAt = (whole, part) => whole === part || whole.endsWith('/' + part);
const hhmmss = t => (Number.isFinite(t) ? new Date(t).toISOString().slice(11, 19) + 'Z' : '');
const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const cell = s => String(s).replace(/\|/g, '\\|');

// { start, calls: [{ name, input, step, t, status, out }] } from the run's Archon log
function logCalls(text) {
  const byId = new Map();
  const calls = [];
  let start = NaN;
  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.type === 'workflow_start' && Number.isNaN(start)) start = Date.parse(o.ts || '');
    const e = o.type === 'provider_event' && o.event;
    if (!e) continue;
    if (e.type === 'tool_call') {
      const c = { name: e.name, input: e.rawInput || {}, step: o.step || '', t: Date.parse(o.observedAt || ''), status: '', out: '' };
      byId.set(e.toolCallId, c);
      calls.push(c);
    } else if (e.type === 'tool_call_update' && byId.has(e.toolCallId)) {
      const c = byId.get(e.toolCallId);
      c.status = e.status || c.status;
      if (e.output !== undefined) {
        let out = e.output;
        if (typeof out === 'string') { try { out = JSON.parse(out); } catch { /* plain text */ } }
        c.out = typeof out === 'string' ? out : [out.stdout, out.stderr].filter(Boolean).join('\n') || JSON.stringify(out);
      }
    }
  }
  return { start, calls };
}

// [{ target, template, how }] from .apm-audit/scaffold.jsonl
function scaffoldRecords(root, since) {
  let text = '';
  try { text = fs.readFileSync(path.join(root, '.apm-audit', 'scaffold.jsonl'), 'utf8'); } catch { return []; }
  const recs = [];
  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.type !== 'SCAFFOLD' || !o.target) continue;
    const t = Date.parse(o.loggedAt || '');
    if (Number.isFinite(since) && Number.isFinite(t) && t < since - 1000) continue;
    recs.push({ target: norm(o.target), template: o.template || '?', how: 'SCAFFOLD record', t });
  }
  return recs;
}

// [{ target, template, how, step, t }] from the `[scaffold] <target>` lines of the run's Bash calls
function scaffoldOutputs(calls) {
  const recs = [];
  for (const c of calls) {
    const cmd = c.input.command || '';
    if (c.name !== 'Bash' || !cmd.includes('scaffold.sh') || !c.out) continue;
    // one segment per scaffold.sh invocation, from its name up to the next one
    const segs = cmd.split(/(?=scaffold\.sh\s)/).filter(s => /^scaffold\.sh\s/.test(s));
    for (const m of c.out.matchAll(/^\[scaffold\] (.+?)\s*$/gm)) {
      const target = norm(m[1]);
      const base = path.posix.basename(target);
      const seg = segs.find(s => s.includes(base));
      const tm = seg && /^scaffold\.sh\s+(?:--test\s+)?(?:"([^"]+)"|'([^']+)'|(\S+))/.exec(seg);
      const template = tm ? norm(tm[1] || tm[2] || tm[3]).replace(/\.mustache$/, '').replace(/^.*(?:Moustache scripts|scaffold-templates)\//, '') : '?';
      recs.push({ target, template, how: 'scaffold.sh output', step: c.step, t: c.t });
    }
  }
  return recs;
}

// first Write call or Bash redirect that names the file: { how, step, t } or null
function createdBy(file, calls) {
  const base = path.posix.basename(file);
  const redirect = new RegExp(`(?:>>?|\\btee\\b(?:\\s+-a)?)\\s*["']?[^\\s"'<>|;&]*?(?:^|/|\\$\\w+/|\\$\\{\\w+\\}/)?${esc(base)}(?![\\w.])`, 'm');
  for (const c of calls) {
    if (c.status === 'failed') continue;
    if ((c.name === 'Write' || c.name === 'NotebookEdit') && endsAt(norm(c.input.file_path || c.input.notebook_path), file)) {
      return { how: 'Write', step: c.step, t: c.t };
    }
    if (c.name === 'Bash' && redirect.test(c.input.command || '')) return { how: 'Bash redirect', step: c.step, t: c.t };
  }
  return null;
}

// first Write call or whole-file Bash redirect (`>`, `tee`; not `>>` or `tee -a`) that names the file after the render
// at <after>, other than a scaffold.sh call: { how, step, t } or null. A rendered file written over whole was written
// by hand: the render bought nothing, and the vars and the read-back cost tokens on top (owner request 2026-10-24).
function rewrittenBy(file, calls, after) {
  if (!Number.isFinite(after)) return null;
  const base = path.posix.basename(file);
  const whole = new RegExp(`(?:(?<![>&\\d])>(?!>)|\\btee\\b(?!\\s+-a))\\s*["']?[^\\s"'<>|;&]*?(?:^|/|\\$\\w+/|\\$\\{\\w+\\}/)?${esc(base)}(?![\\w.])`, 'm');
  for (const c of calls) {
    if (c.status === 'failed' || !(c.t > after)) continue;
    if ((c.name === 'Write' || c.name === 'NotebookEdit') && endsAt(norm(c.input.file_path || c.input.notebook_path), file)) {
      return { how: 'Write', step: c.step, t: c.t };
    }
    const cmd = c.name === 'Bash' ? c.input.command || '' : '';
    if (cmd && !cmd.includes('scaffold.sh') && whole.test(cmd)) return { how: 'Bash redirect', step: c.step, t: c.t };
  }
  return null;
}

const DASH ='\\s+(?:—|–|--?)\\s+';
const FORMS = '`Hand-written: <path> — no-template: <shape>` or `Hand-written: <path> — template-misfit: <template> — <why>`';

// The plan's `Hand-written:` lines: { named: [{ file, glob, kind, shape, note, template, why, n }], malformed: [{ line, n }] }.
// glob is true for a <path> ending in `/**` (file is then the directory); n is the line number.
function handWritten(text) {
  const named = [];
  const malformed = [];
  text.split(/\r?\n/).forEach((l, i) => {
    const m = /^\s*(?:[-*]\s+)?Hand-written:\s*(.*?)\s*$/.exec(l);
    if (!m) return;
    const n = i + 1;
    const f = new RegExp(`^\`?([^\`\\s]+?)\`?${DASH}(no-template|template-misfit):\\s*(.*)$`).exec(m[1]);
    const nt = f && f[2] === 'no-template' && new RegExp(`^\`?([a-z0-9]+(?:-[a-z0-9]+)*)\`?(?:${DASH}(\\S.*))?$`).exec(f[3]);
    const tm = f && f[2] === 'template-misfit' && new RegExp(`^\`?([A-Za-z0-9_./-]+?)\`?${DASH}(\\S.*)$`).exec(f[3]);
    if (!nt && !tm) { malformed.push({ line: l.trim(), n }); return; }
    const file = norm(f[1]);
    const glob = file.endsWith('/**');
    const h = { file: glob ? file.slice(0, -3) : file, glob, kind: f[2], n };
    if (nt) Object.assign(h, { shape: nt[1], note: nt[2] || '' });
    else Object.assign(h, { template: tm[1].replace(/\.mustache$/, ''), why: tm[2] });
    named.push(h);
  });
  return { named, malformed };
}

const holds = (h, fits) => (h.kind === 'no-template' ? !fits.length : fits.some(t => t.template === h.template));
const lineText = h => (h.kind === 'no-template' ? `no-template: ${h.shape}${h.note ? ` — ${h.note}` : ''}` : `template-misfit: ${h.template} — ${h.why}`);

// The plan line that names a file written by hand, and its verdict: { line, verdict: no-template | misfit | refused, refusal }
function judge(file, fits, named) {
  const exact = named.filter(h => !h.glob && endsAt(file, h.file)).pop();
  const line = exact || named.filter(h => h.glob && (file.startsWith(h.file + '/') || file.includes('/' + h.file + '/')) && holds(h, fits)).pop();
  const fitList = fitsText(fits);
  if (!line) {
    return {
      line: null, verdict: 'refused',
      refusal: fits.length
        ? `a template targets it: ${fitList}. Render it (\`scripts/scaffold.sh --for ${file}\` prints the command), or, when none fits, name it \`Hand-written: ${file} — template-misfit: <template> — <why>\``
        : `no template targets it, and the plan does not name it: add \`Hand-written: ${file} — no-template: <shape>\``,
    };
  }
  if (holds(line, fits)) return { line, verdict: line.kind === 'no-template' ? 'no-template' : 'misfit', refusal: null };
  return {
    line, verdict: 'refused',
    refusal: line.kind === 'no-template'
      ? `plan.md line ${line.n} says no-template, but ${fitList} targets it: render it, or name the one that does not fit with template-misfit`
      : fits.length
        ? `plan.md line ${line.n} says template-misfit: ${line.template}, which does not target it; what does: ${fitList}`
        : `plan.md line ${line.n} says template-misfit: ${line.template}, but no template targets it: say no-template: <shape>`,
  };
}

// skills the run loaded: the Archon log's Skill calls and the audit trail's Skill records since the run started
function loadedSkills(root, calls, since) {
  const got = new Set();
  const add = s => { if (s) got.add(String(s).replace(/^.*:/, '')); };
  for (const c of calls) if (c.name === 'Skill' && c.status !== 'failed') add(c.input.skill);
  const dir = path.join(root, '.apm-audit', 'sessions');
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { /* no trail */ }
  for (const f of files) {
    for (const l of fs.readFileSync(path.join(dir, f), 'utf8').split('\n')) {
      let o;
      try { o = JSON.parse(l); } catch { continue; }
      if (o.type !== 'TOOL' || o.tool !== 'Skill' || o.ok === false) continue;
      const t = Date.parse(o.loggedAt || '');
      if (Number.isFinite(since) && Number.isFinite(t) && t < since - 1000) continue;
      try { add(JSON.parse(o.arg).skill); } catch { add((/"skill"\s*:\s*"([\w:-]+)"/.exec(o.arg || '') || [])[1]); }
    }
  }
  return got;
}

// problems: what kept the check from judging every file; any one fails the gate (fail closed)
function check({ runId, base = 'main', head = 'HEAD', root = process.cwd(), plan }) {
  const problems = [];
  const a = addedFiles(base, head);
  if (a.problem) return { problems: [a.problem], rows: [], skipped: [], malformed: [], loaded: new Set(), base, head };
  let hw = { named: [], malformed: [] };
  try { hw = handWritten(fs.readFileSync(plan, 'utf8')); } catch { problems.push(`no plan at ${plan}: no file can be named as hand-written`); }
  let calls = [];
  let since = NaN;
  const log = runId && findLog(runId);
  if (log) ({ start: since, calls } = logCalls(fs.readFileSync(log, 'utf8')));
  else problems.push(`no Archon log for run ${runId || '(none given)'}: the skills the run loaded are unknown, only SCAFFOLD records count, and "Created by" is unknown`);

  const scaffolds = [...scaffoldRecords(root, since), ...scaffoldOutputs(calls)];
  const templates = templateTargets(root);
  const loaded = loadedSkills(root, calls, since);
  const rows = [];
  const skipped = [];
  for (const f of a.added) {
    if (!isSource(f)) { skipped.push(f); continue; }
    // the last render counts: a file rendered again after a `git rm` is judged from that render on
    const s = scaffolds.filter(r => endsAt(f, r.target) || endsAt(r.target, f)).sort((x, y) => (y.t || 0) - (x.t || 0))[0];
    const over = s && rewrittenBy(f, calls, s.t);
    if (s && !over) {
      rows.push({ file: f, scaffolded: true, template: s.template, verdict: 'scaffolded', by: { how: s.how, step: s.step, t: s.t } });
      continue;
    }
    const fits = templates.filter(t => t.re.test(f));
    const j = judge(f, fits, hw.named);
    if (over && j.verdict === 'refused' && fits.length && !j.line) {
      j.refusal = `rendered with ${s.template}, then written over whole (${over.how}): a template that fits is edited, `
        + `never rewritten. Render it again and edit it, or, when ${s.template} does not fit, name it \`Hand-written: ${f} — `
        + `template-misfit: ${s.template} — <why>\``;
    }
    rows.push({
      file: f, scaffolded: false, fits, loadedFit: fits.some(t => loaded.has(t.skill)), by: over || createdBy(f, calls),
      rendered: over ? s.template : null, verdict: j.verdict, refusal: j.refusal, line: j.line, reason: j.line ? lineText(j.line) : null,
    });
  }
  return { problems, rows, skipped, malformed: hw.malformed, loaded, base: a.base, head };
}

// "t1, t2 (skill); t3 (skill, not loaded)", with loaded the skills the run loaded (none given: no mark)
function fitsText(fits, loaded) {
  const bySkill = new Map();
  for (const t of fits) bySkill.set(t.skill, [...(bySkill.get(t.skill) || []), t.template]);
  return [...bySkill].map(([skill, ts]) => `${ts.join(', ')} (${skill}${!loaded || loaded.has(skill) ? '' : ', not loaded'})`).join('; ');
}

// { id, title, epic } from the ticket node's ticket.md, or null when the run has no ticket
function ticketOf(art) {
  let text = '';
  try { text = fs.readFileSync(path.join(art, 'ticket.md'), 'utf8'); } catch { return null; }
  const t = /^Task (TASK-\d+(?:\.\d+)*) - (.+?)\s*$/m.exec(text);
  if (!t) return null;
  const p = /^Parent: (TASK-\d+(?:\.\d+)*) - (.+?)\s*$/m.exec(text);
  return { id: t[1], title: t[2], epic: p ? { id: p[1], title: p[2] } : null };
}

// every follow-up JSON under docs/follow-ups/
function followUpFiles(root) {
  const out = [];
  const walk = d => {
    let ents = [];
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.json') && e.name !== 'follow-up.schema.json') {
        try { out.push(JSON.parse(fs.readFileSync(p, 'utf8'))); } catch { /* not a follow-up */ }
      }
    }
  };
  walk(path.join(root, 'docs', 'follow-ups'));
  return out;
}

// The follow-ups this run owes (owner decision 2026-10-23): one per misfit template at once, one per no-template shape
// from its third ticket on, none twice. Returns { write: [{ id, file, json }], notes: [lines for the report] }.
function followUps(root, art, runId, rows, today = new Date().toISOString().slice(0, 10)) {
  const ticket = ticketOf(art);
  if (!ticket) return { write: [], notes: ['No ticket in ticket.md: no follow-ups.'] };
  const existing = followUpFiles(root);
  const refOf = key => existing.find(f => String((f.source || {}).ref || '').startsWith(key));
  let nn = Math.max(0, ...existing.map(f => Number((new RegExp(`^FU-${esc(ticket.id)}-(\\d{2})$`).exec(f.id || '') || [])[1] || 0)));
  const write = [];
  const notes = [];
  const add = (key, title, description, impact, priorityScore, scoreRationale) => {
    const id = `FU-${ticket.id}-${String(++nn).padStart(2, '0')}`;
    const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 60).replace(/^-+|-+$/g, '');
    write.push({
      id, file: `${FOLLOW_UPS}/${id}-${slug}.json`,
      json: {
        id, title, category: 'script', ownerDecision: true,
        originalTicket: { id: ticket.id, title: ticket.title }, epic: ticket.epic,
        source: { kind: 'gate', ref: `${key} run ${runId || '(none)'}`, pr: null },
        description,
        reasonNotFixedInReview: 'Scaffold templates and their targets change only on the owner\'s request (docs/memory.md); the run wrote the file by hand and named why in its plan.',
        impact, priorityScore, scoreRationale, possiblyCoveredBy: [], status: 'open', backlogTask: null, created: today,
      },
    });
    notes.push(`Written: ${id}, ${title}.`);
  };

  const misfits = new Map();
  for (const x of rows.filter(r => r.verdict === 'misfit')) misfits.set(x.line.template, [...(misfits.get(x.line.template) || []), x]);
  for (const [template, xs] of misfits) {
    const key = `scaffold-check template-misfit: ${template},`;
    const had = refOf(key);
    if (had) { notes.push(`template-misfit ${template}: ${had.id} has it already (${had.status}).`); continue; }
    const skill = (xs[0].fits.find(t => t.template === template) || {}).skill || '?';
    add(key, `Scaffold template ${template} did not fit a file ${ticket.id} added`,
      `The plan of ${ticket.id} (build-feature run ${runId || '(none)'}) wrote ${xs.length === 1 ? 'a file' : `${xs.length} files`} by hand where the scaffold template ${template} (skill ${skill}) targets the path: `
        + xs.map(x => `${x.file} (${x.line.why})`).join('; ')
        + `. Either the template should render what such a file needs, or its Target in docs/code-maps/${skill}.md is wider than what it renders. Written by the scaffold-check gate.`,
      'MEDIUM', 6, 'MEDIUM: every later ticket that adds this kind of file writes it by hand again or bends the template; it recurs with the next such file.');
  }

  const shapes = new Map();
  for (const x of rows.filter(r => r.verdict === 'no-template')) shapes.set(x.line.shape, [...(shapes.get(x.line.shape) || []), x.file]);
  if (shapes.size) {
    const others = [];
    let runs = [];
    try { runs = fs.readdirSync(path.dirname(art)).filter(d => d !== path.basename(art)); } catch { /* no other runs */ }
    for (const d of runs) {
      const dir = path.join(path.dirname(art), d);
      const t = ticketOf(dir);
      let plan = '';
      try { plan = fs.readFileSync(path.join(dir, 'plan.md'), 'utf8'); } catch { continue; }
      if (t) others.push({ ticket: t.id, shapes: new Set(handWritten(plan).named.filter(h => h.kind === 'no-template').map(h => h.shape)) });
    }
    for (const [shape, files] of shapes) {
      const tickets = [...new Set([ticket.id, ...others.filter(o => o.shapes.has(shape)).map(o => o.ticket)])]
        .sort((x, y) => x.localeCompare(y, 'en', { numeric: true }));
      const key = `scaffold-check no-template: ${shape},`;
      const had = refOf(key);
      if (had) { notes.push(`no-template ${shape}: ${had.id} has it already (${had.status}).`); continue; }
      if (tickets.length < 3) { notes.push(`no-template ${shape}: ${tickets.length} of the 3 tickets a follow-up needs (${tickets.join(', ')}).`); continue; }
      add(key, `No scaffold template for the ${shape} shape: ${tickets.length} tickets wrote one by hand`,
        `The plans of ${tickets.join(', ')} each named a file of shape ${shape} as written by hand because no scaffold template targets it; in ${ticket.id} (build-feature run ${runId || '(none)'}): ${files.join(', ')}. `
          + 'From the third ticket with one shape, a template rendered by scripts/scaffold.sh, with a row in the ## Scaffold table of the docs/code-maps leaf of the skill that owns the file, may pay for itself. Written by the scaffold-check gate.',
        'LOW', 4, `LOW: nothing breaks without it, but it recurs: ${tickets.length} tickets wrote this shape by hand.`);
    }
  }
  return { write, notes };
}

// Write the follow-ups and commit them, alone, on the branch
function commitFollowUps(root, write) {
  if (!write.length) return;
  for (const w of write) {
    fs.mkdirSync(path.dirname(path.join(root, w.file)), { recursive: true });
    fs.writeFileSync(path.join(root, w.file), JSON.stringify(w.json, null, 2) + '\n');
  }
  const files = write.map(w => w.file);
  execFileSync('git', ['add', '--', ...files], { cwd: root, stdio: ['ignore', 'ignore', 'pipe'] });
  execFileSync('git', ['commit', '-q', '-m', `docs(follow-ups): ${write.map(w => w.id).join(', ')} from the scaffold-check gate`,
    '-m', 'Written by .archon/scripts/scaffold-check.js --follow-ups (owner decision 2026-10-23, docs/memory.md).', '--', ...files],
  { cwd: root, stdio: ['ignore', 'ignore', 'pipe'] });
}

function report(art, r, fu) {
  const { rows, skipped, problems, malformed } = r;
  const scaffolded = rows.filter(x => x.scaffolded);
  const hand = rows.filter(x => !x.scaffolded);
  const refused = hand.filter(x => x.verdict === 'refused');
  const named = hand.filter(x => x.verdict !== 'refused');
  const misfit = named.filter(x => x.verdict === 'misfit');
  const ok = !problems.length && !refused.length && !malformed.length;
  const by = b => (b ? [b.how, b.step, hhmmss(b.t)].filter(Boolean).join(', ') : 'not in the run log');
  const out = ['# Scaffold check — the source files this branch added, scaffolded or written by hand', ''];
  out.push(`Gate: **${ok ? 'passed' : 'failed'}.** ${rows.length} added source file(s) since ${String(r.base || '').slice(0, 7)}: `
    + `**${scaffolded.length} scaffolded, ${hand.length} written by hand: ${named.length - misfit.length} no-template, `
    + `${misfit.length} template-misfit, ${refused.length} refused.**`
    + (malformed.length ? ` **${malformed.length} \`Hand-written:\` line(s) in neither form.**` : ''), '');
  for (const p of problems) out.push(`- The check cannot judge every file: ${p}`);
  if (problems.length) out.push('');
  out.push('## Refused', '');
  if (!refused.length && !malformed.length) out.push('None.');
  if (refused.length) {
    out.push('Each file written by hand needs a line under its step in plan.md: `Hand-written: <path> — no-template: <shape>` '
      + 'when no template targets it, `Hand-written: <path> — template-misfit: <template> — <why>` when one does but does not fit. '
      + '`scripts/scaffold.sh --for <path>` says which.', '');
    out.push('| File | Why | Created by |', '|---|---|---|');
    for (const x of refused) out.push(`| \`${x.file}\` | ${cell(x.refusal)} | ${by(x.by)} |`);
  }
  if (malformed.length) {
    out.push('', `Lines in plan.md in neither form (${FORMS}):`, '');
    for (const m of malformed) out.push(`- line ${m.n}: \`${m.line.replace(/`/g, "'")}\``);
  }
  if (named.length) {
    out.push('', '## Named hand-written in the plan', '', '| File | Templates that target it | Plan line |', '|---|---|---|');
    for (const x of named) out.push(`| \`${x.file}\` | ${x.fits.length ? fitsText(x.fits, r.loaded) : 'none'} | ${cell(x.reason)} |`);
  }
  if (fu) {
    out.push('', '## Follow-ups', '');
    out.push(...(fu.notes.length ? fu.notes.map(n => `- ${n}`) : ['None due.']));
  }
  out.push('', `<details><summary>Every added source file (${rows.length})</summary>`, '');
  if (rows.length) {
    out.push('| File | How | Templates that target it | Created by |', '|---|---|---|---|');
    for (const x of rows) {
      if (x.scaffolded) { out.push(`| \`${x.file}\` | scaffolded | ${x.template} | ${by(x.by)} |`); continue; }
      out.push(`| \`${x.file}\` | by hand, ${x.verdict}${x.rendered ? `, rendered with ${x.rendered} then written over` : ''} | ${x.fits.length ? fitsText(x.fits, r.loaded) : 'none'} | ${by(x.by)} |`);
    }
  } else out.push('No source file was added.');
  out.push('', '</details>', '');
  if (skipped.length) {
    out.push(`<details><summary>Not counted, not source (${skipped.length})</summary>`, '');
    for (const f of skipped) out.push(`- \`${f}\``);
    out.push('', '</details>', '');
  }
  out.push('Rule: a source file is scaffolded when scripts/scaffold.sh rendered it (its SCAFFOLD record, or its `[scaffold]` '
    + 'line in the run log) and no Write call or whole-file Bash redirect wrote it over after that; a template targets it when the path matches a Target in a `## Scaffold` table of docs/code-maps '
    + '(see .archon/scripts/scaffold-check.js).');
  fs.mkdirSync(art, { recursive: true });
  fs.writeFileSync(path.join(art, 'scaffold-check.md'), out.join('\n') + '\n');
  return { ok, scaffolded: scaffolded.length, hand: hand.length, refused: refused.length, malformed: malformed.length, named: named.length, misfit: misfit.length, problems: problems.length };
}

function main(argv) {
  const withFollowUps = argv.includes('--follow-ups');
  const [art, runId, base, head] = argv.filter(a => a !== '--follow-ups');
  if (!art) { console.error('usage: node scaffold-check.js <artifacts-dir> [<run-id>] [<base>] [<head>] [--follow-ups]'); process.exitCode = 2; return; }
  try {
    const dir = path.resolve(art);
    const r = check({ runId, base: base || 'main', head: head || 'HEAD', plan: path.join(dir, 'plan.md') });
    let n = report(dir, r);
    let fu = null;
    if (n.ok && withFollowUps) {
      fu = followUps(process.cwd(), dir, runId, r.rows);
      commitFollowUps(process.cwd(), fu.write);
      n = report(dir, r, fu);
    }
    console.log(`SCAFFOLD: ${n.ok ? 'passed' : 'FAILED'}: ${n.scaffolded} scaffolded, ${n.hand} by hand (${n.named - n.misfit} no-template, `
      + `${n.misfit} template-misfit, ${n.refused} refused), ${n.malformed} malformed Hand-written line(s), ${n.problems} problem(s)`
      + (fu ? `, ${fu.write.length} follow-up(s) written` : ''));
    if (!n.ok) process.exitCode = 1;
  } catch (e) {
    // fail closed: a check that cannot run fails the gate
    process.exitCode = 1;
    try {
      fs.mkdirSync(path.resolve(art), { recursive: true });
      fs.writeFileSync(path.join(path.resolve(art), 'scaffold-check.md'),
        `# Scaffold check — the source files this branch added, scaffolded or written by hand\n\nGate: **failed.** The check could not run: ${e.message}\n`);
    } catch { /* nothing more to do */ }
    console.log(`SCAFFOLD: FAILED: the check could not run: ${e.message}`);
  }
}

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  handWritten, judge, isSource, targetRegex, templateTargets, scaffoldOutputs, createdBy, rewrittenBy, logCalls, check, fitsText,
  ticketOf, followUps, FORMS,
};
