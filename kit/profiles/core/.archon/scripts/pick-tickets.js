// The tickets the delegator may build at the same time (P2: a script, not a model; owner decision 2026-10-18,
// docs/memory.md, TASK-55; park, night list and start at merge: owner decisions D1, D10, D11 of 2026-10-20).
//   node pick-tickets.js [--max <n> | --cap <n>] [--list <file>] [--night]
//     --max <n>     pick at most n tickets, 1 to 3 (default 2); live runs are not read (the caller counts them)
//     --cap <n>     pick as many as there is room for, cap 1 to 3: room = min(n - runs before their merge,
//                   4 - every live run). A build-feature run past its `merged` node (main-ci, close-out) no longer
//                   counts toward the cap, only toward the ceiling of 4, and its ticket's components are free, so the
//                   next ticket starts at the merge. Runs come from `archon workflow runs --json --verbose`.
//     --list <file> pick only the tickets named in the file (one TASK id per line, `#` starts a comment); it implies
//                   --night. A named ticket that is not a ready To Do ticket is skipped with its reason.
//     --night       skip what must not run unattended: a `P4` ticket, a `manual` ticket and a ticket with a `stop-*`
//                   label that no current owner approval covers ("stop-unapproved").
// Prints JSON: { picked: [{ id, title, components, stop }], skipped: [{ id, reason }], busy: [components], night }, and
// with --cap also { cap, ceiling, room, runs: [{ run, task, phase }] } (phase pre-merge, post-merge or parked). In night
// mode each skip is also printed to stderr, one line each.
// Candidates are the ready To Do tickets (`backlog task list -s "To Do" --ready --json`: every dependency done), highest
// priority first, then by ordinal. A ticket is picked when its Groma component references (a reference that is a bare
// element id such as `orders-backend`, not a path) share none with a ticket already picked or one In Progress (busy).
// An In Progress ticket that depends on a ticket waits for it (TASK-63): its components do not count as busy for that
// one, and do for every other. The list leaves dependencies out, so they are read per In Progress ticket with
// `backlog task view <id> --json`. An In Progress ticket labelled `parked` (park-ticket.sh) holds no component and its
// run no slot; one whose live run is past `merged` holds no component either. A failed run is not live, so its ticket
// stays busy (fail closed).
// Skipped, each with its reason: an epic (label `epic` or a title with `Epic:`), a ticket labelled `parked`, one
// labelled `stop-contract-push` (build-feature does not change the contract), the night-mode skips above, and a ticket
// whose components are taken. A ticket with no component reference cannot be shown apart from the others, so it is
// picked only alone: as the first pick, and then nothing more. `stop` lists the ticket's other `stop-*` labels, for the
// delegator to judge.
// Owner approvals: judged by stop-lib.js (verdict, `ticket` mode), with `.archon/stop/policy.json` and the files under
// `.archon/stop/approvals/` at origin/main (the owner's chat approvals, recorded by stop-approve.sh record; a `_` file
// grants nothing): a label is approved when a standing rule of the policy covers its category, or an entry for exactly
// this ticket and category whose file and entry are not revoked or expired, in the owner's name, with a matching digest. A category
// that is never coverable, an unknown stop-* label, or no policy at origin/main: never approved. The merge gate
// (stop-check.sh) still judges every PR: this only keeps an unapproved ticket out of a night.
// Fails closed: a backlog or archon command that fails or prints no JSON exits 1; a bad argument or an unreadable list
// exits 2.
// Overrides for the tests: PICK_TODO_JSON and PICK_ACTIVE_JSON, files that stand in for the two backlog lists (a
// fixture's In Progress tickets carry their own `dependencies`); PICK_RUNS_JSON for the archon runs; PICK_APPROVALS_DIR,
// a folder of approval files read instead of origin/main; PICK_POLICY_FILE, the STOP policy read instead of origin/main;
// PICK_NOW, the time approvals are judged at.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const { kitGet } = require('./kit-config');
const BUILD_WORKFLOW = kitGet('build_workflow', 'build-feature', 'BUILD_WORKFLOW');
const RANK = { high: 0, medium: 1, low: 2 };
const CEILING = 4;
const ENDED = new Set(['completed', 'failed', 'cancelled', 'rejected']);
const isComponent = r => /^[a-z0-9][a-z0-9-]*$/.test(String(r).trim());
const run = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024 });

function list(status, env, extra) {
  const file = process.env[env];
  const text = file ? fs.readFileSync(file, 'utf8') : run('backlog', ['task', 'list', '-s', status, ...extra, '--json']);
  const o = JSON.parse(text);
  const tasks = Array.isArray(o) ? o : o && Array.isArray(o.tasks) ? o.tasks : null;
  if (!tasks) throw new Error(`no task list in the backlog output for "${status}"`);
  return tasks;
}

const components = t => [...new Set((t.references || []).filter(isComponent).map(r => r.trim()))];
const key = id => String(id).trim().toUpperCase();
const parked = t => (t.labels || []).includes('parked');

