/**
 * Tests for `archon kit` against a fixture kit (never the bundled one).
 */
import { afterEach, beforeEach, describe, expect, it, spyOn } from 'bun:test';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
  realpathSync,
} from 'fs';
import { createHash } from 'crypto';
import { tmpdir } from 'os';
import { dirname, join, resolve } from 'path';
import { removeTempTree } from '@archon/paths/test-utils';
import {
  backlogSwitchedOff,
  buildToolchain,
  checkTools,
  kitCommand,
  kitToolsCommand,
  applySetOverrides,
  checkFileHooks,
  checkMcpServers,
  checkTrust,
  coerceScalar,
  enableFileHooks,
  shellQuote,
  unsafeManifestPath,
  computeDrift,
  existingFileState,
  flattenKitConfig,
  kitAddCommand,
  readKitLock,
  mergeAliases,
  renderTemplate,
  resolveProfiles,
  templateVars,
  trustFolder,
  type DoctorCheck,
  type Kit,
} from './kit';
import * as validateRoute from './validate';
import * as routeLoader from '../routes/route-loader';

const sha = (t: string): string => createHash('sha256').update(t).digest('hex');

function makeKit(): Kit {
  const files: Record<string, string> = {
    'core/README.md': '# core\n',
    'core/scripts/run.sh': '#!/bin/bash\necho hi\n',
    'core/.github/agent.md':
      'dir @@KIT_PROJECT_DIR@@ repo @@KIT_CONTRACT_REPO@@ branches @@KIT_BRANCHES@@ none @@KIT_NOPE@@\n',
    'java/README.md': '# java wins\n',
    'java/src.txt': 'java file\n',
    'spring/s.txt': 'spring\n',
    'micronaut/q.txt': 'micronaut\n',
  };
  const meta: Record<string, { mode?: string; template?: boolean }> = {
    'core/scripts/run.sh': { mode: '0755' },
    'core/.github/agent.md': { template: true },
  };
  return {
    manifest: {
      version: 1,
      source: { name: 'fixture', commit: 'abcdef0123' },
      profiles: {
        core: { requires: [], description: 'core profile' },
        java: { requires: ['core'], description: 'java profile' },
        spring: { requires: ['java'], description: 'spring' },
        micronaut: { requires: ['java'], description: 'micronaut' },
      },
      exclusive: [['spring', 'micronaut']],
      files: Object.entries(files).map(([key, content]) => {
        const [profile, ...rest] = key.split('/');
        return {
          path: rest.join('/'),
          profile,
          mode: meta[key]?.mode ?? '0644',
          template: meta[key]?.template ?? false,
          origin: null,
          kind: 'config',
          sha256: sha(content),
        };
      }),
      aliases: { '@scout': { provider: 'copilot', model: 'claude-haiku-5.5' } },
      postInstall: [
        { profile: 'core', run: 'echo post-core > post.txt', optional: false },
        { profile: 'micronaut', run: 'echo never > never.txt', optional: false },
        { profile: 'core', run: 'exit 3', optional: true },
      ],
    },
    defaults:
      '# defaults\nprofiles: [core]\nbase_branch: main\ncontract:\n  repo: ""\nbranches: [a, b]\n',
    files,
  };
}

function addFile(kit: Kit, profile: string, path: string, content: string): void {
  kit.files[`${profile}/${path}`] = content;
  kit.manifest.files.push({
    path,
    profile,
    mode: '0644',
    template: false,
    origin: null,
    kind: 'config',
    sha256: sha(content),
  });
}

/** The kit's real dispatch.sh, which the user hook runs. */
const DISPATCH_SH = readFileSync(
  resolve(dirname(import.meta.path), '../../../../kit/profiles/core/.github/hooks/dispatch.sh'),
  'utf-8'
);

function gitRepo(dir: string): string {
  const r = Bun.spawnSync(['git', 'init', '-q', dir]);
  expect(r.exitCode).toBe(0);
  return dir;
}

