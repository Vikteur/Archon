/**
 * kit-sync's copy lists, rewrites and leak patterns (kit/SPEC.md): which source file goes to which profile, and what
 * kit-sync changes in it. scripts/kit-sync.ts runs them.
 */
import { mergeRewrites, NOUN_REWRITES, NOUN_TARGETED } from './kit-sync-generic';
import { STANDALONE_TARGETED } from './kit-sync-standalone-text';
import { CONSUMER_TARGETED } from './kit-sync-consumer';

export const PROFILES = [
  'core',
  'java',
  'java-quarkus',
  'java-spring',
  'openapi-contract',
  'mijn-gezondheid',
] as const;
export type Profile = (typeof PROFILES)[number];
export type Kind =
  | 'agent'
  | 'skill'
  | 'hook'
  | 'instructions'
  | 'mcp'
  | 'workflow'
  | 'script'
  | 'template'
  | 'config'
  | 'doc';

/**
 * `project: true` marks a profile that carries one repo's own files (kit/SPEC.md, Project profiles): the only profile
 * whose files may lie in docs/scaffold-templates/project/, the repo's own folder. A generic profile never may.
 */
export const PROFILE_META: Record<
  Profile,
  { requires: Profile[]; description: string; project?: boolean }
> = {
  core: {
    requires: [],
    description:
      'Archon run tooling (one build run per ticket with a plan approval, CI by SHA, retro, run observability), hooks, generic skills and agents, the codegraph MCP entry, the tool installer, the githooks and the Copilot instructions.',
  },
  java: {
    requires: ['core'],
    description:
      'Shared Java/JVM skills, the layer rules as .github/instructions, ArchUnit/Gradle CI scripts, the scaffolder and its stack-neutral templates, and the analyst, developer, test-writer and debugger agents.',
  },
  'java-quarkus': {
    requires: ['java'],
    description:
      'The Quarkus originals: bean-config-di, persistence-repository, resilience4j, exception-to-http, api-first-controller, testcontainers, the Quarkus scaffold templates, the CI workflow and run-app.',
  },
  'java-spring': {
    requires: ['java'],
    description:
      'The java-quarkus paths rewritten for Spring Boot, from the hand-written kit/overlays/java-spring.',
  },
  'openapi-contract': {
    requires: ['core'],
    description:
      'The contract-api MCP server, contract-agent-readiness, contract-pin, contract-db-parity and the contract-agent.',
  },
  'mijn-gezondheid': {
    requires: ['java-spring', 'openapi-contract'],
    project: true,
    description:
      "The mijn-gezondheid portal's own scaffold templates and its scaffold.json (docs/scaffold-templates/project/), from the hand-written kit/overlays/mijn-gezondheid: java's new-context.sh, smoke.sh and the wiring check run on them as installed.",
  },
};

export const EXCLUSIVE: Profile[][] = [['java-quarkus', 'java-spring']];

export const POST_INSTALL: { profile: Profile; run: string; optional: boolean }[] = [
  { profile: 'core', run: 'bash scripts/install-hooks.sh', optional: true },
  { profile: 'core', run: 'bash .archon/scripts/codegraph-setup.sh', optional: true },
  { profile: 'openapi-contract', run: 'npm ci --prefix scripts/contract-mcp', optional: false },
  {
    profile: 'openapi-contract',
    run: 'bash .archon/scripts/contract-mcp-setup.sh',
    optional: true,
  },
  { profile: 'core', run: 'bash .archon/scripts/mcp-setup.sh', optional: true },
];

/** The source folders kit-sync scans. A tracked file under one of them is assigned or excluded, never ignored. */
export const SCANNED_ROOTS = [
  '.agents/',
  '.archon/',
  '.claude/',
  '.githooks/',
  '.github/',
  'docs/code-maps/',
  'docs/scaffold-templates/',
  'scripts/',
];

