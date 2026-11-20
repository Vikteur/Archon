// Skill gate (P2: a script, not a model): every skill a plan step names on its `Test skills:` and `Build skills:`
// lines was loaded by the agent that worked on that step, with the Skill tool.
//   node skill-check.js <artifacts-dir> [<run-id>]
// Loads come from the audit trail the PostToolUse hook writes in the checkout (.apm-audit/sessions/*.jsonl, a
// `"tool":"Skill"` record per load, stamped to the second), plus the skills a subagent's frontmatter preloads when it
// starts: the hook's SKILL_PRELOAD records, or, in a session file that has none (an older hook), the `skills:` of the
// agent's frontmatter now, at its AGENT_START record (a node's own `skills:` is an allow-list, not a preload: its agent
// still calls Skill). A preload of a skill the checkout did not have (`"found":false`) loads nothing. They are matched
// to plan steps by time:
//   - step markers: <artifacts-dir>/steps/next.log, one line `<utc time>\t<step json>` per build-loop iteration; a
//     load belongs to the step and phase of the last line before it (phase tests: Test skills; code: Build skills).
//     Its writer, agent-feature's step-gate.sh, was removed 2026-10-20 (owner decision D19).
//   - build-feature (no next.log): the run's Archon log gives each write-tests and build-step window; the write-tests
//     window in which red/step-<n>.log was last written (or the last one started before it) is step n, and so is
//     every build-step window until the next step's write-tests window. The loop keeps each node's conversation, so a
//     load by the same node in an earlier window counts too. Step n's write-tests windows also run on after its red
//     log's window, until the next step's write-tests window or the first one after a build-step that ran (a
//     node_skipped one does not count): a test-side remedy that does not rewrite the red log counts (TASK-77).
//     The plan node must also have loaded clean-architecture. An included plan block's nodes (`plan.<node>`) are the plan.
// Steps marked `(verify only)` or `(done by the workflow` need no skill; a `(pin only)` step needs only its Test
// skills. A step marked `(folded into step <k>)`, k an earlier checkbox position, was built inside step k's windows (an
// answer to a BLOCKED question folded it): when it has no window of its own, its skills are checked against step k's
// windows; when step k has none either, it still fails. `none` and an empty line need nothing. Writes <artifacts-dir>/skill-check.md and exits 1 on a skill that was
// never loaded, or when there is no audit trail at all. When plan.md has a `BLOCKED:` line, the steps that have no agent
// window are reported once as never built, quoting that line, instead of one "no agent window" per step. A red log may
// carry a suffix (red/step-<n>-<part>.log, a resumed write-tests wrote one): it is step n's.
//   node skill-check.js <artifacts-dir> <run-id> --live test|build
// The same check inside the build loop of build-feature, right after one agent: only the step that agent worked on,
// only its side (test: the first open step; build: the step of the newest red/step-<n>.log), with the skills of the
// steps folded into it. It never fails the node:
// it prints {"ok", "n", "side", "missing"} for the loop's `when:` and, on a miss, writes
// <artifacts-dir>/skills-missing.md for the next agent (an ok check removes it only when it is of its own side) and,
// for the build side, opens the step again in the plan, so
// the loop builds it again with the skill loaded. A blocked plan, or a step with no window yet, is left to the gates
// after the loop.
const fs = require('fs');
const path = require('path');
const { findLog } = require('./run-trace.js');
const { missSide } = require('./step-cut.js');

const SLACK_MS = 1000; // the audit stamp has whole seconds
// red/step-<n>.log, or a suffixed red/step-<n>-<part>.log a resumed write-tests may write: group 1 is n
const RED_LOG = /^step-(\d+)(?:-[\w-]+)?\.log$/;

