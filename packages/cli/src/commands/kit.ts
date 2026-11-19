/**
 * Kit command - install the bundled Copilot kit into a project and check it.
 *
 * `archon kit add`    writes the kit's profile files, kit.yaml and model aliases
 * `archon kit doctor` checks tools, auth, trust, MCP servers, hooks and drift
 * `archon kit list`   shows the profiles and which are installed
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
  realpathSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'fs';
import { homedir } from 'os';
import { delimiter, dirname, isAbsolute, join, resolve } from 'path';
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
}

const KIT_YAML = join('.archon', 'kit.yaml');

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

export function copilotHome(env: NodeJS.ProcessEnv = process.env): string {
  return env.COPILOT_HOME ? resolve(env.COPILOT_HOME) : join(homedir(), '.copilot');
}

function sha256(text: string): string {
  return createHash('sha256').update(text).digest('hex');
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

function coerceScalar(raw: string): unknown {
  try {
    const parsed: unknown = parseYaml(raw);
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) return raw;
    return parsed ?? '';
  } catch {
    return raw;
  }
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
  writeFileSync(configPath, `${JSON.stringify(data, null, 2)}\n`);
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

function isGitRepo(path: string): boolean {
  const result = spawnSync('git', ['rev-parse', '--is-inside-work-tree'], {
    cwd: path,
    encoding: 'utf-8',
  });
  return result.status === 0 && result.stdout.trim() === 'true';
}

function streamCommand(command: string, cwd: string): Promise<number> {
  return new Promise(resolveExit => {
    const child = spawn('bash', ['-c', command], { cwd, stdio: 'inherit' });
    child.on('error', () => resolveExit(127));
    child.on('close', code => resolveExit(code ?? 1));
  });
}

// ---------------------------------------------------------------------------
// kit tools
// ---------------------------------------------------------------------------

const INSTALL_TOOLS = join('scripts', 'install-tools.sh');

/** Run `bash scripts/install-tools.sh [--check]` in the project, streaming output. */
export async function kitToolsCommand(targetPath: string, check = false): Promise<number> {
  const project = resolve(targetPath);
  if (!existsSync(join(project, INSTALL_TOOLS))) {
    console.error(
      `Error: ${join(project, INSTALL_TOOLS)} not found. Install the kit first: archon kit add ${project}`
    );
    return 1;
  }
  return await streamCommand(`bash ${INSTALL_TOOLS}${check ? ' --check' : ''}`, project);
}

// ---------------------------------------------------------------------------
// kit add
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

