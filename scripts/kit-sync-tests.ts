/**
 * kit-sync's test-suite rules (kit/SPEC.md, Test suites): a shell suite of the source ships with the profile of the
 * script it tests, so the suites run in an install (the archon-scripts CI job, run-suites.sh). A suite that only works
 * against the source project stays out, with its reason. scripts/kit-sync.ts calls classifySuite from classify.
 */
import type { Profile } from './kit-sync-lists';

/** The suite folders; a suite is `<folder>/<name>.test.sh`, its fixtures `<folder>/fixtures/<name>/**`. */
export const SUITE_DIRS = ['.archon/scripts/test/', 'scripts/test/'];

/** Where a suite's subject is looked for by its stem, in this order (a folder means any tracked file in it). */
const STEM_SUBJECTS = [
  '.archon/scripts/{}.sh',
  '.archon/scripts/{}.js',
  '.claude/scripts/{}.sh',
  '.claude/hooks/scripts/{}.sh',
  'scripts/{}.sh',
  'scripts/{}/',
];

/** Suites whose stem names no script: the file they test. */
export const SUITE_SUBJECTS: Record<string, string> = {
  '.archon/scripts/test/audit-preload.test.sh': '.claude/hooks/scripts/audit-log.sh',
  '.archon/scripts/test/build-feature.test.sh': '.archon/workflows/build-feature.yaml',
  '.archon/scripts/test/commit-msg.test.sh': '.archon/githooks/commit-msg',
  '.archon/scripts/test/copilot-guard.test.sh': '.archon/copilot/hooks/run-guard.sh',
  '.archon/scripts/test/merge-path.test.sh': '.archon/scripts/merge-ready.sh',
  '.archon/scripts/test/ready-node.test.sh': '.archon/workflows/build-feature.yaml',
  '.archon/scripts/test/retro-fence.test.sh': '.claude/agents/retro.md',
  '.archon/scripts/test/script-calls.test.sh': '.archon/workflows/build-feature.yaml',
  '.archon/scripts/test/supervisor-fence.test.sh': '.archon/scripts/supervisor-jobs.sh',
  '.archon/scripts/test/wait-merge-ping.test.sh': '.archon/scripts/wait-merge.sh',
  '.archon/scripts/test/workflow-contracts.test.sh': '.archon/workflows/build-feature.yaml',
  'scripts/test/audit-log-args.test.sh': '.claude/hooks/scripts/audit-log.sh',
  'scripts/test/pre-push.test.sh': '.githooks/pre-push',
};

const SOURCE_BUILD = "tests the source app's own build, not a script the kit ships";

