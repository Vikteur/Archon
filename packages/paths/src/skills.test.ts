import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { removeTempTree } from './test-utils';

import {
  copilotSkillSearchRoots,
  parseSettingSources,
  resolveSkillDirectories,
  resolveSkillDirectoriesFromRoots,
  skillSearchRoots,
} from './skills';

type FakeWorld = {
  root: string;
  cwd: string;
  home: string;
  stageSkill: (under: 'cwd' | 'home', subdir: '.agents' | '.claude', name: string) => string;
};

/**
 * Stages a temp cwd and HOME so the resolver's filesystem reads are isolated
 * per test. Each test gets its own `cwd/.agents/skills/` etc. tree to populate
 * as needed.
 */
function makeFakeWorld(): FakeWorld {
  const root = mkdtempSync(join(tmpdir(), 'archon-skills-test-'));
  const cwd = join(root, 'project');
  const home = join(root, 'home');
  mkdirSync(cwd, { recursive: true });
  mkdirSync(home, { recursive: true });

  const stageSkill = (
    under: 'cwd' | 'home',
    subdir: '.agents' | '.claude',
    name: string
  ): string => {
    const base = under === 'cwd' ? cwd : home;
    const dir = join(base, subdir, 'skills', name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'SKILL.md'), `# ${name}\n`);
    return dir;
  };

  return { root, cwd, home, stageSkill };
}

describe('resolveSkillDirectories', () => {
  const originalHome = process.env.HOME;
  let fake: ReturnType<typeof makeFakeWorld>;

  beforeEach(() => {
    fake = makeFakeWorld();
    process.env.HOME = fake.home;
  });

  afterEach(async () => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    await removeTempTree(fake.root);
  });

  test('returns empty paths and missing for undefined input', () => {
    expect(resolveSkillDirectories(fake.cwd, undefined)).toEqual({ paths: [], missing: [] });
  });

  test('returns empty paths and missing for empty array', () => {
    expect(resolveSkillDirectories(fake.cwd, [])).toEqual({ paths: [], missing: [] });
  });

  test('skips empty strings and non-string entries', () => {
    // Cast through unknown so we can exercise the runtime guard against
    // wonky callers; the type system rules these out at compile time.
    const input = ['', '  ', null, undefined, 42] as unknown as string[];
    expect(resolveSkillDirectories(fake.cwd, input)).toEqual({ paths: [], missing: [] });
  });

  test('reports a missing skill that nothing on disk provides', () => {
    const result = resolveSkillDirectories(fake.cwd, ['nonexistent']);
    expect(result.paths).toEqual([]);
    expect(result.missing).toEqual(['nonexistent']);
  });

  test('resolves a skill staged under cwd/.agents/skills', () => {
    const dir = fake.stageSkill('cwd', '.agents', 'alpha');
    const result = resolveSkillDirectories(fake.cwd, ['alpha']);
    expect(result.paths).toEqual([dir]);
    expect(result.missing).toEqual([]);
  });

  test('falls back to cwd/.claude/skills when .agents misses', () => {
    const dir = fake.stageSkill('cwd', '.claude', 'beta');
    const result = resolveSkillDirectories(fake.cwd, ['beta']);
    expect(result.paths).toEqual([dir]);
    expect(result.missing).toEqual([]);
  });

  test('falls back to home/.agents/skills when both cwd locations miss', () => {
    const dir = fake.stageSkill('home', '.agents', 'gamma');
    const result = resolveSkillDirectories(fake.cwd, ['gamma']);
    expect(result.paths).toEqual([dir]);
    expect(result.missing).toEqual([]);
  });

  test('prefers cwd over home when the same name exists in both', () => {
    const cwdDir = fake.stageSkill('cwd', '.agents', 'delta');
    fake.stageSkill('home', '.agents', 'delta');
    const result = resolveSkillDirectories(fake.cwd, ['delta']);
    expect(result.paths).toEqual([cwdDir]);
    expect(result.missing).toEqual([]);
  });

  test('deduplicates repeated names', () => {
    const dir = fake.stageSkill('cwd', '.agents', 'epsilon');
    const result = resolveSkillDirectories(fake.cwd, ['epsilon', 'epsilon', 'epsilon']);
    expect(result.paths).toEqual([dir]);
    expect(result.missing).toEqual([]);
  });

  test('rejects absolute-path names', () => {
    const result = resolveSkillDirectories(fake.cwd, ['/etc/passwd']);
    expect(result.paths).toEqual([]);
    expect(result.missing).toEqual(['/etc/passwd']);
  });

  test('rejects nested-path names', () => {
    const result = resolveSkillDirectories(fake.cwd, ['foo/bar']);
    expect(result.paths).toEqual([]);
    expect(result.missing).toEqual(['foo/bar']);
  });

  test('rejects parent-traversal names', () => {
    const result = resolveSkillDirectories(fake.cwd, ['..', '../escape']);
    expect(result.paths).toEqual([]);
    expect(result.missing).toEqual(['..', '../escape']);
  });

  test('treats directories without a SKILL.md as missing', () => {
    // Stage the directory itself but omit the SKILL.md file — the resolver
    // requires the marker to consider it a skill.
    const partialDir = join(fake.cwd, '.agents', 'skills', 'zeta');
    mkdirSync(partialDir, { recursive: true });
    const result = resolveSkillDirectories(fake.cwd, ['zeta']);
    expect(result.paths).toEqual([]);
    expect(result.missing).toEqual(['zeta']);
  });
});

