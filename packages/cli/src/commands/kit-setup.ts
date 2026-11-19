/**
 * `archon kit setup` - the guided install of the Copilot kit.
 *
 * A terminal dialog asks for the backend repository, the frontend repository (optional) and the API contract file,
 * then installs the tools, puts the kit into the backend, points it at the contract, indexes both repositories for
 * CodeGraph, gives the frontend the codegraph MCP server, adds the rtk hooks, checks every MCP server and starts the
 * web views. Flags answer the dialog for a run without a terminal. Each step's output goes to a log file under the
 * Archon home, never to the terminal; a failed step is reported with that log and the later steps still run.
 *
 * Every external effect goes through `KitSetupDeps`, so the tests stub the runner, the tool installer and the
 * MCP probe and never spawn a real tool.
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'fs';
import { homedir } from 'os';
import { extname, join, resolve } from 'path';
import { format } from 'util';
import { getArchonHome } from '@archon/paths';
import { parse as parseYaml, parseDocument } from 'yaml';
import {
  KIT_YAML,
  applySetOverrides,
  checkMcpServers,
  copilotHome,
  isGitRepo,
  kitAddCommand,
  kitToolsCommand,
  onPath,
  resolveProfiles,
  trustFolder,
  type DoctorCheck,
  type Kit,
  type OutputSink,
} from './kit';
import { clackUi, plainUi, spawnRunner, type Runner, type SetupUi } from './kit-setup-ui';

export {
  clackUi,
  plainUi,
  spawnRunner,
  type Runner,
  type SetupSpinner,
  type SetupUi,
} from './kit-setup-ui';

export const DEFAULT_SETUP_PROFILES = ['core', 'java', 'java-spring', 'openapi-contract'];
const CONTRACT_EXTENSIONS = new Set(['.yaml', '.yml', '.json']);
const MCP_JSON = join('.github', 'mcp.json');
const CODEGRAPH_SETUP = '.archon/scripts/codegraph-setup.sh';
/** The kit's contract MCP setup script; a project synced before the kit's rename carries the older name. */
const CONTRACT_SETUP_SCRIPTS = [
  '.archon/scripts/contract-mcp-setup.sh',
  '.archon/scripts/portal-mcp-setup.sh',
];
const WEB_UIS = 'scripts/web-uis.sh';

export const KIT_SETUP_USAGE = `Usage: archon kit setup [--backend <path> --contract <file>] [options]

Asks for the backend repository, the frontend repository and the API contract file, then installs the
tools, the kit, the contract MCP server, the CodeGraph indexes, the rtk hooks and the web views.
Without a terminal, --backend and --contract are required.

Options:
  --backend <path>     Backend git repository (gets the kit)
  --frontend <path>    Frontend git repository (gets the codegraph MCP server; empty or absent skips it)
  --contract <file>    OpenAPI contract (.yaml, .yml or .json with a top-level openapi key)
  --profile <a,b,c>    Kit profiles (default: the last run's, else ${DEFAULT_SETUP_PROFILES.join(',')})
  --yes                Skip the confirmation
  --no-tools           Skip the tool installer
  --no-rtk             Skip the rtk hooks
  --no-web             Do not start the web views

Exit codes: 0 done (or cancelled), 1 a step failed, 2 a usage error.`;

// ---------------------------------------------------------------------------
// Paths and their checks
// ---------------------------------------------------------------------------

/** `~` and `~/x` read against the home folder; any other relative path against `cwd`. */
export function expandPath(input: string, cwd: string, home: string): string {
  const text = input.trim();
  if (text === '~') return home;
  if (text.startsWith('~/')) return join(home, text.slice(2));
  return resolve(cwd, text);
}

export type PathCheck = { ok: true; path: string } | { ok: false; error: string };

/** An existing git repository, as an absolute path. */
export function checkRepoPath(input: string | undefined, cwd: string, home: string): PathCheck {
  const text = (input ?? '').trim();
  if (text === '') return { ok: false, error: 'Enter a path' };
  const path = expandPath(text, cwd, home);
  if (!existsSync(path)) return { ok: false, error: `${path} does not exist` };
  if (!statSync(path).isDirectory()) return { ok: false, error: `${path} is not a folder` };
  if (!isGitRepo(path)) return { ok: false, error: `${path} is not a git repository` };
  return { ok: true, path };
}