// [{ n, kind: build|pin|verify, fold, test: [], build: [] }]: n is the step's position among the checkbox lines, from 1
// (the number the red/step-<n>.log names use, not the plan's own Step label); fold is the earlier step it was folded
// into, or 0. A skills line starts with its label, after optional indent and a - or * list marker, outside a fenced
// code block (TASK-77, run b1d9506f): prose, BLOCKED and ANSWER lines that quote the label add nothing.
function planSteps(text) {
  const steps = [];
  let fence = ''; // the character of the open code fence, '' outside one
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*- \[[ xX]\]/.test(line)) {
      const kind = /\(verify only\)|\(done by the workflow/.test(line) ? 'verify' : /\(pin only\)/.test(line) ? 'pin' : 'build';
      const n = steps.length + 1;
      const fold = Number((/\(folded into step (\d+)\)/i.exec(line) || [])[1] || 0);
      steps.push({ n, kind, fold: fold > 0 && fold < n ? fold : 0, test: [], build: [] });
      continue;
    }
    const fenceMark = (/^\s*(`{3,}|~{3,})/.exec(line) || [])[1];
    if (fenceMark && (!fence || fenceMark[0] === fence)) {
      fence = fence ? '' : fenceMark[0];
      continue;
    }
    const m = /^\s*(?:[-*]\s+)?(Test|Build) skills:\s*(.*)$/.exec(line);
    if (fence || !m || !steps.length) continue;
    const names = m[2].replace(/[`*]/g, '').split(/[\s,]+/).filter(s => /^[a-z][a-z0-9-]*$/.test(s) && s !== 'none');
    steps[steps.length - 1][m[1] === 'Test' ? 'test' : 'build'].push(...names);
  }
  return steps;
}