// ---------------------------------------------------------------------------------------------------------------
// Copy lists
// ---------------------------------------------------------------------------------------------------------------

/**
 * Never shipped, in no profile: the source's unattended machinery (owner decision 2026-11-19, kit/SPEC.md, What never
 * ships). A person starts a run, approves its plan and merges its pull request, so the delegator, the night runs, the
 * merge queue and the STOP ledger have no job in the kit. The leak check fails a shipped file that still names one of
 * their scripts.
 */
export const NEVER_SHIP_GROUPS: Record<string, string[]> = {
  'The delegator: ticket picking, parallel runs, the night list and its watchers.': [
    '.archon/scripts/delegator-session.sh',
    '.archon/scripts/delegator-start.sh',
    '.archon/scripts/pick-tickets.js',
    '.archon/scripts/launch-run.sh',
    '.archon/scripts/park-ticket.sh',
    '.archon/scripts/commit-tickets.sh',
    '.archon/scripts/run-watch.js',
    '.archon/scripts/verify-fixes.js',
    '.archon/scripts/test/delegator-fence.test.sh',
    '.archon/scripts/test/delegator-session.test.sh',
    '.archon/scripts/test/delegator-settings.test.sh',
    '.archon/scripts/test/delegator-start.test.sh',
    '.archon/scripts/test/pick-tickets.test.sh',
    '.archon/scripts/test/launch-run.test.sh',
    '.archon/scripts/test/park-ticket.test.sh',
    '.archon/scripts/test/commit-tickets.test.sh',
    '.archon/scripts/test/run-watch.test.sh',
    '.archon/scripts/test/verify-fixes.test.sh',
    '.claude/agents/delegator.md',
    '.claude/delegator.settings.json',
    '.archon/schemas/delegator-decision.json',
  ],
  "Night runs: the supervisor, its timers, the owner's pings and the nightly digest, run recovery.":
    [
      '.archon/scripts/night-preflight.sh',
      '.archon/scripts/supervisor-ctl.sh',
      '.archon/scripts/supervisor-jobs.sh',
      '.archon/scripts/supervisor-judge.sh',
      '.archon/scripts/supervisor-tick.sh',
      '.archon/scripts/notify-owner.sh',
      '.archon/scripts/retro-digest.sh',
      '.archon/scripts/recover-run.sh',
      '.archon/scripts/rebase-and-resume.sh',
      '.archon/scripts/recovery-state.js',
      '.archon/scripts/classify-failure.js',
      '.archon/scripts/classify-failure.signatures.json',
      '.archon/scripts/test/night-preflight.test.sh',
      '.archon/scripts/test/supervisor-ctl.test.sh',
      '.archon/scripts/test/supervisor-fence.test.sh',
      '.archon/scripts/test/supervisor-judge.test.sh',
      '.archon/scripts/test/supervisor-tick.test.sh',
      '.archon/scripts/test/notify-owner.test.sh',
      '.archon/scripts/test/retro-digest.test.sh',
      '.archon/scripts/test/recover-run.test.sh',
      '.archon/scripts/test/rebase-and-resume.test.sh',
      '.archon/scripts/test/recovery-state.test.sh',
      '.archon/scripts/test/classify-failure.test.sh',
      '.archon/systemd/delegator-supervisor.service',
      '.archon/systemd/delegator-supervisor.timer',
      '.archon/systemd/notify-digest.service',
      '.archon/systemd/notify-digest.timer',
      '.archon/notify/ntfy.env.example',
      'docs/archon/script/night-preflight.md',
    ],
  'The merge queue and the post-merge close-out: a team member merges.': [
    '.archon/scripts/auto-merge.sh',
    '.archon/scripts/merge-turn.sh',
    '.archon/scripts/rebase-behind.sh',
    '.archon/scripts/wait-merge.sh',
    '.archon/scripts/ready-runs.sh',
    '.archon/scripts/merge-ready.sh',
    '.archon/scripts/merge-ledger.sh',
    '.archon/scripts/sync-main.sh',
    '.archon/scripts/main-ci.sh',
    '.archon/scripts/ticket-files.sh',
    '.archon/scripts/close-out.sh',
    '.archon/scripts/test/auto-merge.test.sh',
    '.archon/scripts/test/merge-turn.test.sh',
    '.archon/scripts/test/rebase-behind.test.sh',
    '.archon/scripts/test/wait-merge.test.sh',
    '.archon/scripts/test/wait-merge-ping.test.sh',
    '.archon/scripts/test/ready-runs.test.sh',
    '.archon/scripts/test/merge-ready.test.sh',
    '.archon/scripts/test/merge-ledger.test.sh',
    '.archon/scripts/test/merge-path.test.sh',
    '.archon/scripts/test/sync-main.test.sh',
    '.archon/scripts/test/main-ci.test.sh',
    '.archon/scripts/test/ticket-files.test.sh',
    '.archon/scripts/test/close-out.test.sh',
  ],
  'The STOP approval ledger: the plan approval replaces it.': [
    '.archon/scripts/stop-approve.sh',
    '.archon/scripts/stop-round.sh',
    '.archon/scripts/stop-check.sh',
    '.archon/scripts/stop-lib.js',
    '.archon/scripts/stop-scan.js',
    '.archon/scripts/test/stop-approve.test.sh',
    '.archon/scripts/test/stop-round.test.sh',
    '.archon/scripts/test/stop-check.test.sh',
    '.archon/scripts/test/stop-scan.test.sh',
    '.archon/stop/policy.json',
    '.archon/stop/approvals/_template.json',
  ],
  'The Copilot workflow generator: the kit ships its output, transformed (scripts/kit-sync-standalone.ts).':
    ['.archon/scripts/copilot-workflow.js', '.archon/scripts/test/copilot-workflow.test.sh'],
  'The Groma architecture map, its checks and the pre-push hook that ran them (owner decision 2026-11-20).':
    [
      '.claude/scripts/groma-check.sh',
      '.claude/scripts/groma-delta.sh',
      '.archon/scripts/groma-links.sh',
      '.archon/scripts/groma-sync.sh',
      '.archon/scripts/test/groma-links.test.sh',
      '.archon/scripts/test/groma-sync.test.sh',
      'scripts/test/groma-delta.test.sh',
      '.githooks/pre-push',
      'scripts/test/pre-push.test.sh',
    ],
  'The mutation gate (PIT on the changed domain, usecase and gateway classes), never wired into a build.':
    ['.claude/scripts/mutation-gate.sh', 'scripts/test/mutation-gate.test.sh'],
  "The image CI job's check of a built image (a multi-stage Dockerfile contract not every project follows).":
    ['.claude/scripts/image-check.sh', 'scripts/test/image-check.test.sh'],
};

