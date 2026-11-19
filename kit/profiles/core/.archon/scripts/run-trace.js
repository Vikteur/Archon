// Trace of one Archon run (P2: a script, not a model): which skills, templates, scripts, code-maps, Gradle tasks and
// commands each node used, written to $ARTIFACTS_DIR/trace.md so it shows in the run's ARTIFACTS tab.
//   node run-trace.js --start <run-id> <artifacts-dir>    detach a follower and return at once (the ticket node does this)
//   node run-trace.js --follow <run-id> <artifacts-dir>   rewrite trace.md while the run's log grows; exit when it ends
//   node run-trace.js <run-id> <artifacts-dir>            write trace.md once
// Reads the run's log from $ARCHON_HOME/workspaces/<owner>/<repo>/logs/<run-id>.jsonl (ARCHON_HOME defaults to
// ~/.archon). The follower stops on workflow_complete, 30 minutes after workflow_error with no resume, or after 3 hours
// with no new log line. A Bash command segment that starts with an interpreter or a script path counts as running the
// script; any other mention counts as reading it.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const HOME = process.env.ARCHON_HOME || path.join(os.homedir(), '.archon');
const POLL_MS = Number(process.env.TRACE_POLL_MS || 20000);
const AFTER_ERROR_MS = Number(process.env.TRACE_AFTER_ERROR_MS || 30 * 60000);
const IDLE_MS = Number(process.env.TRACE_IDLE_MS || 3 * 3600000);

