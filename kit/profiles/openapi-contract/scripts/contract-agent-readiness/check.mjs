// Check an OpenAPI 3.x contract for what an agent must know before it calls an operation, and give every operation a
// verdict: wrap (expose it as it is), describe (its description must answer more first) or redesign (no description
// makes it safe: it needs a confirmation step or a person). An agent picks a tool and calls it knowing only its name,
// description, parameters, answers and errors, so every answer has to be in the contract.
// Usage: node check.mjs <openapi.yaml|json> [map.json] [--first-paragraph]   (JSON report on stdout)
//   --first-paragraph: also checks every operation description cut to its first paragraph, in memory, and adds a `cut`
//                      block: the cut's errors and warnings, and the ones the cut has that the full text does not.
// An operation, its first paragraph, a word and the `read` answer come from read.mjs, the definition the measuring
// scripts use too; each operation's row carries its `read` size in chars and its first paragraph's words. The
// `readBudget` block measures every `read` answer against the map's budget; it is a block, not a finding, so it moves
// no verdict.
//
// map.json (optional) holds the project's judgement, which no heuristic can make:
//   { "minWords": 15,                                     a description with fewer words is thin
//     "explainStatuses": ["409"],                         error answers whose cause the contract must give
//     "lookAlikes": [["<operationId>", ...]],              operations an agent can take for one another: each one
//                                                           must name all the others
//     "humanConfirm": { "<operationId>" | "tag:<tag>": "<why a person confirms it>" },   every non-GET it matches, and
//                                                           a GET named by its operationId
//     "alsoDestroys": { "<operationId>": "<what it destroys>" },   a call that destroys though its summary hides it
//     "readBudget": { "maxTokens": 4000, "medianTokens": 1000,     the most one `read` answer and the median may cost
//                     "allowOver": { "<operationId>": "<why it may be over>" } },   only for an answer over the budget
//     "accept": { "<operationId>": { "<rule>": "<reason>" } } }
// An accepted finding drops to info and carries its reason. A map entry that names an operation or a tag the contract
// does not have is an error, so the map cannot go stale; an `allowOver` entry for an answer within the budget is an
// error too, so that list can only shrink.
import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { firstParagraph, inliner, operations as specOperations, readAnswer, resolve as resolveIn, size, words } from './read.mjs';

const args = process.argv.slice(2);
const cutToo = args.includes('--first-paragraph');
const [specPath, mapPath] = args.filter((a) => a !== '--first-paragraph');
if (!specPath || args.some((a) => a.startsWith('--') && a !== '--first-paragraph')) {
  console.error('usage: node check.mjs <openapi.yaml|json> [map.json] [--first-paragraph]');
  process.exit(2);
}
const spec = parse(readFileSync(specPath, 'utf8'));
if (!spec?.openapi?.startsWith('3.')) {
  console.error(`[readiness] not an OpenAPI 3.x document: ${specPath}`);
  process.exit(1);
}
const map = mapPath ? JSON.parse(readFileSync(mapPath, 'utf8')) : {};
const minWords = map.minWords ?? 15;
const explainStatuses = (map.explainStatuses ?? ['409']).map(String);
const lookAlikes = map.lookAlikes ?? [];
const humanConfirm = map.humanConfirm ?? {};
const alsoDestroys = map.alsoDestroys ?? {};
const budget = { maxTokens: map.readBudget?.maxTokens ?? 4000, medianTokens: map.readBudget?.medianTokens ?? 1000,
  allowOver: map.readBudget?.allowOver ?? {} };
const accepted = map.accept ?? {};