export const NEVER_SHIP: string[] = Object.values(NEVER_SHIP_GROUPS).flat();

/** Never shipped (or only shipped converted). Checked after NEVER_SHIP. */
export const EXCLUDE: string[] = [
  '.claude/settings.json', // converted: hooks -> .github/hooks/kit.json, permissions.deny -> .archon/copilot/deny.json
  '.claude/skills/archon-cli/**', // the same skill ships from .agents/skills/archon-cli
  '.archon/stop/approvals/2*.json', // the owner's dated approvals
  '.archon/pin-proofs.txt', // the source's own pin proofs (kit key pin_proofs)
];

export const AGENT_PROFILES: Record<string, Profile> = {
  analyst: 'java',
  'contract-agent': 'openapi-contract',
  debugger: 'java',
  'design-critic': 'core',
  developer: 'java',
  'github-agent': 'core',
  retro: 'core',
  reviewer: 'core',
  'test-writer': 'java',
};

export const SKILL_PROFILES: Record<string, Profile> = {
  'clean-architecture': 'core',
  'clean-code': 'core',
  'code-generation': 'core',
  'code-review-process': 'core',
  'conventional-commits': 'core',
  'design-review': 'core',
  'gh-git-ops': 'core',
  'gh-switch-account': 'core',
  'grill-plan': 'core',
  'grill-pr': 'core',
  'release-changelog': 'core',
  retro: 'core',
  'tdd-loop': 'core',
  'archunit-fitness': 'java',
  'domain-dto-mapper': 'java',
  'domain-events': 'java',
  'domain-modeling': 'java',
  'domain-to-dto-mapper-tests': 'java',
  'flyway-migrations': 'java',
  java: 'java',
  'jpa-entity-mapping': 'java',
  'jvm-testing': 'java',
  'object-mother-builders': 'java',
  'openapi-rest-client-codegen': 'java',
  'usecase-bdd-spec': 'java',
  'usecase-orchestration': 'java',
  'validation-notification-result': 'java',
  'api-first-controller': 'java-quarkus',
  'bean-config-di': 'java-quarkus',
  'exception-to-http': 'java-quarkus',
  'persistence-repository': 'java-quarkus',
  resilience4j: 'java-quarkus',
  testcontainers: 'java-quarkus',
  'run-wedding-portal': 'java-quarkus',
  'contract-agent-readiness': 'openapi-contract',
  'contract-db-parity': 'openapi-contract',
  'contract-slice': 'openapi-contract',
};

