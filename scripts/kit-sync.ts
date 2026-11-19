#!/usr/bin/env bun
/**
 * kit-sync: generate the Copilot kit (`kit/profiles/**` and `kit/manifest.json`) from a Claude Code source repo.
 * The contract is `kit/SPEC.md`. The copy lists and rewrites are in kit-sync-lists.ts, the conversions in
 * kit-sync-convert.ts, and the source and overlay reading in kit-sync-source.ts; this file builds, writes and checks.
 *
 *   bun run scripts/kit-sync.ts <source-repo> [--out kit]          regenerate kit/profiles and kit/manifest.json
 *   bun run scripts/kit-sync.ts <source-repo> --check [--out kit]  regenerate into a temp dir, exit 1 on drift
 *   bun run scripts/kit-sync.ts --verify [--out kit]               no source needed: manifest <-> files, overlays, leaks
 *
 * The source is read from its HEAD commit (git-tracked files only), never from its work tree, so the output is the
 * same on every machine for one source commit. Every tracked file under the scanned roots must be assigned to a
 * profile or excluded in kit-sync-lists.ts: a new source file fails the sync until a list names it.
 */
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import {
  AGENT_SCOPES,
  convertAgent,
  convertDeny,
  convertHooks,
  convertRule,
  convertSkillMd,
  DISPATCH_SH,
  fencedAgents,
  KIT_MODULES,
  mcpFallbackCommands,
  mcpJson,
  parseYaml,
  splitFrontmatter,
  withMcpFallbackScopes,
  withoutAgentScopes,
  withWorkflowFallback,
} from './kit-sync-convert';
import { depsCheck, judgeDeps } from './kit-sync-deps';
import {
  applySuiteNouns,
  classifySuite,
  isSuitePath,
  suiteOf,
  suiteSubject,
} from './kit-sync-tests';
import { genericThisRepo, PATH_REWRITES, PATH_SKIP, renamePath } from './kit-sync-generic';
import { BUILD_WORKFLOW, COPILOT_WORKFLOW, standaloneWorkflow } from './kit-sync-standalone';
import {
  AGENT_PROFILES,
  EXCLUDE,
  EXCLUSIVE,
  FILES,
  GLOBAL_REWRITES,
  type Kind,
  LEAF_PROFILES,
  leakCheck,
  NEVER_SHIP,
  neverShipNamesIn,
  POST_INSTALL,
  PROFILE_META,
  PROFILES,
  PROJECT_DIR,
  type Profile,
  QUARKUS_TEMPLATE,
  RULE_PROFILES,
  type Rewrite,
  SKILL_PROFILES,
  SKILL_RENAMES,
  TARGETED,
} from './kit-sync-lists';
import {
  type OverlayFile,
  readOverlays,
  readSource,
  type Source,
  type SourceFile,
  sha256,
  staleOverlays,
  uncommitted,
  walk,
} from './kit-sync-source';

export * from './kit-sync-convert';
export * from './kit-sync-lists';
export * from './kit-sync-source';

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
  /** Written only when the project has no such file (an overlay's `createOnly`). */
  createOnly?: boolean;
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

type Convert = 'agent' | 'skill' | 'rule';

const CLAUDE_LISTS: [RegExp, Record<string, Profile>, Convert, string][] = [
  [
    /^\.claude\/agents\/([^/]+)\.md$/,
    AGENT_PROFILES,
    'agent',
    'agent not on a copy list (AGENT_PROFILES)',
  ],
  [
    /^\.claude\/skills\/([^/]+)\//,
    SKILL_PROFILES,
    'skill',
    'skill not on a copy list (SKILL_PROFILES)',
  ],
  [
    /^\.claude\/rules\/([^/]+)\.md$/,
    RULE_PROFILES,
    'rule',
    'rule not on a copy list (RULE_PROFILES)',
  ],
];

/** An agent, skill or rule: its own copy list decides. */
function classifyClaude(path: string): Assignment | undefined {
  for (const [re, list, convert, missing] of CLAUDE_LISTS) {
    const m = re.exec(path);
    if (!m) continue;
    const profile = list[m[1] ?? ''];
    if (!profile) throw new Error(`${path}: ${missing}`);
    return { profile, convert };
  }
  return undefined;
}

