#!/usr/bin/env node
// The contract operations a ticket names, with where they live in the code (P2: a script, not a model). It runs
// `where`'s logic (code-index.mjs) and reads `read`'s readiness verdict without the MCP server, for plan-context.sh.
// Usage: node scripts/contract-mcp/plan-ops.mjs <ticket.md> [<checkout>]
// Writes a Markdown section to stdout, or nothing when the ticket names no operation. An operation is named by its
// operationId as a whole word, or by `METHOD /path` exactly as the contract writes it. Needs the checkout's
// the contract bundle, contract/dist/openapi.yaml by default (`contract.spec_path` of .archon/kit.yaml; exit 1 without it); the readiness report only adds the verdicts.
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';
import { operations } from '../contract-agent-readiness/read.mjs';
import { codeIndex } from './code-index.mjs';
import { kitConfig } from './kit-config.mjs';

const MAX_OPS = 12;
const [ticketFile, checkout = '.'] = process.argv.slice(2);
if (!ticketFile) { console.error('usage: plan-ops.mjs <ticket.md> [<checkout>]'); process.exit(2); }
const root = path.resolve(checkout);
const specFile = path.resolve(root, kitConfig(root)('contract.spec_path'));
if (!existsSync(specFile)) { console.error(`plan-ops: no ${specFile}`); process.exit(1); }

const text = existsSync(ticketFile) ? readFileSync(ticketFile, 'utf8') : '';
const spec = parse(readFileSync(specFile, 'utf8'));
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// The first place in the ticket that names each operation, so the section follows the ticket's order.
const named = [];
for (const o of operations(spec)) {
  const id = new RegExp(`(^|[^A-Za-z0-9_])${escape(o.id)}($|[^A-Za-z0-9_])`).exec(text);
  const route = new RegExp(`\\b${o.method.toUpperCase()}\\s+${escape(o.path)}($|[^A-Za-z0-9_/{-])`).exec(text);
  const at = Math.min(id ? id.index : Infinity, route ? route.index : Infinity);
  if (at !== Infinity) named.push({ id: o.id, at });
}
if (!named.length) process.exit(0);
named.sort((a, b) => a.at - b.at || a.id.localeCompare(b.id));

// The verdicts, only from a report of the same contract version (as the server checks).
let verdicts = null;
const reportFile = path.join(root, 'build/contract-agent-readiness/readiness-report.json');
if (existsSync(reportFile)) {
  try {
    const report = JSON.parse(readFileSync(reportFile, 'utf8'));
    if (report.sources?.version === spec.info?.version) verdicts = new Map(report.operations.map((o) => [o.operationId, o.verdict]));
  } catch { /* an unreadable report only costs the verdicts */ }
}

const code = codeIndex(root, spec);
const list = (label, items) => (items?.length ? [`  - ${label}: ${items.map((i) => `\`${i}\``).join(', ')}`] : []);
const out = [
  '## Contract operations this ticket names',
  '',
  `_Where each one lives, from scripts/contract-mcp/plan-ops.mjs (the logic of @@KIT_CONTRACT_SERVER_NAME@@'s \`where\`, contract v${spec.info?.version}). `
    + 'Ask `where`, `schema` or `usedBy` for more; read a file only for what this does not say._',
];
if (!verdicts) out.push('', '_No readiness report of this contract version: the verdicts are left out._');
for (const { id } of named.slice(0, MAX_OPS)) {
  const w = code.where(id);
  const verdict = verdicts?.get(id);
  out.push('', `- **${w.operationId}** \`${w.method.toUpperCase()} ${w.path}\` (${w.tag ?? 'no tag'}): ${w.status}${verdict ? `, verdict ${verdict}` : ''}`);
  out.push(`  - interface: \`${w.interface}\``);
  if (w.controller) out.push(`  - controller: \`${w.controller}\`${w.alsoImplementedBy ? ` (also: ${w.alsoImplementedBy.join(', ')})` : ''}`);
  if (w.hint) out.push(`  - ${w.hint}`);
  out.push(...list(`calls (${w.via ?? 'none'})`, w.calls), ...list('unit tests', w.unitTests),
    ...list('HTTP tests', w.httpTests), ...list('mentions', w.mentions));
  for (const n of w.notes ?? []) out.push(`  - note: ${n}`);
}
if (named.length > MAX_OPS) out.push('', `_Also named, not shown: ${named.slice(MAX_OPS).map((n) => n.id).join(', ')}._`);
console.log(out.join('\n'));