function withDependencies(active) {
  if (process.env.PICK_ACTIVE_JSON) return active;
  return active.map(t => {
    const o = JSON.parse(run('backlog', ['task', 'view', t.id, '--json']));
    const view = o && o.task ? o.task : o;
    if (!view || !Array.isArray(view.dependencies)) throw new Error(`no dependencies in the backlog view of ${t.id}`);
    return { ...t, dependencies: view.dependencies };
  });
}

// The live build-feature runs, each with its ticket and whether its `merged` node completed.
function liveRuns() {
  const file = process.env.PICK_RUNS_JSON;
  const text = file ? fs.readFileSync(file, 'utf8') : run('archon', ['workflow', 'runs', '--json', '--verbose', '--limit', '50']);
  const o = JSON.parse(text);
  const runs = Array.isArray(o) ? o : o && Array.isArray(o.runs) ? o.runs : null;
  if (!runs) throw new Error('no run list in the archon output');
  return runs.filter(r => r.workflow_name === BUILD_WORKFLOW && !ENDED.has(r.status)).map(r => {
    const nodes = Array.isArray(r.nodes) ? r.nodes : [];
    let task = null;
    const ticket = nodes.find(n => n.nodeId === 'ticket');
    try { task = JSON.parse(ticket && ticket.outputPreview).task || null; } catch (e) { task = null; }
    if (!task) { const m = /\bTASK-\d+(?:\.\d+)*/i.exec(r.user_message || ''); task = m ? m[0] : null; }
    const merged = nodes.some(n => n.nodeId === 'merged' && n.state === 'completed');
    return { run: r.id, task: task ? key(task) : null, merged };
  });
}

// A file at origin/main (or, for the tests, in a fixture folder), as text; null when it is not there.
function mainFile(rel) {
  try { return run('git', ['show', `origin/main:${rel}`]); } catch (e) { return null; }
}

function approvalFiles() {
  const dir = process.env.PICK_APPROVALS_DIR;
  if (dir) {
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir).filter(f => f.endsWith('.json') && !f.startsWith('_'))
      .map(f => ({ name: f, text: fs.readFileSync(path.join(dir, f), 'utf8') }));
  }
  let names;
  try { names = run('git', ['ls-tree', '--name-only', 'origin/main', '.archon/stop/approvals/']).split('\n').filter(n => n.endsWith('.json')); }
  catch (e) { return []; }   // no origin/main or no folder: nothing is approved
  return names.filter(n => !path.basename(n).startsWith('_')).map(n => ({ name: path.basename(n), text: mainFile(n) || '' }));
}

// The judge of a ticket's stop-* labels at night: stop-lib.js's own verdict in `ticket` mode (the same judgement as
// `stop-check.sh ticket <id>`: the policy's coverable categories and standing rules, and only an entry whose file
// and entry are not revoked, not expired, in the owner's name and whose digest matches). It returns the labels no rule
// or approval covers. No policy at origin/main, or a policy stop-lib cannot read: every stop-* label is unapproved.
function stopJudge(now) {
  let lib, policy;
  try {
    lib = require(process.env.PICK_STOP_LIB || path.join(__dirname, 'stop-lib.js'));
    const text = process.env.PICK_POLICY_FILE ? fs.readFileSync(process.env.PICK_POLICY_FILE, 'utf8') : mainFile('.archon/stop/policy.json');
    policy = text === null ? null : lib.loadPolicy(text);
  } catch (e) { policy = null; }
  if (!policy) return { ok: false, unapproved: (id, stops) => stops };
  const approvalsIn = approvalFiles();
  return { ok: true, unapproved: (id, stops) => {
    if (!stops.length) return [];
    try {
      const v = lib.verdict({ policy, ticket: id, now, mode: 'ticket', labels: stops, approvals: approvalsIn });
      return stops.filter(l => v.items.some(i => i.source === 'label' && i.detail === l && i.verdict !== 'covered'));
    } catch (e) { return stops; }   // fail closed
  } };
}

