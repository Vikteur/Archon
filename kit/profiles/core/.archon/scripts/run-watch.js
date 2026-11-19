// What every build-feature run is doing, and which one is stuck (P2: a script reads the logs, not a model; R19, T14).
// The delegator's status lines and the supervisor's pings come from here, so a run that sits at merged all night is
// named within minutes (37e12149 waited 489.8 min unseen; owner decision D7: a ready run merges at once, so 10 minutes
// at merged is already a stall).
//   node run-watch.js snapshot [--json] [--at <iso>]
//     One line per build-feature run that is live or ended in the last 2 h, e.g.
//       TASK-5.2 37e12149 waiting-for-merge since 23:47 (8h10m) PR #150, as of 07:57
//     Phases: building, ci, gate, waiting-for-merge, post-merge, failed (with the node and an excerpt), completed (with
//     close=true|false), cancelled; a paused run says so. Times are local. The status is archon's (`archon workflow runs`)
//     and falls back to the log, with a warning, when archon cannot be asked; the phase comes from the log's open nodes.
//     A waiting run's since is its ready record's, else its merged node's start. --json prints {as_of, source, runs: []}.
//   node run-watch.js stalls [--json] [--state <file>] [--at <iso>]
//     One line per stall: {run, kind, since, over_min, threshold_min, hint} (--json), or a readable line. over_min is
//     how long the condition has held. Kinds and their thresholds in minutes (env RUN_WATCH_<KIND>_MIN overrides, e.g.
//     RUN_WATCH_MERGED_WAIT_MIN=30):
//       merged-wait 10 (D7)        waiting-for-merge that long
//       failed-not-resumed 10      failed and not resumed
//       main-ci-slow 10            the main-ci node running that long
//       gate-wait 20               the auto-merge gate running that long
//       close-false 0              completed with close-out skipped because finalize said close=false
//       no-progress 20             an agent node with no log event for that long
//     --state <file> keeps what was printed: a run:kind already printed is printed again only after 30 min; a stall that
//     has cleared is forgotten. Exit 0 no stall printed, 1 a stall printed, 2 an error.
//   node run-watch.js events <previous snapshot.json> <current snapshot.json>
//     The changes between two `snapshot --json` files, one JSON line each with a stable key for the supervisor:
//       {key: "<run>:new", ...}, {key: "<run>:<phase>:<since>", event: "phase", from, to, ...}, {key: "<run>:gone", ...}
//     Exit 0, or 2 when a file cannot be read.
//   --at <iso> replays every log as it stood at that moment. Archon's record is used only for a run that had ended by
//   then (a cancel leaves no event in the log); without archon such a run replays as still going.
// Reads $ARCHON_HOME/workspaces/*/*/logs (ARCHON_HOME defaults to ~/.archon) and the ready records in $READY_RUNS_DIR
// (default: merge-queue/ready/ beside the main checkout).
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const runLog = require('./run-log.js');
const BUILD_WORKFLOW = require('./kit-config').kitGet('build_workflow', 'build-feature', 'BUILD_WORKFLOW');

const WINDOW_MS = 2 * 60 * 60 * 1000;
const REPEAT_MS = 30 * 60 * 1000;
const THRESHOLDS = { 'merged-wait': 10, 'failed-not-resumed': 10, 'main-ci-slow': 10, 'gate-wait': 20, 'close-false': 0, 'no-progress': 20 };
const PHASE_OF = { build: 'building', ci: 'ci', gate: 'gate', merged: 'waiting-for-merge', post: 'post-merge' };
const HINTS = {
  'merged-wait': 'merge it through the merge gate (merge-ready), or hold it: bash .archon/scripts/ready-runs.sh hold <run>',
  'failed-not-resumed': 'read the error (archon workflow get <run>), then resume or park the ticket',
  'main-ci-slow': 'check the local CI on the merge commit: bash .archon/scripts/local-ci-status.sh',
  'gate-wait': 'the gate waits on reviews, CI or a STOP item: gh pr view <pr>',
  'close-false': 'finalize said the ticket is not done: read its notes and decide whether to close it by hand',
  'no-progress': 'the agent node logged nothing: archon workflow get <run>; cancel and resume if it hangs',
};

