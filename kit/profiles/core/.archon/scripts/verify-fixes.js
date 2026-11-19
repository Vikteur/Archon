// Grade one build-feature run against the workflow fixes it should carry (P2: a script grades the canary, not a model
// reading its logs; R18, T13). The checks read the run's event log (exec_output stdout, stderr and exit code per node)
// and its workflow capture (did the run carry the fix at all).
//   node verify-fixes.js <run id or prefix> [--woke <iso>] [--commit <sha>] [--pr <url>] [--fixes 69,72]
//     One JSON line per fix, {fix, verdict, evidence}, then {summary: {pass, fail, ...}, exit}. A verdict is
//       pass           the fix triggered and did its job
//       fail           the fix triggered and the old failure is back
//       not-triggered  the run never reached the case the fix handles (grade it on a later run or by its unit test)
//       not-in-capture the run's captured workflow does not carry the fix, so the run is no valid canary
//       unknown        the evidence cannot tell: a tail cut at 2000 characters where only the absence of a failure
//                      would prove a pass, or an input left out (--woke, --commit, archon's record)
//     --woke: when the delegator saw the run ready (69 grades the wait: at most 75 s after the merged node started).
//     --commit: the ticket commit on main (64 grades that it touches backlog/ only).
//     --pr: the run's pull request (70 checks open-pr printed it).
//   node verify-fixes.js --preflight [--ticket <TASK-n>]
//     The canary's preconditions, one JSON line each {check, ok, detail}: sync-main.sh --dry-run exits 0, the main
//     checkout is clean, no build-feature run is live, the merge queue is empty, no ready records, and the ticket (when
//     named) has no stop-* label.
// Exit codes: 0 no fail and no not-in-capture (preflight: all ok); 1 any fail (it wins over 3; preflight: any not ok);
// 3 any not-in-capture; 2 usage, or a log or capture it cannot read.
// The checks are the FIXES table below (kept here rather than in a JSON file so a message change and its pattern move in
// one diff; the test pins them). Not graded: 62 (its evidence is the scope-guard audit trail, not the run log), 68 (a
// drill, not a run), 73 (its exemption was dropped).
// Overrides: VERIFY_FIXES_REPO (the main checkout; default: this script's repo), READY_RUNS_DIR, ARCHON_HOME.
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const runLog = require('./run-log.js');

const REPO = process.env.VERIFY_FIXES_REPO || path.resolve(__dirname, '..', '..');
const CUT = '[truncated to last';
const WOKE_MAX_S = 75;
const FIRST_NODE_MAX_S = 60;

