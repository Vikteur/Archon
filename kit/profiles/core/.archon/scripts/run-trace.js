// Trace of one Archon run (P2: a script, not a model): which skills, templates, scripts, code-maps, Gradle tasks and
// commands each node used, written to $ARTIFACTS_DIR/trace.md so it shows in the run's ARTIFACTS tab.
//   node run-trace.js --start <run-id> <artifacts-dir>    detach a follower and return at once (the ticket node does this)
//   node run-trace.js --follow <run-id> <artifacts-dir> [<checkout>]   rewrite trace.md while the run's log grows; exit when it ends
//   node run-trace.js <run-id> <artifacts-dir> [<checkout>]            write trace.md once
// Reads the run's log from $ARCHON_HOME/workspaces/<owner>/<repo>/logs/<run-id>.jsonl (ARCHON_HOME defaults to
// ~/.archon). The follower stops on workflow_complete, 30 minutes after workflow_error with no resume, or after 3 hours
// with no new log line. A Bash command segment that starts with an interpreter or a script path counts as running the
// script; any other mention counts as reading it. A Copilot tool name (bash, view, skill, ...) counts as the Claude tool
// .archon/copilot/tools.json maps it to.
// Below the trace: the run's warnings, a script node's stderr line that says it failed (an `|| echo "... failed ..." >&2`
// fallback leaves only that line), a script node that exited non-zero, and the provider's warning codes per node (the
// codes only, never their message); then the Copilot usage per node and the hook trail counts of copilot-usage.js
// (<checkout>/.apm-audit/sessions; --start passes its own working directory). A copied line has every home directory
// cut to ~, every URL to <url> and every e-mail address to <email>, and is capped at 200 characters.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const HOME = process.env.ARCHON_HOME || path.join(os.homedir(), '.archon');
const POLL_MS = Number(process.env.TRACE_POLL_MS || 20000);
const AFTER_ERROR_MS = Number(process.env.TRACE_AFTER_ERROR_MS || 30 * 60000);
const IDLE_MS = Number(process.env.TRACE_IDLE_MS || 3 * 3600000);

