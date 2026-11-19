// Classify how a build-feature run ended into one failure signature and one action (P2: a script, not a model; owner
// decision 2026-10-20, D13). The delegator, or a supervisor, no longer judges a failure at night: this prints what to
// do, recover-run.sh does the mechanical part, and a person gets every case no script can settle.
//   node classify-failure.js <run id> [--json-file <file>] [--facts-file <file>] [--now <ISO time>]
// The signatures, S01 to S24, are classify-failure.signatures.json beside this script; the first that matches wins,
// and S20 (no known signature) asks a person. Actions: resume | repair | park | ask | none, with `step` naming the
// mechanical work (sync-relaunch, ci-local-post, rebase-and-resume, cleanup-merged, ...).
// Reads the run with `archon workflow get <id> --json --verbose`, then gathers facts: the worktree's head, the
// origin/main tip, the head's .archon/scripts tree, local-ci-status.sh of the head and of main, the pull request's
// state and head on GitHub (open-pr's output names it), whether origin's copy of the branch holds the head, and
// whether blocked.md is among the artifacts. Tests pass --json-file (the run) and
// --facts-file (the facts) instead; a fact that cannot be gathered is null, never a crash.
// Reads (never writes) the recovery state of recovery-state.js:
//   - budget: attempts of one signature and step in one run (S04: 2, at 2 and 10 min after the end; most others 1);
//     a spent budget parks the run and pings now, exit 4;
//   - change token: a hash of the head, the main tip, the scripts tree and the CI state of the head and of main. A
//     resume needs a token that differs from the last attempt's (S04 within its budget excepted); no change parks the
//     run, exit 4;
//   - breaker: open, or opened by this failure (one signature in 2 runs within 60 min, an `immediate` signature, a red
//     main), turns a resume or repair into ask, exit 5. S13 waits for main anyway and is not turned.
// Prints one JSON line: run, ticket, pr, head, status, signature, class, action, step, not_before, wait_for, attempt, budget,
// change_token, changed, breaker, main_red, ping (now | digest | no), reason, evidence. Home paths are redacted.
// Exit 0: a decision. 1: the run cannot be read. 2: usage. 3: unknown signature (S20, ask). 4: budget spent or nothing
// changed since the last attempt (park). 5: breaker open (ask).
// Override: ARCHON, the archon command.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const state = require('./recovery-state.js');

const HERE = __dirname;
const TABLE = JSON.parse(fs.readFileSync(path.join(HERE, 'classify-failure.signatures.json'), 'utf8')).signatures;

function usage(msg) {
  process.stderr.write(`classify-failure: ${msg}\n` +
    'usage: classify-failure.js <run id> [--json-file <file>] [--facts-file <file>] [--now <ISO time>]\n');
  process.exit(2);
}

function parseArgs(argv) {
  const o = { run: null, jsonFile: null, factsFile: null, now: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => argv[++i] ?? usage(`${a} needs a value`);
    if (a === '--json-file') o.jsonFile = val();
    else if (a === '--facts-file') o.factsFile = val();
    else if (a === '--now') o.now = val();
    else if (a.startsWith('-')) usage(`unknown option ${a}`);
    else if (o.run) usage('only one run id');
    else o.run = a;
  }
  if (!o.run && !o.jsonFile) usage('a run id is required');
  if (o.now && Number.isNaN(Date.parse(o.now))) usage('--now needs an ISO time');
  return o;
}

