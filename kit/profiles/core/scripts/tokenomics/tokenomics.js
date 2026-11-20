// Token and cost reports (TASK-41, P2): reads the Claude Code transcripts and the Archon run history, keeps one ledger
// record per agent and local day, and renders the daily, per-ticket and per-agent reports from the whole ledger.
//   node tokenomics.js update [--projects <dir>] [--archon-runs <file.json> | --archon-db <path>] [--out <dir>]
//                             [--home <dir>] [--repo <dir>] [--pricing <file>] [--incremental]
//     scans the transcripts, merges them into <out>/ledger and rewrites every report; prints one JSON line.
//       --incremental  only the transcripts written on or after the ledger's latest day (by mtime, local day), with a
//                      sub-agent's session transcript, and only the daily reports of those days and the ticket reports
//                      of the tickets with a record on them; agents.md as always; no report is removed. With no ledger
//                      yet it is a full update (owner decision 2026-10-23); a full update is the
//                      command without it.
//       --projects     Claude Code transcripts            (default <home>/.claude/projects, env TOKENOMICS_PROJECTS)
//       --archon-runs  normalized Archon runs, see below  (env TOKENOMICS_ARCHON_RUNS)
//       --archon-db    Archon's SQLite file, read-only    (default <home>/.archon/archon.db, env TOKENOMICS_ARCHON_DB)
//       --out          where the reports and the ledger live (default <repo>/docs/tokenomics)
//       --home         the home directory to hide         (default the real one, env TOKENOMICS_HOME)
//       --repo         the repo of the reports; the ticket titles come from its backlog/
//                                                                              (default the repo of this script)
//       --pricing      rates in USD per million tokens    (default <out>/pricing.json)
//       --artifacts    Archon's workspaces, for each run's mcp-status.txt
//                                       (default <home>/.archon/workspaces, env TOKENOMICS_ARCHON_ARTIFACTS)
// The normalized Archon runs are {runs:[{id, workflowName, userMessage, workingPath, branch?, startedAt,
// nodes:[{nodeId, sessionPreview, model, sessionOrigin, status, costUsd, numTurns, durationMs}]}]}; the database
// loader produces the same shape. <out>/attribution.json holds overrides {"<agent|run|session id>": "TASK-x"}.
// Nothing newer than Node 20 is used; node:sqlite is loaded only when the database is read, and skipped with a warning
// when it is missing. No prompt, message, tool result, command line, e-mail or secret is stored (see the README).
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

// The contract MCP server's name: contract.server_name of .archon/kit.yaml (kit-config.js), default @@KIT_CONTRACT_SERVER_NAME@@
const SERVER = (() => {
  try { return require('../../.archon/scripts/kit-config.js').kitGet('contract.server_name', '@@KIT_CONTRACT_SERVER_NAME@@'); } catch { return '@@KIT_CONTRACT_SERVER_NAME@@'; }
})();
const { StringDecoder } = require('string_decoder');

const SCHEMA = 1;
const COORD = 'coordination';
const SYNTHETIC = '<synthetic>';
const READ_TOOLS = new Set(['Read', 'NotebookRead']);
const EDIT_TOOLS = new Set(['Edit', 'MultiEdit', 'Write', 'NotebookEdit']);
const FILE_CAP = 30;
const LIST_CAP = 40;
const TOP_AGENTS = 15;
const RULES = ['override', 'archon-request', 'archon-branch', 'label', 'prompt-share', 'parent-archon', 'coordination'];

// ---------- small helpers ----------
const warn = msg => process.stderr.write('tokenomics: ' + msg + '\n');
const die = msg => { warn(msg); process.exit(1); };
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const fwd = p => String(p).replace(/\\/g, '/');
const norm = p => fwd(p).replace(/\/+/g, '/').replace(/\/+$/, '');
const num = v => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0);
const str = v => (typeof v === 'string' ? v : '');
const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const isDir = p => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const isFile = p => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const listDir = p => { try { return fs.readdirSync(p); } catch { return []; } };
const readText = f => { try { return fs.readFileSync(f, 'utf8').replace(/\r/g, ''); } catch { return null; } };
const readJson = f => { const s = readText(f); if (s === null || !s.trim()) return null; try { return JSON.parse(s); } catch { return null; } };

// Sorted keys and two-space indent: the same data always gives the same bytes.
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v).sort()) if (v[k] !== undefined) o[k] = sortKeys(v[k]);
    return o;
  }
  return v;
}
const stable = v => JSON.stringify(sortKeys(v), null, 2) + '\n';

// Calls fn(line) for every line of a (possibly very large) file without holding the file in memory.
function eachLine(file, fn) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.allocUnsafe(1 << 20);
    const dec = new StringDecoder('utf8');
    let rest = '';
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (n === 0) break;
      const parts = (rest + dec.write(buf.subarray(0, n))).split('\n');
      rest = parts.pop();
      for (const l of parts) fn(l.charCodeAt(l.length - 1) === 13 ? l.slice(0, -1) : l);
    }
    rest += dec.end();
    if (rest) fn(rest.charCodeAt(rest.length - 1) === 13 ? rest.slice(0, -1) : rest);
  } finally { fs.closeSync(fd); }
}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) die(`unexpected argument: ${a}`);
    if (a === '--incremental') { o.incremental = true; continue; }
    const eq = a.indexOf('=');
    if (eq > 0) { o[a.slice(2, eq)] = a.slice(eq + 1); continue; }
    if (i + 1 >= argv.length) die(`${a} needs a value`);
    o[a.slice(2)] = argv[++i];
  }
  return o;
}

// ---------- tickets ----------
const TASK_G = /(?<![A-Za-z0-9])TASK-(\d+(?:\.\d+)?)/gi;
const taskIds = text => { const r = []; for (const m of String(text).matchAll(TASK_G)) r.push('TASK-' + m[1]); return r; };
const firstTask = text => { const t = taskIds(text); return t.length ? t[0] : null; };
const branchTask = text => { const m = /(?<![A-Za-z0-9])task-(\d+(?:\.\d+)?)/i.exec(String(text)); return m ? 'TASK-' + m[1] : null; };
const ticketParts = t => String(t).replace(/^TASK-/, '').split('.').map(Number);
function cmpTickets(a, b) {
  if (a === COORD || b === COORD) return a === b ? 0 : a === COORD ? 1 : -1;
  const x = ticketParts(a), y = ticketParts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) { const d = (x[i] || 0) - (y[i] || 0); if (d) return d; }
  return cmp(a, b);
}
const validTicket = v => typeof v === 'string' && (/^TASK-\d+(\.\d+)?$/.test(v) || v === COORD);

// The ticket titles come from the repo's own backlog.
function loadTitles(repo) {
  const titles = new Map();
  const backlog = path.join(repo, 'backlog');
  for (const dir of ['tasks', 'completed']) {
    for (const name of listDir(path.join(backlog, dir)).sort()) {
      const m = /^task-(\d+(?:\.\d+)?) - (.+)\.md$/i.exec(name);
      if (!m) continue;
      const raw = m[2].trim();
      const p = /^(P\d+-E\d+(?:-T\d+)?)(?:-(.*))?$/i.exec(raw);
      titles.set('TASK-' + m[1], p ? p[1] + (p[2] ? ' ' + p[2].replace(/-/g, ' ') : '') : raw.replace(/-/g, ' '));
    }
  }
  return titles;
}