const threshold = kind => {
  const env = process.env[`RUN_WATCH_${kind.toUpperCase().replace(/-/g, '_')}_MIN`];
  return env !== undefined && env !== '' && !Number.isNaN(Number(env)) ? Number(env) : THRESHOLDS[kind];
};
const hhmm = t => new Date(t).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', hour12: false });
const dur = d => { const m = Math.max(0, Math.floor(d / 60000)); return m >= 60 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m` : `${m}m`; };
const minutes = d => Math.round(d / 600) / 100;
const iso = t => new Date(t).toISOString();

function readyRecords() {
  let dir = process.env.READY_RUNS_DIR;
  if (!dir) {
    const r = spawnSync('git', ['-C', __dirname, 'worktree', 'list', '--porcelain'], { encoding: 'utf8' });
    const main = r.status === 0 ? (r.stdout.match(/^worktree (.*)$/m) || [])[1] : null;
    if (main) dir = path.join(path.dirname(main), 'merge-queue', 'ready');
  }
  const out = {};
  if (!dir) return out;
  let files = [];
  try { files = fs.readdirSync(dir); } catch { return out; }
  for (const f of files) {
    if (!f.endsWith('.json')) continue;
    try { const o = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); out[o.run || f.slice(0, -5)] = o; } catch { /* half-written */ }
  }
  return out;
}

// archonRuns: {id: run record} from `archon workflow runs`, or null when archon cannot be asked
function archonRuns() {
  if (process.env.RUN_LOG_OFFLINE === '1') return null;
  const r = spawnSync('archon', ['workflow', 'runs', '--json', '--limit', '50'], { encoding: 'utf8', timeout: 20000 });
  try { return Object.fromEntries(JSON.parse(r.stdout).runs.map(x => [x.id, x])); } catch { return null; }
}

// describe <events> <id> <now> <archon record|null> <ready record|null>: one run's state, or null when it is no
// build-feature run
function describe(events, id, now, rec, ready, replay = false) {
  const ws = events.find(e => e.type === 'workflow_start');
  const name = ws?.workflow_name || rec?.workflow_name;
  if (name !== BUILD_WORKFLOW && name !== 'build-feature') return null;
  const ended = rec && runLog.ms(rec.completed_at) !== null && runLog.ms(rec.completed_at) <= now;
  const get = replay && !ended ? null : rec;
  const c = runLog.clock(events, { run: id, at: get ? null : now, get, warn: () => {} });
  const exec = step => events.filter(e => e.type === 'exec_output' && e.step === step);
  const lastJson = step => { for (const e of exec(step).reverse()) { const m = String(e.stdout_tail || '').match(/\{[^\n]*\}/g); if (m) for (const s of m.reverse()) { try { return JSON.parse(s); } catch { /* next */ } } } return null; };
  const ticket = lastJson('ticket')?.task || (String(ws?.content || rec?.user_message || '').match(/TASK-[\d.]+/) || [])[0] || null;
  const prUrl = lastJson('open-pr')?.pr || ready?.pr || null;
  const pr = prUrl ? `#${(prUrl.match(/(\d+)\/?$/) || [])[1] || prUrl}` : null;
  const lastEvent = events.length ? events[events.length - 1].t : null;
  const s = { run: id, ticket, status: c.status, phase: null, node: null, kind: null, since: null, pr, pr_url: prUrl,
    close: null, excerpt: null, end: c.open ? null : c.end, last_event: lastEvent === null ? null : iso(lastEvent) };
  const open = c.nodes.filter(n => n.end === null).sort((a, b) => Date.parse(b.start) - Date.parse(a.start));
  if (c.status === 'completed') {
    // The last close-out event decides: a resumed run may have skipped it on an earlier attempt.
    const last = [...events].reverse().find(e => ['node_skipped', 'node_complete'].includes(e.type) && e.step === 'close-out');
    const skip = last?.type === 'node_skipped' ? last : null;
    const fin = lastJson('finalize');
    s.phase = 'completed';
    if (skip) s.close = JSON.stringify(skip.cause || {}).includes('close') ? false : null;
    else if (last) s.close = true;
    if (fin && fin.close !== undefined) s.close = String(fin.close) === 'true';
    s.since = c.end; s.close_skip = skip ? skip.t : null;
  } else if (c.status === 'failed' || c.status === 'cancelled') {
    s.phase = c.status;
    const bad = [...c.nodes].reverse().find(n => n.outcome === 'failed') || c.nodes[c.nodes.length - 1];
    s.node = bad?.id || null;
    s.excerpt = c.error ? c.error.replace(/\s+/g, ' ').slice(0, 120) : null;
    s.since = c.end;
  } else {
    const cur = open[0] || null;
    s.node = cur?.id || null; s.kind = cur?.kind || null;
    s.phase = cur ? PHASE_OF[runLog.BUCKET_OF[cur.id]] || cur.id : 'starting';
    s.since = cur ? cur.start : c.start;
    if (s.phase === 'waiting-for-merge' && ready?.since) s.since = ready.since;
    if (c.status === 'paused') s.paused = true;
  }
  return s;
}

