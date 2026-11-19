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
import { spawn } from 'child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'fs';
import { homedir } from 'os';
import { extname, join, resolve } from 'path';
import { format } from 'util';
import * as clack from '@clack/prompts';
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
// The terminal, the runner and the other seams
// ---------------------------------------------------------------------------

export interface SetupSpinner {
  start(message: string): void;
  stop(message: string): void;
  error(message: string): void;
}

export interface SetupUi {
  intro(title: string): void;
  outro(message: string): void;
  note(message: string, title: string): void;
  info(message: string): void;
  warn(message: string): void;
  text(options: {
    message: string;
    placeholder?: string;
    initialValue?: string;
    validate: (value: string | undefined) => string | undefined;
  }): Promise<string | symbol | undefined>;
  confirm(options: { message: string }): Promise<boolean | symbol>;
  isCancel(value: unknown): value is symbol;
  cancel(message: string): void;
  spinner(): SetupSpinner;
}

export const clackUi: SetupUi = {
  intro: title => clack.intro(title),
  outro: message => clack.outro(message),
  note: (message, title) => clack.note(message, title),
  info: message => clack.log.info(message),
  warn: message => clack.log.warn(message),
  text: options => clack.text(options),
  confirm: options => clack.confirm(options),
  isCancel: (value): value is symbol => clack.isCancel(value),
  cancel: message => clack.cancel(message),
  spinner: () => clack.spinner(),
};

/** Plain lines for a run without a terminal: no animation, no prompts. */
export function plainUi(write: (line: string) => void = line => console.log(line)): SetupUi {
  const noPrompt = (): never => {
    throw new Error('kit setup cannot ask without a terminal');
  };
  return {
    intro: title => write(title),
    outro: message => write(message),
    note: (message, title) => write(`${title}\n${message}`),
    info: message => write(message),
    warn: message => write(`Warning: ${message}`),
    text: noPrompt,
    confirm: noPrompt,
    isCancel: (value): value is symbol => typeof value === 'symbol',
    cancel: message => write(message),
    spinner: () => ({
      start: () => undefined,
      stop: message => write(`ok  ${message}`),
      error: message => write(`FAIL ${message}`),
    }),
  };
}

/** Runs one program (no shell); its output goes to `output`, its stdin is closed. Resolves its exit code. */
export type Runner = (
  command: string,
  args: string[],
  options: { cwd: string; env: NodeJS.ProcessEnv; output: OutputSink }
) => Promise<number>;

export const spawnRunner: Runner = (command, args, { cwd, env, output }) =>
  new Promise(done => {
    let finished = false;
    const finish = (code: number): void => {
      if (finished) return;
      finished = true;
      done(code);
    };
    const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', chunk => output(String(chunk)));
    child.stderr.on('data', chunk => output(String(chunk)));
    child.on('error', err => {
      output(`${err.message}\n`);
      finish(127);
    });
    child.on('close', code => finish(code ?? 1));
    // A background process the command started may hold its pipes open: its exit ends the step a moment later.
    child.on('exit', code => {
      setTimeout(() => {
        child.stdout.destroy();
        child.stderr.destroy();
        finish(code ?? 1);
      }, 1000).unref();
    });
  });

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
    tools: (backend, kit, output) => kitToolsCommand(backend, false, kit, output),
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

