// The live check after one agent inside build-feature's build loop (P2: a script, not a model; owner decision
// 2026-10-23, docs/memory.md): the step that agent worked on, on its side only, so a miss is fixed in the next
// iteration instead of failing the gates after the loop.
//   node step-check.js <artifacts-dir> <run-id> test|build
// Two checks, both of the step the agent worked on (test: the first open step; build: the step of the newest red log):
//   - skills: skill-check.js --live (every skill on the step's `Test skills:` / `Build skills:` line, and on those of
//     the steps folded into it, was loaded); a miss writes skills-missing.md;
//   - scaffold: scaffold-check.js over the files added since <artifacts-dir>/step-base.sha (the HEAD before the step's
//     first test commit), on the agent's side only (test: files under a test tree; build: the others). A file the gate
//     would refuse (written by hand, and not named on a `Hand-written:` line in a form that holds for it) is a miss, and
//     so, on the build side, is a `Hand-written:` line of plan.md in neither form: scaffold-missing.md says why for each.
// A build-side miss opens the step again in the plan, so the loop builds it once more; a test-side miss leaves the plan
// alone and the loop's `when:` skips the build agent. It never fails the node: it prints {"ok", "n", "side", "missing",
// "scaffold"} for that `when:`. What it cannot judge (a blocked plan, no step-base.sha, no run log) is left to the gates
// after the loop, skill-check and scaffold-check, which still run over the whole branch. A `BLOCKED:` line is the node's
// blocked-stop.sh, run before this.
const fs = require('fs');
const path = require('path');
const skills = require('./skill-check.js');
const scaffold = require('./scaffold-check.js');

const TEST_TREE = /(^|\/)src\/(test|testFixtures|integrationTest)\//;

// What the scaffold-check gate would refuse on this side: [{ file, why }], a malformed plan line as file plan.md:<n>
function scaffoldMisses(art, runId, root, side) {
  let base;
  try { base = fs.readFileSync(path.join(art, 'step-base.sha'), 'utf8').trim(); } catch { return []; }
  if (!base) return [];
  let r;
  try { r = scaffold.check({ runId, base, head: 'HEAD', root, plan: path.join(art, 'plan.md') }); } catch { return []; }
  const refused = r.rows
    .filter(x => x.verdict === 'refused' && TEST_TREE.test(x.file) === (side === 'test'))
    .map(x => ({ file: x.file, why: x.refusal }));
  const malformed = side === 'build' ? r.malformed.map(m => ({ file: `plan.md:${m.n}`, why: `\`${m.line}\` is in neither form` })) : [];
  return [...refused, ...malformed];
}

function reopen(art, n) {
  const planFile = path.join(art, 'plan.md');
  let k = 0;
  fs.writeFileSync(planFile, fs.readFileSync(planFile, 'utf8').replace(/^(\s*- )\[[ xX]\]/gm, (m, lead) => (++k === n ? `${lead}[ ]` : m)));
}

function stepCheck(art, runId, root, side) {
  const r = skills.live(art, runId, root, side);
  skills.remedy(art, r);
  const misses = r.n ? scaffoldMisses(art, runId, root, side) : [];
  const file = path.join(art, 'scaffold-missing.md');
  if (!misses.length) fs.rmSync(file, { force: true });
  else {
    const scaffoldSh = `scripts/scaffold.sh${side === 'test' ? ' --test' : ''}`;
    fs.writeFileSync(file, [`# Scaffold missing — step ${r.n}, ${side} side`, '',
      `The scaffold-check gate would refuse these, which the ${side} agent of step ${r.n} wrote by hand or left in plan.md:`, '',
      ...misses.map(m => `- \`${m.file}\`: ${m.why}`), '',
      `- A file a template targets: keep your edits aside, \`git rm\` the file, render it with the command \`${scaffoldSh} --for <path>\` ` +
      'prints, apply your edits again with Edit or `cp`, never by retyping the file (a Write or `cat >` over a rendered file counts as written by hand), then commit. Only when no template that targets it fits what the file needs, add ' +
      '`Hand-written: <path> — template-misfit: <template> — <why>` under the step in the plan instead.',
      '- A file no template targets: add `Hand-written: <path> — no-template: <shape>` under the step in the plan, <shape> ' +
      'in kebab-case, the word an earlier plan used for the same kind of file (enum, exception, ...). Files of one shape ' +
      'under one directory can be named once, as `<dir>/**`.',
      '- A plan.md line in neither form: rewrite it as one of the two above.', ''].join('\n'));
    if (side === 'build') reopen(art, r.n);
  }
  return { ok: r.ok && !misses.length, n: r.n, side, missing: r.missing, scaffold: misses.map(m => m.file) };
}

if (require.main === module) {
  const [art, runId, side] = process.argv.slice(2);
  if (!art || !['test', 'build'].includes(side)) { console.error('usage: node step-check.js <artifacts-dir> <run-id> test|build'); process.exit(2); }
  const r = stepCheck(path.resolve(art), runId, process.cwd(), side);
  if (r.missing.length) console.error(`STEP: step ${r.n}: the ${side} agent never loaded ${r.missing.join(', ')}: skills-missing.md tells the next agent to load them`);
  if (r.scaffold.length) console.error(`STEP: step ${r.n}: scaffold-check would refuse ${r.scaffold.join(', ')} (${side} side): scaffold-missing.md says what to do`);
  console.log(JSON.stringify(r));
}

module.exports = { stepCheck };
