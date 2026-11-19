// Recovery state and the circuit breaker of failed build-feature runs (P2: a script, not a model; owner decision
// 2026-10-20, D13). A resume overwrites a run's earlier error and resets its start time, so the history of what was
// tried lives here, outside the run, and survives a restart or a compacted session.
//   node recovery-state.js show [<run id>]          print the breaker, or one run's record, as JSON
//   node recovery-state.js record <file|->          append a classify-failure.js decision (one JSON line) to its run's
//                                                   history and update the breaker; prints the new breaker
//   node recovery-state.js result <run id> <text>   set the result of the run's last history entry
//   node recovery-state.js park <run id> <reason>   mark the run parked (rebase-and-resume.sh refuses a parked run)
//   node recovery-state.js half-open                an open breaker allows one canary launch (after main moved and the
//                                                   launch checks pass); a failed canary opens it again
//   node recovery-state.js reset-breaker            close the breaker (the owner's order, or after a fixed cause)
//   node recovery-state.js prune [--days <n>]       delete run records with no entry in the last n days (default 7)
// The breaker opens when one signature fails in 2 different runs within 60 minutes (signatures marked `counts`), at
// once on a signature marked `immediate`, and when main's local CI is red. A failure while it is half-open opens it
// again; a clean run end while half-open closes it.
// Files, in $RECOVERY_DIR (default: recovery/ beside the main checkout): runs/<run id>.json
// {history: [{at, signature, action, step, attempt, change_token, result}], parked, parked_reason} and breaker.json
// {state: closed|open|half_open, signature, runs: [{run, signature, at}], tripped_at, reason}. Writes take a mkdir lock
// (taken over when its pid is gone or it is older than 60 s) and go to a temp file first, then rename. A corrupt file
// is read as empty, with a warning on stderr; it never crashes a caller.
// Exit 0: done. Exit 1: the state cannot be written. Exit 2: usage.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const WINDOW_MS = 60 * 60 * 1000;
const EMPTY_BREAKER = { state: 'closed', signature: null, runs: [], tripped_at: null, reason: null };

function dir() {
  if (process.env.RECOVERY_DIR) return process.env.RECOVERY_DIR;
  const out = execFileSync('git', ['worktree', 'list', '--porcelain'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const main = (out.match(/^worktree (.+)$/m) || [])[1];
  if (!main) throw new Error('not in a git checkout; set RECOVERY_DIR');
  return path.join(path.dirname(main), 'recovery');
}

function readJson(file, fallback) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return structuredClone(fallback); }
  try { return JSON.parse(text); } catch {
    process.stderr.write(`recovery-state: ${path.basename(file)} is not valid JSON; read as empty\n`);
    return structuredClone(fallback);
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };

function withLock(base, fn) {
  fs.mkdirSync(base, { recursive: true });
  const lock = path.join(base, '.lock');
  for (let i = 0; ; i++) {
    try { fs.mkdirSync(lock); fs.writeFileSync(path.join(lock, 'pid'), String(process.pid)); break; } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (i > 200) throw new Error('the recovery state is locked by another writer');
      let pid = 0, age = 0;
      try { pid = Number(fs.readFileSync(path.join(lock, 'pid'), 'utf8')); } catch { /* being written */ }
      try { age = Date.now() - fs.statSync(lock).mtimeMs; } catch { continue; }
      if ((pid && !alive(pid)) || age > 60000) { fs.rmSync(lock, { recursive: true, force: true }); continue; }
      sleep(50);
    }
  }
  try { return fn(); } finally { fs.rmSync(lock, { recursive: true, force: true }); }
}

const runFile = (base, run) => path.join(base, 'runs', `${run}.json`);
const breakerFile = base => path.join(base, 'breaker.json');
const loadRun = (base, run) => ({ history: [], parked: false, parked_reason: null, ...readJson(runFile(base, run), {}) });
const loadBreaker = base => ({ ...EMPTY_BREAKER, ...readJson(breakerFile(base), EMPTY_BREAKER) });

// The breaker after one more failure of `signature` in `run` at `now`: whether it trips, and why. Pure, so the
// classifier can ask before anything is written.
function afterFailure(breaker, { run, signature, mode, mainRed, now }) {
  const t = Date.parse(now);
  const recent = (breaker.runs || []).filter(r => t - Date.parse(r.at) < WINDOW_MS);
  const runs = mode === 'counts' ? [...recent.filter(r => !(r.run === run && r.signature === signature)), { run, signature, at: now }] : recent;
  const same = new Set(runs.filter(r => r.signature === signature).map(r => r.run));
  let reason = null;
  if (mode === 'immediate') reason = `${signature} opens the breaker at once`;
  else if (mode === 'counts' && same.size >= 2) reason = `${signature} failed in ${same.size} runs within 60 min`;
  else if (mainRed) reason = 'main is red';
  else if (breaker.state === 'half_open' && mode !== 'exempt') reason = `the canary failed (${signature})`;
  return { runs, reason };
}

