#!/usr/bin/env bun
/**
 * kit-sync: generate the Copilot kit (`kit/profiles/**` and `kit/manifest.json`) from a Claude Code source repo.
 * The contract is `kit/SPEC.md`; this file holds its copy lists, conversions and rewrites.
 *
 *   bun run scripts/kit-sync.ts <source-repo> [--out kit]          regenerate kit/profiles and kit/manifest.json
 *   bun run scripts/kit-sync.ts <source-repo> --check [--out kit]  regenerate into a temp dir, exit 1 on drift
 *   bun run scripts/kit-sync.ts --verify [--out kit]               no source needed: manifest <-> files, overlays, leaks
 *
 * The source is read from its HEAD commit (git-tracked files only), never from its work tree, so the output is the
 * same on every machine for one source commit. Every tracked file under the scanned roots must be assigned to a
 * profile or excluded below: a new source file fails the sync until a list names it.
 */
import { createHash } from 'node:crypto';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';

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

const PROFILE_META: Record<Profile, { requires: Profile[]; description: string }> = {
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

const EXCLUSIVE: Profile[][] = [['java-quarkus', 'java-spring']];

const POST_INSTALL: { profile: Profile; run: string; optional: boolean }[] = [
  { profile: 'core', run: 'bash scripts/install-hooks.sh', optional: true },
  { profile: 'core', run: 'bash .archon/scripts/codegraph-setup.sh', optional: true },
  { profile: 'openapi-contract', run: 'npm ci --prefix scripts/portal-mcp', optional: false },
  { profile: 'openapi-contract', run: 'bash .archon/scripts/portal-mcp-setup.sh', optional: true },
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

/** Never shipped (or only shipped converted). Checked first. */
const EXCLUDE: string[] = [
  '.claude/settings.json', // converted: hooks -> .github/hooks/kit.json, permissions.deny -> .archon/copilot/deny.json
  '.claude/skills/archon-cli/**', // the same skill ships from .agents/skills/archon-cli
  '.archon/stop/approvals/2*.json', // the owner's dated approvals
  '.archon/scripts/test/**', // the source's own tests
  'scripts/test/**',
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
const LEAF_PROFILES: Record<string, Profile> = { 'junit-tests': 'java' };

/** Verbatim copies. An exact path beats a glob; two globs that both match one file are an error. */
const FILES: Record<Profile, string[]> = {
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
    '.claude/scripts/class-version-check.sh',
    '.claude/scripts/mutation-gate.sh',
    '.claude/scripts/test-set-coverage.java',
    '.claude/scripts/test-set-coverage.sh',
    'scripts/scaffold.sh',
    'scripts/scaffold/**',
  ],
  'java-quarkus': [
    '.claude/scripts/build-shape-check.sh',
    '.claude/scripts/ci-workflow-check.sh',
    '.claude/scripts/image-check.sh',
    '.claude/scripts/pin-proof-check.sh',
    '.github/ci-inputs.yml',
    '.github/workflows/ci.yml',
  ],
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
const QUARKUS_TEMPLATE = /io\.quarkus|jakarta\.ws\.rs|jakarta\.enterprise|jakarta\.inject/;

// ---------------------------------------------------------------------------------------------------------------
// Rewrites
// ---------------------------------------------------------------------------------------------------------------

/** [from, to, expected count] on one source file, before conversion. A count that does not fit fails the sync. */
export type Rewrite = [from: string, to: string, count: number];

const ACCOUNTS_LIST = 'Vikteur, ViktorVS1 and viktor-vansteenweghen_ssgia';

export const TARGETED: Record<string, Rewrite[]> = {
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

/** Applied to every shipped text file after conversion, except the verbatim `.agents/skills/archon-cli/**`. */
export const GLOBAL_REWRITES: [RegExp, string][] = [
  [/\/home\/viktor\/wedding-portal(?![\w-])/g, '@@KIT_PROJECT_DIR@@'],
  [/\.claude([/\\])skills\1run-wedding-portal/g, '.github$1skills$1run-app'],
  [/(?<![\w-])run-wedding-portal(?![\w-])/g, 'run-app'],
  [/\.claude([/\\])skills(?![\w-])/g, '.github$1skills'],
  [/Vikteur\/rekord-contract/g, '@@KIT_CONTRACT_REPO@@'],
];

/** The source's main checkout: `archon kit add` renders @@KIT_PROJECT_DIR@@ as the project's absolute path. */
const PROJECT_DIR = /\/home\/viktor\/wedding-portal(?![\w-])/g;
const CONTRACT_SERVER = '@@KIT_CONTRACT_SERVER_NAME@@';
const SOURCE_CONTRACT_SERVER = /(?<![\w-])portal-api(?![\w-])/g;

// ---------------------------------------------------------------------------------------------------------------
// Leak check
// ---------------------------------------------------------------------------------------------------------------

const LEAK_FAIL: [string, RegExp][] = [
  ['home path', /\/home\/viktor\b/],
  ['owner account', /\b(Vikteur|ViktorVS1|viktor-vansteenweghen)/],
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

export function leakCheck(files: { profile: string; path: string; content: string }[]): LeakReport {
  const failures: string[] = [];
  const warnings: string[] = [];
  for (const f of files) {
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

// ---------------------------------------------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------------------------------------------

const MODEL_MAP: [RegExp, string][] = [
  [/opus/i, 'claude-opus-5.5'],
  [/sonnet/i, 'claude-sonnet-5.5'],
  [/haiku/i, 'claude-haiku-5.5'],
];
const CLAUDE_ONLY_TOOLS = ['PushNotification', 'SendMessage', 'ListAgents'];

const y = (v: unknown): string => JSON.stringify(v);
const yList = (items: readonly string[]): string => `[${items.map(i => y(i)).join(', ')}]`;

export function splitFrontmatter(text: string): { front: string; body: string } | null {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) return null;
  return { front: m[1] ?? '', body: text.slice(m[0].length) };
}

function parseYaml(text: string, where: string): Record<string, unknown> {
  const v: unknown = Bun.YAML.parse(text);
  if (v === null || v === undefined) return {};
  if (typeof v !== 'object' || Array.isArray(v))
    throw new Error(`${where}: frontmatter is not a map`);
  return v as Record<string, unknown>;
}

function contractName(name: string): string {
  return name.replace(SOURCE_CONTRACT_SERVER, CONTRACT_SERVER);
}

function onCopilotSection(notes: string[]): string {
  return notes.length ? `\n## On Copilot CLI\n\n${notes.map(n => `- ${n}`).join('\n')}\n` : '';
}

function withTrailingSection(body: string, section: string): string {
  if (!section) return body;
  return `${body.replace(/\s*$/, '')}\n${section}`;
}

interface McpServer {
  command: string;
  args?: string[];
  env?: Record<string, string>;
}

function mcpEntry(server: McpServer): string[] {
  const lines = ['    type: "local"', `    command: ${y(server.command)}`];
  lines.push(`    args: ${yList(server.args ?? [])}`);
  lines.push('    tools: ["*"]');
  const env = Object.entries(server.env ?? {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  if (env.length) {
    lines.push('    env:');
    for (const [k, v] of env) lines.push(`      ${k}: ${y(String(v))}`);
  }
  return lines;
}

/** `.claude/agents/<n>.md` -> `.github/agents/<n>.agent.md` (kit/SPEC.md, Conversion rules). */
export function convertAgent(text: string, where = 'agent'): string {
  const parts = splitFrontmatter(text);
  if (!parts) throw new Error(`${where}: no frontmatter`);
  const fm = parseYaml(parts.front, where);
  const name = String(fm.name ?? '');
  if (!name) throw new Error(`${where}: no name`);
  const modelIn = String(fm.model ?? '');
  const model = MODEL_MAP.find(([re]) => re.test(modelIn))?.[1];
  if (modelIn && !model) throw new Error(`${where}: unknown model ${modelIn}`);

  const tools: string[] = [];
  const add = (...t: string[]): void => {
    for (const x of t) if (!tools.includes(x)) tools.push(x);
  };
  const bash: string[] = [];
  const delegates: string[] = [];
  const dropped: string[] = [];
  const toolList = Array.isArray(fm.tools)
    ? (fm.tools as unknown[]).map(String)
    : typeof fm.tools === 'string'
      ? fm.tools.split(/,\s*(?![^()]*\))/)
      : [];
  for (const raw of toolList) {
    const t = raw.trim();
    let m: RegExpExecArray | null;
    if (t === 'Read' || t === 'Grep' || t === 'Glob') add('read', 'search');
    else if (t === 'Edit' || t === 'Write' || t === 'MultiEdit' || t === 'NotebookEdit')
      add('edit');
    else if ((m = /^Bash(?:\((.*)\))?$/.exec(t))) {
      add('execute');
      if (m[1]) bash.push(m[1]);
    } else if (t === 'WebFetch' || t === 'WebSearch') add('web');
    else if ((m = /^(?:Agent|Task)(?:\((.*)\))?$/.exec(t))) {
      add('agent');
      if (m[1]) delegates.push(...m[1].split(/,\s*/));
    } else if ((m = /^mcp__(.+?)__(.+)$/.exec(t))) add(`${contractName(m[1] ?? '')}/${m[2]}`);
    else if (t === 'Skill') continue;
    else if (CLAUDE_ONLY_TOOLS.includes(t)) dropped.push(t);
    else throw new Error(`${where}: no Copilot mapping for tool ${t}`);
  }

  const servers: [string, McpServer][] = [];
  const rawServers = fm.mcpServers;
  const pushServer = (k: string, v: unknown): void => {
    if (!v || typeof v !== 'object') throw new Error(`${where}: mcpServers.${k} is not a map`);
    const s = v as Record<string, unknown>;
    servers.push([
      contractName(k),
      {
        command: String(s.command ?? ''),
        args: Array.isArray(s.args) ? s.args.map(String) : [],
        env:
          s.env && typeof s.env === 'object'
            ? Object.fromEntries(Object.entries(s.env).map(([a, b]) => [a, String(b)]))
            : undefined,
      },
    ]);
  };
  if (Array.isArray(rawServers)) {
    for (const item of rawServers)
      for (const [k, v] of Object.entries(item as Record<string, unknown>)) pushServer(k, v);
  } else if (rawServers && typeof rawServers === 'object') {
    for (const [k, v] of Object.entries(rawServers)) pushServer(k, v);
  }

  const out = ['---', `name: ${y(name)}`, `description: ${y(String(fm.description ?? ''))}`];
  if (model) out.push(`model: ${y(model)}`);
  out.push(`tools: ${yList(tools)}`);
  if (servers.length) {
    out.push('mcp-servers:');
    for (const [k, s] of servers) out.push(`  ${y(k)}:`, ...mcpEntry(s));
  }
  out.push('include-custom-instructions: true', '---', '');

  let body = parts.body.replace(SOURCE_CONTRACT_SERVER, CONTRACT_SERVER);
  const skills = Array.isArray(fm.skills) ? (fm.skills as unknown[]).map(String) : [];
  if (skills.length)
    body = `Load these skills first: ${skills.join(', ')}.\n\n${body.replace(/^\s+/, '')}`;
  const notes: string[] = [];
  if (dropped.length)
    notes.push(
      `Claude Code gives this agent tools that Copilot CLI does not have: ${dropped.map(t => `\`${t}\``).join(', ')}. Where these instructions use one, go without it and say so in your report.`
    );
  if (bash.length)
    notes.push(
      `Claude Code limits this agent's shell to these commands; keep to them: ${bash.map(b => `\`${b}\``).join(', ')}.`
    );
  if (delegates.length)
    notes.push(`Delegate only to these agents: ${delegates.map(d => `\`${d}\``).join(', ')}.`);
  return out.join('\n') + withTrailingSection(body, onCopilotSection(notes));
}

const SKILL_KEEP = ['name', 'description', 'license', 'allowed-tools'];

/** SKILL.md: keep name, description, license and allowed-tools (as written); note a dropped invocation rule. */
export function convertSkillMd(text: string, where = 'SKILL.md'): string {
  const parts = splitFrontmatter(text);
  if (!parts) return text;
  const fm = parseYaml(parts.front, where);
  const kept: string[] = [];
  let keep = false;
  for (const line of parts.front.split('\n')) {
    const key = /^([A-Za-z0-9_-]+):/.exec(line)?.[1];
    if (key !== undefined) keep = SKILL_KEEP.includes(key);
    if (keep) kept.push(line);
  }
  const notes: string[] = [];
  if (fm['disable-model-invocation'] === true)
    notes.push(
      'Claude Code runs this skill only when the user names it (`disable-model-invocation`). Load it only when the user asks for it by name.'
    );
  const disallowed = fm['disallowed-tools'];
  const list = Array.isArray(disallowed)
    ? disallowed.map(String)
    : typeof disallowed === 'string'
      ? disallowed.split(/,\s*(?![^()]*\))/).filter(Boolean)
      : [];
  if (list.length)
    notes.push(
      `Claude Code withholds these tools while this skill runs (\`disallowed-tools\`): ${list.map(t => `\`${t}\``).join(', ')}. Do not use them while you follow this skill.`
    );
  return `---\n${kept.join('\n')}\n---\n${withTrailingSection(parts.body, onCopilotSection(notes))}`;
}

/** `.claude/rules/<layer>.md` -> `.github/instructions/<layer>.instructions.md`. */
export function convertRule(layer: string, text: string, modules: readonly string[]): string {
  const parts = splitFrontmatter(text);
  let applyTo = '**';
  let body = text;
  if (parts) {
    const fm = parseYaml(parts.front, `rule ${layer}`);
    body = parts.body;
    const paths = Array.isArray(fm.paths)
      ? fm.paths.map(String)
      : fm.paths
        ? [String(fm.paths)]
        : [];
    if (paths.length) applyTo = paths.join(',');
  }
  if (modules.includes(layer))
    applyTo = `@@KIT_MODULES_${layer.toUpperCase().replace(/-/g, '_')}@@`;
  return `---\napplyTo: ${y(applyTo)}\n---\n${body}`;
}

export const KIT_MODULES = ['domain', 'usecase', 'adapter', 'gateway', 'platform'];

const EVENT_MAP: Record<string, string> = {
  SessionStart: 'sessionStart',
  UserPromptSubmit: 'userPromptSubmitted',
  PreToolUse: 'preToolUse',
  PostToolUse: 'postToolUse',
  PostToolUseFailure: 'postToolUseFailure',
  SubagentStart: 'subagentStart',
  SubagentStop: 'subagentStop',
  SessionEnd: 'sessionEnd',
  Stop: 'agentStop',
};

function shellWord(s: string): string {
  return /^[\w./@%+=:,-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`;
}

/** One settings.json hook command -> the script it runs (project-relative) and its arguments. */
export function parseHookCommand(cmd: string): { script: string; args: string[] } {
  const cd = /cd "\$CLAUDE_PROJECT_DIR\/([^"]+)"\s*&&/.exec(cmd)?.[1];
  const m =
    /exec bash (?:"\$CLAUDE_PROJECT_DIR\/([^"]+)"|([^\s;"]+))([^;]*?)\s*(?:;\s*else\b|;\s*fi\b|$)/.exec(
      cmd
    );
  if (!m) throw new Error(`hook command not understood: ${cmd}`);
  const script = m[1] ?? (cd ? `${cd}/${m[2]}` : (m[2] ?? ''));
  const args = (m[3] ?? '').trim().split(/\s+/).filter(Boolean);
  return { script, args };
}