type FileState = 'written' | 'unchanged' | 'kept';

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
  if (readFileSync(dest, 'utf-8') === content) return 'unchanged';
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
  try {
    const defaultsConfig = parseYaml(kit.defaults) as Record<string, unknown> | null;
    const requested =
      options.profiles && options.profiles.length > 0
        ? options.profiles
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
    const sets = [
      ...(kitYamlExists ? [] : [`profiles=${JSON.stringify(profiles)}`]),
      ...(options.set ?? []),
    ];
    // An explicit --profile also replaces the profiles recorded in an existing kit.yaml.
    if (kitYamlExists && options.profiles && options.profiles.length > 0) {
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

  console.log(`Kit ${kit.manifest.source.name}@${kit.manifest.source.commit.slice(0, 7)}`);
  console.log(`Profiles: ${profiles.join(', ')}${dry ? ' (dry run, nothing is written)' : ''}`);

  const results: { path: string; state: FileState }[] = [];
  const write = (
    relative: string,
    content: string,
    mode: string | null,
    createOnly = false
  ): FileState => {
    const dest = join(project, relative);
    const state = existingFileState(dest, content, options.force ?? false, createOnly);
    if (state) return state;
    if (!dry) {
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, content);
      if (mode !== null && (Number.parseInt(mode, 8) & 0o111) !== 0) chmodSync(dest, 0o755);
    }
    return 'written';
  };

  results.push({ path: KIT_YAML, state: write(KIT_YAML, kitYamlText, null) });

  // 4. Files, in profile order; the last profile carrying a path wins.
  const missing = new Set<string>();
  const winners = winningFiles(kit, profiles);
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

  const count = (state: FileState): number => results.filter(r => r.state === state).length;
  for (const result of results.filter(r => r.state === 'kept')) {
    console.log(`  kept (differs)  ${result.path}`);
  }
  console.log(
    `Files: ${count('written')} ${dry ? 'would be written' : 'written'}, ${count('unchanged')} unchanged, ${count('kept')} kept (differs)` +
      (count('kept') > 0 ? ' (use --force to overwrite)' : '')
  );

  // 5. Aliases.
  mergeAliasesIntoProject(project, kit, dry);

  // 6. Tools.
  const installTools = join(project, 'scripts', 'install-tools.sh');
  if (!options.noTools && !dry && existsSync(installTools)) {
    console.log('\nRunning scripts/install-tools.sh');
    const code = await kitToolsCommand(project);
    if (code !== 0) console.warn(`Warning: scripts/install-tools.sh exited with ${code}`);
  }

  // 7. Post-install.
  let postInstallFailed = false;
  if (!options.noPostInstall && !dry) {
    for (const step of kit.manifest.postInstall.filter(s => profiles.includes(s.profile))) {
      console.log(`\nRunning ${step.run}`);
      const code = await streamCommand(step.run, project);
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
      const guardPath = join(project, guard);
      const dispatch = winners.has('.github/hooks/dispatch.sh')
        ? join(project, '.github/hooks/dispatch.sh')
        : null;
      const run =
        dispatch === null
          ? `bash '${guardPath}'`
          : `bash '${dispatch}' PreToolUse '.*' '${guardPath}'`;
      const hook = {
        version: 1,
        hooks: {
          preToolUse: [
            { type: 'command', bash: `[ -f '${guardPath}' ] && ${run} || true`, timeoutSec: 30 },
          ],
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

function mergeAliasesIntoProject(project: string, kit: Kit, dry: boolean): void {
  if (Object.keys(kit.manifest.aliases).length === 0) return;
  const configPath = join(project, '.archon', 'config.yaml');
  try {
    const existing = existsSync(configPath) ? readFileSync(configPath, 'utf-8') : '';
    const merged = mergeAliases(existing, kit.manifest.aliases);
    if (merged.added.length > 0 && !dry) {
      mkdirSync(dirname(configPath), { recursive: true });
      writeFileSync(configPath, merged.text);
    }
    if (merged.added.length > 0) {
      console.log(
        `Aliases ${dry ? 'would be added' : 'added'} to .archon/config.yaml: ${merged.added.join(', ')}`
      );
    }
    for (const name of merged.conflicts) {
      console.warn(`Warning: alias ${name} already set differently in .archon/config.yaml, kept`);
    }
  } catch (err) {
    console.warn(`Warning: could not merge aliases: ${(err as Error).message}`);
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
    if (!existsSync(dest)) report.missing.push(file.path);
    else if (sha256(readFileSync(dest, 'utf-8')) !== file.sha256) report.modified.push(file.path);
  }
  return report;
}

function versionOf(command: string, args: string[]): string | null {
  const result = spawnSync(command, args, { encoding: 'utf-8', timeout: 15000 });
  if (result.error || result.status !== 0) return null;
  return (result.stdout || result.stderr).trim().split('\n')[0] ?? '';
}

function onPath(command: string, env: NodeJS.ProcessEnv): boolean {
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
  const folders = stringList(config?.trustedFolders ?? config?.trusted_folders);
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
      const profiles = resolveProfiles(kit, stringList(config.profiles));
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
      `${subcommand === undefined ? 'Missing kit subcommand' : `Unknown kit subcommand: ${subcommand}`}\nAvailable: add, doctor, list, tools`
    );
    return 1;
  }
  if (subcommand === 'tools')
    return await kitToolsCommand(targetArg ? resolve(targetArg) : cwd, options.check);
  const { BUNDLED_KIT: kit } = await import('../bundled-kit');
  const target = targetArg ? resolve(targetArg) : cwd;
  if (subcommand === 'list') return kitListCommand(target, kit);
  if (subcommand === 'doctor') return await kitDoctorCommand(target, kit);
  return await kitAddCommand(target, options, kit);
}
