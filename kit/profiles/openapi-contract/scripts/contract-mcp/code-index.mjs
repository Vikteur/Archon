// Where an operation of the contract lives in the Java code: its generated interface method, the controller that
// implements it, whether that method is live or a stub, what it calls and the tests that reach it. The `where` tool of
// server.mjs and .archon/scripts/plan-context.sh both call it. It reads the tree on every call and stores nothing, so an
// answer never lags behind an edit. The call chain comes from CodeGraph when the checkout has a `.codegraph/` index and
// the CLI runs, and from the code's own conventions otherwise; the answer says which (`via`).
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { operations } from '../contract-agent-readiness/read.mjs';

import { kitConfig } from './kit-config.mjs';

// Where the generated *Api interfaces live: `contract.generated_dir` of .archon/kit.yaml (this repo's own folder by default).
export const generatedDir = (root) => kitConfig(root)('contract.generated_dir');
const MAX_CHARS = 4000;
const SKIP_DIRS = new Set(['build', 'node_modules', '.git', '.gradle', '.codegraph', 'contract', 'out']);

// The generator's name for a tag's interface: each word capitalised, an all-caps word lowered after its first letter
// (`DJ` → `DjApi`).
export const apiName = (tag) => `${String(tag).split(/[^A-Za-z0-9]+/).filter(Boolean)
  .map((w) => w[0].toUpperCase() + (w === w.toUpperCase() ? w.slice(1).toLowerCase() : w.slice(1))).join('')}Api`;

// Every .java file under <root>/<module>/src/<kind>/java, as paths relative to root.
function javaFiles(root, kind) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walk(join(dir, e.name)); }
      else if (e.name.endsWith('.java')) out.push(relative(root, join(dir, e.name)));
    }
  };
  for (const m of readdirSync(root, { withFileTypes: true })) {
    if (m.isDirectory() && !SKIP_DIRS.has(m.name)) walk(join(root, m.name, 'src', kind, 'java'));
  }
  return out.sort();
}

const lineOf = (text, index) => text.slice(0, index).split('\n').length;

// The body of the block that opens at the first `{` at or after `from`, without its braces. Braces inside string and
// char literals and comments are skipped.
function blockAt(text, from) {
  const open = text.indexOf('{', from);
  if (open < 0) return { body: '', end: from };
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '"' || c === "'") { for (i++; i < text.length && text[i] !== c; i++) if (text[i] === '\\') i++; continue; }
    if (c === '/' && text[i + 1] === '/') { i = text.indexOf('\n', i); if (i < 0) break; continue; }
    if (c === '/' && text[i + 1] === '*') { i = text.indexOf('*/', i + 2); if (i < 0) break; i++; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return { body: text.slice(open + 1, i), end: i };
  }
  return { body: text.slice(open + 1), end: text.length };
}

// The generated interfaces: operationId → { api, file, line, httpMethod, path }.
export function generatedMethods(root) {
  const GENERATED = generatedDir(root);
  const dir = join(root, GENERATED);
  const out = new Map();
  if (!existsSync(dir)) return null;
  for (const f of readdirSync(dir).filter((n) => n.endsWith('Api.java'))) {
    const text = readFileSync(join(dir, f), 'utf8');
    const api = f.replace(/\.java$/, '');
    // The class's @Path, then per method its verb, its own @Path when it has one, and its name.
    const base = /@Path\("([^"]*)"\)\s*(?:@[\s\S]*?)?public\s+interface/.exec(text)?.[1] ?? '';
    const re = /@(GET|PUT|POST|PATCH|DELETE)\s+((?:@[\w.]+(?:\([^)]*\))?\s+)*)[\w<>\[\], ?.]+\s+(\w+)\(/g;
    for (let m; (m = re.exec(text));) {
      const own = /@Path\("([^"]*)"\)/.exec(m[2])?.[1] ?? '';
      out.set(m[3], { api, file: `${GENERATED}/${f}`, line: lineOf(text, m.index + m[0].length), httpMethod: m[1], path: base + own });
    }
  }
  return out;
}