// The `skills:` of an agent's frontmatter (.claude/agents/<name>.md): a block list or an inline [a, b] list
function agentSkills(root, name) {
  let text;
  try { text = fs.readFileSync(path.join(root, '.claude', 'agents', `${name.replace(/[^\w-]/g, '')}.md`), 'utf8'); } catch { return []; }
  const fm = (/^---\r?\n([\s\S]*?)\r?\n---/.exec(text) || [])[1] || '';
  const inline = /^skills:[ \t]*\[([^\]]*)\]/m.exec(fm);
  if (inline) return inline[1].split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
  const block = /^skills:[ \t]*\r?\n((?:[ \t]*- .*\r?\n?)*)/m.exec(fm);
  return block ? block[1].split(/\r?\n/).map(s => s.replace(/^[ \t]*- /, '').trim().replace(/^["']|["']$/g, '')).filter(Boolean) : [];
}

// [{ t, skill }] from every session file of the audit trail: a Skill tool call, and each skill a subagent's frontmatter
// preloads when it starts: Claude Code puts those in its context with no Skill call, so no TOOL record ever shows them.
// The hook records them (SKILL_PRELOAD); a session file it wrote before it did falls back to the frontmatter.
function auditLoads(root) {
  const dir = path.join(root, '.apm-audit', 'sessions');
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { return null; }
  const loads = [];
  for (const f of files) {
    const records = [];
    for (const l of fs.readFileSync(path.join(dir, f), 'utf8').split('\n')) {
      try { records.push(JSON.parse(l)); } catch { /* a partial or garbled line */ }
    }
    const recorded = records.some(o => o && o.type === 'SKILL_PRELOAD');
    for (const o of records) {
      if (!o) continue;
      if (o.type === 'SKILL_PRELOAD') {
        const t = Date.parse(o.loggedAt || '');
        if (t && o.skill && o.found !== false) loads.push({ t, skill: String(o.skill).replace(/^.*:/, '') });
        continue;
      }
      if (o.type === 'AGENT_START' && o.agentName) {
        const t = Date.parse(o.loggedAt || '');
        if (t && !recorded) for (const skill of agentSkills(root, o.agentName)) loads.push({ t, skill: skill.replace(/^.*:/, '') });
        continue;
      }
      if (o.type !== 'TOOL' || o.tool !== 'Skill' || o.ok === false) continue;
      let skill = '';
      try { skill = JSON.parse(o.arg).skill || ''; } catch { skill = (/"skill"\s*:\s*"([\w-]+)"/.exec(o.arg || '') || [])[1] || ''; }
      const t = Date.parse(o.loggedAt || '');
      if (skill && t) loads.push({ t, skill: skill.replace(/^.*:/, '') });
    }
  }
  return loads;
}

// [{ n, side: test|build, from, to }] from the step markers (steps/next.log)
function markerWindows(text) {
  const marks = [];
  for (const l of text.split(/\r?\n/)) {
    const [ts, json] = l.split('\t');
    let o;
    try { o = JSON.parse(json); } catch { continue; }
    const t = Date.parse(ts);
    if (t && o.n) marks.push({ t, n: o.n, side: o.phase === 'tests' ? 'test' : 'build' });
  }
  return marks.map((m, i) => ({ n: m.n, side: m.side, from: m.t, to: i + 1 < marks.length ? marks[i + 1].t : Infinity }));
}

// { plan: [{from, to}], windows: [{ n, side, from, to }] } from the Archon log of build-feature
function logWindows(text, art) {
  const inv = new Map();
  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    const x = o.execution;
    if (!x || !/^node_/.test(o.type)) continue;
    const id = x.invocation?.id;
    if (!id) continue;
    const t = Date.parse(o.ts || '');
    if (!inv.has(id)) inv.set(id, { path: x.path, iter: x.invocation.loopPath?.[0]?.iteration || 0, from: t, to: Infinity, skipped: o.type === 'node_skipped' });
    if (o.type !== 'node_start') inv.get(id).to = t;
  }
  const all = [...inv.values()];
  // An included plan block logs its nodes as plan__<node> (the 2026-10-23 trial's runs); plan.<node> is kept too.
  const plan = all.filter(w => w.path === 'plan' || /^plan(\.|__)/.test(w.path));
  const reds = [];
  try {
    for (const f of fs.readdirSync(path.join(art, 'red'))) {
      const m = RED_LOG.exec(f);
      if (m) reds.push({ n: Number(m[1]), t: fs.statSync(path.join(art, 'red', f)).mtimeMs });
    }
  } catch { /* no red logs: no step was built */ }
  // A step's red log belongs to the write-tests window it was written in; one written after that window ended (the
  // build-step ran the tests again into it) belongs to the last write-tests window that started before it. A step with
  // several red logs (a resumed run wrote another) belongs to the latest of their windows.
  const writes = all.filter(w => w.path === 'implement.write-tests').sort((a, b) => a.from - b.from);
  const builds = all.filter(w => w.path === 'implement.build-step');
  const latest = new Map();
  for (const r of reds) {
    const w = writes.find(w => within(r.t, w)) || writes.filter(w => w.from <= r.t + SLACK_MS).pop();
    if (w && !(latest.get(r.n) >= w.from)) latest.set(r.n, w.from);
  }
  const owned = [...latest].map(([n, from]) => ({ n, from }));
  // By time, not by iteration: the loop keeps each node's conversation between iterations (no fresh_context), so a
  // skill the node loaded in an earlier window is still in its context and counts for the step too; and a resumed
  // run numbers its iterations from 1 again. Step n's build-step windows run until the write-tests window of the next
  // step began, so an iteration that built step n again (its build-step stopped before the step was done) counts.
  const windows = [];
  for (const o of owned) {
    const until = Math.min(...owned.filter(x => x.from > o.from).map(x => x.from), Infinity);
    // Step n's write-tests windows run on after its red log's window (a test-side remedy that does not rewrite the red
    // log, TASK-77, run 3bb0bc20), until the first write-tests window after a build-step that ran (a node_skipped one
    // does not count) or the next owned step's write-tests window.
    const ran = Math.min(...builds.filter(b => !b.skipped && b.from > o.from).map(b => b.from), Infinity);
    const testUntil = Math.min(until, ...writes.filter(w => w.from > ran).map(w => w.from), Infinity);
    for (const t of writes.filter(t => t.from < testUntil)) windows.push({ n: o.n, side: 'test', from: t.from, to: t.to });
    for (const b of builds.filter(b => b.from < until)) windows.push({ n: o.n, side: 'build', from: b.from, to: b.to });
  }
  return { plan, windows, reds: new Set(reds.map(r => r.n)) };
}

const within = (t, w) => t >= w.from - SLACK_MS && t <= w.to + SLACK_MS;

// The windows of step s on one side: its own, or, for a folded step that has none, those of the step it was folded into
function stepWindows(windows, s, side) {
  const own = windows.filter(w => w.n === s.n && w.side === side);
  return own.length || !s.fold ? own : windows.filter(w => w.n === s.fold && w.side === side);
}

function check(art, runId, root) {
  const problems = [];
  const planFile = path.join(art, 'plan.md');
  if (!fs.existsSync(planFile)) return { problems: [`no plan at ${planFile}`], rows: [] };
  const planText = fs.readFileSync(planFile, 'utf8');
  const steps = planSteps(planText);
  // A `BLOCKED:` line ends the implement loop early: the steps after it have no agent window because nobody built them.
  const blocked = (/^BLOCKED:.*$/m.exec(planText) || [])[0];
  const loads = auditLoads(root);
  if (!loads) return { problems: [`no audit trail at ${path.join(root, '.apm-audit', 'sessions')} (the PostToolUse audit hook needs jq)`], rows: [] };

  let windows;
  let plan = null;
  let reds = null;
  const markers = path.join(art, 'steps', 'next.log');
  if (fs.existsSync(markers)) windows = markerWindows(fs.readFileSync(markers, 'utf8'));
  else {
    const log = runId && findLog(runId);
    if (!log) return { problems: [`no step markers at ${markers} and no Archon log for run ${runId || '(none given)'}`], rows: [] };
    ({ plan, windows, reds } = logWindows(fs.readFileSync(log, 'utf8'), art));
  }

  const rows = [];
  if (plan) {
    const got = loads.some(l => l.skill === 'clean-architecture' && plan.some(w => within(l.t, w)));
    rows.push(['plan', 'plan', 'clean-architecture', got ? '' : 'clean-architecture']);
    if (!got) problems.push('the plan node never loaded clean-architecture');
  }
  const unbuilt = [];
  for (const s of steps) {
    for (const side of ['test', 'build']) {
      const need = s.kind === 'verify' || (s.kind === 'pin' && side === 'build') ? [] : [...new Set(s[side])];
      if (!need.length) continue;
      const ws = stepWindows(windows, s, side);
      const got = new Set(loads.filter(l => ws.some(w => within(l.t, w))).map(l => l.skill));
      const missing = need.filter(k => !got.has(k));
      rows.push([s.fold ? `step ${s.n} (folded into ${s.fold})` : `step ${s.n}`, side, need.join(', '), missing.join(', ')]);
      const why = s.fold ? ` (it is folded into step ${s.fold}, which has none either)`
        : reds && !reds.has(s.n) ? ` (there is no red/step-${s.n}.log, the red run that names its write-tests window)` : '';
      if (!ws.length && blocked) { if (!unbuilt.includes(s.n)) unbuilt.push(s.n); }
      else if (!ws.length) problems.push(`step ${s.n}: no ${side} agent window found to check its ${side === 'test' ? 'Test' : 'Build'} skills against${why}`);
      else if (missing.length) problems.push(`step ${s.n}: the ${side} agent never loaded ${missing.join(', ')}`);
    }
  }
  if (unbuilt.length) problems.push(`the run is blocked, so step(s) ${unbuilt.join(', ')} were never built: ${blocked.trim()}`);
  return { problems, rows };
}

function report(art, { problems, rows }) {
  const out = ['# Skill check — the skills each plan step names, and which were never loaded', ''];
  out.push('| Step | Agent | Named | Never loaded |', '|---|---|---|---|');
  for (const [step, side, need, missing] of rows) out.push(`| ${step} | ${side} | ${need} | ${missing || '—'} |`);
  out.push('', problems.length ? `**${problems.length} problem(s):**` : '**Every named skill was loaded.**');
  for (const p of problems) out.push(`- ${p}`);
  fs.mkdirSync(art, { recursive: true });
  fs.writeFileSync(path.join(art, 'skill-check.md'), out.join('\n') + '\n');
}

if (require.main === module && process.argv[4] !== '--live') {
  const [art, runId] = process.argv.slice(2);
  if (!art) { console.error('usage: node skill-check.js <artifacts-dir> [<run-id>]'); process.exit(2); }
  const r = check(path.resolve(art), runId, process.cwd());
  report(path.resolve(art), r);
  for (const p of r.problems) console.error(`SKILLS: ${p}`);
  if (r.problems.length) {
    console.error(`SKILLS: ${r.problems.length} problem(s): load every skill on the step's line with the Skill tool.`);
    process.exit(1);
  }
  console.log('SKILLS: every skill the plan names was loaded by the agent of its step');
}

// The in-loop check of one agent's step: { ok, n, side, missing } (see the header)
function live(art, runId, root, side) {
  const ok = { ok: true, n: 0, side, missing: [] };
  const planFile = path.join(art, 'plan.md');
  if (!fs.existsSync(planFile)) return ok;
  const planText = fs.readFileSync(planFile, 'utf8');
  if (/^BLOCKED:/m.test(planText)) return ok;
  const loads = auditLoads(root);
  const log = runId && findLog(runId);
  if (!loads || !log) return ok;
  const { windows } = logWindows(fs.readFileSync(log, 'utf8'), art);
  const steps = planSteps(planText);
  let n = 0;
  if (side === 'test') {
    const boxes = planText.split(/\r?\n/).filter(l => /^\s*- \[[ xX]\]/.test(l));
    n = boxes.findIndex(l => /^\s*- \[ \]/.test(l)) + 1;
  } else {
    let newest = -1;
    try {
      for (const f of fs.readdirSync(path.join(art, 'red'))) {
        const m = RED_LOG.exec(f);
        const t = m && fs.statSync(path.join(art, 'red', f)).mtimeMs;
        if (m && t > newest) { newest = t; n = Number(m[1]); }
      }
    } catch { /* no red log yet */ }
  }
  const s = steps.find(x => x.n === n);
  if (!s || s.kind === 'verify' || (s.kind === 'pin' && side === 'build')) return { ...ok, n };
  // The steps folded into this one are built in its windows, so their skills count here too
  const need = [...new Set([...s[side], ...steps.filter(x => x.fold === n && x.kind !== 'verify' && !(x.kind === 'pin' && side === 'build')).flatMap(x => x[side])])];
  const ws = stepWindows(windows, s, side);
  if (!need.length || !ws.length) return { ...ok, n };
  const got = new Set(loads.filter(l => ws.some(w => within(l.t, w))).map(l => l.skill));
  const missing = need.filter(k => !got.has(k));
  return { ok: !missing.length, n, side, missing };
}

// A miss: tell the next agent which skills to load, and open a built step again so the loop builds it once more
function remedy(art, r) {
  const file = path.join(art, 'skills-missing.md');
  // a pass removes a note of its own side only: a build-side miss outlives the test-side check before the build agent
  if (r.ok) { if (['', r.side].includes(missSide(file))) fs.rmSync(file, { force: true }); return; }
  fs.writeFileSync(file, [`# Skills missing — step ${r.n}`, '',
    `${r.side === 'test' ? 'Test' : 'Build'} skills: ${r.missing.join(', ')}`, '',
    `The ${r.side} agent of step ${r.n} never loaded these. Load each with the Skill tool, check the step's ` +
    `${r.side === 'test' ? 'tests' : 'code'} against them and fix what they change.`, ''].join('\n'));
  if (r.side !== 'build') return;
  const planFile = path.join(art, 'plan.md');
  let k = 0;
  const text = fs.readFileSync(planFile, 'utf8').replace(/^(\s*- )\[[ xX]\]/gm, (m, lead) => (++k === r.n ? `${lead}[ ]` : m));
  fs.writeFileSync(planFile, text);
}

if (require.main === module && process.argv[4] === '--live') {
  const [art, runId, , side] = process.argv.slice(2);
  const r = live(path.resolve(art), runId, process.cwd(), side === 'build' ? 'build' : 'test');
  remedy(path.resolve(art), r);
  if (!r.ok) console.error(`SKILLS: step ${r.n}: the ${r.side} agent never loaded ${r.missing.join(', ')}: skills-missing.md tells the next agent to load them`);
  console.log(JSON.stringify(r));
  process.exit(0);
}

module.exports = { planSteps, check, live, remedy };