// The messages each fix's check looks for. A pattern change here is a change in what a script prints.
const FIXES = {
  57: { what: 'main checkout fast-forwards before a launch' },
  59: { what: 'CI by SHA on the pushed head', steps: ['ci'] },
  64: { what: 'the ticket commit on main touches backlog/ only' },
  65: { what: 'single-quoted node outputs', steps: ['ci', 'ready', 'gate'],
    fail: [/a quote in the argument/, /\b\d{3,}'/] },
  66: { what: 'a resume keeps the YAML of its launch', file: '.archon/workflows/build-feature.yaml' },
  69: { what: 'the ready signal', file: '.archon/workflows/build-feature.yaml', marker: 'RUN_ID=$WORKFLOW_ID',
    fail: [/could not list run/] },
  70: { what: 'open-pr pushes with a lease', steps: ['open-pr'], fail: [/Refusing to overwrite/] },
  71: { what: 'local-ci job names', steps: ['ci', 'ready', 'main-ci'], fail: [/local-ci\/[\w.-]+=missing/] },
  72: { what: 'main-ci on the merge commit', file: '.archon/workflows/build-feature.yaml', marker: 'main-ci.sh',
    steps: ['main-ci'], fail: [/cannot tell which commit/, /"state":\s*"none"/],
    pass: [/is reused/, /"state":\s*"(green|red)"/] },
  74: { what: 'token reports commit', file: '.archon/scripts/close-out.sh',
    marker: 'bash "$umbrella/scripts/tokenomics/commit-reports.sh"', steps: ['close-out'],
    fail: [/Permission denied/, /token reports were not committed/] },
};

const v = (verdict, evidence) => ({ verdict, evidence });
const cut = s => String(s || '').includes(CUT);
const short = s => String(s || '').replace(/\s+/g, ' ').trim().slice(-160);
const git = (...args) => spawnSync('git', ['-C', REPO, ...args], { encoding: 'utf8' });

// lastJson <text>: the last {...} object in a node's stdout, or null
function lastJson(text) {
  const lines = String(text || '').split('\n').reverse();
  for (const l of lines) {
    const m = l.match(/\{.*\}/);
    if (!m) continue;
    try { return JSON.parse(m[0]); } catch { /* not this line */ }
  }
  return null;
}

// grade <ctx> <fix id>: {verdict, evidence}
function grade(ctx, id) {
  const fx = FIXES[id];
  const outs = steps => ctx.events.filter(e => e.type === 'exec_output' && steps.includes(e.step));
  const text = e => `${e.stdout_tail || ''}\n${e.stderr_tail || ''}`;
  const hit = (list, pats) => {
    for (const e of list) for (const p of pats || []) { const m = text(e).match(p); if (m) return { e, m: m[0] }; }
    return null;
  };
  let captured = null;
  if (fx.file) {
    const f = path.join(ctx.capture, 'project', fx.file);
    try { captured = fs.readFileSync(f, 'utf8'); } catch { return v('not-in-capture', `the capture has no ${fx.file}`); }
    if (fx.marker && !captured.includes(fx.marker)) return v('not-in-capture', `${fx.file} in the capture lacks ${fx.marker}`);
  }
  const node = id => ctx.events.find(e => e.type === 'node_start' && e.execution?.path === id);

  switch (Number(id)) {
    case 57: {
      const ws = ctx.events.find(e => e.type === 'workflow_start');
      const first = ctx.events.find(e => e.type === 'node_start');
      if (!ws) return v('unknown', 'no workflow_start in the log');
      if (!first) return v('fail', 'the run started no node');
      const s = (first.t - ws.t) / 1000;
      return s <= FIRST_NODE_MAX_S ? v('pass', `first node ${first.step} ${s.toFixed(1)} s after workflow_start`)
        : v('fail', `first node ${first.step} only ${s.toFixed(1)} s after workflow_start`);
    }
    case 59: {
      const list = outs(fx.steps);
      if (!list.length) return v('not-triggered', 'the run has no ci output');
      const pushed = new Set(outs(['open-pr']).map(e => lastJson(e.stdout_tail)?.sha).filter(Boolean));
      for (const e of list) {
        const o = lastJson(e.stdout_tail);
        if (!o) return v('unknown', `ci printed no result${cut(e.stdout_tail) ? ' (tail cut)' : ''}`);
        if (o.state === 'none') return v('fail', `ci state none on ${o.sha}`);
        if (!['green', 'red'].includes(o.state)) return v('fail', `ci state ${o.state}`);
        if (!pushed.has(o.sha)) return v('fail', `ci graded ${o.sha}, open-pr pushed ${[...pushed].join(' ') || 'nothing'}`);
      }
      return v('pass', `ci graded the pushed head (${[...pushed].map(s => s.slice(0, 7)).join(' ')})`);
    }
    case 64: {
      if (!ctx.commit) return v('not-triggered', 'no --commit given');
      const r = git('show', '--stat', '--format=', '--name-only', ctx.commit);
      if (r.status !== 0) return v('unknown', `git show ${ctx.commit} failed: ${short(r.stderr)}`);
      const files = r.stdout.split('\n').filter(Boolean);
      const other = files.filter(f => !f.startsWith('backlog/'));
      return other.length ? v('fail', `the commit touches ${other.slice(0, 5).join(' ')}`)
        : v('pass', `${files.length} file(s), all under backlog/`);
    }
    case 65: {
      const list = outs(fx.steps);
      if (!list.length) return v('not-triggered', 'no ci, ready or gate output');
      for (const e of list) for (const p of fx.fail) {
        const m = String(e.stderr_tail || '').match(p);
        if (m) return v('fail', `${e.step} stderr: ${m[0]}`);
      }
      const bad = list.find(e => e.exit_code !== 0);
      if (bad) return v('fail', `${bad.step} exited ${bad.exit_code}`);
      if (list.some(e => cut(e.stderr_tail))) return v('unknown', 'a stderr tail was cut; the quote error may be in the cut part');
      return v('pass', `${list.length} output(s), no quote error, all exit 0`);
    }
    case 66: {
      const base = ctx.get?.checkout_baseline?.commit;
      if (!base) return v('unknown', "archon's record gives no checkout baseline");
      const r = git('show', `${base}:${fx.file}`);
      if (r.status !== 0) return v('unknown', `git show ${base.slice(0, 7)}:${fx.file} failed`);
      return r.stdout === captured ? v('pass', `the captured YAML equals ${base.slice(0, 7)}'s`)
        : v('fail', `the captured YAML differs from ${base.slice(0, 7)}'s`);
    }
    case 69: {
      const m = node('merged');
      if (!m) return v('not-triggered', 'the run never reached merged');
      const h = hit(outs(['merged']), fx.fail);
      if (h) return v('fail', `merged: ${h.m}`);
      if (ctx.status === 'completed') {
        const dir = readyDir();
        if (dir && fs.existsSync(path.join(dir, `${ctx.run}.json`))) return v('fail', `a ready record is left in ${dir}`);
      }
      if (ctx.woke === null) return v('unknown', `merged started ${new Date(m.t).toISOString()}; no --woke given`);
      const s = (ctx.woke - m.t) / 1000;
      return s <= WOKE_MAX_S ? v('pass', `ready seen ${s.toFixed(0)} s after merged started`)
        : v('fail', `ready seen ${s.toFixed(0)} s after merged started (more than ${WOKE_MAX_S} s)`);
    }
    case 70: {
      const list = outs(fx.steps);
      if (!list.length) return v('not-triggered', 'no open-pr output');
      const h = hit(list, fx.fail);
      if (h) return v('fail', `open-pr: ${h.m}`);
      const last = list[list.length - 1];
      if (last.exit_code !== 0) return v('fail', `open-pr last exited ${last.exit_code}`);
      const o = lastJson(last.stdout_tail);
      if (!o || !o.pr || !o.sha) return v(cut(last.stdout_tail) ? 'unknown' : 'fail', 'open-pr printed no {pr, sha}');
      if (ctx.pr && o.pr !== ctx.pr) return v('fail', `open-pr printed ${o.pr}, not ${ctx.pr}`);
      return v('pass', `open-pr exited 0 with ${o.pr} at ${o.sha.slice(0, 7)}${list.length > 1 ? ` (after ${list.length - 1} retry)` : ''}`);
    }
    case 71: {
      const list = outs(fx.steps);
      if (!list.length) return v('not-triggered', 'no ci, ready or main-ci output');
      const h = hit(list, fx.fail);
      if (h) return v('fail', `${h.e.step}: ${h.m}`);
      if (list.some(e => cut(e.stdout_tail) || cut(e.stderr_tail))) return v('unknown', 'a tail was cut; a missing job may be in the cut part');
      return v('pass', 'no local-ci job reported missing');
    }
    case 72: {
      const list = outs(fx.steps);
      if (!list.length) return v('not-triggered', 'the run never reached main-ci');
      const h = hit(list, fx.fail);
      if (h) return v('fail', `main-ci: ${h.m}`);
      const p = hit(list, fx.pass);
      if (p) return v('pass', `main-ci: ${p.m}`);
      return v('unknown', `main-ci printed neither a reuse nor a state: ${short(list[list.length - 1].stdout_tail)}`);
    }
    case 74: {
      const list = outs(fx.steps);
      if (!list.length) return v('not-triggered', 'close-out never ran');
      for (const e of list) for (const p of fx.fail) {
        const m = String(e.stderr_tail || '').match(p);
        if (m) return v('fail', `close-out stderr: ${m[0]}`);
      }
      if (list.some(e => cut(e.stderr_tail))) return v('unknown', 'the close-out stderr tail was cut; the error may be in the cut part');
      return v('pass', 'close-out reported no token report error');
    }
    default: return v('unknown', 'no check for this fix');
  }
}

function readyDir() {
  if (process.env.READY_RUNS_DIR) return process.env.READY_RUNS_DIR;
  const r = git('worktree', 'list', '--porcelain');
  const main = r.status === 0 ? (r.stdout.match(/^worktree (.*)$/m) || [])[1] : null;
  return main ? path.join(path.dirname(main), 'merge-queue', 'ready') : null;
}

function preflight(ticket) {
  const out = [];
  const add = (check, ok, detail) => out.push({ check, ok, detail: short(detail) });
  const sh = (script, ...a) => spawnSync('bash', [path.join(REPO, '.archon', 'scripts', script), ...a],
    { cwd: REPO, encoding: 'utf8', env: { ...process.env, ...(readyDir() ? { READY_RUNS_DIR: readyDir() } : {}) } });

  let r = sh('sync-main.sh', '--dry-run');
  add('sync-main', r.status === 0, r.status === 0 ? r.stdout : r.stderr || `exit ${r.status}`);
  r = git('status', '--porcelain');
  add('clean-checkout', r.status === 0 && !r.stdout.trim(), r.status !== 0 ? r.stderr : r.stdout.trim() ? r.stdout.split('\n').slice(0, 3).join('; ') : 'clean');
  r = spawnSync('archon', ['workflow', 'runs', '--json', '--limit', '50'], { encoding: 'utf8', timeout: 20000 });
  let live = null;
  try {
    live = JSON.parse(r.stdout).runs.filter(x => x.workflow_name === 'build-feature' && ['running', 'paused', 'pending'].includes(x.status));
  } catch { /* archon down */ }
  add('no-live-run', live !== null && live.length === 0,
    live === null ? 'archon workflow runs failed' : live.length ? live.map(x => `${x.id.slice(0, 8)} ${x.status}`).join(', ') : 'none');
  r = sh('merge-turn.sh', 'list');
  add('merge-queue-empty', r.status === 0 && !r.stdout.trim(), r.status !== 0 ? r.stderr : r.stdout.trim() || 'empty');
  r = sh('ready-runs.sh', 'list');
  add('no-ready-records', r.status === 0 && !r.stdout.trim(), r.status !== 0 ? r.stderr : r.stdout.trim() || 'none');
  if (ticket) {
    r = spawnSync('backlog', ['task', 'view', ticket, '--plain'], { cwd: REPO, encoding: 'utf8' });
    const labels = (r.stdout.match(/^Labels:\s*(.*)$/m) || [])[1] || '';
    const stops = labels.split(/[,\s]+/).filter(l => l.startsWith('stop'));
    add('ticket-no-stop-label', r.status === 0 && !stops.length, r.status !== 0 ? r.stderr || `exit ${r.status}` : stops.join(' ') || 'none');
  }
  for (const o of out) console.log(JSON.stringify(o));
  return out.every(o => o.ok) ? 0 : 1;
}

module.exports = { FIXES, grade, lastJson };

if (require.main === module) {
  const args = process.argv.slice(2);
  const usage = m => { console.error(`verify-fixes: ${m}\nusage: node verify-fixes.js <run> [--woke <iso>] [--commit <sha>] [--pr <url>] [--fixes 69,72]\n       node verify-fixes.js --preflight [--ticket <TASK-n>]`); process.exit(2); };
  const o = { run: null, woke: null, commit: null, pr: null, fixes: null, preflight: false, ticket: null };
  for (let i = 0; i < args.length; i++) {
    const a = args[i]; const val = () => { const x = args[++i]; if (x === undefined) usage(`${a} needs a value`); return x; };
    if (a === '--woke') { o.woke = runLog.ms(val()); if (o.woke === null) usage('--woke needs an ISO time'); }
    else if (a === '--commit') o.commit = val();
    else if (a === '--pr') o.pr = val();
    else if (a === '--fixes') { o.fixes = val().split(',').map(s => s.trim()).filter(Boolean); }
    else if (a === '--preflight') o.preflight = true;
    else if (a === '--ticket') o.ticket = val();
    else if (a.startsWith('-')) usage(`unknown option ${a}`);
    else if (o.run) usage('one run id only');
    else o.run = a;
  }
  if (o.preflight) process.exit(preflight(o.ticket));
  if (!o.run) usage('a run id is needed');
  for (const f of o.fixes || []) if (!FIXES[f]) usage(`no check for fix ${f} (checks: ${Object.keys(FIXES).join(',')})`);
  const found = runLog.findRun(o.run);
  if (found.error === 'ambiguous') usage(`ambiguous run id ${o.run}: ${found.matches.join(' ')}`);
  if (found.error) { console.error(`verify-fixes: no log for run ${o.run}`); process.exit(2); }
  let events;
  try { events = runLog.parse(fs.readFileSync(found.log, 'utf8')); } catch (e) { console.error(`verify-fixes: cannot read ${found.log}: ${e.message}`); process.exit(2); }
  const get = runLog.archonGet(found.id);
  const status = runLog.clock(events, { run: found.id, get }).status;
  const ctx = { run: found.id, events, capture: found.capture, get, status, woke: o.woke, commit: o.commit, pr: o.pr };
  const summary = { pass: 0, fail: 0, 'not-triggered': 0, 'not-in-capture': 0, unknown: 0 };
  for (const id of o.fixes || Object.keys(FIXES)) {
    const g = grade(ctx, id);
    summary[g.verdict]++;
    console.log(JSON.stringify({ fix: Number(id), verdict: g.verdict, evidence: g.evidence }));
  }
  const exit = summary.fail ? 1 : summary['not-in-capture'] ? 3 : 0;
  console.log(JSON.stringify({ run: found.id, summary, exit }));
  process.exit(exit);
}
