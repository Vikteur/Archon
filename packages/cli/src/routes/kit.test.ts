import { afterEach, expect, test } from 'bun:test';
import { removeTempTree } from '@archon/paths/test-utils';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { CliRouteContext } from './context';
import { runKit } from './commands';

const roots: string[] = [];
afterEach(async () => {
  for (const root of roots.splice(0)) await removeTempTree(root);
});

function context(
  subcommand: string,
  project: string,
  values: Record<string, unknown> = {}
): CliRouteContext {
  return {
    values,
    positionals: ['kit', subcommand, project],
    command: 'kit',
    subcommand,
    cwd: project,
    effectiveCwd: project,
    json: false,
    detachedRunConfig: undefined,
    inheritedEnv: process.env,
    forgeTrustedEnv: process.env,
  };
}

test('archon kit tools reaches the kit command and passes --check', async () => {
  const project = mkdtempSync(join(tmpdir(), 'archon-kit-route-'));
  roots.push(project);
  mkdirSync(join(project, 'scripts'));
  writeFileSync(join(project, 'scripts', 'install-tools.sh'), 'echo "args:$*" > ran.txt\nexit 0\n');
  expect(await runKit(context('tools', project, { check: true }))).toBe(0);
  expect(readFileSync(join(project, 'ran.txt'), 'utf-8').trim()).toBe('args:--check');
});

test('an unknown kit subcommand still fails', async () => {
  const project = mkdtempSync(join(tmpdir(), 'archon-kit-route-'));
  roots.push(project);
  expect(await runKit(context('nope', project))).toBe(1);
});

test('archon kit setup takes no path', async () => {
  const project = mkdtempSync(join(tmpdir(), 'archon-kit-route-'));
  roots.push(project);
  expect(await runKit(context('setup', project))).toBe(1);
});

test.skipIf(process.stdin.isTTY === true && process.stdout.isTTY === true)(
  'archon kit setup without a terminal and without --backend and --contract exits 2',
  async () => {
    const project = mkdtempSync(join(tmpdir(), 'archon-kit-route-'));
    roots.push(project);
    const ctx = context('setup', project);
    ctx.positionals = ['kit', 'setup'];
    expect(await runKit(ctx)).toBe(2);
  }
);

test('archon kit web reaches the web command: a project without scripts/web-uis.sh exits 1', async () => {
  const project = mkdtempSync(join(tmpdir(), 'archon-kit-route-'));
  roots.push(project);
  const saved = process.env.ARCHON_HOME;
  process.env.ARCHON_HOME = join(project, 'archon-home');
  try {
    expect(await runKit(context('web', project))).toBe(1);
    const logs = join(project, 'archon-home', 'logs');
    expect(readdirSync(logs).some(name => name.startsWith('kit-web-'))).toBe(true);
  } finally {
    if (saved === undefined) delete process.env.ARCHON_HOME;
    else process.env.ARCHON_HOME = saved;
  }
});