describe('kit', () => {
  let root: string;
  let project: string;
  let home: string;
  let env: NodeJS.ProcessEnv;
  let logs: string[];

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'archon-kit-test-'));
    project = gitRepo(join(root, 'proj'));
    home = join(root, 'copilot-home');
    env = { ...process.env, COPILOT_HOME: home };
    logs = [];
    spyOn(console, 'log').mockImplementation((...a: unknown[]) => void logs.push(a.join(' ')));
    spyOn(console, 'warn').mockImplementation((...a: unknown[]) => void logs.push(a.join(' ')));
    spyOn(console, 'error').mockImplementation((...a: unknown[]) => void logs.push(a.join(' ')));
  });

  afterEach(async () => {
    await removeTempTree(root);
  });

  const add = (opts: Parameters<typeof kitAddCommand>[1] = {}, kit = makeKit()) =>
    kitAddCommand(
      project,
      { noTools: true, noPostInstall: true, skipValidate: true, env, ...opts },
      kit
    );

  describe('profile resolution', () => {
    it('expands requires and orders by manifest', () => {
      expect(resolveProfiles(makeKit(), ['spring'])).toEqual(['core', 'java', 'spring']);
    });
    it('rejects exclusive combos', () => {
      expect(() => resolveProfiles(makeKit(), ['spring', 'micronaut'])).toThrow(
        /mutually exclusive/
      );
    });
    it('lists valid profiles for an unknown one', () => {
      expect(() => resolveProfiles(makeKit(), ['nope'])).toThrow(/core, java, spring, micronaut/);
    });
    it('add fails on unknown profile and non-git dirs', async () => {
      expect(await add({ profiles: ['nope'] })).toBe(1);
      const plain = join(root, 'plain');
      mkdirSync(plain);
      expect(await kitAddCommand(plain, { env }, makeKit())).toBe(1);
      expect(logs.join('\n')).toContain('not a git repository');
    });
  });

  describe('placeholders', () => {
    it('flattens nested keys and joins lists', () => {
      expect(
        flattenKitConfig({ base_branch: 'main', contract: { repo: 'a/b' }, l: ['x', 'y'] })
      ).toEqual({
        BASE_BRANCH: 'main',
        CONTRACT_REPO: 'a/b',
        L: 'x, y',
      });
    });
    it('renders missing keys empty and records them', () => {
      const missing = new Set<string>();
      expect(renderTemplate('a @@KIT_X@@ b @@KIT_Y@@ @@KIT_Y@@', { X: '1' }, missing)).toBe(
        'a 1 b  '
      );
      expect([...missing]).toEqual(['Y']);
    });
    it('keeps a profile-marked line for an installed profile and drops it for another', () => {
      const missing = new Set<string>();
      const text =
        'a\n- x @@KIT_IF_PROFILE_JAVA@@\n- y@@KIT_IF_PROFILE_SPRING@@ @@KIT_X@@\nb @@KIT_X@@';
      expect(renderTemplate(text, { X: '1', IF_PROFILE_JAVA: '' }, missing)).toBe('a\n- x \nb 1');
      expect([...missing]).toEqual([]);
    });
    it('gives each installed profile, with the ones it requires, an IF_PROFILE variable', () => {
      const kit = makeKit();
      const vars = templateVars(project, kit, 'profiles: [spring]\n', null);
      expect(
        Object.keys(vars)
          .filter(k => k.startsWith('IF_PROFILE_'))
          .sort()
      ).toEqual(['IF_PROFILE_CORE', 'IF_PROFILE_JAVA', 'IF_PROFILE_SPRING']);
      expect(
        renderTemplate(
          'q @@KIT_IF_PROFILE_MICRONAUT@@\ns @@KIT_IF_PROFILE_SPRING@@\n',
          vars,
          new Set()
        )
      ).toBe('s \n');
    });
    it('renders template files on add and warns once per missing key', async () => {
      expect(await add({ set: ['contract.repo=acme/contract'] })).toBe(0);
      expect(readFileSync(join(project, '.github/agent.md'), 'utf-8')).toBe(
        `dir ${realpathSync(project)} repo acme/contract branches a, b none \n`
      );
      expect(logs.filter(l => l.includes('@@KIT_NOPE@@'))).toHaveLength(1);
      expect(logs.some(l => l.includes('PROJECT_DIR'))).toBe(false);
    });
  });

  describe('writing', () => {
    it('writes kit.yaml from defaults with profiles and keeps comments', async () => {
      expect(await add({ profiles: ['java'], set: ['base_branch=develop'] })).toBe(0);
      const text = readFileSync(join(project, '.archon/kit.yaml'), 'utf-8');
      expect(text).toContain('# defaults');
      expect(text).toContain('base_branch: develop');
      expect(text).toMatch(/profiles:\s*\n?\s*(- core|\[)/);
      expect(applySetOverrides(text, ['contract.repo=x/y'])).toMatch(/repo: "?x\/y"?/);
    });
    it('renders a key missing from an existing kit.yaml from the kit defaults', async () => {
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(join(project, '.archon/kit.yaml'), 'contract:\n  repo: acme/mine\n');
      expect(await add({ force: true })).toBe(0);
      expect(readFileSync(join(project, '.github/agent.md'), 'utf-8')).toBe(
        `dir ${realpathSync(project)} repo acme/mine branches a, b none \n`
      );
      expect(readFileSync(join(project, '.archon/kit.yaml'), 'utf-8')).toBe(
        'contract:\n  repo: acme/mine\n'
      );
      expect(logs.some(l => l.includes('@@KIT_BRANCHES@@'))).toBe(false);
    });
    it('records --profile in an existing kit.yaml, keeping its own text', async () => {
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(join(project, '.archon/kit.yaml'), '# mine\nbase_branch: dev\n');
      expect(await add({ profiles: ['java'] })).toBe(0);
      const text = readFileSync(join(project, '.archon/kit.yaml'), 'utf-8');
      expect(text).toContain('# mine');
      expect(text).toContain('base_branch: dev');
      expect(text).toMatch(/profiles:/);
      expect(text).toContain('java');
    });
    it('later profile wins, modes apply, rerun is unchanged', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# java wins\n');
      expect(statSync(join(project, 'scripts/run.sh')).mode & 0o111).not.toBe(0);
      logs.length = 0;
      expect(await add()).toBe(0);
      expect(logs.join('\n')).toContain('0 written');
    });
    it('gives an unchanged executable its mode back, and leaves an unchanged plain file alone', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      chmodSync(join(project, 'scripts/run.sh'), 0o644);
      logs.length = 0;
      expect(await add({ dryRun: true })).toBe(0);
      expect(statSync(join(project, 'scripts/run.sh')).mode & 0o111).toBe(0);
      expect(logs.join('\n')).toContain('1 would be written');
      logs.length = 0;
      expect(await add()).toBe(0);
      expect(statSync(join(project, 'scripts/run.sh')).mode & 0o111).not.toBe(0);
      expect(statSync(join(project, 'README.md')).mode & 0o111).toBe(0);
      expect(logs.join('\n')).toContain('1 written');
      logs.length = 0;
      expect(await add()).toBe(0);
      expect(logs.join('\n')).toContain('0 written');
    });
    it('updates a file it wrote that the project never edited, keeps one the project edited', async () => {
      await add({ profiles: ['java'] });
      writeFileSync(join(project, 'src.txt'), 'my edit\n');
      const newer = makeKit();
      for (const key of ['java/README.md', 'java/src.txt']) newer.files[key] = 'newer kit\n';
      for (const f of newer.manifest.files) f.sha256 = sha(newer.files[`${f.profile}/${f.path}`]);
      logs.length = 0;
      expect(await add({ profiles: ['java'] }, newer)).toBe(0);
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('newer kit\n');
      expect(readFileSync(join(project, 'src.txt'), 'utf-8')).toBe('my edit\n');
      expect(logs.join('\n')).toContain('kept (differs)  src.txt');
      const lock = readKitLock(project);
      expect(lock['README.md']).toBe(sha('newer kit\n'));
      expect(lock['src.txt']).toBe(sha('java file\n'));
      expect(lock['.archon/kit.yaml']).toBeUndefined();
    });
    it('keeps a differing file unless --force', async () => {
      await add();
      writeFileSync(join(project, 'README.md'), 'mine\n');
      logs.length = 0;
      await add();
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('mine\n');
      expect(logs.join('\n')).toContain('kept (differs)  README.md');
      await add({ force: true });
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# core\n');
    });
    it('writes a create-only file only when the project has none, even with --force', async () => {
      const kit = makeKit();
      kit.files['core/docs/memory.md'] = '# starter\n';
      kit.manifest.files.push({
        path: 'docs/memory.md',
        profile: 'core',
        mode: '0644',
        template: false,
        origin: null,
        kind: 'doc',
        sha256: sha('# starter\n'),
        createOnly: true,
      });
      expect(await add({}, kit)).toBe(0);
      expect(readFileSync(join(project, 'docs/memory.md'), 'utf-8')).toBe('# starter\n');
      writeFileSync(join(project, 'docs/memory.md'), '# ours\n');
      expect(await add({ force: true }, kit)).toBe(0);
      expect(readFileSync(join(project, 'docs/memory.md'), 'utf-8')).toBe('# ours\n');
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# core\n');
      expect(computeDrift(project, kit, ['core']).modified).toEqual([]);
    });
    it('existingFileState: absent writes, equal is unchanged, --force overrides all but create-only', () => {
      const f = join(root, 'f.txt');
      expect(existingFileState(f, 'a', false)).toBeNull();
      writeFileSync(f, 'a');
      expect(existingFileState(f, 'a', true, true)).toBe('unchanged');
      expect(existingFileState(f, 'b', false)).toBe('kept');
      expect(existingFileState(f, 'b', true)).toBeNull();
      expect(existingFileState(f, 'b', true, true)).toBe('kept');
    });
    it('dry-run writes nothing', async () => {
      expect(await add({ dryRun: true, trust: true })).toBe(0);
      expect(existsSync(join(project, 'README.md'))).toBe(false);
      expect(existsSync(join(project, '.archon'))).toBe(false);
      expect(existsSync(join(home, 'config.json'))).toBe(false);
    });
    it('runs post-install for selected profiles, failing on a non-optional failure', async () => {
      expect(await add({ noPostInstall: false })).toBe(0);
      expect(existsSync(join(project, 'post.txt'))).toBe(true);
      expect(existsSync(join(project, 'never.txt'))).toBe(false);
      const kit = makeKit();
      kit.manifest.postInstall = [{ profile: 'core', run: 'exit 2', optional: false }];
      expect(await add({ noPostInstall: false }, kit)).toBe(1);
    });
  });

  describe('aliases', () => {
    it('creates config.yaml with aliases, adds only missing keys, reports conflicts', async () => {
      await add();
      const cfg = join(project, '.archon/config.yaml');
      expect(readFileSync(cfg, 'utf-8')).toContain('@scout');
      writeFileSync(
        cfg,
        '# mine\nassistants:\n  claude:\n    model: sonnet\naliases:\n  "@scout":\n    provider: claude\n    model: x\n'
      );
      logs.length = 0;
      await add();
      const text = readFileSync(cfg, 'utf-8');
      expect(text).toContain('# mine');
      expect(text).toContain('provider: claude');
      expect(logs.join('\n')).toContain('alias @scout already set differently');
    });
    it('merge keeps unrelated content', () => {
      const r = mergeAliases('# top\nfoo: 1\n', makeKit().manifest.aliases);
      expect(r.added).toEqual(['@scout']);
      expect(r.text).toContain('# top');
      expect(r.text).toContain('foo: 1');
    });
  });

  describe('user hooks', () => {
    const DENY_GUARD =
      '#!/usr/bin/env bash\ncat >/dev/null\necho "no way from the guard" >&2\nexit 2\n';
    const guardKit = (withDispatch: boolean): Kit => {
      const kit = makeKit();
      addFile(kit, 'core', '.archon/copilot/hooks/run-guard.sh', DENY_GUARD);
      if (withDispatch) addFile(kit, 'core', '.github/hooks/dispatch.sh', DISPATCH_SH);
      return kit;
    };
    const runHook = (command: string, cwd: string) => {
      const { CLAUDE_PROJECT_DIR: _drop, ...rest } = process.env;
      const r = Bun.spawnSync(['bash', '-c', command], {
        cwd,
        env: rest,
        stdin: Buffer.from(
          JSON.stringify({
            toolName: 'bash',
            toolArgs: { command: 'git push' },
            cwd,
          })
        ),
      });
      return {
        code: r.exitCode,
        out: r.stdout.toString(),
        err: r.stderr.toString(),
      };
    };
    const hookCommand = (): string =>
      (
        JSON.parse(readFileSync(join(home, 'hooks', 'archon-kit-run-guard.json'), 'utf-8')) as {
          hooks: { preToolUse: { bash: string }[] };
        }
      ).hooks.preToolUse[0].bash;

    it('the written user hook runs the guard through dispatch.sh, from any folder, and its deny comes out', async () => {
      project = gitRepo(join(root, "it's proj"));
      expect(await add({ userHooks: true }, guardKit(true))).toBe(0);
      const outside = mkdtempSync(join(root, 'elsewhere-'));
      const result = runHook(hookCommand(), outside);
      expect(result.code).toBe(0);
      const decision = JSON.parse(result.out.trim()) as Record<string, string>;
      expect(decision.permissionDecision).toBe('deny');
      expect(decision.permissionDecisionReason).toContain('no way from the guard');
    });
    it('without dispatch.sh the guard runs itself and its exit 2 comes out', async () => {
      expect(await add({ userHooks: true }, guardKit(false))).toBe(0);
      const result = runHook(hookCommand(), root);
      expect(result.code).toBe(2);
      expect(result.err).toContain('no way from the guard');
    });
    it('a guard that is gone allows', async () => {
      expect(await add({ userHooks: true }, guardKit(true))).toBe(0);
      Bun.spawnSync(['rm', join(project, '.archon/copilot/hooks/run-guard.sh')]);
      expect(runHook(hookCommand(), root)).toMatchObject({ code: 0, out: '' });
    });
    it('shellQuote keeps a quote inside one word', () => {
      const r = Bun.spawnSync(['bash', '-c', `printf %s ${shellQuote("a'b c")}`]);
      expect(r.stdout.toString()).toBe("a'b c");
    });
  });

  describe('kit defaults file', () => {
    it('kit add writes the kit defaults beside kit.yaml, lock-tracked', async () => {
      expect(await add()).toBe(0);
      const kit = makeKit();
      expect(readFileSync(join(project, '.archon/kit.defaults.yaml'), 'utf-8')).toBe(kit.defaults);
      expect(readKitLock(project)['.archon/kit.defaults.yaml']).toBe(sha(kit.defaults));
    });
    it('a rerun updates an unedited copy and keeps an edited one', async () => {
      expect(await add()).toBe(0);
      const newer = makeKit();
      newer.defaults = `${newer.defaults}agent_cli: copilot\n`;
      expect(await add({}, newer)).toBe(0);
      const dest = join(project, '.archon/kit.defaults.yaml');
      expect(readFileSync(dest, 'utf-8')).toBe(newer.defaults);
      writeFileSync(dest, 'mine: 1\n');
      const newest = makeKit();
      newest.defaults = `${newest.defaults}agent_cli: claude\n`;
      expect(await add({}, newest)).toBe(0);
      expect(readFileSync(dest, 'utf-8')).toBe('mine: 1\n');
    });
  });

  describe('java_version follows the build toolchain', () => {
    /** A kit whose defaults say java_version 21 and whose ci.yml renders it. */
    const javaKit = (): Kit => {
      const kit = makeKit();
      kit.defaults = `${kit.defaults}java_version: 21\n`;
      addFile(kit, 'core', 'ci.yml', "java-version: '@@KIT_JAVA_VERSION@@'\n");
      const entry = kit.manifest.files.find(f => f.path === 'ci.yml');
      if (entry) entry.template = true;
      return kit;
    };
    const toolchain = (rel: string, n: number): void => {
      mkdirSync(dirname(join(project, rel)), { recursive: true });
      writeFileSync(
        join(project, rel),
        `java {\n  toolchain {\n    languageVersion.set(JavaLanguageVersion.of(${n}))\n  }\n}\n`
      );
    };
    const kitYaml = (): Record<string, unknown> =>
      Bun.YAML.parse(readFileSync(join(project, '.archon/kit.yaml'), 'utf-8')) as Record<
        string,
        unknown
      >;
    const ci = (): string => readFileSync(join(project, 'ci.yml'), 'utf-8');

    it('a new kit.yaml takes the toolchain of build.gradle.kts, not the defaults', async () => {
      toolchain('build.gradle.kts', 17);
      expect(await add({}, javaKit())).toBe(0);
      expect(kitYaml().java_version).toBe(17);
      expect(ci()).toBe("java-version: '17'\n");
    });
    it('a convention plugin under buildSrc/ names the toolchain too', async () => {
      writeFileSync(join(project, 'build.gradle.kts'), 'plugins { java }\n');
      toolchain('buildSrc/src/main/kotlin/java-conventions.gradle.kts', 25);
      toolchain('buildSrc/build/generated/old.gradle.kts', 11);
      expect(buildToolchain(project)).toEqual({
        version: '25',
        file: 'buildSrc/src/main/kotlin/java-conventions.gradle.kts',
      });
      expect(await add({}, javaKit())).toBe(0);
      expect(ci()).toBe("java-version: '25'\n");
    });
    it('a kit.yaml without the key renders the toolchain and is not given the key', async () => {
      toolchain('build.gradle.kts', 17);
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(join(project, '.archon/kit.yaml'), 'profiles: [core]\n');
      expect(await add({}, javaKit())).toBe(0);
      expect(ci()).toBe("java-version: '17'\n");
      expect(Object.hasOwn(kitYaml(), 'java_version')).toBe(false);
    });
    it('refuses a kit.yaml java_version that is not the toolchain, and writes nothing', async () => {
      toolchain('build.gradle.kts', 17);
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(join(project, '.archon/kit.yaml'), 'profiles: [core]\njava_version: 21\n');
      expect(await add({ force: true }, javaKit())).toBe(1);
      expect(logs.join('\n')).toContain(
        "kit.yaml java_version 21 does not match the build's toolchain, JavaLanguageVersion.of(17) in build.gradle.kts"
      );
      expect(existsSync(join(project, 'ci.yml'))).toBe(false);
      writeFileSync(join(project, '.archon/kit.yaml'), 'profiles: [core]\njava_version: 17\n');
      expect(await add({}, javaKit())).toBe(0);
      expect(ci()).toBe("java-version: '17'\n");
    });
    it('refuses a --set java_version that is not the toolchain', async () => {
      toolchain('build.gradle.kts', 17);
      expect(await add({ set: ['java_version=21'] }, javaKit())).toBe(1);
      expect(existsSync(join(project, 'ci.yml'))).toBe(false);
      expect(await add({ set: ['java_version=17'] }, javaKit())).toBe(0);
    });
    it('a build that names no toolchain keeps the kit.yaml value', async () => {
      expect(buildToolchain(project)).toBeNull();
      expect(await add({}, javaKit())).toBe(0);
      expect(ci()).toBe("java-version: '21'\n");
    });
  });

  describe('project config', () => {
    it('kit add turns the Copilot file hooks on in .archon/config.yaml, keeping the rest', async () => {
      mkdirSync(join(project, '.archon'), { recursive: true });
      const cfg = join(project, '.archon/config.yaml');
      writeFileSync(cfg, '# mine\nassistants:\n  copilot:\n    model: gpt-5 # pinned\nother: 1\n');
      expect(await add()).toBe(0);
      const text = readFileSync(cfg, 'utf-8');
      expect(text).toContain('# mine');
      expect(text).toContain('model: gpt-5 # pinned');
      expect(text).toContain('other: 1');
      const parsed = Bun.YAML.parse(text) as {
        assistants: { copilot: { fileHooks: boolean; model: string } };
      };
      expect(parsed.assistants.copilot).toEqual({
        model: 'gpt-5',
        fileHooks: true,
      });
    });
    it("kit add validates only the project's workflows, never Archon's bundled ones", async () => {
      const kit = makeKit();
      addFile(kit, 'core', '.archon/workflows/w.yaml', 'name: w\n');
      const loader = spyOn(routeLoader, 'loadRoute').mockImplementation(load => load());
      const validate = spyOn(validateRoute, 'validateWorkflowsCommand').mockResolvedValue(0);
      try {
        expect(await add({ skipValidate: false }, kit)).toBe(0);
        expect(validate).toHaveBeenCalledTimes(1);
        expect(validate.mock.calls[0]).toEqual([
          project,
          undefined,
          false,
          { sources: ['project'] },
        ]);
      } finally {
        loader.mockRestore();
        validate.mockRestore();
      }
    });
    it('a fileHooks the project set itself is kept', () => {
      expect(enableFileHooks('assistants:\n  copilot:\n    fileHooks: false\n')).toMatchObject({
        state: 'off',
      });
      expect(enableFileHooks('assistants:\n  copilot:\n    fileHooks: true\n').state).toBe(
        'present'
      );
      expect(enableFileHooks('').text).toContain('fileHooks: true');
    });
  });

  describe('path safety', () => {
    it('refuses absolute, drive, .. and its own paths', () => {
      expect(unsafeManifestPath('/etc/passwd')).not.toBeNull();
      expect(unsafeManifestPath('C:/x')).not.toBeNull();
      expect(unsafeManifestPath('c:x')).not.toBeNull();
      expect(unsafeManifestPath('a/../../x')).not.toBeNull();
      expect(unsafeManifestPath('a\\..\\x')).not.toBeNull();
      expect(unsafeManifestPath('.archon/kit.lock.json')).not.toBeNull();
      expect(unsafeManifestPath('./.archon/kit.yaml')).not.toBeNull();
      expect(unsafeManifestPath('.archon/workflows/x.yaml')).toBeNull();
      expect(unsafeManifestPath('a..b/c')).toBeNull();
    });
    it('kit add refuses a kit with a traversal path and writes nothing', async () => {
      const kit = makeKit();
      addFile(kit, 'core', '../escaped.txt', 'x\n');
      expect(await add({}, kit)).toBe(1);
      expect(existsSync(join(root, 'escaped.txt'))).toBe(false);
      expect(existsSync(join(project, 'README.md'))).toBe(false);
      expect(logs.join('\n')).toContain('a .. segment');
    });
    it('never writes through a symlink, nor into a linked folder outside the project', async () => {
      const outsideFile = join(root, 'outside.txt');
      writeFileSync(outsideFile, 'precious\n');
      symlinkSync(outsideFile, join(project, 'README.md'));
      const outsideDir = join(root, 'outside-dir');
      mkdirSync(outsideDir);
      symlinkSync(outsideDir, join(project, 'scripts'));
      expect(await add()).toBe(0);
      expect(readFileSync(outsideFile, 'utf-8')).toBe('precious\n');
      expect(readdirSync(outsideDir)).toEqual([]);
      const out = logs.join('\n');
      expect(out).toContain('skipped (symlink)  README.md');
      expect(out).toContain('skipped (outside)  scripts/run.sh');
      expect(readKitLock(project)['README.md']).toBeUndefined();
    });
  });

  describe('line ends and the lock', () => {
    it('a CRLF checkout of an unedited file is the kit own: updated, and not drift', async () => {
      await add({ profiles: ['java'] });
      const kit = makeKit();
      writeFileSync(join(project, 'src.txt'), 'java file\r\n');
      expect(computeDrift(project, kit, resolveProfiles(kit, ['java'])).modified).toEqual([]);
      expect(existingFileState(join(project, 'src.txt'), 'java file\n', false)).toBe('unchanged');
      const newer = makeKit();
      newer.files['java/src.txt'] = 'newer kit\n';
      for (const f of newer.manifest.files) f.sha256 = sha(newer.files[`${f.profile}/${f.path}`]);
      expect(await add({ profiles: ['java'] }, newer)).toBe(0);
      expect(readFileSync(join(project, 'src.txt'), 'utf-8')).toBe('newer kit\n');
    });
    it('says once that files from before the lock differ', async () => {
      writeFileSync(join(project, 'README.md'), 'mine\n');
      mkdirSync(join(project, 'scripts'));
      writeFileSync(join(project, 'scripts/run.sh'), 'mine\n');
      expect(await add()).toBe(0);
      const lines = logs.filter(l => l.includes('predate the kit lock'));
      expect(lines).toEqual([
        "2 files predate the kit lock and differ from the kit; review them and rerun with --force to take the kit's version",
      ]);
    });
  });

  describe('the merged .archon/config.yaml', () => {
    const withConfig = (text: string): Kit => {
      const kit = makeKit();
      addFile(kit, 'core', '.archon/config.yaml', text);
      return kit;
    };
    it('is no drift after the alias merge; an edit to it is', async () => {
      const kit = withConfig('# kit config v1 @@KIT_BASE_BRANCH@@\n');
      kit.manifest.files[kit.manifest.files.length - 1].template = true;
      expect(await add({}, kit)).toBe(0);
      const cfg = join(project, '.archon/config.yaml');
      expect(readFileSync(cfg, 'utf-8')).toContain('@scout');
      const vars = templateVars(
        project,
        kit,
        readFileSync(join(project, '.archon/kit.yaml'), 'utf-8'),
        null
      );
      const profiles = resolveProfiles(kit, ['core']);
      expect(computeDrift(project, kit, profiles, vars).modified).toEqual([]);
      writeFileSync(cfg, `${readFileSync(cfg, 'utf-8')}# edited\n`);
      expect(computeDrift(project, kit, profiles, vars).modified).toEqual(['.archon/config.yaml']);
    });
    it('stays the kit own after the alias merge, so a newer kit updates it', async () => {
      expect(await add({}, withConfig('# kit config v1\n'))).toBe(0);
      expect(readFileSync(join(project, '.archon/config.yaml'), 'utf-8')).toContain('@scout');
      logs.length = 0;
      expect(await add({}, withConfig('# kit config v2\n'))).toBe(0);
      const text = readFileSync(join(project, '.archon/config.yaml'), 'utf-8');
      expect(text).toContain('# kit config v2');
      expect(text).toContain('@scout');
      expect(logs.join('\n')).not.toContain('kept (differs)  .archon/config.yaml');
    });
    it('a lock from before holds the unmerged hash: the merged file still counts as the kit own', async () => {
      expect(await add({}, withConfig('# kit config v1\n'))).toBe(0);
      const lockPath = join(project, '.archon/kit.lock.json');
      const lock = JSON.parse(readFileSync(lockPath, 'utf-8')) as { files: Record<string, string> };
      lock.files['.archon/config.yaml'] = sha('# kit config v1\n');
      writeFileSync(lockPath, JSON.stringify(lock));
      logs.length = 0;
      expect(await add({}, withConfig('# kit config v1\n'))).toBe(0);
      expect(logs.join('\n')).not.toContain('kept (differs)  .archon/config.yaml');
      expect(readKitLock(project)['.archon/config.yaml']).toBe(
        sha(readFileSync(join(project, '.archon/config.yaml'), 'utf-8'))
      );
    });
    it('is kept once the project edited it', async () => {
      expect(await add({}, withConfig('# kit config v1\n'))).toBe(0);
      const path = join(project, '.archon/config.yaml');
      writeFileSync(path, `${readFileSync(path, 'utf-8')}# mine\n`);
      logs.length = 0;
      expect(await add({}, withConfig('# kit config v2\n'))).toBe(0);
      expect(readFileSync(path, 'utf-8')).toContain('# mine');
      expect(logs.join('\n')).toContain('kept (differs)  .archon/config.yaml');
    });
  });

  describe("the repo's own files", () => {
    const own = 'docs/scaffold-templates/project/domain/id.mustache';
    it('refuses a kit that ships into docs/scaffold-templates/project/ and writes nothing', async () => {
      const kit = makeKit();
      addFile(kit, 'core', own, 'kit text\n');
      expect(unsafeManifestPath(own)).not.toBeNull();
      expect(unsafeManifestPath('./docs/scaffold-templates/project/x')).not.toBeNull();
      expect(unsafeManifestPath('docs/scaffold-templates/domain/id.mustache')).toBeNull();
      expect(await add({ force: true }, kit)).toBe(1);
      expect(existsSync(join(project, own))).toBe(false);
      expect(existsSync(join(project, 'README.md'))).toBe(false);
      expect(logs.join('\n')).toContain("the repo's own scaffold templates");
    });
    it('never removes a file there, not even one the lock lists unedited and with --force', async () => {
      expect(await add()).toBe(0);
      mkdirSync(join(project, dirname(own)), { recursive: true });
      writeFileSync(join(project, own), 'mine\n');
      const lockPath = join(project, '.archon/kit.lock.json');
      const lock = JSON.parse(readFileSync(lockPath, 'utf-8')) as { files: Record<string, string> };
      lock.files[own] = sha('mine\n');
      writeFileSync(lockPath, JSON.stringify(lock));
      expect(await add({ force: true })).toBe(0);
      expect(readFileSync(join(project, own), 'utf-8')).toBe('mine\n');
    });
    it('never touches a file the manifest does not ship, edited or not, with or without --force', async () => {
      mkdirSync(join(project, 'docs/scaffold-templates/project/domain'), { recursive: true });
      writeFileSync(join(project, own), 'mine\n');
      writeFileSync(join(project, 'notes.md'), 'notes\n');
      for (const force of [false, true]) {
        expect(await add({ profiles: ['java'], force })).toBe(0);
        expect(readFileSync(join(project, own), 'utf-8')).toBe('mine\n');
        expect(readFileSync(join(project, 'notes.md'), 'utf-8')).toBe('notes\n');
        expect(Object.keys(readKitLock(project))).not.toContain('notes.md');
      }
      expect(await add({ profiles: ['core'] })).toBe(0);
      expect(readFileSync(join(project, 'notes.md'), 'utf-8')).toBe('notes\n');
    });

    // A project profile (manifest `project: true`) carries one repo's own templates: it alone may write there.
    const withProject = (text: string): Kit => {
      const kit = makeKit();
      kit.manifest.profiles.repo = { requires: ['java'], description: 'one repo', project: true };
      addFile(kit, 'repo', own, text);
      return kit;
    };
    it('a project profile writes there, replaces an unedited file and keeps an edited one', async () => {
      expect(unsafeManifestPath(own, true)).toBeNull();
      expect(unsafeManifestPath('../x', true)).not.toBeNull();
      expect(await add({ profiles: ['repo'] }, withProject('v1\n'))).toBe(0);
      expect(readFileSync(join(project, own), 'utf-8')).toBe('v1\n');
      expect(readKitLock(project)[own]).toBe(sha('v1\n'));
      expect(await add({ profiles: ['repo'] }, withProject('v2\n'))).toBe(0);
      expect(readFileSync(join(project, own), 'utf-8')).toBe('v2\n');
      writeFileSync(join(project, own), 'mine\n');
      logs.length = 0;
      expect(await add({ profiles: ['repo'] }, withProject('v3\n'))).toBe(0);
      expect(readFileSync(join(project, own), 'utf-8')).toBe('mine\n');
      expect(logs.join('\n')).toContain(`kept (differs)  ${own}`);
    });
    it('the same path from a profile that is no project profile is still refused', async () => {
      const kit = withProject('v1\n');
      kit.manifest.profiles.repo.project = false;
      expect(await add({ profiles: ['repo'], force: true }, kit)).toBe(1);
      expect(existsSync(join(project, own))).toBe(false);
    });
    it('leaving the project profile out removes none of its files, unedited ones included', async () => {
      expect(await add({ profiles: ['repo'] }, withProject('v1\n'))).toBe(0);
      expect(await add({ profiles: ['java'], force: true }, withProject('v1\n'))).toBe(0);
      expect(readFileSync(join(project, own), 'utf-8')).toBe('v1\n');
    });
  });

  describe('files the kit no longer ships', () => {
    const without = (kit: Kit, key: string): Kit => {
      delete kit.files[key];
      kit.manifest.files = kit.manifest.files.filter(f => `${f.profile}/${f.path}` !== key);
      return kit;
    };
    it('removes an unedited one and the folders it leaves empty, and drops its lock entry', async () => {
      const first = makeKit();
      addFile(first, 'core', 'old/deep/gone.sh', 'old\n');
      expect(await add({}, first)).toBe(0);
      expect(existsSync(join(project, 'old/deep/gone.sh'))).toBe(true);
      logs.length = 0;
      expect(await add({}, makeKit())).toBe(0);
      expect(existsSync(join(project, 'old'))).toBe(false);
      expect(readKitLock(project)['old/deep/gone.sh']).toBeUndefined();
      expect(logs.join('\n')).toContain('removed  old/deep/gone.sh');
      expect(logs.join('\n')).toContain('1 removed (no longer in the kit)');
    });
    it('keeps an edited one, lists it on every run, and forgets it once the project removed it', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      writeFileSync(join(project, 'src.txt'), 'my edit\n');
      const newer = (): Kit => without(makeKit(), 'java/src.txt');
      for (let run = 0; run < 2; run++) {
        logs.length = 0;
        expect(await add({ profiles: ['java'], force: true }, newer())).toBe(0);
        expect(readFileSync(join(project, 'src.txt'), 'utf-8')).toBe('my edit\n');
        expect(logs.join('\n')).toContain('kept (no longer in the kit)  src.txt');
        expect(readKitLock(project)['src.txt']).toBe(sha('java file\n'));
      }
      unlinkSync(join(project, 'src.txt'));
      expect(await add({ profiles: ['java'] }, newer())).toBe(0);
      expect(readKitLock(project)['src.txt']).toBeUndefined();
    });
    it('a dry run says what it would remove and removes nothing', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      logs.length = 0;
      expect(
        await add({ profiles: ['java'], dryRun: true }, without(makeKit(), 'java/src.txt'))
      ).toBe(0);
      expect(existsSync(join(project, 'src.txt'))).toBe(true);
      expect(logs.join('\n')).toContain('would be removed  src.txt');
      expect(readKitLock(project)['src.txt']).toBe(sha('java file\n'));
    });
    it('leaving a profile out removes its untouched files', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      expect(await add({ profiles: ['core'] })).toBe(0);
      expect(existsSync(join(project, 'src.txt'))).toBe(false);
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# core\n');
    });
    it('never removes through a symlink, nor a lock path outside the project', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      const outside = join(root, 'outside.txt');
      writeFileSync(outside, 'java file\n');
      unlinkSync(join(project, 'src.txt'));
      symlinkSync(outside, join(project, 'src.txt'));
      const lockPath = join(project, '.archon/kit.lock.json');
      const lock = JSON.parse(readFileSync(lockPath, 'utf-8')) as { files: Record<string, string> };
      lock.files['../outside.txt'] = sha('java file\n');
      writeFileSync(lockPath, JSON.stringify(lock));
      expect(await add({ profiles: ['java'] }, without(makeKit(), 'java/src.txt'))).toBe(0);
      expect(readFileSync(outside, 'utf-8')).toBe('java file\n');
      expect(logs.join('\n')).toContain('skipped (symlink)  src.txt');
    });
  });

  describe('the local_ci switch (manifest when)', () => {
    /** The kit with one local-CI file, switched by local_ci, which the defaults turn on. */
    const ciKit = (): Kit => {
      const kit = makeKit();
      addFile(kit, 'core', 'ci/local.sh', 'local ci\n');
      kit.manifest.files[kit.manifest.files.length - 1].when = 'local_ci';
      kit.defaults += 'local_ci: true\n';
      return kit;
    };
    const ciFile = () => join(project, 'ci/local.sh');
    it('the default writes the switched file', async () => {
      expect(await add({}, ciKit())).toBe(0);
      expect(readFileSync(ciFile(), 'utf-8')).toBe('local ci\n');
      expect(readKitLock(project)['ci/local.sh']).toBe(sha('local ci\n'));
    });
    it('local_ci false writes none of the switched files and every other file', async () => {
      expect(await add({ set: ['local_ci=false'] }, ciKit())).toBe(0);
      expect(existsSync(ciFile())).toBe(false);
      expect(readKitLock(project)['ci/local.sh']).toBeUndefined();
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# core\n');
      expect(existsSync(join(project, 'scripts/run.sh'))).toBe(true);
    });
    it("reads the project's kit.yaml, not only --set", async () => {
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(join(project, '.archon/kit.yaml'), 'profiles: [core]\nlocal_ci: false\n');
      expect(await add({}, ciKit())).toBe(0);
      expect(existsSync(ciFile())).toBe(false);
    });
    it('reads a quoted or upper-case false as off, as the runtime scripts do', async () => {
      mkdirSync(join(project, '.archon'), { recursive: true });
      for (const value of ['"false"', "'False'", 'FALSE']) {
        writeFileSync(join(project, '.archon/kit.yaml'), `profiles: [core]\nlocal_ci: ${value}\n`);
        expect(await add({}, ciKit())).toBe(0);
        expect(existsSync(ciFile())).toBe(false);
      }
      expect(await add({ set: ['local_ci=False'] }, ciKit())).toBe(0);
      expect(existsSync(ciFile())).toBe(false);
    });
    it('a kit whose defaults leave the key out ships the file', async () => {
      const kit = ciKit();
      kit.defaults = makeKit().defaults;
      expect(await add({}, kit)).toBe(0);
      expect(existsSync(ciFile())).toBe(true);
    });
    it('doctor does not report a switched-off file missing', async () => {
      expect(await add({}, ciKit())).toBe(0);
      unlinkSync(ciFile());
      const yaml = join(project, '.archon/kit.yaml');
      writeFileSync(yaml, readFileSync(yaml, 'utf-8').replace('local_ci: true', 'local_ci: false'));
      const kit = ciKit();
      const drift = computeDrift(project, kit, resolveProfiles(kit, ['core']));
      expect(drift.missing).toEqual([]);
      expect(drift.modified).toEqual([]);
    });
    it('doctor still reports it missing while the switch is on', async () => {
      expect(await add({}, ciKit())).toBe(0);
      unlinkSync(ciFile());
      const kit = ciKit();
      expect(computeDrift(project, kit, resolveProfiles(kit, ['core'])).missing).toEqual([
        'ci/local.sh',
      ]);
    });
    it('switching off prunes the unedited file and keeps an edited one', async () => {
      expect(await add({}, ciKit())).toBe(0);
      expect(await add({ set: ['local_ci=false'] }, ciKit())).toBe(0);
      expect(existsSync(ciFile())).toBe(false);
      expect(await add({ set: ['local_ci=true'] }, ciKit())).toBe(0);
      expect(existsSync(ciFile())).toBe(true);
      writeFileSync(ciFile(), 'my ci\n');
      logs.length = 0;
      expect(await add({ set: ['local_ci=false'], force: true }, ciKit())).toBe(0);
      expect(readFileSync(ciFile(), 'utf-8')).toBe('my ci\n');
      expect(logs.join('\n')).toContain('kept (no longer in the kit)  ci/local.sh');
    });
  });

  describe('--set', () => {
    it('keeps numbers-looking values as strings; coerces only booleans and lists', () => {
      expect(coerceScalar('20.10')).toBe('20.10');
      expect(coerceScalar('010')).toBe('010');
      expect(coerceScalar('true')).toBe(true);
      expect(coerceScalar('false')).toBe(false);
      expect(coerceScalar('[a, b]')).toEqual(['a', 'b']);
      expect(coerceScalar('null')).toBe('null');
      expect(applySetOverrides('node: x\n', ['node=20.10'])).toMatch(/node: "20\.10"/);
    });
    it('--set profiles= picks the profiles of the same run', async () => {
      expect(await add({ set: ['profiles=[java]'] })).toBe(0);
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# java wins\n');
      const yaml = Bun.YAML.parse(readFileSync(join(project, '.archon/kit.yaml'), 'utf-8')) as {
        profiles: string[];
      };
      expect(yaml.profiles).toEqual(['core', 'java']);
      expect(await add({ profiles: ['core'], set: ['profiles=java'] })).toBe(1);
      expect(logs.join('\n')).toContain('not both');
    });
  });

  describe('trust', () => {
    it('merges trustedFolders and preserves other keys', () => {
      mkdirSync(home, { recursive: true });
      const cfg = join(home, 'config.json');
      writeFileSync(cfg, JSON.stringify({ theme: 'dark', trustedFolders: ['/a'] }));
      expect(trustFolder(cfg, '/b')).toBe('added');
      expect(trustFolder(cfg, '/b')).toBe('present');
      expect(JSON.parse(readFileSync(cfg, 'utf-8'))).toEqual({
        theme: 'dark',
        trustedFolders: ['/a', '/b'],
      });
    });
    it('an empty trustedFolders does not hide trusted_folders, and the write leaves no temp file', () => {
      mkdirSync(home, { recursive: true });
      writeFileSync(
        join(home, 'config.json'),
        JSON.stringify({ trustedFolders: [], trusted_folders: [project] })
      );
      expect(checkTrust(project, env).status).toBe('ok');
      expect(trustFolder(join(home, 'config.json'), '/c')).toBe('added');
      expect(readdirSync(home)).toEqual(['config.json']);
    });
    it('--trust creates the file under COPILOT_HOME', async () => {
      await add({ trust: true });
      expect(JSON.parse(readFileSync(join(home, 'config.json'), 'utf-8')).trustedFolders).toEqual([
        resolve(project),
      ]);
    });
  });

  describe('tools', () => {
    it('errors when the script is missing, else runs it with --check and returns its code', async () => {
      expect(await kitToolsCommand(project)).toBe(1);
      expect(logs.join('\n')).toContain('install-tools.sh');
      mkdirSync(join(project, 'scripts'));
      writeFileSync(
        join(project, 'scripts/install-tools.sh'),
        'echo "args:$*" > args.txt\n[ "$1" = "--check" ] && exit 4\nexit 0\n'
      );
      expect(await kitToolsCommand(project)).toBe(0);
      expect(readFileSync(join(project, 'args.txt'), 'utf-8').trim()).toBe('args:');
      expect(await kitToolsCommand(project, { check: true })).toBe(4);
      expect(readFileSync(join(project, 'args.txt'), 'utf-8').trim()).toBe('args:--check');
    });
    it("without a project installer runs the kit's bundled one from a temp folder it removes", async () => {
      const plain = mkdtempSync(join(root, 'no-kit-'));
      const kit = makeKit();
      kit.files['core/scripts/install-tools.sh'] =
        'echo "args:$* conf:$(cat "$PROJECT_DIR/scripts/tools.conf") home:$PROJECT_DIR" > ran.txt\nexit 0\n';
      kit.files['core/scripts/tools.conf'] = 'jq 1.7\n';
      expect(await kitToolsCommand(plain, { check: true, kit })).toBe(0);
      const ran = readFileSync(join(plain, 'ran.txt'), 'utf-8').trim();
      expect(ran).toStartWith('args:--check conf:jq 1.7 home:');
      expect(existsSync(ran.split('home:')[1])).toBe(false);
      expect(await kitToolsCommand(plain, { kit: makeKit() })).toBe(1);
    });
    it('--no-backlog runs the installer with INSTALL_TOOLS_BACKLOG=0, and leaves it unset without', async () => {
      mkdirSync(join(project, 'scripts'));
      writeFileSync(
        join(project, 'scripts/install-tools.sh'),
        'echo "backlog:${INSTALL_TOOLS_BACKLOG-unset}" > env.txt\n'
      );
      const saved = process.env.INSTALL_TOOLS_BACKLOG;
      delete process.env.INSTALL_TOOLS_BACKLOG;
      try {
        expect(await kitCommand('tools', project, root, { noBacklog: true })).toBe(0);
        expect(readFileSync(join(project, 'env.txt'), 'utf-8').trim()).toBe('backlog:0');
        expect(await kitCommand('tools', project, root, {})).toBe(0);
        expect(readFileSync(join(project, 'env.txt'), 'utf-8').trim()).toBe('backlog:unset');
      } finally {
        if (saved !== undefined) process.env.INSTALL_TOOLS_BACKLOG = saved;
      }
    });
  });

  describe('doctor pieces', () => {
    it('reports the Copilot fileHooks switch in .archon/config.yaml', () => {
      expect(checkFileHooks(project)).toMatchObject({ status: 'warn', name: 'fileHooks' });
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(
        join(project, '.archon/config.yaml'),
        'assistants:\n  copilot:\n    model: x\n'
      );
      const unset = checkFileHooks(project);
      expect(unset.status).toBe('warn');
      expect(unset.detail).toContain('is not set');
      writeFileSync(
        join(project, '.archon/config.yaml'),
        'assistants:\n  copilot:\n    fileHooks: false\n'
      );
      expect(checkFileHooks(project)).toMatchObject({ status: 'warn' });
      expect(checkFileHooks(project).detail).toContain('is false');
      writeFileSync(
        join(project, '.archon/config.yaml'),
        'assistants:\n  copilot:\n    fileHooks: true\n'
      );
      expect(checkFileHooks(project)).toMatchObject({ status: 'ok', name: 'fileHooks' });
      writeFileSync(join(project, '.archon/config.yaml'), 'assistants: [\n');
      expect(checkFileHooks(project).detail).toContain('does not parse');
    });
    it('checks backlog unless kit.yaml (or the kit defaults) switches it off', () => {
      const backlog = (): DoctorCheck | undefined =>
        checkTools(project, { PATH: '' }).find(c => c.name === 'backlog');
      expect(backlog()).toMatchObject({ status: 'fail', detail: 'not found on PATH' });
      mkdirSync(join(project, '.archon'), { recursive: true });
      writeFileSync(join(project, '.archon/kit.defaults.yaml'), 'backlog: false\n');
      expect(backlogSwitchedOff(project)).toBe('.archon/kit.defaults.yaml');
      writeFileSync(join(project, '.archon/kit.yaml'), 'backlog: true\n');
      expect(backlog()?.status).toBe('fail');
      writeFileSync(join(project, '.archon/kit.yaml'), 'profiles: [core]\nbacklog: false\n');
      expect(backlog()).toEqual({
        status: 'skip',
        name: 'backlog',
        detail: 'off (backlog: false in .archon/kit.yaml)',
      });
    });
    it('probes a stdio MCP server and counts tools; reports a broken one', async () => {
      mkdirSync(join(project, '.github'), { recursive: true });
      const server = resolve(dirname(import.meta.path), 'fixtures/kit-mcp-server.js');
      writeFileSync(
        join(project, '.github/mcp.json'),
        JSON.stringify({
          mcpServers: {
            good: { command: process.execPath, args: [server] },
            bad: { command: process.execPath, args: ['-e', 'process.exit(1)'] },
          },
        })
      );
      const checks = await checkMcpServers(project, 10000);
      expect(checks.find(c => c.name === 'mcp good')).toMatchObject({
        status: 'ok',
        detail: '2 tools',
      });
      expect(checks.find(c => c.name === 'mcp bad')?.status).toBe('fail');
    });
    it('reports drift as modified and missing', async () => {
      await add({ profiles: ['java'] });
      writeFileSync(join(project, 'README.md'), 'changed\n');
      chmodSync(join(project, 'scripts/run.sh'), 0o755);
      unlinkSync(join(project, 'src.txt'));
      const kit = makeKit();
      const drift = computeDrift(project, kit, resolveProfiles(kit, ['java']));
      expect(drift.modified).toEqual(['README.md']);
      expect(drift.missing).toEqual(['src.txt']);
      expect(drift.checked).toBe(4);
    });
    it('checks a template as kit add rendered it, and skips templates without vars', async () => {
      await add({ profiles: ['java'] });
      const kit = makeKit();
      const profiles = resolveProfiles(kit, ['java']);
      const vars = templateVars(
        project,
        kit,
        readFileSync(join(project, '.archon/kit.yaml'), 'utf-8'),
        null
      );
      expect(computeDrift(project, kit, profiles, vars)).toMatchObject({
        modified: [],
        checked: 5,
      });
      writeFileSync(join(project, '.github/agent.md'), 'an older generator wrote this\n');
      expect(computeDrift(project, kit, profiles, vars).modified).toEqual(['.github/agent.md']);
      expect(computeDrift(project, kit, profiles)).toMatchObject({ modified: [], checked: 4 });
    });
    it('reports the defaults file beside kit.yaml as drift once edited', async () => {
      await add({ profiles: ['java'] });
      const kit = makeKit();
      writeFileSync(join(project, '.archon/kit.defaults.yaml'), 'edited: 1\n');
      expect(computeDrift(project, kit, resolveProfiles(kit, ['java'])).modified).toEqual([
        '.archon/kit.defaults.yaml',
      ]);
    });
  });
});