/** An existing .yaml/.yml/.json file that parses and has a top-level `openapi` key, as an absolute path. */
export function checkContractPath(input: string | undefined, cwd: string, home: string): PathCheck {
  const text = (input ?? '').trim();
  if (text === '') return { ok: false, error: 'Enter a path' };
  const path = expandPath(text, cwd, home);
  if (!existsSync(path)) return { ok: false, error: `${path} does not exist` };
  if (!statSync(path).isFile()) return { ok: false, error: `${path} is not a file` };
  if (!CONTRACT_EXTENSIONS.has(extname(path).toLowerCase())) {
    return { ok: false, error: `${path} is not a .yaml, .yml or .json file` };
  }
  let parsed: unknown;
  try {
    // JSON is YAML, so one parser reads both.
    parsed = parseYaml(readFileSync(path, 'utf-8'));
  } catch (err) {
    return { ok: false, error: `${path} does not parse: ${(err as Error).message.split('\n')[0]}` };
  }
  if (
    parsed === null ||
    typeof parsed !== 'object' ||
    Array.isArray(parsed) ||
    !Object.hasOwn(parsed, 'openapi')
  ) {
    return { ok: false, error: `${path} has no top-level openapi key` };
  }
  return { ok: true, path };
}

// ---------------------------------------------------------------------------
// Saved answers
// ---------------------------------------------------------------------------

export interface SetupDefaults {
  backend?: string;
  /** "" when the last run skipped the frontend. */
  frontend?: string;
  contract?: string;
  profiles?: string[];
}

export function setupDefaultsPath(archonHome: string): string {
  return join(archonHome, 'kit-setup.json');
}

export function readSetupDefaults(archonHome: string): SetupDefaults {
  try {
    const parsed: unknown = JSON.parse(readFileSync(setupDefaultsPath(archonHome), 'utf-8'));
    if (parsed === null || typeof parsed !== 'object') return {};
    const data = parsed as Record<string, unknown>;
    const text = (value: unknown): string | undefined =>
      typeof value === 'string' ? value : undefined;
    return {
      backend: text(data.backend),
      frontend: text(data.frontend),
      contract: text(data.contract),
      profiles: Array.isArray(data.profiles)
        ? data.profiles.filter((p): p is string => typeof p === 'string')
        : undefined,
    };
  } catch {
    return {};
  }
}

/** Only the three paths and the profiles: the file never holds anything else. */
export function saveSetupDefaults(archonHome: string, answers: Required<SetupDefaults>): void {
  mkdirSync(archonHome, { recursive: true });
  const { backend, frontend, contract, profiles } = answers;
  writeFileSync(
    setupDefaultsPath(archonHome),
    `${JSON.stringify({ backend, frontend, contract, profiles }, null, 2)}\n`
  );
}

// ---------------------------------------------------------------------------
// Config edits
// ---------------------------------------------------------------------------

/** The backend's kit.yaml text; a missing one starts from the kit defaults with the profiles, as kit add does. */
export function kitYamlText(backend: string, kit: Kit, profiles: string[]): string {
  const path = join(backend, KIT_YAML);
  if (existsSync(path)) return readFileSync(path, 'utf-8');
  return applySetOverrides(kit.defaults, [
    `profiles=${JSON.stringify(resolveProfiles(kit, profiles))}`,
  ]);
}

function writeKitYaml(backend: string, text: string): void {
  mkdirSync(join(backend, '.archon'), { recursive: true });
  writeFileSync(join(backend, KIT_YAML), text);
}

/** Add `project` to `codegraph.extra_projects` (a YAML list), deduped, keeping the file's comments. */
export function addExtraProject(yamlText: string, project: string): string {
  const doc = parseDocument(yamlText);
  if (doc.errors.length > 0) throw doc.errors[0];
  const current: unknown = doc.getIn(['codegraph', 'extra_projects']);
  const plain: unknown =
    current !== null && typeof current === 'object' && 'toJSON' in current
      ? (current as { toJSON(): unknown }).toJSON()
      : current;
  const list = Array.isArray(plain)
    ? plain.map(item => String(item))
    : typeof plain === 'string' && plain !== ''
      ? [plain]
      : [];
  if (list.includes(project) && Array.isArray(plain)) return yamlText;
  doc.setIn(['codegraph', 'extra_projects'], [...new Set([...list, project])]);
  return doc.toString();
}