// Every hand-written class in src/main: its file, and for a class that implements generated interfaces, which ones.
function mainClasses(root) {
  const classes = new Map();
  for (const file of javaFiles(root, 'main')) {
    const text = readFileSync(join(root, file), 'utf8');
    const decl = /\b(?:class|record|interface|enum)\s+(\w+)[^{]*?(?:\bimplements\s+([^{]+))?\{/.exec(text);
    if (!decl) continue;
    const apis = (decl[2] ?? '').split(',').map((s) => s.trim().replace(/<.*$/, '')).filter((s) => /Api$/.test(s));
    classes.set(decl[1], { file, text, apis });
  }
  return classes;
}

// One controller method: its line, whether it is a stub, and its body.
function controllerMethod(cls, name) {
  const re = new RegExp(`((?:\\s*@[\\w.]+(?:\\([^)]*\\))?)*)\\s*public\\s+[\\w<>\\[\\], ?.]+\\s+${name}\\s*\\(`);
  const m = re.exec(cls.text);
  if (!m) return null;
  const at = m.index + m[0].length;
  const { body } = blockAt(cls.text, at);
  const stub = /@DenyAll\b/.test(m[1]) && /^\s*throw\s+new\s+UnsupportedOperationException\(\s*\)\s*;\s*$/.test(body);
  return { line: lineOf(cls.text, at), stub, body };
}

// The classes a method body calls, by the code's conventions: the `private final` fields it calls, and the classes
// it calls a static method on (a mapper's `map`).
function conventionCallees(cls, body, classes) {
  const fields = new Map();
  for (const m of cls.text.matchAll(/private\s+final\s+([\w<>.]+)\s+(\w+)\s*;/g)) fields.set(m[2], m[1].replace(/<.*$/, ''));
  const names = new Set();
  for (const m of body.matchAll(/\b(\w+)\s*\.\s*(\w+)\s*\(/g)) {
    if (fields.has(m[1])) names.add(fields.get(m[1]));
    else if (/^[A-Z]/.test(m[1]) && classes.has(m[1])) names.add(m[1]);
  }
  return [...names].filter((n) => classes.has(n)).map((n) => ({ name: n, file: classes.get(n).file }));
}

// The call chain from CodeGraph: the methods the controller method calls, and the test files that call those.
// Null when there is no index or the CLI fails, so the caller falls back to the conventions.
function codegraphCallees(root, controller, method) {
  if (!existsSync(join(root, '.codegraph'))) return null;
  const run = (...args) => JSON.parse(execFileSync('codegraph', [...args, '--json'], {
    cwd: root, encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'ignore'],
  }));
  try {
    const callees = (run('callees', `${controller}.${method}`).definitions?.[0]?.callees ?? [])
      .filter((c) => c.filePath.includes('/src/main/'))
      .map((c) => ({ name: `${c.filePath.replace(/^.*\//, '').replace(/\.java$/, '')}.${c.name}`, file: c.filePath, line: c.startLine }));
    const tests = new Set();
    for (const c of callees) {
      try {
        for (const d of run('callers', c.name).definitions ?? []) {
          for (const k of d.callers ?? []) if (k.filePath.includes('/src/test/')) tests.add(k.filePath);
        }
      } catch { /* a callee without callers is no failure */ }
    }
    return { callees, unitTests: [...tests].sort() };
  } catch {
    return null;
  }
}

// A regex for a string literal in a test that names this path: the literal text between the parameters must match,
// and a parameter may be written out, left as `{name}`, or concatenated (`"/api/weddings/" + id + "/people"`).
export function pathPattern(path) {
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  const param = String.raw`(?:[^"/\s]+|"\s*\+\s*[^+;\n]+?(?:\+\s*"|(?=\s*[),;])))`;
  const parts = path.split(/\{[^}]+\}/).map(esc);
  return new RegExp(`"${parts.join(param)}(?:"|\\?|(?=\\s*[),;]))`);
}

// The test files in src/test that send this method to this path (`http`), and those that only name the operationId
// (`mentions`), each with the line of its first hit.
function testsFor(root, testFiles, op) {
  const pat = pathPattern(op.path);
  const call = new RegExp(`\\.${op.method.toLowerCase()}\\s*\\(\\s*$`);
  const word = new RegExp(`\\b${op.id}\\b`);
  const http = []; const mentions = [];
  for (const file of testFiles) {
    const text = readFileSync(join(root, file), 'utf8');
    const lines = text.split('\n');
    const hit = lines.findIndex((l) => { const m = pat.exec(l); return m && call.test(l.slice(0, m.index)); });
    if (hit >= 0) { http.push(`${file}:${hit + 1}`); continue; }
    const named = lines.findIndex((l) => word.test(l));
    if (named >= 0) mentions.push(`${file}:${named + 1}`);
  }
  return { http, mentions };
}

// The checkout's contract pin (gradle.properties), when it is a version tag.
export function pinnedVersion(root) {
  try {
    const key = kitConfig(root)('contract.tag_key').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const m = new RegExp(`^${key}=v(\\d+\\.\\d+\\.\\d+)\\s*$`, 'm').exec(readFileSync(join(root, 'gradle.properties'), 'utf8'));
    return m ? m[1] : null;
  } catch { return null; }
}

const cap = (list, n) => (list.length > n ? [...list.slice(0, n), `… ${list.length - n} more`] : list);

// codeIndex(root, spec) → { where(operationId), list({ tag } | { status }) }.
export function codeIndex(root, spec) {
  const ops = new Map(operations(spec).map((o) => [o.id, o]));
  const scan = () => {
    const generated = generatedMethods(root);
    const classes = mainClasses(root);
    const byApi = new Map();
    for (const [name, c] of classes) for (const a of c.apis) byApi.set(a, [...(byApi.get(a) ?? []), name]);
    return { generated, classes, byApi };
  };

  // The short facts of one operation: interface, controller, status.
  const locate = (o, { generated, classes, byApi }) => {
    const g = generated?.get(o.id);
    const api = g?.api ?? apiName(o.tags[0] ?? 'Default');
    const controllers = (byApi.get(api) ?? []).filter((c) => controllerMethod(classes.get(c), o.id));
    const controller = controllers[0];
    const m = controller ? controllerMethod(classes.get(controller), o.id) : null;
    return {
      api, g, controller, m, also: controllers.slice(1),
      status: !m ? 'none' : m.stub ? 'stub' : 'live',
    };
  };

  const notes = (generated) => {
    const out = [];
    if (!generated) out.push(`generated sources missing (${generatedDir(root)}); the interface name comes from the naming rule. Make them with the openApiGenerate task of shared-adapter.`);
    const pin = pinnedVersion(root);
    if (pin && pin !== spec.info?.version) out.push(`gradle.properties pins contract v${pin}, the server loaded v${spec.info?.version}: the code follows the pin.`);
    return out;
  };

  function where(operationId) {
    const o = ops.get(operationId);
    if (!o) return null;
    const s = scan();
    const { api, g, controller, m, also, status } = locate(o, s);
    const cls = controller ? s.classes.get(controller) : null;
    const answer = {
      operationId: o.id, tag: o.tags[0] ?? null, method: o.method, path: o.path, status,
      interface: g ? `${api}.${o.id} ${g.file}:${g.line}` : `${api}.${o.id} (from the naming rule)`,
      controller: cls ? `${controller}.${o.id} ${cls.file}:${m.line}` : null,
    };
    if (also.length) answer.alsoImplementedBy = also;
    if (status === 'none') {
      answer.hint = `No class in */src/main implements ${api} with ${o.id}. A controller implements ${api} in its module's adapter/controller package.`;
    }
    if (status === 'live') {
      const cg = codegraphCallees(root, controller, o.id);
      if (cg) Object.assign(answer, { via: 'codegraph', calls: cap(cg.callees.map((c) => `${c.name} ${c.file}:${c.line}`), 12), unitTests: cap(cg.unitTests, 10) });
      else {
        const callees = conventionCallees(cls, m.body, s.classes);
        const tests = new Set(callees.map((c) => `${c.name}Test`));
        answer.via = 'conventions';
        answer.calls = cap(callees.map((c) => `${c.name} ${c.file}`), 12);
        answer.unitTests = cap(javaFiles(root, 'test').filter((f) => tests.has(f.replace(/^.*\//, '').replace(/\.java$/, ''))), 10);
      }
    }
    const t = testsFor(root, javaFiles(root, 'test'), o);
    answer.httpTests = cap(t.http, 10);
    answer.mentions = cap(t.mentions, 8);
    const n = notes(s.generated);
    if (n.length) answer.notes = n;
    answer.next = status === 'live'
      ? 'codegraph_impact on the controller method for what a change reaches; schema for a body\'s fields'
      : 'read for the operation; schema for its body\'s fields';
    for (const k of ['mentions', 'httpTests', 'unitTests', 'calls']) {
      while (JSON.stringify(answer).length > MAX_CHARS && answer[k]?.length > 1) answer[k] = cap(answer[k].slice(0, -1), answer[k].length - 2);
    }
    return answer;
  }

  function list({ tag, status } = {}) {
    const s = scan();
    const out = [];
    for (const o of ops.values()) {
      if (tag && !o.tags.some((t) => t.toLowerCase() === String(tag).toLowerCase())) continue;
      const l = locate(o, s);
      if (status && l.status !== status) continue;
      out.push({ operationId: o.id, status: l.status, controller: l.controller ? `${s.classes.get(l.controller).file}:${l.m.line}` : null });
    }
    return out;
  }

  return { where, list };
}