/** A code-map leaf ships only as a worked example, in the most specific profile of the skills it serves. */
function classifyCodeMap(path: string, text: string): Assignment {
  const fm = frontmatterOf(text);
  if (fm.kind !== 'worked-example' || !path.endsWith('.md'))
    return { exclude: true, why: 'project code-map leaf' };
  let names = [basename(path, '.md').replace(/\.worked-example$/, '')];
  if (path.startsWith('docs/code-maps/exemplars/'))
    names = Array.isArray(fm.serves) ? fm.serves.map(String) : [];
  const profiles = names.map(leafProfile).filter((p): p is Profile => p !== undefined);
  return { profile: mostSpecific(profiles, path), convert: 'copy' };
}

/** FILES: an exact path beats a glob; more than one match of the same kind is an error. */
function classifyByList(path: string): Assignment {
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
  throw new Error(
    `${path}: not on a copy list and not excluded; assign it in scripts/kit-sync-lists.ts`
  );
}

export function classify(
  path: string,
  text: string,
  files: ReadonlySet<string> = new Set()
): Assignment {
  if (NEVER_SHIP.includes(path)) return { exclude: true, why: 'never ships' };
  if (isSuitePath(path) && NEVER_SHIP.includes(suiteOf(path)))
    return { exclude: true, why: 'its suite never ships' };
  if (isSuitePath(path)) {
    const a = classifySuite(path, files, p => classify(p, '', files));
    return a.exclude ? a : { profile: a.profile, convert: 'copy' };
  }
  if (EXCLUDE.some(p => matches(p, path))) return { exclude: true, why: 'excluded' };
  const claude = classifyClaude(path);
  if (claude) return claude;
  if (path.startsWith('docs/scaffold-templates/'))
    return { profile: QUARKUS_TEMPLATE.test(text) ? 'java-quarkus' : 'java', convert: 'copy' };
  if (path.startsWith('docs/code-maps/') && path !== 'docs/code-maps/README.md')
    return classifyCodeMap(path, text);
  return classifyByList(path);
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

/** A PATH_SKIP file, or a suite (or its fixture) of one, keeps its Claude Code path references. */
function keepsClaudePaths(path: string): boolean {
  if (PATH_SKIP.includes(path)) return true;
  if (!isSuitePath(path)) return false;
  const subject = suiteSubject(suiteOf(path), new Set(PATH_SKIP));
  return subject !== undefined && PATH_SKIP.includes(subject);
}

/** `path` is the source path: see keepsClaudePaths; a suite also gets the suite nouns. */
export function applyGlobalRewrites(text: string, path = ''): string {
  let out = text;
  for (const [re, to] of GLOBAL_REWRITES) out = out.replace(re, to);
  if (!keepsClaudePaths(path)) for (const [re, to] of PATH_REWRITES) out = out.replace(re, to);
  return isSuitePath(path) ? applySuiteNouns(out) : out;
}

function targetPath(path: string, convert: 'agent' | 'skill' | 'rule' | 'copy'): string {
  if (convert === 'agent') return `.github/agents/${basename(path, '.md')}.agent.md`;
  if (convert === 'rule') return `.github/instructions/${basename(path, '.md')}.instructions.md`;
  if (convert === 'skill') {
    const [, , skill, ...rest] = path.split('/');
    return ['.github/skills', SKILL_RENAMES[skill ?? ''] ?? skill, ...rest].join('/');
  }
  return renamePath(path);
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

type NewFile = Omit<KitFile, 'template' | 'kind'> & { kind?: Kind };

/** A hook script or deny rule that names a never-ship file is left out of the converted settings. */
const namesNeverShip = (text: string): boolean => neverShipNamesIn(text).length > 0;

/** The source agents that never ship; their fences are dropped from agent-scopes.json. */
const NEVER_SHIP_AGENTS = NEVER_SHIP.filter(p => /^\.claude\/agents\/[^/]+\.md$/.test(p)).map(p =>
  basename(p, '.md')
);

const kitFile = (f: NewFile): KitFile => ({
  ...f,
  kind: f.kind ?? kindOf(f.path),
  template: f.content.includes('@@KIT_'),
});

function checkRewriteTargets(src: Source, rewrites: Record<string, Rewrite[]>): void {
  for (const p of Object.keys(rewrites))
    if (!src.files.has(p) && !(p === COPILOT_WORKFLOW && src.files.has(BUILD_WORKFLOW)))
      throw new Error(`${p}: has rewrites in scripts/kit-sync-lists.ts but is not in the source`);
}

/** What the conversion of one file needs to know of the other agents. */
interface AgentContext {
  /** The agents agent-scopes.json fences. */
  fenced: ReadonlySet<string>;
  /** Each agent's MCP fallback commands (mcpFallbackCommands), for agent-scopes.json. */
  fallbacks: ReadonlyMap<string, readonly string[]>;
}

/** Each shipped source agent's MCP fallback commands, by its frontmatter name; an agent with none is left out. */
function agentFallbacks(src: Source, tracked: ReadonlySet<string>): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const f of src.files.values()) {
    if (!/^\.claude\/agents\/[^/]+\.md$/.test(f.path)) continue;
    const text = textOf(f);
    if (classify(f.path, text, tracked).exclude) continue;
    const fm = frontmatterOf(text);
    const commands = mcpFallbackCommands(fm.tools);
    if (commands.length && fm.name) out.set(String(fm.name), commands);
  }
  return out;
}