describe('copilotSkillSearchRoots', () => {
  const originalHome = process.env.HOME;
  const originalCopilotHome = process.env.COPILOT_HOME;
  let fake: ReturnType<typeof makeFakeWorld>;

  const stageAt = (dir: string, name: string): string => {
    const skillDir = join(dir, name);
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(join(skillDir, 'SKILL.md'), `# ${name}\n`);
    return skillDir;
  };

  beforeEach(() => {
    fake = makeFakeWorld();
    process.env.HOME = fake.home;
    delete process.env.COPILOT_HOME;
  });

  afterEach(async () => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    if (originalCopilotHome === undefined) delete process.env.COPILOT_HOME;
    else process.env.COPILOT_HOME = originalCopilotHome;
    await removeTempTree(fake.root);
  });

  test('adds .github/skills and ~/.copilot/skills around the shared roots', () => {
    expect(copilotSkillSearchRoots(fake.cwd)).toEqual([
      join(fake.cwd, '.github', 'skills'),
      join(fake.cwd, '.agents', 'skills'),
      join(fake.cwd, '.claude', 'skills'),
      join(fake.home, '.copilot', 'skills'),
      join(fake.home, '.agents', 'skills'),
      join(fake.home, '.claude', 'skills'),
    ]);
  });

  test('reads the user skill dir from COPILOT_HOME', () => {
    process.env.COPILOT_HOME = join(fake.root, 'copilot-home');
    expect(copilotSkillSearchRoots(fake.cwd)).toContain(join(fake.root, 'copilot-home', 'skills'));
  });

  test('an explicit copilotHome wins over COPILOT_HOME', () => {
    process.env.COPILOT_HOME = join(fake.root, 'env-home');
    const roots = copilotSkillSearchRoots(fake.cwd, {
      copilotHome: join(fake.root, 'config'),
    });
    expect(roots).toContain(join(fake.root, 'config', 'skills'));
    expect(roots).not.toContain(join(fake.root, 'env-home', 'skills'));
  });

  test('an empty COPILOT_HOME falls back to ~/.copilot', () => {
    process.env.COPILOT_HOME = '';
    expect(copilotSkillSearchRoots(fake.cwd)).toContain(join(fake.home, '.copilot', 'skills'));
  });

  test('resolves a skill that only .github/skills provides', () => {
    const dir = stageAt(join(fake.cwd, '.github', 'skills'), 'gh-only');
    expect(
      resolveSkillDirectoriesFromRoots(copilotSkillSearchRoots(fake.cwd), ['gh-only'])
    ).toEqual({ paths: [dir], missing: [] });
  });

  test('resolves a skill that only the Copilot home provides', () => {
    const dir = stageAt(join(fake.home, '.copilot', 'skills'), 'user-copilot');
    expect(
      resolveSkillDirectoriesFromRoots(copilotSkillSearchRoots(fake.cwd), ['user-copilot'])
    ).toEqual({ paths: [dir], missing: [] });
  });

  test('.github/skills wins over .agents/skills for the same name', () => {
    const gh = stageAt(join(fake.cwd, '.github', 'skills'), 'dup');
    fake.stageSkill('cwd', '.agents', 'dup');
    expect(
      resolveSkillDirectoriesFromRoots(copilotSkillSearchRoots(fake.cwd), ['dup']).paths
    ).toEqual([gh]);
  });

  test('the shared roots never include the Copilot-only directories', () => {
    stageAt(join(fake.cwd, '.github', 'skills'), 'gh-only');
    stageAt(join(fake.home, '.copilot', 'skills'), 'user-copilot');
    const roots = skillSearchRoots(fake.cwd);
    expect(roots).not.toContain(join(fake.cwd, '.github', 'skills'));
    expect(roots).not.toContain(join(fake.home, '.copilot', 'skills'));
    expect(resolveSkillDirectories(fake.cwd, ['gh-only', 'user-copilot'])).toEqual({
      paths: [],
      missing: ['gh-only', 'user-copilot'],
    });
  });
});

describe('parseSettingSources', () => {
  test('returns undefined for a non-array value', () => {
    expect(parseSettingSources(undefined)).toBeUndefined();
    expect(parseSettingSources('project')).toBeUndefined();
  });

  test('keeps recognized entries in order', () => {
    expect(parseSettingSources(['user', 'project'])).toEqual(['user', 'project']);
  });

  test('preserves an explicitly empty list', () => {
    expect(parseSettingSources([])).toEqual([]);
  });

  test('drops unrecognized entries, narrowing rather than widening', () => {
    expect(parseSettingSources(['project', 'local', { nope: 1 }])).toEqual(['project']);
    expect(parseSettingSources(['projct'])).toEqual([]);
  });
});