// ---------- privacy: masking secrets, the user name and paths ----------
const SECRET_RES = [
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g, '<email>'],
  [/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g, '<secret>'],
  [/\bgh[pousr]_[A-Za-z0-9]{8,}/g, '<secret>'],
  [/\bgithub_pat_[A-Za-z0-9_]{10,}/g, '<secret>'],
  [/\bsk-[A-Za-z0-9_-]{8,}/g, '<secret>'],
  [/\bxox[a-z]?-[A-Za-z0-9-]{8,}/g, '<secret>'],
  [/\b(?:AKIA|ASIA)[A-Z0-9]{12,}/g, '<secret>'],
  [/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/gi, '<secret>'],
  [/\b(?:password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|auth|authorization)\s*[=:]\s*[^\s"',;]+/gi, '<secret>'],
  [/\b[0-9a-fA-F]{32,}\b/g, '<secret>'],
];
const maskSecrets = s => {
  let r = s;
  for (const [re, to] of SECRET_RES) r = r.replace(re, to);
  return r.replace(/[A-Za-z0-9+]{32,}={0,2}/g, m => (/[a-z]/.test(m) && /[A-Z]/.test(m) && /[0-9]/.test(m) ? '<secret>' : m));
};

// Archon worktrees: <anything>/.archon/workspaces/<owner>/<repo>/worktrees/<branch>, where the branch has one segment or
// two (feat/x). Only the prefixes git branch naming makes common are read as the first of two.
const TWO_SEGMENT_PREFIX = new Set(['feat', 'fix', 'chore', 'refactor', 'docs', 'test', 'hotfix', 'archon', 'task', 'release', 'build', 'ci', 'perf', 'style']);
const WORKTREE_RE = /^(.*\/\.archon\/workspaces\/[^/]+\/([^/]+)\/worktrees\/)(.+)$/i;
function worktreeRoot(p) {
  const m = WORKTREE_RE.exec(p);
  if (!m) return null;
  const segs = m[3].split('/');
  const n = segs.length > 1 && TWO_SEGMENT_PREFIX.has(segs[0].toLowerCase()) ? 2 : 1;
  return { prefix: m[1] + segs.slice(0, n).join('/'), name: m[2], branch: segs.slice(0, n).join('/'), rest: segs.slice(n).join('/') };
}

function makeSanitizer(cfg, dirs) {
  const homeLower = cfg.home.toLowerCase();
  const names = [...cfg.userNames].filter(n => n && n.length >= 2).sort((a, b) => b.length - a.length);
  const userRes = names.map(n => new RegExp('(?<![A-Za-z0-9])' + esc(n) + '(?![A-Za-z0-9])', 'gi'));
  const maskUser = s => { let r = s; for (const re of userRes) r = r.replace(re, '<user>'); return r; };
  const text = (s, cap = 200) => { const r = maskUser(maskSecrets(String(s).replace(/\s+/g, ' ').trim())); return r.length > cap ? r.slice(0, cap) + '...' : r; };

  // The repo roots: every directory a session ran in (Claude Code or Archon); a directory inside another one is dropped.
  const cand = new Map();
  for (const d of dirs) {
    if (!d) continue;
    const p = norm(d);
    if (p.length <= 3 || p.toLowerCase() === homeLower || homeLower.startsWith(p.toLowerCase() + '/')) continue;
    const w = worktreeRoot(p);
    const r = w ? { prefix: w.prefix, name: w.name } : { prefix: p, name: p.split('/').pop() };
    cand.set(r.prefix.toLowerCase(), { lower: r.prefix.toLowerCase(), prefix: r.prefix, name: text(r.name, 60) });
  }
  const all = [...cand.values()];
  const roots = all.filter(r => !all.some(o => o !== r && r.lower.startsWith(o.lower + '/'))).sort((a, b) => b.lower.length - a.lower.length || cmp(a.lower, b.lower));

  function rootFor(p) {
    const lp = p.toLowerCase();
    for (const r of roots) if (lp === r.lower || lp.startsWith(r.lower + '/')) return r;
    return null;
  }
  // Which repo a directory belongs to; '~' for the home directory itself.
  function repoName(dir) {
    if (!dir) return null;
    const p = norm(dir);
    if (p.toLowerCase() === homeLower) return '~';
    const r = rootFor(p);
    if (r) return r.name;
    const w = worktreeRoot(p);
    return text(w ? w.name : p.split('/').pop() || p, 60);
  }
  // {kind: repo|home|rel|other, text}: a path as it may be written down.
  function mapPath(raw, ctx) {
    let p = fwd(raw).replace(/\/{2,}/g, '/');
    if (!p) return { kind: 'rel', text: '' };
    let kind, out;
    if (p === '~' || p.startsWith('~/')) { kind = 'home'; out = p; }
    else if (!/^(?:\/|[A-Za-z]:\/)/.test(p)) {
      kind = 'rel';
      p = p.replace(/^(?:\.\/)+/, '');
      out = ctx === '~' ? '~/' + p : ctx ? ctx + ':' + p : p;
    } else {
      const lp = p.toLowerCase();
      const r = rootFor(p);
      let w;
      let m;
      if (r) { kind = 'repo'; out = r.name + ':' + (lp === r.lower ? '.' : p.slice(r.lower.length + 1)); }
      else if ((w = worktreeRoot(p))) { kind = 'repo'; out = text(w.name, 60) + ':' + (w.rest || '.'); }
      else if (lp === homeLower) { kind = 'home'; out = '~'; }
      else if (lp.startsWith(homeLower + '/')) { kind = 'home'; out = '~/' + p.slice(cfg.home.length + 1); }
      else if ((m = /^(?:\/home\/[^/]+|\/Users\/[^/]+|[A-Za-z]:\/Users\/[^/]+)(\/.*)?$/i.exec(p))) { kind = 'home'; out = '~' + (m[1] || ''); }
      else { kind = 'other'; out = p; }
    }
    return { kind, text: text(out, 300) };
  }
  // An id the tools generate (a run id is 32 hex digits) is kept as it is, so that it can be matched in attribution.json.
  const id = s => (/^[A-Za-z0-9_-]{1,64}$/.test(String(s)) ? String(s) : text(s, 80));
  return { text, id, mapPath, repoName, path: (raw, ctx) => mapPath(raw, ctx).text };
}

// ---------- shell commands: only the program, and the subcommand where there is one ----------
const SUB_PROGRAMS = new Set(['git', 'gh', 'npm', 'npx', 'archon', 'backlog', 'docker', './gradlew', 'gradlew']);
const SCRIPT_PROGRAMS = new Set(['node', 'bash', 'sh', 'python']);
const SCRIPT_EXT = /\.(sh|js|mjs|cjs|ts|py|ps1|rb|bat|cmd)$/i;
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;
const LEADING = new Set(['do', 'then', 'else', 'elif', 'if', 'while', 'until', '!', '{', '(', '&', '.', 'sudo', 'time', 'nohup', 'exec', 'command', 'env', 'builtin', 'call']);
const DROP_SEGMENT = new Set(['cd', 'pushd', 'popd', 'set-location', 'sl', 'export', 'declare', 'local', 'readonly', 'unset', 'typeset', 'set', 'alias',
  'for', 'case', 'function', 'select', 'done', 'fi', 'esac', 'return', 'exit', 'break', 'continue', 'shift', 'trap', 'wait', '}', ')', 'in']);
const KEYWORDS = new Set(['if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done', 'case', 'esac', 'in', 'function', 'select', 'time']);
const VALUE_OPTS = {
  git: new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--super-prefix', '--config-env']),
  gh: new Set(['-R', '--repo', '--hostname']),
  npm: new Set(['--prefix', '-w', '--workspace', '--registry', '--userconfig', '--cache', '--loglevel', '--otp', '--tag']),
  npx: new Set(['-p', '--package', '-c', '--call', '--node-arg', '--registry', '--cache', '--prefix', '-w', '--workspace']),
  archon: new Set(['--cwd', '-C', '--config']),
  docker: new Set(['-H', '--host', '-c', '--context', '-l', '--log-level', '--config', '--tlscacert', '--tlscert', '--tlskey']),
  gradlew: new Set(['-p', '--project-dir', '-c', '--settings-file', '-b', '--build-file', '-g', '--gradle-user-home', '-I', '--init-script', '--max-workers', '-x', '--exclude-task']),
  node: new Set(['-e', '-p', '--eval', '--print', '-r', '--require', '--import', '--loader', '--experimental-loader', '-C', '--conditions', '--inspect-port']),
  bash: new Set(['-c', '-o', '-O', '--rcfile', '--init-file']),
  sh: new Set(['-c', '-o', '-O', '--rcfile', '--init-file']),
  python: new Set(['-c', '-m', '-W', '-X', '-Q']),
};
// git, gh and npm take global options with values, so their subcommand is checked against what exists.
const ALLOWED_SUB = {
  git: new Set(('add am apply archive bisect blame branch bundle cat-file check-ignore checkout cherry-pick clean clone commit commit-tree config count-objects describe diff diff-tree ' +
    'fetch for-each-ref format-patch gc grep hash-object init log ls-files ls-remote ls-tree merge merge-base mktree mv name-rev notes pull push range-diff read-tree rebase reflog ' +
    'remote reset restore rev-list rev-parse revert rm shortlog show show-ref sparse-checkout stash status submodule switch symbolic-ref tag update-index update-ref ' +
    'whatchanged worktree write-tree').split(' ')),
  gh: new Set(('alias api attestation auth browse cache codespace completion config copilot extension gist issue label org pr project release repo ruleset run search secret ssh-key status ' +
    'variable workflow').split(' ')),
  npm: new Set(('access audit bin cache ci completion config dedupe deprecate diff dist-tag docs doctor edit exec explain explore find-dupes fund help help-search hook init install ' +
    'install-ci-test install-test link ln login logout ls org outdated owner pack ping pkg prefix profile prune publish query rebuild repo restart root run run-script sbom search set ' +
    'shrinkwrap star stars start stop team test token uninstall unpublish unstar update version view whoami i it t').split(' ')),
};
const SUB_RE = /^[a-z][a-z0-9:_-]{0,30}$/;
const GRADLE_TASK_RE = /^[:A-Za-z][A-Za-z0-9:_.-]{0,60}$/;
const NPX_PKG_RE = /^@?[a-z0-9][a-z0-9._-]{0,60}(?:\/[a-z0-9][a-z0-9._-]{0,60})?$/;
const PROGRAM_RE = /^[A-Za-z0-9][A-Za-z0-9_.+@-]{0,39}$/;

// Splits a command line on && || ; | & and newlines outside quotes, and drops heredoc bodies and PowerShell here-strings.
function splitSegments(cmd) {
  const segs = [];
  const pending = [];
  let cur = '';
  let q = null;
  let i = 0;
  const n = cmd.length;
  const push = () => { if (cur.trim()) segs.push(cur); cur = ''; };
  while (i < n) {
    const c = cmd[i];
    if (q) {
      cur += c;
      if (q === '"' && c === '\\' && i + 1 < n) { cur += cmd[i + 1]; i += 2; continue; }
      if (c === q) q = null;
      i++;
      continue;
    }
    if (c === "'" || c === '"') { q = c; cur += c; i++; continue; }
    if (c === '@' && (cmd[i + 1] === "'" || cmd[i + 1] === '"')) {
      const m = /^@(['"])[ \t]*\r?\n/.exec(cmd.slice(i, i + 24));
      if (m) {
        const end = cmd.indexOf('\n' + m[1] + '@', i + m[0].length - 1);
        cur += ' ';
        i = end < 0 ? n : end + 3;
        continue;
      }
    }
    if ((c === '\\' || c === '`') && (cmd[i + 1] === '\n' || (cmd[i + 1] === '\r' && cmd[i + 2] === '\n'))) { cur += ' '; i += cmd[i + 1] === '\n' ? 2 : 3; continue; }
    if (c === '<' && cmd[i + 1] === '<' && cmd[i + 2] !== '<') {
      const m = /^<<(-?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\?([A-Za-z0-9_.-]+))/.exec(cmd.slice(i, i + 120));
      if (m) {
        pending.push({ delim: m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4], strip: m[1] === '-' });
        i += m[0].length;
        continue;
      }
    }
    if (c === '\n') {
      push();
      i++;
      for (const h of pending.splice(0)) {
        while (i < n) {
          let e = cmd.indexOf('\n', i);
          if (e < 0) e = n;
          const line = cmd.slice(i, e).replace(/\r$/, '');
          i = Math.min(n, e + 1);
          if ((h.strip ? line.trim() : line) === h.delim) break;
        }
      }
      continue;
    }
    if ((c === '&' && cmd[i + 1] === '&') || (c === '|' && cmd[i + 1] === '|')) { push(); i += 2; continue; }
    if (c === ';' || c === '|') { push(); i++; continue; }
    if (c === '&' && cmd[i - 1] !== '>' && cmd[i - 1] !== '<' && cmd[i + 1] !== '>') { push(); i++; continue; }
    cur += c;
    i++;
  }
  push();
  return segs;
}

function tokenize(seg) {
  const toks = [];
  let cur = '';
  let has = false;
  let q = null;
  for (let i = 0; i < seg.length; i++) {
    const c = seg[i];
    if (q) {
      if (c === q) q = null;
      else if (q === '"' && c === '\\' && seg[i + 1] === '"') { cur += '"'; i++; }
      else cur += c;
      continue;
    }
    if (c === '"' || c === "'") { q = c; has = true; continue; }
    if (/\s/.test(c)) { if (has) { toks.push(cur); cur = ''; has = false; } continue; }
    cur += c;
    has = true;
  }
  if (has) toks.push(cur);
  return toks;
}

const isRedirect = t => /^(?:\d*[<>]|&>)/.test(t);
const redirectTakesNext = t => /^(?:\d*>>?|\d*<|&>>?)$/.test(t);

// First non-option token after the program, skipping options that take a separate value and redirections.
function firstOperand(tokens, valueOpts) {
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (isRedirect(t)) { if (redirectTakesNext(t)) i++; continue; }
    if (t.startsWith('-')) { if (valueOpts && valueOpts.has(t)) i++; continue; }
    return t;
  }
  return null;
}

// -> [{prog, sub?, script?}]; script is the raw script argument of node/bash/sh/python, resolved later (it must be a repo path).
function parseCommand(cmd) {
  const found = [];
  if (!cmd) return found;
  for (const seg of splitSegments(cmd)) {
    const tokens = tokenize(seg);
    let i = 0;
    while (i < tokens.length) {
      const t = tokens[i];
      const low = t.toLowerCase();
      if (ASSIGN.test(t) || LEADING.has(low)) { i++; continue; }
      if (low === 'timeout') { i++; if (/^\d+[smhd]?$/.test(tokens[i] || '')) i++; continue; }
      break;
    }
    if (i >= tokens.length) continue;
    let first = tokens[i].replace(/^[({]+/, '').replace(/[)};]+$/, '');
    if (!first || DROP_SEGMENT.has(first.toLowerCase())) continue;
    if (/^\.?\/?gradlew(?:\.bat)?$/i.test(first.replace(/^.*[\\/]/, '').replace(/^/, first.startsWith('./') ? './' : ''))) first = first.startsWith('./') ? './gradlew' : 'gradlew';
    let prog;
    if (first === './gradlew' || first === 'gradlew') prog = first;
    else {
      let base = fwd(first).split('/').pop().replace(/\.(?:exe|cmd|bat|ps1)$/i, '');
      let key = base.toLowerCase();
      if (/^python[0-9.]*$/.test(key) || key === 'py') key = 'python';
      if (/^gradlew$/.test(key)) key = 'gradlew';
      prog = SUB_PROGRAMS.has(key) || SCRIPT_PROGRAMS.has(key) || key === 'python' || key === 'curl' ? key : base;
    }
    if (!PROGRAM_RE.test(prog.replace(/^\.\//, '')) || KEYWORDS.has(prog.toLowerCase())) continue;
    const rest = tokens.slice(i + 1);
    const item = { prog };
    const key = prog === './gradlew' ? 'gradlew' : prog;
    if (SUB_PROGRAMS.has(prog)) {
      const t = firstOperand(rest, VALUE_OPTS[key]);
      if (t !== null) {
        const ok = ALLOWED_SUB[key] ? ALLOWED_SUB[key].has(t)
          : key === 'gradlew' ? GRADLE_TASK_RE.test(t)
            : key === 'npx' ? NPX_PKG_RE.test(t)
              : SUB_RE.test(t);
        if (ok) item.sub = t;
      }
    } else if (SCRIPT_PROGRAMS.has(prog)) {
      const t = firstOperand(rest, VALUE_OPTS[prog]);
      if (t !== null) item.script = t;
    }
    found.push(item);
  }
  return found;
}

// A script is kept by its base name, and only when it is a file of the repo.
function programNames(items, san, ctx) {
  const out = [];
  for (const it of items) {
    let name = it.prog;
    if (it.sub) name += ' ' + it.sub;
    else if (it.script) {
      const t = fwd(it.script);
      if (/^[^\s]+$/.test(t) && !/[$`*?{}()<>|;&"']/.test(t) && SCRIPT_EXT.test(t)) {
        const m = san.mapPath(t, ctx);
        const base = t.split('/').pop();
        if ((m.kind === 'repo' || m.kind === 'rel') && /^[A-Za-z0-9][A-Za-z0-9_.+@-]*$/.test(base)) name += ' ' + base;
      }
    }
    out.push(san.text(name, 80));
  }
  return out;
}

// ---------- time ----------
function makeDayFn(timeZone) {
  const fmt = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' });
  const cache = new Map();
  return ms => {
    const k = Math.floor(ms / 60000);
    let d = cache.get(k);
    if (!d) {
      const p = {};
      for (const x of fmt.formatToParts(new Date(ms))) p[x.type] = x.value;
      d = `${p.year}-${p.month}-${p.day}`;
      cache.set(k, d);
    }
    return d;
  };
}

// ---------- configuration ----------
function loadConfig(opts) {
  const repo = path.resolve(opts.repo || path.join(__dirname, '..', '..'));
  const out = path.resolve(opts.out || path.join(repo, 'docs', 'tokenomics'));
  const homeArg = opts.home || process.env.TOKENOMICS_HOME || '';
  const home = norm(path.resolve(homeArg || os.homedir()));
  const userNames = new Set([home.split('/').pop()]);
  if (!homeArg) { try { userNames.add(os.userInfo().username); } catch { /* no user database */ } }
  const pricingFile = path.resolve(opts.pricing || path.join(out, 'pricing.json'));
  const pricing = readJson(pricingFile);
  if (!pricing || typeof pricing !== 'object' || !pricing.models) die(`pricing file missing or invalid: ${pricingFile}`);
  if (!(pricing.usdPerEur > 0)) die('pricing.usdPerEur must be a positive number');
  // Which transcript folders belong to this project is a project fact: <out>/scope.json, { "include": [<part of an encoded folder name>, ...] }.
  // Fail closed: a missing or invalid file means no folder is read, never all of them.
  const scopeFile = path.join(out, 'scope.json');
  const scopeJson = readJson(scopeFile);
  const include = scopeJson && Array.isArray(scopeJson.include) ? scopeJson.include.filter(x => typeof x === 'string' && x.length > 3) : [];
  if (!include.length) warn(`scope.json missing or invalid (needs {"include": [...]}): ${scopeFile}; no transcripts are read`);
  const attribution = readJson(path.join(out, 'attribution.json')) || {};
  const overrides = {};
  for (const [k, v] of Object.entries(attribution)) {
    const val = typeof v === 'string' && v.toLowerCase() === COORD ? COORD : typeof v === 'string' ? v.toUpperCase() : v;
    if (validTicket(val)) overrides[k] = val; else warn(`attribution.json: ignoring ${k}: expected "TASK-x" or "coordination"`);
  }
  return {
    repo, out, home, userNames, pricing, overrides, include,
    projects: path.resolve(opts.projects || process.env.TOKENOMICS_PROJECTS || path.join(home, '.claude', 'projects')),
    archonRuns: opts['archon-runs'] || process.env.TOKENOMICS_ARCHON_RUNS || '',
    archonDb: opts['archon-db'] || process.env.TOKENOMICS_ARCHON_DB || '',
    artifacts: path.resolve(opts.artifacts || process.env.TOKENOMICS_ARCHON_ARTIFACTS || path.join(home, '.archon', 'workspaces')),
    explicitHome: !!homeArg,
    dayOf: makeDayFn(pricing.timeZone || 'Europe/Amsterdam'),
  };
}

// ---------- pricing ----------
function rateFor(pricing, model) {
  if (pricing.models[model]) return pricing.models[model];
  let best = null;
  for (const k of Object.keys(pricing.models)) if (model.startsWith(k + '-') && (best === null || k.length > best.length)) best = k;
  return best === null ? null : pricing.models[best];
}
// -> {usd, priced}: a model with no rate is flagged, never counted as free.
function costOf(pricing, model, m) {
  const r = rateFor(pricing, model);
  if (!r) return { usd: 0, priced: false };
  const usd = ((m.input || 0) * r.input + (m.cacheWrite5m || 0) * r.cacheWrite5m + (m.cacheWrite1h || 0) * r.cacheWrite1h +
    (m.cacheRead || 0) * r.cacheRead + (m.output || 0) * r.output) / 1e6 + (m.webSearch || 0) * (pricing.webSearchUsdPerRequest || 0);
  return { usd, priced: true };
}

// ---------- transcripts ----------
function discover(projects, include) {
  const files = [];
  let skipped = 0;
  const agentFile = /^agent-(.+)\.jsonl$/;
  for (const enc of listDir(projects).sort()) {
    const dir = path.join(projects, enc);
    if (!isDir(dir)) continue;
    if (!include.some(p => enc.includes(p))) { skipped++; continue; } // outside the project's scope: counted, never named
    for (const name of listDir(dir).sort()) {
      const p = path.join(dir, name);
      if (name.endsWith('.jsonl') && isFile(p)) {
        const id = name.slice(0, -6);
        files.push({ kind: 'top', file: p, key: id, sessionId: id, rel: `${enc}/${name}` });
      } else if (isDir(p)) {
        const subs = path.join(p, 'subagents');
        for (const n of listDir(subs).sort()) {
          const q = path.join(subs, n);
          const a = agentFile.exec(n);
          if (a && isFile(q)) files.push({ kind: 'sub', file: q, key: a[1], sessionId: name, rel: `${enc}/${name}/subagents/${n}`, metaFile: q.replace(/\.jsonl$/, '.meta.json') });
          else if (n === 'workflows' && isDir(q)) {
            for (const wf of listDir(q).sort()) {
              const wd = path.join(q, wf);
              for (const m of listDir(wd).sort()) {
                const b = agentFile.exec(m);
                if (b && isFile(path.join(wd, m))) {
                  files.push({ kind: 'wf', file: path.join(wd, m), key: b[1], sessionId: name, wfDir: wd, rel: `${enc}/${name}/subagents/workflows/${wf}/${m}`,
                    metaFile: path.join(wd, m).replace(/\.jsonl$/, '.meta.json') });
                }
              }
            }
          }
        }
      }
    }
  }
  return { files: files.filter(f => /^[A-Za-z0-9_-]{1,80}$/.test(f.key) && /^[A-Za-z0-9_-]{1,80}$/.test(f.sessionId)), skipped };
}

function promptText(message) {
  if (!message) return null;
  const c = message.content;
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map(b => (b && b.type === 'text' && typeof b.text === 'string' ? b.text : '')).join('\n');
  return null;
}

function addTool(m, b) {
  const id = typeof b.id === 'string' && b.id ? b.id : 't' + m.tools.size;
  if (m.tools.has(id)) return;
  const inp = b.input && typeof b.input === 'object' ? b.input : {};
  const name = str(b.name) || '?';
  const t = { name };
  if (name === 'Skill') t.skill = str(inp.skill);
  else if (name === 'Agent' || name === 'Task') t.sub = str(inp.subagent_type) || 'general-purpose';
  else if (READ_TOOLS.has(name)) {
    t.read = str(inp.file_path) || str(inp.notebook_path);
    t.whole = inp.offset === undefined && inp.limit === undefined;
  }
  else if (EDIT_TOOLS.has(name)) t.edit = str(inp.file_path) || str(inp.notebook_path);
  else if (name === 'Bash' || name === 'PowerShell') t.programs = parseCommand(str(inp.command));
  m.tools.set(id, t);
}

// One pass over a transcript. Only usage numbers, tool names and a few tool arguments are read; the prompt of an agent is
// read for its ticket mentions and dropped.
function scanTranscript(entry) {
  const st = { cwd: null, branch: null, msgs: new Map(), taskCounts: null, instructions: [], lastMs: -Infinity };
  let promptDone = entry.kind === 'top';
  let metaTries = 0;
  eachLine(entry.file, line => {
    const hasUsage = line.indexOf('"usage"') !== -1;
    const hasAttach = !hasUsage && line.indexOf('"instructions"') !== -1;
    const maybeUser = !promptDone && line.indexOf('"user"') !== -1;
    const needMeta = !st.cwd && metaTries < 50;
    if (!hasUsage && !hasAttach && !maybeUser && !needMeta) return;
    let o;
    try { o = JSON.parse(line); } catch { return; }
    if (!o || typeof o !== 'object') return;
    if (needMeta) metaTries++;
    if (!st.cwd && typeof o.cwd === 'string' && o.cwd) st.cwd = o.cwd;
    if (st.branch === null && typeof o.gitBranch === 'string' && o.gitBranch) st.branch = o.gitBranch;
    if (o.type === 'user') {
      if (!promptDone) {
        promptDone = true;
        const t = promptText(o.message);
        if (t !== null) { st.taskCounts = new Map(); for (const id of taskIds(t)) st.taskCounts.set(id, (st.taskCounts.get(id) || 0) + 1); }
      }
    } else if (o.type === 'attachment') {
      const a = o.attachment;
      if (a && a.type === 'instructions' && Array.isArray(a.files)) for (const f of a.files) if (f && typeof f.path === 'string') st.instructions.push(f.path);
    } else if (o.type === 'assistant') {
      const msg = o.message;
      if (!msg || !msg.usage || typeof msg.model !== 'string' || msg.model === SYNTHETIC) return;
      const key = str(msg.id || o.uuid) + '|' + str(o.requestId);
      if (key === '|') return;
      let m = st.msgs.get(key);
      if (!m) {
        m = { model: msg.model, t0: Infinity, t1: -Infinity, input: 0, output: 0, cacheRead: 0, cwTotal: 0, cw5: 0, cw1: 0, split: false, web: 0, tools: new Map() };
        st.msgs.set(key, m);
      }
      const u = msg.usage;
      m.input = Math.max(m.input, num(u.input_tokens));
      m.output = Math.max(m.output, num(u.output_tokens));
      m.cacheRead = Math.max(m.cacheRead, num(u.cache_read_input_tokens));
      m.cwTotal = Math.max(m.cwTotal, num(u.cache_creation_input_tokens));
      const cc = u.cache_creation;
      if (cc && typeof cc === 'object') {
        m.split = true;
        m.cw5 = Math.max(m.cw5, num(cc.ephemeral_5m_input_tokens));
        m.cw1 = Math.max(m.cw1, num(cc.ephemeral_1h_input_tokens));
      }
      if (u.server_tool_use && typeof u.server_tool_use === 'object') m.web = Math.max(m.web, num(u.server_tool_use.web_search_requests));
      const ts = Date.parse(o.timestamp);
      if (Number.isFinite(ts)) { m.t0 = Math.min(m.t0, ts); m.t1 = Math.max(m.t1, ts); st.lastMs = Math.max(st.lastMs, ts); }
      if (Array.isArray(msg.content)) for (const b of msg.content) if (b && b.type === 'tool_use') addTool(m, b);
    }
  });
  return st;
}

function loadJournals(files) {
  const byDir = new Map();
  for (const f of files) {
    if (f.kind !== 'wf' || byDir.has(f.wfDir)) continue;
    const labels = new Map();
    const j = path.join(f.wfDir, 'journal.jsonl');
    if (isFile(j)) {
      eachLine(j, line => {
        if (line.indexOf('"started"') === -1) return;
        let o;
        try { o = JSON.parse(line); } catch { return; }
        if (o && o.type === 'started' && typeof o.agentId === 'string') labels.set(o.agentId, { label: str(o.label), phase: str(o.phase) });
      });
    }
    byDir.set(f.wfDir, labels);
  }
  return byDir;
}

// ---------- Archon ----------
function loadArchon(cfg) {
  if (cfg.archonRuns) {
    const j = readJson(path.resolve(cfg.archonRuns));
    if (!j || !Array.isArray(j.runs)) die(`archon runs file missing or invalid: ${cfg.archonRuns}`);
    return j.runs.map(r => ({
      id: str(r.id), workflowName: str(r.workflowName), userMessage: str(r.userMessage), workingPath: str(r.workingPath), branch: str(r.branch), startedAt: str(r.startedAt),
      nodes: (Array.isArray(r.nodes) ? r.nodes : []).map(n => ({
        nodeId: str(n.nodeId), sessionPreview: str(n.sessionPreview), model: str(n.model), sessionOrigin: str(n.sessionOrigin), status: str(n.status),
        costUsd: num(n.costUsd), numTurns: num(n.numTurns), durationMs: num(n.durationMs),
      })),
    }));
  }
  const dbPath = path.resolve(cfg.archonDb || path.join(cfg.home, '.archon', 'archon.db'));
  if (!isFile(dbPath)) { warn(`no Archon database at ${cfg.explicitHome || cfg.archonDb ? 'the given path' : 'the default path'}: Archon costs skipped`); return []; }
  let DatabaseSync;
  try { ({ DatabaseSync } = require('node:sqlite')); } catch { warn('node:sqlite is not available in this Node: Archon costs skipped'); return []; }
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const runs = new Map();
    for (const r of db.prepare('SELECT id, workflow_name, user_message, working_path, started_at FROM remote_agent_workflow_runs').all()) {
      runs.set(r.id, { id: str(r.id), workflowName: str(r.workflow_name), userMessage: str(r.user_message), workingPath: str(r.working_path), branch: '',
        startedAt: str(r.started_at), nodes: new Map() });
    }
    const events = db.prepare("SELECT workflow_run_id AS rid, step_name AS step, event_type AS type, data FROM remote_agent_workflow_events WHERE event_type IN ('node_completed','node_failed')").all();
    for (const e of events) {
      const run = runs.get(e.rid);
      let d;
      try { d = JSON.parse(e.data); } catch { continue; }
      const sp = d && d.binding && d.binding.sessionPreview;
      if (!run || typeof sp !== 'string' || !sp) continue;
      const v = x => (x && typeof x === 'object' ? x.value : x);
      const nodeId = str((d.node && d.node.id) || e.step);
      run.nodes.set(nodeId + '|' + sp, {
        nodeId, sessionPreview: sp, model: str(d.binding.model && d.binding.model.resolved && d.binding.model.resolved.value), sessionOrigin: str(d.binding.sessionOrigin),
        status: e.type === 'node_failed' ? 'failed' : 'completed', costUsd: num(v(d.spend && d.spend.costUsd)), numTurns: num(v(d.spend && d.spend.numTurns)),
        durationMs: num(d.timing && d.timing.durationMs),
      });
    }
    return [...runs.values()].map(r => Object.assign(r, { nodes: [...r.nodes.values()] }));
  } catch (e) {
    warn(`could not read the Archon database (${String(e.message).split('\n')[0]}): Archon costs skipped`);
    return [];
  } finally { try { if (db) db.close(); } catch { /* already closed */ } }
}

// Archon nodes are top-level sessions: the session id starts with the node's sessionPreview and the cwd is the run's.
function matchArchon(runs, files) {
  const tops = files.filter(f => f.kind === 'top' && f.cwd);
  const key = p => norm(p).toLowerCase();
  let matched = 0, unmatched = 0;
  const sorted = runs.slice().sort((a, b) => cmp(a.startedAt, b.startedAt) || cmp(a.id, b.id));
  for (const run of sorted) {
    for (const n of run.nodes.slice().sort((a, b) => cmp(a.nodeId, b.nodeId))) {
      if (n.sessionPreview.length < 4) continue;
      const c = tops.filter(f => f.key.startsWith(n.sessionPreview) && key(f.cwd) === key(run.workingPath));
      if (c.length !== 1) { unmatched++; continue; }
      matched++;
      (c[0].archonNodes = c[0].archonNodes || []).push({ run, node: n });
    }
  }
  return { matched, unmatched };
}

// ---------- ownership of messages that sit in several files ----------
// A resumed or forked Archon session copies the history of its source under a new session id, so the same message is in
// several files. Each message counts once: for the file that owns it. The owner is remembered for shared messages, so the
// count does not move when a file is pruned later.
const msgHash = k => crypto.createHash('sha1').update(k).digest('hex').slice(0, 12);

function assignOwners(files, prev) {
  const holders = new Map();
  for (const f of files) for (const k of f.st.msgs.keys()) { const a = holders.get(k); if (a) a.push(f); else holders.set(k, [f]); }
  const owners = {};
  const rank = (a, b) => ((a.kind === 'top') === (b.kind === 'top') ? 0 : a.kind === 'top' ? 1 : -1) || (a.st.lastMs - b.st.lastMs) || cmp(a.rel, b.rel);
  for (const f of files) f.owned = [];
  for (const [k, hs] of holders) {
    const h = msgHash(k);
    const mapped = prev[h];
    let owner;
    if (hs.length === 1) {
      owner = mapped === undefined || mapped === hs[0].key ? hs[0] : null;
    } else if (mapped !== undefined) {
      owner = hs.find(f => f.key === mapped) || null;
      owners[h] = mapped;
    } else {
      hs.sort(rank);
      owner = hs[0];
      owners[h] = owner.key;
    }
    if (owner) owner.owned.push(k);
  }
  for (const [h, o] of Object.entries(prev)) if (!(h in owners)) owners[h] = o;
  return owners;
}

// ---------- records ----------
const ttlFor = (pricing, kind) => ((pricing.cacheTtlByKind && (pricing.cacheTtlByKind[kind] || pricing.cacheTtlByKind.default)) || '1h');
const bump = (obj, key, by = 1) => { obj[key] = (obj[key] || 0) + by; };

function attribute(f, parent, cfg) {
  const ov = cfg.overrides[f.key] || (f.runId && cfg.overrides[f.runId]) || cfg.overrides[f.sessionId];
  if (ov) return { ticket: ov, rule: 'override' };
  if (f.archonNodes) {
    const { run } = f.archonNodes[0];
    const wt = worktreeRoot(norm(run.workingPath));
    const fromRequest = firstTask(run.userMessage);
    if (fromRequest) return { ticket: fromRequest, rule: 'archon-request' };
    const fromBranch = branchTask(run.branch) || branchTask(wt ? wt.branch : '');
    if (fromBranch) return { ticket: fromBranch, rule: 'archon-branch' };
    return { ticket: COORD, rule: COORD };
  }
  if (f.kind !== 'top') {
    const fromLabel = firstTask(f.rawLabel) || firstTask(f.rawDescription);
    if (fromLabel) return { ticket: fromLabel, rule: 'label' };
    if (f.st.taskCounts && f.st.taskCounts.size) {
      let total = 0;
      for (const c of f.st.taskCounts.values()) total += c;
      for (const [id, c] of [...f.st.taskCounts].sort((a, b) => b[1] - a[1] || cmp(a[0], b[0]))) {
        if (c / total >= 0.6) return { ticket: id, rule: 'prompt-share' };
        break;
      }
    }
    if (parent && parent.archonNodes && parent.attr && parent.attr.ticket !== COORD) return { ticket: parent.attr.ticket, rule: 'parent-archon' };
  }
  return { ticket: COORD, rule: COORD };
}

function describeFiles(files, journals, cfg, san) {
  const byKey = new Map();
  for (const f of files) if (f.kind === 'top') byKey.set(f.key, f);
  for (const f of files) {
    const meta = f.metaFile ? readJson(f.metaFile) || {} : {};
    const jr = f.kind === 'wf' ? (journals.get(f.wfDir) || new Map()).get(f.key) : null;
    f.type = f.kind === 'top' ? null : san.text(str(meta.agentType) || null, 60) || null;
    f.phase = f.kind === 'wf' ? san.text(str(jr && jr.phase) || str(meta.workflowPhase), 60) || null : null;
    f.rawDescription = str(meta.description);
    if (f.kind === 'top') {
      if (f.archonNodes) {
        const wf = f.archonNodes[0].run.workflowName;
        f.rawLabel = `${wf}/${[...new Set(f.archonNodes.map(a => a.node.nodeId))].join('+')}`;
        f.recKind = 'archon-node';
      } else { f.rawLabel = `session ${f.key.slice(0, 8)}`; f.recKind = 'coordinator'; }
    } else {
      f.rawLabel = (f.kind === 'wf' && jr && jr.label) || f.rawDescription || `agent ${f.key.slice(0, 9)}`;
      f.recKind = f.kind === 'wf' ? 'workflow-agent' : 'subagent';
    }
    f.label = san.text(f.rawLabel, 160);
    const parent = f.kind === 'top' ? null : byKey.get(f.sessionId) || null;
    f.parent = parent;
    f.runId = f.archonNodes ? f.archonNodes[0].run.id : parent && parent.archonNodes ? parent.archonNodes[0].run.id : null;
  }
  // tops first, so that agents can follow the ticket of the Archon node they run in
  for (const f of files.filter(x => x.kind === 'top')) f.attr = attribute(f, null, cfg);
  for (const f of files.filter(x => x.kind !== 'top')) f.attr = attribute(f, f.parent, cfg);
}

function buildRecords(files, cfg, san) {
  const records = [];
  for (const f of files) {
    if (!f.owned.length) continue;
    const ttl = ttlFor(cfg.pricing, f.recKind);
    const ctx = san.repoName(f.cwd);
    const repo = ctx;
    const byDay = new Map();
    const days = [];
    for (const k of f.owned.slice().sort()) {
      const m = f.st.msgs.get(k);
      if (!Number.isFinite(m.t0)) continue;
      const day = cfg.dayOf(m.t0);
      let r = byDay.get(day);
      if (!r) {
        r = { day, models: {}, activity: { filesEdited: {}, filesRead: {}, instructions: [], programs: {}, skills: {}, subagents: {}, tools: {}, workflows: 0 }, first: Infinity, last: -Infinity };
        byDay.set(day, r);
        days.push(day);
      }
      const mm = r.models[m.model] || (r.models[m.model] = { cacheRead: 0, cacheWrite1h: 0, cacheWrite5m: 0, calls: 0, input: 0, output: 0, webSearch: 0 });
      let c5 = 0, c1 = 0;
      if (m.split) {
        c5 = m.cw5; c1 = m.cw1;
        const rem = Math.max(0, m.cwTotal - c5 - c1);
        if (ttl === '5m') c5 += rem; else c1 += rem;
      } else if (ttl === '5m') c5 = m.cwTotal; else c1 = m.cwTotal;
      mm.calls++; mm.input += m.input; mm.output += m.output; mm.cacheRead += m.cacheRead; mm.cacheWrite5m += c5; mm.cacheWrite1h += c1; mm.webSearch += m.web;
      r.first = Math.min(r.first, m.t0); r.last = Math.max(r.last, m.t1);
      const a = r.activity;
      for (const t of m.tools.values()) {
        bump(a.tools, san.text(t.name, 80));
        if (t.name === 'Workflow') a.workflows++;
        if (t.skill) bump(a.skills, san.text(t.skill, 80));
        if (t.sub) bump(a.subagents, san.text(t.sub, 60));
        if (t.read) bump(a.filesRead, san.path(t.read, ctx));
        if (t.read && t.whole && /\.java$/i.test(t.read)) a.wholeJavaReads = (a.wholeJavaReads || 0) + 1;
        if (t.edit) bump(a.filesEdited, san.path(t.edit, ctx));
        if (t.programs) for (const p of programNames(t.programs, san, ctx)) bump(a.programs, p);
      }
    }
    days.sort();
    if (f.st.instructions.length && days.length) {
      byDay.get(days[0]).activity.instructions = [...new Set(f.st.instructions.map(p => san.path(p, ctx)))].sort();
    }
    for (const day of days) {
      const r = byDay.get(day);
      const rec = {
        activity: r.activity, branch: f.st.branch ? san.text(f.st.branch, 100) : null, day,
        durationMs: Math.max(0, r.last - r.first), first: new Date(r.first).toISOString(), key: f.key, kind: f.recKind, label: f.label,
        last: new Date(r.last).toISOString(), models: r.models, phase: f.phase, repo, rule: f.attr.rule, runId: f.runId ? san.id(f.runId) : null,
        sessionId: f.sessionId, ticket: f.attr.ticket, type: f.type,
      };
      records.push(rec);
    }
    if (f.archonNodes && days.length) {
      const last = records[records.length - 1];
      const nodes = f.archonNodes;
      last.archon = {
        costUsd: Math.round(nodes.reduce((s, a) => s + a.node.costUsd, 0) * 1e6) / 1e6, durationMs: nodes.reduce((s, a) => s + a.node.durationMs, 0),
        node: san.text([...new Set(nodes.map(a => a.node.nodeId))].join('+'), 120), runId: san.id(nodes[0].run.id),
        sessionOrigin: san.text(nodes[0].node.sessionOrigin, 30), turns: nodes.reduce((s, a) => s + a.node.numTurns, 0),
        workflow: san.text(nodes[0].run.workflowName, 80),
      };
      const mcp = mcpStatus(cfg.artifacts, nodes[0].run.id);
      if (mcp) last.archon.mcp = mcp;
    }
  }
  return records;
}

// A build-feature run's ticket node writes mcp-status.txt (mcp-setup.sh) into the run's artifacts folder; its last
// "mcp: <contract server> up|down, codegraph up|down" line says which servers the nodes had (docs/mcp/plan.md, C1).
const MCP_LINE = /^mcp: (\S+) (up|down), codegraph (up|down)$/;
function mcpStatus(root, runId) {
  if (!root || !/^[A-Za-z0-9_-]{1,80}$/.test(String(runId))) return null;
  for (const owner of listDir(root)) for (const repo of listDir(path.join(root, owner))) {
    const text = readText(path.join(root, owner, repo, 'artifacts', 'runs', runId, 'mcp-status.txt'));
    if (text === null) continue;
    const m = text.split('\n').map(l => MCP_LINE.exec(l.trim())).filter(Boolean).pop();
    return m ? { codegraph: m[3], contract: m[2], server: m[1] } : null;
  }
  return null;
}

// ---------- ledger ----------
const recCalls = r => Object.values(r.models || {}).reduce((s, m) => s + (m.calls || 0), 0);

function loadLedger(dir) {
  const ledger = new Map();
  for (const m of listDir(dir).sort()) {
    if (!/^\d{4}-\d{2}$/.test(m)) continue;
    for (const f of listDir(path.join(dir, m)).sort()) {
      const mm = /^(\d{4}-\d{2}-\d{2})\.json$/.exec(f);
      const j = mm ? readJson(path.join(dir, m, f)) : null;
      if (j && j.records && typeof j.records === 'object') ledger.set(mm[1], j.records);
    }
  }
  return ledger;
}

// Per agent and day the record with more calls wins; a tie goes to the new one. Nothing is ever dropped.
function mergeLedger(ledger, records) {
  let added = 0, replaced = 0;
  for (const rec of records) {
    const day = ledger.get(rec.day) || {};
    ledger.set(rec.day, day);
    const old = day[rec.key];
    if (!old) { day[rec.key] = rec; added++; continue; }
    const win = recCalls(rec) >= recCalls(old) ? rec : old;
    const lose = win === rec ? old : rec;
    if (!win.archon && lose.archon) win.archon = lose.archon;
    // The run's artifacts may be gone by the next update: keep the MCP status the ledger already has.
    else if (win.archon && !win.archon.mcp && lose.archon && lose.archon.mcp) win.archon.mcp = lose.archon.mcp;
    if (win !== old) replaced++;
    day[rec.key] = win;
  }
  return { added, replaced };
}

// Archon's own cost of an agent is kept on its latest day only; overrides are applied to every record.
function settleLedger(ledger, cfg) {
  const latest = new Map();
  for (const day of [...ledger.keys()].sort()) for (const [k, r] of Object.entries(ledger.get(day))) if (r.archon) latest.set(k, day);
  for (const day of ledger.keys()) {
    for (const [k, r] of Object.entries(ledger.get(day))) {
      if (r.archon && latest.get(k) !== day) delete r.archon;
      const ov = cfg.overrides[r.key] || (r.runId && cfg.overrides[r.runId]) || (r.archon && cfg.overrides[r.archon.runId]) || cfg.overrides[r.sessionId];
      if (ov && (r.ticket !== ov || r.rule !== 'override')) { r.ticket = ov; r.rule = 'override'; }
    }
  }
}

// ---------- formatting ----------
const int = n => String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const money = n => n.toFixed(4);
const pct = (a, b) => (b > 0 ? (a / b * 100).toFixed(1) + '%' : '-');
function duration(ms) {
  const s = Math.round(ms / 1000);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  const p = v => String(v).padStart(2, '0');
  return h > 0 ? `${h}h ${p(m)}m ${p(x)}s` : m > 0 ? `${m}m ${p(x)}s` : `${x}s`;
}
const cell = s => String(s).replace(/\|/g, '\\|').replace(/\s+/g, ' ');
const row = cells => '| ' + cells.map(cell).join(' | ') + ' |';
const table = (head, align, rows) => [row(head), '|' + align.map(a => (a === 'r' ? '---:' : '---')).join('|') + '|', ...rows.map(row)];
const csv = v => { const s = String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const byCountThenName = o => Object.entries(o).sort((a, b) => b[1] - a[1] || cmp(a[0], b[0]));
function counts(o, cap) {
  const all = byCountThenName(o);
  const shown = all.slice(0, cap).map(([k, v]) => `${k} (${v})`);
  return shown.join(', ') + (all.length > cap ? `, and ${all.length - cap} more not listed` : '');
}

// ---------- aggregation ----------
const newAgg = () => ({ calls: 0, input: 0, cacheWrite: 0, cacheRead: 0, output: 0, usd: 0, unpriced: false, unpricedTokens: 0 });
const tokensOf = a => a.input + a.cacheWrite + a.cacheRead + a.output;
function addAgg(t, a) {
  t.calls += a.calls; t.input += a.input; t.cacheWrite += a.cacheWrite; t.cacheRead += a.cacheRead; t.output += a.output; t.usd += a.usd;
  t.unpriced = t.unpriced || a.unpriced; t.unpricedTokens += a.unpricedTokens;
  return t;
}
function modelAgg(pricing, model, m) {
  const c = costOf(pricing, model, m);
  const a = newAgg();
  a.calls = m.calls; a.input = m.input; a.output = m.output; a.cacheRead = m.cacheRead; a.cacheWrite = m.cacheWrite5m + m.cacheWrite1h; a.usd = c.usd;
  if (!c.priced) { a.unpriced = true; a.unpricedTokens = tokensOf(a); }
  return a;
}
function recAgg(pricing, rec) {
  const a = newAgg();
  for (const model of Object.keys(rec.models).sort()) addAgg(a, modelAgg(pricing, model, rec.models[model]));
  return a;
}
function groupBy(items, keyFn) {
  const g = new Map();
  for (const it of items) { const k = keyFn(it); let a = g.get(k); if (!a) g.set(k, a = []); a.push(it); }
  return g;
}

function context(ledger, cfg, titles) {
  const recs = [];
  for (const day of [...ledger.keys()].sort()) for (const key of Object.keys(ledger.get(day)).sort()) recs.push(ledger.get(day)[key]);
  const aggOf = new Map();
  for (const r of recs) aggOf.set(r, recAgg(cfg.pricing, r));
  const tickets = [...new Set(recs.map(r => r.ticket).filter(t => t !== COORD))].sort(cmpTickets);
  return { recs, aggOf, tickets, ticketSet: new Set(tickets), titles, pricing: cfg.pricing, eur: usd => money(usd / cfg.pricing.usdPerEur) };
}
const usdCell = (a) => money(a.usd) + (a.unpriced ? ' *' : '');
const eurCell = (cx, a) => cx.eur(a.usd) + (a.unpriced ? ' *' : '');
const ticketCell = (cx, t, base) => (t === COORD ? 'coordination (unattributed)' : cx.ticketSet.has(t) ? `[${t}]` : t);
function ticketLinks(cx, tickets, prefix) {
  return tickets.filter(t => t !== COORD && cx.ticketSet.has(t)).map(t => `[${t}]: ${prefix}${t}.md`);
}
function rateNote(cx) {
  const p = cx.pricing;
  return `EUR at ${p.usdPerEur} USD per EUR (${p.rateSource}, ${p.rateDate}). USD per million tokens from \`pricing.json\`; days are ${p.timeZone || 'Europe/Amsterdam'} days.`;
}
const totalsTable = (cx, a) => table(['Calls', 'Input', 'Cache write', 'Cache read', 'Output', 'Total tokens', 'USD', 'EUR'], ['r', 'r', 'r', 'r', 'r', 'r', 'r', 'r'],
  [[int(a.calls), int(a.input), int(a.cacheWrite), int(a.cacheRead), int(a.output), int(tokensOf(a)), usdCell(a), eurCell(cx, a)]]);

// ---------- daily report ----------
function renderDaily(cx, day, recs) {
  const total = newAgg();
  for (const r of recs) addAgg(total, cx.aggOf.get(r));
  const L = [`# Token and cost report ${day}`, '', rateNote(cx), '', '## Totals', '', ...totalsTable(cx, total), ''];
  if (total.unpriced) L.push(`Cost excludes unpriced model calls (${int(total.unpricedTokens)} tokens, see Unpriced models). A cost marked * is therefore a lower bound.`, '');

  const models = new Map();
  const unpriced = new Map();
  for (const r of recs) {
    for (const model of Object.keys(r.models).sort()) {
      const a = modelAgg(cx.pricing, model, r.models[model]);
      addAgg(models.get(model) || models.set(model, newAgg()).get(model), a);
      if (a.unpriced) addAgg(unpriced.get(model) || unpriced.set(model, newAgg()).get(model), a);
    }
  }
  L.push('## By model', '', ...table(['Model', 'Calls', 'Input', 'Cache write', 'Cache read', 'Output', 'USD', 'EUR'], ['l', 'r', 'r', 'r', 'r', 'r', 'r', 'r'],
    [...models].sort((a, b) => b[1].usd - a[1].usd || cmp(a[0], b[0])).map(([m, a]) =>
      [m, int(a.calls), int(a.input), int(a.cacheWrite), int(a.cacheRead), int(a.output), a.unpriced ? 'unpriced' : money(a.usd), a.unpriced ? 'unpriced' : cx.eur(a.usd)])), '');

  const group = (keyFn) => {
    const out = new Map();
    for (const r of recs) {
      const k = keyFn(r);
      const g = out.get(k) || out.set(k, { agg: newAgg(), keys: new Set() }).get(k);
      addAgg(g.agg, cx.aggOf.get(r));
      g.keys.add(r.key);
    }
    return out;
  };
  const kinds = group(r => r.kind);
  L.push('## By agent kind', '', ...table(['Kind', 'Agents', 'Calls', 'Tokens', 'USD', 'EUR'], ['l', 'r', 'r', 'r', 'r', 'r'],
    [...kinds].sort((a, b) => cmp(a[0], b[0])).map(([k, g]) => [k, int(g.keys.size), int(g.agg.calls), int(tokensOf(g.agg)), usdCell(g.agg), eurCell(cx, g.agg)])), '');

  const tickets = group(r => r.ticket);
  L.push('## By ticket', '', ...table(['Ticket', 'Agents', 'Calls', 'Tokens', 'USD', 'EUR'], ['l', 'r', 'r', 'r', 'r', 'r'],
    [...tickets].sort((a, b) => cmpTickets(a[0], b[0])).map(([t, g]) => [ticketCell(cx, t), int(g.keys.size), int(g.agg.calls), int(tokensOf(g.agg)), usdCell(g.agg), eurCell(cx, g.agg)])), '');

  const top = recs.slice().sort((a, b) => cx.aggOf.get(b).usd - cx.aggOf.get(a).usd || cmp(a.key, b.key)).slice(0, TOP_AGENTS);
  L.push(`## Top ${TOP_AGENTS} agents by cost`, '', ...table(['#', 'Agent', 'Kind', 'Ticket', 'Calls', 'Tokens', 'USD', 'EUR'], ['r', 'l', 'l', 'l', 'r', 'r', 'r', 'r'],
    top.map((r, i) => { const a = cx.aggOf.get(r); return [i + 1, r.label, r.kind, ticketCell(cx, r.ticket), int(a.calls), int(tokensOf(a)), usdCell(a), eurCell(cx, a)]; })), '');

  if (unpriced.size) {
    L.push('## Unpriced models', '', 'These models have no rate in `pricing.json`. Their tokens are shown here and are left out of every USD and EUR figure; add the rate and run the update again to price them.', '',
      ...table(['Model', 'Calls', 'Input', 'Cache write', 'Cache read', 'Output'], ['l', 'r', 'r', 'r', 'r', 'r'],
        [...unpriced].sort((a, b) => cmp(a[0], b[0])).map(([m, a]) => [m, int(a.calls), int(a.input), int(a.cacheWrite), int(a.cacheRead), int(a.output)])), '');
  }
  const links = ticketLinks(cx, [...tickets.keys()], '../ticket-token-reports/');
  if (links.length) L.push(...links.sort(), '');
  return L.join('\n').replace(/\n+$/, '\n');
}

// ---------- ticket report ----------
function mergeActivity(list) {
  const a = { filesEdited: {}, filesRead: {}, instructions: new Set(), programs: {}, skills: {}, subagents: {}, tools: {}, wholeJavaReads: 0, workflows: 0 };
  for (const r of list) {
    const x = r.activity || {};
    for (const f of ['filesEdited', 'filesRead', 'programs', 'skills', 'subagents', 'tools']) for (const [k, v] of Object.entries(x[f] || {})) bump(a[f], k, v);
    for (const p of x.instructions || []) a.instructions.add(p);
    a.workflows += x.workflows || 0;
    a.wholeJavaReads += x.wholeJavaReads || 0;
  }
  a.instructions = [...a.instructions].sort();
  return a;
}

function agentsOfTicket(cx, recs) {
  const out = [];
  for (const [key, list] of groupBy(recs, r => r.key)) {
    const first = list[0];
    const agg = newAgg();
    const models = {};
    let ms = 0;
    let archon = null;
    for (const r of list) {
      addAgg(agg, cx.aggOf.get(r));
      for (const [m, u] of Object.entries(r.models)) bump(models, m, u.calls);
      ms += r.durationMs || 0;
      if (r.archon) archon = r.archon;
    }
    out.push({ key, kind: first.kind, label: first.label, type: first.type || first.phase || '', agg, models: Object.keys(models).sort(), ms: archon && archon.durationMs ? archon.durationMs : ms, archon,
      activity: mergeActivity(list), days: [...new Set(list.map(r => r.day))].sort() });
  }
  return out.sort((a, b) => b.agg.usd - a.agg.usd || cmp(a.key, b.key));
}

function activityLines(act) {
  const L = [];
  const tools = {}, mcp = {};
  for (const [k, v] of Object.entries(act.tools)) (k.startsWith('mcp__') ? mcp : tools)[k] = v;
  if (Object.keys(act.skills).length) L.push(`- Skills: ${counts(act.skills, LIST_CAP)}`);
  if (act.instructions.length) L.push(`- Instruction files: ${act.instructions.slice(0, LIST_CAP).join(', ')}${act.instructions.length > LIST_CAP ? `, and ${act.instructions.length - LIST_CAP} more not listed` : ''}`);
  if (Object.keys(tools).length) L.push(`- Tools: ${counts(tools, LIST_CAP)}`);
  if (Object.keys(mcp).length) L.push(`- MCP tools: ${counts(mcp, LIST_CAP)}`);
  if (Object.keys(act.filesRead).length) L.push(`- Files read: ${counts(act.filesRead, FILE_CAP)}`);
  if (Object.keys(act.filesEdited).length) L.push(`- Files edited: ${counts(act.filesEdited, FILE_CAP)}`);
  if (Object.keys(act.programs).length) L.push(`- Programs: ${counts(act.programs, LIST_CAP)}`);
  if (Object.keys(act.subagents).length) L.push(`- Subagents spawned: ${counts(act.subagents, LIST_CAP)}`);
  if (act.workflows) L.push(`- Workflows spawned: ${act.workflows}`);
  if (act.wholeJavaReads) L.push(`- Whole Java files read (no offset): ${act.wholeJavaReads}`);
  return L;
}

function renderTicket(cx, ticket, recs) {
  const title = cx.titles.get(ticket);
  const total = newAgg();
  for (const r of recs) addAgg(total, cx.aggOf.get(r));
  const L = [`# ${ticket}${title ? ': ' + title : ''}`, '', rateNote(cx), '', '## Totals', '', ...totalsTable(cx, total), ''];
  if (total.unpriced) L.push(`Cost excludes unpriced model calls (${int(total.unpricedTokens)} tokens), so a cost marked * is a lower bound.`, '');
  const days = groupBy(recs, r => r.day);
  L.push('## Days', '', ...table(['Day', 'Agents', 'Calls', 'Tokens', 'USD', 'EUR'], ['l', 'r', 'r', 'r', 'r', 'r'],
    [...days].sort((a, b) => cmp(a[0], b[0])).map(([d, list]) => {
      const a = newAgg();
      for (const r of list) addAgg(a, cx.aggOf.get(r));
      return [`[${d}]`, int(new Set(list.map(r => r.key)).size), int(a.calls), int(tokensOf(a)), usdCell(a), eurCell(cx, a)];
    })), '');
  const agents = agentsOfTicket(cx, recs);
  L.push('## Agents', '', ...table(['Kind', 'Agent', 'Type or phase', 'Model', 'Calls', 'Tokens', 'USD', 'Duration', 'Archon USD'], ['l', 'l', 'l', 'l', 'r', 'r', 'r', 'r', 'r'],
    agents.map(a => [a.kind, a.label, a.type, a.models.join(', '), int(a.agg.calls), int(tokensOf(a.agg)), usdCell(a.agg), duration(a.ms), a.archon ? money(a.archon.costUsd) : ''])), '');
  const runs = new Map();
  for (const a of agents) if (a.archon && a.archon.mcp) runs.set(a.archon.runId, a.archon.mcp);
  if (runs.size) {
    L.push('## MCP servers', '', 'What mcp-setup.sh found in each run worktree; a node of a run with a server down worked without its tools.', '',
      ...table(['Run', SERVER, 'codegraph'], ['l', 'l', 'l'], [...runs].sort((a, b) => cmp(a[0], b[0])).map(([id, m]) => [id, m.contract, m.codegraph])), '');
  }
  L.push('## What each agent did', '');
  for (const a of agents) {
    L.push(`### ${a.label.replace(/\s+/g, ' ')} (${a.kind})`, '',
      `- Model: ${a.models.join(', ')}`,
      `- Tokens: ${int(tokensOf(a.agg))} (input ${int(a.agg.input)}, cache write ${int(a.agg.cacheWrite)}, cache read ${int(a.agg.cacheRead)}, output ${int(a.agg.output)}) in ${int(a.agg.calls)} calls; cost ${usdCell(a.agg)} USD, ${eurCell(cx, a.agg)} EUR`,
      ...activityLines(a.activity), '');
  }
  L.push(...[...days.keys()].sort().map(d => `[${d}]: ../daily-token-reports/${d}.md`), '');
  return L.join('\n').replace(/\n+$/, '\n');
}

function renderActionsCsv(cx, recs) {
  const L = ['agent,kind,model,action,name,count,tokens,usd'];
  for (const a of agentsOfTicket(cx, recs)) {
    const who = csv(`${a.label} (${a.key.slice(0, 8)})`);
    const models = csv(a.models.join('+'));
    const perModel = new Map();
    for (const r of recs.filter(x => x.key === a.key)) {
      for (const m of Object.keys(r.models).sort()) addAgg(perModel.get(m) || perModel.set(m, newAgg()).get(m), modelAgg(cx.pricing, m, r.models[m]));
    }
    for (const m of [...perModel.keys()].sort()) {
      const g = perModel.get(m);
      L.push([who, a.kind, csv(m), 'usage', 'calls', g.calls, tokensOf(g), g.unpriced ? '' : g.usd.toFixed(6)].join(','));
    }
    const act = a.activity;
    const emit = (action, obj) => { for (const [k, v] of byCountThenName(obj)) L.push([who, a.kind, models, action, csv(k), v, '', ''].join(',')); };
    emit('tool', act.tools);
    emit('skill', act.skills);
    emit('subagent', act.subagents);
    if (act.workflows) L.push([who, a.kind, models, 'workflow', 'Workflow', act.workflows, '', ''].join(','));
    for (const p of act.instructions) L.push([who, a.kind, models, 'instruction', csv(p), 1, '', ''].join(','));
    emit('file-read', act.filesRead);
    emit('file-edit', act.filesEdited);
    emit('program', act.programs);
  }
  return L.join('\n') + '\n';
}

// ---------- the per-agent report ----------
function renderAgents(cx) {
  const L = ['# Agents', '',
    'What each kind of agent, each workflow phase and each Archon node cost, over every day in the ledger. An invocation is one agent (one transcript); the average is USD per invocation. Cache-read share is cache read over input, cache read and cache write.', '',
    rateNote(cx), ''];
  const section = (title, keyFn, recs, archonColumn) => {
    const groups = new Map();
    for (const r of recs) {
      const k = keyFn(r);
      const g = groups.get(k) || groups.set(k, { agg: newAgg(), keys: new Set(), tools: {}, skills: {}, archon: 0 }).get(k);
      addAgg(g.agg, cx.aggOf.get(r));
      g.keys.add(r.key);
      for (const [t, v] of Object.entries((r.activity || {}).tools || {})) bump(g.tools, t, v);
      for (const [s, v] of Object.entries((r.activity || {}).skills || {})) bump(g.skills, s, v);
      if (r.archon) g.archon += r.archon.costUsd;
    }
    const head = ['Name', 'Invocations', 'Calls', 'Tokens', 'USD', 'Avg USD per invocation', 'Cache-read share', 'Top tools', 'Top skills'];
    const align = ['l', 'r', 'r', 'r', 'r', 'r', 'r', 'l', 'l'];
    if (archonColumn) { head.push('Archon USD'); align.push('r'); }
    L.push(`## ${title}`, '');
    if (!groups.size) { L.push('None yet.', ''); return; }
    L.push(...table(head, align, [...groups].sort((a, b) => b[1].agg.usd - a[1].agg.usd || cmp(a[0], b[0])).map(([k, g]) => {
      const a = g.agg;
      const cells = [k, int(g.keys.size), int(a.calls), int(tokensOf(a)), usdCell(a), money(a.usd / g.keys.size), pct(a.cacheRead, a.input + a.cacheRead + a.cacheWrite),
        counts(g.tools, 3), counts(g.skills, 3)];
      if (archonColumn) cells.push(money(g.archon));
      return cells;
    })), '');
  };
  section('By agent kind and type', r => (r.type ? `${r.kind} / ${r.type}` : r.kind), cx.recs, false);
  toolChoice(L, cx);
  section('By workflow phase or label', r => r.phase || r.label, cx.recs.filter(r => r.kind === 'workflow-agent'), false);
  section('By Archon workflow and node', r => r.label, cx.recs.filter(r => r.kind === 'archon-node'), true);
  return L.join('\n').replace(/\n+$/, '\n');
}

// Per agent kind: how often it asked the MCP servers, and how often it searched or read by hand (docs/mcp/plan.md, C6).
// An Archon node gets a row of its own (archon-node / build-feature/explore), so explore and plan can be told apart (C8).
const CONTRACT_READ = /(^|:)contract\//;
const BASH_SEARCH = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag', 'find', 'sed', 'awk', 'cat', 'head', 'tail', 'less']);
function toolChoice(L, cx) {
  const groups = new Map();
  for (const r of cx.recs) {
    const k = r.kind === 'archon-node' ? `${r.kind} / ${r.label}` : r.type ? `${r.kind} / ${r.type}` : r.kind;
    const g = groups.get(k) || groups.set(k, { agg: newAgg(), keys: new Set(), tickets: new Set(), server: 0, codegraph: 0, grep: 0, glob: 0, bash: 0, contract: 0, whole: 0 }).get(k);
    const act = r.activity || {};
    addAgg(g.agg, cx.aggOf.get(r));
    g.keys.add(r.key);
    if (r.ticket && r.ticket !== COORD) g.tickets.add(r.ticket);
    for (const [t, v] of Object.entries(act.tools || {})) {
      if (t.startsWith(`mcp__${SERVER}__`)) g.server += v;
      else if (t.startsWith('mcp__codegraph__')) g.codegraph += v;
      else if (t === 'Grep') g.grep += v;
      else if (t === 'Glob') g.glob += v;
    }
    for (const [p, v] of Object.entries(act.programs || {})) if (BASH_SEARCH.has(p)) g.bash += v;
    for (const [f, v] of Object.entries(act.filesRead || {})) if (CONTRACT_READ.test(f)) g.contract += v;
    g.whole += act.wholeJavaReads || 0;
  }
  L.push('## Tool choice by agent kind and type', '',
    `Calls to the ${SERVER} and CodeGraph MCP servers against searching and reading by hand. Each Archon node has its own row. Bash searches counts grep, sed, cat, find and the like in Bash commands, a pipe stage included. A contract read is a Read of contract/; a whole Java read is a Read of a .java file with no offset or limit. Tokens per ticket is over the tickets the kind worked on.`, '');
  if (!groups.size) { L.push('None yet.', ''); return; }
  L.push(...table(['Name', 'Invocations', SERVER, 'codegraph', 'Grep', 'Glob', 'Bash searches', 'Contract reads', 'Whole Java reads', 'Tokens per ticket'],
    ['l', 'r', 'r', 'r', 'r', 'r', 'r', 'r', 'r', 'r'],
    [...groups].sort((a, b) => b[1].agg.usd - a[1].agg.usd || cmp(a[0], b[0])).map(([k, g]) => [k, int(g.keys.size), int(g.server), int(g.codegraph),
      int(g.grep), int(g.glob), int(g.bash), int(g.contract), int(g.whole), g.tickets.size ? int(tokensOf(g.agg) / g.tickets.size) : ''])), '');
}

// ---------- writing ----------
function writeIfChanged(file, content, stats) {
  let old = null;
  try { old = fs.readFileSync(file, 'utf8'); } catch { /* new file */ }
  if (old === content) return;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  stats.changed++;
}

function removeStale(dir, pattern, keep, stats) {
  for (const name of listDir(dir)) {
    if (pattern.test(name) && !keep.has(name)) { try { fs.unlinkSync(path.join(dir, name)); stats.changed++; } catch { /* already gone */ } }
  }
}

// ---------- update ----------
function update(opts) {
  const cfg = loadConfig(opts);
  const ledgerDir = path.join(cfg.out, 'ledger');
  const ledger = loadLedger(ledgerDir);
  const since = opts.incremental ? [...ledger.keys()].sort().pop() || null : null;
  const found = discover(cfg.projects, cfg.include);
  const projectsSkipped = found.skipped;
  let files = found.files;
  if (since) {
    const recent = f => { try { return cfg.dayOf(fs.statSync(f.file).mtimeMs) >= since; } catch { return false; } };
    const sessions = new Set(files.filter(recent).map(f => f.sessionId));
    files = files.filter(f => recent(f) || (f.kind === 'top' && sessions.has(f.sessionId)));
  }
  if (!files.length) warn(`no transcripts under ${isDir(cfg.projects) ? 'the projects dir' : 'a missing projects dir'}; the ledger is only re-rendered`);
  for (const f of files) f.st = scanTranscript(f);
  const live = files.filter(f => f.st.msgs.size > 0);
  for (const f of live) f.cwd = f.st.cwd;
  // sub-agents run where their session does
  const topCwd = new Map(live.filter(f => f.kind === 'top').map(f => [f.key, f.cwd]));
  for (const f of live) if (f.kind !== 'top' && !f.cwd) f.cwd = topCwd.get(f.sessionId) || null;

  const runs = loadArchon(cfg);
  const arch = matchArchon(runs, live);
  if (arch.unmatched) warn(`${arch.unmatched} Archon node(s) have no transcript here and are ignored`);

  const journals = loadJournals(live);
  const san = makeSanitizer(cfg, [...live.map(f => f.cwd), ...runs.map(r => r.workingPath)]);
  describeFiles(live, journals, cfg, san);

  const sharedFile = path.join(cfg.out, 'ledger', 'shared-messages.json');
  const prevShared = (readJson(sharedFile) || {}).owners || {};
  const owners = assignOwners(live, prevShared);
  const records = buildRecords(live, cfg, san);

  const merged = mergeLedger(ledger, records);
  settleLedger(ledger, cfg);

  const stats = { changed: 0 };
  for (const day of [...ledger.keys()].sort()) writeIfChanged(path.join(ledgerDir, day.slice(0, 7), day + '.json'), stable({ day, records: ledger.get(day), schema: SCHEMA }), stats);
  writeIfChanged(sharedFile, stable({ owners, schema: SCHEMA }), stats);

  const titles = loadTitles(cfg.repo);
  const cx = context(ledger, cfg, titles);
  const days = [...ledger.keys()].sort();
  const dailyDir = path.join(cfg.out, 'daily-token-reports');
  const ticketDir = path.join(cfg.out, 'ticket-token-reports');
  const keepDaily = new Set(), keepTicket = new Set();
  const shown = day => !since || day >= since;
  for (const day of days) {
    keepDaily.add(day + '.md');
    if (!shown(day)) continue;
    writeIfChanged(path.join(dailyDir, day + '.md'), renderDaily(cx, day, cx.recs.filter(r => r.day === day)), stats);
  }
  for (const t of cx.tickets) {
    const recs = cx.recs.filter(r => r.ticket === t);
    keepTicket.add(t + '.md'); keepTicket.add(t + '.actions.csv');
    if (!recs.some(r => shown(r.day))) continue;
    writeIfChanged(path.join(ticketDir, t + '.md'), renderTicket(cx, t, recs), stats);
    writeIfChanged(path.join(ticketDir, t + '.actions.csv'), renderActionsCsv(cx, recs), stats);
  }
  if (days.length) writeIfChanged(path.join(cfg.out, 'agents.md'), renderAgents(cx), stats);
  if (!since) {
    removeStale(dailyDir, /^\d{4}-\d{2}-\d{2}\.md$/, keepDaily, stats);
    removeStale(ticketDir, /^TASK-\d+(?:\.\d+)?\.(?:md|actions\.csv)$/, keepTicket, stats);
  }

  const unpricedModels = new Set();
  for (const r of cx.recs) for (const m of Object.keys(r.models)) if (!rateFor(cfg.pricing, m)) unpricedModels.add(m);
  if (unpricedModels.size) warn(`unpriced models (tokens listed, cost left out): ${[...unpricedModels].sort().join(', ')}`);
  process.stdout.write(JSON.stringify({
    latestDay: days.length ? days[days.length - 1] : null, days: days.length, agents: new Set(cx.recs.map(r => r.key)).size, records: cx.recs.length,
    calls: cx.recs.reduce((s, r) => s + recCalls(r), 0), tickets: cx.tickets.length, transcripts: live.length, projectsSkipped, recordsAdded: merged.added, recordsReplaced: merged.replaced,
    archonNodesMatched: arch.matched, archonNodesIgnored: arch.unmatched, unpricedModels: [...unpricedModels].sort(), filesChanged: stats.changed, since,
  }) + '\n');
}

function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === 'update') return update(parseArgs(rest));
  process.stderr.write('usage: tokenomics.js update [--projects <dir>] [--archon-runs <file> | --archon-db <path>] [--out <dir>] [--home <dir>] [--repo <dir>] [--pricing <file>] [--incremental]\n');
  process.exit(2);
}

if (require.main === module) main(process.argv.slice(2));
module.exports = { parseCommand, programNames, splitSegments, makeSanitizer, maskSecrets, costOf };
