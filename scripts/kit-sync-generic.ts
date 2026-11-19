/**
 * kit-sync's project-noun and path rewrites (kit/SPEC.md, Rewrites): what makes a shipped file generic. The token
 * and path rules run over every shipped text file; the per-file rules are exact and fail the sync when their text is
 * missing, like the rest of TARGETED. scripts/kit-sync.ts runs them.
 */
import type { Rewrite } from './kit-sync-lists';

/** Project-noun tokens, rewritten in every shipped text file (after TARGETED, before PATH_REWRITES). */
export const NOUN_REWRITES: [RegExp, string][] = [
  [/%h\/wedding-portal(?![\w-])/g, '@@KIT_PROJECT_DIR@@'], // systemd units
  [/mcp__portal-api__/g, 'mcp__@@KIT_CONTRACT_SERVER_NAME@@__'],
  [/(?<![\w-])portal-api(?![\w-])/g, '@@KIT_CONTRACT_SERVER_NAME@@'],
  [/(?<![\w-])portal-mcp(?!\w)/g, 'contract-mcp'], // scripts/portal-mcp/, portal-mcp-setup.sh, `portal-mcp:` lines
  [/(?<![\w-])portal-metrics(?![\w-])/g, 'run-metrics'],
  [/(?<![\w-])rekordContractTag(?![\w-])/g, '@@KIT_CONTRACT_TAG_KEY@@'],
];