// What a miss costs, which verdict it leads to, and what the contract has to say instead.
const RULES = {
  reversibility: { severity: 'error', verdict: 'describe',
    fix: 'Say whether this can be undone and with which operation, or that it cannot.' },
  'look-alike': { severity: 'error', verdict: 'describe',
    fix: 'Name each look-alike operation and say when to use it instead.' },
  completion: { severity: 'error', verdict: 'describe',
    fix: 'Say how the caller learns that the work has finished (the operation to poll, the field that shows it), or '
      + 'that there is nothing to wait for and no reason to call again.' },
  'blast-radius': { severity: 'warning', verdict: 'describe',
    fix: 'Say what else this changes or removes, and what it leaves alone.' },
  alternative: { severity: 'info', verdict: 'describe',
    fix: 'Say when not to use this and which operation to use instead; a real look-alike belongs in the map.' },
  'error-cause': { severity: 'warning', verdict: 'describe',
    fix: 'Give the cause of the answer, in the response or in the description, so an agent can change the call '
      + 'instead of retrying it.' },
  'example-code': { severity: 'warning', verdict: 'describe',
    fix: 'Name each code the error examples carry in that response\'s description or the operation\'s, with its cause: '
      + 'a `read` drops the examples, so a code only they show never reaches the agent.' },
  'thin-description': { severity: 'warning', verdict: 'describe',
    fix: 'Describe the purpose, when to use it, what it changes besides its answer, and when not to use it.' },
  'param-undocumented': { severity: 'warning', verdict: 'describe',
    fix: 'Describe each parameter: what it is and which operation gives its value.' },
  'human-confirm': { severity: 'info', verdict: 'redesign',
    fix: 'Have a person confirm it outside the agent (a confirmation screen, a second factor), or leave it out of the '
      + 'agent\'s tools.' },
  'single-step-irreversible': { severity: 'info', verdict: 'redesign',
    fix: 'Split it into prepare (answers a plan id and what will be lost), inspect, and execute with that plan id.' },
};
// Findings on the map itself, not on an operation.
const MAP_RULES = ['map-stale', 'budget-stale'];