// snapshot [at]: {as_of, source, runs}
function snapshot(at = null) {
  const now = at ?? Date.now();
  const arch = archonRuns();
  if (at === null && arch === null) process.stderr.write('run-watch: archon cannot be asked; the status comes from the logs\n');
  const ready = readyRecords();
  const runs = [];
  for (const d of runLog.logDirs()) for (const f of fs.readdirSync(d)) {
    if (!f.endsWith('.jsonl')) continue;
    const id = f.slice(0, -6);
    let events;
    try { events = runLog.parse(fs.readFileSync(path.join(d, f), 'utf8')); } catch { continue; }
    if (at !== null) events = events.filter(e => e.t <= at);
    if (!events.length) continue;
    const s = describe(events, id, now, arch ? arch[id] || null : null, ready[id] || null, at !== null);
    if (!s) continue;
    if (s.end && now - Date.parse(s.end) > WINDOW_MS) continue;
    runs.push(s);
  }
  runs.sort((a, b) => Date.parse(a.since || 0) - Date.parse(b.since || 0));
  return { as_of: iso(now), source: at !== null ? 'replay' : arch ? 'archon' : 'log', runs };
}

function line(s, now) {
  const head = `${s.ticket || '?'} ${s.run.slice(0, 8)} ${s.phase}${s.paused ? ' (paused)' : ''}`;
  const since = s.since ? ` since ${hhmm(Date.parse(s.since))} (${dur(now - Date.parse(s.since))})` : '';
  let tail = '';
  if (s.phase === 'failed') tail = ` at ${s.node || '?'}${s.excerpt ? `: ${s.excerpt}` : ''}`;
  else if (s.phase === 'completed') tail = ` close=${s.close === null ? '?' : s.close}`;
  else if (s.node && !['waiting-for-merge'].includes(s.phase)) tail = ` at ${s.node}`;
  return `${head}${since}${tail}${s.pr ? ` PR ${s.pr}` : ''}, as of ${hhmm(now)}`;
}

// stalls <snapshot>: [{run, kind, since, over_min, threshold_min, hint}]
function stalls(snap) {
  const now = Date.parse(snap.as_of);
  const out = [];
  const add = (s, kind, since) => {
    const held = now - Date.parse(since);
    if (held < threshold(kind) * 60000) return;
    out.push({ run: s.run, ticket: s.ticket, kind, since, over_min: minutes(held), threshold_min: threshold(kind),
      hint: HINTS[kind].replace('<run>', s.run.slice(0, 8)).replace('<pr>', s.pr_url || 'the PR') });
  };
  for (const s of snap.runs) {
    if (s.phase === 'waiting-for-merge') add(s, 'merged-wait', s.since);
    if (s.phase === 'failed') add(s, 'failed-not-resumed', s.since);
    if (s.node === 'main-ci' && s.phase === 'post-merge') add(s, 'main-ci-slow', s.since);
    if (s.phase === 'gate') add(s, 'gate-wait', s.since);
    if (s.phase === 'completed' && s.close === false) add(s, 'close-false', iso(s.close_skip || Date.parse(s.since)));
    if (s.kind === 'agent' && !['completed', 'failed', 'cancelled'].includes(s.phase) && s.last_event) add(s, 'no-progress', s.last_event);
  }
  return out;
}

