// The true clock of one Archon run, read from its event log (P2: a script, not a model; R18, T13). Archon resets a
// run's started_at on every resume, so its own duration undercounts a resumed run; this reads the log instead.
//   node run-log.js <run id or prefix> [--at <iso>]
// Prints one JSON object: {run, status, start, start_source, end, open, true_min, reported_min, resumes, stopped_min,
// buckets {build, ci, gate, merged, post, stopped, idle, other}, nodes [{id, attempt, start, end, min, outcome}]}.
//   - start: the first workflow_start, else the capture's captured_at (workflow-source/runs/<id>/manifest.json), else
//     the first event; start_source names which.
//   - end: workflow_complete, or a workflow_error no resume followed, or archon's completed_at for a run that ended
//     without either (a cancel); a run still going ends at now (or --at) and has open: true.
//   - buckets split true_min (start to end) by what the run was doing: the top-level node that started last among the
//     running ones gives the bucket (run-buckets.json); stopped is a workflow_error up to its workflow_resume; idle is
//     time with no node running. A node not in run-buckets.json counts as other, with a warning on stderr.
//   - reported_min is archon's own figure (completed_at, else now, minus started_at), null when archon cannot tell.
//   - --at replays the run as it stood at that moment: later events are ignored and archon's status is not used.
// Exit codes: 0 printed; 1 no log for the run (runs before 2026-10-18 16:09 have none); 2 usage, or an ambiguous id.
// Reads $ARCHON_HOME/workspaces/<owner>/<repo>/logs/<id>.jsonl (ARCHON_HOME defaults to ~/.archon), and asks
// `archon workflow get <id> --json` for the status (RUN_LOG_OFFLINE=1 skips it).
// Also a module: it exports parse, clock, findRun, archonGet and BUCKETS.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const HOME = process.env.ARCHON_HOME || path.join(os.homedir(), '.archon');

// build-feature's nodes by phase, in run-buckets.json (workflow-contracts.test.sh W5 checks that it names every node of
// the workflow). A loop's children are listed under their loop's bucket; the clock counts a loop child as its loop node.
const BUCKETS = JSON.parse(fs.readFileSync(path.join(__dirname, 'run-buckets.json'), 'utf8'));
const BUCKET_OF = Object.fromEntries(Object.entries(BUCKETS).flatMap(([b, ids]) => ids.map(id => [id, b])));
const ENDED = ['completed', 'failed', 'cancelled', 'rejected'];

const ms = s => { const t = Date.parse(s || ''); return Number.isNaN(t) ? null : t; };
const iso = t => (t === null || t === undefined ? null : new Date(t).toISOString());
const min = d => Math.round(d / 600) / 100; // minutes, two decimals

// parse <jsonl text>: the events with a timestamp, in log order, each with t (epoch ms).
function parse(text) {
  const out = [];
  for (const l of text.split('\n')) {
    if (!l.trim()) continue;
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    const t = ms(o.ts || o.event?.observedAt);
    if (t !== null) out.push({ ...o, t });
  }
  return out;
}

// top <event>: the top-level node id of a node event, or null for a loop child (path a.b) or an unknown event
function top(e) {
  const p = e.execution?.path;
  if (p) return p.includes('.') ? null : p;
  return BUCKET_OF[e.step] ? e.step : null;
}