// Cues are whole words, matched without case. An operation destroys when it is a DELETE, when the map's alsoDestroys
// names it, or when it is no GET and its operationId or its summary says so; a description mentions deleting too
// often to tell. In the summary a determiner and the word after it are left out first, so the object of the call
// ("from the trash") does not count as its verb.
const DESTROYS = /\b(delete|deletes|remove|removes|erase|erases|purge|purges|destroy|destroys|drop|drops|wipe|wipes|trash|trashes|unlink|unlinks|revoke|revokes|withdraw|withdraws|forget|forgets|clear|clears)\b/i;
const DETERMINED = /\b(the|a|an|its|their|this|that)\s+\S+/gi;
const IRREVERSIBLE = /\b(permanently|permanent|for good|irreversibl[ey]|(cannot|can't|can not) be (undone|restored|recovered)|no undo|not recoverable)\b/i;
const REVERSIBLE = /\b(undo|undoes|undone|restor(e|es|ed|ing)|reversibl[ey]|recover(s|ed|able)?|trash|back on|re-?(add|creat|link|import|upload|invit|enabl|open)\w*|(add|create|link|enable|invite|upload|import|save|set|block|remember)(s|ed)? (it |them |one |a new one )?again)\b/i;
const BLAST = /\b(also|along with|together with|with it|cascad(e|es|ed|ing)|every|all (of )?(its|the|their)|nothing else|only (the|this|that|its)|not (those|the|any|its)|neither|stays?|keeps?|kept|left|remains?|leaves?|untouched|unaffected)\b/i;
// An irreversible call whose loss is wide: it takes what hangs off the object with it, or it acts on all of them.
const CASCADE = /\b(everything|all (of )?(its|their)|with (its|their|all)|cascad(e|es|ed|ing)|along with|together with)\b/i;
const BULK = /\b(all|every)\b/i;
const COMPLETION = /\b(poll(s|ed|ing)?|progress|after the answer|in the background|asynchronous(ly)?|task id|job id|until it|nothing to (poll|wait for)|shows when)\b/i;
// A prepare step the description names: "call `previewTrash` first", "first read `listTrackChoices`". A bare "first"
// is a precondition, not a prepared call.
const PREPARE_VERBS = '(call|read|run|check|use)';
// An input that makes a destructive call a second, deliberate step: a confirmation, a plan from a prepare call, a
// precondition on the version the caller saw.
const CONFIRM_INPUT = /^(confirm\w*|\w*confirmation\w*|plan_?id|dry_?run|preview\w*|expected\w*|if-match|etag|version)$/i;
const REASON_PHRASES = new Set(['bad request', 'unauthorized', 'forbidden', 'not found', 'conflict', 'gone',
  'unprocessable entity', 'unprocessable content', 'too many requests', 'internal server error', 'service unavailable',
  'precondition failed', 'error', 'client error']);

const idWords = (id) => id.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase();
// Two operations undo each other when their ids differ only by a toggle (link/unlink, block/unblock, paid/unpaid,
// enable/disable, open/close, trash/restore) and connecting words: unlinkMemberFromVendor undoes linkMemberToVendor.
const TOGGLES = { disable: 'enable', close: 'open', restore: 'trash', off: 'on' };
const CONNECTORS = new Set(['to', 'from', 'of', 'for', 'in', 'into', 'with']);
const toggleKey = (id) => idWords(id).split(' ').filter((w) => !CONNECTORS.has(w))
  .map((w) => TOGGLES[w] ?? (w.startsWith('un') && w.length > 4 ? w.slice(2) : w)).join(' ');
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// A code is named where it stands as a whole word: not inside a longer code.
const namesCode = (code, text) => new RegExp(`(^|[^A-Za-z0-9_])${escape(code)}([^A-Za-z0-9_]|$)`).test(text ?? '');
const destroyText = (o) => `${o.summary.replace(DETERMINED, ' ')} ${idWords(o.id)}`;

// Every finding on one version of the contract: the full text, or the text an agent sees of it in a cut.
function check(doc) {
  const resolve = (node) => resolveIn(doc, node);
  const ops = specOperations(doc).map((o) => {
    const params = new Map();
    for (const p of [...(o.item.parameters ?? []), ...(o.op.parameters ?? [])].map(resolve)) params.set(`${p.in}:${p.name}`, p);
    const summary = o.op.summary ?? '';
    const description = o.op.description ?? '';
    const op = { ...o, summary, description, text: `${summary}\n${description}`, params: [...params.values()] };
    op.destroys = o.method === 'DELETE' || Object.hasOwn(alsoDestroys, o.id)
      || (o.method !== 'GET' && DESTROYS.test(destroyText(op)));
    return op;
  });
  const ids = new Set(ops.map((o) => o.id));
  const tags = new Set(ops.flatMap((o) => o.tags));
  const getIds = new Set(ops.filter((o) => o.method === 'GET').map((o) => o.id));
  const names = (o, other) => new RegExp(`\\b${escape(other)}\\b`).test(o.description);
  const namedOps = (o) => [...ids].filter((other) => other !== o.id && names(o, other));
  const prepares = (o, other) => new RegExp(`\\b${PREPARE_VERBS}\\s+\`?${escape(other)}\`?\\s+first\\b`
    + `|\\bfirst,?\\s+${PREPARE_VERBS}\\s+\`?${escape(other)}\\b`, 'i').test(o.description);

  const findings = [];
  function finding(o, rule, detail) {
    const r = RULES[rule];
    const reason = accepted[o.id]?.[rule];
    findings.push({ severity: reason ? 'info' : r.severity, rule, operationId: o.id, method: o.method, path: o.path,
      detail, fix: r.fix, ...(reason ? { accepted: reason } : {}) });
  }
  function stale(where, name) {
    findings.push({ severity: 'error', rule: 'map-stale', detail: `${where} names ${name}, which the contract does not have`,
      fix: 'Rename or remove the map entry.' });
  }

  // The map first: what it names has to exist.
  lookAlikes.forEach((group, i) => group.filter((id) => !ids.has(id)).forEach((id) => stale(`lookAlikes[${i}]`, id)));
  for (const key of Object.keys(humanConfirm)) {
    if (key.startsWith('tag:') ? !tags.has(key.slice(4)) : !ids.has(key)) stale('humanConfirm', key);
  }
  for (const id of Object.keys(alsoDestroys)) if (!ids.has(id)) stale('alsoDestroys', id);
  for (const id of Object.keys(budget.allowOver)) if (!ids.has(id)) stale('readBudget.allowOver', id);
  for (const [id, rules] of Object.entries(accepted)) {
    if (!ids.has(id)) stale('accept', id);
    for (const rule of Object.keys(rules)) if (!RULES[rule]) stale(`accept.${id}`, `rule ${rule}`);
  }

  for (const o of ops) {
    const others = namedOps(o);
    if (o.destroys) {
      const undoneBy = others.filter((other) => toggleKey(other) === toggleKey(o.id));
      if (!IRREVERSIBLE.test(o.text) && !REVERSIBLE.test(o.text) && !undoneBy.length) {
        finding(o, 'reversibility', `destroys${alsoDestroys[o.id] ? ` (${alsoDestroys[o.id]})` : ''}, and says neither how `
          + 'to undo it nor that it cannot be undone');
      }
      if (!BLAST.test(o.description)) finding(o, 'blast-radius', 'destroys, and says nothing of what else goes or stays');
    }
    // Every member of a look-alike group names the others, whether it destroys or not.
    const groups = lookAlikes.filter((g) => g.includes(o.id));
    for (const g of groups) {
      const missing = g.filter((other) => other !== o.id && ids.has(other) && !names(o, other));
      if (missing.length) finding(o, 'look-alike', `does not name its look-alike ${missing.map((m) => `\`${m}\``).join(', ')}`);
    }
    if (o.destroys) {
      if (!groups.length && !others.length) finding(o, 'alternative', 'destroys, and names no other operation to use instead');
      const inputs = [...o.params.map((p) => p.name), ...Object.keys(bodySchema(doc, o)?.properties ?? {})];
      const prepared = inputs.some((n) => CONFIRM_INPUT.test(n)) || others.some((other) => prepares(o, other));
      const wide = CASCADE.test(o.description) || BULK.test(o.summary);
      if (IRREVERSIBLE.test(o.text) && wide && !prepared) {
        finding(o, 'single-step-irreversible', 'cannot be undone, takes more than the one object, and one call does it: '
          + 'no confirmation input, no prepare call named');
      }
    }
    if (o.op.responses?.['202'] && !COMPLETION.test(o.description) && !others.some((other) => getIds.has(other))) {
      finding(o, 'completion', 'answers 202, and says neither how to learn the outcome nor that there is none to wait for');
    }
    for (const status of explainStatuses) {
      const response = resolve(o.op.responses?.[status]);
      if (!response) continue;
      const said = (response.description ?? '').trim().replace(/\.$/, '');
      const generic = words(said) < 3 || REASON_PHRASES.has(said.toLowerCase());
      if (generic && !new RegExp(`\\b${status}\\b`).test(o.description)) {
        finding(o, 'error-cause', `answers ${status} "${said}" with no cause in the response or the description`);
      }
    }
    const unnamed = [];
    for (const [status, ref] of Object.entries(o.op.responses ?? {})) {
      if (!(Number(status) >= 400)) continue;
      const response = resolve(ref);
      for (const code of codesOf(doc, response)) {
        if (!namesCode(code, response?.description) && !namesCode(code, o.description)) unnamed.push(`${status}:${code}`);
      }
    }
    if (unnamed.length) finding(o, 'example-code', `the error examples carry ${unnamed.join(', ')}, which no description names`);
    if (words(o.description) < minWords) {
      finding(o, 'thin-description', `${words(o.description)} words of description (at least ${minWords})`);
    }
    const bare = o.params.filter((p) => !(p.description ?? '').trim()).map((p) => `\`${p.name}\``);
    if (bare.length) finding(o, 'param-undocumented', `${bare.join(', ')} ${bare.length === 1 ? 'has' : 'have'} no description`);
    // A tag entry matches only writes; a read is matched only when the map names it by its operationId.
    const why = humanConfirm[o.id] ?? (o.method !== 'GET' ? o.tags.map((t) => humanConfirm[`tag:${t}`]).find(Boolean) : undefined);
    if (why) finding(o, 'human-confirm', why);
  }
  return { ops, findings, tags };
}

function bodySchema(doc, o) {
  const resolve = (node) => resolveIn(doc, node);
  const body = resolve(o.op.requestBody);
  const media = body?.content && Object.values(body.content)[0];
  const schema = resolve(media?.schema);
  if (!schema?.allOf) return schema;
  return { properties: Object.assign({}, ...schema.allOf.map((s) => resolve(s)?.properties ?? {})) };
}

// The codes an error response's examples carry, in order: `example` and each of `examples`, after $ref.
function codesOf(doc, response) {
  const out = [];
  const add = (v) => { if (typeof v?.code === 'string' && !out.includes(v.code)) out.push(v.code); };
  for (const media of Object.values(response?.content ?? {})) {
    for (const ex of Object.values(media?.examples ?? {})) add(resolveIn(doc, ex)?.value);
    add(resolveIn(doc, media?.example));
  }
  return out;
}

const { ops, findings, tags } = check(spec);
const resolve = (node) => resolveIn(spec, node);
// A schema with every $ref inlined and its examples dropped, as read.mjs builds the `read` answer; a cycle stays a $ref.
const inline = inliner(spec).deref;

// What one tool per operation costs: name, description and input schema go out with every request.
function tokens(o) {
  const properties = {};
  const required = [];
  for (const p of o.params) {
    properties[p.name] = { ...inline(p.schema ?? {}), ...(p.description ? { description: p.description } : {}) };
    if (p.required) required.push(p.name);
  }
  const body = resolve(o.op.requestBody);
  const media = body?.content && Object.values(body.content)[0];
  if (media?.schema) {
    properties.body = inline(media.schema);
    if (body.required) required.push('body');
  }
  const tool = { name: o.id, description: [o.summary, o.description].filter(Boolean).join('\n\n'),
    inputSchema: { type: 'object', properties, required } };
  return Math.ceil(JSON.stringify(tool).length / 4);
}

// The `read` budget: characters / 4 of each answer, the median and p90 at floor(p × n) of the sorted list, as the
// measuring scripts take them.
const reads = ops.map((o) => ({ operationId: o.id, chars: size(readAnswer(spec, o).answer) }));
const q = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(p * s.length))] ?? 0; };
const readChars = reads.map((x) => x.chars);
const tok = (chars) => Math.ceil(chars / 4);
const over = reads.filter((x) => x.chars > budget.maxTokens * 4).sort((a, b) => b.chars - a.chars)
  .map((x) => ({ operationId: x.operationId, tokens: tok(x.chars),
    ...(Object.hasOwn(budget.allowOver, x.operationId) ? { allowed: budget.allowOver[x.operationId] } : {}) }));
