// The STOP policy's shared logic (P2: a script, not a model; owner decisions 2026-10-20 D4, D7, D8 and the STOP rule
// changes; docs/archon/stop-policy.md). Used by stop-check.sh, stop-approve.sh, stop-round.sh and stop-scan.js.
//   node stop-lib.js verdict <input.json>        prints the verdict JSON (see verdict() below)
//   node stop-lib.js classify <policy.json>      stdin: text; prints the categories its STOP wording names, as JSON
//   node stop-lib.js draft-add <policy.json> <draft.json> <ticket> <category> <detail> [--paths <glob>[,<glob>...]]
//   node stop-lib.js record <policy.json> <draft.json> <out file dir> <now iso> --by <who> --words <text>
//                                                 [--until <iso>] [--only <n>[,<n>...]]
//                                                 writes <out dir>/<id>.json with the drafted entries the owner approved
//                                                 in chat (all, or --only those draft numbers), drops them from the draft
//                                                 and prints the file's path (owner decision 2026-11-19: the list round)
//   node stop-lib.js revoke <file.json> <now iso> [<n>]
//   node stop-lib.js show <policy.json> <now iso> <file.json>...
//   node stop-lib.js covered <policy.json> <now iso> <ticket> <category> <file.json>...   exit 0 and the entry, or 4
// Exit 0 ok, 1 error, 2 usage, 4 refused input (an unknown or non-coverable category, a bad expiry, nothing recorded).
// Times: STOP_NOW (ISO) stands in for the clock in every caller; the policy's timezone names the file ids.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

class Refused extends Error {}

function loadPolicy(text) {
  const p = JSON.parse(text);
  if (!p || p.schema !== 1 || !Array.isArray(p.categories) || !Array.isArray(p.standing_rules)
    || !Array.isArray(p.protected_paths) || !Array.isArray(p.paths)) throw new Error('not a schema 1 STOP policy');
  if (p.timezone) process.env.TZ = p.timezone;
  return p;
}

const category = (policy, id) => policy.categories.find(c => c.id === id || c.label === id);
const rx = s => new RegExp(s, 'i');

// The categories a STOP text names (the plan's answer in the pull request, a label list): the strict `match` words.
function classify(text, policy, field = 'match') {
  const hits = [];
  text = String(text).replace(/\s+/g, ' ');   // a wrapped line still names its item
  for (const c of policy.categories) {
    const words = field === 'signals' ? [...c.match, ...(c.signals || [])] : c.match;
    if (words.some(w => rx(w).test(text))) hits.push(c.id);
  }
  return hits;
}

const CHUNK_BREAK = /\n[ \t]*\n|\n(?=[ \t]*(?:[-*+]|\d+[.)])[ \t])|;[ \t]*(?=(?:ticket labels|plan):)/i;
const SENTENCE_END = /(?<=[.!?])\s+/;
const DENIAL_SUBJECT = /^(?:it|this|the|(?:this|the) (?:ticket|plan|change|pull request|step)) (?:touches|needs|makes|has|adds|ships|includes|brings) /;
const CLAUSE_BREAK = /\s*,\s*(?:(?:and|or|nor)\s+)?|\s+(?:and|or|nor)\s+/;
const DENIAL_FILLER = /\b(?:a|an|any|the|new|item|items|stop|here|needed|planned)\b/g;