/** Source skill folders that ship under another name. */
export const SKILL_RENAMES: Record<string, string> = { 'run-wedding-portal': 'run-app' };

export const RULE_PROFILES: Record<string, Profile> = {
  general: 'core',
  adapter: 'java',
  domain: 'java',
  gateway: 'java',
  platform: 'java',
  usecase: 'java',
};

/** Code-map leaves that are not named after a skill. */
export const LEAF_PROFILES: Record<string, Profile> = { 'junit-tests': 'java' };

/** Verbatim copies. An exact path beats a glob; two globs that both match one file are an error. */
export const FILES: Record<Profile, string[]> = {
  core: [
    '.agents/skills/archon-cli/**',
    '.archon/config.yaml',
    '.archon/copilot/**',
    '.archon/githooks/*',
    '.archon/red-triage/*.tsv',
    '.archon/schemas/*',
    '.archon/scripts/*',
    '.archon/workflows/build-feature-copilot.yaml',
    '.archon/workflows/build-feature.yaml',
    '.archon/workflows/portal-metrics.yaml',
    '.archon/workflows/sdlc/.shared/**',
    '.claude/CLAUDE.md',
    '.claude/hooks/**',
    '.claude/scripts/archon-suites.sh',
    '.claude/scripts/ci-audit.sh',
    '.claude/scripts/ci-cost.sh',
    '.claude/scripts/ci-ledger.sh',
    '.claude/scripts/ci-local.sh',
    '.claude/scripts/ci-plan.sh',
    '.claude/scripts/ci-queue.sh',
    '.claude/scripts/ci-status-grammar.sh',
    '.claude/scripts/gate-change-check.sh',
    '.claude/scripts/run-suites.sh',
    '.githooks/*',
    '.github/copilot-instructions.md',
    '.github/hooks/archon-run-guard.json',
    'docs/code-maps/README.md',
    'scripts/install-hooks.sh',
    'scripts/install-tools.sh',
    'scripts/tokenomics/**',
    'scripts/tools.conf',
    'scripts/web-uis.sh',
  ],
  java: [
    '.claude/scripts/affected-check.sh',
    '.claude/scripts/build-shape-check.sh',
    '.claude/scripts/ci-workflow-check.sh',
    '.claude/scripts/class-version-check.sh',
    '.claude/scripts/pin-proof-check.sh',
    '.claude/scripts/test-set-coverage.java',
    '.claude/scripts/test-set-coverage.sh',
    'scripts/scaffold.sh',
    'scripts/scaffold/**',
  ],
  'java-quarkus': ['.github/ci-inputs.yml', '.github/workflows/ci.yml'],
  'java-spring': [],
  'openapi-contract': [
    '.archon/scripts/portal-mcp-setup.sh',
    '.claude/scripts/contract-pin.sh',
    '.claude/scripts/contract-read-only-check.sh',
    '.claude/scripts/generated-untracked-check.sh',
    'scripts/contract-agent-readiness.sh',
    'scripts/contract-agent-readiness/**',
    'scripts/contract-db-parity.sh',
    'scripts/contract-db-parity/**',
    'scripts/portal-mcp/**',
  ],
  'mijn-gezondheid': [],
};