for (const x of reads) {
  if (Object.hasOwn(budget.allowOver, x.operationId) && x.chars <= budget.maxTokens * 4) {
    findings.push({ severity: 'error', rule: 'budget-stale',
      detail: `readBudget.allowOver names ${x.operationId}, whose \`read\` answer is within the budget (≈ ${tok(x.chars)} tokens)`,
      fix: 'Remove the entry: the list may only shrink.' });
  }
}
const medianChars = q(readChars, 0.5);
const readBudget = { note: 'Each `read` answer as characters / 4; an answer over maxTokens is listed, with the map\'s '
    + 'reason when readBudget.allowOver has one; --strict fails on an unlisted one and on a median over medianTokens',
  maxTokens: budget.maxTokens, medianTokens: budget.medianTokens,
  median: tok(medianChars), p90: tok(q(readChars, 0.9)), max: tok(Math.max(0, ...readChars)),
  medianChars, maxChars: Math.max(0, ...readChars),
  medianOver: medianChars > budget.medianTokens * 4, unallowed: over.filter((x) => !x.allowed).length, over };

const order = { error: 0, warning: 1, info: 2 };
const sortFindings = (list) => list.sort((a, b) => order[a.severity] - order[b.severity] || a.rule.localeCompare(b.rule)
  || (a.operationId ?? '').localeCompare(b.operationId ?? '') || a.detail.localeCompare(b.detail));