/** Suites that stay out, each with its reason. A file here never ships, whatever its subject. */
export const SUITE_EXCLUDE: Record<string, string> = {
  'scripts/test/ci-image.test.sh': `${SOURCE_BUILD}: the image job of its ci.yml and its Dockerfile`,
  'scripts/test/ci-workflow.test.sh': `${SOURCE_BUILD}: the jobs and steps of its own ci.yml`,
  'scripts/test/codegen.test.sh': `${SOURCE_BUILD}: its Gradle openApiGenerate task and generated packages`,
  'scripts/test/image.test.sh': `${SOURCE_BUILD}: it builds the source's Dockerfile and runs its app`,
  'scripts/test/wiremock-harness.test.sh': `${SOURCE_BUILD}: its version catalog and gateway module`,
  'scripts/test/portal-mcp-eval.sh':
    "an evaluation run of the contract server against the source's own contract, not a suite",
  // The source's contract checkout and build files.
  'scripts/test/contract-agent-readiness.test.sh':
    "a case reads the source's pinned contract checkout (contract/dist/openapi.yaml)",
  'scripts/test/contract-db-parity.test.sh':
    "a case reads the source's pinned contract checkout (contract/dist/openapi.yaml)",
  '.archon/scripts/test/portal-mcp-setup.test.sh':
    "it makes a worktree of the checkout and reads the source's gradle.properties contract pin",
  'scripts/test/contract-pin.test.sh':
    "it asserts the source's own gradle.properties contract pin and hub",
  'scripts/test/generated-untracked-check.test.sh':
    "it copies the source's .gitignore into its fixtures and needs its contract bundle",
  'scripts/test/ci-workflow-check.test.sh':
    "its fixtures are the source's ci.yml (its contract checkout step and job set), not the kit's",
  'scripts/test/image-check.test.sh':
    "it asserts the source's Dockerfile base images and its app's ops and throttle settings",
  'scripts/test/test-set-coverage.test.sh':
    "it reads the source's root build.gradle.kts test-set list",
  // Project files that never ship.
  'scripts/test/tokenomics.test.sh': "it checks the source's docs/tokenomics pricing and README",
  '.archon/scripts/test/scaffold-check.test.sh':
    'it validates against docs/follow-ups/follow-up.schema.json, which does not ship',
  '.archon/scripts/test/stop-policy.test.sh':
    "it asserts the source's CLAUDE.md wording and docs/archon/stop-policy.md",
  '.archon/scripts/test/mcp-setup.test.sh':
    "it asserts the source's .gitignore entries; an install has its own",
  '.archon/scripts/test/developer-fence.test.sh':
    "it asserts the source's .gitignore entries and the Claude agent file",
  'scripts/test/audit-log.test.sh':
    "it compares the hook with a reference commit of the source's history",
  // The Claude agents and their settings, which ship converted to .github/agents.
  '.archon/scripts/test/delegator-fence.test.sh':
    "it reads the Claude agent's frontmatter tools list",
  '.archon/scripts/test/delegator-settings.test.sh':
    "it reads the Claude delegator's settings file",
  '.archon/scripts/test/contract-agent-fence.test.sh':
    "it reads the Claude agent's frontmatter tools list",
  'scripts/test/scaffold.test.sh':
    "cases read the Claude test-writer's tools list and the source's table-test package",
  'scripts/test/agent-script-names.test.sh':
    "it reads the Claude agent texts, their allowlists and the source's retired script names",
};

/** A fixture folder goes with the suite that reads it. */
export const SUITE_FIXTURES: Record<string, string> = {
  '.archon/scripts/test/fixtures/classify/': '.archon/scripts/test/classify-failure.test.sh',
  '.archon/scripts/test/fixtures/copilot-audit/': '.archon/scripts/test/copilot-audit.test.sh',
  'scripts/test/fixtures/ci-workflow/': 'scripts/test/ci-workflow-check.test.sh',
  // Read by contract-agent-readiness too, which stays out; the contract server's suite ships them.
  'scripts/test/fixtures/contract-agent-readiness/': 'scripts/test/portal-mcp.test.sh',
  'scripts/test/fixtures/contract-db-parity/': 'scripts/test/contract-db-parity.test.sh',
  'scripts/test/fixtures/mutation-gate/': 'scripts/test/mutation-gate.test.sh',
  'scripts/test/fixtures/portal-mcp/': 'scripts/test/portal-mcp.test.sh',
  'scripts/test/fixtures/tokenomics/': 'scripts/test/tokenomics.test.sh',
};

export function isSuitePath(path: string): boolean {
  return SUITE_DIRS.some(d => path.startsWith(d));
}

type SuiteAssignment = { exclude: true; why: string } | { exclude?: false; profile: Profile };
type Judge = (path: string) => SuiteAssignment;

/** The file a suite tests: SUITE_SUBJECTS, else the first stem candidate the source tracks. */
export function suiteSubject(path: string, files: ReadonlySet<string>): string | undefined {
  const named = SUITE_SUBJECTS[path];
  if (named) return named;
  const stem = (path.split('/').pop() ?? '').replace(/\.test\.sh$/, '');
  for (const c of STEM_SUBJECTS.map(s => s.replace('{}', stem))) {
    if (!c.endsWith('/')) {
      if (files.has(c)) return c;
      continue;
    }
    const first = [...files].filter(f => f.startsWith(c)).sort()[0];
    if (first) return first;
  }
  return undefined;
}

