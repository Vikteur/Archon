// Copilot usage per Archon node (P2: a script, not a model): model calls, tokens, time and Copilot cost units of every
// agent node of a run, read from the Copilot CLI's own session log. Archon's copilot provider reports a node's tokens
// incompletely and its cost as unsupported; the CLI writes one session.usage_record per model call to
// <COPILOT_HOME or ~/.copilot>/session-state/<session-id>/events.jsonl.
//   node copilot-usage.js <run-id> [--audit <dir>] [--json]
// The join: an agent node's node_complete (or node_error) line in the run's Archon log carries
// execution.binding.sessionPreview, the first 8 characters of the Copilot session id, which names the session folder and
// the hook trail .apm-audit/sessions/<session-id>.jsonl (--audit <dir> names that sessions folder: only its record
// counts are read). One session per node; a record whose accounting.sourceSessionId names another session is not
// counted. A preview that matches no session folder, or more than one, is reported as such, never guessed.
// Input is the fresh input: the record's inputTokens holds the cache reads and writes too. `cost` is the CLI's own unit
// (Copilot cost units), never money.
// Personal data: a session log holds prompts and file contents. Only lines of type session.usage_record are parsed, and
// of those only counts, durations and the model id are kept; no text, path or account name leaves this script.
// Exits 0 (also with no Copilot session), 1 no log for the run, 2 usage.
const fs = require('fs');
const path = require('path');
const os = require('os');

const USAGE_LINE = '"type":"session.usage_record"';
const PREVIEW = /^[0-9a-f]{8}$/i;
const MODEL = /^[\w.:/-]{1,64}$/;
const SUMS = ['calls', 'input', 'cacheRead', 'cacheWrite', 'output', 'reasoning', 'costUnits', 'apiMs'];

const sessionRoot = (env = process.env) => path.join(env.COPILOT_HOME || path.join(os.homedir(), '.copilot'), 'session-state');
const zero = () => Object.fromEntries(SUMS.map(k => [k, 0]));
const num = v => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : 0);
const add = (a, b) => { for (const k of SUMS) a[k] += b[k] || 0; return a; };

// { id, file } for the one session folder whose name starts with the preview, else { error }
function findSession(root, preview) {
  if (!PREVIEW.test(String(preview || ''))) return { error: 'no session id' };
  let names;
  try { names = fs.readdirSync(root); } catch { return { error: 'no Copilot session folder' }; }
  const hits = names.filter(n => n.toLowerCase().startsWith(preview.toLowerCase()));
  if (!hits.length) return { error: 'session not found' };
  if (hits.length > 1) return { error: `preview matches ${hits.length} sessions` };
  return { id: hits[0], file: path.join(root, hits[0], 'events.jsonl') };
}

// The usage records of one session file: { total, models: Map<model, sums>, other } (other: records of another session)
function readUsage(file, id) {
  const total = zero();
  const models = new Map();
  let other = 0;
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  for (const l of text.split('\n')) {
    if (!l.includes(USAGE_LINE)) continue;
    let u;
    try { const o = JSON.parse(l); if (o.type !== 'session.usage_record') continue; u = o.data && o.data.usage; } catch { continue; }
    if (!u || typeof u !== 'object') continue;
    const src = u.accounting && u.accounting.sourceSessionId;
    if (id && typeof src === 'string' && src !== id) { other++; continue; }
    const cacheRead = num(u.cacheReadTokens);
    const cacheWrite = num(u.cacheWriteTokens);
    const r = {
      calls: 1, input: Math.max(0, num(u.inputTokens) - cacheRead - cacheWrite), cacheRead, cacheWrite,
      output: num(u.outputTokens), reasoning: num(u.reasoningTokens), costUnits: num(u.cost), apiMs: num(u.duration),
    };
    const model = [u.model, u.responseModel].find(m => typeof m === 'string' && MODEL.test(m)) || 'unknown';
    if (!models.has(model)) models.set(model, zero());
    add(models.get(model), r);
    add(total, r);
  }
  return { total, models, other };
}

// The agent nodes of a run log, in log order: { step, preview, origin, durationMs, archon: {input, output}, failed }
function nodeSessions(text) {
  const out = [];
  for (const l of text.split('\n')) {
    if (!l.includes('"node_complete"') && !l.includes('"node_error"')) continue;
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.type !== 'node_complete' && o.type !== 'node_error') continue;
    const b = o.execution && o.execution.binding;
    if (!b || !b.sessionPreview) continue;
    out.push({
      step: String(o.step || '?'), preview: String(b.sessionPreview), origin: String(b.sessionOrigin || ''),
      durationMs: num(o.duration_ms), archon: { input: num(o.tokens && o.tokens.input), output: num(o.tokens && o.tokens.output) },
      failed: o.type === 'node_error',
    });
  }
  return out;
}

// Record counts of one hook trail: { records, tools, skills }, null when there is none
function auditCounts(dir, id) {
  if (!dir || !id) return null;
  let text;
  try { text = fs.readFileSync(path.join(dir, `${id}.jsonl`), 'utf8'); } catch { return null; }
  const c = { records: 0, tools: 0, skills: 0 };
  for (const l of text.split('\n')) {
    let r;
    try { r = JSON.parse(l); } catch { continue; }
    c.records++;
    if (r.type === 'TOOL') { c.tools++; if (r.tool === 'Skill') c.skills++; }
  }
  return c;
}