sortFindings(findings);

const operations = ops.map((o, i) => {
  const own = findings.filter((f) => f.operationId === o.id && !f.accepted);
  const verdict = own.some((f) => RULES[f.rule].verdict === 'redesign') ? 'redesign'
    : own.some((f) => f.severity !== 'info') ? 'describe' : 'wrap';
  return { operationId: o.id, method: o.method, path: o.path, tags: o.tags, verdict, tokens: tokens(o),
    read: reads[i].chars, firstParagraphWords: words(firstParagraph(o.description)),
    rules: [...new Set(own.map((f) => f.rule))] };
});
const tally = (list) => ({ operations: list.length, wrap: list.filter((o) => o.verdict === 'wrap').length,
  describe: list.filter((o) => o.verdict === 'describe').length,
  redesign: list.filter((o) => o.verdict === 'redesign').length, tokens: list.reduce((n, o) => n + o.tokens, 0) });
const count = (list, s) => list.filter((f) => f.severity === s).length;
const getOps = operations.filter((o) => o.method === 'GET');

// The cut: every operation description is its first paragraph, as an agent sees it in a `search` hit or a short read.
// A finding is new when the full text has no finding of that rule on that operation.
let cut;
if (cutToo) {
  const doc = structuredClone(spec);
  for (const o of specOperations(doc)) if (typeof o.op.description === 'string') o.op.description = firstParagraph(o.op.description);
  const cutFindings = sortFindings(check(doc).findings);
  const key = (f) => `${f.rule}|${f.operationId ?? f.detail}`;
  const full = new Set(findings.filter((f) => !f.accepted).map(key));
  const open = cutFindings.filter((f) => !f.accepted && f.severity !== 'info');
  cut = { note: 'Every operation description cut to its first paragraph; adds are the errors and warnings the cut has '
      + 'and the full text does not', errors: count(open, 'error'), warnings: count(open, 'warning'),
    adds: open.filter((f) => !full.has(key(f))).map(({ fix, ...f }) => f) };
}