const RULES = [
  [/\bscaffold\.sh\s+(?:--test\s+)?["']?([\w/.-]+)/g, m => ['template', m[1]]],
  [/(?:Moustache scripts|scaffold-templates)\/([\w/-]+)\.mustache/g, m => ['template read', m[1]]],
  [/\.claude\/skills\/([\w-]+)\/scripts\/([\w.-]+)/g, m => ['skill script', `${m[1]}/${m[2]}`]],
  [/\.claude\/skills\/([\w-]+)\/SKILL\.md/g, m => ['skill read', m[1]]],
  [/\.archon\/scripts\/([\w./-]+\.(?:sh|js|mjs))/g, m => ['archon script', m[1]]],
  [/\.claude\/scripts\/([\w./-]+\.(?:sh|js|mjs))/g, m => ['claude script', m[1]]],
  [/(?<![\w./])scripts\/(?!scaffold\.sh)([\w./-]+\.(?:sh|js|mjs))/g, m => ['repo script', m[1]]],
  [/docs\/code-maps\/([\w-]+)\.md/g, m => ['code-map', m[1]]],
  [/\.\/gradlew\s+((?:[:\w-]+\s*)+)/g, m => ['gradle', m[1].trim().split(/\s+/).filter(t => /^[:a-zA-Z]/.test(t)).join(' ')]],
  [/\b(git|gh|backlog|groma)\s+([a-z][\w-]*)/g, m => ['cli', `${m[1]} ${m[2]}`]],
];
const ORDER = ['skill', 'skill read', 'template', 'template read', 'skill script', 'archon script', 'claude script', 'repo script',
  'skill script (read)', 'archon script (read)', 'claude script (read)', 'repo script (read)', 'code-map', 'gradle', 'cli', 'wrote'];

// { workflow, end: 'complete' | 'error' | '', md }
function trace(text) {
  const nodes = new Map();
  let t0 = null;
  let workflow = '';
  let end = '';
  const node = step => {
    if (!nodes.has(step)) nodes.set(step, { start: null, kind: '', uses: new Map() });
    return nodes.get(step);
  };
  const use = (step, kind, what) => {
    const k = `${kind}\t${what.replace(/\\/g, '/')}`;
    const u = node(step).uses;
    u.set(k, (u.get(k) || 0) + 1);
  };

  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    const ts = Date.parse(o.ts || o.event?.observedAt || '');
    if (t0 === null && ts) t0 = ts;
    if (o.type === 'workflow_start') { workflow = o.workflow_name || ''; continue; }
    if (o.type === 'workflow_complete') { end = 'complete'; continue; }
    if (o.type === 'workflow_error') { end = 'error'; continue; }
    if (o.type === 'workflow_resume') { end = ''; continue; }
    if (o.type === 'node_start') {
      const n = node(o.step);
      n.start = ts;
      n.kind = o.execution?.node?.kind || '';
      continue;
    }
    const e = o.event;
    if (o.type !== 'provider_event' || !e || e.type !== 'tool_call') continue;
    const input = e.rawInput || {};
    if (e.name === 'Skill') { use(o.step, 'skill', input.skill || e.title || '?'); continue; }
    // A write counts only as `wrote`: the scripts and tasks named in its content are text, not runs or reads.
    if (['Write', 'Edit', 'MultiEdit'].includes(e.name)) {
      use(o.step, 'wrote', String(input.file_path || '').replace(/\\/g, '/').replace(/^.*?(worktrees\/[^/]+|runs\/[^/]+)\//, ''));
      continue;
    }
    const cmd = (e.name === 'Bash' ? input.command || e.title || '' : JSON.stringify(input)).replace(/\\\\/g, '/').replace(/\\/g, '/');
    const segments = e.name === 'Bash' ? cmd.split(/;|&&|\|\||\||\n/) : [cmd];
    for (const seg of segments) {
      const s = seg.trim().replace(/^(?:[A-Z_]+=\S+\s+)+/, '');
      const runs = e.name === 'Bash' && /^(?:bash|sh|node|\.\/|\.?\.?\/?[\w.-]*\/)[^\s]*/.test(s) && !/^(?:cat|sed|grep|head|tail|ls)\b/.test(s);
      for (const [re, f] of RULES) {
        for (const m of s.matchAll(re)) {
          const [kind, what] = f(m);
          use(o.step, /script$/.test(kind) && !runs ? `${kind} (read)` : kind, what);
        }
      }
    }
  }

  const out = [];
  for (const [step, n] of nodes) {
    const at = n.start && t0 ? `+${Math.round((n.start - t0) / 60000)}m` : '';
    out.push('', `== ${step} ${n.kind === 'exec' ? '(script node) ' : ''}${at}`);
    const rows = [...n.uses].map(([k, c]) => [...k.split('\t'), c])
      .sort((a, b) => ORDER.indexOf(a[0]) - ORDER.indexOf(b[0]) || a[1].localeCompare(b[1]));
    if (!rows.length) out.push('   (no skills, scripts or templates)');
    for (const [kind, what, c] of rows) out.push(`   ${kind.padEnd(20)} ${what}${c > 1 ? `  ×${c}` : ''}`);
  }
  const state = end === 'complete' ? 'finished' : end === 'error' ? 'failed' : 'running';
  const at = new Date().toLocaleTimeString('nl-BE', { hour: '2-digit', minute: '2-digit' });
  const md = `# Trace — skills, templates and scripts per node\n\n_${workflow || 'workflow'} · ${state} · updated ${at}_\n\n\`\`\`${out.join('\n')}\n\`\`\`\n`;
  return { workflow, end, md };
}

function findLog(runId) {
  const ws = path.join(HOME, 'workspaces');
  let owners = [];
  try { owners = fs.readdirSync(ws); } catch { return null; }
  for (const owner of owners) {
    let repos = [];
    try { repos = fs.readdirSync(path.join(ws, owner)); } catch { continue; }
    for (const repo of repos) {
      const f = path.join(ws, owner, repo, 'logs', `${runId}.jsonl`);
      if (fs.existsSync(f)) return f;
    }
  }
  return null;
}

function write(log, dir) {
  const r = trace(fs.readFileSync(log, 'utf8'));
  const target = path.join(dir, 'trace.md');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(`${target}.tmp`, r.md);
  fs.renameSync(`${target}.tmp`, target);
  return r;
}

function follow(runId, dir) {
  let log = null;
  let size = -1;
  let changed = Date.now();
  let errorAt = 0;
  const tick = () => {
    log = log || findLog(runId);
    if (log) {
      const now = fs.statSync(log).size;
      if (now !== size) {
        size = now;
        changed = Date.now();
        const { end } = write(log, dir);
        if (end === 'complete') return process.exit(0);
        errorAt = end === 'error' ? errorAt || Date.now() : 0;
      }
    }
    if ((errorAt && Date.now() - errorAt > AFTER_ERROR_MS) || Date.now() - changed > IDLE_MS) return process.exit(0);
    setTimeout(tick, POLL_MS);
  };
  tick();
}

module.exports = { findLog };

const [mode, ...rest] = require.main === module ? process.argv.slice(2) : ['--module'];
if (mode === '--module') {
  // required by another script (skill-check.js): only findLog
} else if (mode === '--start' || mode === '--follow') {
  const [runId, dir] = rest;
  if (!runId || !dir) { console.error(`usage: node run-trace.js ${mode} <run-id> <artifacts-dir>`); process.exit(2); }
  if (mode === '--follow') follow(runId, path.resolve(dir));
  else {
    // Detached, from the home directory: the run's worktree can be removed while the follower still runs.
    spawn(process.execPath, [__filename, '--follow', runId, path.resolve(dir)], { cwd: os.homedir(), detached: true, stdio: 'ignore', windowsHide: true }).unref();
  }
} else {
  const [runId, dir] = [mode, ...rest];
  if (!runId || !dir) { console.error('usage: node run-trace.js [--start|--follow] <run-id> <artifacts-dir>'); process.exit(2); }
  const log = findLog(runId);
  if (!log) { console.error(`run-trace: no log for run ${runId} under ${HOME}/workspaces`); process.exit(1); }
  write(log, path.resolve(dir));
}