export async function kitSetupCommand(
  options: KitSetupOptions,
  deps: KitSetupDeps
): Promise<number> {
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
  const profiles =
    options.profiles && options.profiles.length > 0
      ? options.profiles
      : saved.profiles && saved.profiles.length > 0
        ? saved.profiles
        : DEFAULT_SETUP_PROFILES;
  try {
    resolveProfiles(kit, profiles);
  } catch (err) {
    deps.stderr(`Error: ${(err as Error).message}`);
    return 2;
  }

  if (deps.interactive) ui.intro('archon kit setup');
  let answers: Answers;
  if (fromFlags) {
    const result = flagAnswers(options, deps.cwd, home);
    if (typeof result === 'string') {
      deps.stderr(`Error: ${result}\n\n${KIT_SETUP_USAGE}`);
      return 2;
    }
    answers = result;
  } else {
    const asked = await askAnswers(options, saved, deps, home);
    if (asked === null) {
      ui.cancel('Setup cancelled. Nothing changed.');
      return 0;
    }
    answers = asked;
  }
  const { backend, frontend, contract } = answers;

  const skipped = (flag: boolean, name: string): string => (flag ? ` (skipped: ${name})` : '');
  ui.note(
    [
      `Backend:   ${backend}`,
      `Frontend:  ${frontend ?? '(skipped)'}`,
      `Contract:  ${contract}`,
      `Profiles:  ${profiles.join(', ')}`,
      '',
      `Steps: tools${skipped(options.noTools === true, '--no-tools')}, kit, contract, codegraph,` +
        ` frontend MCP${frontend === null ? ' (skipped: no frontend)' : ''}, rtk hooks${skipped(options.noRtk === true, '--no-rtk')},` +
        ` servers check, web views${skipped(options.noWeb === true, '--no-web')}`,
    ].join('\n'),
    'Setup'
  );
  if (deps.interactive && options.yes !== true) {
    const go = await ui.confirm({ message: 'Install and wire everything?' });
    if (ui.isCancel(go) || go !== true) {
      ui.cancel('Setup cancelled. Nothing changed.');
      return 0;
    }
  }
  saveSetupDefaults(archonHome, { backend, frontend: frontend ?? '', contract, profiles });

  const logDir = join(archonHome, 'logs');
  mkdirSync(logDir, { recursive: true });
  const logPath = join(logDir, `kit-setup-${stamp(deps.now())}.log`);
  const log: OutputSink = text => appendFileSync(logPath, text);
  log(`archon kit setup\nbackend ${backend}\nfrontend ${frontend ?? '-'}\ncontract ${contract}\n`);

  const failed: string[] = [];
  const step = async (title: string, body: () => Promise<string>): Promise<boolean> => {
    log(`\n=== ${title} ===\n`);
    const spin = ui.spinner();
    spin.start(title);
    try {
      const detail = await body();
      log(`=== ${title}: ok (${detail})\n`);
      spin.stop(`${title}: ${detail}`);
      return true;
    } catch (err) {
      const message = (err as Error).message;
      log(`=== ${title}: FAILED: ${message}\n`);
      spin.error(`${title}: failed (${message}); see ${logPath}`);
      failed.push(title);
      return false;
    }
  };
  const skip = (title: string, reason: string): void => {
    log(`\n=== ${title}: skipped (${reason})\n`);
    ui.info(`${title}: skipped (${reason})`);
  };
  /** Run in `cwd`; a nonzero exit throws. `also` sees the output too. */
  const run = async (
    cwd: string,
    command: string,
    args: string[],
    also?: OutputSink
  ): Promise<void> => {
    log(`$ ${[command, ...args].join(' ')}   (in ${cwd})\n`);
    const code = await deps.run(command, args, {
      cwd,
      env,
      output: text => {
        log(text);
        also?.(text);
      },
    });
    if (code !== 0) throw new Error(`${command} ${args.join(' ')} exited with ${code}`);
  };
  const repos: [string, string][] = [['backend', backend]];
  if (frontend !== null) repos.push(['frontend', frontend]);
  /** Run the body for each repo; every repo is tried, the failures are thrown together. */
  const eachRepo = async (body: (dir: string) => Promise<void>): Promise<string> => {
    const problems: string[] = [];
    for (const [name, dir] of repos) {
      try {
        await body(dir);
      } catch (err) {
        problems.push(`${name}: ${(err as Error).message}`);
      }
    }
    if (problems.length > 0) throw new Error(problems.join('; '));
    return repos.map(([name]) => name).join(' and ');
  };

  // 1. Tools.
  if (options.noTools) skip('Tools', '--no-tools');
  else {
    await step('Tools', async () => {
      const code = await deps.tools(backend, kit, log);
      if (code !== 0) throw new Error(`the tool installer exited with ${code}`);
      return 'installed';
    });
  }

  // 2. The kit into the backend (the contract path goes in with it, so its post-install steps see it).
  await step('Kit', async () => {
    const code = await withConsoleTo(log, () =>
      deps.kitAdd(
        backend,
        {
          profiles,
          trust: true,
          noTools: true,
          env,
          output: log,
          set: [`contract.spec_path=${contract}`],
        },
        kit
      )
    );
    if (code !== 0) throw new Error(`kit add exited with ${code}`);
    return `profiles ${profiles.join(', ')}`;
  });

  // 3. Contract.
  await step('Contract', async () => {
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
    await run(backend, 'bash', [script]);
    return `contract.spec_path ${contract}`;
  });

  // 4. CodeGraph indexes.
  await step('CodeGraph index', async () => {
    if (!existsSync(join(backend, CODEGRAPH_SETUP)))
      throw new Error(`the backend has no ${CODEGRAPH_SETUP}`);
    return `${await eachRepo(dir => run(backend, 'bash', [CODEGRAPH_SETUP, dir]))} indexed`;
  });

  // 5. The frontend's MCP server, trust and the backend's extra project.
  if (frontend === null) skip('Frontend MCP', 'no frontend');
  else {
    await step('Frontend MCP', async () => {
      const entry = codegraphServerEntry(backend, kit);
      const file = join(frontend, MCP_JSON);
      const merged = mergeMcpServer(
        existsSync(file) ? readFileSync(file, 'utf-8') : null,
        'codegraph',
        entry
      );
      mkdirSync(join(frontend, '.github'), { recursive: true });
      writeFileSync(file, merged);
      log(`wrote ${file}\n`);
      const config = join(copilotHome(env), 'config.json');
      log(`trust ${frontend} in ${config}: ${trustFolder(config, frontend)}\n`);
      writeKitYaml(backend, addExtraProject(kitYamlText(backend, kit, profiles), frontend));
      log(`codegraph.extra_projects += ${frontend}\n`);
      return '.github/mcp.json codegraph, trusted, codegraph.extra_projects';
    });
  }

  // 6. rtk hooks, per repository (never the global ones).
  if (options.noRtk) skip('rtk hooks', '--no-rtk');
  else if (!deps.which('rtk')) skip('rtk hooks', 'rtk is not on PATH');
  else {
    await step('rtk hooks', async () => {
      return `${await eachRepo(dir => run(dir, 'rtk', ['init', '--copilot']))}`;
    });
  }

  // 7. Every MCP server starts and lists its tools.
  await step('Servers check', async () => {
    const lines: string[] = [];
    const problems: string[] = [];
    for (const [name, dir] of repos) {
      const checks = await deps.checkMcp(dir);
      for (const check of checks) {
        log(`${name} ${check.status} ${check.name}: ${check.detail}\n`);
        if (check.status === 'fail') problems.push(`${name} ${check.name}: ${check.detail}`);
        else lines.push(`${name} ${check.name.replace(/^mcp /, '')} ${check.detail}`);
      }
    }
    if (problems.length > 0) throw new Error(problems.join('; '));
    return lines.join(', ') || 'no servers';
  });

  // 8. The web views.
  const urls: string[] = [];
  if (options.noWeb) skip('Web views', '--no-web');
  else {
    await step('Web views', async () => {
      if (!existsSync(join(backend, WEB_UIS))) throw new Error(`the backend has no ${WEB_UIS}`);
      let pending = '';
      const collect: OutputSink = text => {
        pending += text;
        const lines = pending.split('\n');
        pending = lines.pop() ?? '';
        for (const line of lines) if (line.includes('http://')) urls.push(line.trim());
      };
      try {
        await run(backend, 'bash', [WEB_UIS, 'start', '--open'], collect);
      } finally {
        if (pending.includes('http://')) urls.push(pending.trim());
      }
      return `${urls.length} started`;
    });
  }

  // 9. What next.
  const next = [
    ...(options.noWeb
      ? []
      : urls.length > 0
        ? [
            'Web views:',
            ...urls.map(url => `  ${url}`),
            `Stop them: cd ${backend} && bash ${WEB_UIS} stop`,
          ]
        : ['Web views: none started']),
    `Log: ${logPath}`,
    '',
    'Copilot login: run `copilot`, then `/login`, and finish it in a browser signed in as the GitHub',
    'account that has Copilot (it may differ from your gh account).',
  ];
  ui.note(next.join('\n'), 'Next');
  if (failed.length > 0) {
    ui.outro(`${failed.length} step(s) failed: ${failed.join(', ')}. Log: ${logPath}`);
    return 1;
  }
  ui.outro('Setup done.');
  return 0;
}