/** The suite a test-folder file belongs to: a suite is its own, a listed fixture its suite's; anything else throws. */
export function suiteOf(path: string): string {
  const fixture = Object.keys(SUITE_FIXTURES).find(d => path.startsWith(d));
  if (fixture) return SUITE_FIXTURES[fixture] ?? '';
  if (/\.test\.sh$/.test(path) || SUITE_EXCLUDE[path]) return path;
  throw new Error(
    `${path}: a test-folder file that is no suite and no listed fixture; add it to SUITE_FIXTURES or SUITE_EXCLUDE in scripts/kit-sync-tests.ts`
  );
}

/**
 * A test-folder file: the profile of the script its suite tests, or excluded with the reason. A suite whose subject
 * cannot be found, or does not ship, fails the sync until it is listed.
 */
export function classifySuite(
  path: string,
  files: ReadonlySet<string>,
  judge: Judge
): SuiteAssignment {
  const suite = suiteOf(path);
  const reason = SUITE_EXCLUDE[suite];
  if (reason) return { exclude: true, why: `suite stays out: ${reason}` };
  const subject = suiteSubject(suite, files);
  if (!subject)
    throw new Error(
      `${suite}: no script found for the suite; name it in SUITE_SUBJECTS or SUITE_EXCLUDE in scripts/kit-sync-tests.ts`
    );
  const a = judge(subject);
  if (a.exclude)
    throw new Error(
      `${suite}: its subject ${subject} does not ship (${a.why}); list the suite in SUITE_EXCLUDE in scripts/kit-sync-tests.ts`
    );
  return { profile: a.profile };
}

/**
 * The source's own names in its suites and their fixtures, rewritten after the global rewrites (so `portal-api` and
 * the contract hub have their placeholders first). A suite builds its own throwaway repos, so a name only has to stay
 * the same within it, and the same as the shipped script's where it asserts one (`app-image-check`, `project-hooks`).
 */
export const SUITE_NOUNS: [RegExp, string][] = [
  [/Viktor Van Steenweghen/g, 'Example Owner'],
  [/vansteenweghenviktor@gmail\.com/g, 'owner@example.invalid'],
  [/\bViktorVS1\b/g, 'example-bot'],
  [/\bviktor-vansteenweghen_ssgia\b/g, 'example-work'],
  [/\bVikteur\b/g, 'example-org'],
  [/wedding-image-check/g, 'app-image-check'],
  [/wedding-portal:/g, 'app:'],
  [/wedding-portal-hooks/g, 'project-hooks'],
  [/\bPORTAL_DIR\b/g, 'PROJECT_DIR'],
  [/\bweddingapp\b/g, 'example-umbrella'],
  [/wedding-portal/g, 'example-app'],
  [/wedding_portal/g, 'example_app'],
  [/\bWEDDING_/g, 'APP_'],
  [/WeddingId/g, 'OrderId'],
  [/\bWedding/g, 'Order'],
  [/\bwedding/g, 'order'],
  [/\bapp\.rekord\b/g, 'com.example'],
  [/\bapp\/rekord\b/g, 'com/example'],
  [/rekord-contract/g, 'example-contract'],
  [/rekord-api/g, 'legacy-api'],
  [/rekord/gi, 'example'],
  [/\bportal-(backend|adapter|domain|usecase)\b/g, 'orders-$1'],
  [/\bPORTAL(_|\b)/g, 'PROJECT$1'],
  [/\bportal/g, 'project'],
  [/\bPortal/g, 'Project'],
];

export function applySuiteNouns(text: string): string {
  let out = text;
  for (const [re, to] of SUITE_NOUNS) out = out.replace(re, to);
  return out;
}
