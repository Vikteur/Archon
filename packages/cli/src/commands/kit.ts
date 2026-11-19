/**
 * Kit command - install the bundled Copilot kit into a project and check it.
 *
 * `archon kit add`    writes the kit's profile files, kit.yaml and model aliases
 * `archon kit doctor` checks tools, auth, trust, MCP servers, hooks and drift
 * `archon kit list`   shows the profiles and which are installed
 * `archon kit tools`  installs the tools the kit needs
 * `archon kit setup`  the guided install of all of it (kit-setup.ts)
 *
 * The kit object is injected into every function so tests use a fixture kit.
 * The real one (`BUNDLED_KIT`) loads lazily, like the bundled skill, because it
 * is large. The layout contract is kit/SPEC.md.
 */
import { spawn, spawnSync } from 'child_process';
import { createHash } from 'crypto';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  realpathSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'fs';
import { homedir, tmpdir } from 'os';
import { delimiter, dirname, isAbsolute, join, relative as relativePath, resolve, sep } from 'path';
import { isMap, parse as parseYaml, parseDocument } from 'yaml';
import type { BUNDLED_KIT } from '../bundled-kit';

export type Kit = typeof BUNDLED_KIT;

export interface KitAddOptions {
  profiles?: string[];
  force?: boolean;
  dryRun?: boolean;
  noTools?: boolean;
  noPostInstall?: boolean;
  trust?: boolean;
  userHooks?: boolean;
  /** `key=value` strings; dot keys address nested kit.yaml keys. */
  set?: string[];
  /** Skip `archon validate workflows` (tests). */
  skipValidate?: boolean;
  /** `kit tools --check`. */
  check?: boolean;
  env?: NodeJS.ProcessEnv;
  /** Where the tools and post-install commands write their output; unset streams it to the terminal. */
  output?: OutputSink;
}

/** Receives a child command's output, stdout and stderr interleaved as they come. */
export type OutputSink = (text: string) => void;

export const KIT_YAML = join('.archon', 'kit.yaml');
/**
 * The kit defaults, beside kit.yaml: the project's scripts (kit-config.sh, kit-config.js) read a key kit.yaml
 * leaves out from here at runtime, so it ships as a lock-tracked kit file of its own.
 */
export const KIT_DEFAULTS = '.archon/kit.defaults.yaml';
/** What kit add last wrote, path → sha256: a file still holding it is the kit's own, so a newer kit updates it. */
export const KIT_LOCK = join('.archon', 'kit.lock.json');
const DISPATCH = '.github/hooks/dispatch.sh';

export function readKitLock(projectPath: string): Record<string, string> {
  try {
    const parsed = JSON.parse(readFileSync(join(projectPath, KIT_LOCK), 'utf-8')) as {
      files?: Record<string, string>;
    };
    return parsed.files ?? {};
  } catch {
    return {};
  }
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

export function copilotHome(env: NodeJS.ProcessEnv = process.env): string {
  return env.COPILOT_HOME ? resolve(env.COPILOT_HOME) : join(homedir(), '.copilot');
}

function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex');
}

/** CRLF → LF, so a Windows checkout (core.autocrlf) of an unedited file hashes and compares as the kit's own. */
function toLf(text: string): string {
  return text.replace(/\r\n/g, '\n');
}

/** sha256 of the text with CRLF line ends read as LF: what the lock records and drift compares. */
export function contentHash(text: string): string {
  return sha256(toLf(text));
}

/** Quote one word for bash: a path holding a `'` stays one word. */
export function shellQuote(word: string): string {
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

/** kit add owns these two files; a manifest entry for either is refused. */
const RESERVED_PATHS = new Set(['.archon/kit.yaml', '.archon/kit.lock.json']);

/**
 * Why a manifest path cannot be written inside the project, or null when it can: an absolute path, a
 * drive letter, a `..` segment (either separator) or one of kit add's own files is refused.
 */
export function unsafeManifestPath(path: string): string | null {
  if (path === '' || path.startsWith('/') || path.startsWith('\\') || isAbsolute(path)) {
    return 'an absolute path';
  }
  if (/^[A-Za-z]:/.test(path)) return 'a drive letter';
  const segments = path.split(/[\\/]/);
  if (segments.includes('..')) return 'a .. segment';
  if (RESERVED_PATHS.has(segments.filter(seg => seg !== '' && seg !== '.').join('/'))) {
    return "kit add's own file";
  }
  return null;
}

/** The nearest existing ancestor of `path` (itself when it exists), by lstat so a dangling link counts. */
function nearestExisting(path: string): string {
  let current = path;
  for (;;) {
    try {
      lstatSync(current);
      return current;
    } catch {
      const parent = dirname(current);
      if (parent === current) return current;
      current = parent;
    }
  }
}

/**
 * Where a write to `relative` under `project` would land: 'symlink' when the destination is a link
 * (never written through), 'outside' when its nearest existing parent resolves outside the project.
 */
export function destinationProblem(
  project: string,
  relative: string
): 'symlink' | 'outside' | null {
  const dest = join(project, relative);
  try {
    if (lstatSync(dest).isSymbolicLink()) return 'symlink';
  } catch {
    // absent: checked through its parent below
  }
  const root = realpathSync(project);
  let real: string;
  try {
    real = realpathSync(nearestExisting(dirname(dest)));
  } catch {
    return 'outside';
  }
  const rel = relativePath(root, real);
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel))
    ? null
    : 'outside';
}

/**
 * Expand the requested profiles with everything they require, reject exclusive
 * combinations and return them in the kit's install order (manifest key order).
 * Throws an Error with a user-facing message.
 */
