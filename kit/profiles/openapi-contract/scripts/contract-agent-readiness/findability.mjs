// Findability: can a `search` that matches words find the right operation for an intent? For each intent it ranks every
// operation by word overlap with the intent's phrase: each shared word weighs its inverse document frequency (BM25's idf,
// ln(1 + (N - df + 0.5) / (df + 0.5))), after light stemming, without stop words. It ranks twice:
//   (a) over the operationId split into words, the method, the path's words and the summary;
//   (b) over the same, plus the description's first paragraph (read.mjs, the checker's definition).
// A rank is the worst place among ties, so a tie never counts in the expected operation's favour; no shared word is a miss.
// For each intent it also says where its facts' keywords are: in the first paragraph, only later, or absent.
// Usage: node findability.mjs [--spec <openapi.yaml>] [--intents <intents.json>] [--after <spec>] [--known <known.json>] [--json]
//   --spec:    default contract/dist/openapi.yaml.
//   --intents: default scripts/test/fixtures/contract-agent-readiness/intents.json, a JSON array of
//              { "id", "set", "intent", "expected", "lookAlike"?, "facts"?: [{ "label", "all": ["regex", ...] | "cue": "completion" }] }
//              (each regex matches without case; a fact holds where all of its regexes match; `cue` names a checker cue).
//              Recall is given in total and per `set`.
//   --after:   ranks the same intents on a second spec too, and shows before → after.
//   --known:   { "misses": [<intent id>, ...], "ties": [<intent id>, ...] }, the intents known to miss at 10 in (b) and
//              the ones known to tie with or trail their look-alike there (lookAlike.best <= rank, the intent not a
//              miss). Checked on the last spec ranked. Both lists may only shrink: a miss or a tie not listed fails, and
//              so does a listed one that no longer misses or ties, or an id the intents do not have.
//   --json:    prints the results as JSON instead of the table.
// Writes no file. Exits 1 when an intent names an operation the contract does not have (intent-stale), or when the
// --known lists do not match.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { firstParagraph, operations, searchHit, searchText, tokens, words } from './read.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); if (i < 0) return undefined; const v = args[i + 1]; args.splice(i, 2); return v; };
const specPath = path.resolve(flag('--spec') ?? path.join(root, 'contract/dist/openapi.yaml'));
const intentsPath = path.resolve(flag('--intents') ?? path.join(root, 'scripts/test/fixtures/contract-agent-readiness/intents.json'));
const afterPath = flag('--after');
const knownPath = flag('--known');
const asJson = args.includes('--json');
if (asJson) args.splice(args.indexOf('--json'), 1);
if (args.length) {
  console.error('usage: node findability.mjs [--spec <openapi.yaml>] [--intents <intents.json>] [--after <spec>] '
    + '[--known <known.json>] [--json]');
  process.exit(2);
}

// The checker's cues, read from check.mjs so that both use one definition.
const checkSrc = readFileSync(path.join(here, 'check.mjs'), 'utf8');
const CUES = { completion: checkSrc.match(/^const COMPLETION = \/(.+)\/i;$/m)?.[1] };
if (!CUES.completion) { console.error('[findability] COMPLETION not found in check.mjs'); process.exit(1); }

const intents = JSON.parse(readFileSync(intentsPath, 'utf8'));
const factRes = (f) => (f.cue ? [CUES[f.cue]] : f.all).map((s) => {
  if (!s) throw new Error(`[findability] unknown cue ${f.cue} in fact ${f.label}`);
  return new RegExp(s, 'i');
});

const MODES = {
  a: 'operationId words, method, path words, summary',
  b: 'the same plus the first paragraph',
};
// Mode (b) is what the portal-api MCP server's search matches on.
const docText = { a: searchHit, b: searchText };
const KS = [1, 3, 10];
const recallOf = (rs) => Object.fromEntries(Object.keys(MODES).map((mode) => [mode, Object.fromEntries(KS
  .map((k) => [k, rs.filter((r) => r[mode].rank !== null && r[mode].rank <= k).length]))]));

