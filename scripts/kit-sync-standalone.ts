/**
 * The kit's build workflows run standalone (kit/SPEC.md, Plan approval and human merge): a person approves the plan,
 * the run builds and brings its pull request to ready, and a team member reviews and merges it. The source's workflows
 * go on after `ready` (a merge queue, a wait for the delegator or the owner to merge, the post-merge close-out) and
 * never pause; kit-sync cuts that tail, adds the plan approval and rewrites the text that names what is cut.
 *
 * Every step is checked (P2): a node id the cut expects that is gone, a node in the tail it does not know, an anchor
 * whose count does not fit, or a cut name still in the result fails the sync, so a source change under the transform
 * is seen at the next sync instead of shipping half a workflow.
 */
import type { Rewrite } from './kit-sync-lists';

export const BUILD_WORKFLOW = '.archon/workflows/build-feature.yaml';
export const COPILOT_WORKFLOW = '.archon/workflows/build-feature-copilot.yaml';
export const STANDALONE_WORKFLOWS = [BUILD_WORKFLOW, COPILOT_WORKFLOW];

/** The nodes after `ready`, in order: the merge queue, the wait for the merge and the post-merge close-out. */
export const TAIL_IDS = [
  'auto-merge',
  'merged',
  'main-ci',
  'ticket-files',
  'finalize',
  'close-out',
];

/** The node the plan approval waits on, and the node it gates. */
const BEFORE_GATE = 'stop-route';
const GATED = 'implement';

export const PLAN_APPROVAL = [
  '  # One human gate (kit/SPEC.md, Plan approval and human merge): a person approves the plan before any code is',
  '  # written. Answer it in the Archon console or with `archon workflow approve <run-id> [text]` or',
  '  # `archon workflow reject <run-id> <why>`. A rejection ends the run and no code is written: fix the ticket or the',
  '  # request and start a new run. The approval text reaches the agents as reviewer notes.',
  '  - id: plan-approval',
  `    depends_on: [${BEFORE_GATE}]`,
  '    wait:',
  '      form: approval',
  '      attention: |',
  '        Approve the plan before the run writes any code.',
  '        Ticket: $ticket.output.task',
  '        Plan: $ARTIFACTS_DIR/plan.md',
  '        STOP items the ticket or the plan touches (empty: none): $stop-route.output.why',
  '        Approve to build it; reject (with the reason) to end the run.',
  '',
  '  - id: plan-rejected',
  '    depends_on: [plan-approval]',
  '    when: "$plan-approval.output.decision == \'reject\'"',
  '    cancel: The plan was rejected, so no code was written. Fix the ticket or the request and start a new run.',
  '',
  '',
].join('\n');

/** Text that names the cut nodes or the delegator, in both workflows. [from, to, count] on the cut text. */
const COMMON: Rewrite[] = [
  [
    'plan (no Gradle; no\n  approval stop; STOP items the ticket or the plan touches are named in the pull request)',
    'plan (no Gradle) -> a person\n  approves the plan, its STOP items named, or rejects it and the run ends',
    1,
  ],
  [
    'SHA, fix a red run (at most 3 rounds) -> mark it ready -> wait until every review is done and CI on its head is green\n' +
      '  (the GitHub agent resolves a merge conflict or a red run on the way) -> wait for the delegator or the owner to merge\n' +
      '  it (the run never merges) -> finalize the Backlog ticket (Done) ->\n' +
      "  commit and push the Backlog ticket, and delete the run's branch and worktree. The retro",
    'SHA, fix a red run (at most 3 rounds) -> mark it ready for review. The run ends there: a team member reviews and\n' +
      '  merges the pull request and closes the Backlog ticket; the run never merges. The retro',
    1,
  ],
  [
    '# SHA, the merge gate.\n' +
      '# No human gate (owner decision 2026-10-17, docs/memory.md): the run never pauses for a STOP approval. It never merges\n' +
      '# its own pull request either (owner decision 2026-10-18, docs/memory.md, TASK-58): once every review is done and CI is\n' +
      '# green it waits for the delegator or the owner to merge it.\n',
    '# SHA.\n' +
      '# One human gate: a person approves the plan (plan-approval) before any code is written; a rejection ends the run. The\n' +
      '# run never merges its own pull request: it ends once the pull request is ready, and a team member reviews and merges.\n',
    1,
  ],
  [
    '  # The STOP items the ticket labels or the plan name are listed for the pull request; nothing pauses on them.\n' +
      '  # stop-items.txt is what pr-refresh.sh writes as the body\'s "STOP items touched:" line, the line stop-check.sh reads\n' +
      '  # (P2: a model once worded it "This ticket touches no STOP item." and the merge waited for the owner, PR #196).\n',
    '  # The STOP items the ticket labels or the plan name are listed for the plan approval and the pull request.\n' +
      '  # stop-items.txt is what pr-refresh.sh writes as the body\'s "STOP items touched:" line (P2: a script words it).\n',
    1,
  ],
  [
    'step. No run pauses for it (no human gate, owner decision 2026-10-17): the run fails.',
    'step. The run does not wait for the answer: it fails.',
    1,
  ],
  [
    "The ticket is edited in the backlog checkout; close-out commits it with the ticket's Done.",
    'The ticket is edited in the backlog checkout and\n  # left uncommitted there: whoever closes the ticket after the merge commits it.',
    1,
  ],
  [
    'the pull request opens as a draft, and the GitHub agent resolves it in the auto-merge loop.',
    'the pull request opens as a draft, and the ready node fails the run on it.',
    1,
  ],
  [
    'echo "The base conflicts with this branch: the GitHub agent resolves it before the merge." >&2',
    'echo "The base conflicts with this branch: the pull request opens as a draft." >&2',
    1,
  ],
  [
    '  # No review gate before the push. The run never merges: the delegator or the owner does (TASK-58).\n',
    '  # No review gate before the push. The run never merges: a team member does.\n',
    1,
  ],
  [
    '`## Merge` saying that the delegator or the owner merges this pull request, never the build-feature workflow\n' +
      '      itself, once every requested review is given, no review requests changes, every review thread is resolved and CI\n' +
      '      on its head commit is green (owner decision 2026-10-18, docs/memory.md). A reviewer holds the merge by requesting\n' +
      '      changes.',
    '`## Merge` saying that a team member reviews and merges this pull request, never the build-feature workflow\n' +
      '      itself, once CI on its head commit is green. A reviewer holds the merge by requesting\n      changes.',
    1,
  ],
  [
    'no agent fixes the machine; the delegator resumes it once that is fixed.',
    'no agent fixes the machine; a person resumes it once that is fixed.',
    1,
  ],
  [
    'leaves it a draft\n  # for the GitHub agent in the auto-merge loop.',
    'leaves it a draft\n  # and fails the run, so a person sees it.',
    1,
  ],
  [
    '(CI_FIX_NO_COMMIT). classify-failure.js matches both tokens. No node\n',
    '(CI_FIX_NO_COMMIT). No node\n',
    1,
  ],
  ['it stays a draft for the GitHub agent." >&2 ;;', 'it stays a draft." >&2; exit 1 ;;', 2],
];

