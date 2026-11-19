#!/usr/bin/env node
// The request a build-feature run starts with: `<TASK-id>: <label>`, the label being two or three words of the
// ticket's title, so the console's run list and run log say what the run builds (P2: a rule, not a model).
//   node .archon/scripts/run-label.js <TASK-id>            prints the request, the title read from Backlog
//   node .archon/scripts/run-label.js --title "<title>"    prints only the label of that title
// The label: the title without its `[P1]`-style tags, `Epic:` and a leading old ticket code (`P0-E02-T04a`), cut at
// the first `,;:(`, without articles and possessives, up to the first linking word (with, by, and, ...) once two
// words are kept, at most three words, lower case except acronyms. Only letters, digits, spaces, `.` and `-` remain,
// so the request is safe in a shell argument and every reader's `TASK-<n>` match still finds the id first.
// Backlog is read from the current directory (the main checkout; BACKLOG_CWD overrides). A ticket Backlog cannot read,
// or a title that leaves no word, prints the bare `<TASK-id>`: a label never stops a launch.
// Exit codes: 0 printed; 2 bad usage or not a TASK id.
'use strict';
const { execFileSync } = require('child_process');

const DROP = new Set('a an the my your its their his her this that'.split(' '));
const CUT = new Set('with by from for of in on to into within before after keeping refusing and or as at which'.split(' '));
const MAX_WORDS = 3;
const MAX_CHARS = 40;

/** Two or three words that say what a ticket title is about; '' when none remain. */
function label(title) {
  let t = String(title || '')
    .replace(/^(\s*\[[^\]]*\]\s*)+/, '')
    .replace(/^\s*Epic:\s*/i, '')
    .replace(/^\s*P\d+-E\d+-T\d+[a-z]?\s+/i, '')
    .replace(/\bTASK-\d+(\.\d+)*/gi, '')
    .replace(/['’]s\b/g, '');
  t = t.split(/[,;:(]/)[0];
  const words = [];
  for (const raw of t.split(/\s+/)) {
    const w = raw.replace(/[^A-Za-z0-9.-]/g, '').replace(/^[.-]+|[.-]+$/g, '');
    if (!w) continue;
    const lower = w.toLowerCase();
    if (words.length >= 2 && CUT.has(lower)) break;
    if (DROP.has(lower)) continue;
    words.push(/^[A-Z0-9]{2,}$/.test(w) && /[A-Z]/.test(w) ? w : lower);
    if (words.length === MAX_WORDS) break;
  }
  let out = words.join(' ');
  while (out.length > MAX_CHARS && words.length > 1) { words.pop(); out = words.join(' '); }
  return out.slice(0, MAX_CHARS);
}

/** The ticket title Backlog shows for an id, or '' when Backlog cannot read it. */
function titleOf(id) {
  try {
    const out = execFileSync('backlog', ['task', 'view', id, '--plain'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], cwd: process.env.BACKLOG_CWD || process.cwd(),
    });
    const m = out.match(/^Task\s+TASK-[\d.]+\s+-\s+(.+)$/m);
    return m ? m[1].trim() : '';
  } catch { return ''; }
}

function request(id, title) {
  const l = label(title);
  return l ? `${id}: ${l}` : id;
}

function main(argv) {
  const usage = () => { console.error('usage: run-label.js <TASK-id> | --title "<title>"'); process.exit(2); };
  if (argv[0] === '--title') { if (argv.length !== 2) usage(); console.log(label(argv[1])); return; }
  if (argv.length !== 1) usage();
  const id = argv[0].toUpperCase();
  if (!/^TASK-\d+(\.\d+)*$/.test(id)) { console.error(`run-label: not a TASK id: ${argv[0]}`); process.exit(2); }
  console.log(request(id, titleOf(id)));
}

if (require.main === module) main(process.argv.slice(2));
module.exports = { label, request };