// A skill is read under .github/skills (Claude Code) or .github/skills (the Copilot kit's path for the same skill).
const RULES = [
  [/\bscaffold\.sh\s+(?:--test\s+)?["']?([\w/.-]+)/g, m => ['template', m[1]]],
  [/(?:Moustache scripts|scaffold-templates)\/([\w/-]+)\.mustache/g, m => ['template read', m[1]]],
  [/\.(?:claude|github)\/skills\/([\w-]+)\/scripts\/([\w.-]+)/g, m => ['skill script', `${m[1]}/${m[2]}`]],
  [/\.(?:claude|github)\/skills\/([\w-]+)\/SKILL\.md/g, m => ['skill read', m[1]]],
  [/\.archon\/scripts\/([\w./-]+\.(?:sh|js|mjs))/g, m => ['archon script', m[1]]],
  [/\.claude\/scripts\/([\w./-]+\.(?:sh|js|mjs))/g, m => ['claude script', m[1]]],
  [/(?<![\w./])scripts\/(?!scaffold\.sh)([\w./-]+\.(?:sh|js|mjs))/g, m => ['repo script', m[1]]],
  [/docs\/code-maps\/([\w-]+)\.md/g, m => ['code-map', m[1]]],
  [/\.\/gradlew\s+((?:[:\w-]+\s*)+)/g, m => ['gradle', m[1].trim().split(/\s+/).filter(t => /^[:a-zA-Z]/.test(t)).join(' ')]],
  [/\b(git|gh|backlog)\s+([a-z][\w-]*)/g, m => ['cli', `${m[1]} ${m[2]}`]],
];
const ORDER = ['skill', 'skill read', 'template', 'template read', 'skill script', 'archon script', 'claude script', 'repo script',
  'skill script (read)', 'archon script (read)', 'claude script (read)', 'repo script (read)', 'code-map', 'gradle', 'cli', 'wrote'];

// The tools.json map of copilot-audit.js, required at call time (copilot-audit.js requires this file); none: names as is
let toolMap;
function claudeCall(e) {
  if (toolMap === undefined) {
    try { const a = require('./copilot-audit.js'); toolMap = { map: a.loadMap(), call: a.claudeCall }; } catch { toolMap = null; }
  }
  return toolMap ? toolMap.call(e, toolMap.map) : { name: String(e.name || ''), input: e.rawInput || {} };
}

const FAILURE = /\b(?:failed|fails|error|cannot|could not|unable|not found)\b|\bwarn(?:ing)?\b/i;
const HOMES = [/\/home\/[^/\s'"]+/g, /\/Users\/[^/\s'"]+/g, /[A-Za-z]:[\\/]Users[\\/][^\\/\s'"]+/gi];
function clean(line) {
  let s = String(line);
  const home = os.homedir();
  if (home && home.length > 1) s = s.split(home).join('~');
  for (const re of HOMES) s = s.replace(re, '~');
  s = s.replace(/\b[a-z][\w+.-]*:\/\/\S+/gi, '<url>').replace(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, '<email>').trim();
  return s.length > 200 ? `${s.slice(0, 200)}…` : s;
}

// The run's warnings, in log order: [{ step, what }]
function warnings(text) {
  const out = [];
  const codes = new Map();
  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.type === 'exec_output') {
      for (const line of String(o.stderr_tail || '').split('\n')) if (FAILURE.test(line)) out.push({ step: o.step, what: clean(line) });
      if (o.exit_code) out.push({ step: o.step, what: `exit ${Number(o.exit_code)}` });
    } else if (o.type === 'provider_event' && o.event && o.event.type === 'warning') {
      const k = `${o.step}\t${String(o.event.code || 'warning').replace(/[^\w.-]/g, '').slice(0, 64)}`;
      codes.set(k, (codes.get(k) || 0) + 1);
    }
  }
  for (const [k, c] of codes) { const [step, code] = k.split('\t'); out.push({ step, what: `provider warning ${code}${c > 1 ? ` ×${c}` : ''}` }); }
  return out;
}

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
    const { name, input } = claudeCall(e);
    if (name === 'Skill') { use(o.step, 'skill', input.skill || e.title || '?'); continue; }
    // A write counts only as `wrote`: the scripts and tasks named in its content are text, not runs or reads.
    if (['Write', 'Edit', 'MultiEdit'].includes(name)) {
      use(o.step, 'wrote', String(input.file_path || '').replace(/\\/g, '/').replace(/^.*?(worktrees\/[^/]+|runs\/[^/]+)\//, ''));
      continue;
    }
    const cmd = (name === 'Bash' ? input.command || e.title || '' : JSON.stringify(input)).replace(/\\\\/g, '/').replace(/\\/g, '/');
    const segments = name === 'Bash' ? cmd.split(/;|&&|\|\||\||\n/) : [cmd];
    for (const seg of segments) {
      const s = seg.trim().replace(/^(?:[A-Z_]+=\S+\s+)+/, '');
      const runs = name === 'Bash' && /^(?:bash|sh|node|\.\/|\.?\.?\/?[\w.-]*\/)[^\s]*/.test(s) && !/^(?:cat|sed|grep|head|tail|ls)\b/.test(s);
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
  const warn = warnings(text);
  const warnMd = `\n## Warnings\n\n${warn.length ? warn.map(w => `- ${w.step}: ${w.what}`).join('\n') : '_None._'}\n`;
  const md = `# Trace — skills, templates and scripts per node\n\n_${workflow || 'workflow'} · ${state} · updated ${at}_\n\n\`\`\`${out.join('\n')}\n\`\`\`\n${warnMd}`;
  return { workflow, end, md, warnings: warn };
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

// The usage tables of copilot-usage.js ('' when it has none or cannot run: the trace never fails on them)
function usage(text, checkout) {
  try {
    const u = require('./copilot-usage.js');
    const md = u.markdown(u.perNode(text, { auditDir: checkout ? path.join(checkout, '.apm-audit', 'sessions') : null }));
    return md ? `\n${md}` : '';
  } catch (e) {
    return `\n_Copilot usage not read: ${clean(e.message)}_\n`;
  }
}

function write(log, dir, checkout) {
  const text = fs.readFileSync(log, 'utf8');
  const r = trace(text);
  const target = path.join(dir, 'trace.md');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(`${target}.tmp`, r.md + usage(text, checkout));
  fs.renameSync(`${target}.tmp`, target);
  return r;
}

function follow(runId, dir, checkout) {
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
        const { end } = write(log, dir, checkout);
        if (end === 'complete') return process.exit(0);
        errorAt = end === 'error' ? errorAt || Date.now() : 0;
      }
    }
    if ((errorAt && Date.now() - errorAt > AFTER_ERROR_MS) || Date.now() - changed > IDLE_MS) return process.exit(0);
    setTimeout(tick, POLL_MS);
  };
  tick();
}

module.exports = { findLog, trace, warnings, clean };

const [mode, ...rest] = require.main === module ? process.argv.slice(2) : ['--module'];
if (mode === '--module') {
  // required by another script (skill-check.js): only findLog
} else if (mode === '--start' || mode === '--follow') {
  const [runId, dir, checkout] = rest;
  if (!runId || !dir) { console.error(`usage: node run-trace.js ${mode} <run-id> <artifacts-dir> [<checkout>]`); process.exit(2); }
  if (mode === '--follow') follow(runId, path.resolve(dir), checkout ? path.resolve(checkout) : null);
  else {
    // Detached, from the home directory: the run's worktree can be removed while the follower still runs. The checkout
    // it started from is where the hook trail is.
    spawn(process.execPath, [__filename, '--follow', runId, path.resolve(dir), path.resolve(checkout || process.cwd())],
      { cwd: os.homedir(), detached: true, stdio: 'ignore', windowsHide: true }).unref();
  }
} else {
  const [runId, dir, checkout] = [mode, ...rest];
  if (!runId || !dir) { console.error('usage: node run-trace.js [--start|--follow] <run-id> <artifacts-dir> [<checkout>]'); process.exit(2); }
  const log = findLog(runId);
  if (!log) { console.error(`run-trace: no log for run ${runId} under ${HOME}/workspaces`); process.exit(1); }
  write(log, path.resolve(dir), checkout ? path.resolve(checkout) : null);
}