// Never print a home path or a user folder (Linux, macOS or Windows).
const redact = s => String(s)
  .replace(/[A-Za-z]:(\\\\|\\|\/)+Users(\\\\|\\|\/)+[^\\/\s"']+/g, '<home>')
  .replace(/\/(home|Users)\/[^/\s"']+/g, '<home>');

const sh = (cmd, args, opts = {}) => {
  try { return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 60000, ...opts }).trim(); } catch { return null; }
};
const tryJson = s => { try { return JSON.parse(s); } catch { return null; } };

function outputOf(run, id) {
  const n = (run.nodes || []).find(x => x.nodeId === id);
  return n ? n.outputPreview ?? null : null;
}

function gather(run) {
  const f = { head: null, main: null, scripts_tree: null, head_ci: null, main_ci: null, pr: null, pr_state: null,
    pr_head: null, head_pushed: null, blocked: false };
  const openPr = tryJson(outputOf(run, 'open-pr') || '');
  if (openPr && openPr.pr) f.pr = String(openPr.pr);
  const wt = run.working_path && fs.existsSync(run.working_path) ? run.working_path : null;
  const git = (...a) => sh('git', wt ? ['-C', wt, ...a] : a);
  if (wt) {
    f.head = git('rev-parse', 'HEAD');
    f.scripts_tree = git('rev-parse', 'HEAD:.archon/scripts');
    const branch = git('symbolic-ref', '--short', '-q', 'HEAD');
    if (branch && f.head && git('fetch', '-q', 'origin', branch) !== null) {
      const remote = git('rev-parse', `origin/${branch}`);
      f.head_pushed = remote === f.head || git('merge-base', '--is-ancestor', f.head, `origin/${branch}`) !== null;
    }
  }
  git('fetch', '-q', 'origin', 'main');
  f.main = git('rev-parse', 'origin/main');
  const repo = sh('gh', ['repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'], wt ? { cwd: wt } : {});
  const status = sha => repo && sha ? sh('bash', [path.join(HERE, 'local-ci-status.sh'), repo, sha]) : null;
  f.head_ci = status(f.head);
  f.main_ci = status(f.main);
  const pr = f.pr && tryJson(sh('gh', ['pr', 'view', f.pr, '--json', 'state,headRefOid'], wt ? { cwd: wt } : {}) || '');
  if (pr) { f.pr_state = pr.state || null; f.pr_head = pr.headRefOid || null; }
  const art = run.terminal_record && run.terminal_record.artifacts && run.terminal_record.artifacts.root;
  f.blocked = !!(art && fs.existsSync(path.join(art, 'blocked.md')));
  return f;
}

const word = s => (s ? String(s).trim().split(/\s+/)[0] : null);
const redJobs = s => new Set((String(s || '').match(/local-ci\/[\w.-]+=(failure|error)/g) || []).map(j => j.split('=')[0]));

function derive(run, facts) {
  const d = { ...facts };
  d.head_ci_state = word(facts.head_ci);
  d.main_ci_state = word(facts.main_ci);
  const mainRed = redJobs(facts.main_ci);
  d.main_red_overlap = d.main_ci_state === 'red' && [...redJobs(facts.head_ci)].some(j => mainRed.has(j));
  const merged = (run.nodes || []).find(n => n.nodeId === 'merged');
  d.merged = !!(merged && merged.state === 'completed');
  // Where the worktree's head stands against the pull request: its head on GitHub, pushed but GitHub still shows an
  // older one, or not pushed at all.
  d.head_state = !facts.head || !facts.pr_head ? null : facts.head === facts.pr_head ? 'pr-head'
    : facts.head_pushed === true ? 'pushed-stale' : facts.head_pushed === false ? 'unpushed' : null;
  return d;
}

function failedNode(run) {
  const tr = run.terminal_record || {};
  const id = tr.first_failed_node || ((tr.nodes || []).find(n => n.state === 'failed') || {}).node_id || null;
  const n = id && (run.nodes || []).find(x => x.nodeId === id);
  const kind = n && n.execution && n.execution.node ? n.execution.node.kind : (n && n.kind) || null;
  return { id, kind };
}

// The whole error text plus each failed node's own error: an error can be cut at its start, with the verdict at its end.
function errorText(run) {
  const tr = run.terminal_record || {};
  const parts = [run.metadata && run.metadata.error, tr.error,
    ...(tr.nodes || []).filter(n => n.state === 'failed').map(n => n.error),
    ...(run.nodes || []).filter(n => n.state === 'failed').map(n => n.error)];
  return parts.filter(Boolean).join('\n');
}

function holds(when, ctx) {
  const { run, facts, text, failed } = ctx;
  if (when.status && !when.status.includes(run.status)) return false;
  if (when.nodes !== undefined && (run.nodes || []).length !== when.nodes) return false;
  if (when.failed_node && !when.failed_node.includes(failed.id)) return false;
  if (when.failed_node_not && when.failed_node_not.includes(failed.id)) return false;
  if (when.failed_kind && !when.failed_kind.includes(failed.kind)) return false;
  if (when.merged !== undefined && facts.merged !== when.merged) return false;
  if (when.text && !new RegExp(when.text).test(text)) return false;
  if (when.tdd_only) {
    const lines = text.split('\n').map(l => l.slice(l.indexOf('TDD:'))).filter(l => l.startsWith('TDD:'));
    const re = new RegExp(when.tdd_only);
    if (!lines.length || !lines.every(l => re.test(l))) return false;
  }
  if (when.output) {
    const out = outputOf(run, when.output.node);
    if (out === null || !new RegExp(when.output.match).test(out)) return false;
  }
  if (when.facts && !Object.entries(when.facts).every(([k, v]) => facts[k] === v)) return false;
  if (when.seen && !ctx.seen.has(when.seen)) return false;
  if (when.any && !when.any.some(w => holds(w, ctx))) return false;
  return true;
}

function evidence(sig, text, run) {
  if (sig.when.output) return redact(`${sig.when.output.node}: ${outputOf(run, sig.when.output.node)}`).slice(0, 240);
  const pats = [sig.when.text, ...(sig.when.any || []).map(w => w.text)].filter(Boolean);
  const lines = text.split('\n');
  for (const p of pats) {
    const re = new RegExp(p.split('[\\s\\S]*')[0]);
    const line = lines.find(l => re.test(l));
    if (line) return redact(line.trim()).slice(0, 240);
  }
  return redact((lines.find(l => l.trim()) || '').trim()).slice(0, 240);
}

const ticketOf = run => {
  const t = tryJson(outputOf(run, 'ticket') || '');
  if (t && t.task) return t.task;
  const m = String(run.user_message || '').match(/\bTASK-\d+(\.\d+)*/);
  return m ? m[0] : null;
};

function classify(run, rawFacts, now, base) {
  const facts = derive(run, rawFacts);
  const text = errorText(run);
  const failed = failedNode(run);
  const record = base ? state.loadRun(base, run.id) : { history: [] };
  const breaker = base ? state.loadBreaker(base) : { state: 'closed', runs: [] };
  const ctx = { run, facts, text, failed, seen: new Set(record.history.map(h => h.signature)) };
  const sig = TABLE.find(s => holds(s.when, ctx));
  let { action, step, reason } = sig;
  for (const v of sig.variants || []) {
    if (Object.entries(v.if).every(([k, val]) => facts[k] === val)) { ({ action, step } = v); reason = v.reason || reason; break; }
  }

  const token = crypto.createHash('sha256')
    .update([facts.head, facts.main, facts.scripts_tree, facts.head_ci_state, facts.main_ci_state].map(x => x ?? '').join('\n'))
    .digest('hex').slice(0, 16);
  const mine = record.history.filter(h => h.signature === sig.id && h.step === step);
  const attempt = mine.length + 1;
  const last = record.history.filter(h => h.signature === sig.id).pop();
  const changed = !last || last.change_token !== token;
  const mainRed = facts.main_ci_state === 'red';

  const out = {
    run: run.id, ticket: ticketOf(run), pr: facts.pr ?? null, head: facts.head ?? null, status: run.status,
    signature: sig.id, class: sig.class, action, step, not_before: null, wait_for: null,
    attempt, budget: sig.budget, change_token: token, changed, breaker: sig.breaker, main_red: mainRed,
    ping: sig.ping, reason, evidence: evidence(sig, text, run), at: now,
  };
  let exit = sig.id === 'S20' ? 3 : 0;

  if (step === 'wait-main-green') out.wait_for = 'main-green';
  if (step === 'wait-local-ci') out.wait_for = 'local-ci';
  if (step === 'wait-main-green' && !sig.quiet_wait && Date.parse(now) - Date.parse(run.completed_at || now) > 30 * 60000) {
    out.ping = 'now'; out.reason += '; main has stayed red over 30 min since the run failed';
  }

  const mechanical = action === 'resume' || action === 'repair';
  if (mechanical && !out.wait_for && sig.budget !== null && attempt > sig.budget) {
    Object.assign(out, { action: 'park', step: 'park', ping: 'now',
      reason: `${sig.id} budget spent (${sig.budget} ${step} attempt(s)); ${reason}` });
    exit = 4;
  } else if (action === 'resume' && !changed && sig.id !== 'S04') {
    Object.assign(out, { action: 'park', step: 'park', ping: 'now',
      reason: `${sig.id} again with nothing changed since the last attempt (same head, main, scripts and main CI)` });
    exit = 4;
  } else if (sig.breaker !== 'exempt') {
    const trip = state.afterFailure(breaker, { run: run.id, signature: sig.id, mode: sig.breaker, mainRed, now });
    const open = breaker.state === 'open' ? breaker.reason || 'the breaker is open' : trip.reason;
    if (open && (mechanical || sig.breaker === 'immediate')) {
      Object.assign(out, { action: 'ask', ping: 'now', reason: `breaker: ${open}; ${reason}` });
      exit = 5;
    } else if (open) {
      Object.assign(out, { ping: 'now', reason: `${reason}; breaker: ${open}` });
    }
  }

  if (out.action === 'resume' && Array.isArray(sig.delays)) {
    const delay = sig.delays[Math.min(attempt, sig.delays.length) - 1] || 0;
    const end = Date.parse(run.completed_at || now);
    const at = new Date(end + delay * 1000);
    if (at > new Date(now)) out.not_before = at.toISOString().replace(/\.\d{3}Z$/, 'Z');
  }
  return { out, exit };
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  let run;
  try {
    run = JSON.parse(o.jsonFile ? fs.readFileSync(o.jsonFile, 'utf8')
      : execFileSync(process.env.ARCHON || 'archon', ['workflow', 'get', o.run, '--json', '--verbose'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 << 20 }));
  } catch (e) {
    process.stderr.write(`classify-failure: cannot read run ${o.run || o.jsonFile}: ${redact(e.message).split('\n')[0]}\n`);
    process.exit(1);
  }
  if (!run || !run.id || !run.status) { process.stderr.write('classify-failure: the run record has no id or status\n'); process.exit(1); }
  const facts = o.factsFile ? JSON.parse(fs.readFileSync(o.factsFile, 'utf8')) : gather(run);
  let base = null;
  try { base = state.dir(); } catch (e) { process.stderr.write(`classify-failure: no recovery state (${e.message}); budgets and breaker unchecked\n`); }
  const now = o.now || new Date().toISOString();
  const { out, exit } = classify(run, facts, now, base);
  process.stdout.write(redact(JSON.stringify(out)) + '\n');
  process.exit(exit);
}

module.exports = { classify, redact };
if (require.main === module) main();
