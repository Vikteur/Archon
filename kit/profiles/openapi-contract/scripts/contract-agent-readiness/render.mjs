// Render a readiness report (check.mjs) as Markdown for a person: the verdicts, the tags, the findings per rule with
// their fix, what exposing every operation as its own tool would cost, the `read` budget, and what a first-paragraph
// cut adds when the report has one.
// Usage: node render.mjs <readiness-report.json>   (Markdown on stdout)
import { readFileSync } from 'node:fs';

const reportPath = process.argv[2];
if (!reportPath) {
  console.error('usage: node render.mjs <readiness-report.json>');
  process.exit(2);
}
const r = JSON.parse(readFileSync(reportPath, 'utf8'));
const s = r.summary;
const n = (x) => x.toLocaleString('en-US');
const plural = (count, severity) => `${count} ${severity}${count === 1 || severity === 'info' ? '' : 's'}`;
const lines = [];
const out = (...l) => lines.push(...l);

out(`# Agent readiness: ${r.sources.title ?? 'contract'} ${r.sources.version ?? ''}`.trimEnd(), '',
  `Contract \`${r.sources.contract}\`${r.sources.map ? `, map \`${r.sources.map}\`` : ', no map'}. `
    + `${s.errors} errors, ${s.warnings} warnings, ${s.info} info (${s.accepted} accepted).`, '',
  '| Verdict | Operations | What it means |', '|---|---|---|',
  `| wrap | ${s.wrap} | An agent can get it as it is. |`,
  `| describe | ${s.describe} | Its description must answer more first: an error or a warning below. |`,
  `| redesign | ${s.redesign} | No description makes it safe: a person confirms it, or it needs a prepare step. |`, '',
  '## By tag', '',
  '| Tag | Operations | wrap | describe | redesign | Tokens as one tool each |', '|---|---|---|---|---|---|',
  ...Object.entries(r.tags).map(([t, c]) => `| ${t} | ${c.operations} | ${c.wrap} | ${c.describe} | ${c.redesign} | ≈ ${n(c.tokens)} |`),
  '', '## Findings', '');

const byRule = new Map();
for (const f of r.findings) byRule.set(f.rule, [...(byRule.get(f.rule) ?? []), f]);
if (!byRule.size) out('None.', '');
for (const [rule, list] of byRule) {
  const open = list.filter((f) => !f.accepted);
  const counts = [...(open.length ? [plural(open.length, open[0].severity)] : []),
    ...(open.length < list.length ? [`${list.length - open.length} accepted`] : [])];
  out(`### ${rule}: ${counts.join(', ')}`, '', list[0].fix, '');
  if (rule === 'human-confirm') {
    const byReason = new Map();
    for (const f of list) byReason.set(f.detail, [...(byReason.get(f.detail) ?? []), f.operationId]);
    for (const [reason, ids] of byReason) out(`- ${ids.map((id) => `\`${id}\``).join(', ')}: ${reason}`);
  } else {
    for (const f of list) {
      const where = f.operationId ? `\`${f.operationId}\` ${f.method} \`${f.path}\`: ` : '';
      out(`- ${where}${f.detail}${f.accepted ? ` (accepted: ${f.accepted})` : ''}`);
    }
  }
  out('');
}

const b = r.toolBudget;
out('## Tool budget', '',
  `One MCP tool per operation: ${b.tools} tools, ≈ ${n(b.tokens)} tokens sent with every request; the ${b.readOnlyTools} `
    + `GET operations alone ≈ ${n(b.readOnlyTokens)}. ${b.note}. The largest: `
    + `${b.largest.map((l) => `\`${l.operationId}\` (${n(l.tokens)})`).join(', ')}.`);

const rb = r.readBudget;
out('', '## Read budget', '',
  `One \`read\` answer: median ≈ ${n(rb.median)} tokens (budget ${n(rb.medianTokens)}${rb.medianOver ? ', over' : ''}), `
    + `p90 ≈ ${n(rb.p90)}, max ≈ ${n(rb.max)} (budget ${n(rb.maxTokens)}). ${rb.note}.`);
if (rb.over.length) {
  out('', ...rb.over.map((o) => `- \`${o.operationId}\`: ≈ ${n(o.tokens)} tokens${o.allowed ? ` (allowed: ${o.allowed})` : ', not allowed'}`));
}
if (r.cut) {
  out('', '## First paragraph only', '',
    `${r.cut.note}: ${plural(r.cut.errors, 'error')}, ${plural(r.cut.warnings, 'warning')}, ${r.cut.adds.length} new.`);
  if (r.cut.adds.length) out('', ...r.cut.adds.map((f) => `- ${f.rule}: \`${f.operationId ?? ''}\` ${f.detail}`));
}
process.stdout.write(`${lines.join('\n')}\n`);