function record(base, decision) {
  if (!decision || !decision.run || !decision.signature) throw new Error('record needs a classify-failure.js decision');
  const now = decision.at || new Date().toISOString();
  return withLock(base, () => {
    const r = loadRun(base, decision.run);
    r.history.push({ at: now, signature: decision.signature, action: decision.action, step: decision.step ?? null,
      attempt: decision.attempt ?? null, change_token: decision.change_token ?? null, result: null });
    writeJson(runFile(base, decision.run), r);

    const b = loadBreaker(base);
    if (decision.action === 'none') {
      if (b.state === 'half_open' && decision.signature === 'S19') Object.assign(b, { ...EMPTY_BREAKER, runs: b.runs });
    } else {
      const { runs, reason } = afterFailure(b, { run: decision.run, signature: decision.signature,
        mode: decision.breaker || 'exempt', mainRed: decision.main_red === true, now });
      b.runs = runs;
      if (reason && b.state !== 'open') Object.assign(b, { state: 'open', signature: decision.signature, tripped_at: now, reason });
    }
    writeJson(breakerFile(base), b);
    return b;
  });
}

function main(argv) {
  const [cmd, ...args] = argv;
  const usage = msg => { process.stderr.write(`recovery-state: ${msg}\nusage: recovery-state.js show [<run>] | record <file|-> | ` +
    'result <run> <text> | park <run> <reason> | half-open | reset-breaker | prune [--days <n>]\n'); process.exit(2); };
  const base = dir();
  const out = v => process.stdout.write(JSON.stringify(v) + '\n');
  switch (cmd) {
    case 'show':
      if (args.length > 1) usage('show takes at most one run id');
      return out(args[0] ? loadRun(base, args[0]) : loadBreaker(base));
    case 'record': {
      if (args.length !== 1) usage('record needs a file, or - for stdin');
      const text = fs.readFileSync(args[0] === '-' ? 0 : args[0], 'utf8').trim().split('\n').pop();
      let decision;
      try { decision = JSON.parse(text); } catch { usage('record needs one JSON line from classify-failure.js'); }
      return out(record(base, decision));
    }
    case 'result':
    case 'park':
      if (args.length < 2) usage(`${cmd} needs <run id> <text>`);
      return withLock(base, () => {
        const r = loadRun(base, args[0]);
        const text = args.slice(1).join(' ');
        if (cmd === 'park') Object.assign(r, { parked: true, parked_reason: text });
        else if (r.history.length) r.history[r.history.length - 1].result = text;
        else throw new Error(`run ${args[0]} has no history to set a result on`);
        writeJson(runFile(base, args[0]), r);
        out(r);
      });
    case 'half-open':
      return withLock(base, () => {
        const b = loadBreaker(base);
        if (b.state !== 'open') { process.stderr.write(`recovery-state: the breaker is ${b.state}, not open\n`); return out(b); }
        b.state = 'half_open';
        writeJson(breakerFile(base), b);
        out(b);
      });
    case 'reset-breaker':
      return withLock(base, () => { const b = { ...EMPTY_BREAKER }; writeJson(breakerFile(base), b); out(b); });
    case 'prune': {
      const days = args[0] === '--days' ? Number(args[1]) : 7;
      if (!(days > 0)) usage('--days needs a positive number');
      const cut = Date.now() - days * 86400000;
      const removed = [];
      withLock(base, () => {
        let files = [];
        try { files = fs.readdirSync(path.join(base, 'runs')).filter(f => f.endsWith('.json')); } catch { /* none yet */ }
        for (const f of files) {
          const r = readJson(path.join(base, 'runs', f), { history: [] });
          const last = Math.max(0, ...(r.history || []).map(h => Date.parse(h.at) || 0));
          if (last < cut) { fs.rmSync(path.join(base, 'runs', f)); removed.push(f.replace(/\.json$/, '')); }
        }
      });
      return out({ removed });
    }
    default:
      usage(cmd ? `unknown command ${cmd}` : 'a command is required');
  }
}

module.exports = { dir, loadRun, loadBreaker, afterFailure, record };

if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (e) { process.stderr.write(`recovery-state: ${e.message}\n`); process.exit(1); }
}