/** A scaffold template that names one of these is Quarkus-flavoured; every other template is stack-neutral. */
export const QUARKUS_TEMPLATE = /io\.quarkus|jakarta\.ws\.rs|jakarta\.enterprise|jakarta\.inject/;

// ---------------------------------------------------------------------------------------------------------------
// Rewrites
// ---------------------------------------------------------------------------------------------------------------

/** [from, to, expected count] on one source file, before conversion. A count that does not fit fails the sync. */
export type Rewrite = [from: string, to: string, count: number];

const ACCOUNTS_LIST = 'Vikteur, ViktorVS1 and viktor-vansteenweghen_ssgia';

const BASE_TARGETED: Record<string, Rewrite[]> = {
  '.archon/copilot/README.md': [['in the Vikteur/Archon fork', 'in the Archon fork', 1]],
  '.archon/config.yaml': [['  baseBranch: main\n', '  baseBranch: @@KIT_BASE_BRANCH@@\n', 1]],
  '.archon/workflows/build-feature.yaml': [
    ['git rev-parse origin/main)', 'git rev-parse origin/@@KIT_BASE_BRANCH@@)', 1],
    ['"Bash(*git push*main*)"', '"Bash(*git push*@@KIT_BASE_BRANCH@@*)"', 3],
    ['"Bash(*git push*HEAD:main*)"', '"Bash(*git push*HEAD:@@KIT_BASE_BRANCH@@*)"', 3],
  ],
  '.archon/workflows/build-feature-copilot.yaml': [
    ['git rev-parse origin/main)', 'git rev-parse origin/@@KIT_BASE_BRANCH@@)', 1],
    ['"Bash(*git push*main*)"', '"Bash(*git push*@@KIT_BASE_BRANCH@@*)"', 3],
    ['"Bash(*git push*HEAD:main*)"', '"Bash(*git push*HEAD:@@KIT_BASE_BRANCH@@*)"', 3],
  ],
  '.claude/skills/gh-switch-account/scripts/gh-switch.sh': [
    [
      `# Switch the active gh account between ${ACCOUNTS_LIST}.\n`,
      '# Switch the active gh account between the accounts of gh_accounts in .archon/kit.yaml (read with yq).\n',
      1,
    ],
    [
      'ACCOUNTS=("Vikteur" "ViktorVS1" "viktor-vansteenweghen_ssgia")\n',
      [
        'ACCOUNTS=()',
        'kit_yaml="${KIT_CONFIG:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.archon/kit.yaml}"',
        'if [[ -f "$kit_yaml" ]] && command -v yq >/dev/null 2>&1; then',
        '  while IFS= read -r a; do',
        '    [[ -n "$a" && "$a" != null ]] && ACCOUNTS+=("$a")',
        '  done < <(yq -r \'.gh_accounts // [] | .[]\' "$kit_yaml" 2>/dev/null)',
        'fi',
        'if [[ ${#ACCOUNTS[@]} -eq 0 ]]; then',
        '  echo "error: no gh accounts: list them under gh_accounts in $kit_yaml (needs yq)" >&2',
        '  exit 2',
        'fi',
        '',
      ].join('\n'),
      1,
    ],
  ],
  '.claude/skills/gh-switch-account/scripts/gh-switch.ps1': [
    [
      `# Switch the active gh account between ${ACCOUNTS_LIST}.\n`,
      '# Switch the active gh account between @@KIT_GH_ACCOUNTS@@ (gh_accounts in .archon/kit.yaml).\n',
      1,
    ],
    [
      "$Accounts = @('Vikteur', 'ViktorVS1', 'viktor-vansteenweghen_ssgia')\n",
      "$Accounts = @('@@KIT_GH_ACCOUNTS@@' -split ',\\s*' | Where-Object { $_ })\n",
      1,
    ],
  ],
  '.claude/skills/gh-switch-account/SKILL.md': [
    [`between ${ACCOUNTS_LIST}\n  (work).`, 'between the accounts\n  @@KIT_GH_ACCOUNTS@@.', 1],
    [
      '"use Vikteur", "use ViktorVS1", "use my work account"',
      '"use <account>", "use my work account"',
      1,
    ],
    [
      'between three accounts (all must',
      'between the accounts of `gh_accounts` in `.archon/kit.yaml` (all must',
      1,
    ],
    [
      '| `Vikteur` | personal |\n| `ViktorVS1` | personal |\n| `viktor-vansteenweghen_ssgia` | work |\n',
      '| @@KIT_GH_ACCOUNTS@@ | this project |\n',
      1,
    ],
    [
      'gh-switch.sh Vikteur                      # explicit\nbash .claude/skills/gh-switch-account/scripts/gh-switch.sh ViktorVS1\nbash .claude/skills/gh-switch-account/scripts/gh-switch.sh viktor-vansteenweghen_ssgia\n',
      'gh-switch.sh <account>                    # explicit\n',
      1,
    ],
    ['gh-switch.ps1" Vikteur\n', 'gh-switch.ps1" <account>\n', 1],
    [
      'cycling (Vikteur -> ViktorVS1 -> viktor-vansteenweghen_ssgia -> Vikteur)',
      'cycling (through @@KIT_GH_ACCOUNTS@@ in that order)',
      1,
    ],
  ],
  '.claude/skills/gh-git-ops/SKILL.md': [
    [
      'run as Vikteur, ViktorVS1 or viktor-vansteenweghen_ssgia.',
      'run as one of @@KIT_GH_ACCOUNTS@@.',
      1,
    ],
    ['`Vikteur`, `ViktorVS1` or `viktor-vansteenweghen_ssgia`;', 'one of @@KIT_GH_ACCOUNTS@@;', 1],
    ['(`Vikteur`, `ViktorVS1`, `viktor-vansteenweghen_ssgia`)', '(one of @@KIT_GH_ACCOUNTS@@)', 1],
  ],
};

