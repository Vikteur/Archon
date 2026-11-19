// Ratchet: do the pinned contract's readiness numbers still equal the ones the repo wrote down? Read-only.
// The measured values come from a readiness report made with --first-paragraph and a findability JSON of one spec:
//   errors, warnings:   the report's summary;
//   cutAdds:            the findings only the first-paragraph cut has (report `cut.adds`);
//   readMedianTokens:   the median `read` answer (report `readBudget.median`);
//   recallAt10:         findability recall at 10 in mode (b), a floor: higher is better, the others are ceilings.
// Each value must equal the ratchet's. Better fails too, asking to write the new value down, so a gain is kept; worse
// fails with what grew. With --base (the ratchet file as it is on origin/main), no ceiling may be above the base's and
// no floor below it, unless --rules-changed says the same diff changes the checker or the map's look-alikes, humanConfirm
// or explainStatuses: new rules and entries add findings on purpose, a pin bump alone never may.
// Usage: node ratchet.mjs --ratchet <ratchet.json> --report <readiness-report.json> --findability <findability.json>
//          [--base <ratchet.json>] [--rules-changed]
// Exits 1 when a value differs or a raise is not allowed, 2 on a usage error or a file it cannot read.
import { readFileSync } from 'node:fs';

const KEYS = { errors: 'ceiling', warnings: 'ceiling', cutAdds: 'ceiling', readMedianTokens: 'ceiling', recallAt10: 'floor' };

const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const usage = (msg) => { console.error(`ratchet: ${msg}`); process.exit(2); };
const read = (path, what) => {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch (e) { return usage(`cannot read ${what} ${path}: ${e.message}`); }
};
const [ratchetPath, reportPath, fyPath, basePath] = ['--ratchet', '--report', '--findability', '--base'].map(opt);
if (!ratchetPath || !reportPath || !fyPath) usage('--ratchet, --report and --findability are required');
const ratchet = read(ratchetPath, 'the ratchet');
const report = read(reportPath, 'the report');
const fy = read(fyPath, 'the findability JSON');
const base = basePath ? read(basePath, 'the base ratchet') : null;
const rulesChanged = args.includes('--rules-changed');
if (!report.cut) usage(`${reportPath} has no cut: make it with --first-paragraph`);
for (const key of Object.keys(KEYS)) if (typeof ratchet[key] !== 'number') usage(`the ratchet has no number ${key}`);

const measured = {
  errors: report.summary.errors,
  warnings: report.summary.warnings,
  cutAdds: report.cut.adds.length,
  readMedianTokens: report.readBudget.median,
  recallAt10: fy.before.recall.b['10'],
};
// What grew, so a worse value says where to look.
const grew = {
  errors: () => report.findings.filter((f) => f.severity === 'error').map((f) => `${f.rule}:${f.operationId ?? ''}`),
  warnings: () => report.findings.filter((f) => f.severity === 'warning').map((f) => `${f.rule}:${f.operationId ?? ''}`),
  cutAdds: () => report.cut.adds.map((f) => `${f.rule}:${f.operationId}`),
  readMedianTokens: () => [],
  recallAt10: () => [],
};

const problems = [];
for (const [key, kind] of Object.entries(KEYS)) {
  const want = ratchet[key];
  const got = measured[key];
  if (got === want) continue;
  const better = kind === 'ceiling' ? got < want : got > want;
  if (better) problems.push(`${key} is ${got}, better than ${want}: ${kind === 'ceiling' ? 'lower' : 'raise'} ratchet.${key} to ${got}`);
  else {
    const list = grew[key]();
    problems.push(`${key} is ${got}, worse than ${want}${list.length ? `: ${list.join(', ')}` : ''}`);
  }
}
if (base && !rulesChanged) {
  for (const [key, kind] of Object.entries(KEYS)) {
    if (typeof base[key] !== 'number') continue;
    const raised = kind === 'ceiling' ? ratchet[key] > base[key] : ratchet[key] < base[key];
    if (raised) problems.push(`ratchet.${key} ${kind === 'ceiling' ? 'rises' : 'falls'} from ${base[key]} to ${ratchet[key]} `
      + 'without a change to check.mjs or the map\'s lookAlikes, humanConfirm or explainStatuses');
  }
}
for (const p of problems) console.error(`[ratchet] ${p}`);
if (problems.length) process.exit(1);
console.log(`[ratchet] ${Object.entries(measured).map(([k, v]) => `${k} ${v}`).join(', ')}: as written down`);
