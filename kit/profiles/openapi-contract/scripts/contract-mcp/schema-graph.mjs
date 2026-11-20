// The schemas of the contract as an agent implements them: `schema` answers one schema's fields, flattened and with
// nested schemas left as names; `usedBy` answers which operations carry a schema or a field, request or response, and
// where the generated model enters the hand-written Java. The server builds the graph once at start from the spec it
// loaded; the Java side is read on every call, so it never lags behind an edit.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { firstParagraph, operations } from '../contract-agent-readiness/read.mjs';
import { kitConfig } from './kit-config.mjs';

const SCHEMA_CHARS = 6000;
const USED_BY_CHARS = 6000;
const KEEP = ['type', 'format', 'enum', 'nullable', 'readOnly', 'writeOnly', 'default', 'maxLength', 'minLength',
  'pattern', 'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf', 'minItems', 'maxItems',
  'uniqueItems', 'minProperties', 'maxProperties', 'x-extensible-enum'];
const SKIP_DIRS = new Set(['build', 'node_modules', '.git', '.gradle', '.codegraph', 'contract', 'out']);

// A route as one line: a property, item or map step sticks to the schema before it (`folderPage.items[]`).
const joinRoute = (steps) => steps.reduce((out, s) => (/^(\.|\[\]|\{\})/.test(s) && out ? out + s : out ? `${out} > ${s}` : s), '');
const refName = (ref) => ref.replace(/^#\/components\/schemas\//, '');
// The generator's Java name for a schema: its first letter capitalised (`folderPage` → `FolderPage`).
export const javaName = (name) => name[0].toUpperCase() + name.slice(1);
const sentence = (s) => { const p = firstParagraph(s).replace(/\s+/g, ' '); const m = /^.*?[.!?](?=\s|$)/.exec(p); return m ? m[0] : p; };

function levenshtein(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) {
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  }
  return d[a.length][b.length];
}

function javaFiles(root) {
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
    if (!m.isDirectory() || SKIP_DIRS.has(m.name)) continue;
    for (const kind of ['main', 'test']) walk(join(root, m.name, 'src', kind, 'java'));
  }
  return out.sort();
}