export function resolveProfiles(kit: Kit, requested: string[]): string[] {
  const known = Object.keys(kit.manifest.profiles);
  const wanted = new Set<string>();
  const visit = (name: string, trail: string[]): void => {
    if (!Object.hasOwn(kit.manifest.profiles, name)) {
      throw new Error(`Unknown profile: ${name}. Valid profiles: ${known.join(', ')}`);
    }
    if (trail.includes(name)) throw new Error(`Profile cycle: ${[...trail, name].join(' -> ')}`);
    if (wanted.has(name)) return;
    wanted.add(name);
    for (const required of kit.manifest.profiles[name].requires) visit(required, [...trail, name]);
  };
  for (const name of requested) visit(name, []);
  for (const group of kit.manifest.exclusive) {
    const hit = group.filter(name => wanted.has(name));
    if (hit.length > 1) {
      throw new Error(`Profiles cannot be combined: ${hit.join(' and ')} are mutually exclusive`);
    }
  }
  return known.filter(name => wanted.has(name));
}

/** Flatten nested kit.yaml keys into `@@KIT_<NAME>@@` variables (upper-snake, lists joined with ", "). */
export function flattenKitConfig(config: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (value: unknown, path: string[]): void => {
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      for (const [key, child] of Object.entries(value)) walk(child, [...path, key]);
      return;
    }
    if (path.length === 0) return;
    const name = path
      .join('_')
      .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
      .replace(/[^A-Za-z0-9]+/g, '_')
      .toUpperCase();
    if (Array.isArray(value)) out[name] = value.map(item => String(item)).join(', ');
    else out[name] = value === null || value === undefined ? '' : String(value);
  };
  walk(config, []);
  return out;
}

/** Replace `@@KIT_<NAME>@@`; a missing key renders empty and is recorded once in `missing`. */
export function renderTemplate(
  content: string,
  vars: Record<string, string>,
  missing: Set<string>
): string {
  return content.replace(/@@KIT_([A-Z0-9_]+)@@/g, (_match, name: string) => {
    if (Object.hasOwn(vars, name)) return vars[name];
    missing.add(name);
    return '';
  });
}

/**
 * A `--set` value: true/false become booleans and an explicit `[a, b]` list a list; everything else stays
 * the string it is, so a version such as 20.10 or a code such as 010 is not turned into a number.
 */
export function coerceScalar(raw: string): unknown {
  const text = raw.trim();
  if (text === 'true') return true;
  if (text === 'false') return false;
  if (text.startsWith('[') && text.endsWith(']')) {
    try {
      const parsed: unknown = parseYaml(text);
      if (Array.isArray(parsed))
        return parsed.map(item => (typeof item === 'string' ? item : String(item)));
    } catch {
      // not a list after all: keep the text
    }
  }
  return raw;
}

/** The value of a `--set profiles=…` among the overrides, as a profile list; undefined when absent. */
export function profilesFromSets(sets: string[]): string[] | undefined {
  let found: string[] | undefined;
  for (const entry of sets) {
    const eq = entry.indexOf('=');
    if (eq <= 0 || entry.slice(0, eq).trim() !== 'profiles') continue;
    const value = coerceScalar(entry.slice(eq + 1));
    found = (Array.isArray(value) ? value.map(String) : String(value).split(','))
      .map(name => name.trim())
      .filter(Boolean);
  }
  return found;
}

/** Apply `key=value` overrides (dot keys) to a YAML document, keeping its comments. */
export function applySetOverrides(yamlText: string, sets: string[]): string {
  const doc = parseDocument(yamlText);
  if (doc.errors.length > 0) throw doc.errors[0];
  for (const entry of sets) {
    const eq = entry.indexOf('=');
    if (eq <= 0) throw new Error(`Invalid --set value "${entry}", expected key=value`);
    const key = entry.slice(0, eq).trim();
    doc.setIn(key.split('.'), coerceScalar(entry.slice(eq + 1)));
  }
  return doc.toString();
}

export interface AliasMergeResult {
  text: string;
  added: string[];
  conflicts: string[];
}

/** Add missing `aliases.<@name>: {provider, model}` entries, leaving the rest of the file untouched. */
export function mergeAliases(
  existing: string,
  aliases: Kit['manifest']['aliases']
): AliasMergeResult {
  const doc = parseDocument(existing, { uniqueKeys: false });
  if (doc.errors.length > 0) throw doc.errors[0];
  const added: string[] = [];
  const conflicts: string[] = [];
  for (const [name, preset] of Object.entries(aliases)) {
    const current: unknown = doc.getIn(['aliases', name]);
    if (current !== undefined && current !== null) {
      const plain = isMap(current) ? (current.toJSON() as Record<string, unknown>) : current;
      const same =
        typeof plain === 'object' &&
        plain !== null &&
        (plain as Record<string, unknown>).provider === preset.provider &&
        (plain as Record<string, unknown>).model === preset.model;
      if (!same) conflicts.push(name);
      continue;
    }
    doc.setIn(['aliases', name], { provider: preset.provider, model: preset.model });
    added.push(name);
  }
  return { text: added.length > 0 ? doc.toString() : existing, added, conflicts };
}

/** Add `projectPath` to `trustedFolders` in a Copilot config.json, preserving every other key. */
export function trustFolder(configPath: string, projectPath: string): 'added' | 'present' {
  let data: Record<string, unknown> = {};
  if (existsSync(configPath)) {
    const text = readFileSync(configPath, 'utf-8');
    // Copilot's config.json may carry // comments; strip whole-line ones before parsing.
    const parsed: unknown = text.trim() === '' ? {} : JSON.parse(text.replace(/^\s*\/\/.*$/gm, ''));
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error(`${configPath} is not a JSON object`);
    }
    data = parsed as Record<string, unknown>;
  }
  const current = Array.isArray(data.trustedFolders) ? (data.trustedFolders as unknown[]) : [];
  if (current.includes(projectPath)) return 'present';
  data.trustedFolders = [...current, projectPath];
  mkdirSync(dirname(configPath), { recursive: true });
  // Temp file and rename: a crash mid-write never leaves Copilot a truncated config.json.
  const temp = `${configPath}.archon-${process.pid}.tmp`;
  try {
    writeFileSync(temp, `${JSON.stringify(data, null, 2)}\n`);
    renameSync(temp, configPath);
  } catch (err) {
    rmSync(temp, { force: true });
    throw err;
  }
  return 'added';
}