/** settings.json `hooks` -> `.github/hooks/kit.json`. */
export function convertHooks(settings: Record<string, unknown>): string {
  const hooks = (settings.hooks ?? {}) as Record<string, unknown>;
  const out: Record<string, unknown[]> = {};
  for (const [event, groups] of Object.entries(hooks)) {
    const target = EVENT_MAP[event];
    if (!target) throw new Error(`no Copilot event for Claude hook event ${event}`);
    for (const group of (groups as Record<string, unknown>[]) ?? []) {
      const matcher = String(group.matcher ?? '');
      for (const h of (group.hooks as Record<string, unknown>[]) ?? []) {
        if (h.type !== 'command')
          throw new Error(`${event}: hook type ${String(h.type)} is not supported`);
        const { script, args } = parseHookCommand(String(h.command ?? ''));
        const bash = [
          'bash .github/hooks/dispatch.sh',
          event,
          `'${matcher.replace(/'/g, `'\\''`)}'`,
          shellWord(script),
          ...args.map(shellWord),
        ].join(' ');
        const entry = { type: 'command', bash, timeoutSec: Number(h.timeout ?? 60) };
        (out[target] ??= []).push(entry);
      }
    }
  }
  return `${JSON.stringify({ version: 1, hooks: out }, null, 2)}\n`;
}

/** settings.json `permissions.deny` -> `.archon/copilot/deny.json`. */
export function convertDeny(settings: Record<string, unknown>): string {
  const perms = (settings.permissions ?? {}) as Record<string, unknown>;
  const deny = Array.isArray(perms.deny) ? perms.deny.map(String) : [];
  return `${JSON.stringify(deny, null, 2)}\n`;
}

/** `.github/mcp.json`: core-only, or core plus the contract server. */
export function mcpJson(withContract: boolean): string {
  const servers: Record<string, unknown> = {
    codegraph: {
      type: 'local',
      command: 'codegraph',
      args: ['serve', '--mcp'],
      env: { CODEGRAPH_MCP_TOOLS: 'explore,node,search,callers,callees,impact' },
      tools: ['*'],
    },
  };
  if (withContract)
    servers[CONTRACT_SERVER] = {
      type: 'local',
      command: 'node',
      args: ['scripts/portal-mcp/server.mjs'],
      tools: ['*'],
    };
  return `${JSON.stringify({ mcpServers: servers }, null, 2)}\n`;
}

export const DISPATCH_SH = `#!/usr/bin/env bash
# dispatch.sh: GENERATED by Archon's kit-sync (kit/SPEC.md), do not edit. Runs one Claude Code hook script under the
# GitHub Copilot CLI; .github/hooks/kit.json calls it once per hook of the source's .claude/settings.json:
#   bash .github/hooks/dispatch.sh <ClaudeEvent> '<matcher>' <script path> [args...]
# It reads the hook payload on stdin and normalizes it to the Claude shape with .claude/hooks/scripts/payload.sh
# (when present), skips the hook when the Claude matcher (a regex over the tool name, anchored) does not match, and
# runs the script with the normalized payload on stdin: from .claude/hooks for a script under it (as settings.json
# does), else from the project root. On PreToolUse it turns a Claude deny (hookSpecificOutput.permissionDecision, or
# exit 2 with the reason on stderr) into Copilot's top-level permissionDecision/permissionDecisionReason. A missing
# script is a no-op, as in settings.json. The script's stderr passes through; dispatch.sh itself always exits 0.
set -uo pipefail
event="\${1:-}"; matcher="\${2:-}"; script="\${3:-}"
[ "$#" -ge 3 ] || exit 0
shift 3
root="\${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
[ -n "$root" ] || root="$PWD"
export CLAUDE_PROJECT_DIR="$root"
[ -f "$root/$script" ] || exit 0

payload="$(cat)"
if [ -f "$root/.claude/hooks/scripts/payload.sh" ]; then
  # shellcheck source=/dev/null
  . "$root/.claude/hooks/scripts/payload.sh"
  payload="$(hook_normalize_payload "$payload")"
fi

kit_deny() { # kit_deny <reason>: a deny decision in the Copilot and the Claude shape
  if declare -F hook_deny_json >/dev/null; then hook_deny_json "$1"; return; fi
  local r="\${1//\\\\/\\\\\\\\}"; r="\${r//\\"/\\\\\\"}"; r="\${r//$'\\n'/ }"
  printf '{"permissionDecision":"deny","permissionDecisionReason":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\\n' "$r" "$r"
}

if [ -n "$matcher" ] && [ "$matcher" != "*" ]; then
  tool=""
  re='"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
  [[ $payload =~ $re ]] && tool="\${BASH_REMATCH[1]}"
  [[ $tool =~ ^($matcher)$ ]] || exit 0
fi

case "$script" in
  .claude/hooks/*) dir="$root/.claude/hooks" ;;
  *) dir="$root" ;;
esac
errf="$(mktemp)"
trap 'rm -f "$errf"' EXIT
out="$(cd "$dir" && printf '%s' "$payload" | bash "$root/$script" "$@" 2>"$errf")"
rc=$?
cat "$errf" >&2

if [ "$event" = PreToolUse ]; then
  if [ "$rc" -eq 2 ]; then
    reason="$(tr '\\n' ' ' <"$errf")"
    kit_deny "\${reason:-blocked by $script}"
    exit 0
  fi
  case "$out" in
    *'"permissionDecision"'*)
      if command -v jq >/dev/null 2>&1; then
        conv="$(printf '%s' "$out" | jq -c 'if type == "object" and (.hookSpecificOutput.permissionDecision // null) != null and (.permissionDecision // null) == null
          then . + {permissionDecision: .hookSpecificOutput.permissionDecision, permissionDecisionReason: (.hookSpecificOutput.permissionDecisionReason // "")}
          else . end' 2>/dev/null)" && out="$conv"
      fi ;;
  esac
fi
[ -z "$out" ] || printf '%s\\n' "$out"
exit 0
`;

// ---------------------------------------------------------------------------------------------------------------
// Reading the source
// ---------------------------------------------------------------------------------------------------------------

export interface SourceFile {
  path: string;
  gitMode: string;
  content: Buffer;
}

export interface Source {
  dir: string;
  name: string;
  commit: string;
  files: Map<string, SourceFile>;
}

function git(dir: string, args: string[], input?: string): Buffer {
  const r = Bun.spawnSync(['git', '-C', dir, ...args], {
    stdin: input === undefined ? 'ignore' : Buffer.from(input),
    stdout: 'pipe',
    stderr: 'pipe',
  });
  if (r.exitCode !== 0)
    throw new Error(`git ${args.join(' ')} failed in ${dir}: ${r.stderr.toString().trim()}`);
  return r.stdout;
}

export function readSource(dir: string): Source {
  const commit = git(dir, ['rev-parse', 'HEAD']).toString().trim();
  let name = '';
  try {
    const url = git(dir, ['config', '--get', 'remote.origin.url']).toString().trim();
    name = basename(url).replace(/\.git$/, '');
  } catch {
    name = '';
  }
  if (!name) name = basename(git(dir, ['rev-parse', '--show-toplevel']).toString().trim());
  const entries: { path: string; gitMode: string; sha: string }[] = [];
  for (const rec of git(dir, ['ls-tree', '-r', '-z', 'HEAD']).toString().split('\0')) {
    if (!rec) continue;
    const tab = rec.indexOf('\t');
    const [mode, type, sha] = rec.slice(0, tab).split(' ');
    const path = rec.slice(tab + 1);
    if (type !== 'blob' || !SCANNED_ROOTS.some(r => path.startsWith(r))) continue;
    entries.push({ path, gitMode: mode ?? '', sha: sha ?? '' });
  }
  const files = new Map<string, SourceFile>();
  if (entries.length) {
    const out = git(dir, ['cat-file', '--batch'], `${entries.map(e => e.sha).join('\n')}\n`);
    let pos = 0;
    for (const e of entries) {
      const nl = out.indexOf(10, pos);
      const header = out.subarray(pos, nl).toString();
      const size = Number(header.split(' ')[2]);
      if (!Number.isFinite(size)) throw new Error(`git cat-file: bad header ${header}`);
      files.set(e.path, {
        path: e.path,
        gitMode: e.gitMode,
        content: Buffer.from(out.subarray(nl + 1, nl + 1 + size)),
      });
      pos = nl + 1 + size + 1;
    }
  }
  return { dir, name, commit, files };
}

/** Source paths that differ between the work tree and HEAD (kit-sync reads HEAD, so these are not in the kit). */
export function uncommitted(dir: string): string[] {
  return git(dir, ['status', '--porcelain', '--', ...SCANNED_ROOTS])
    .toString()
    .split('\n')
    .filter(Boolean)
    .map(l => l.slice(3));
}

// ---------------------------------------------------------------------------------------------------------------
// Building the kit
// ---------------------------------------------------------------------------------------------------------------

export interface KitFile {
  path: string;
  profile: Profile;
  mode: '0644' | '0755';
  template: boolean;
  origin: string | null;
  kind: Kind;
  content: string;
}

export interface Kit {
  source: { name: string; commit: string };
  aliases: Record<string, { provider: string; model: string }>;
  files: KitFile[];
  warnings: string[];
  failures: string[];
}

function globRe(pattern: string): RegExp {
  let re = '';
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i] ?? '';
    if (c === '*' && pattern[i + 1] === '*') {
      re += '.*';
      i++;
    } else if (c === '*') re += '[^/]*';
    else re += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}
const matches = (pattern: string, path: string): boolean => globRe(pattern).test(path);
const isGlob = (p: string): boolean => p.includes('*');

export function kindOf(path: string): Kind {
  if (path.startsWith('.github/agents/')) return 'agent';
  if (path.startsWith('.github/skills/') || path.startsWith('.agents/skills/')) return 'skill';
  if (path === '.github/mcp.json') return 'mcp';
  if (
    path.startsWith('.github/instructions/') ||
    path === '.github/copilot-instructions.md' ||
    path === '.claude/CLAUDE.md'
  )
    return 'instructions';
  if (path.startsWith('docs/scaffold-templates/')) return 'template';
  if (path.startsWith('.archon/workflows/')) return 'workflow';
  if (path.endsWith('.md')) return 'doc';
  if (
    /^(\.github\/hooks|\.claude\/hooks|\.archon\/copilot\/hooks|\.githooks|\.archon\/githooks)\//.test(
      path
    )
  )
    return 'hook';
  if (
    /\.(json|ya?ml|tsv|conf|service|timer|globs|env|example|toml|ini)$/.test(path) ||
    basename(path).startsWith('.')
  )
    return 'config';
  return 'script';
}

function frontmatterOf(text: string): Record<string, unknown> {
  const parts = splitFrontmatter(text);
  if (!parts) return {};
  try {
    return parseYaml(parts.front, 'frontmatter');
  } catch {
    return {};
  }
}

function mostSpecific(profiles: Profile[], where: string): Profile {
  if (!profiles.length) throw new Error(`${where}: names no known skill`);
  for (const p of ['java-quarkus', 'java', 'openapi-contract', 'core'] as Profile[])
    if (profiles.includes(p)) return p;
  throw new Error(`${where}: no profile`);
}

function leafProfile(name: string): Profile | undefined {
  return SKILL_PROFILES[name] ?? LEAF_PROFILES[name];
}

type Assignment =
  | { exclude: true; why: string }
  | { exclude?: false; profile: Profile; convert: 'agent' | 'skill' | 'rule' | 'copy' };

export function classify(path: string, text: string): Assignment {
  if (EXCLUDE.some(p => matches(p, path))) return { exclude: true, why: 'excluded' };
  let m: RegExpExecArray | null;
  if ((m = /^\.claude\/agents\/([^/]+)\.md$/.exec(path))) {
    const p = AGENT_PROFILES[m[1] ?? ''];
    if (!p) throw new Error(`${path}: agent not on a copy list (AGENT_PROFILES)`);
    return { profile: p, convert: 'agent' };
  }
  if ((m = /^\.claude\/skills\/([^/]+)\//.exec(path))) {
    const p = SKILL_PROFILES[m[1] ?? ''];
    if (!p) throw new Error(`${path}: skill not on a copy list (SKILL_PROFILES)`);
    return { profile: p, convert: 'skill' };
  }
  if ((m = /^\.claude\/rules\/([^/]+)\.md$/.exec(path))) {
    const p = RULE_PROFILES[m[1] ?? ''];
    if (!p) throw new Error(`${path}: rule not on a copy list (RULE_PROFILES)`);
    return { profile: p, convert: 'rule' };
  }
  if (path.startsWith('docs/scaffold-templates/'))
    return { profile: QUARKUS_TEMPLATE.test(text) ? 'java-quarkus' : 'java', convert: 'copy' };
  if (path.startsWith('docs/code-maps/') && path !== 'docs/code-maps/README.md') {
    const fm = frontmatterOf(text);
    if (fm.kind !== 'worked-example' || !path.endsWith('.md'))
      return { exclude: true, why: 'project code-map leaf' };
    const names = path.startsWith('docs/code-maps/exemplars/')
      ? Array.isArray(fm.serves)
        ? fm.serves.map(String)
        : []
      : [basename(path, '.md').replace(/\.worked-example$/, '')];
    const profiles = names.map(leafProfile).filter((p): p is Profile => p !== undefined);
    return { profile: mostSpecific(profiles, path), convert: 'copy' };
  }
  const hits: { profile: Profile; pattern: string }[] = [];
  for (const profile of PROFILES)
    for (const pattern of FILES[profile])
      if (matches(pattern, path)) hits.push({ profile, pattern });
  const exact = hits.filter(h => !isGlob(h.pattern));
  const chosen = exact.length ? exact : hits;
  if (chosen.length === 1 && chosen[0]) return { profile: chosen[0].profile, convert: 'copy' };
  if (chosen.length > 1)
    throw new Error(
      `${path}: on more than one copy list (${chosen.map(h => `${h.profile}:${h.pattern}`).join(', ')})`
    );
  throw new Error(`${path}: not on a copy list and not excluded; assign it in scripts/kit-sync.ts`);
}

function textOf(f: SourceFile): string {
  if (f.content.includes(0))
    throw new Error(`${f.path}: binary files are not supported by the kit`);
  return f.content.toString('utf8');
}

export function applyRewrites(path: string, text: string, rules: Rewrite[]): string {
  let out = text;
  for (const [from, to, count] of rules) {
    const n = out.split(from).length - 1;
    if (n !== count)
      throw new Error(
        `${path}: rewrite expected ${count} of ${JSON.stringify(from.slice(0, 60))}, found ${n}`
      );
    out = out.split(from).join(to);
  }
  return out;
}

export function applyGlobalRewrites(text: string): string {
  let out = text;
  for (const [re, to] of GLOBAL_REWRITES) out = out.replace(re, to);
  return out;
}

function targetPath(path: string, convert: 'agent' | 'skill' | 'rule' | 'copy'): string {
  if (convert === 'agent') return `.github/agents/${basename(path, '.md')}.agent.md`;
  if (convert === 'rule') return `.github/instructions/${basename(path, '.md')}.instructions.md`;
  if (convert === 'skill') {
    const [, , skill, ...rest] = path.split('/');
    return ['.github/skills', SKILL_RENAMES[skill ?? ''] ?? skill, ...rest].join('/');
  }
  return path;
}

function copilotWorkflowFromScript(src: Source): string {
  const tmp = mkdtempSync(join(tmpdir(), 'kit-sync-wf-'));
  try {
    for (const p of [
      '.archon/workflows/build-feature.yaml',
      '.archon/scripts/copilot-workflow.js',
    ]) {
      const f = src.files.get(p);
      if (!f)
        throw new Error(
          `${p}: missing in the source, needed to generate build-feature-copilot.yaml`
        );
      mkdirSync(join(tmp, dirname(p)), { recursive: true });
      writeFileSync(join(tmp, p), f.content);
    }
    const r = Bun.spawnSync(['node', join(tmp, '.archon/scripts/copilot-workflow.js')], {
      env: { ...process.env, COPILOT_WORKFLOW_ROOT: tmp },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    if (r.exitCode !== 0)
      throw new Error(`copilot-workflow.js failed: ${r.stderr.toString().trim()}`);
    return readFileSync(join(tmp, '.archon/workflows/build-feature-copilot.yaml'), 'utf8');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

const sha256 = (s: string | Buffer): string => createHash('sha256').update(s).digest('hex');

interface OverlayEntry {
  derivedFrom: string | null;
  sourceSha256: string | null;
}

function walk(dir: string, base = dir): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(full, base));
    else if (e.isFile()) out.push(relative(base, full).split('\\').join('/'));
  }
  return out.sort();
}

export interface OverlayFile {
  profile: Profile;
  path: string;
  content: string;
  executable: boolean;
  entry: OverlayEntry;
}

/** `kit/overlays/<profile>/**`: every file (but overlay.json) listed in overlay.json, and every entry present. */
export function readOverlays(overlaysDir: string): OverlayFile[] {
  const out: OverlayFile[] = [];
  if (!existsSync(overlaysDir)) return out;
  for (const profile of readdirSync(overlaysDir).sort()) {
    const dir = join(overlaysDir, profile);
    if (!statSync(dir).isDirectory()) continue;
    if (!(PROFILES as readonly string[]).includes(profile))
      throw new Error(`kit/overlays/${profile}: not a profile`);
    const listFile = join(dir, 'overlay.json');
    const list: Record<string, OverlayEntry> = existsSync(listFile)
      ? (JSON.parse(readFileSync(listFile, 'utf8')) as Record<string, OverlayEntry>)
      : {};
    const files = walk(dir).filter(p => p !== 'overlay.json');
    for (const p of files) {
      const entry = list[p];
      if (!entry) throw new Error(`kit/overlays/${profile}/${p}: not listed in overlay.json`);
      const full = join(dir, p);
      const content = readFileSync(full, 'utf8');
      out.push({
        profile: profile as Profile,
        path: p,
        content,
        executable: (statSync(full).mode & 0o111) !== 0,
        entry,
      });
    }
    for (const p of Object.keys(list))
      if (!files.includes(p))
        throw new Error(`kit/overlays/${profile}/overlay.json lists ${p}, which is missing`);
  }
  return out;
}

/** Overlays whose derivedFrom source file changed since the overlay was written. */
export function staleOverlays(overlays: OverlayFile[], src: Source): string[] {
  const out: string[] = [];
  for (const o of overlays) {
    if (!o.entry.derivedFrom) continue;
    const f = src.files.get(o.entry.derivedFrom);
    const now = f ? sha256(f.content) : null;
    if (now !== o.entry.sourceSha256)
      out.push(
        `${o.profile}/${o.path}: derivedFrom ${o.entry.derivedFrom} ${now ? `is now ${now}` : 'is gone'} (overlay records ${o.entry.sourceSha256})`
      );
  }
  return out;
}

const COPILOT_WORKFLOW = '.archon/workflows/build-feature-copilot.yaml';
const BUILD_WORKFLOW = '.archon/workflows/build-feature.yaml';

/** `rewrites` is a test seam; the real sync uses TARGETED, and a TARGETED path the source lacks fails it. */
export function buildKit(
  src: Source,
  overlays: OverlayFile[],
  rewrites: Record<string, Rewrite[]> = TARGETED
): Kit {
  const files: KitFile[] = [];
  const add = (f: Omit<KitFile, 'template' | 'kind'> & { kind?: Kind }): void => {
    files.push({ ...f, kind: f.kind ?? kindOf(f.path), template: f.content.includes('@@KIT_') });
  };
  for (const p of Object.keys(rewrites))
    if (!src.files.has(p) && !(p === COPILOT_WORKFLOW && src.files.has(BUILD_WORKFLOW)))
      throw new Error(`${p}: has rewrites in scripts/kit-sync.ts but is not in the source`);

  for (const f of [...src.files.values()].sort((a, b) => (a.path < b.path ? -1 : 1))) {
    const raw = textOf(f);
    const a = classify(f.path, raw);
    if (a.exclude) continue;
    if (f.gitMode === '120000') throw new Error(`${f.path}: symlinks are not supported by the kit`);
    let text = applyRewrites(f.path, raw, rewrites[f.path] ?? []);
    if (a.convert === 'agent') text = convertAgent(text, f.path);
    else if (a.convert === 'rule') text = convertRule(basename(f.path, '.md'), text, KIT_MODULES);
    else if (a.convert === 'skill' && basename(f.path) === 'SKILL.md')
      text = convertSkillMd(text, f.path);
    text = f.path.startsWith('.agents/skills/archon-cli/')
      ? text.replace(PROJECT_DIR, '@@KIT_PROJECT_DIR@@')
      : applyGlobalRewrites(text);
    add({
      path: targetPath(f.path, a.convert),
      profile: a.profile,
      mode: f.gitMode === '100755' ? '0755' : '0644',
      origin: f.path,
      content: text,
    });
  }

  if (!src.files.has(COPILOT_WORKFLOW) && src.files.has(BUILD_WORKFLOW)) {
    const text = applyGlobalRewrites(
      applyRewrites(
        COPILOT_WORKFLOW,
        copilotWorkflowFromScript(src),
        rewrites[COPILOT_WORKFLOW] ?? []
      )
    );
    add({
      path: COPILOT_WORKFLOW,
      profile: 'core',
      mode: '0644',
      origin: BUILD_WORKFLOW,
      content: text,
    });
  }

  const settingsFile = src.files.get('.claude/settings.json');
  if (settingsFile) {
    const settings = JSON.parse(textOf(settingsFile)) as Record<string, unknown>;
    add({
      path: '.github/hooks/kit.json',
      profile: 'core',
      mode: '0644',
      origin: '.claude/settings.json',
      kind: 'hook',
      content: convertHooks(settings),
    });
    add({
      path: '.archon/copilot/deny.json',
      profile: 'core',
      mode: '0644',
      origin: '.claude/settings.json',
      kind: 'config',
      content: convertDeny(settings),
    });
  }
  add({
    path: '.github/hooks/dispatch.sh',
    profile: 'core',
    mode: '0755',
    origin: null,
    kind: 'hook',
    content: DISPATCH_SH,
  });
  add({
    path: '.github/mcp.json',
    profile: 'core',
    mode: '0644',
    origin: null,
    content: mcpJson(false),
  });
  add({
    path: '.github/mcp.json',
    profile: 'openapi-contract',
    mode: '0644',
    origin: null,
    content: mcpJson(true),
  });

  const seen = new Map<string, KitFile>();
  for (const f of files) {
    const key = `${f.profile}/${f.path}`;
    if (seen.has(key))
      throw new Error(`${key}: generated twice (from ${seen.get(key)?.origin} and ${f.origin})`);
    seen.set(key, f);
  }
  for (const o of overlays) {
    const key = `${o.profile}/${o.path}`;
    seen.set(key, {
      path: o.path,
      profile: o.profile,
      mode: o.executable ? '0755' : '0644',
      template: o.content.includes('@@KIT_'),
      origin: o.entry.derivedFrom,
      kind: kindOf(o.path),
      content: o.content,
    });
  }
  const order = (p: Profile): number => PROFILES.indexOf(p);
  const all = [...seen.values()].sort((a, b) =>
    order(a.profile) !== order(b.profile)
      ? order(a.profile) - order(b.profile)
      : a.path < b.path
        ? -1
        : a.path > b.path
          ? 1
          : 0
  );
  for (const f of all)
    if (f.path.startsWith('/') || f.path.split('/').includes('..'))
      throw new Error(`${f.profile}/${f.path}: not a relative project path`);

  const leaks = leakCheck(all);
  return {
    source: { name: src.name, commit: src.commit },
    aliases: aliasesOf(src),
    files: all,
    ...leaks,
  };
}

function aliasesOf(src: Source): Record<string, { provider: string; model: string }> {
  const f = src.files.get('.archon/config.yaml');
  if (!f) return {};
  const cfg = Bun.YAML.parse(textOf(f)) as {
    aliases?: Record<string, { provider?: string; model?: string }>;
  };
  const out: Record<string, { provider: string; model: string }> = {};
  for (const [k, v] of Object.entries(cfg?.aliases ?? {}).sort(([a], [b]) => (a < b ? -1 : 1)))
    if (v?.provider === 'copilot') out[k] = { provider: 'copilot', model: String(v.model ?? '') };
  return out;
}

export function manifestOf(kit: Kit): string {
  const manifest = {
    version: 1,
    source: kit.source,
    profiles: Object.fromEntries(PROFILES.map(p => [p, PROFILE_META[p]])),
    exclusive: EXCLUSIVE,
    files: kit.files.map(f => ({
      path: f.path,
      profile: f.profile,
      mode: f.mode,
      template: f.template,
      origin: f.origin,
      kind: f.kind,
      sha256: sha256(f.content),
    })),
    aliases: kit.aliases,
    postInstall: POST_INSTALL,
  };
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

/** Writes `<out>/profiles/**` (replacing it) and `<out>/manifest.json`; leaves the hand-written files alone. */
export function writeKit(kit: Kit, out: string): void {
  rmSync(join(out, 'profiles'), { recursive: true, force: true });
  for (const f of kit.files) {
    const full = join(out, 'profiles', f.profile, f.path);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, f.content);
    chmodSync(full, f.mode === '0755' ? 0o755 : 0o644);
  }
  writeFileSync(join(out, 'manifest.json'), manifestOf(kit));
}

/** The generated tree as `relative path -> bytes`: `manifest.json` and `profiles/**`. */
export function snapshot(out: string): Map<string, string> {
  const m = new Map<string, string>();
  if (existsSync(join(out, 'manifest.json')))
    m.set('manifest.json', readFileSync(join(out, 'manifest.json'), 'utf8'));
  for (const p of walk(join(out, 'profiles'))) {
    const full = join(out, 'profiles', p);
    const exec = (statSync(full).mode & 0o111) !== 0 ? ' (0755)' : '';
    m.set(`profiles/${p}${exec}`, readFileSync(full, 'utf8'));
  }
  return m;
}

export function diffSnapshots(want: Map<string, string>, have: Map<string, string>): string[] {
  const out: string[] = [];
  for (const [k, v] of want)
    if (have.get(k) !== v) out.push(have.has(k) ? `changed: ${k}` : `missing: ${k}`);
  for (const k of have.keys()) if (!want.has(k)) out.push(`extra: ${k}`);
  return out.sort();
}

/** Source-free check of a committed kit: manifest <-> profiles files, overlay copies, order and leaks. */
export function verifyKit(out: string): string[] {
  const problems: string[] = [];
  const mf = join(out, 'manifest.json');
  if (!existsSync(mf)) return [`${mf}: missing`];
  const manifest = JSON.parse(readFileSync(mf, 'utf8')) as {
    files: { path: string; profile: Profile; mode: string; template: boolean; sha256: string }[];
  };
  const listed = new Set<string>();
  const files: { profile: string; path: string; content: string }[] = [];
  let prev = '';
  for (const f of manifest.files) {
    const key = `${f.profile}/${f.path}`;
    const sortKey = `${PROFILES.indexOf(f.profile)}\0${f.path}`;
    if (sortKey <= prev) problems.push(`manifest: ${key} is out of order`);
    prev = sortKey;
    listed.add(key);
    const full = join(out, 'profiles', key);
    if (!existsSync(full)) {
      problems.push(`missing: profiles/${key}`);
      continue;
    }
    const content = readFileSync(full, 'utf8');
    files.push({ profile: f.profile, path: f.path, content });
    if (sha256(content) !== f.sha256)
      problems.push(`changed: profiles/${key} (sha256 differs from manifest)`);
    if (f.template !== content.includes('@@KIT_'))
      problems.push(`manifest: ${key} template flag is wrong`);
    const exec = (statSync(full).mode & 0o111) !== 0;
    if (exec !== (f.mode === '0755')) problems.push(`mode: profiles/${key} is not ${f.mode}`);
  }
  for (const p of walk(join(out, 'profiles')))
    if (!listed.has(p)) problems.push(`extra: profiles/${p}`);
  try {
    for (const o of readOverlays(join(out, 'overlays'))) {
      const full = join(out, 'profiles', o.profile, o.path);
      if (!existsSync(full) || readFileSync(full, 'utf8') !== o.content)
        problems.push(`overlay not synced: overlays/${o.profile}/${o.path} (run kit-sync)`);
    }
  } catch (e) {
    problems.push(String((e as Error).message));
  }
  for (const f of leakCheck(files).failures) problems.push(`leak: ${f}`);
  return problems;
}

// ---------------------------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------------------------

export interface SyncResult {
  kit: Kit;
  drift: string[];
  stale: string[];
  dirty: string[];
}

export function sync(
  source: string,
  out: string,
  check: boolean,
  rewrites: Record<string, Rewrite[]> = TARGETED
): SyncResult {
  const src = readSource(source);
  const overlays = readOverlays(join(out, 'overlays'));
  const kit = buildKit(src, overlays, rewrites);
  const stale = staleOverlays(overlays, src);
  const dirty = uncommitted(source).filter(p => {
    try {
      return !classify(p, '').exclude;
    } catch {
      return true;
    }
  });
  if (kit.failures.length) return { kit, drift: [], stale, dirty };
  if (!check) {
    writeKit(kit, out);
    return { kit, drift: [], stale, dirty };
  }
  const tmp = mkdtempSync(join(tmpdir(), 'kit-sync-check-'));
  try {
    writeKit(kit, tmp);
    return { kit, drift: diffSnapshots(snapshot(tmp), snapshot(out)), stale, dirty };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

function main(argv: string[]): number {
  let out = 'kit';
  let check = false;
  let verify = false;
  let source = '';
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i] ?? '';
    if (a === '--check') check = true;
    else if (a === '--verify') verify = true;
    else if (a === '--out') out = argv[++i] ?? '';
    else if (a.startsWith('--')) {
      console.error(`unknown option ${a}`);
      return 2;
    } else source = a;
  }
  out = resolve(out);
  if (verify) {
    const problems = verifyKit(out);
    for (const p of problems) console.error(p);
    if (problems.length) {
      console.error(
        `kit is not consistent (${problems.length}); regenerate with: bun run kit:sync <source-repo>`
      );
      return 1;
    }
    console.log(`kit ok: ${out}`);
    return 0;
  }
  if (!source) {
    console.error(
      'usage: kit-sync.ts <source-repo> [--check] [--out kit] | kit-sync.ts --verify [--out kit]'
    );
    return 2;
  }
  const r = sync(resolve(source), out, check);
  for (const d of r.dirty)
    console.error(`warning: ${d} has uncommitted changes; the kit reads the source's HEAD`);
  for (const w of r.kit.warnings) console.log(`WARN project noun: ${w}`);
  if (r.kit.failures.length) {
    for (const f of r.kit.failures) console.error(`FAIL leak: ${f}`);
    return 1;
  }
  for (const s of r.stale) console.error(`stale overlay: ${s}`);
  const counts = PROFILES.map(p => `${p} ${r.kit.files.filter(f => f.profile === p).length}`).join(
    ', '
  );
  if (check) {
    for (const d of r.drift) console.error(d);
    if (r.drift.length || r.stale.length) {
      console.error(
        `kit drift (${r.drift.length} paths, ${r.stale.length} stale overlays); run: bun run kit:sync ${source}`
      );
      return 1;
    }
    console.log(
      `kit up to date with ${r.kit.source.name}@${r.kit.source.commit.slice(0, 12)} (${counts})`
    );
    return 0;
  }
  console.log(
    `kit written from ${r.kit.source.name}@${r.kit.source.commit.slice(0, 12)}: ${counts}`
  );
  return 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
