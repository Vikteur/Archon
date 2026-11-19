/**
 * Tests for `archon kit` against a fixture kit (never the bundled one).
 */
import { afterEach, beforeEach, describe, expect, it, spyOn } from 'bun:test';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  statSync,
  writeFileSync,
  realpathSync,
} from 'fs';
import { createHash } from 'crypto';
import { tmpdir } from 'os';
import { dirname, join, resolve } from 'path';
import { removeTempTree } from '@archon/paths/test-utils';
import {
  kitToolsCommand,
  applySetOverrides,
  checkMcpServers,
  computeDrift,
  flattenKitConfig,
  kitAddCommand,
  mergeAliases,
  renderTemplate,
  resolveProfiles,
  trustFolder,
  type Kit,
} from './kit';

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
    'quarkus/q.txt': 'quarkus\n',
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
        quarkus: { requires: ['java'], description: 'quarkus' },
      },
      exclusive: [['spring', 'quarkus']],
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
        { profile: 'quarkus', run: 'echo never > never.txt', optional: false },
        { profile: 'core', run: 'exit 3', optional: true },
      ],
    },
    defaults:
      '# defaults\nprofiles: [core]\nbase_branch: main\ncontract:\n  repo: ""\nbranches: [a, b]\n',
    files,
  };
}

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
      expect(() => resolveProfiles(makeKit(), ['spring', 'quarkus'])).toThrow(/mutually exclusive/);
    });
    it('lists valid profiles for an unknown one', () => {
      expect(() => resolveProfiles(makeKit(), ['nope'])).toThrow(/core, java, spring, quarkus/);
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
    it('later profile wins, modes apply, rerun is unchanged', async () => {
      expect(await add({ profiles: ['java'] })).toBe(0);
      expect(readFileSync(join(project, 'README.md'), 'utf-8')).toBe('# java wins\n');
      expect(statSync(join(project, 'scripts/run.sh')).mode & 0o111).not.toBe(0);
      logs.length = 0;
      expect(await add()).toBe(0);
      expect(logs.join('\n')).toContain('0 written');
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
      expect(await kitToolsCommand(project, true)).toBe(4);
      expect(readFileSync(join(project, 'args.txt'), 'utf-8').trim()).toBe('args:--check');
    });
  });

  describe('doctor pieces', () => {
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
      Bun.spawnSync(['rm', join(project, 'src.txt')]);
      const kit = makeKit();
      const drift = computeDrift(project, kit, resolveProfiles(kit, ['java']));
      expect(drift.modified).toEqual(['README.md']);
      expect(drift.missing).toEqual(['src.txt']);
      expect(drift.checked).toBe(3);
    });
  });
});