// One clause of a denial: "no <item>", where <item> is a category's match words or "stop item(s)" and nothing else.
function deniesOnlyCategories(clause, policy) {
  const named = /^no\s+(.*)$/.exec(clause);
  if (!named) return false;
  const item = named[1];
  if (/^stop items?$/.test(item)) return true;
  let hit = false;
  let rest = item;
  for (const c of policy.categories) for (const w of c.match) {
    rest = rest.replace(new RegExp(w, 'gi'), () => { hit = true; return ' '; });
  }
  return hit && rest.replace(/[()[\]:"'`,-]/g, ' ').replace(DENIAL_FILLER, '').trim() === '';
}

function isDenial(sentence, policy) {
  const text = sentence.toLowerCase()
    .replace(/^(?:[-*+]|\d+[.)])\s+/, '')
    .replace(/^(?:ticket labels|plan):\s*/, '')
    .replace(/[.!?]+$/, '')
    .trim()
    .replace(DENIAL_SUBJECT, '');
  return text.split(CLAUSE_BREAK).every(clause => deniesOnlyCategories(clause, policy));
}

// The categories a plan's STOP text names, read sentence by sentence: a sentence that only denies categories ("No
// contract change and no migration.") names none. kept/denied are the sentences, whitespace collapsed.
function planCategories(text, policy) {
  const sentences = String(text).replace(/\r/g, '').split(CHUNK_BREAK)
    .flatMap(chunk => chunk.replace(/\s+/g, ' ').trim().split(SENTENCE_END))
    .filter(Boolean);
  const kept = sentences.filter(s => !isDenial(s, policy));
  const denied = sentences.filter(s => isDenial(s, policy));
  return { categories: classify(kept.join(' '), policy), kept, denied };
}

// A glob with `**` (any folders, also none), `*` (no slash) and `?`.
function globRx(glob) {
  let s = '';
  for (let i = 0; i < glob.length; i++) {
    const ch = glob[i];
    if (ch === '*' && glob[i + 1] === '*') { s += glob[i + 2] === '/' ? '(?:.*/)?' : '.*'; i += glob[i + 2] === '/' ? 2 : 1; }
    else if (ch === '*') s += '[^/]*';
    else if (ch === '?') s += '[^/]';
    else s += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${s}$`);
}
const matches = (glob, file) => globRx(glob).test(file);

// The digest that ties an entry to its file's grant: any edit after recording (other ticket, category, detail, paths,
// times, owner or recorder) makes it fail. It detects a hand edit. A file from before 2026-11-19 has no recorded_by and
// no paths, and its digest leaves them out.
function digest(file, e) {
  const parts = [file.id, file.granted_at, file.expires_at, file.signed_by, e.n, e.ticket, e.category, e.detail];
  if (file.recorded_by !== undefined) parts.push(file.recorded_by, (e.paths || []).join(','));
  return crypto.createHash('sha256').update(parts.join('|')).digest('hex');
}

const DAY = 24 * 3600 * 1000;
const maxDays = policy => (policy.expiry && policy.expiry.max_days) || 7;
// An approval lasts until its ticket merges, at most max_days (owner decision 2026-11-19): the default is the maximum.
const defaultExpiry = (now, policy) => now + maxDays(policy) * DAY;
function checkExpiry(granted, expires, policy) {
  if (Number.isNaN(expires)) return 'no valid expiry';
  if (expires <= granted) return 'expires before it was granted';
  if (expires - granted > maxDays(policy) * DAY) return `valid for more than ${maxDays(policy)} days`;
  return '';
}

// The paths a governance entry covers: repo paths or globs, none starting with `*` (that would cover every path).
function parsePaths(text) {
  const paths = String(text || '').split(',').map(p => p.trim().replace(/^\.\//, '')).filter(Boolean);
  const bad = paths.find(p => /^[*?]/.test(p) || p.startsWith('/') || p.split('/').includes('..'));
  if (bad) throw new Refused(`not a repo path or a narrow glob: ${bad}`);
  return paths;
}

// Why an approval file grants nothing at `now` ('' when it may grant).
function fileProblem(f, policy, now) {
  if (!f || f.schema !== 1 || !f.id || !Array.isArray(f.entries)) return 'not a schema 1 approvals file';
  if (f.signed_by !== policy.owner) return `approved for "${f.signed_by}", not the owner`;
  const granted = Date.parse(f.granted_at), expires = Date.parse(f.expires_at);
  if (Number.isNaN(granted)) return 'no valid granted_at';
  const bad = checkExpiry(granted, expires, policy);
  if (bad) return bad;
  if (f.revoked_at) return `revoked at ${f.revoked_at}`;
  if (now < granted) return 'granted in the future';
  if (now >= expires) return `expired at ${f.expires_at}`;
  return '';
}
function entryProblem(f, e, policy) {
  if (!e || !e.ticket || !e.category) return 'entry without ticket or category';
  if (e.revoked_at) return `entry revoked at ${e.revoked_at}`;
  if (e.digest !== digest(f, e)) return 'digest does not match: edited after signing';
  const c = category(policy, e.category);
  if (!c) return `unknown category ${e.category}`;
  if (!c.coverable) return `${c.id} is never covered by an approval`;
  if (c.needs_paths && !(Array.isArray(e.paths) && e.paths.length)) return `a ${c.id} entry must name its paths`;
  return '';
}

const key = id => String(id || '').trim().toUpperCase();

// input: { policy, ticket, now, mode: 'pr'|'ticket'|'cleanup', labels: [], plan_text, files: [], approvals: [{name, text}],
//          cleanup: { ok, reason } }
// Each item is judged, first match wins: unknown category → owner; never coverable → owner; an active standing rule for
// the category (and the mode, when the rule names one) → covered; a valid entry (the owner's chat approval) for exactly this ticket and
// category → covered; else owner. A protected path in the diff is an item of its own: covered only by a valid governance
// entry for this ticket whose paths match that file, else owner. No item → none. A sentence of the plan text that only
// denies categories ("No contract change and no migration.") names no item.
function verdict(input) {
  const policy = input.policy;
  const now = input.now;
  const items = [];
  const add = (cat, source, detail) => {
    if (!items.some(i => i.category === cat && i.source === source && i.detail === detail)) items.push({ category: cat, source, detail });
  };
  for (const l of input.labels || []) {
    if (!/^stop-/.test(l)) continue;
    const c = category(policy, l);
    add(c ? c.id : `unknown:${l}`, 'label', l);
  }
  const plan = String(input.plan_text || '').trim();
  if (plan) {
    const { categories, kept } = planCategories(plan, policy);
    const detail = c => (kept.find(k => rx(category(policy, c).match.join('|')).test(k)) || kept[0]).slice(0, 160);
    if (categories.length) categories.forEach(c => add(c, 'plan', detail(c)));
    else if (kept.some(k => /[a-z]/i.test(k))) add('unknown:plan', 'plan', kept[0].slice(0, 160));
  }
  const protectedHits = [];
  for (const f of input.files || []) {
    if (policy.protected_paths.some(g => matches(g, f))) protectedHits.push(f);
    for (const p of policy.paths) if (matches(p.glob, f)) add(p.category, 'diff', f);
  }
  if (input.mode === 'cleanup') add('delete-history', 'cleanup', input.cleanup && input.cleanup.reason || '');

  const files = [];
  const unread = [];
  for (const a of input.approvals || []) {
    let f;
    try { f = JSON.parse(a.text); } catch (e) { unread.push(`${a.name}: not JSON`); continue; }
    const why = fileProblem(f, policy, now);
    if (why) { unread.push(`${a.name}: ${why}`); continue; }
    files.push(f);
  }
  const ticket = key(input.ticket);
  for (const it of items) {
    const c = category(policy, it.category);
    if (!c) { it.verdict = 'owner'; it.reason = it.category === 'unknown:plan'
      ? 'the STOP text names no known category' : `unknown STOP label ${it.detail}`; continue; }
    if (!c.coverable) { it.verdict = 'owner'; it.reason = `${c.id} is never covered: the owner decides each one`; continue; }
    if (it.source === 'cleanup' && !(input.cleanup && input.cleanup.ok)) {
      it.verdict = 'owner'; it.reason = `not all in main: ${it.detail}`; continue;
    }
    const rule = policy.standing_rules.find(r => r.active && r.covers.includes(c.id) && (!r.mode || r.mode === input.mode));
    if (rule) { it.verdict = 'covered'; it.covered_by = `rule:${rule.id}`; it.reason = rule.source; continue; }
    let hit = null, why = '';
    for (const f of files) for (const e of f.entries) {
      if (key(e.ticket) !== ticket) continue;
      const ec = category(policy, e.category);
      if (!ec || ec.id !== c.id) continue;
      const p = entryProblem(f, e, policy);
      if (p) { why = `approval ${f.id}#${e.n}: ${p}`; continue; }
      hit = hit || { f, e };
    }
    if (hit) { it.verdict = 'covered'; it.covered_by = `approval:${hit.f.id}#${hit.e.n}`; it.reason = hit.e.detail; continue; }
    it.verdict = 'owner'; it.reason = why || `no approval in chat for ${ticket || 'this ticket'} ${c.id}`;
  }
  for (const p of protectedHits) {
    let hit = null;
    for (const f of files) for (const e of f.entries) {
      if (hit || key(e.ticket) !== ticket || (category(policy, e.category) || {}).id !== 'governance') continue;
      if (entryProblem(f, e, policy)) continue;
      if ((e.paths || []).some(g => matches(g, p))) hit = { f, e };
    }
    items.push(hit
      ? { category: 'governance', source: 'protected-path', detail: p, verdict: 'covered',
        covered_by: `approval:${hit.f.id}#${hit.e.n}`, reason: hit.e.detail }
      : { category: 'governance', source: 'protected-path', detail: p, verdict: 'owner',
        reason: 'a protected path no approval for this ticket names: the owner decides (#151 precedent)' });
  }
  const v = items.length === 0 ? 'none' : items.some(i => i.verdict === 'owner') ? 'owner' : 'covered';
  return { verdict: v, mode: input.mode, ticket: input.ticket || null, items, approvals_ignored: unread,
    checked_at: new Date(now).toISOString() };
}

