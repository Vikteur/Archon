/**
 * Tests for `archon kit setup`: every external command, the tool installer, kit add and the MCP probe are stubbed.
 */
import { afterEach, beforeEach, describe, expect, it } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { parse as parseYaml } from 'yaml';
import { removeTempTree } from '@archon/paths/test-utils';
import { applySetOverrides, type Kit } from './kit';
import {
  addExtraProject,
  checkContractPath,
  checkRepoPath,
  expandPath,
  kitSetupCommand,
  mergeMcpServer,
  readSetupDefaults,
  saveSetupDefaults,
  setupDefaultsPath,
  type KitSetupDeps,
  type KitSetupOptions,
  type SetupUi,
} from './kit-setup';

const KIT_MCP = {
  mcpServers: {
    codegraph: {
      type: 'local',
      command: 'codegraph',
      args: ['serve', '--mcp'],
      env: { CODEGRAPH_MCP_TOOLS: 'explore,node' },
      tools: ['*'],
    },
    'contract-api': { type: 'local', command: 'node', args: ['scripts/contract-mcp/server.mjs'] },
  },
};

function makeKit(): Kit {
  const profile = (requires: string[]) => ({ requires, description: '' });
  return {
    manifest: {
      version: 1,
      source: { name: 'fixture', commit: 'abc' },
      profiles: {
        core: profile([]),
        java: profile(['core']),
        'java-spring': profile(['java']),
        'openapi-contract': profile(['core']),
      },
      exclusive: [],
      files: [],
      aliases: {},
      postInstall: [],
    },
    defaults:
      '# kit config\nprofiles: [core]\ncontract:\n  spec_path: contract/dist/openapi.yaml # the spec\n',
    files: { 'core/.github/mcp.json': JSON.stringify(KIT_MCP) },
  };
}

function gitRepo(dir: string): string {
  mkdirSync(dir, { recursive: true });
  expect(Bun.spawnSync(['git', 'init', '-q', dir]).exitCode).toBe(0);
  return dir;
}

interface Call {
  command: string;
  args: string[];
  cwd: string;
}

