// Pointer check: do proposed leaf changes still apply to a contract as it is? Read-only: it changes no file. For each
// change it reads the value at the change's path and says:
//   replace, remove: same (the value is `old`), diff (the value is something else) or missing (nothing at the path);
//   add:             absent (nothing at the path yet, as it should be) or present (something is there already).
// A proposal whose text has moved on under it is a red check instead of a silent overwrite.
// Usage: node pointer-check.mjs --spec <openapi.yaml|json> --changes <changes.json> [--json]
//   --changes: { "changes": [{ "op": "replace"|"remove"|"add", "path": ["paths", "/a", ...] | "/paths/~1a/...",
//              "old"?: <value> }, ...] } or the bare array; `old` is required for replace and remove, and two values are
//              the same when their JSON is.
//   --json:    prints every change with its status as JSON instead of the summary.
// Exits 1 when a change is diff, missing or present; 2 on a usage error or a change it cannot read.
import { readFileSync } from 'node:fs';
import { parse } from 'yaml';

const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); if (i < 0) return undefined; const v = args[i + 1]; args.splice(i, 2); return v; };
const specPath = flag('--spec');
const changesPath = flag('--changes');
const asJson = args.includes('--json');
if (asJson) args.splice(args.indexOf('--json'), 1);
const usage = (why) => {
  if (why) console.error(`[pointer-check] ${why}`);
  console.error('usage: node pointer-check.mjs --spec <openapi.yaml|json> --changes <changes.json> [--json]');
  process.exit(2);
};
if (!specPath || !changesPath || args.length) usage();

const spec = parse(readFileSync(specPath, 'utf8'));
const loaded = JSON.parse(readFileSync(changesPath, 'utf8'));
const changes = Array.isArray(loaded) ? loaded : loaded?.changes;
if (!Array.isArray(changes)) usage(`no changes array in ${changesPath}`);

// A path is an array of keys and indices, or a JSON pointer ("/paths/~1notes/get"; ~1 is "/", ~0 is "~").
const keysOf = (p) => (Array.isArray(p) ? p.map(String)
  : p.split('/').slice(1).map((k) => k.replace(/~1/g, '/').replace(/~0/g, '~')));
function at(doc, keys) {
  let node = doc;
  for (const k of keys) {
    if (node === null || typeof node !== 'object' || !Object.hasOwn(node, k)) return { found: false };
    node = node[k];
  }
  return { found: true, value: node };
}

const results = changes.map((c, i) => {
  if (!['replace', 'remove', 'add'].includes(c?.op) || !(Array.isArray(c.path) || typeof c.path === 'string')) {
    usage(`change ${i} has no op replace|remove|add or no path`);
  }
  if (c.op !== 'add' && !Object.hasOwn(c, 'old')) usage(`change ${i} (${c.op}) has no old value to compare`);
  const { found, value } = at(spec, keysOf(c.path));
  const status = c.op === 'add' ? (found ? 'present' : 'absent')
    : !found ? 'missing' : JSON.stringify(value) === JSON.stringify(c.old) ? 'same' : 'diff';
  return { index: i, op: c.op, path: c.path, ...(c.operationId ? { operationId: c.operationId } : {}), status };
});

const counts = Object.fromEntries(['same', 'diff', 'missing', 'absent', 'present']
  .map((s) => [s, results.filter((r) => r.status === s).length]));
const bad = results.filter((r) => ['diff', 'missing', 'present'].includes(r.status));
if (asJson) {
  process.stdout.write(`${JSON.stringify({ spec: specPath, changes: changesPath, counts, results }, null, 2)}\n`);
} else {
  console.log(`[pointer-check] ${results.length} changes: ${counts.same} same, ${counts.diff} diff, ${counts.missing} `
    + `missing; ${counts.absent} add absent, ${counts.present} add present`);
  for (const r of bad) {
    const where = Array.isArray(r.path) ? `/${r.path.map((k) => String(k).replace(/~/g, '~0').replace(/\//g, '~1')).join('/')}` : r.path;
    console.log(`[pointer-check] ${r.status}: change ${r.index} (${r.op}) ${where}`);
  }
}
process.exit(bad.length ? 1 : 0);