function convertText(
  f: SourceFile,
  raw: string,
  convert: Assignment & { exclude?: false },
  rewrites: Rewrite[],
  ctx: AgentContext
): string {
  let text = standaloneWorkflow(f.path, applyRewrites(f.path, raw, rewrites));
  if (/^docs\/code-maps\/[^/]+\.md$/.test(f.path))
    text = genericThisRepo(f.path, convert.profile, text);
  if (f.path === AGENT_SCOPES)
    text = withMcpFallbackScopes(withoutAgentScopes(text, NEVER_SHIP_AGENTS), ctx.fallbacks);
  if (f.path === COPILOT_WORKFLOW) text = withWorkflowFallback(text, f.path);
  if (convert.convert === 'agent') text = convertAgent(text, f.path, ctx.fenced);
  else if (convert.convert === 'rule')
    text = convertRule(basename(f.path, '.md'), text, KIT_MODULES);
  else if (convert.convert === 'skill' && basename(f.path) === 'SKILL.md')
    text = convertSkillMd(text, f.path);
  if (f.path.startsWith('.agents/skills/archon-cli/'))
    return text.replace(PROJECT_DIR, '@@KIT_PROJECT_DIR@@');
  return applyGlobalRewrites(text, f.path);
}

/** Every tracked source file that is not excluded, converted and rewritten. */
function sourceFiles(src: Source, rewrites: Record<string, Rewrite[]>): KitFile[] {
  const out: KitFile[] = [];
  const tracked = new Set(src.files.keys());
  const scopes = src.files.get(AGENT_SCOPES);
  const ctx: AgentContext = {
    fenced: fencedAgents(scopes && withoutAgentScopes(textOf(scopes), NEVER_SHIP_AGENTS)),
    fallbacks: agentFallbacks(src, tracked),
  };
  for (const f of [...src.files.values()].sort((a, b) => (a.path < b.path ? -1 : 1))) {
    const raw = textOf(f);
    const a = classify(f.path, raw, tracked);
    if (a.exclude) continue;
    if (f.gitMode === '120000') throw new Error(`${f.path}: symlinks are not supported by the kit`);
    out.push(
      kitFile({
        path: targetPath(f.path, a.convert),
        profile: a.profile,
        mode: f.gitMode === '100755' ? '0755' : '0644',
        origin: f.path,
        content: convertText(f, raw, a, rewrites[f.path] ?? [], ctx),
      })
    );
  }
  return out;
}

function copilotWorkflow(src: Source, rewrites: Record<string, Rewrite[]>): KitFile[] {
  if (src.files.has(COPILOT_WORKFLOW) || !src.files.has(BUILD_WORKFLOW)) return [];
  const text = withWorkflowFallback(
    standaloneWorkflow(
      COPILOT_WORKFLOW,
      applyRewrites(
        COPILOT_WORKFLOW,
        copilotWorkflowFromScript(src),
        rewrites[COPILOT_WORKFLOW] ?? []
      )
    ),
    COPILOT_WORKFLOW
  );
  const content = applyGlobalRewrites(text, COPILOT_WORKFLOW);
  return [
    kitFile({
      path: COPILOT_WORKFLOW,
      profile: 'core',
      mode: '0644',
      origin: BUILD_WORKFLOW,
      content,
    }),
  ];
}

function settingsFiles(src: Source): KitFile[] {
  const f = src.files.get('.claude/settings.json');
  if (!f) return [];
  const settings = JSON.parse(textOf(f)) as Record<string, unknown>;
  const origin = '.claude/settings.json';
  return [
    kitFile({
      path: '.github/hooks/kit.json',
      profile: 'core',
      mode: '0644',
      origin,
      kind: 'hook',
      content: convertHooks(settings, namesNeverShip),
    }),
    kitFile({
      path: '.archon/copilot/deny.json',
      profile: 'core',
      mode: '0644',
      origin,
      kind: 'config',
      content: convertDeny(settings, namesNeverShip),
    }),
  ];
}