// clock <events> [opts]: the run's clock. opts: {run, at (ms), capturedAt (iso), get (archon's run record), warn (fn)}
function clock(events, opts = {}) {
  const at = opts.at ?? null;
  const get = at === null ? opts.get || null : null;
  const warn = opts.warn || (() => {});
  const evs = at === null ? events : events.filter(e => e.t <= at);
  const now = at ?? Date.now();

  const ws = evs.find(e => e.type === 'workflow_start');
  let start; let startSource;
  if (ws) { start = ws.t; startSource = 'workflow_start'; }
  else if (ms(opts.capturedAt) !== null) { start = ms(opts.capturedAt); startSource = 'captured_at'; }
  else if (evs.length) { start = evs[0].t; startSource = 'first_event'; }
  else { start = null; startSource = null; }

  // Stopped intervals: a workflow_error until the next workflow_resume.
  const stopped = []; let errAt = null; let resumes = 0; let complete = null; let lastError = null;
  for (const e of evs) {
    if (e.type === 'workflow_error') { if (errAt === null) errAt = e.t; lastError = e; }
    else if (e.type === 'workflow_resume') { resumes++; if (errAt !== null) stopped.push([errAt, e.t]); errAt = null; complete = null; }
    else if (e.type === 'workflow_complete') { complete = e.t; errAt = null; }
  }

  let status; let end; let open = false;
  const archonStatus = get && get.status;
  if (complete !== null) { status = 'completed'; end = complete; }
  else if (errAt !== null && !(archonStatus && !ENDED.includes(archonStatus))) {
    status = archonStatus && ENDED.includes(archonStatus) && archonStatus !== 'completed' ? archonStatus : 'failed';
    end = errAt;
  } else if (archonStatus && ENDED.includes(archonStatus)) {
    status = archonStatus;
    end = ms(get.completed_at) ?? (evs.length ? evs[evs.length - 1].t : now);
  } else { status = archonStatus || 'running'; end = now; open = true; }
  if (start !== null && end < start) end = start;

  // Node spans, top-level only, one per attempt.
  const nodes = []; const openBy = new Map();
  const close = (n, t, outcome) => { n.end = t; n.outcome = outcome; };
  for (const e of evs) {
    if (!['node_start', 'node_complete', 'node_error', 'node_skipped'].includes(e.type)) {
      if (e.type === 'workflow_error') for (const n of openBy.values()) close(n, e.t, 'stopped');
      if (e.type === 'workflow_error') openBy.clear();
      continue;
    }
    const id = top(e);
    if (!id) continue;
    const attempt = e.execution?.attempt?.id || null;
    const key = attempt || id;
    if (e.type === 'node_start') {
      const n = { id, attempt, kind: e.execution?.node?.kind || '', start: e.t, end: null, outcome: 'running' };
      nodes.push(n); openBy.set(key, n);
      continue;
    }
    let n = openBy.get(key) || [...openBy.values()].reverse().find(x => x.id === id);
    if (!n) { n = { id, attempt, kind: e.execution?.node?.kind || '', start: e.t, end: null, outcome: '' }; nodes.push(n); }
    for (const [k, v] of openBy) if (v === n) openBy.delete(k);
    close(n, e.t, { node_complete: 'completed', node_error: 'failed', node_skipped: 'skipped' }[e.type]);
  }
  for (const n of nodes) if (n.end === null) n.end = open ? null : end;

  const buckets = { build: 0, ci: 0, gate: 0, merged: 0, post: 0, stopped: 0, idle: 0, other: 0 };
  const warned = new Set();
  const bucketOf = id => {
    if (BUCKET_OF[id]) return BUCKET_OF[id];
    if (!warned.has(id)) { warned.add(id); warn(`run-log: node ${id} is in no bucket; counted as other`); }
    return 'other';
  };
  if (start !== null) {
    const spans = nodes.map(n => ({ ...n, e: n.end ?? end }));
    const cuts = [...new Set([start, end, ...spans.flatMap(n => [n.start, n.e]), ...stopped.flat()])]
      .filter(t => t >= start && t <= end).sort((a, b) => a - b);
    for (let i = 0; i + 1 < cuts.length; i++) {
      const [a, b] = [cuts[i], cuts[i + 1]];
      const mid = (a + b) / 2;
      let bucket;
      if (stopped.some(([s, e]) => mid >= s && mid < e)) bucket = 'stopped';
      else {
        const live = spans.filter(n => n.start <= mid && n.e > mid).sort((x, y) => y.start - x.start);
        bucket = live.length ? bucketOf(live[0].id) : 'idle';
      }
      buckets[bucket] += b - a;
    }
  }
  for (const n of nodes) if (!BUCKET_OF[n.id]) bucketOf(n.id);
  for (const k of Object.keys(buckets)) buckets[k] = min(buckets[k]);

  const startedAt = get ? ms(get.started_at) : null;
  const reported = startedAt === null ? null : min((ms(get.completed_at) ?? now) - startedAt);
  return {
    run: opts.run || ws?.workflow_id || evs[0]?.workflow_id || null,
    status, start: iso(start), start_source: startSource, end: iso(end), open,
    true_min: start === null ? 0 : min(end - start), reported_min: reported, resumes,
    stopped_min: buckets.stopped, buckets,
    error: status === 'failed' && lastError ? String(lastError.error || '').slice(0, 300) : null,
    nodes: nodes.map(n => ({ id: n.id, attempt: n.attempt, kind: n.kind, start: iso(n.start), end: iso(n.end),
      min: n.end === null ? min(end - n.start) : min(n.end - n.start), outcome: n.outcome })),
  };
}