function localStamp(ms) {
  const d = new Date(ms), p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

function main(argv) {
  const [cmd, ...a] = argv;
  const read = f => fs.readFileSync(f, 'utf8');
  switch (cmd) {
    case 'verdict': {
      const input = JSON.parse(read(a[0]));
      input.policy = loadPolicy(input.policy_text);
      input.now = Date.parse(input.now);
      if (Number.isNaN(input.now)) throw new Error('no valid time to judge at (STOP_NOW?)');
      process.stdout.write(JSON.stringify(verdict(input), null, 2) + '\n');
      return 0;
    }
    case 'classify': {
      const policy = loadPolicy(read(a[0]));
      process.stdout.write(JSON.stringify(classify(read('/dev/stdin'), policy, a[1] === '--signals' ? 'signals' : 'match')) + '\n');
      return 0;
    }
    case 'draft-add': {
      const pathsText = a.indexOf('--paths') >= 0 ? a.splice(a.indexOf('--paths'), 2)[1] : '';
      const [pf, df, ticket, cat, ...rest] = a;
      const policy = loadPolicy(read(pf));
      const detail = rest.join(' ').trim();
      if (!/^TASK-\d+(\.\d+)*$/i.test(ticket || '')) throw new Refused(`not a ticket id: ${ticket}`);
      const c = category(policy, cat || '');
      if (!c) throw new Refused(`unknown STOP category: ${cat} (known: ${policy.categories.map(x => x.id).join(', ')})`);
      if (!c.coverable) throw new Refused(`${c.id} is never covered by an approval: the owner decides each one when it comes`);
      if (!detail) throw new Refused('say what is approved: the detail is the action the entry covers');
      const paths = parsePaths(pathsText);
      if (c.needs_paths && !paths.length) throw new Refused(`a ${c.id} entry must name the paths it covers: --paths <glob>[,<glob>...]`);
      const d = fs.existsSync(df) ? JSON.parse(read(df)) : { schema: 1, entries: [] };
      if (d.entries.some(e => key(e.ticket) === key(ticket) && e.category === c.id)) throw new Refused(`${key(ticket)} ${c.id} is already drafted`);
      d.entries.push({ ticket: key(ticket), category: c.id, detail, ...(paths.length ? { paths } : {}) });
      fs.mkdirSync(path.dirname(df), { recursive: true });
      fs.writeFileSync(df, JSON.stringify(d, null, 2) + '\n');
      console.log(`drafted ${d.entries.length}: ${key(ticket)} ${c.id} — ${detail}${paths.length ? ` (paths: ${paths.join(', ')})` : ''}`);
      return 0;
    }
    case 'record': {
      const opt = name => { const i = a.indexOf(name); return i >= 0 ? a.splice(i, 2)[1] : undefined; };
      const by = opt('--by'), words = opt('--words'), untilIso = opt('--until'), only = opt('--only');
      const [pf, df, outDir, nowIso] = a;
      const policy = loadPolicy(read(pf));
      const now = Date.parse(nowIso);
      if (!by || !String(by).trim()) throw new Refused('say who records it: --by <the owner\'s chat session or delegator>');
      if (!words || !String(words).trim()) throw new Refused('--words is required: the owner\'s own words from the chat that approve these entries');
      if (!fs.existsSync(df)) throw new Refused(`no draft at ${df}: draft the entries first`);
      const d = JSON.parse(read(df));
      const pick = only ? String(only).split(',').map(n => Number(n.trim())) : d.entries.map((_, i) => i + 1);
      if (pick.some(n => !Number.isInteger(n) || n < 1 || n > d.entries.length)) throw new Refused(`--only names a draft number that does not exist (1 to ${d.entries.length})`);
      const expires = untilIso ? Date.parse(untilIso) : defaultExpiry(now, policy);
      const bad = checkExpiry(now, expires, policy);
      if (bad) throw new Refused(`refused expiry: ${bad}`);
      const file = { schema: 1, id: localStamp(now), granted_at: new Date(now).toISOString(),
        expires_at: new Date(expires).toISOString(), revoked_at: null, signed_by: policy.owner,
        recorded_by: String(by).trim(), words: String(words).trim(), entries: [] };
      for (const i of pick) {
        const e = d.entries[i - 1];
        const c = category(policy, e.category);
        if (!c || !c.coverable) throw new Refused(`draft ${i}: ${e.category} cannot be approved in advance`);
        if (c.needs_paths && !(e.paths || []).length) throw new Refused(`draft ${i}: a ${c.id} entry must name its paths`);
        const entry = { n: file.entries.length + 1, ticket: e.ticket, category: c.id, detail: e.detail,
          ...(e.paths && e.paths.length ? { paths: e.paths } : {}), revoked_at: null };
        entry.digest = digest(file, entry);
        file.entries.push(entry);
      }
      if (!file.entries.length) throw new Refused('nothing to record');
      fs.mkdirSync(outDir, { recursive: true });
      const out = path.join(outDir, `${file.id}.json`);
      if (fs.existsSync(out)) throw new Refused(`${out} exists: record again in a minute`);
      fs.writeFileSync(out, JSON.stringify(file, null, 2) + '\n');
      const left = d.entries.filter((_, i) => !pick.includes(i + 1));
      if (left.length) fs.writeFileSync(df, JSON.stringify({ ...d, entries: left }, null, 2) + '\n'); else fs.unlinkSync(df);
      console.log(`recorded ${file.entries.length} of ${d.entries.length}: ${out}`);
      return 0;
    }
    case 'revoke': {
      const [ff, nowIso, n] = a;
      const f = JSON.parse(read(ff));
      const at = new Date(Date.parse(nowIso)).toISOString();
      if (n) { const e = f.entries.find(x => String(x.n) === String(n)); if (!e) throw new Refused(`no entry ${n} in ${ff}`); e.revoked_at = at; }
      else f.revoked_at = at;
      fs.writeFileSync(ff, JSON.stringify(f, null, 2) + '\n');
      console.log(`revoked ${n ? `${f.id}#${n}` : f.id} at ${at}`);
      return 0;
    }
    case 'show': {
      const [pf, nowIso, ...files] = a;
      const policy = loadPolicy(read(pf));
      const now = Date.parse(nowIso);
      for (const ff of files) {
        let f; try { f = JSON.parse(read(ff)); } catch (e) { console.log(`${ff}: not JSON`); continue; }
        if (!f.granted_at) { (f.entries || []).forEach((e, i) => console.log(`draft ${i + 1}: ${e.ticket} ${e.category} — ${e.detail}${(e.paths || []).length ? ` (paths: ${e.paths.join(', ')})` : ''}`)); continue; }
        const why = fileProblem(f, policy, now);
        console.log(`${f.id}: ${why ? `grants nothing (${why})` : `active until ${f.expires_at}`}`);
        for (const e of f.entries || []) {
          const p = why || entryProblem(f, e, policy);
          console.log(`  #${e.n} ${e.ticket} ${e.category}: ${p ? `inactive (${p})` : 'active'} — ${e.detail}`);
        }
      }
      return 0;
    }
    case 'covered': {   // covered <policy.json> <now iso> <ticket> <category> <file.json>...: exit 0 when a valid entry covers it
      const [pf, nowIso, ticket, cat, ...files] = a;
      const policy = loadPolicy(read(pf));
      const now = Date.parse(nowIso);
      for (const ff of files) {
        let f; try { f = JSON.parse(read(ff)); } catch (e) { continue; }
        if (fileProblem(f, policy, now)) continue;
        const e = f.entries.find(x => key(x.ticket) === key(ticket) && (category(policy, x.category) || {}).id === cat && !entryProblem(f, x, policy));
        if (e) { console.log(`approval:${f.id}#${e.n}`); return 0; }
      }
      return 4;
    }
    default:
      console.error('usage: stop-lib.js verdict|classify|draft-add|record|revoke|show|covered ...');
      return 2;
  }
}

module.exports = { loadPolicy, classify, planCategories, matches, digest, defaultExpiry, checkExpiry, fileProblem, entryProblem, verdict, category, parsePaths };

if (require.main === module) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (e) { console.error(`stop-lib: ${e.message}`); process.exitCode = e instanceof Refused ? 4 : 1; }
}