process.stdout.write(`${JSON.stringify({
  sources: { contract: specPath.replace(/\\/g, '/'), title: spec.info?.title ?? null, version: spec.info?.version ?? null,
    map: mapPath?.replace(/\\/g, '/') ?? null },
  summary: {
    errors: count(findings, 'error'), warnings: count(findings, 'warning'), info: count(findings, 'info'),
    accepted: findings.filter((f) => f.accepted).length,
    ...tally(operations),
    rules: Object.fromEntries([...Object.keys(RULES), ...MAP_RULES]
      .map((r) => [r, findings.filter((f) => f.rule === r && !f.accepted).length])),
  },
  toolBudget: {
    note: 'Estimated as characters / 4 of each tool\'s name, description and input schema, with every $ref inlined',
    tools: operations.length, tokens: tally(operations).tokens,
    readOnlyTools: getOps.length, readOnlyTokens: tally(getOps).tokens,
    largest: [...operations].sort((a, b) => b.tokens - a.tokens).slice(0, 5).map((o) => ({ operationId: o.operationId, tokens: o.tokens })),
  },
  readBudget,
  ...(cut ? { cut } : {}),
  tags: Object.fromEntries([...tags].sort().map((t) => [t, tally(operations.filter((o) => o.tags.includes(t)))])),
  operations,
  findings,
}, null, 2)}\n`);
