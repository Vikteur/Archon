// What an MCP server with `search` and `read` sends of an OpenAPI contract: one definition of an operation, its first
// paragraph, a word and the `read` answer, shared by check.mjs, findability.mjs and the measuring scripts, so that a
// checker finding and a measured number never disagree on what an agent sees. Pure functions over a parsed spec; the
// caller parses the file.

export const METHODS = ['get', 'put', 'post', 'patch', 'delete'];

// A paragraph ends at the first line that is empty or holds only spaces or tabs. A YAML folded block (`>`) turns a
// blank source line into a single newline, so it has no paragraph break.
const PARAGRAPH_BREAK = /\n[ \t]*\n/;
export const firstParagraph = (s) => (s ?? '').split(PARAGRAPH_BREAK)[0].trim();
export const paragraphs = (s) => (s ?? '').split(PARAGRAPH_BREAK).filter((p) => p.trim()).length;
// A word is a run of characters between whitespace: `deleteVendorContact` in backticks counts as one.
export const words = (s) => (s ?? '').trim().split(/\s+/).filter(Boolean).length;

export const size = (v) => JSON.stringify(v ?? null).length;
export const pointer = (spec, ref) => ref.replace(/^#\//, '').split('/')
  .map((p) => p.replace(/~1/g, '/').replace(/~0/g, '~')).reduce((n, p) => n?.[p], spec);
export const resolve = (spec, node) => {
  let cur = node;
  for (let i = 0; cur?.$ref && i < 20; i++) cur = pointer(spec, cur.$ref);
  return cur;
};

// Every operation, in path order, then method order.
export function operations(spec) {
  const out = [];
  for (const [p, item] of Object.entries(spec.paths ?? {})) {
    for (const m of METHODS) {
      const op = item?.[m];
      if (op) out.push({ id: op.operationId ?? `${m.toUpperCase()} ${p}`, method: m.toUpperCase(), path: p, item, op, tags: op.tags ?? [] });
    }
  }
  return out;
}

// A search hit: one line with the operationId, method, path and summary.
export const searchHit = (o) => `${o.id} ${o.method} ${o.path} ${o.op.summary ?? ''}`.trim();

// Every $ref inlined (a cycle stays a $ref), example and examples dropped. A `properties` map's keys are names, never
// keywords, so a property called `example` stays. Records each inlining: the ref, how deep, and its inlined chars.
export function inliner(spec) {
  const visits = [];
  let maxDepth = 0;
  const deref = (node, seen = [], names = false) => {
    if (Array.isArray(node)) return node.map((n) => deref(n, seen));
    if (!node || typeof node !== 'object') return node;
    if (!names && typeof node.$ref === 'string') {
      if (seen.includes(node.$ref)) return node;
      const out = deref(pointer(spec, node.$ref), [...seen, node.$ref]);
      visits.push({ ref: node.$ref, depth: seen.length + 1, chars: size(out) });
      maxDepth = Math.max(maxDepth, seen.length + 1);
      return out;
    }
    return Object.fromEntries(Object.entries(node)
      .filter(([k]) => names || (k !== 'example' && k !== 'examples'))
      .map(([k, v]) => [k, deref(v, seen, !names && k === 'properties')]));
  };
  return { deref, visits, depth: () => maxDepth };
}

// The `read` answer for an operation from operations(): method, path and the operation, path-level parameters
// included, every $ref inlined, examples dropped, and each non-2xx response cut to its description.
export function readAnswer(spec, o) {
  const params = [...(o.item.parameters ?? []), ...(o.op.parameters ?? [])];
  const responses = Object.fromEntries(Object.entries(o.op.responses ?? {})
    .map(([s, r]) => [s, s.startsWith('2') ? r : { description: resolve(spec, r)?.description }]));
  const inl = inliner(spec);
  const answer = { method: o.method, path: o.path, ...inl.deref({ ...o.op, parameters: params, responses }) };
  return { answer, visits: inl.visits, refDepth: inl.depth() };
}

// How `search` matches: the words an agent types against the words of an operation, both cut into stems.
// Function words only; every other word counts, weighted by how rare it is.
export const STOP = new Set(('a an the and or but if then so of to in on at by for from with without as into onto about over under '
  + 'is are was were be been being am do does did has have had it its this that these those there their them they he she '
  + 'his her we our you your i me my what which who whom whose why how when where can could may might must shall should '
  + 'will would not no nor than too very just also only s').split(' '));
// Light stemming: plurals and -ies, then -ing and -ed (undoubling a final consonant other than l, s or z), then a final e.
export const stem = (word) => {
  let w = word;
  if (w.length <= 3 || /^\d+$/.test(w)) return w;
  if (w.endsWith('ies') && w.length > 4) w = `${w.slice(0, -3)}y`;
  else if (w.endsWith('sses')) w = w.slice(0, -2);
  else if (w.endsWith('s') && !/(ss|us|is)$/.test(w)) w = w.slice(0, -1);
  const undouble = (s) => (/([^aeiouylsz])\1$/.test(s) ? s.slice(0, -1) : s);
  if (w.endsWith('ing') && w.length - 3 >= 3) w = undouble(w.slice(0, -3));
  else if (w.endsWith('ed') && w.length - 2 >= 3) w = undouble(w.slice(0, -2));
  if (w.endsWith('e') && w.length > 3) w = w.slice(0, -1);
  return w;
};
// camelCase and path words split apart, lower case, the possessive 's dropped.
export const tokens = (text) => (text ?? '').replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
  .toLowerCase().replace(/['’]s\b/g, '').split(/[^a-z0-9]+/).filter((w) => w && !STOP.has(w)).map(stem);

// What `search` matches an operation on: its operationId, method, path, summary and the description's first paragraph.
export const searchText = (o) => `${searchHit(o)} ${firstParagraph(o.op.description)}`;