function readJsonObject(path: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, 'utf-8').replace(/^\s*\/\/.*$/gm, ''));
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function readKitYaml(projectPath: string): Record<string, unknown> | null {
  const path = join(projectPath, KIT_YAML);
  if (!existsSync(path)) return null;
  try {
    const parsed: unknown = parseYaml(readFileSync(path, 'utf-8'));
    return parsed !== null && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : {};
  } catch {
    return null;
  }
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.map(item => String(item)) : [];
}

/** Which kit file wins for each path under the selected profiles (later profile wins). */
export function winningFiles(
  kit: Kit,
  profiles: string[]
): Map<string, Kit['manifest']['files'][number]> {
  const order = new Map(profiles.map((name, index) => [name, index]));
  const winners = new Map<string, Kit['manifest']['files'][number]>();
  for (const file of kit.manifest.files) {
    const rank = order.get(file.profile);
    if (rank === undefined) continue;
    const prior = winners.get(file.path);
    if (prior === undefined || (order.get(prior.profile) ?? -1) <= rank)
      winners.set(file.path, file);
  }
  return winners;
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

export function isGitRepo(path: string): boolean {
  const result = spawnSync('git', ['rev-parse', '--is-inside-work-tree'], {
    cwd: path,
    encoding: 'utf-8',
  });
  return result.status === 0 && result.stdout.trim() === 'true';
}

/** Run `bash -c command`: its output streams to the terminal, or to `output` when one is given (stdin then closed). */
export function streamCommand(
  command: string,
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
  output?: OutputSink
): Promise<number> {
  return new Promise(resolveExit => {
    const child = spawn('bash', ['-c', command], {
      cwd,
      env,
      stdio: output ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    });
    if (output) {
      child.stdout?.on('data', chunk => output(String(chunk)));
      child.stderr?.on('data', chunk => output(String(chunk)));
    }
    child.on('error', () => resolveExit(127));
    child.on('close', code => resolveExit(code ?? 1));
  });
}

// ---------------------------------------------------------------------------
// kit tools
// ---------------------------------------------------------------------------

const INSTALL_TOOLS = join('scripts', 'install-tools.sh');
const BUNDLED_INSTALLER = 'core/scripts/install-tools.sh';
const BUNDLED_TOOLS_CONF = 'core/scripts/tools.conf';

/** Does the project carry its own tool installer? Else `kit tools` needs the bundled kit's. */
export function hasProjectInstaller(targetPath: string): boolean {
  return existsSync(join(resolve(targetPath), INSTALL_TOOLS));
}

/**
 * Run `bash scripts/install-tools.sh [--check]` in the project, streaming output. A folder without one (no
 * kit installed yet, as when an installer runs it) runs the kit's own installer and tool list from `kit`,
 * written to a temp folder; its PROJECT_DIR is that folder, so it switches on no project's git hooks.
 */
export interface KitToolsOptions {
  /** `--check`: report the tools, install nothing. */
  check?: boolean;
  /** The kit whose installer runs when the project has none. */
  kit?: Kit;
  /** Where the installer's output goes; unset streams it to the terminal. */
  output?: OutputSink;
  /** The installer's environment (default process.env). */
  env?: NodeJS.ProcessEnv;
}

export async function kitToolsCommand(
  targetPath: string,
  { check = false, kit, output, env = process.env }: KitToolsOptions = {}
): Promise<number> {
  const project = resolve(targetPath);
  const flag = check ? ' --check' : '';
  if (existsSync(join(project, INSTALL_TOOLS))) {
    return await streamCommand(`bash ${INSTALL_TOOLS}${flag}`, project, env, output);
  }
  const installer = kit?.files[BUNDLED_INSTALLER];
  const toolsConf = kit?.files[BUNDLED_TOOLS_CONF];
  if (installer === undefined || toolsConf === undefined) {
    const message = `Error: ${join(project, INSTALL_TOOLS)} not found. Install the kit first: archon kit add ${project}`;
    if (output) output(`${message}\n`);
    else console.error(message);
    return 1;
  }
  const temp = mkdtempSync(join(tmpdir(), 'archon-kit-tools-'));
  try {
    mkdirSync(join(temp, 'scripts'));
    writeFileSync(join(temp, INSTALL_TOOLS), installer);
    writeFileSync(join(temp, 'scripts', 'tools.conf'), toolsConf);
    const notice = `No ${INSTALL_TOOLS} in ${project}; running the kit's bundled tool installer`;
    if (output) output(`${notice}\n`);
    else console.log(notice);
    return await streamCommand(
      `bash ${shellQuote(join(temp, INSTALL_TOOLS))}${flag}`,
      project,
      { ...env, PROJECT_DIR: temp },
      output
    );
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// kit add
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

type FileState = 'written' | 'unchanged' | 'kept' | 'skipped (symlink)' | 'skipped (outside)';

/**
 * What `kit add` does with a file the project may already hold: null writes it. A create-only file (manifest
 * `createOnly`, e.g. the starter docs/memory.md) the project has is the project's own, kept even with --force.
 */
export function existingFileState(
  dest: string,
  content: string,
  force: boolean,
  createOnly = false
): FileState | null {
  if (!existsSync(dest)) return null;
  if (toLf(readFileSync(dest, 'utf-8')) === toLf(content)) return 'unchanged';
  return force && !createOnly ? null : 'kept';
}

export async function kitAddCommand(
  targetPath: string,
  options: KitAddOptions,
  kit: Kit
): Promise<number> {
  const env = options.env ?? process.env;
  const project = resolve(targetPath);
  const dry = options.dryRun ?? false;

  if (!existsSync(project) || !statSync(project).isDirectory()) {
    console.error(`Error: Directory does not exist: ${project}`);
    return 1;
  }
  if (!isGitRepo(project)) {
    console.error(`Error: ${project} is not a git repository. Run git init first.`);
    return 1;
  }

  // 1. kit.yaml text (existing, or from defaults) with --set overrides applied.
  const kitYamlPath = join(project, KIT_YAML);
  const kitYamlExists = existsSync(kitYamlPath);
  const existingConfig = readKitYaml(project);
  let profiles: string[];
  // `--set profiles=…` picks this run's profiles, as --profile does; it is applied as one, not as a raw set.
  const setProfiles = profilesFromSets(options.set ?? []);
  const otherSets = (options.set ?? []).filter(
    entry => entry.slice(0, Math.max(entry.indexOf('='), 0)).trim() !== 'profiles'
  );
  const explicitProfiles =
    options.profiles && options.profiles.length > 0 ? options.profiles : setProfiles;
  try {
    if (options.profiles && options.profiles.length > 0 && setProfiles !== undefined) {
      throw new Error('Give the profiles once: --profile or --set profiles=…, not both');
    }
    if (setProfiles !== undefined && setProfiles.length === 0) {
      throw new Error('--set profiles= names no profile');
    }
    const defaultsConfig = parseYaml(kit.defaults) as Record<string, unknown> | null;
    const requested =
      explicitProfiles && explicitProfiles.length > 0
        ? explicitProfiles
        : stringList(existingConfig?.profiles).length > 0
          ? stringList(existingConfig?.profiles)
          : stringList(defaultsConfig?.profiles);
    profiles = resolveProfiles(kit, requested);
  } catch (err) {
    console.error(`Error: ${(err as Error).message}`);
    return 1;
  }

  let kitYamlText: string;
  try {
    kitYamlText = kitYamlExists ? readFileSync(kitYamlPath, 'utf-8') : kit.defaults;
    const sets = [...(kitYamlExists ? [] : [`profiles=${JSON.stringify(profiles)}`]), ...otherSets];
    // An explicit --profile (or --set profiles=) also replaces the profiles recorded in an existing kit.yaml.
    if (kitYamlExists && explicitProfiles && explicitProfiles.length > 0) {
      sets.unshift(`profiles=${JSON.stringify(profiles)}`);
    }
    kitYamlText = applySetOverrides(kitYamlText, sets);
  } catch (err) {
    console.error(`Error: ${(err as Error).message}`);
    return 1;
  }
  const config = parseYaml(kitYamlText) as unknown;
  // The kit defaults sit under the project's values, so a key the kit added after this kit.yaml
  // was written still renders (an existing kit.yaml is never rewritten with the new keys).
  const vars = {
    ...flattenKitConfig(parseYaml(kit.defaults) as unknown),
    ...flattenKitConfig(config),
    PROJECT_DIR: realpathSync(project),
  };

  const unsafe = kit.manifest.files
    .map(file => ({ file, why: unsafeManifestPath(file.path) }))
    .filter(entry => entry.why !== null);
  if (unsafe.length > 0) {
    for (const { file, why } of unsafe) {
      console.error(`Error: kit file ${file.profile}/${file.path} is refused: ${why}`);
    }
    return 1;
  }

  console.log(`Kit ${kit.manifest.source.name}@${kit.manifest.source.commit.slice(0, 7)}`);
  console.log(`Profiles: ${profiles.join(', ')}${dry ? ' (dry run, nothing is written)' : ''}`);

  const results: { path: string; state: FileState }[] = [];
  const lock = readKitLock(project);
  const nextLock: Record<string, string> = {};
  // Kept files kit add never wrote (no lock entry): files from before the lock, or the project's own.
  const keptUnlocked: string[] = [];
  const write = (
    relative: string,
    content: string,
    mode: string | null,
    createOnly = false,
    always = false
  ): FileState => {
    const dest = join(project, relative);
    const problem = destinationProblem(project, relative);
    if (problem !== null) {
      if (lock[relative] !== undefined) nextLock[relative] = lock[relative];
      return problem === 'symlink' ? 'skipped (symlink)' : 'skipped (outside)';
    }
    // A file that still holds what kit add last wrote there was never edited: a newer kit replaces it.
    const untouched =
      lock[relative] !== undefined &&
      existsSync(dest) &&
      contentHash(readFileSync(dest, 'utf-8')) === lock[relative];
    const state = existingFileState(
      dest,
      content,
      always || untouched || (options.force ?? false),
      createOnly
    );
    if (state === 'kept') {
      if (lock[relative] !== undefined) nextLock[relative] = lock[relative];
      else if (!createOnly) keptUnlocked.push(relative);
      return state;
    }
    if (!always) nextLock[relative] = contentHash(content);
    if (state) return state;
    if (!dry) {
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, content);
      if (mode !== null && (Number.parseInt(mode, 8) & 0o111) !== 0) chmodSync(dest, 0o755);
    }
    return 'written';
  };

  // kit.yaml is the project's own text plus this command's --profile and --set edits, so it is
  // always written: keeping it would drop the profiles that kit doctor reads back.
  results.push({ path: KIT_YAML, state: write(KIT_YAML, kitYamlText, null, false, true) });

  // 4. Files, in profile order; the last profile carrying a path wins.
  const missing = new Set<string>();
  const winners = winningFiles(kit, profiles);
  // The defaults file, unless the manifest ships it itself: replaced while unedited, kept once edited.
  if (!winners.has(KIT_DEFAULTS)) {
    results.push({
      path: KIT_DEFAULTS,
      state: write(KIT_DEFAULTS, kit.defaults, null),
    });
  }
  for (const file of winners.values()) {
    const source = kit.files[`${file.profile}/${file.path}`];
    if (source === undefined) {
      console.error(`Error: kit is missing content for ${file.profile}/${file.path}`);
      return 1;
    }
    const content = file.template ? renderTemplate(source, vars, missing) : source;
    results.push({
      path: file.path,
      state: write(file.path, content, file.mode, file.createOnly === true),
    });
  }
  for (const key of [...missing].sort()) {
    console.warn(`Warning: kit.yaml has no value for @@KIT_${key}@@, rendered empty`);
  }
  if (!dry) {
    const files = Object.fromEntries(
      Object.entries(nextLock).sort(([a], [b]) => a.localeCompare(b))
    );
    if (destinationProblem(project, KIT_LOCK) === null) {
      writeFileSync(
        join(project, KIT_LOCK),
        `${JSON.stringify({ kit: kit.manifest.source, files }, null, 2)}\n`
      );
    } else {
      console.warn(`Warning: ${KIT_LOCK} is a symlink or lies outside the project, not written`);
    }
  }

  const count = (state: FileState): number => results.filter(r => r.state === state).length;
  for (const result of results.filter(r => r.state !== 'written' && r.state !== 'unchanged')) {
    console.log(`  ${result.state === 'kept' ? 'kept (differs)' : result.state}  ${result.path}`);
  }
  const skipped = count('skipped (symlink)') + count('skipped (outside)');
  console.log(
    `Files: ${count('written')} ${dry ? 'would be written' : 'written'}, ${count('unchanged')} unchanged, ${count('kept')} kept (differs)` +
      (count('kept') > 0 ? ' (use --force to overwrite)' : '') +
      (skipped > 0
        ? `, ${skipped} skipped (a symlink or outside the project, never written through)`
        : '')
  );
  if (keptUnlocked.length > 0) {
    console.log(
      `${keptUnlocked.length} ${keptUnlocked.length === 1 ? 'file predates' : 'files predate'} the kit lock and ${keptUnlocked.length === 1 ? 'differs' : 'differ'} from the kit; review ${keptUnlocked.length === 1 ? 'it' : 'them'} and rerun with --force to take the kit's version`
    );
  }

  // 5. Aliases and the Copilot file hooks in .archon/config.yaml.
  mergeProjectConfig(project, kit, dry);

  // 6. Tools.
  const installTools = join(project, 'scripts', 'install-tools.sh');
  if (!options.noTools && !dry && existsSync(installTools)) {
    console.log('\nRunning scripts/install-tools.sh');
    const code = await kitToolsCommand(project, { output: options.output });
    if (code !== 0) console.warn(`Warning: scripts/install-tools.sh exited with ${code}`);
  }

  // 7. Post-install.
  let postInstallFailed = false;
  if (!options.noPostInstall && !dry) {
    for (const step of kit.manifest.postInstall.filter(s => profiles.includes(s.profile))) {
      console.log(`\nRunning ${step.run}`);
      const code = await streamCommand(step.run, project, process.env, options.output);
      if (code !== 0) {
        if (step.optional) console.warn(`Warning: optional step failed (${code}): ${step.run}`);
        else {
          console.error(`Error: step failed (${code}): ${step.run}`);
          postInstallFailed = true;
        }
      }
    }
  }

  // 8. Trust.
  const configJson = join(copilotHome(env), 'config.json');
  if (options.trust) {
    if (dry) console.log(`Would trust ${project} in ${configJson}`);
    else {
      try {
        const state = trustFolder(configJson, project);
        console.log(
          state === 'added' ? `Trusted ${project} in ${configJson}` : `Already trusted: ${project}`
        );
      } catch (err) {
        console.warn(`Warning: could not update ${configJson}: ${(err as Error).message}`);
      }
    }
  } else {
    console.log(
      `\nCopilot asks before trusting a folder. To trust it now: archon kit add ${project} --trust`
    );
  }

  // 9. User-level run-guard hook.
  if (options.userHooks) {
    const hookFile = join(copilotHome(env), 'hooks', 'archon-kit-run-guard.json');
    const guard = [...winners.keys()].find(p => p.endsWith('run-guard.sh'));
    if (guard === undefined)
      console.warn('Warning: the kit has no run-guard.sh, user hook not written');
    else if (dry) console.log(`Would write ${hookFile}`);
    else {
      const hook = {
        version: 1,
        hooks: {
          preToolUse: [userHookEntry(project, guard, winners.has(DISPATCH))],
        },
      };
      mkdirSync(dirname(hookFile), { recursive: true });
      writeFileSync(hookFile, `${JSON.stringify(hook, null, 2)}\n`);
      console.log(`Wrote user hook ${hookFile}`);
    }
  }

  // 10. Validate workflows.
  if (!options.skipValidate && !dry && existsSync(join(project, '.archon', 'workflows'))) {
    console.log('\nValidating workflows');
    try {
      const { loadRoute } = await import('../routes/route-loader');
      const { validateWorkflowsCommand } = await loadRoute(() => import('./validate'));
      const code = await validateWorkflowsCommand(project);
      if (code !== 0) console.warn('Warning: workflow validation reported problems');
    } catch (err) {
      console.warn(`Warning: could not validate workflows: ${(err as Error).message}`);
    }
  }

  // 11. Next steps.
  console.log(
    [
      '',
      'Next steps:',
      `  cd ${project}`,
      '  copilot, then /login (or set COPILOT_GITHUB_TOKEN in ~/.archon/.env), then /model',
      '  archon workflow run build-feature-copilot --dry-run --default-stubs',
      `  archon kit doctor ${project}`,
    ].join('\n')
  );
  return postInstallFailed ? 1 : 0;
}

/**
 * The user-level preToolUse entry that runs the project's run guard in every Copilot session. It runs from
 * the project with CLAUDE_PROJECT_DIR set, because dispatch.sh resolves the script path against that root
 * (an absolute path would never resolve, and the guard would allow everything); a missing guard allows.
 */
export function userHookEntry(
  project: string,
  guard: string,
  withDispatch: boolean
): { type: 'command'; bash: string; timeoutSec: number } {
  const dir = shellQuote(project);
  const script = shellQuote(guard);
  const run = withDispatch ? `bash ${DISPATCH} PreToolUse '*' ${script}` : `bash ${script}`;
  return {
    type: 'command',
    bash: `if [ -f ${dir}/${script} ]; then cd ${dir} && CLAUDE_PROJECT_DIR=${dir} ${run}; else exit 0; fi`,
    timeoutSec: 30,
  };
}

export interface FileHooksResult {
  text: string;
  state: 'added' | 'present' | 'off';
}

/**
 * Turn on `assistants.copilot.fileHooks` (off by default in the provider), so Archon's Copilot sessions run
 * the kit's `.github/hooks/*.json`. A value the project set itself is kept.
 */
export function enableFileHooks(existing: string): FileHooksResult {
  const doc = parseDocument(existing, { uniqueKeys: false });
  if (doc.errors.length > 0) throw doc.errors[0];
  const current: unknown = doc.getIn(['assistants', 'copilot', 'fileHooks']);
  if (current === true) return { text: existing, state: 'present' };
  if (current !== undefined && current !== null) return { text: existing, state: 'off' };
  doc.setIn(['assistants', 'copilot', 'fileHooks'], true);
  return { text: doc.toString(), state: 'added' };
}

function mergeProjectConfig(project: string, kit: Kit, dry: boolean): void {
  const configPath = join(project, '.archon', 'config.yaml');
  try {
    const existing = existsSync(configPath) ? readFileSync(configPath, 'utf-8') : '';
    const merged =
      Object.keys(kit.manifest.aliases).length === 0
        ? { text: existing, added: [], conflicts: [] }
        : mergeAliases(existing, kit.manifest.aliases);
    const hooks = enableFileHooks(merged.text);
    if ((merged.added.length > 0 || hooks.state === 'added') && !dry) {
      mkdirSync(dirname(configPath), { recursive: true });
      writeFileSync(configPath, hooks.text);
    }
    if (merged.added.length > 0) {
      console.log(
        `Aliases ${dry ? 'would be added' : 'added'} to .archon/config.yaml: ${merged.added.join(', ')}`
      );
    }
    for (const name of merged.conflicts) {
      console.warn(`Warning: alias ${name} already set differently in .archon/config.yaml, kept`);
    }
    if (hooks.state === 'added') {
      console.log(
        `assistants.copilot.fileHooks: true ${dry ? 'would be set' : 'set'} in .archon/config.yaml (Copilot runs the kit's .github/hooks)`
      );
    } else if (hooks.state === 'off') {
      console.warn(
        "Warning: .archon/config.yaml sets assistants.copilot.fileHooks to something other than true, kept; Copilot runs will not run the kit's hooks"
      );
    }
  } catch (err) {
    console.warn(`Warning: could not update .archon/config.yaml: ${(err as Error).message}`);
  }
}

// ---------------------------------------------------------------------------
// kit list
// ---------------------------------------------------------------------------

export function kitListCommand(cwd: string, kit: Kit): number {
  const installed = new Set(stringList(readKitYaml(cwd)?.profiles));
  for (const [name, info] of Object.entries(kit.manifest.profiles)) {
    const fileCount = kit.manifest.files.filter(f => f.profile === name).length;
    const requires = info.requires.length > 0 ? info.requires.join(', ') : '-';
    console.log(
      `${installed.has(name) ? '*' : ' '} ${name}  (${fileCount} files, requires: ${requires})`
    );
    console.log(`    ${info.description}`);
  }
  console.log('\n* installed in this project (from .archon/kit.yaml)');
  return 0;
}

// ---------------------------------------------------------------------------
// kit doctor
// ---------------------------------------------------------------------------

export interface DoctorCheck {
  status: 'ok' | 'fail' | 'warn';
  name: string;
  detail: string;
}

export interface DriftReport {
  modified: string[];
  missing: string[];
  checked: number;
}

/** sha256 of each installed non-template file against the manifest; a create-only file is the project's own. */
export function computeDrift(projectPath: string, kit: Kit, profiles: string[]): DriftReport {
  const report: DriftReport = { modified: [], missing: [], checked: 0 };
  for (const file of winningFiles(kit, profiles).values()) {
    if (file.template || file.createOnly) continue;
    report.checked++;
    const dest = join(projectPath, file.path);
    const source = kit.files[`${file.profile}/${file.path}`];
    const expected = source === undefined ? file.sha256 : contentHash(source);
    if (!existsSync(dest)) report.missing.push(file.path);
    else if (contentHash(readFileSync(dest, 'utf-8')) !== expected) report.modified.push(file.path);
  }
  if (!winningFiles(kit, profiles).has(KIT_DEFAULTS)) {
    report.checked++;
    const dest = join(projectPath, KIT_DEFAULTS);
    if (!existsSync(dest)) report.missing.push(KIT_DEFAULTS);
    else if (contentHash(readFileSync(dest, 'utf-8')) !== contentHash(kit.defaults)) {
      report.modified.push(KIT_DEFAULTS);
    }
  }
  return report;
}

function versionOf(command: string, args: string[]): string | null {
  const result = spawnSync(command, args, { encoding: 'utf-8', timeout: 15000 });
  if (result.error || result.status !== 0) return null;
  return (result.stdout || result.stderr).trim().split('\n')[0] ?? '';
}

export function onPath(command: string, env: NodeJS.ProcessEnv): boolean {
  for (const dir of (env.PATH ?? '').split(delimiter)) {
    if (dir && existsSync(join(dir, command))) return true;
  }
  return false;
}

export function checkTools(
  projectPath: string,
  env: NodeJS.ProcessEnv = process.env
): DoctorCheck[] {
  const installer = join(projectPath, INSTALL_TOOLS);
  if (existsSync(installer) && readFileSync(installer, 'utf-8').includes('--check')) {
    const result = spawnSync('bash', [INSTALL_TOOLS, '--check'], {
      cwd: projectPath,
      encoding: 'utf-8',
      timeout: 120000,
    });
    const output = `${result.stdout}${result.stderr}`.trim();
    return [
      {
        status: result.status === 0 ? 'ok' : 'fail',
        name: 'tools (scripts/install-tools.sh --check)',
        detail: output,
      },
    ];
  }
  const checks: DoctorCheck[] = [];
  const check = (
    name: string,
    required: boolean,
    versionArgs: string[],
    validate?: (version: string) => string | null
  ): void => {
    const missingStatus = required ? 'fail' : 'warn';
    if (!onPath(name, env)) {
      checks.push({ status: missingStatus, name, detail: 'not found on PATH' });
      return;
    }
    const version = versionOf(name, versionArgs);
    if (version === null) {
      checks.push({ status: missingStatus, name, detail: 'found but did not report a version' });
      return;
    }
    const problem = validate?.(version) ?? null;
    checks.push(
      problem === null
        ? { status: 'ok', name, detail: version }
        : { status: missingStatus, name, detail: `${version}: ${problem}` }
    );
  };
  check('git', true, ['--version']);
  check('node', true, ['--version'], v => {
    const m = /v?(\d+)\.(\d+)/.exec(v);
    if (!m) return 'unrecognised version';
    const [major, minor] = [Number(m[1]), Number(m[2])];
    return major > 20 || (major === 20 && minor >= 19) ? null : 'need node >= 20.19';
  });
  check('npm', true, ['--version']);
  check('jq', true, ['--version']);
  check('yq', true, ['--version'], v =>
    /mikefarah/i.test(v) || /version v?4\./i.test(v) ? null : 'need mikefarah yq v4'
  );
  check('gh', true, ['--version']);
  check('copilot', true, ['--version']);
  check('codegraph', true, ['--version']);
  check('backlog', true, ['--version']);
  check('groma', true, ['--version']);
  check('java', false, ['-version']);
  check('docker', false, ['--version']);
  return checks;
}

export function checkAuth(env: NodeJS.ProcessEnv = process.env): DoctorCheck {
  for (const key of ['COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN']) {
    if (env[key]) return { status: 'ok', name: 'copilot auth', detail: `${key} is set` };
  }
  const envFile = join(env.ARCHON_HOME ?? join(homedir(), '.archon'), '.env');
  if (
    existsSync(envFile) &&
    /^\s*(export\s+)?COPILOT_GITHUB_TOKEN\s*=\s*\S/m.test(readFileSync(envFile, 'utf-8'))
  ) {
    return { status: 'ok', name: 'copilot auth', detail: `COPILOT_GITHUB_TOKEN in ${envFile}` };
  }
  const config = readJsonObject(join(copilotHome(env), 'config.json'));
  if (config) {
    const key = Object.keys(config).find(
      k =>
        /logged.?in|login|user/i.test(k) &&
        config[k] !== null &&
        config[k] !== '' &&
        !(Array.isArray(config[k]) && (config[k] as unknown[]).length === 0)
    );
    if (key)
      return { status: 'ok', name: 'copilot auth', detail: `logged in (config.json key ${key})` };
  }
  return {
    status: 'fail',
    name: 'copilot auth',
    detail: 'no token and no logged-in user; run copilot then /login, or set COPILOT_GITHUB_TOKEN',
  };
}

export function checkTrust(projectPath: string, env: NodeJS.ProcessEnv = process.env): DoctorCheck {
  const config = readJsonObject(join(copilotHome(env), 'config.json'));
  // Both spellings count: an empty trustedFolders must not hide a filled trusted_folders.
  const folders = [...stringList(config?.trustedFolders), ...stringList(config?.trusted_folders)];
  const trusted = folders.some(f => projectPath === f || projectPath.startsWith(`${f}/`));
  return trusted
    ? { status: 'ok', name: 'folder trust', detail: projectPath }
    : {
        status: 'fail',
        name: 'folder trust',
        detail: `${projectPath} is not trusted; run archon kit add ${projectPath} --trust`,
      };
}

interface McpServerSpec {
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  cwd?: string;
  url?: string;
  type?: string;
}

/** Start one stdio MCP server, run `initialize` and `tools/list`, return the tool count. */
export function probeMcpServer(
  spec: McpServerSpec,
  projectPath: string,
  timeoutMs: number
): Promise<{ ok: true; tools: number } | { ok: false; error: string }> {
  return new Promise(done => {
    if (!spec.command) {
      done({ ok: false, error: 'no command' });
      return;
    }
    const cwd = spec.cwd ? resolve(projectPath, spec.cwd) : projectPath;
    const child = spawn(spec.command, spec.args ?? [], {
      cwd,
      env: { ...process.env, ...(spec.env ?? {}) },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let settled = false;
    let buffer = '';
    let stderr = '';
    const finish = (result: { ok: true; tools: number } | { ok: false; error: string }): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      done(result);
    };
    const timer = setTimeout(
      () => finish({ ok: false, error: `no answer within ${Math.round(timeoutMs / 1000)} s` }),
      timeoutMs
    );
    const send = (message: unknown): void => {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    };
    child.on('error', err => finish({ ok: false, error: err.message }));
    child.on('close', code =>
      finish({
        ok: false,
        error: `exited (${code})${stderr ? `: ${stderr.trim().slice(-200)}` : ''}`,
      })
    );
    child.stderr.on('data', chunk => {
      stderr += String(chunk);
    });
    child.stdout.on('data', chunk => {
      buffer += String(chunk);
      let newline = buffer.indexOf('\n');
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf('\n');
        if (!line) continue;
        let message: { id?: number; result?: { tools?: unknown[] }; error?: { message?: string } };
        try {
          message = JSON.parse(line) as typeof message;
        } catch {
          continue;
        }
        if (message.error) finish({ ok: false, error: message.error.message ?? 'MCP error' });
        else if (message.id === 1) {
          send({ jsonrpc: '2.0', method: 'notifications/initialized' });
          send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
        } else if (message.id === 2) {
          finish({ ok: true, tools: message.result?.tools?.length ?? 0 });
        }
      }
    });
    send({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'archon-kit-doctor', version: '1' },
      },
    });
  });
}