// One row per agent node of the run (a node that ran more than once sums its sessions)
function perNode(text, { root = sessionRoot(), auditDir = null } = {}) {
  const rows = new Map();
  for (const n of nodeSessions(text)) {
    if (!rows.has(n.step)) {
      rows.set(n.step, { step: n.step, sessions: [], models: new Map(), ...zero(), durationMs: 0, archon: { input: 0, output: 0 },
        audit: null, missing: [], other: 0, failed: false });
    }
    const row = rows.get(n.step);
    row.sessions.push(n.preview);
    row.durationMs += n.durationMs;
    row.archon.input += n.archon.input;
    row.archon.output += n.archon.output;
    row.failed = row.failed || n.failed;
    const s = findSession(root, n.preview);
    if (s.error) { row.missing.push(`${n.preview}: ${s.error}`); continue; }
    const u = readUsage(s.file, s.id);
    if (!u) { row.missing.push(`${n.preview}: no events.jsonl`); continue; }
    add(row, u.total);
    row.other += u.other;
    for (const [m, sums] of u.models) {
      if (!row.models.has(m)) row.models.set(m, zero());
      add(row.models.get(m), sums);
    }
    const a = auditCounts(auditDir, s.id);
    if (a) {
      row.audit = row.audit || { records: 0, tools: 0, skills: 0 };
      for (const k of Object.keys(a)) row.audit[k] += a[k];
    }
  }
  return [...rows.values()];
}

const fmt = n => Math.round(n).toLocaleString('en-US');
const secs = ms => (ms ? `${Math.round(ms / 1000)} s` : '');
const units = n => (Math.round(n * 100) / 100).toString();

// Markdown: the usage table, and the trail counts when there are any; '' when the run has no Copilot node
function markdown(rows) {
  if (!rows.length) return '';
  const L = ['## Copilot usage per node (the CLI\'s session log)', '',
    '_Input is fresh input (cache reads and writes apart). Cost is in Copilot cost units, the CLI\'s own unit, not money._', '',
    '| Node | Session | Model | Model calls | Input | Cache read | Cache write | Output | Copilot cost units | Node time | Archon in/out |',
    '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'];
  const total = zero();
  for (const r of rows) {
    add(total, r);
    const model = [...r.models.keys()].join(', ') || '—';
    L.push(`| ${r.step}${r.failed ? ' (failed)' : ''} | ${r.sessions.join(', ')} | ${model} | ${r.calls} | ${fmt(r.input)} | ${fmt(r.cacheRead)} | ` +
      `${fmt(r.cacheWrite)} | ${fmt(r.output)} | ${units(r.costUnits)} | ${secs(r.durationMs)} | ${fmt(r.archon.input)}/${fmt(r.archon.output)} |`);
  }
  L.push(`| **run** | | | ${total.calls} | ${fmt(total.input)} | ${fmt(total.cacheRead)} | ${fmt(total.cacheWrite)} | ${fmt(total.output)} | ` +
    `${units(total.costUnits)} | | |`);
  const notes = rows.flatMap(r => [...r.missing.map(m => `- ${r.step}: ${m}, not counted`),
    ...(r.other ? [`- ${r.step}: ${r.other} records of another session left out`] : [])]);
  if (notes.length) L.push('', ...notes);
  const trail = rows.filter(r => r.audit);
  if (trail.length) {
    L.push('', '## Hook audit trail per node (joined by session id)', '', '| Node | Records | Tool calls | Skill calls |', '| --- | ---: | ---: | ---: |');
    for (const r of trail) L.push(`| ${r.step} | ${r.audit.records} | ${r.audit.tools} | ${r.audit.skills} |`);
  }
  L.push('');
  return L.join('\n');
}

// rows as plain JSON (models as an object)
const toJson = rows => rows.map(r => ({ ...r, models: Object.fromEntries(r.models) }));

function main(argv) {
  const json = argv.includes('--json');
  const ai = argv.indexOf('--audit');
  const auditDir = ai >= 0 ? argv[ai + 1] : null;
  const runId = argv.filter((a, i) => a !== '--json' && a !== '--audit' && !(ai >= 0 && i === ai + 1))[0];
  if (!runId || (ai >= 0 && !auditDir)) { console.error('usage: node copilot-usage.js <run-id> [--audit <dir>] [--json]'); return 2; }
  const { findLog } = require('./run-trace.js');
  const log = findLog(runId);
  if (!log) { console.error(`copilot-usage: no Archon log for run ${runId}`); return 1; }
  const rows = perNode(fs.readFileSync(log, 'utf8'), { auditDir });
  process.stdout.write(json ? `${JSON.stringify(toJson(rows), null, 2)}\n` : markdown(rows) || 'No Copilot agent node in this run.\n');
  return 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));
module.exports = { sessionRoot, findSession, readUsage, nodeSessions, auditCounts, perNode, markdown, toJson };