const FIXED_FILES: KitFile[] = [
  kitFile({
    path: '.github/hooks/dispatch.sh',
    profile: 'core',
    mode: '0755',
    origin: null,
    kind: 'hook',
    content: DISPATCH_SH,
  }),
  kitFile({
    path: '.github/mcp.json',
    profile: 'core',
    mode: '0644',
    origin: null,
    content: mcpJson(false),
  }),
  kitFile({
    path: '.github/mcp.json',
    profile: 'openapi-contract',
    mode: '0644',
    origin: null,
    content: mcpJson(true),
  }),
];

/** Keyed by `<profile>/<path>`: a path generated twice fails; an overlay replaces what it lands on. */
function withOverlays(files: KitFile[], overlays: OverlayFile[]): KitFile[] {
  const seen = new Map<string, KitFile>();
  for (const f of files) {
    const key = `${f.profile}/${f.path}`;
    const had = seen.get(key);
    if (had) throw new Error(`${key}: generated twice (from ${had.origin} and ${f.origin})`);
    seen.set(key, f);
  }
  for (const o of overlays)
    seen.set(
      `${o.profile}/${o.path}`,
      kitFile({
        path: o.path,
        profile: o.profile,
        mode: o.executable ? '0755' : '0644',
        origin: o.entry.derivedFrom,
        content: o.content,
        ...(o.entry.createOnly ? { createOnly: true } : {}),
      })
    );
  return [...seen.values()];
}

/** Profile order, then path (byte order). */
function compareKitFiles(a: KitFile, b: KitFile): number {
  const d = PROFILES.indexOf(a.profile) - PROFILES.indexOf(b.profile);
  if (d) return d;
  if (a.path === b.path) return 0;
  return a.path < b.path ? -1 : 1;
}

