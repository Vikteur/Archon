// The evening approval round's first step: scan each night ticket for the STOP items it could touch (P2: a script finds
// the signals, a model judges the hits, the owner answers each likely item; owner decision 2026-10-20, STOP rule changes;
// docs/archon/stop-policy.md). Read-only: it only reads tickets and docs.
//   node stop-scan.js [--json] [--all] <TASK-id>...
// For every ticket it reads the whole ticket with `backlog task view <id> --json` (title, description, acceptance
// criteria, plan, notes), its linked spec (the "Plan item `P<n>-E<nn>-T<nn>`" file under docs/rewrite/tickets/) and the
// docs line ranges its references name (`docs/...:<from>-<to>`). Each line is matched against every category of
// .archon/stop/policy.json: its `match` words (strong) and its `signals` (weak). Per ticket and category it prints whether
// the ticket carries the `stop-*` label, what settles it without a question (a standing rule, or never coverable: the
// owner decides that one when it comes), and up to 5 triggering lines, strong first (--all: every line). A label with
// no text hit is listed too. Labelled and unlabelled items are printed alike: the label is detection, not approval.
// Prints text, or with --json [{ id, title, labels, items: [{ category, labelled, settled, hits: [{ where, strong, text }] }],
// labels_without_hit, sources }].
// Exit 0 printed, 1 a ticket could not be read, 2 usage.
// Overrides for the tests: STOP_SCAN_TICKETS (a folder of <id>.json files standing in for backlog task view),
// STOP_SCAN_ROOT (the repo root holding docs/ and .archon/stop/policy.json; default the repo of this script).
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { loadPolicy, category } = require('./stop-lib.js');

const root = process.env.STOP_SCAN_ROOT || path.resolve(__dirname, '..', '..');
const PER_CATEGORY = 5;
const SKIP_SECTIONS = /^## (Definition of Done|References)\b/i;

