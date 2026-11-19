/**
 * kit-sync's copy lists, rewrites and leak patterns (kit/SPEC.md): which source file goes to which profile, and what
 * kit-sync changes in it. scripts/kit-sync.ts runs them.
 */
import { mergeRewrites, NOUN_REWRITES, NOUN_TARGETED } from './kit-sync-generic';

export const PROFILES = [
  'core',
  'java',
  'java-quarkus',
  'java-spring',
  'openapi-contract',
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

export const PROFILE_META: Record<Profile, { requires: Profile[]; description: string }> = {
  core: {
    requires: [],
    description:
      'Archon run tooling (delegator, STOP policy, merge, CI by SHA, retro, run observability), hooks, generic skills and agents, the codegraph MCP entry, the tool installer, the githooks and the Copilot instructions.',
  },
  java: {
    requires: ['core'],
    description:
      'Shared Java/JVM skills, the layer rules as .github/instructions, ArchUnit/PIT/Gradle CI scripts, the scaffolder and its stack-neutral templates, and the analyst, developer, test-writer and debugger agents.',
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
 * The owner's own tools (owner decision 2026-11-19: night-preflight is not part of the kit). They are in no profile,
 * and the leak check fails a shipped file that still names one of their scripts (kit/SPEC.md, What never ships).
 */
export const NEVER_SHIP: string[] = [
  '.archon/scripts/night-preflight.sh',
  '.archon/scripts/test/night-preflight.test.sh',
  'docs/archon/script/night-preflight.md',
];

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
  delegator: 'core',
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
    '.archon/notify/ntfy.env.example',
    '.archon/red-triage/*.tsv',
    '.archon/schemas/*',
    '.archon/scripts/*',
    '.archon/stop/approvals/_template.json',
    '.archon/stop/policy.json',
    '.archon/systemd/*',
    '.archon/workflows/build-feature-copilot.yaml',
    '.archon/workflows/build-feature.yaml',
    '.archon/workflows/portal-metrics.yaml',
    '.archon/workflows/sdlc/.shared/**',
    '.claude/CLAUDE.md',
    '.claude/delegator.settings.json',
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
    '.claude/scripts/groma-check.sh',
    '.claude/scripts/groma-delta.sh',
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
    '.claude/scripts/image-check.sh',
    '.claude/scripts/mutation-gate.sh',
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
};

/** A scaffold template that names one of these is Quarkus-flavoured; every other template is stack-neutral. */
export const QUARKUS_TEMPLATE = /io\.quarkus|jakarta\.ws\.rs|jakarta\.enterprise|jakarta\.inject/;

// ---------------------------------------------------------------------------------------------------------------
// Rewrites
// ---------------------------------------------------------------------------------------------------------------

/** [from, to, expected count] on one source file, before conversion. A count that does not fit fails the sync. */
export type Rewrite = [from: string, to: string, count: number];

const ACCOUNTS_LIST = 'Vikteur, ViktorVS1 and viktor-vansteenweghen_ssgia';

/** The delegator's night-list step 6 names night-preflight.sh, which never ships: drop it and renumber step 7. */
export const DELEGATOR_NIGHT_STEP: Rewrite = [
  '6. The owner runs `night-preflight.sh` (it is no delegator tool). Start nothing until the owner says it printed GO;\n' +
    '   help fix each NO-GO it names.\n' +
    '7. **Build the list',
  '6. **Build the list',
  1,
];

const BASE_TARGETED: Record<string, Rewrite[]> = {
  '.claude/agents/delegator.md': [DELEGATOR_NIGHT_STEP],
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

/** Exact rewrites per source file (the lists above plus kit-sync-generic.ts's NOUN_TARGETED). */
export const TARGETED: Record<string, Rewrite[]> = mergeRewrites(BASE_TARGETED, NOUN_TARGETED);

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

const NEVER_SHIP_SCRIPTS = NEVER_SHIP.map(p => p.split('/').pop() ?? '').filter(
  n => /\.(sh|js|mjs|ts)$/.test(n) && !/\.test\./.test(n)
);

/** A test that only asserts a fence denies the script may name it. */
const isDenyCase = (path: string, line: string): boolean =>
  path.endsWith('delegator-fence.test.sh') && /\bdeny\b/.test(line);

/** Shipped lines that name a never-ship script by path. */
export function neverShipRefs(f: { profile: string; path: string; content: string }): string[] {
  const out: string[] = [];
  const lines = f.content.split('\n');
  for (const name of NEVER_SHIP_SCRIPTS) {
    const re = new RegExp(`(?<![\\w-])${name.replace(/[.]/g, '\\.')}(?![\\w-])`);
    lines.forEach((line, i) => {
      if (re.test(line) && !isDenyCase(f.path, line))
        out.push(`${f.profile}/${f.path}:${i + 1}: names never-ship ${name}`);
    });
  }
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