function readJson(text: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(text.replace(/^\s*\/\/.*$/gm, ''));
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('not a JSON object');
  }
  return parsed as Record<string, unknown>;
}

/** The codegraph server entry of the backend's .github/mcp.json (what kit add wrote), else the kit's own. */
export function codegraphServerEntry(backend: string, kit: Kit): Record<string, unknown> {
  const sources: [string, () => string | undefined][] = [
    [
      join(backend, MCP_JSON),
      () =>
        existsSync(join(backend, MCP_JSON))
          ? readFileSync(join(backend, MCP_JSON), 'utf-8')
          : undefined,
    ],
    ['the kit core/.github/mcp.json', () => kit.files['core/.github/mcp.json']],
  ];
  for (const [, read] of sources) {
    const text = read();
    if (text === undefined) continue;
    try {
      const data = readJson(text);
      const servers = (data.mcpServers ?? data.servers) as Record<string, unknown> | undefined;
      const entry = servers?.codegraph;
      if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) {
        return entry as Record<string, unknown>;
      }
    } catch {
      // try the next source
    }
  }
  throw new Error(`no codegraph server in ${sources.map(([name]) => name).join(' or ')}`);
}

/** Put `entry` under `name` in an mcp.json text (null: no file yet), keeping every other server and key. */
export function mergeMcpServer(
  existing: string | null,
  name: string,
  entry: Record<string, unknown>
): string {
  const data = existing === null || existing.trim() === '' ? {} : readJson(existing);
  const key =
    data.mcpServers === undefined && data.servers !== undefined ? 'servers' : 'mcpServers';
  const current = data[key];
  const servers =
    current !== null && typeof current === 'object' && !Array.isArray(current)
      ? (current as Record<string, unknown>)
      : {};
  data[key] = { ...servers, [name]: entry };
  return `${JSON.stringify(data, null, 2)}\n`;
}

// ---------------------------------------------------------------------------
// The options and the seams (the terminal and the runner are in kit-setup-ui)
// ---------------------------------------------------------------------------

export interface KitSetupOptions {
  backend?: string;
  frontend?: string;
  contract?: string;
  profiles?: string[];
  yes?: boolean;
  noRtk?: boolean;
  noWeb?: boolean;
  noTools?: boolean;
}

export interface KitSetupDeps {
  cwd: string;
  env: NodeJS.ProcessEnv;
  /** Both stdin and stdout are terminals: the dialog may ask. */
  interactive: boolean;
  ui: SetupUi;
  run: Runner;
  loadKit: () => Promise<Kit>;
  /** The tool installer (kit tools) for the backend. */
  tools: (backend: string, kit: Kit, output: OutputSink) => Promise<number>;
  kitAdd: typeof kitAddCommand;
  checkMcp: (dir: string) => Promise<DoctorCheck[]>;
  which: (command: string) => boolean;
  now: () => Date;
  /** Usage and argument errors (stderr). */
  stderr: (text: string) => void;
}

export function defaultSetupDeps(cwd: string, env: NodeJS.ProcessEnv = process.env): KitSetupDeps {
  const interactive = process.stdin.isTTY === true && process.stdout.isTTY === true;
  return {
    cwd,
    env,
    interactive,
    ui: interactive ? clackUi : plainUi(),
    run: spawnRunner,
    loadKit: async () => (await import('../bundled-kit')).BUNDLED_KIT,
    tools: (backend, kit, output) => kitToolsCommand(backend, { kit, output }),
    kitAdd: kitAddCommand,
    checkMcp: dir => checkMcpServers(dir),
    which: command => onPath(command, env),
    now: () => new Date(),
    stderr: text => console.error(text),
  };
}