// logDirs: every $ARCHON_HOME/workspaces/<owner>/<repo>/logs folder
function logDirs() {
  const ws = path.join(HOME, 'workspaces'); const out = [];
  const ls = d => { try { return fs.readdirSync(d); } catch { return []; } };
  for (const owner of ls(ws)) for (const repo of ls(path.join(ws, owner))) {
    const d = path.join(ws, owner, repo, 'logs');
    if (fs.existsSync(d)) out.push(d);
  }
  return out;
}

// findRun <id or prefix>: {id, log, manifest} | {error: 'none' | 'ambiguous', matches}
function findRun(idOrPrefix) {
  const hits = [];
  for (const d of logDirs()) for (const f of fs.readdirSync(d)) {
    if (f.endsWith('.jsonl') && f.startsWith(idOrPrefix)) hits.push({ id: f.slice(0, -6), dir: d });
  }
  const exact = hits.find(h => h.id === idOrPrefix);
  const pick = exact ? [exact] : hits;
  if (pick.length === 0) return { error: 'none', matches: [] };
  if (pick.length > 1) return { error: 'ambiguous', matches: pick.map(h => h.id) };
  const { id, dir } = pick[0];
  const manifest = path.join(dir, '..', 'workflow-source', 'runs', id, 'manifest.json');
  return { id, log: path.join(dir, `${id}.jsonl`), manifest, capture: path.join(dir, '..', 'workflow-source', 'runs', id) };
}

// archonGet <id>: archon's record of the run, or null
function archonGet(id) {
  if (process.env.RUN_LOG_OFFLINE === '1') return null;
  const r = spawnSync('archon', ['workflow', 'get', id, '--json'], { encoding: 'utf8', timeout: 20000 });
  if (r.status !== 0 || !r.stdout) return null;
  try { const o = JSON.parse(r.stdout); return o && o.id ? o : null; } catch { return null; }
}

function capturedAt(manifest) {
  try { return JSON.parse(fs.readFileSync(manifest, 'utf8')).captured_at || null; } catch { return null; }
}

// load <id or prefix> [at]: {found, result} for the CLI and the other scripts
function load(idOrPrefix, at = null, warn = m => process.stderr.write(`${m}\n`)) {
  const f = findRun(idOrPrefix);
  if (f.error) return f;
  const get = at === null ? archonGet(f.id) : null;
  const result = clock(parse(fs.readFileSync(f.log, 'utf8')), { run: f.id, at, capturedAt: capturedAt(f.manifest), get, warn });
  return { ...f, get, result };
}

module.exports = { BUCKETS, BUCKET_OF, parse, clock, findRun, archonGet, capturedAt, load, logDirs, top, ms };

if (require.main === module) {
  const args = process.argv.slice(2);
  const usage = m => { console.error(`run-log: ${m}\nusage: node run-log.js <run id or prefix> [--at <iso>]`); process.exit(2); };
  let run = null; let at = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--at') { at = ms(args[++i]); if (at === null) usage('--at needs an ISO time'); }
    else if (args[i].startsWith('-')) usage(`unknown option ${args[i]}`);
    else if (run) usage('one run id only');
    else run = args[i];
  }
  if (!run) usage('a run id is needed');
  const r = load(run, at);
  if (r.error === 'ambiguous') { console.error(`run-log: ambiguous run id ${run}: ${r.matches.join(' ')}`); process.exit(2); }
  if (r.error) { console.error(`run-log: no log for run ${run} under ${HOME}/workspaces`); process.exit(1); }
  console.log(JSON.stringify(r.result));
}