describe('kit setup', () => {
  let root: string;
  let home: string;
  let archonHome: string;
  let backend: string;
  let frontend: string;
  let contract: string;
  let env: NodeJS.ProcessEnv;
  let calls: Call[];
  let lines: string[];
  let stderr: string[];
  let kitAddOptions: Parameters<KitSetupDeps['kitAdd']>[1][];
  let failWhen: (call: Call) => boolean;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'archon-kit-setup-test-'));
    home = join(root, 'home');
    mkdirSync(home);
    archonHome = join(root, 'archon-home');
    backend = gitRepo(join(home, 'code', 'backend'));
    frontend = gitRepo(join(home, 'code', 'frontend'));
    contract = join(root, 'openapi.yaml');
    writeFileSync(contract, 'openapi: 3.0.3\ninfo: { title: t, version: "1" }\npaths: {}\n');
    env = {
      ...process.env,
      HOME: home,
      ARCHON_HOME: archonHome,
      COPILOT_HOME: join(root, 'copilot'),
      ARCHON_DOCKER: '',
      WORKSPACE_PATH: '',
    };
    calls = [];
    lines = [];
    stderr = [];
    kitAddOptions = [];
    failWhen = () => false;
  });

  afterEach(async () => {
    await removeTempTree(root);
  });

  /** A UI that records every line; `answers` script the text prompts in order. */
  function recordingUi(
    answers: (string | symbol)[] = [],
    confirm: boolean | symbol = true
  ): SetupUi {
    const cancelled = Symbol('cancel');
    return {
      intro: title => void lines.push(`intro ${title}`),
      outro: message => void lines.push(`outro ${message}`),
      note: (message, title) => void lines.push(`note ${title}\n${message}`),
      info: message => void lines.push(`info ${message}`),
      warn: message => void lines.push(`warn ${message}`),
      text: async options => {
        const answer = answers.shift();
        if (answer === undefined) throw new Error(`unexpected prompt: ${options.message}`);
        if (typeof answer === 'symbol') return cancelled;
        lines.push(`prompt ${options.message} [${options.initialValue ?? ''}]`);
        const problem = options.validate(answer);
        if (problem !== undefined) throw new Error(`validate refused ${answer}: ${problem}`);
        return answer;
      },
      confirm: async () => (typeof confirm === 'symbol' ? cancelled : confirm),
      isCancel: (value): value is symbol => typeof value === 'symbol',
      cancel: message => void lines.push(`cancel ${message}`),
      spinner: () => ({
        start: message => void lines.push(`start ${message}`),
        stop: message => void lines.push(`ok ${message}`),
        error: message => void lines.push(`fail ${message}`),
      }),
    };
  }

  function deps(overrides: Partial<KitSetupDeps> = {}): KitSetupDeps {
    return {
      cwd: root,
      env,
      interactive: false,
      ui: recordingUi(),
      run: async (command, args, { cwd, output }) => {
        const call = { command, args, cwd };
        calls.push(call);
        output(`ran ${command} ${args.join(' ')}\n`);
        if (args[0] === 'scripts/web-uis.sh' && args[1] === 'start') {
          output('Backlog board: http://localhost:6420\nArchon web UI: http://localhost:3090');
        }
        return failWhen(call) ? 1 : 0;
      },
      loadKit: async () => makeKit(),
      tools: async (dir, _kit, output) => {
        calls.push({ command: 'tools', args: [], cwd: dir });
        output('tools installed\n');
        return 0;
      },
      kitAdd: async (target, options, kit) => {
        kitAddOptions.push(options);
        console.log('kit add wrote the files');
        mkdirSync(join(target, '.archon', 'scripts'), { recursive: true });
        mkdirSync(join(target, '.github'), { recursive: true });
        mkdirSync(join(target, 'scripts'), { recursive: true });
        writeFileSync(
          join(target, '.archon', 'kit.yaml'),
          applySetOverrides(kit.defaults, options.set ?? [])
        );
        writeFileSync(join(target, '.github', 'mcp.json'), JSON.stringify(KIT_MCP, null, 2));
        for (const script of [
          '.archon/scripts/contract-mcp-setup.sh',
          '.archon/scripts/codegraph-setup.sh',
          'scripts/web-uis.sh',
        ]) {
          writeFileSync(join(target, script), '#!/bin/bash\n');
        }
        return 0;
      },
      checkMcp: async () => [{ status: 'ok', name: 'mcp codegraph', detail: '6 tools' }],
      which: () => true,
      now: () => new Date(2026, 10, 19, 8, 5, 9),
      stderr: text => void stderr.push(text),
      ...overrides,
    };
  }

  const flags = (extra: KitSetupOptions = {}): KitSetupOptions => ({
    backend,
    frontend,
    contract,
    ...extra,
  });
  const ran = (script: string): Call[] =>
    calls.filter(c => c.command === script || c.args[0] === script);
  const kitYaml = (): Record<string, unknown> =>
    parseYaml(readFileSync(join(backend, '.archon', 'kit.yaml'), 'utf-8')) as Record<
      string,
      unknown
    >;
  const logFile = (): string => join(archonHome, 'logs', 'kit-setup-20261119-080509.log');

  describe('paths', () => {
    it('expands ~ and ~/x against the home folder and resolves a relative path against cwd', () => {
      expect(expandPath('~', '/work', '/h')).toBe('/h');
      expect(expandPath('~/code/x', '/work', '/h')).toBe('/h/code/x');
      expect(expandPath('code/x', '/work', '/h')).toBe('/work/code/x');
      expect(expandPath(' /abs/x ', '/work', '/h')).toBe('/abs/x');
    });

    it('accepts a git repository by tilde or relative path, as an absolute path', () => {
      expect(checkRepoPath('~/code/backend', root, home)).toEqual({ ok: true, path: backend });
      expect(checkRepoPath('home/code/frontend', root, home)).toEqual({
        ok: true,
        path: frontend,
      });
    });

    it('refuses an empty path, a missing folder, a file and a folder that is not a git repository', () => {
      const plain = join(root, 'plain');
      mkdirSync(plain);
      const refused = (input: string): string => {
        const check = checkRepoPath(input, root, home);
        if (check.ok) throw new Error(`accepted ${input}`);
        return check.error;
      };
      expect(refused('')).toBe('Enter a path');
      expect(refused('nope')).toContain('does not exist');
      expect(refused('openapi.yaml')).toContain('is not a folder');
      expect(refused('plain')).toContain('is not a git repository');
    });

    it('accepts an OpenAPI contract in YAML or JSON', () => {
      writeFileSync(join(root, 'api.json'), '{"openapi": "3.1.0", "paths": {}}');
      expect(checkContractPath('openapi.yaml', root, home)).toEqual({ ok: true, path: contract });
      expect(checkContractPath('api.json', root, home)).toEqual({
        ok: true,
        path: join(root, 'api.json'),
      });
    });

    it('refuses a missing file, a wrong extension, a file that does not parse and one without openapi', () => {
      writeFileSync(join(root, 'api.txt'), 'openapi: 3.0.0\n');
      writeFileSync(join(root, 'swagger.yaml'), 'swagger: "2.0"\n');
      writeFileSync(join(root, 'list.yml'), '- openapi\n');
      writeFileSync(join(root, 'broken.yaml'), 'openapi: [\n');
      const refused = (input: string): string => {
        const check = checkContractPath(input, root, home);
        if (check.ok) throw new Error(`accepted ${input}`);
        return check.error;
      };
      expect(refused('missing.yaml')).toContain('does not exist');
      expect(refused('api.txt')).toContain('is not a .yaml, .yml or .json file');
      expect(refused('swagger.yaml')).toContain('has no top-level openapi key');
      expect(refused('list.yml')).toContain('has no top-level openapi key');
      expect(refused('broken.yaml')).toContain('does not parse');
      expect(refused('~')).toContain('is not a file');
    });
  });

  describe('config edits', () => {
    it('adds the frontend to codegraph.extra_projects once, keeping the comments', () => {
      const once = addExtraProject('# top\nbase_branch: main # branch\n', '/fe');
      expect(once).toContain('# top');
      expect(once).toContain('# branch');
      expect(parseYaml(once).codegraph.extra_projects).toEqual(['/fe']);
      const twice = addExtraProject(addExtraProject(once, '/fe'), '/other');
      expect(parseYaml(twice).codegraph.extra_projects).toEqual(['/fe', '/other']);
      const fromScalar = addExtraProject('codegraph:\n  extra_projects: /old\n', '/fe');
      expect(parseYaml(fromScalar).codegraph.extra_projects).toEqual(['/old', '/fe']);
    });

    it('merges a server into mcp.json, replacing that key and keeping the others', () => {
      const entry = { command: 'codegraph' };
      expect(JSON.parse(mergeMcpServer(null, 'codegraph', entry))).toEqual({
        mcpServers: { codegraph: entry },
      });
      const existing = JSON.stringify({
        mcpServers: { codegraph: { command: 'old' }, other: { command: 'x' } },
        extra: 1,
      });
      expect(JSON.parse(mergeMcpServer(existing, 'codegraph', entry))).toEqual({
        mcpServers: { codegraph: entry, other: { command: 'x' } },
        extra: 1,
      });
      const vscode = '// comment\n{"servers": {"other": {}}}';
      expect(JSON.parse(mergeMcpServer(vscode, 'codegraph', entry))).toEqual({
        servers: { other: {}, codegraph: entry },
      });
      expect(() => mergeMcpServer('{nope', 'codegraph', entry)).toThrow();
    });

    it('saves only the three paths and the profiles, and reads them back', () => {
      saveSetupDefaults(archonHome, {
        backend: '/b',
        frontend: '',
        contract: '/c.yaml',
        profiles: ['core'],
      });
      expect(JSON.parse(readFileSync(setupDefaultsPath(archonHome), 'utf-8'))).toEqual({
        backend: '/b',
        frontend: '',
        contract: '/c.yaml',
        profiles: ['core'],
      });
      expect(readSetupDefaults(archonHome).profiles).toEqual(['core']);
      expect(readSetupDefaults(join(root, 'nowhere'))).toEqual({});
    });
  });

  describe('command', () => {
    it('without a terminal and without --backend and --contract prints the usage and exits 2', async () => {
      expect(await kitSetupCommand({}, deps())).toBe(2);
      expect(await kitSetupCommand({ backend }, deps())).toBe(2);
      expect(stderr.join('\n')).toContain('Usage: archon kit setup');
      expect(calls).toEqual([]);
      expect(existsSync(setupDefaultsPath(archonHome))).toBe(false);
    });

    it('refuses a bad flag value or an unknown profile with exit 2, before any step', async () => {
      expect(await kitSetupCommand(flags({ contract: join(root, 'missing.yaml') }), deps())).toBe(
        2
      );
      expect(stderr.join('\n')).toContain('--contract:');
      expect(await kitSetupCommand(flags({ frontend: backend }), deps())).toBe(2);
      expect(await kitSetupCommand(flags({ profiles: ['nope'] }), deps())).toBe(2);
      expect(calls).toEqual([]);
    });

    it('runs every step from the flags and wires the backend and the frontend', async () => {
      mkdirSync(join(frontend, '.github'));
      writeFileSync(
        join(frontend, '.github', 'mcp.json'),
        JSON.stringify({ mcpServers: { codegraph: { command: 'old' }, other: { command: 'x' } } })
      );

      expect(await kitSetupCommand(flags(), deps())).toBe(0);

      expect(calls).toEqual([
        { command: 'tools', args: [], cwd: backend },
        { command: 'bash', args: ['.archon/scripts/contract-mcp-setup.sh'], cwd: backend },
        { command: 'bash', args: ['.archon/scripts/codegraph-setup.sh', backend], cwd: backend },
        { command: 'bash', args: ['.archon/scripts/codegraph-setup.sh', frontend], cwd: backend },
        { command: 'rtk', args: ['init', '--copilot'], cwd: backend },
        { command: 'rtk', args: ['init', '--copilot'], cwd: frontend },
        { command: 'bash', args: ['scripts/web-uis.sh', 'start', '--open'], cwd: backend },
      ]);
      expect(kitAddOptions[0]).toMatchObject({
        profiles: ['core', 'java', 'java-spring', 'openapi-contract'],
        trust: true,
        noTools: true,
        set: [`contract.spec_path=${contract}`],
      });

      const config = kitYaml();
      expect((config.contract as Record<string, unknown>).spec_path).toBe(contract);
      expect((config.codegraph as Record<string, unknown>).extra_projects).toEqual([frontend]);
      expect(readFileSync(join(backend, '.archon', 'kit.yaml'), 'utf-8')).toContain('# the spec');

      const mcp = JSON.parse(readFileSync(join(frontend, '.github', 'mcp.json'), 'utf-8'));
      expect(mcp.mcpServers.other).toEqual({ command: 'x' });
      expect(mcp.mcpServers.codegraph).toEqual(KIT_MCP.mcpServers.codegraph);
      expect(mcp.mcpServers['contract-api']).toBeUndefined();
      expect(readFileSync(join(root, 'copilot', 'config.json'), 'utf-8')).toContain(frontend);

      const log = readFileSync(logFile(), 'utf-8');
      expect(log).toContain('tools installed');
      expect(log).toContain('kit add wrote the files');
      expect(log).toContain('ran rtk init --copilot');
      const out = lines.join('\n');
      expect(out).toContain('http://localhost:6420');
      expect(out).toContain('http://localhost:3090');
      expect(out).toContain(`cd ${backend} && bash scripts/web-uis.sh stop`);
      expect(out).toContain(logFile());
      expect(out).toContain('/login');
      expect(out).toContain('outro Setup done.');

      expect(JSON.parse(readFileSync(setupDefaultsPath(archonHome), 'utf-8'))).toEqual({
        backend,
        frontend,
        contract,
        profiles: ['core', 'java', 'java-spring', 'openapi-contract'],
      });
    });

    it('skips the tools, the rtk hooks and the web views on --no-tools, --no-rtk and --no-web', async () => {
      const code = await kitSetupCommand(
        flags({ noTools: true, noRtk: true, noWeb: true, profiles: ['core'] }),
        deps()
      );
      expect(code).toBe(0);
      expect(ran('tools')).toEqual([]);
      expect(ran('rtk')).toEqual([]);
      expect(ran('scripts/web-uis.sh')).toEqual([]);
      expect(ran('.archon/scripts/codegraph-setup.sh')).toHaveLength(2);
      const out = lines.join('\n');
      expect(out).toContain('rtk hooks: skipped (--no-rtk)');
      expect(out).toContain('Web views: skipped (--no-web)');
      expect(readSetupDefaults(archonHome).profiles).toEqual(['core']);
    });

    it('skips the rtk hooks with a note when rtk is not on PATH', async () => {
      expect(await kitSetupCommand(flags({ noWeb: true }), deps({ which: () => false }))).toBe(0);
      expect(ran('rtk')).toEqual([]);
      expect(lines.join('\n')).toContain('rtk hooks: skipped (rtk is not on PATH)');
    });

    it('without a frontend indexes only the backend and saves the frontend as skipped', async () => {
      expect(await kitSetupCommand(flags({ frontend: '' }), deps())).toBe(0);
      expect(ran('.archon/scripts/codegraph-setup.sh').map(c => c.args[1])).toEqual([backend]);
      expect(ran('rtk').map(c => c.cwd)).toEqual([backend]);
      expect(kitYaml().codegraph).toBeUndefined();
      expect(existsSync(join(frontend, '.github', 'mcp.json'))).toBe(false);
      expect(lines.join('\n')).toContain('Frontend MCP: skipped (no frontend)');
      expect(readSetupDefaults(archonHome).frontend).toBe('');
    });

    it('a failed step is shown failed with the log, the later steps still run, and it exits 1', async () => {
      failWhen = call => call.args[0] === '.archon/scripts/contract-mcp-setup.sh';
      const failingMcp = async () => [
        { status: 'fail' as const, name: 'mcp contract-api', detail: 'did not start' },
      ];
      expect(await kitSetupCommand(flags(), deps({ checkMcp: failingMcp }))).toBe(1);
      expect(ran('.archon/scripts/codegraph-setup.sh')).toHaveLength(2);
      expect(ran('rtk')).toHaveLength(2);
      expect(ran('scripts/web-uis.sh')).toHaveLength(1);
      const out = lines.join('\n');
      expect(out).toContain(
        `fail Contract: failed (bash .archon/scripts/contract-mcp-setup.sh exited with 1); see ${logFile()}`
      );
      expect(out).toContain('fail Servers check: failed');
      expect(out).toContain('2 step(s) failed: Contract, Servers check');
      expect(readFileSync(logFile(), 'utf-8')).toContain('=== Contract: FAILED');
    });

    it('a failing kit add still lets the later steps run', async () => {
      expect(await kitSetupCommand(flags({ noWeb: true }), deps({ kitAdd: async () => 1 }))).toBe(
        1
      );
      expect(lines.join('\n')).toContain('fail Kit: failed (kit add exited with 1)');
      // The contract step still writes kit.yaml from the kit defaults, then finds no setup script.
      expect((kitYaml().contract as Record<string, unknown>).spec_path).toBe(contract);
      expect(lines.join('\n')).toContain('fail Contract: failed');
      expect(lines.join('\n')).toContain('ok Servers check');
    });

    it('without openapi-contract a missing contract MCP script is not a failure', async () => {
      const code = await kitSetupCommand(
        flags({ noWeb: true, profiles: ['core'] }),
        deps({ kitAdd: async () => 0 })
      );
      expect(lines.join('\n')).toContain('no contract MCP server without openapi-contract');
      expect((kitYaml().contract as Record<string, unknown>).spec_path).toBe(contract);
      // The stub kit add wrote no codegraph-setup.sh, so only that step fails.
      expect(code).toBe(1);
      expect(lines.join('\n')).toContain('1 step(s) failed: CodeGraph index');
    });

    it('asks each path in a terminal, offers the saved answers, and confirms before it runs', async () => {
      saveSetupDefaults(archonHome, {
        backend,
        frontend: '',
        contract,
        profiles: ['core'],
      });
      const ui = recordingUi(['~/code/backend', '~/code/frontend', '../openapi.yaml']);
      const code = await kitSetupCommand(
        { noWeb: true },
        deps({ interactive: true, ui, cwd: join(root, 'home') })
      );
      expect(code).toBe(0);
      const out = lines.join('\n');
      expect(out).toContain(
        `prompt Backend repository (a git checkout; the kit goes here) [${backend}]`
      );
      expect(out).toContain('prompt Frontend repository (empty to skip) []');
      expect(out).toContain(`[${contract}]`);
      expect(readSetupDefaults(archonHome)).toEqual({
        backend,
        frontend,
        contract,
        profiles: ['core'],
      });
      expect(kitAddOptions[0]?.profiles).toEqual(['core']);
    });

    it('rejects a frontend that is the backend while it is typed', async () => {
      const ui = recordingUi([backend, backend]);
      await expect(kitSetupCommand({}, deps({ interactive: true, ui }))).rejects.toThrow(
        'The frontend is the backend'
      );
    });

    it('a cancelled prompt or a declined confirmation changes nothing and exits 0', async () => {
      const cancelled = Symbol('cancel');
      expect(
        await kitSetupCommand(
          {},
          deps({ interactive: true, ui: recordingUi([backend, cancelled]) })
        )
      ).toBe(0);
      expect(
        await kitSetupCommand(flags(), deps({ interactive: true, ui: recordingUi([], false) }))
      ).toBe(0);
      expect(calls).toEqual([]);
      expect(existsSync(setupDefaultsPath(archonHome))).toBe(false);
      expect(
        existsSync(join(archonHome, 'logs')) ? readdirSync(join(archonHome, 'logs')) : []
      ).toEqual([]);
      expect(lines.filter(line => line.startsWith('cancel'))).toHaveLength(2);
    });

    it('--yes skips the confirmation in a terminal', async () => {
      const ui = recordingUi([], false);
      expect(
        await kitSetupCommand(flags({ yes: true, noWeb: true }), deps({ interactive: true, ui }))
      ).toBe(0);
      expect(calls.length).toBeGreaterThan(0);
    });
  });
});