function stamp(date: Date): string {
  const pad = (n: number): string => String(n).padStart(2, '0');
  return (
    `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-` +
    `${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
  );
}

/** Send console output to `output` while `fn` runs: kit add reports through console. */
async function withConsoleTo<T>(output: OutputSink, fn: () => Promise<T>): Promise<T> {
  const saved = {
    log: console.log,
    info: console.info,
    warn: console.warn,
    error: console.error,
  };
  const write = (...args: unknown[]): void => output(`${format(...args)}\n`);
  console.log = write;
  console.info = write;
  console.warn = write;
  console.error = write;
  try {
    return await fn();
  } finally {
    Object.assign(console, saved);
  }
}

// ---------------------------------------------------------------------------
// The command
// ---------------------------------------------------------------------------

interface Answers {
  backend: string;
  frontend: string | null;
  contract: string;
}

/** The dialog: each answer is checked as it is typed; a cancel resolves null. */
async function askAnswers(
  options: KitSetupOptions,
  saved: SetupDefaults,
  deps: KitSetupDeps,
  home: string
): Promise<Answers | null> {
  const { ui, cwd } = deps;
  const errorOf = (check: PathCheck): string | undefined => (check.ok ? undefined : check.error);
  const backend = await ui.text({
    message: 'Backend repository (a git checkout; the kit goes here)',
    placeholder: '~/code/backend',
    initialValue: options.backend ?? saved.backend,
    validate: value => errorOf(checkRepoPath(value, cwd, home)),
  });
  if (ui.isCancel(backend)) return null;
  const backendPath = expandPath(String(backend), cwd, home);
  const frontend = await ui.text({
    message: 'Frontend repository (empty to skip)',
    placeholder: '~/code/frontend',
    initialValue: options.frontend ?? saved.frontend ?? '',
    validate: value => {
      if ((value ?? '').trim() === '') return undefined;
      const check = checkRepoPath(value, cwd, home);
      if (check.ok && check.path === backendPath)
        return 'The frontend is the backend; give another repository';
      return errorOf(check);
    },
  });
  if (ui.isCancel(frontend)) return null;
  const contract = await ui.text({
    message: 'API contract file (OpenAPI .yaml, .yml or .json)',
    placeholder: '~/code/contract/openapi.yaml',
    initialValue: options.contract ?? saved.contract,
    validate: value => errorOf(checkContractPath(value, cwd, home)),
  });
  if (ui.isCancel(contract)) return null;
  const frontendText = String(frontend ?? '').trim();
  return {
    backend: backendPath,
    frontend: frontendText === '' ? null : expandPath(frontendText, cwd, home),
    contract: expandPath(String(contract), cwd, home),
  };
}

/** The flags as answers, or the first problem with them. */
function flagAnswers(options: KitSetupOptions, cwd: string, home: string): Answers | string {
  const backend = checkRepoPath(options.backend, cwd, home);
  if (!backend.ok) return `--backend: ${backend.error}`;
  let frontend: string | null = null;
  if ((options.frontend ?? '').trim() !== '') {
    const check = checkRepoPath(options.frontend, cwd, home);
    if (!check.ok) return `--frontend: ${check.error}`;
    if (check.path === backend.path) return '--frontend: the frontend is the backend';
    frontend = check.path;
  }
  const contract = checkContractPath(options.contract, cwd, home);
  if (!contract.ok) return `--contract: ${contract.error}`;
  return { backend: backend.path, frontend, contract: contract.path };
}

function pickProfiles(options: KitSetupOptions, saved: SetupDefaults): string[] {
  if (options.profiles && options.profiles.length > 0) return options.profiles;
  if (saved.profiles && saved.profiles.length > 0) return saved.profiles;
  return DEFAULT_SETUP_PROFILES;
}

interface Prepared {
  answers: Answers;
  profiles: string[];
  kit: Kit;
  archonHome: string;
}

/** The kit, the profiles and the answers (from the flags or the dialog), or the exit code to end with. */
async function prepare(options: KitSetupOptions, deps: KitSetupDeps): Promise<Prepared | number> {
  const { ui, env } = deps;
  const home = env.HOME ?? homedir();
  const archonHome = getArchonHome(env);
  const saved = readSetupDefaults(archonHome);
  const fromFlags = Boolean(options.backend?.trim()) && Boolean(options.contract?.trim());
  if (!deps.interactive && !fromFlags) {
    deps.stderr(
      `archon kit setup needs a terminal, or --backend and --contract.\n\n${KIT_SETUP_USAGE}`
    );
    return 2;
  }
  let kit: Kit;
  try {
    kit = await deps.loadKit();
  } catch (err) {
    deps.stderr(`Error: could not load the kit: ${(err as Error).message}`);
    return 1;
  }
  const profiles = pickProfiles(options, saved);
  try {
    resolveProfiles(kit, profiles);
  } catch (err) {
    deps.stderr(`Error: ${(err as Error).message}`);
    return 2;
  }
  if (deps.interactive) ui.intro('archon kit setup');
  if (fromFlags) {
    const result = flagAnswers(options, deps.cwd, home);
    if (typeof result === 'string') {
      deps.stderr(`Error: ${result}\n\n${KIT_SETUP_USAGE}`);
      return 2;
    }
    return { answers: result, profiles, kit, archonHome };
  }
  const asked = await askAnswers(options, saved, deps, home);
  if (asked === null) {
    ui.cancel('Setup cancelled. Nothing changed.');
    return 0;
  }
  return { answers: asked, profiles, kit, archonHome };
}

function summary(options: KitSetupOptions, answers: Answers, profiles: string[]): string {
  const skipped = (flag: boolean | undefined, why: string): string =>
    flag === true ? ` (skipped: ${why})` : '';
  const steps = [
    `tools${skipped(options.noTools, '--no-tools')}`,
    'kit',
    'contract',
    'codegraph',
    `frontend MCP${skipped(answers.frontend === null, 'no frontend')}`,
    `rtk hooks${skipped(options.noRtk, '--no-rtk')}`,
    'servers check',
    `web views${skipped(options.noWeb, '--no-web')}`,
  ];
  return [
    `Backend:   ${answers.backend}`,
    `Frontend:  ${answers.frontend ?? '(skipped)'}`,
    `Contract:  ${answers.contract}`,
    `Profiles:  ${profiles.join(', ')}`,
    '',
    `Steps: ${steps.join(', ')}`,
  ].join('\n');
}

/** Show the summary; in a terminal, ask (unless --yes). False: cancelled. */
async function confirmed(
  options: KitSetupOptions,
  deps: KitSetupDeps,
  prepared: Prepared
): Promise<boolean> {
  const { ui } = deps;
  ui.note(summary(options, prepared.answers, prepared.profiles), 'Setup');
  if (!deps.interactive || options.yes === true) return true;
  const go = await ui.confirm({ message: 'Install and wire everything?' });
  return !ui.isCancel(go) && go === true;
}

/** What the steps share while they run. */
interface SetupRun extends Answers {
  options: KitSetupOptions;
  deps: KitSetupDeps;
  kit: Kit;
  profiles: string[];
  /** [name, path] of the backend and, when given, the frontend. */
  repos: [string, string][];
  logPath: string;
  log: OutputSink;
  failed: string[];
}

function startRun(options: KitSetupOptions, deps: KitSetupDeps, prepared: Prepared): SetupRun {
  const { answers, kit, profiles, archonHome } = prepared;
  const logDir = join(archonHome, 'logs');
  mkdirSync(logDir, { recursive: true });
  const logPath = join(logDir, `kit-setup-${stamp(deps.now())}.log`);
  const log: OutputSink = text => appendFileSync(logPath, text);
  log(
    `archon kit setup\nbackend ${answers.backend}\nfrontend ${answers.frontend ?? '-'}\ncontract ${answers.contract}\n`
  );
  const repos: [string, string][] = [['backend', answers.backend]];
  if (answers.frontend !== null) repos.push(['frontend', answers.frontend]);
  return { ...answers, options, deps, kit, profiles, repos, logPath, log, failed: [] };
}

/** One step under a spinner: its body returns the detail line, a throw marks it failed. */
async function step(run: SetupRun, title: string, body: () => Promise<string>): Promise<void> {
  run.log(`\n=== ${title} ===\n`);
  const spin = run.deps.ui.spinner();
  spin.start(title);
  try {
    const detail = await body();
    run.log(`=== ${title}: ok (${detail})\n`);
    spin.stop(`${title}: ${detail}`);
  } catch (err) {
    const message = (err as Error).message;
    run.log(`=== ${title}: FAILED: ${message}\n`);
    spin.error(`${title}: failed (${message}); see ${run.logPath}`);
    run.failed.push(title);
  }
}

function skip(run: SetupRun, title: string, reason: string): void {
  run.log(`\n=== ${title}: skipped (${reason})\n`);
  run.deps.ui.info(`${title}: skipped (${reason})`);
}

/** Run a program in `cwd` into the log (and `also`); a nonzero exit throws. */
async function runIn(
  run: SetupRun,
  cwd: string,
  command: string,
  args: string[],
  also?: OutputSink
): Promise<void> {
  run.log(`$ ${[command, ...args].join(' ')}   (in ${cwd})\n`);
  const output: OutputSink = text => {
    run.log(text);
    also?.(text);
  };
  const code = await run.deps.run(command, args, { cwd, env: run.deps.env, output });
  if (code !== 0) throw new Error(`${command} ${args.join(' ')} exited with ${code}`);
}

/** The body for each repository; every one is tried, and the failures are thrown together. */
async function eachRepo(run: SetupRun, body: (dir: string) => Promise<void>): Promise<string> {
  const problems: string[] = [];
  for (const [name, dir] of run.repos) {
    try {
      await body(dir);
    } catch (err) {
      problems.push(`${name}: ${(err as Error).message}`);
    }
  }
  if (problems.length > 0) throw new Error(problems.join('; '));
  return run.repos.map(([name]) => name).join(' and ');
}

async function toolsStep(run: SetupRun): Promise<void> {
  if (run.options.noTools) return skip(run, 'Tools', '--no-tools');
  await step(run, 'Tools', async () => {
    const code = await run.deps.tools(run.backend, run.kit, run.log);
    if (code !== 0) throw new Error(`the tool installer exited with ${code}`);
    return 'installed';
  });
}

/** The kit into the backend; the contract path goes in with it, so its post-install steps see it. */
async function kitStep(run: SetupRun): Promise<void> {
  await step(run, 'Kit', async () => {
    const options = {
      profiles: run.profiles,
      trust: true,
      noTools: true,
      env: run.deps.env,
      output: run.log,
      set: [`contract.spec_path=${run.contract}`],
    };
    const code = await withConsoleTo(run.log, () => run.deps.kitAdd(run.backend, options, run.kit));
    if (code !== 0) throw new Error(`kit add exited with ${code}`);
    return `profiles ${run.profiles.join(', ')}`;
  });
}

async function contractStep(run: SetupRun): Promise<void> {
  await step(run, 'Contract', async () => {
    const { backend, contract, kit, profiles } = run;
    writeKitYaml(
      backend,
      applySetOverrides(kitYamlText(backend, kit, profiles), [`contract.spec_path=${contract}`])
    );
    const script = CONTRACT_SETUP_SCRIPTS.find(path => existsSync(join(backend, path)));
    if (script === undefined) {
      if (!resolveProfiles(kit, profiles).includes('openapi-contract')) {
        return `contract.spec_path ${contract} (no contract MCP server without openapi-contract)`;
      }
      throw new Error(
        `contract.spec_path set, but the backend has no ${CONTRACT_SETUP_SCRIPTS[0]}`
      );
    }
    await runIn(run, backend, 'bash', [script]);
    return `contract.spec_path ${contract}`;
  });
}

async function codegraphStep(run: SetupRun): Promise<void> {
  await step(run, 'CodeGraph index', async () => {
    if (!existsSync(join(run.backend, CODEGRAPH_SETUP))) {
      throw new Error(`the backend has no ${CODEGRAPH_SETUP}`);
    }
    const done = await eachRepo(run, dir =>
      runIn(run, run.backend, 'bash', [CODEGRAPH_SETUP, dir])
    );
    return `${done} indexed`;
  });
}

/** The frontend's codegraph MCP server, its folder trust and the backend's extra project. */
async function frontendStep(run: SetupRun): Promise<void> {
  const { frontend } = run;
  if (frontend === null) return skip(run, 'Frontend MCP', 'no frontend');
  await step(run, 'Frontend MCP', async () => {
    const { backend, kit, profiles, log, deps } = run;
    const file = join(frontend, MCP_JSON);
    const existing = existsSync(file) ? readFileSync(file, 'utf-8') : null;
    const merged = mergeMcpServer(existing, 'codegraph', codegraphServerEntry(backend, kit));
    mkdirSync(join(frontend, '.github'), { recursive: true });
    writeFileSync(file, merged);
    log(`wrote ${file}\n`);
    const config = join(copilotHome(deps.env), 'config.json');
    log(`trust ${frontend} in ${config}: ${trustFolder(config, frontend)}\n`);
    writeKitYaml(backend, addExtraProject(kitYamlText(backend, kit, profiles), frontend));
    log(`codegraph.extra_projects += ${frontend}\n`);
    return '.github/mcp.json codegraph, trusted, codegraph.extra_projects';
  });
}

/** rtk's Copilot hooks, per repository (never the global ones). */
async function rtkStep(run: SetupRun): Promise<void> {
  if (run.options.noRtk) return skip(run, 'rtk hooks', '--no-rtk');
  if (!run.deps.which('rtk')) return skip(run, 'rtk hooks', 'rtk is not on PATH');
  await step(run, 'rtk hooks', () =>
    eachRepo(run, dir => runIn(run, dir, 'rtk', ['init', '--copilot']))
  );
}

/** Every MCP server of each repository starts and lists its tools. */
async function serversStep(run: SetupRun): Promise<void> {
  await step(run, 'Servers check', async () => {
    const lines: string[] = [];
    const problems: string[] = [];
    for (const [name, dir] of run.repos) {
      for (const check of await run.deps.checkMcp(dir)) {
        run.log(`${name} ${check.status} ${check.name}: ${check.detail}\n`);
        const line = `${name} ${check.name.replace(/^mcp /, '')} ${check.detail}`;
        (check.status === 'fail' ? problems : lines).push(line);
      }
    }
    if (problems.length > 0) throw new Error(problems.join('; '));
    return lines.join(', ') || 'no servers';
  });
}

/** Start the web views; resolves the lines of their output that name a URL. */
async function webStep(run: SetupRun): Promise<string[]> {
  const urls: string[] = [];
  if (run.options.noWeb) {
    skip(run, 'Web views', '--no-web');
    return urls;
  }
  await step(run, 'Web views', async () => {
    if (!existsSync(join(run.backend, WEB_UIS))) throw new Error(`the backend has no ${WEB_UIS}`);
    let pending = '';
    const collect: OutputSink = text => {
      const lines = (pending + text).split('\n');
      pending = lines.pop() ?? '';
      urls.push(...lines.filter(line => line.includes('http://')).map(line => line.trim()));
    };
    try {
      await runIn(run, run.backend, 'bash', [WEB_UIS, 'start', '--open'], collect);
    } finally {
      if (pending.includes('http://')) urls.push(pending.trim());
    }
    return `${urls.length} started`;
  });
  return urls;
}

/** The closing screen; resolves the exit code. */
function finish(run: SetupRun, urls: string[]): number {
  const { ui } = run.deps;
  const web = run.options.noWeb
    ? []
    : urls.length > 0
      ? [
          'Web views:',
          ...urls.map(url => `  ${url}`),
          `Stop them: cd ${run.backend} && bash ${WEB_UIS} stop`,
        ]
      : ['Web views: none started'];
  const next = [
    ...web,
    `Log: ${run.logPath}`,
    '',
    'Copilot login: run `copilot`, then `/login`, and finish it in a browser signed in as the GitHub',
    'account that has Copilot (it may differ from your gh account).',
  ];
  ui.note(next.join('\n'), 'Next');
  if (run.failed.length > 0) {
    ui.outro(`${run.failed.length} step(s) failed: ${run.failed.join(', ')}. Log: ${run.logPath}`);
    return 1;
  }
  ui.outro('Setup done.');
  return 0;
}

export async function kitSetupCommand(
  options: KitSetupOptions,
  deps: KitSetupDeps
): Promise<number> {
  const prepared = await prepare(options, deps);
  if (typeof prepared === 'number') return prepared;
  if (!(await confirmed(options, deps, prepared))) {
    deps.ui.cancel('Setup cancelled. Nothing changed.');
    return 0;
  }
  const { answers, profiles, archonHome } = prepared;
  saveSetupDefaults(archonHome, { ...answers, frontend: answers.frontend ?? '', profiles });

  const run = startRun(options, deps, prepared);
  await toolsStep(run);
  await kitStep(run);
  await contractStep(run);
  await codegraphStep(run);
  await frontendStep(run);
  await rtkStep(run);
  await serversStep(run);
  const urls = await webStep(run);
  return finish(run, urls);
}