function events(prev, cur) {
  const out = [];
  const by = snap => Object.fromEntries((snap.runs || []).map(r => [r.run, r]));
  const p = by(prev); const c = by(cur);
  for (const [id, r] of Object.entries(c)) {
    const base = { run: id, ticket: r.ticket, phase: r.phase, since: r.since, as_of: cur.as_of };
    if (!p[id]) out.push({ key: `${id}:new`, event: 'new', ...base });
    else if (p[id].phase !== r.phase || p[id].since !== r.since) out.push({ key: `${id}:${r.phase}:${r.since}`, event: 'phase', from: p[id].phase, to: r.phase, ...base });
  }
  for (const id of Object.keys(p)) if (!c[id]) out.push({ key: `${id}:gone`, event: 'gone', run: id, ticket: p[id].ticket, phase: p[id].phase, as_of: cur.as_of });
  return out;
}

module.exports = { snapshot, stalls, events, describe, THRESHOLDS };

if (require.main === module) {
  const [cmd, ...args] = process.argv.slice(2);
  const usage = m => { console.error(`run-watch: ${m}\nusage: node run-watch.js snapshot [--json] [--at <iso>] | stalls [--json] [--state <file>] [--at <iso>] | events <prev.json> <now.json>`); process.exit(2); };
  if (cmd === 'events') {
    if (args.length !== 2) usage('events needs two snapshot files');
    let a; let b;
    try { a = JSON.parse(fs.readFileSync(args[0], 'utf8')); b = JSON.parse(fs.readFileSync(args[1], 'utf8')); } catch (e) { console.error(`run-watch: ${e.message}`); process.exit(2); }
    for (const e of events(a, b)) console.log(JSON.stringify(e));
    process.exit(0);
  }
  if (!['snapshot', 'stalls'].includes(cmd)) usage(cmd ? `unknown command ${cmd}` : 'a command is needed');
  let json = false; let at = null; let state = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--json') json = true;
    else if (args[i] === '--at') { at = runLog.ms(args[++i]); if (at === null) usage('--at needs an ISO time'); }
    else if (args[i] === '--state' && cmd === 'stalls') { state = args[++i]; if (!state) usage('--state needs a file'); }
    else usage(`unknown option ${args[i]}`);
  }
  let snap;
  try { snap = snapshot(at); } catch (e) { console.error(`run-watch: ${e.message}`); process.exit(2); }
  const now = Date.parse(snap.as_of);
  if (cmd === 'snapshot') {
    if (json) console.log(JSON.stringify(snap));
    else if (!snap.runs.length) console.log(`no build-feature run live or ended in the last 2 h, as of ${hhmm(now)}`);
    else for (const s of snap.runs) console.log(line(s, now));
    process.exit(0);
  }
  let found = stalls(snap);
  if (state) {
    let seen = {};
    try { seen = JSON.parse(fs.readFileSync(state, 'utf8')); } catch { /* first round */ }
    const next = {};
    const show = [];
    for (const s of found) {
      const key = `${s.run}:${s.kind}`;
      const last = runLog.ms(seen[key]);
      if (last === null || now - last >= REPEAT_MS) { show.push(s); next[key] = snap.as_of; } else next[key] = seen[key];
    }
    try { fs.writeFileSync(state, JSON.stringify(next, null, 1)); } catch (e) { console.error(`run-watch: cannot write ${state}: ${e.message}`); process.exit(2); }
    found = show;
  }
  for (const s of found) {
    if (json) { const { ticket, ...o } = s; console.log(JSON.stringify(o)); }
    else console.log(`STALL ${s.kind} ${s.ticket || '?'} ${s.run.slice(0, 8)} since ${hhmm(Date.parse(s.since))}, ${Math.floor(s.over_min)} min (threshold ${s.threshold_min}): ${s.hint}`);
  }
  process.exit(found.length ? 1 : 0);
}