function view(id) {
  const dir = process.env.STOP_SCAN_TICKETS;
  const text = dir ? fs.readFileSync(path.join(dir, `${id}.json`), 'utf8')
    : execFileSync('backlog', ['task', 'view', id, '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const o = JSON.parse(text);
  const t = o && o.task ? o.task : o;
  if (!t || !t.id) throw new Error(`no task in the backlog view of ${id}`);
  return t;
}

function find(dir, name) {
  if (!fs.existsSync(dir)) return null;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { const r = find(p, name); if (r) return r; } else if (e.name === name) return p;
  }
  return null;
}

// The ticket's text, as [{ where, lines: [[lineNo, text]] }].
function sources(t) {
  const out = [];
  const add = (where, text, from = 1, numbered = true) => {
    if (!text) return;
    out.push({ where, numbered, lines: String(text).split('\n').map((l, i) => [from + i, l]) });
  };
  add('title', t.title, 1, false);
  add('description', t.description);
  (t.acceptanceCriteria || []).forEach(ac => add(`AC #${ac.index}`, ac.text, 1, false));
  add('plan', t.implementationPlan);
  add('notes', t.implementationNotes);
  const all = [t.description, t.implementationNotes].join('\n');
  const item = /Plan item `(P\d+-E\d+-T\d+)`/.exec(all);
  if (item) {
    const spec = find(path.join(root, 'docs', 'rewrite', 'tickets'), `${item[1]}.md`);
    if (spec) {
      // The spec's generic sections say the same for every ticket (the STOP list itself, "every contract change ..."):
      // they are left out, the rest keeps its line numbers.
      let skip = false;
      const lines = fs.readFileSync(spec, 'utf8').split('\n').map(l => {
        if (/^## /.test(l)) skip = SKIP_SECTIONS.test(l);
        return skip ? '' : l;
      });
      add(path.relative(root, spec), lines.join('\n'));
    }
  }
  for (const r of t.references || []) {
    const m = /^(docs\/[^:\s]+\.md):(\d+)-(\d+)/.exec(String(r).trim());
    if (!m) continue;
    const f = path.join(root, m[1]);
    if (!fs.existsSync(f)) continue;
    const lines = fs.readFileSync(f, 'utf8').split('\n').slice(Number(m[2]) - 1, Number(m[3]));
    add(m[1], lines.join('\n'), Number(m[2]));
  }
  return out;
}

function excerpt(line, re) {
  const m = re.exec(line);
  const at = m ? m.index : 0;
  const from = Math.max(0, at - 70);
  return `${from > 0 ? '…' : ''}${line.slice(from, from + 160).trim()}${from + 160 < line.length ? '…' : ''}`;
}

function scan(t, policy, all) {
  const labels = t.labels || [];
  const srcs = sources(t);
  const items = [];
  for (const c of policy.categories) {
    const strong = new RegExp(c.match.join('|'), 'i');
    const weak = (c.signals || []).length ? new RegExp(c.signals.join('|'), 'i') : null;
    const hits = [];
    for (const s of srcs) for (const [n, l] of s.lines) {
      if (!l.trim()) continue;
      const isStrong = strong.test(l);
      if (!isStrong && !(weak && weak.test(l))) continue;
      hits.push({ where: s.numbered ? `${s.where}:${n}` : s.where, strong: isStrong, text: excerpt(l, isStrong ? strong : weak) });
    }
    const labelled = labels.includes(c.label);
    if (!hits.length && !labelled) continue;
    hits.sort((a, b) => Number(b.strong) - Number(a.strong));
    const rule = policy.standing_rules.find(r => r.active && r.covers.includes(c.id) && !r.mode);
    const settled = !c.coverable ? 'never covered: the owner decides it per action when it comes'
      : rule ? `standing rule ${rule.id}: no question needed` : '';
    items.push({ category: c.id, labelled, settled, strong: hits.filter(h => h.strong).length, count: hits.length,
      hits: all ? hits : hits.slice(0, PER_CATEGORY) });
  }
  const labelsWithoutHit = labels.filter(l => /^stop-/.test(l) && !category(policy, l));
  return { id: t.id, title: t.title, status: t.status, labels, items, unknown_labels: labelsWithoutHit,
    sources: srcs.map(s => s.where) };
}

function print(r) {
  const lines = [`${r.id} ${r.title} (${r.status}; labels: ${r.labels.join(', ') || 'none'})`];
  lines.push(`  read: ${r.sources.join(', ')}`);
  if (!r.items.length) lines.push('  no STOP signal');
  for (const it of r.items) {
    const tag = [it.labelled ? 'labelled' : 'unlabelled', `${it.strong} strong / ${it.count} lines`, it.settled].filter(Boolean).join('; ');
    lines.push(`  ${it.category} — ${tag}`);
    if (!it.count) lines.push('    (label only: no line of the ticket names it)');
    for (const h of it.hits) lines.push(`    ${h.strong ? '!' : '·'} ${h.where}: ${h.text}`);
  }
  for (const l of r.unknown_labels) lines.push(`  unknown STOP label ${l}: stop-check gives owner until the policy knows it`);
  return lines.join('\n');
}

function main(argv) {
  const json = argv.includes('--json');
  const all = argv.includes('--all');
  const ids = argv.filter(a => !a.startsWith('--'));
  if (!ids.length || ids.some(id => !/^TASK-\d+(\.\d+)*$/i.test(id))) {
    console.error('usage: node stop-scan.js [--json] [--all] <TASK-id>...');
    return 2;
  }
  const policy = loadPolicy(fs.readFileSync(path.join(root, '.archon', 'stop', 'policy.json'), 'utf8'));
  const results = [];
  let rc = 0;
  for (const id of ids) {
    try { results.push(scan(view(id.toUpperCase()), policy, all)); }
    catch (e) { console.error(`stop-scan: cannot read ${id}: ${e.message.split('\n')[0]}`); rc = 1; }
  }
  if (json) process.stdout.write(JSON.stringify(results, null, 2) + '\n');
  else process.stdout.write(results.map(print).join('\n\n') + (results.length ? '\n' : ''));
  return rc;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