/** Exact rewrites per source file (the lists above, kit-sync-generic.ts's NOUN_TARGETED, kit-sync-standalone-text.ts's and kit-sync-consumer.ts's). */
export const TARGETED: Record<string, Rewrite[]> = mergeRewrites(
  mergeRewrites(mergeRewrites(BASE_TARGETED, NOUN_TARGETED), STANDALONE_TARGETED),
  CONSUMER_TARGETED
);

/**
 * Applied to every shipped text file after conversion, except the verbatim `.agents/skills/archon-cli/**`; then
 * kit-sync-generic.ts's PATH_REWRITES, except in its PATH_SKIP files.
 */
export const GLOBAL_REWRITES: [RegExp, string][] = [
  [/\/home\/viktor\/wedding-portal(?![\w-])/g, '@@KIT_PROJECT_DIR@@'],
  [/\.claude([/\\])skills\1run-wedding-portal/g, '.github$1skills$1run-app'],
  [/(?<![\w-])run-wedding-portal(?![\w-])/g, 'run-app'],
  [/Vikteur\/rekord-contract/g, '@@KIT_CONTRACT_REPO@@'],
  ...NOUN_REWRITES,
];

/** The source's main checkout: `archon kit add` renders @@KIT_PROJECT_DIR@@ as the project's absolute path. */
export const PROJECT_DIR = /\/home\/viktor\/wedding-portal(?![\w-])/g;
export const CONTRACT_SERVER = '@@KIT_CONTRACT_SERVER_NAME@@';
export const SOURCE_CONTRACT_SERVER = /(?<![\w-])portal-api(?![\w-])/g;