/** Source paths that ship under another path; the content rules above rename every reference to them. */
export const PATH_RENAMES: [RegExp, string][] = [
  [/^scripts\/portal-mcp\//, 'scripts/contract-mcp/'],
  [/^\.archon\/scripts\/portal-mcp-setup\.sh$/, '.archon/scripts/contract-mcp-setup.sh'],
  [/^\.archon\/workflows\/portal-metrics\.yaml$/, '.archon/workflows/run-metrics.yaml'],
  [/^scripts\/test\/portal-mcp\.test\.sh$/, 'scripts/test/contract-mcp.test.sh'],
  [
    /^\.archon\/scripts\/test\/portal-mcp-setup\.test\.sh$/,
    '.archon/scripts/test/contract-mcp-setup.test.sh',
  ],
  [/^scripts\/test\/fixtures\/portal-mcp\//, 'scripts/test/fixtures/contract-mcp/'],
];

export function renamePath(path: string): string {
  for (const [re, to] of PATH_RENAMES) if (re.test(path)) return path.replace(re, to);
  return path;
}

// A file name inside a path reference: no blank, quote, backtick, pipe, comma, semicolon or parenthesis.
const NAME = String.raw`[^\s\x60"'|,;()]*?`;

/** Claude Code paths -> where the kit ships them (task: path references). Every shipped text file except PATH_SKIP. */
export const PATH_REWRITES: [RegExp, string][] = [
  [
    new RegExp(String.raw`\.claude([/\\])agents([/\\]${NAME})(?<!\.agent)\.md(?!\w)`, 'g'),
    '.github$1agents$2.agent.md',
  ],
  [/\.claude([/\\])agents(?![\w-])/g, '.github$1agents'],
  [
    new RegExp(String.raw`\.claude([/\\])rules([/\\]${NAME})(?<!\.instructions)\.md(?!\w)`, 'g'),
    '.github$1instructions$2.instructions.md',
  ],
  [/\.claude([/\\])rules(?![\w-])/g, '.github$1instructions'],
  [/\.claude([/\\])skills(?![\w-])/g, '.github$1skills'],
];

/**
 * Files whose `.claude/agents|rules|skills` references mean those very files, so they keep them:
 * the Copilot README lists what Copilot reads natively; audit-log.sh and verify-claims.sh already match both the
 * Claude and the .github paths; skill-check.js reads an agent's `.claude/agents/<name>.md` frontmatter.
 */
export const PATH_SKIP: string[] = [
  '.archon/copilot/README.md',
  '.archon/scripts/skill-check.js',
  '.claude/hooks/scripts/audit-log.sh',
  '.claude/hooks/scripts/verify-claims.sh',
];

const THIS_REPO_HEADING = /^## This repo \([^)\n]*\)\n[\s\S]*?(?=^## )/m;
const THIS_REPO_STUB =
  '## This repo\n' +
  "Fill in this project's own facts for the pattern here: its modules, packages and the rules in force. Until then,\n" +
  'everything from "Where this pattern lives" down is the pseudonymized worked example: follow its structure, not its\n' +
  'names.\n\n';

/** Code-map leaves whose `## This repo (<source>)` section holds the source's facts; it ships as a stub. */
export const THIS_REPO_LEAVES: string[] = [
  'archunit-fitness',
  'code-generation',
  'domain-events',
  'domain-modeling',
  'flyway-migrations',
  'java',
  'jpa-entity-mapping',
  'object-mother-builders',
  'usecase-orchestration',
  'validation-notification-result',
].map(n => `docs/code-maps/${n}.md`);

/** Profiles whose leaves must be generic; the java-quarkus originals keep their facts (kit/SPEC.md, Leak check). */
const GENERIC_PROFILES = ['core', 'java'];

/**
 * The stub for a listed leaf (fails when its section is gone); any other core or java leaf with such a section fails
 * too, so a new one cannot ship the source's facts unnoticed.
 */
export function genericThisRepo(path: string, profile: string, text: string): string {
  if (!GENERIC_PROFILES.includes(profile)) return text;
  const listed = THIS_REPO_LEAVES.includes(path);
  const has = THIS_REPO_HEADING.test(text);
  if (listed && !has)
    throw new Error(
      `${path}: has no "## This repo (...)" section for THIS_REPO_LEAVES in scripts/kit-sync-generic.ts`
    );
  if (!listed && has)
    throw new Error(
      `${path}: has a "## This repo (...)" section; add it to THIS_REPO_LEAVES in scripts/kit-sync-generic.ts`
    );
  return listed ? text.replace(THIS_REPO_HEADING, THIS_REPO_STUB) : text;
}

const HOOKS = 'the project hooks';
const SOURCE_MODULES =
  'default_mods="application identity-adapter identity-domain identity-usecase library-adapter library-domain ' +
  'library-usecase logging matching-adapter matching-domain matching-usecase musicfolder-gateway pdf-gateway ' +
  'planning-adapter planning-domain planning-usecase portal-adapter portal-domain portal-usecase shared-adapter ' +
  'shared-domain shared-usecase spotify-gateway"';

/** Exact per-file noun rewrites in comments and messages; merged into TARGETED. */
export const NOUN_TARGETED: Record<string, Rewrite[]> = {
  '.archon/scripts/pick-tickets.js': [
    ['element id such as `portal-backend`', 'element id such as `orders-backend`', 1],
  ],
  '.archon/scripts/retro-umbrella.sh': [
    [
      'was the umbrella repo weddingapp until its docs moved into wedding-portal (2026-10-17), so',
      'was a separate umbrella repo until its docs moved into this repo, so',
      1,
    ],
  ],
  '.archon/scripts/ticket.sh': [
    ['The Backlog lives in the wedding-portal repo.', 'The Backlog lives in this repo.', 1],
  ],
  '.archon/scripts/wait-merge.sh': [
    ['main checkout (the wedding-portal one)', "main checkout (this repo's)", 1],
  ],
  '.archon/scripts/park-ticket.sh': [
    ['"Parked <Brussels time>: <why>"', '"Parked <local time>: <why>"', 1],
    ['TZ=Europe/Brussels date', 'TZ=@@KIT_TIMEZONE@@ date', 1],
  ],
  '.archon/stop/policy.json': [
    ['"owner": "Viktor Van Steenweghen",', '"owner": "@@KIT_OWNER@@",', 1],
    ['"timezone": "Europe/Brussels",', '"timezone": "@@KIT_TIMEZONE@@",', 1],
    ['"rekord-contract",', '"@@KIT_CONTRACT_REPO@@",', 1],
  ],
  '.claude/scripts/groma-check.sh': [
    ["is weddingapp's\n# scripts/web-uis.sh.)", 'is\n# scripts/web-uis.sh.)', 1],
  ],
  'scripts/tools.conf': [
    [
      "# wedding-portal's Gradle toolchain is Java 25",
      "# the project's JDK (its Gradle toolchain)",
      1,
    ],
    ["Testcontainers in wedding-portal's tests", "Testcontainers in the project's tests", 1],
    ["under wedding-portal's .archon/", "under the project's .archon/", 1],
    ["(wedding-portal's backlog/)", "(the project's backlog/)", 1],
    [
      "the architecture map in wedding-portal; 0.6.6 is the pin wedding-portal's CI installs",
      "the architecture map (groma/); 0.6.6 is the pin the kit's source CI installs",
      1,
    ],
  ],
  'scripts/install-tools.sh': [
    ['#   PORTAL_DIR      ', '#   PROJECT_DIR     ', 1],
    ['portal=${PORTAL_DIR:-', 'project=${PROJECT_DIR:-', 1],
    ['$portal/', '$project/', 4],
    ['cd "$portal"', 'cd "$project"', 1],
    ["Switching on wedding-portal's git hooks", "Switching on the project's git hooks", 1],
    ['failed: wedding-portal hooks', `failed: ${HOOKS}`, 1],
    ['("wedding-portal-hooks")', '("project-hooks")', 1],
    ['Skipped wedding-portal hooks:', `Skipped ${HOOKS}:`, 1],
  ],
  'scripts/web-uis.sh': [
    [
      '# wedding-portal (`backlog browser`), the Groma architecture map of wedding-portal (`groma web`)',
      '# this project (`backlog browser`), the Groma architecture map of this project (`groma web`)',
      1,
    ],
    ['while wedding-portal has no groma/ folder', 'while this project has no groma/ folder', 1],
  ],
  'scripts/tokenomics/commit-reports.sh': [
    ["<repo dir: wedding-portal's main checkout>", "<repo dir: the project's main checkout>", 1],
  ],
  // The build and image gates: the source's own values sit in their defaults; an install reads its kit.yaml.
  '.claude/scripts/build-shape-check.sh': [
    [
      'no Python or\n# rekord-api remnant is back.',
      'no Python or\n# forbidden remnant (kit key build_shape.forbidden) is back.',
      1,
    ],
    [SOURCE_MODULES, 'default_mods="-"', 1],
    ['"\\"${root_name:-wedding-portal}\\""', '"\\"${root_name:-}\\""', 1],
    ['kit_get build_shape.memory_marker UD-17 ', 'kit_get build_shape.memory_marker - ', 1],
    ['kit_get build_shape.forbidden rekord-api ', 'kit_get build_shape.forbidden - ', 1],
  ],
  '.claude/scripts/image-check.sh': [
    ['wedding-image-check', 'app-image-check', 2],
    ['db_user="wedding_portal"\ndb_name="wedding_portal"', 'db_user="app"\ndb_name="app"', 1],
    [' and the ops/throttle settings.', '.', 1],
    [
      '   -e WEDDING_OPS_USERNAME="ops" -e WEDDING_OPS_PASSWORD="$(openssl rand -hex 16)" \\\n  -e WEDDING_THROTTLE_SERVER_KEY="$(openssl rand -base64 32)" "$image")"',
      ' "$image")"',
      1,
    ],
  ],
  '.claude/scripts/ci-local.sh': [
    ['wedding-portal:ci-', 'app:ci-', 2],
    ['wedding-image-check-', 'app-image-check-', 4],
  ],
  // The contract scripts' defaults: an install's kit.yaml names its own; the shipped defaults are generic examples.
  'scripts/portal-mcp/kit-config.mjs': [
    ["'project_name': 'wedding-portal',", "'project_name': 'app',", 1],
    [
      "'contract.generated_dir': 'shared-adapter/build/generated/openapi/src/gen/java/app/rekord/api',",
      "'contract.generated_dir': 'shared-adapter/build/generated/openapi/src/gen/java/com/example/api',",
      1,
    ],
    ["'contract.api_package': 'app.rekord.api',", "'contract.api_package': 'com.example.api',", 1],
  ],
  '.claude/scripts/contract-pin.sh': [
    ['# Checks the rekord-contract checkout out', '# Checks the contract checkout out', 1],
  ],
  // park-ticket.sh stamps the install's timezone (kit key timezone), not the source's CET/CEST.
  '.archon/scripts/test/park-ticket.test.sh': [
    ['[0-9:]+ CES?T: held', '[0-9:]+ [A-Z][A-Za-z0-9+-]*: held', 1],
  ],
  // A case about the source's own ci-inputs.yml (its test-data gate input); an install's inputs have no such gate.
  'scripts/test/ci-plan.test.sh': [
    [
      '[ "$(fp test "$(plan "$c_leaf")")" != "$(fp test "$(plan "$c_mem")")" ]; check "a docs/code-maps/test-data.md change moves test (the test-data gate reads it)" "$?" 0',
      "# (the source's test-data gate case is left out: it asserts the source's own ci-inputs.yml)",
      1,
    ],
  ],
  // kit-config.mjs's shipped project_name default is 'app' (above), so its suite expects that.
  'scripts/test/portal-mcp.test.sh': [
    ['app.rekord.api wedding-portal from-env', 'app.rekord.api app from-env', 1],
  ],
  'docs/scaffold-templates/domain/id.mustache': [
    ['e.g. Wedding renders WeddingId', 'e.g. Order renders OrderId', 1],
  ],
  'docs/code-maps/code-generation.md': [
    ['`app/rekord/planning/domain/`', '`com/example/orders/domain/`', 1],
    ['"package": "app.rekord.planning"', '"package": "com.example.orders"', 1],
  ],
};

/** a + b, per path; a path in both keeps a's rules first. */
export function mergeRewrites(
  a: Record<string, Rewrite[]>,
  b: Record<string, Rewrite[]>
): Record<string, Rewrite[]> {
  const out: Record<string, Rewrite[]> = { ...a };
  for (const [p, r] of Object.entries(b)) out[p] = [...(out[p] ?? []), ...r];
  return out;
}