/** `rewrites` is a test seam; the real sync uses TARGETED, and a TARGETED path the source lacks fails it. */
export function buildKit(
  src: Source,
  overlays: OverlayFile[],
  rewrites: Record<string, Rewrite[]> = TARGETED
): Kit {
  checkRewriteTargets(src, rewrites);
  const generated = [
    ...sourceFiles(src, rewrites),
    ...copilotWorkflow(src, rewrites),
    ...settingsFiles(src),
    ...FIXED_FILES,
  ];
  const all = withOverlays(generated, overlays).sort(compareKitFiles);
  const bad = all.find(f => f.path.startsWith('/') || f.path.split('/').includes('..'));
  if (bad) throw new Error(`${bad.profile}/${bad.path}: not a relative project path`);
  return {
    source: { name: src.name, commit: src.commit },
    aliases: aliasesOf(src),
    files: all,
    ...leakCheck(all),
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
      ...(f.createOnly ? { createOnly: true } : {}),
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

interface ManifestEntry {
  path: string;
  profile: Profile;
  mode: string;
  template: boolean;
  sha256: string;
}

/** One manifest entry against its file; answers the file's content, or null when it is missing. */
function verifyEntry(out: string, f: ManifestEntry, problems: string[]): string | null {
  const key = `${f.profile}/${f.path}`;
  const full = join(out, 'profiles', key);
  if (!existsSync(full)) {
    problems.push(`missing: profiles/${key}`);
    return null;
  }
  const content = readFileSync(full, 'utf8');
  if (sha256(content) !== f.sha256)
    problems.push(`changed: profiles/${key} (sha256 differs from manifest)`);
  if (f.template !== content.includes('@@KIT_'))
    problems.push(`manifest: ${key} template flag is wrong`);
  const exec = (statSync(full).mode & 0o111) !== 0;
  if (exec !== (f.mode === '0755')) problems.push(`mode: profiles/${key} is not ${f.mode}`);
  return content;
}

function verifyOverlays(out: string): string[] {
  try {
    return readOverlays(join(out, 'overlays'))
      .filter(o => {
        const full = join(out, 'profiles', o.profile, o.path);
        return (
          !existsSync(full) ||
          readFileSync(full, 'utf8') !== o.content ||
          ((statSync(full).mode & 0o111) !== 0) !== o.executable
        );
      })
      .map(o => `overlay not synced: overlays/${o.profile}/${o.path} (run kit-sync)`);
  } catch (e) {
    return [String((e as Error).message)];
  }
}

/** Source-free check of a committed kit: manifest <-> profiles files, overlay copies, order and leaks. */
export function verifyKit(out: string): string[] {
  const mf = join(out, 'manifest.json');
  if (!existsSync(mf)) return [`${mf}: missing`];
  const manifest = JSON.parse(readFileSync(mf, 'utf8')) as { files: ManifestEntry[] };
  const problems: string[] = [];
  const listed = new Set<string>();
  const files: { profile: string; path: string; content: string }[] = [];
  let prev: { rank: number; path: string } | null = null;
  for (const f of manifest.files) {
    const key = `${f.profile}/${f.path}`;
    // Profile order compares by index as a number (a string compare puts 10 before 9).
    const rank = (PROFILES as readonly string[]).indexOf(f.profile);
    if (rank < 0) problems.push(`manifest: ${key} names an unknown profile ${f.profile}`);
    else {
      if (prev !== null && (rank < prev.rank || (rank === prev.rank && f.path <= prev.path)))
        problems.push(`manifest: ${key} is out of order`);
      prev = { rank, path: f.path };
    }
    listed.add(key);
    const content = verifyEntry(out, f, problems);
    if (content !== null) files.push({ profile: f.profile, path: f.path, content });
  }
  for (const p of walk(join(out, 'profiles')))
    if (!listed.has(p)) problems.push(`extra: profiles/${p}`);
  problems.push(...verifyOverlays(out));
  for (const f of leakCheck(files).failures) problems.push(`leak: ${f}`);
  for (const d of judgeDeps(depsCheck(files)).failures) problems.push(`deps: ${d}`);
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
      return !classify(p, '', new Set(src.files.keys())).exclude;
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

interface CliArgs {
  out: string;
  check: boolean;
  verify: boolean;
  source: string;
}

function parseArgs(argv: string[]): CliArgs | string {
  const args: CliArgs = { out: 'kit', check: false, verify: false, source: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i] ?? '';
    if (a === '--check') args.check = true;
    else if (a === '--verify') args.verify = true;
    else if (a === '--out') args.out = argv[++i] ?? '';
    else if (a.startsWith('--')) return `unknown option ${a}`;
    else args.source = a;
  }
  if (!args.verify && !args.source)
    return 'usage: kit-sync.ts <source-repo> [--check] [--out kit] | kit-sync.ts --verify [--out kit]';
  args.out = resolve(args.out);
  return args;
}

function runVerify(out: string): number {
  const problems = verifyKit(out);
  for (const p of problems) console.error(p);
  if (!problems.length) {
    console.log(`kit ok: ${out}`);
    return 0;
  }
  console.error(
    `kit is not consistent (${problems.length}); regenerate with: bun run kit:sync <source-repo>`
  );
  return 1;
}

function runSync(args: CliArgs): number {
  const r = sync(resolve(args.source), args.out, args.check);
  for (const d of r.dirty)
    console.error(`warning: ${d} has uncommitted changes; the kit reads the source's HEAD`);
  for (const w of r.kit.warnings) console.log(`WARN project noun: ${w}`);
  for (const f of r.kit.failures) console.error(`FAIL leak: ${f}`);
  const deps = judgeDeps(depsCheck(r.kit.files));
  for (const d of deps.known) console.log(`WARN deps: ${d}`);
  for (const u of deps.unused)
    console.log(`WARN deps: KNOWN_GAPS entry ${u} matches no gap; remove it`);
  for (const d of deps.failures) console.error(`FAIL deps: ${d}`);
  if (r.kit.failures.length) return 1;
  for (const s of r.stale) console.error(`stale overlay: ${s}`);
  const counts = PROFILES.map(p => `${p} ${r.kit.files.filter(f => f.profile === p).length}`).join(
    ', '
  );
  const at = `${r.kit.source.name}@${r.kit.source.commit.slice(0, 12)}`;
  if (!args.check) {
    console.log(`kit written from ${at}: ${counts}`);
    return 0;
  }
  for (const d of r.drift) console.error(d);
  if (r.drift.length || r.stale.length) {
    console.error(
      `kit drift (${r.drift.length} paths, ${r.stale.length} stale overlays); run: bun run kit:sync ${args.source}`
    );
    return 1;
  }
  console.log(`kit up to date with ${at} (${counts})`);
  return 0;
}

function main(argv: string[]): number {
  const args = parseArgs(argv);
  if (typeof args === 'string') {
    console.error(args);
    return 2;
  }
  return args.verify ? runVerify(args.out) : runSync(args);
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