function readList(file) {
  const ids = fs.readFileSync(file, 'utf8').split('\n').map(l => l.replace(/#.*/, '').trim()).filter(Boolean);
  const bad = ids.filter(id => !/^TASK-\d+(\.\d+)*$/i.test(id));
  if (bad.length) throw new Error(`not a ticket id: ${bad.join(', ')}`);
  return ids.map(key);
}

function pick(todo, active, max, opts = {}) {
  const { night = false, listed = null, judge = null, released = new Set() } = opts;
  const holding = active.filter(a => !parked(a) && !released.has(key(a.id)));
  const busy = new Set(holding.flatMap(components));
  const busyFor = t => new Set(holding.filter(a => !(a.dependencies || []).map(key).includes(key(t.id))).flatMap(components));
  const taken = new Set();
  const picked = [];
  const skipped = [];
  let alone = false;
  let candidates = todo;
  if (listed) {
    const ready = new Set(todo.map(t => key(t.id)));
    const inProgress = new Set(active.map(t => key(t.id)));
    for (const id of [...new Set(listed)].filter(id => !ready.has(id))) {
      skipped.push({ id, reason: inProgress.has(id) ? 'In Progress' : 'not ready: a dependency is not done, or it is not To Do' });
    }
    candidates = todo.filter(t => listed.includes(key(t.id)));
  }
  const order = [...candidates].sort((a, b) => (RANK[a.priority] ?? 3) - (RANK[b.priority] ?? 3)
    || (a.ordinal ?? Infinity) - (b.ordinal ?? Infinity) || String(a.id).localeCompare(String(b.id)));
  for (const t of order) {
    const labels = t.labels || [];
    const skip = reason => skipped.push({ id: t.id, reason });
    if (t.isReady === false) { skip('a dependency is not done'); continue; }
    if (labels.includes('epic') || /\bEpic:/.test(t.title || '')) { skip('an epic: build its tickets'); continue; }
    if (parked(t)) { skip('parked'); continue; }
    if (labels.includes('stop-contract-push')) { skip('changes the contract: build-feature does not push the contract'); continue; }
    if (night && labels.includes('P4')) { skip('P4: not for an unattended night'); continue; }
    if (night && labels.includes('manual')) { skip('manual: needs a person'); continue; }
    const stops = labels.filter(l => /^stop-/.test(l));
    const unapproved = night ? (judge ? judge.unapproved(key(t.id), stops) : stops) : [];
    if (night && unapproved.length) { skip(`stop-unapproved: ${unapproved.join(', ')} has no current owner approval`); continue; }
    if (picked.length >= max || alone) { skip('enough runs picked'); continue; }
    const mine = components(t);
    if (!mine.length) {
      if (picked.length) { skip('no component reference: runs only alone'); continue; }
      alone = true;
    }
    const held = busyFor(t);
    const clash = mine.filter(c => held.has(c) || taken.has(c));
    if (clash.length) { skip(`component taken: ${clash.join(', ')}`); continue; }
    mine.forEach(c => taken.add(c));
    picked.push({ id: t.id, title: t.title, components: mine, stop: stops });
  }
  return { picked, skipped, busy: [...busy], night };
}

// The slots: each live run's phase, the tickets whose components a post-merge run released, and the room left.
function slots(runs, active, cap) {
  const parkedIds = new Set(active.filter(parked).map(t => key(t.id)));
  const phased = runs.map(r => ({ run: r.run, task: r.task,
    phase: r.task && parkedIds.has(r.task) ? 'parked' : r.merged ? 'post-merge' : 'pre-merge' }));
  const pre = phased.filter(r => r.phase === 'pre-merge');
  const held = new Set(pre.map(r => r.task));
  const released = new Set(phased.filter(r => r.phase === 'post-merge' && r.task && !held.has(r.task)).map(r => r.task));
  const room = Math.max(0, Math.min(cap - pre.length, CEILING - phased.length));
  return { runs: phased, released, room };
}

function main(argv) {
  let max = null;
  let cap = null;
  let file = null;
  let night = false;
  const usage = msg => {
    if (msg) console.error(`pick-tickets: ${msg}`);
    console.error('usage: node pick-tickets.js [--max <1 to 3> | --cap <1 to 3>] [--list <file>] [--night]');
    process.exitCode = 2;
  };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--max') max = Number(argv[++i]);
    else if (argv[i] === '--cap') cap = Number(argv[++i]);
    else if (argv[i] === '--list') { file = argv[++i]; night = true; }
    else if (argv[i] === '--night') night = true;
    else return usage(`unknown argument: ${argv[i]}`);
  }
  if (max !== null && cap !== null) return usage('--max and --cap do not go together');
  const n = cap !== null ? cap : max !== null ? max : 2;
  if (!Number.isInteger(n) || n < 1 || n > 3) return usage();
  if (file !== null && !file) return usage('--list needs a file');
  let listed = null;
  if (file) {
    try { listed = readList(file); } catch (e) { return usage(`cannot read the list ${file}: ${e.message}`); }
  }
  let result;
  try {
    const todo = list('To Do', 'PICK_TODO_JSON', ['--ready']);
    const active = withDependencies(list('In Progress', 'PICK_ACTIVE_JSON', []));
    const judge = night ? stopJudge(process.env.PICK_NOW ? Date.parse(process.env.PICK_NOW) : Date.now()) : null;
    if (cap !== null) {
      let runs;
      try { runs = liveRuns(); } catch (e) { e.what = 'the archon runs'; throw e; }
      const s = slots(runs, active, cap);
      result = { ...pick(todo, active, s.room, { night, listed, judge, released: s.released }),
        cap, ceiling: CEILING, room: s.room, runs: s.runs };
    } else {
      result = pick(todo, active, n, { night, listed, judge });
    }
  } catch (e) {
    console.error(`pick-tickets: cannot read ${e.what || 'the backlog'}: ${e.message}`);
    process.exitCode = 1;
    return;
  }
  if (night) result.skipped.forEach(s => console.error(`pick-tickets: skipped ${s.id}: ${s.reason}`));
  console.log(JSON.stringify(result, null, 2));
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { pick, slots, isComponent };