/** Per workflow, on top of COMMON. */
const PER_FILE: Record<string, Rewrite[]> = {
  [BUILD_WORKFLOW]: [],
  [COPILOT_WORKFLOW]: [
    [
      '# GENERATED by .archon/scripts/copilot-workflow.js from build-feature.yaml — do not edit\n',
      '# GENERATED by kit-sync (scripts/kit-sync-standalone.ts) — do not edit\n',
      1,
    ],
    [
      'Copilot variant of build-feature, generated. Use only when the owner asks for GitHub Copilot.\n',
      'Copilot variant of build-feature.\n',
      1,
    ],
  ],
};

/** What must not survive the transform: a cut node's output, a cut script, the delegator. */
const GONE = [
  /\$(auto-merge|merged|main-ci|ticket-files|finalize|close-out)\.output/,
  /(?<![\w-])(auto-merge|merge-turn|rebase-behind|wait-merge|main-ci|close-out|ticket-files|stop-check)\.sh/,
  /delegator/i,
];

const nodeLine = (id: string): string => `  - id: ${id}\n`;

/** The start of the comment block right above the node line at `at` (or `at` when there is none). */
function blockStart(text: string, at: number): number {
  let start = at;
  for (;;) {
    const prevEnd = start - 1;
    if (prevEnd < 0) return start;
    const prevStart = text.lastIndexOf('\n', prevEnd - 1) + 1;
    if (!text.slice(prevStart, prevEnd).startsWith('  #')) return start;
    start = prevStart;
  }
}

function indexOfNode(path: string, text: string, id: string): number {
  const line = nodeLine(id);
  const n = text.split(line).length - 1;
  if (n !== 1) throw new Error(`${path}: standalone: expected node ${id} once, found ${n}`);
  return text.indexOf(line);
}

/** Cut everything from the comment block above the first tail node; the tail must hold exactly TAIL_IDS. */
export function cutTail(path: string, text: string): string {
  const first = TAIL_IDS[0] ?? '';
  const at = blockStart(text, indexOfNode(path, text, first));
  const tail = text.slice(at);
  const ids = [...tail.matchAll(/^ {2}- id: ([\w-]+)$/gm)].map(m => m[1]);
  if (ids.join(',') !== TAIL_IDS.join(','))
    throw new Error(
      `${path}: standalone: the nodes after ready are [${ids.join(', ')}], expected [${TAIL_IDS.join(', ')}]`
    );
  return `${text.slice(0, at).replace(/\n+$/, '')}\n`;
}

/** The plan approval goes right before the gated node's comment block; the gated node then waits on its approval. */
export function insertPlanApproval(path: string, text: string): string {
  const from = `${nodeLine(GATED)}    depends_on: [${BEFORE_GATE}]\n`;
  const n = text.split(from).length - 1;
  if (n !== 1)
    throw new Error(
      `${path}: standalone: expected ${GATED} to depend on [${BEFORE_GATE}] once, found ${n}`
    );
  indexOfNode(path, text, BEFORE_GATE);
  const at = blockStart(text, text.indexOf(from));
  const gated = `${nodeLine(GATED)}    depends_on: [plan-approval]\n    when: "$plan-approval.output.decision == 'approve'"\n`;
  return text.slice(0, at) + PLAN_APPROVAL + text.slice(at).replace(from, gated);
}

function rewrite(path: string, text: string, rules: Rewrite[]): string {
  let out = text;
  for (const [from, to, count] of rules) {
    const n = out.split(from).length - 1;
    if (n !== count)
      throw new Error(
        `${path}: standalone rewrite expected ${count} of ${JSON.stringify(from.slice(0, 60))}, found ${n}`
      );
    out = out.split(from).join(to);
  }
  return out;
}

/** The standalone kit workflow of a source workflow (after its TARGETED rewrites); other paths pass unchanged. */
export function standaloneWorkflow(path: string, text: string): string {
  if (!STANDALONE_WORKFLOWS.includes(path)) return text;
  const cut = cutTail(path, text);
  const out = insertPlanApproval(path, rewrite(path, cut, [...COMMON, ...(PER_FILE[path] ?? [])]));
  for (const re of GONE) {
    const line = out.split('\n').findIndex(l => re.test(l));
    if (line >= 0)
      throw new Error(
        `${path}:${line + 1}: standalone: still names what the kit cuts (${re.source})`
      );
  }
  return out;
}