export async function checkMcpServers(
  projectPath: string,
  timeoutMs = 20000
): Promise<DoctorCheck[]> {
  const file = join(projectPath, '.github', 'mcp.json');
  if (!existsSync(file))
    return [{ status: 'warn', name: 'mcp', detail: '.github/mcp.json not found' }];
  const parsed = readJsonObject(file);
  const servers = (parsed?.mcpServers ?? parsed?.servers) as
    | Record<string, McpServerSpec>
    | undefined;
  if (!servers)
    return [{ status: 'fail', name: 'mcp', detail: '.github/mcp.json has no mcpServers' }];
  const checks = await Promise.all(
    Object.entries(servers).map(async ([name, spec]): Promise<DoctorCheck> => {
      if (spec.url || (spec.type && spec.type !== 'local' && spec.type !== 'stdio')) {
        return { status: 'warn', name: `mcp ${name}`, detail: 'remote server, not probed' };
      }
      const result = await probeMcpServer(spec, projectPath, timeoutMs);
      return result.ok
        ? { status: 'ok', name: `mcp ${name}`, detail: `${result.tools} tools` }
        : { status: 'fail', name: `mcp ${name}`, detail: result.error };
    })
  );
  return checks;
}

export function checkHooks(projectPath: string): DoctorCheck {
  const file = join(projectPath, '.github', 'hooks', 'kit.json');
  if (!existsSync(file))
    return { status: 'fail', name: 'hooks', detail: '.github/hooks/kit.json not found' };
  const parsed = readJsonObject(file);
  if (!parsed)
    return { status: 'fail', name: 'hooks', detail: '.github/hooks/kit.json does not parse' };
  const scripts = new Set<string>();
  const hooks = (parsed.hooks ?? {}) as Record<string, { bash?: string; powershell?: string }[]>;
  for (const entries of Object.values(hooks)) {
    for (const entry of entries) {
      for (const token of (entry.bash ?? '').split(/\s+/)) {
        const bare = token.replace(/^['"]|['"]$/g, '');
        if (/\.(sh|js|mjs|ts|py)$/.test(bare)) scripts.add(bare);
      }
    }
  }
  const absent = [...scripts].filter(s => !existsSync(isAbsolute(s) ? s : join(projectPath, s)));
  return absent.length === 0
    ? { status: 'ok', name: 'hooks', detail: `${scripts.size} scripts referenced, all present` }
    : { status: 'fail', name: 'hooks', detail: `missing scripts: ${absent.join(', ')}` };
}

export async function kitDoctorCommand(
  targetPath: string,
  kit: Kit,
  options: { env?: NodeJS.ProcessEnv; mcpTimeoutMs?: number } = {}
): Promise<number> {
  const env = options.env ?? process.env;
  const project = resolve(targetPath);
  const checks: DoctorCheck[] = [
    ...checkTools(project, env),
    checkAuth(env),
    checkTrust(project, env),
  ];
  checks.push(...(await checkMcpServers(project, options.mcpTimeoutMs ?? 20000)));
  checks.push(checkHooks(project));

  const config = readKitYaml(project);
  if (config === null) {
    checks.push({
      status: 'fail',
      name: 'drift',
      detail: '.archon/kit.yaml not found; run archon kit add',
    });
  } else {
    try {
      // A kit.yaml without profiles installed the kit defaults' profiles, as kit add does.
      const recorded = stringList(config.profiles);
      const defaults = parseYaml(kit.defaults) as Record<string, unknown> | null;
      const profiles = resolveProfiles(
        kit,
        recorded.length > 0 ? recorded : stringList(defaults?.profiles)
      );
      const drift = computeDrift(project, kit, profiles);
      const bad = [
        ...drift.missing.map(p => `missing ${p}`),
        ...drift.modified.map(p => `modified ${p}`),
      ];
      checks.push({
        status: bad.length === 0 ? 'ok' : 'warn',
        name: 'drift',
        detail:
          `${drift.checked} files checked, ${drift.modified.length} modified, ${drift.missing.length} missing` +
          (bad.length > 0
            ? `\n      ${bad.slice(0, 20).join('\n      ')}${bad.length > 20 ? `\n      ...and ${bad.length - 20} more` : ''}`
            : ''),
      });
    } catch (err) {
      checks.push({ status: 'fail', name: 'drift', detail: (err as Error).message });
    }
  }

  const mark = { ok: '✓', fail: '✗', warn: '!' } as const;
  for (const c of checks) console.log(`${mark[c.status]} ${c.name}: ${c.detail}`);
  const failed = checks.filter(c => c.status === 'fail').length;
  console.log(
    failed === 0 ? '\nAll required checks passed.' : `\n${failed} required check(s) failed.`
  );
  return failed === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Entry used by the router
// ---------------------------------------------------------------------------

export async function kitCommand(
  subcommand: string | undefined,
  targetArg: string | undefined,
  cwd: string,
  options: KitAddOptions
): Promise<number> {
  if (
    subcommand !== 'add' &&
    subcommand !== 'doctor' &&
    subcommand !== 'list' &&
    subcommand !== 'tools'
  ) {
    console.error(
      `${subcommand === undefined ? 'Missing kit subcommand' : `Unknown kit subcommand: ${subcommand}`}\nAvailable: add, doctor, list, setup, tools`
    );
    return 1;
  }
  const target = targetArg ? resolve(targetArg) : cwd;
  if (subcommand === 'tools' && hasProjectInstaller(target)) {
    return await kitToolsCommand(target, { check: options.check });
  }
  const { BUNDLED_KIT: kit } = await import('../bundled-kit');
  if (subcommand === 'tools') return await kitToolsCommand(target, { check: options.check, kit });
  if (subcommand === 'list') return kitListCommand(target, kit);
  if (subcommand === 'doctor') return await kitDoctorCommand(target, kit);
  return await kitAddCommand(target, options, kit);
}
