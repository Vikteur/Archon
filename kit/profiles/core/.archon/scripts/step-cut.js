// Cuts the step an agent of the build loop works on out of plan.md into <artifacts-dir>/step.md (P2: a script, not a
// model), so the test and the build agent read one step instead of the whole plan.
//   node step-cut.js <artifacts-dir>
// The step is the first checkbox line still marked `- [ ]`; n is its position among the plan's checkbox lines
// (`- [ ]`, `- [x]`, at any indent; the first is 1), the number step-base and the red/step-<n>.log names use. Its block
// runs from that line to the line before the next checkbox line or the next Markdown heading outside a code fence.
// step.md holds, in this order: a title with n and the step count, the step's block, the block of every open step
// marked `(folded into step <n>)` (built with this one), the plan's `## Owner decisions` section, and every `ANSWER:`
// line of the plan. plan.md stays the file the agents mark, and add `Hand-written:` and `BLOCKED:` lines to.
// No open step removes a step.md left from an earlier step. Prints one line; exits 0, 1 without plan.md, 2 on usage.
const fs = require('fs');
const path = require('path');

const CHECKBOX = /^\s*- \[[ xX]\]/;
const OPEN = /^\s*- \[ \]/;
const HEADING = /^#{1,6}\s/;

// [{ n, open, start, end }] over the checkbox lines; end is the index after the block's last line
function steps(lines) {
  const out = [];
  let fence = '';
  lines.forEach((line, i) => {
    const mark = (/^\s*(`{3,}|~{3,})/.exec(line) || [])[1];
    if (mark && (!fence || mark[0] === fence)) fence = fence ? '' : mark[0];
    const last = out[out.length - 1];
    if (CHECKBOX.test(line)) {
      if (last && last.end === undefined) last.end = i;
      out.push({ n: out.length + 1, open: OPEN.test(line), start: i });
    } else if (!fence && HEADING.test(line) && last && last.end === undefined) {
      last.end = i;
    }
  });
  const last = out[out.length - 1];
  if (last && last.end === undefined) last.end = lines.length;
  return out;
}

function trimBlock(lines) {
  const block = [...lines];
  while (block.length && !block[block.length - 1].trim()) block.pop();
  return block.join('\n');
}

function section(lines, title) {
  const i = lines.findIndex(l => new RegExp(`^## ${title}\\s*$`).test(l));
  if (i < 0) return '';
  let j = i + 1;
  while (j < lines.length && !/^## /.test(lines[j])) j++;
  return trimBlock(lines.slice(i, j));
}

function cut(art) {
  const planFile = path.join(art, 'plan.md');
  const stepFile = path.join(art, 'step.md');
  if (!fs.existsSync(planFile)) return { code: 1, msg: `step-cut: no plan at ${planFile}` };
  const lines = fs.readFileSync(planFile, 'utf8').split(/\r?\n/);
  const all = steps(lines);
  const step = all.find(s => s.open);
  if (!step) {
    fs.rmSync(stepFile, { force: true });
    return { code: 0, msg: 'step-cut: no open step' };
  }
  const folded = all.filter(s => s.open && s.n > step.n && new RegExp(`\\(folded into step ${step.n}\\)`, 'i').test(lines[s.start]));
  const parts = [
    `# Step ${step.n} of ${all.length}`,
    `Cut from plan.md by step-cut.js. n = ${step.n}. Mark the step, and add a Hand-written or BLOCKED line, in plan.md.`,
    trimBlock(lines.slice(step.start, step.end)),
  ];
  for (const s of folded) parts.push(`## Folded into this step: step ${s.n}`, trimBlock(lines.slice(s.start, s.end)));
  const decisions = section(lines, 'Owner decisions');
  if (decisions) parts.push(decisions);
  const answers = lines.filter(l => /^\s*ANSWER:/.test(l));
  if (answers.length) parts.push('## Answers in the plan', answers.join('\n'));
  fs.writeFileSync(stepFile, `${parts.join('\n\n')}\n`);
  return { code: 0, msg: `step-cut: step ${step.n} of ${all.length} in step.md` };
}

if (require.main === module) {
  const art = process.argv[2];
  if (!art || process.argv.length > 3) {
    console.error('usage: node step-cut.js <artifacts-dir>');
    process.exit(2);
  }
  const r = cut(art);
  (r.code ? console.error : console.log)(r.msg);
  process.exit(r.code);
}

module.exports = { cut, steps };