function rankOn(file) {
  const spec = parse(readFileSync(file, 'utf8'));
  const ops = operations(spec);
  const byId = new Map(ops.map((o, i) => [o.id, i]));
  const modes = {};
  for (const mode of Object.keys(MODES)) {
    const docs = ops.map((o) => new Set(tokens(docText[mode](o))));
    const df = new Map();
    for (const d of docs) for (const t of d) df.set(t, (df.get(t) ?? 0) + 1);
    const N = docs.length;
    const idf = (t) => { const d = df.get(t) ?? 0; return d ? Math.log(1 + (N - d + 0.5) / (d + 0.5)) : 0; };
    modes[mode] = { docs, idf };
  }
  const where = (o, fact) => {
    const res = factRes(fact);
    const holds = (t) => res.every((r) => r.test(t));
    const desc = o?.op.description ?? '';
    return holds(firstParagraph(desc)) ? 'first' : holds(desc) ? 'later' : 'absent';
  };
  const stale = intents.flatMap((it) => [it.expected, it.lookAlike].filter((id) => id && !byId.has(id))
    .map((id) => ({ id: it.id, operationId: id })));
  const results = intents.map((it) => {
    const query = [...new Set(tokens(it.intent))];
    const out = { id: it.id, set: it.set, intent: it.intent, expected: it.expected, lookAlike: it.lookAlike ?? null, query };
    for (const [mode, { docs, idf }] of Object.entries(modes)) {
      const round = (x) => Math.round(x * 1e9) / 1e9;
      const scores = docs.map((d) => round(query.reduce((s, t) => s + (d.has(t) ? idf(t) : 0), 0)));
      const place = (id) => {
        const i = byId.get(id);
        if (i === undefined || !(scores[i] > 0)) return { rank: null, best: null, score: 0 };
        return { rank: scores.filter((x) => x >= scores[i]).length, best: 1 + scores.filter((x) => x > scores[i]).length,
          score: Number(scores[i].toFixed(3)), matched: query.filter((t) => docs[i].has(t)) };
      };
      const top = scores.map((s, i) => [s, i]).sort((x, y) => y[0] - x[0]).slice(0, 5)
        .map(([s, i]) => ({ id: ops[i].id, score: Number(s.toFixed(3)), matched: query.filter((t) => docs[i].has(t)) }));
      out[mode] = { ...place(it.expected), lookAlike: it.lookAlike ? place(it.lookAlike) : null, top };
    }
    const o = ops[byId.get(it.expected)];
    out.firstParagraphWords = words(firstParagraph(o?.op.description));
    out.facts = (it.facts ?? []).map((f) => {
      const w = where(o, f);
      return { label: f.label, where: w, expectAbsent: !!f.expectAbsent, ok: f.expectAbsent ? w === 'absent' : w === 'first' };
    });
    return out;
  });
  const sets = [...new Set(results.map((r) => r.set))];
  const recallBySet = Object.fromEntries(sets.map((s) => {
    const rs = results.filter((r) => r.set === s);
    return [s, { intents: rs.length, ...recallOf(rs) }];
  }));
  return { spec: path.relative(root, file), version: spec.info?.version ?? null, operations: ops.length, intents: intents.length,
    stale, recall: recallOf(results), recallBySet, results };
}

const before = rankOn(specPath);
const after = afterPath ? rankOn(path.resolve(afterPath)) : null;
const stale = [...before.stale, ...(after?.stale ?? [])];

// The known misses and ties, against the last spec ranked: what is new fails, and so does what is gone.
let known = null;
if (knownPath) {
  const list = JSON.parse(readFileSync(path.resolve(knownPath), 'utf8'));
  const rs = (after ?? before).results;
  const isMiss = (r) => r.b.rank === null || r.b.rank > 10;
  const misses = rs.filter(isMiss).map((r) => r.id);
  const ties = rs.filter((r) => !isMiss(r) && r.b.lookAlike?.best != null && r.b.lookAlike.best <= r.b.rank).map((r) => r.id);
  const ids = new Set(rs.map((r) => r.id));
  const diff = (now, listed) => ({ unlisted: now.filter((id) => !listed.includes(id)),
    gone: listed.filter((id) => ids.has(id) && !now.includes(id)), unknown: listed.filter((id) => !ids.has(id)) });
  known = { file: path.relative(root, path.resolve(knownPath)), misses: diff(misses, list.misses ?? []),
    ties: diff(ties, list.ties ?? []) };
  known.ok = [known.misses, known.ties].every((d) => !d.unlisted.length && !d.gone.length && !d.unknown.length);
}

if (asJson) {
  process.stdout.write(`${JSON.stringify({ tokensAre: 'stems; see the header of findability.mjs', modes: MODES,
    intents: path.relative(root, intentsPath), before, after, ...(known ? { known } : {}) }, null, 2)}\n`);
} else {
  const place = (p) => (p.rank === null ? '-' : p.best === p.rank ? `${p.rank}` : `${p.best}–${p.rank}`);
  const rec = (x) => `(a) @1 ${x.a[1]} · @3 ${x.a[3]} · @10 ${x.a[10]} | (b) @1 ${x.b[1]} · @3 ${x.b[3]} · @10 ${x.b[10]}`;
  const lines = [`FINDABILITY ${before.spec}${after ? ` → ${after.spec}` : ''} v${before.version} · ${before.operations} operations`
    + ` · ${path.relative(root, intentsPath)} · rank = worst place among ties, - = no shared word`];
  lines.push(`RECALL of ${intents.length}: ${rec(before.recall)}${after ? `  →  ${rec(after.recall)}` : ''}`);
  for (const [s, b] of Object.entries(before.recallBySet)) {
    lines.push(`  ${s.padEnd(12)} of ${String(b.intents).padStart(3)}: ${rec(b)}${after ? `  →  ${rec(after.recallBySet[s])}` : ''}`);
  }
  const final = after ?? before;
  const missed = final.results.filter((r) => r.b.rank === null || r.b.rank > 10);
  lines.push(`MISSED at 10 in (b)${after ? ' after' : ''}: ${missed.length}${missed.length
    ? ` — ${missed.map((r) => `${r.id} ${r.expected} ${place(r.b)}`).join(', ')}` : ''}`);
  console.log(lines.join('\n'));
}
if (known && !known.ok) {
  const say = (kind, d) => [
    ...(d.unlisted.length ? [`new ${kind} not in the list: ${d.unlisted.join(', ')}`] : []),
    ...(d.gone.length ? [`listed ${kind} that no longer ${kind === 'misses' ? 'miss' : 'tie'}, remove: ${d.gone.join(', ')}`] : []),
    ...(d.unknown.length ? [`listed ${kind} the intents do not have: ${d.unknown.join(', ')}`] : [])];
  console.error(`[findability] known (${known.file}): ${[...say('misses', known.misses), ...say('ties', known.ties)].join('; ')}`);
}
if (stale.length) {
  console.error(`[findability] intent-stale: ${stale.map((s) => `${s.id} names ${s.operationId}, which the contract does not have`).join('; ')}`);
  process.exit(1);
}
if (known && !known.ok) process.exit(1);
