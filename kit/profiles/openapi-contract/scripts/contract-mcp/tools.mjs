// The @@KIT_CONTRACT_SERVER_NAME@@ tools, defined once for the MCP server (server.mjs) and the shell fallback (cli.mjs): the loading of
// the spec, the readiness report, the verdicts, the search ranking, the code index and the schema graph, and the five
// tool definitions (name, description, inputSchema, annotations, handler). A tool answers { content: [{ type: 'text',
// text }], isError? }. A missing spec or a stale report exits 1 with its message, for both callers.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';
import { z } from 'zod';
import { operations, readAnswer, searchText, tokens } from '../contract-agent-readiness/read.mjs';
import { codeIndex } from './code-index.mjs';
import { schemaGraph } from './schema-graph.mjs';
import { kitConfig } from './kit-config.mjs';

export function portalTools(root) {
const kit = kitConfig(root);
const serverName = kit('contract.server_name');
const projectName = kit('project_name');
const specPath = kit('contract.spec_path');
const load = (file, hint) => {
  try { return readFileSync(path.resolve(root, file), 'utf8'); } catch {
    console.error(`${serverName}: no ${file} in ${root}. ${hint}`);
    process.exit(1);
  }
};
const spec = parse(load(specPath, 'Run: bash .claude/scripts/contract-pin.sh contract'));
const report = JSON.parse(load('build/contract-agent-readiness/readiness-report.json',
  `Run: bash scripts/contract-agent-readiness.sh --spec ${specPath} --map docs/code-maps/contract-agent-readiness.map.json`));
if (report.sources?.version !== spec.info?.version) {
  console.error(`${serverName}: the readiness report is of contract ${report.sources?.version}, the pin is ${spec.info?.version}. `
    + 'Run the readiness check again.');
  process.exit(1);
}
const verdicts = new Map(report.operations.map((o) => [o.operationId, o.verdict]));

// The ranking of findability.mjs, mode (b): each shared stem weighs its inverse document frequency.
const ops = operations(spec);
const docs = ops.map((o) => new Set(tokens(searchText(o))));
const df = new Map();
for (const d of docs) for (const t of d) df.set(t, (df.get(t) ?? 0) + 1);
const idf = (t) => { const d = df.get(t) ?? 0; return d ? Math.log(1 + (ops.length - d + 0.5) / (d + 0.5)) : 0; };

const code = codeIndex(root, spec);
const graph = schemaGraph(spec, root);

const answer = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value) }] });


return { serverName, projectName, spec, ops, tools: [
{ name: 'search', def: {
  description: `Finds ${projectName} API operations by what they do, e.g. "cancel a booked vendor". Answers the ten best `
    + 'matches: operationId, method, path, summary and verdict. Read one in full with read before you rely on it: a '
    + 'look-alike may rank first.',
  inputSchema: { query: z.string().describe('Words that describe what the operation should do') },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, handler: async ({ query }) => {
  const asked = [...new Set(tokens(query))];
  return answer(ops.map((o, i) => ({ o, score: asked.reduce((s, t) => s + (docs[i].has(t) ? idf(t) : 0), 0) }))
    .filter((h) => h.score > 0).sort((a, b) => b.score - a.score).slice(0, 10)
    .map(({ o }) => ({ operationId: o.id, method: o.method, path: o.path, summary: o.op.summary, verdict: verdicts.get(o.id) })));
} },

{ name: 'read', def: {
  description: `Reads one ${projectName} API operation in full, its $refs inlined and examples dropped: description, `
    + 'parameters, request body, answers (an error answer cut to its description), and its readiness verdict (wrap, '
    + 'describe or redesign) with the findings an agent must know before it calls it.',
  inputSchema: { operationId: z.string().describe('The operationId, as search answers it') },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, handler: async ({ operationId }) => {
  const o = ops.find((x) => x.id === operationId);
  if (!o) return { isError: true, ...answer(`No operation ${operationId}: find it with search.`) };
  const findings = report.findings.filter((f) => f.operationId === operationId)
    .map(({ severity, rule, detail }) => ({ severity, rule, detail }));
  return answer({ ...readAnswer(spec, o).answer, verdict: verdicts.get(operationId), findings,
    next: 'where for the code that builds it; schema for a schema it names' });
} },

{ name: 'where', def: {
  description: 'Finds where an API operation lives in the Java code and whether it is built: its generated interface '
    + 'method, the controller line, status (live, stub or none), what it calls, its unit and HTTP tests. Give one '
    + 'operationId for the full answer, or a tag or status for a list. Next: codegraph_impact, or schema.',
  inputSchema: {
    operationId: z.string().optional().describe('One operation, as search answers it'),
    tag: z.string().optional().describe('Every operation of this tag, short form'),
    status: z.enum(['live', 'stub', 'none']).optional().describe('Every operation with this status, short form'),
  },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, handler: async ({ operationId, tag, status }) => {
  if ([operationId, tag, status].filter((v) => v !== undefined).length !== 1) {
    return { isError: true, ...answer('Give exactly one of operationId, tag or status.') };
  }
  if (operationId) {
    const a = code.where(operationId);
    return a ? answer(a) : { isError: true, ...answer(`No operation ${operationId}: find it with search.`) };
  }
  return answer(code.list({ tag, status }));
} },

{ name: 'schema', def: {
  description: 'Answers one contract schema ready to implement: every field with type, format, enum, nullable, '
    + 'required and constraints, allOf flattened with each inherited field\'s source, nested schemas as names, and '
    + 'the generated Java model with the classes that import it. Next: usedBy for what carries it.',
  inputSchema: { name: z.string().describe('The schema name, e.g. wedding or Wedding') },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, handler: async ({ name }) => {
  const a = graph.schema(name);
  return a ? answer(a)
    : { isError: true, ...answer(`No schema ${name}. Nearest: ${graph.nearest(name).join(', ')}. Or find an operation with search.`) };
} },

{ name: 'usedBy', def: {
  description: 'Answers what a change to a schema or one field reaches: every operation that carries it, request or '
    + 'response, with the shortest route and whether the field is required, and the hand-written Java lines that '
    + 'read it from the generated model. Lists uses; it does not judge a change. Next: codegraph_impact.',
  inputSchema: { target: z.string().describe('A schema (wedding) or a field (wedding.weddingDate)') },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, handler: async ({ target }) => {
  const a = graph.usedBy(target);
  if (!a) {
    const head = String(target).split('.')[0];
    return { isError: true, ...answer(`No schema ${head}. Nearest: ${graph.nearest(head).join(', ')}. Use schema or field, e.g. wedding.weddingDate.`) };
  }
  return a.error ? { isError: true, ...answer(a) } : answer(a);
} },
] };
}