// schemaGraph(spec, root) → { find(name), schema(name), usedBy(target), nearest(name) }.
export function schemaGraph(spec, root) {
  const kit = kitConfig(root);
  const MODELS = `${kit('contract.generated_dir')}/model`;
  const apiPackage = kit('contract.api_package');
  const pkgRe = apiPackage.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const schemas = spec.components?.schemas ?? {};
  const names = Object.keys(schemas);
  const lower = new Map(names.map((n) => [n.toLowerCase(), n]));
  const find = (name) => (schemas[name] ? name : lower.get(String(name).toLowerCase()) ?? null);
  const nearest = (name) => names.map((n) => [n, levenshtein(String(name).toLowerCase(), n.toLowerCase())])
    .sort((a, b) => a[1] - b[1]).slice(0, 3).map(([n]) => n);

  // One property, compact: a nested schema stays a name, an array or a map shows what it holds.
  const compact = (node, withDescription = true) => {
    if (!node || typeof node !== 'object') return node;
    if (node.$ref) return { $ref: refName(node.$ref) };
    const out = {};
    for (const k of KEEP) if (node[k] !== undefined) out[k] = node[k];
    if (node.items) out.items = compact(node.items, false);
    if (node.additionalProperties && typeof node.additionalProperties === 'object') out.additionalProperties = compact(node.additionalProperties, false);
    for (const k of ['oneOf', 'anyOf', 'allOf']) if (node[k]) out[k] = node[k].map((n) => compact(n, false));
    if (node.properties) out.properties = Object.keys(node.properties);
    if (withDescription && node.description) out.description = sentence(node.description);
    return out;
  };

  // The fields of a schema with every allOf part flattened in; a field inherited from a part names that part (`from`).
  const flatten = (name) => {
    const fields = new Map(); const required = new Set(); const seen = new Set();
    const walk = (node, from) => {
      if (!node) return;
      if (node.$ref) {
        const n = refName(node.$ref);
        if (seen.has(n)) return;
        seen.add(n);
        walk(schemas[n], n === name ? null : n);
        return;
      }
      for (const part of node.allOf ?? []) walk(part, part.$ref ? undefined : from);
      for (const r of node.required ?? []) required.add(r);
      for (const [p, v] of Object.entries(node.properties ?? {})) if (!fields.has(p)) fields.set(p, { node: v, from });
    };
    seen.add(name);
    walk(schemas[name], null);
    return { fields, required };
  };

  // The hand-written Java files that import the generated model, with the line of the import.
  const importers = (javaModel) => {
    const re = new RegExp(`^import\\s+${pkgRe}\\.model\\.(?:${javaModel}|\\*)\\s*;`, 'm');
    const out = [];
    for (const f of javaFiles(root)) {
      const text = readFileSync(join(root, f), 'utf8');
      const m = re.exec(text);
      if (m) out.push({ file: f, text, line: text.slice(0, m.index).split('\n').length });
    }
    return out;
  };

  function schema(input) {
    const name = find(input);
    if (!name) return null;
    const s = schemas[name];
    const { fields, required } = flatten(name);
    const answer = { name, description: s.description ? sentence(s.description) : undefined };
    if (fields.size) {
      answer.required = [...required].filter((r) => fields.has(r));
      answer.properties = Object.fromEntries([...fields].map(([p, { node, from }]) => [p, { ...compact(node), ...(from ? { from } : {}) }]));
      if (s.additionalProperties !== undefined) answer.additionalProperties = compact(s.additionalProperties, false) ?? s.additionalProperties;
      for (const k of ['minProperties', 'maxProperties']) if (s[k] !== undefined) answer[k] = s[k];
    } else {
      Object.assign(answer, compact(s, false));
    }
    for (const k of ['oneOf', 'anyOf']) {
      if (!s[k]) continue;
      const mapping = Object.entries(s.discriminator?.mapping ?? {});
      answer[k] = s[k].map((v) => {
        const n = v.$ref ? refName(v.$ref) : null;
        const value = mapping.find(([, ref]) => n && refName(ref) === n)?.[0] ?? (n && s.discriminator ? n : undefined);
        return { ...(n ? { $ref: n } : compact(v, false)), ...(value ? { when: `${s.discriminator.propertyName} = ${value}` } : {}) };
      });
      if (s.discriminator) answer.discriminator = s.discriminator.propertyName;
    }
    const model = `${MODELS}/${javaName(name)}.java`;
    const modelClass = `${apiPackage}.model.${javaName(name)}`;
    answer.java = {
      model: existsSync(join(root, model)) ? `${modelClass} ${model}` : `${modelClass} (not generated in this checkout)`,
      importedBy: importers(javaName(name)).map((i) => i.file),
    };
    answer.next = `usedBy("${name}") or usedBy("${name}.<field>") for the operations that carry it`;
    // Over budget: first the importers, then the field descriptions go.
    while (JSON.stringify(answer).length > SCHEMA_CHARS && answer.java.importedBy.length > 5) answer.java.importedBy.length -= 5;
    if (JSON.stringify(answer).length > SCHEMA_CHARS) for (const p of Object.values(answer.properties ?? {})) delete p.description;
    return answer;
  }

  // Per operation, breadth first from its parameters, body and responses through every $ref, property, item, map value
  // and allOf/oneOf/anyOf part: the shortest route to each schema it reaches, and how many edges lead into each.
  const reach = operations(spec).map((o) => {
    const roots = [];
    for (const p of [...(o.item.parameters ?? []), ...(o.op.parameters ?? [])]) {
      const prm = p.$ref ? spec.components?.parameters?.[p.$ref.replace(/^#\/components\/parameters\//, '')] : p;
      if (prm?.schema) roots.push({ node: prm.schema, direction: 'request', route: [`${prm.in} ${prm.name}`] });
    }
    for (const c of Object.values(o.op.requestBody?.content ?? {})) if (c.schema) roots.push({ node: c.schema, direction: 'request', route: ['body'] });
    for (const [status, r0] of Object.entries(o.op.responses ?? {})) {
      const r = r0.$ref ? spec.components?.responses?.[r0.$ref.replace(/^#\/components\/responses\//, '')] : r0;
      for (const c of Object.values(r?.content ?? {})) if (c.schema) roots.push({ node: c.schema, direction: 'response', status, route: [status] });
    }
    const first = new Map(); const edges = new Map();
    for (const start of roots) {
      const seen = new Set();
      const queue = [start];
      while (queue.length) {
        const { node, route, direction, status } = queue.shift();
        if (!node || typeof node !== 'object') continue;
        let cur = node; let r = route;
        if (node.$ref) {
          const n = refName(node.$ref);
          edges.set(n, (edges.get(n) ?? 0) + 1);
          if (seen.has(n)) continue;
          seen.add(n);
          r = [...route, n];
          const key = `${direction} ${status ?? ''}`;
          if (!first.has(n)) first.set(n, new Map());
          if (!first.get(n).has(key)) first.get(n).set(key, { direction, status, route: r });
          cur = schemas[n];
        }
        const next = (child, step) => queue.push({ node: child, route: step ? [...r, step] : r, direction, status });
        for (const [p, v] of Object.entries(cur?.properties ?? {})) next(v, `.${p}`);
        if (cur?.items) next(cur.items, '[]');
        if (cur?.additionalProperties && typeof cur.additionalProperties === 'object') next(cur.additionalProperties, '{}');
        for (const k of ['allOf', 'oneOf', 'anyOf']) for (const part of cur?.[k] ?? []) next(part, k);
      }
    }
    return { o, first, edges };
  });

  // The hand-written lines that read or set the field on the generated model (or, for a schema, use the model).
  const entryPoints = (owner, field) => {
    const model = javaName(owner);
    const cap = field ? javaName(field) : null;
    const use = field
      ? new RegExp(`\\.(?:get${cap}|set${cap}|is${cap}|${field})\\s*\\(`)
      : new RegExp(`\\b${model}\\b`);
    const out = [];
    for (const { file, text, line } of importers(model)) {
      if (!file.includes('/src/main/')) continue;
      const lines = text.split('\n');
      let method = null;
      lines.forEach((l, i) => {
        const decl = /^\s*(?:(?:public|protected|private|static|final|synchronized)\s+)+[\w<>\[\], ?.]+\s+(\w+)\s*\([^;]*$/.exec(l);
        if (decl) method = decl[1];
        if (i + 1 > line && use.test(l) && !/^\s*(?:import|\*|\/\/)/.test(l)) out.push(`${file}:${i + 1}${method ? ` ${method}` : ''}`);
      });
    }
    return [...new Set(out)];
  };

  function usedBy(target) {
    const [head, field, extra] = String(target).split('.');
    const name = find(head);
    if (!name || extra !== undefined) return null;
    let owner = name;
    if (field) {
      const f = flatten(name).fields.get(field);
      if (!f) return { error: `${name} has no field ${field}`, fields: [...flatten(name).fields.keys()] };
      owner = f.from ?? name;
    }
    const required = field ? flatten(owner).required.has(field) : undefined;
    const hits = [];
    for (const { o, first, edges } of reach) {
      const at = first.get(owner);
      if (!at) continue;
      for (const { direction, status, route } of at.values()) {
        hits.push({
          operationId: o.id, direction, ...(status ? { status } : {}),
          ...(field && direction === 'request' ? { required } : {}),
          route: joinRoute([...route, ...(field ? [`.${field}`] : [])]),
          ...(edges.get(owner) > 1 ? { otherRoutes: edges.get(owner) - 1 } : {}),
        });
      }
    }
    const answer = {
      target: field ? `${name}.${field}` : name,
      ...(owner !== name ? { owner: `${field} is declared on ${owner} (allOf); every schema built on it is counted` } : {}),
      count: { operations: new Set(hits.map((h) => h.operationId)).size, request: hits.filter((h) => h.direction === 'request').length, response: hits.filter((h) => h.direction === 'response').length },
      operations: hits,
      javaEntryPoints: entryPoints(owner, field),
      via: 'conventions',
      next: 'codegraph_impact on each Java entry point for the use cases and tests behind it; where(operationId) for an operation\'s controller',
    };
    while (JSON.stringify(answer).length > USED_BY_CHARS && answer.javaEntryPoints.length > 10) answer.javaEntryPoints.length -= 5;
    if (JSON.stringify(answer).length > USED_BY_CHARS) {
      const n = answer.operations.length;
      while (JSON.stringify(answer).length > USED_BY_CHARS - 80 && answer.operations.length > 5) answer.operations.length -= 5;
      answer.truncated = `${n - answer.operations.length} more operations; narrow the target to a field`;
    }
    return answer;
  }

  return { find, nearest, schema, usedBy };
}