// ---------------------------------------------------------------------------------------------------------------
// Leak check
// ---------------------------------------------------------------------------------------------------------------

const LEAK_FAIL: [string, RegExp][] = [
  ['home path', /\/home\/viktor\b/],
  ['owner account', /\b(Vikteur|ViktorVS1|viktor-vansteenweghen)/],
  ['owner name', /\bViktor\s+Van\s+Steenweghen\b/i],
  ['GitHub token', /\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}/],
  ['AWS key', /\bAKIA[0-9A-Z]{16}\b/],
  ['private key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['Slack token', /\bxox[abprs]-[A-Za-z0-9-]{10,}/],
  ['API key', /\bsk-(ant-)?[A-Za-z0-9_-]{32,}/],
];
const LEAK_WARN = /wedding|rekord|portal/gi;
const LEAK_WARN_FREE: Profile[] = ['java-quarkus', 'openapi-contract'];

export interface LeakReport {
  failures: string[];
  warnings: string[];
}

/**
 * The names a shipped line must not use: each never-ship script, each never-ship agent (by its file and its Copilot
 * file), and each never-ship systemd unit by its stem (it also names the unit's /etc folder). A test file's own name is
 * left out: a suite is named by its script.
 */
const NEVER_SHIP_NAMES = NEVER_SHIP.flatMap(p => {
  const n = p.split('/').pop() ?? '';
  if (/\.test\./.test(n)) return [];
  if (/\.(sh|js|mjs|ts)$/.test(n)) return [n];
  if (p.startsWith('.claude/agents/')) return [n, n.replace(/\.md$/, '.agent.md')];
  if (/\.(service|timer)$/.test(n)) return [n.replace(/\.(service|timer)$/, '')];
  return [];
}).filter((n, i, all) => all.indexOf(n) === i);

const NEVER_SHIP_RES = NEVER_SHIP_NAMES.map(
  name => [name, new RegExp(`(?<![\\w-])${name.replace(/[.]/g, '\\.')}(?![\\w-])`)] as const
);

/** The never-ship names a text uses (a hook command, a deny rule, a shipped line). */
export function neverShipNamesIn(text: string): string[] {
  return NEVER_SHIP_RES.filter(([, re]) => re.test(text)).map(([name]) => name);
}

/** Shipped lines that name a never-ship script by path. */
export function neverShipRefs(f: { profile: string; path: string; content: string }): string[] {
  const out: string[] = [];
  const lines = f.content.split('\n');
  lines.forEach((line, i) => {
    for (const name of neverShipNamesIn(line))
      out.push(`${f.profile}/${f.path}:${i + 1}: names never-ship ${name}`);
  });
  return out;
}

export function leakCheck(files: { profile: string; path: string; content: string }[]): LeakReport {
  const failures: string[] = [];
  const warnings: string[] = [];
  for (const f of files) {
    failures.push(...neverShipRefs(f));
    for (const [label, re] of LEAK_FAIL) {
      const m = re.exec(f.content);
      if (m) failures.push(`${f.profile}/${f.path}: ${label} (${m[0].slice(0, 12)}...)`);
    }
    if (!LEAK_WARN_FREE.includes(f.profile as Profile)) {
      const n = (f.content.match(LEAK_WARN) ?? []).length;
      if (n > 0) warnings.push(`${f.profile}/${f.path} (${n})`);
    }
  }
  return { failures, warnings };
}
