import { describe, expect, test } from 'bun:test';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { trackTempRoots } from '@archon/paths/test-utils';
import { renderBundledKit } from './generate-bundled-kit';
import {
  applyGlobalRewrites,
  applyRewrites,
  classify,
  convertAgent,
  convertDeny,
  convertHooks,
  convertRule,
  convertSkillMd,
  DELEGATOR_NIGHT_STEP,
  DISPATCH_SH,
  KIT_MODULES,
  leakCheck,
  NEVER_SHIP,
  neverShipRefs,
  parseHookCommand,
  type Rewrite,
  snapshot,
  sync,
  verifyKit,
} from './kit-sync';

const track = trackTempRoots();

function git(dir: string, ...args: string[]): string {
  const r = Bun.spawnSync(
    ['git', '-C', dir, '-c', 'user.name=Kit Test', '-c', 'user.email=kit@test.invalid', ...args],
    { stdout: 'pipe', stderr: 'pipe' }
  );
  if (r.exitCode !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr.toString()}`);
  return r.stdout.toString();
}

function write(root: string, path: string, content: string, executable = false): void {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), content);
  if (executable) chmodSync(join(root, path), 0o755);
}

const AGENT = `---
name: developer
description: Implement one part.
model: claude-sonnet-5-5
tools:
  - Read
  - Grep
  - Edit
  - Write
  - Skill
  - Bash(git add *)
  - Agent(github-agent)
  - SendMessage
  - mcp__codegraph__*
  - mcp__portal-api__search
mcpServers:
  - portal-api:
      command: node
      args: [scripts/portal-mcp/server.mjs]
      alwaysLoad: true
skills:
  - tdd-loop
  - clean-code
---
# Developer

Ask portal-api first; my-portal-api-thing stays.
`;

const SKILL = `---
name: grill-pr
description: >-
  Read-only grilling.
disable-model-invocation: true
allowed-tools: Read, Grep, Bash(git diff *)
disallowed-tools: Edit(./**), Bash(git add *, git commit *)
argument-hint: "[base]"
---
# Grill

See .claude/skills/grill-pr/references and .claude/skills/run-wedding-portal/SKILL.md.
`;

const SETTINGS = {
  permissions: { deny: ['Bash(rm -rf /*)', 'Read(./.env)'] },
  hooks: {
    PreToolUse: [
      {
        matcher: 'Write|Edit|Bash',
        hooks: [
          {
            type: 'command',
            command:
              'if [ -d "$CLAUDE_PROJECT_DIR/.claude/hooks" ]; then cd "$CLAUDE_PROJECT_DIR/.claude/hooks" && exec bash scripts/guard.sh PreToolUse; else exit 0; fi',
            timeout: 20,
          },
        ],
      },
    ],
    SessionStart: [
      {
        hooks: [
          {
            type: 'command',
            command:
              'exec bash "$CLAUDE_PROJECT_DIR/.archon/scripts/delegator-session.sh" sessionStart',
          },
        ],
      },
    ],
  },
};

/** A mini source repo: one file per conversion, on the real copy lists. */
function fixture(): string {
  const root = track(mkdtempSync(join(tmpdir(), 'kit-sync-src-')));
  git(root, 'init', '-q', '-b', 'main');
  git(root, 'remote', 'add', 'origin', 'git@github.com:acme/sample-app.git');
  write(root, '.claude/agents/developer.md', AGENT);
  write(root, '.claude/skills/grill-pr/SKILL.md', SKILL);
  write(
    root,
    '.claude/skills/run-wedding-portal/SKILL.md',
    '---\nname: run-wedding-portal\ndescription: Run it.\n---\nRun.\n'
  );
  write(
    root,
    '.claude/skills/run-wedding-portal/scripts/smoke.sh',
    '#!/usr/bin/env bash\necho ok\n',
    true
  );
  write(root, '.claude/rules/domain.md', '---\npaths:\n  - "**/*-domain/**"\n---\n# Domain\n');
  write(root, '.claude/rules/general.md', '# General\n');
  write(root, '.claude/settings.json', `${JSON.stringify(SETTINGS, null, 2)}\n`);
  write(root, '.claude/hooks/scripts/guard.sh', '#!/usr/bin/env bash\nexit 0\n', true);
  write(root, '.claude/scripts/contract-pin.sh', 'repo=Vikteur/rekord-contract\n', true);
  write(root, '.archon/scripts/test/x.test.sh', 'excluded\n');
  write(root, 'docs/scaffold-templates/a/resource.mustache', 'import jakarta.ws.rs.GET;\n');
  write(root, 'docs/scaffold-templates/a/entity.mustache', 'record {{name}}() {}\n');
  write(root, 'docs/code-maps/README.md', '# Code maps\n');
  write(root, 'docs/code-maps/java.md', '---\nkind: worked-example\n---\nJava.\n');
  write(root, 'docs/code-maps/flyway.md', '---\nkind: project\n---\nProject facts.\n');
  write(
    root,
    'docs/code-maps/exemplars/x.md',
    '---\nkind: worked-example\nserves: [java, resilience4j]\n---\nX.\n'
  );
  write(root, 'README.md', 'outside the scanned roots\n');
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'fixture');
  return root;
}

const NO_REWRITES: Record<string, Rewrite[]> = {};

describe('agent conversion', () => {
  const out = convertAgent(AGENT, 'developer.md');

  test('maps the model, the tools and the MCP servers', () => {
    expect(out).toContain('model: "claude-sonnet-5.5"');
    expect(out).toContain(
      'tools: ["read", "search", "edit", "execute", "agent", "codegraph/*", "@@KIT_CONTRACT_SERVER_NAME@@/search"]'
    );
    expect(out).toContain('mcp-servers:\n  "@@KIT_CONTRACT_SERVER_NAME@@":\n    type: "local"');
    expect(out).toContain('    args: ["scripts/portal-mcp/server.mjs"]\n    tools: ["*"]');
    expect(out).not.toContain('alwaysLoad');
    expect(out).toContain('include-custom-instructions: true');
  });

  test('turns skills into a first line and notes what Copilot lacks', () => {
    expect(out).toContain('---\nLoad these skills first: tdd-loop, clean-code.\n\n# Developer');
    expect(out).toContain('Ask @@KIT_CONTRACT_SERVER_NAME@@ first; my-portal-api-thing stays.');
    expect(out).toContain('## On Copilot CLI');
    expect(out).toContain('`SendMessage`');
    expect(out).toContain('`git add *`');
    expect(out).toContain('Delegate only to these agents: `github-agent`.');
  });

  test('fails on a tool it cannot map', () => {
    expect(() => convertAgent(AGENT.replace('  - Read\n', '  - TeleportTool\n'), 'x')).toThrow(
      /TeleportTool/
    );
  });
});

describe('skill frontmatter', () => {
  const out = convertSkillMd(SKILL);

  test('keeps name, description and allowed-tools, drops the rest', () => {
    const front = out.split('---')[1] ?? '';
    expect(front).toContain('name: grill-pr');
    expect(front).toContain('description: >-\n  Read-only grilling.');
    expect(front).toContain('allowed-tools: Read, Grep, Bash(git diff *)');
    expect(front).not.toContain('disable-model-invocation');
    expect(front).not.toContain('argument-hint');
    expect(front).not.toContain('disallowed-tools');
  });

  test('notes the dropped invocation rule and the withheld tools', () => {
    expect(out).toContain('only when the user names it');
    expect(out).toContain('`Edit(./**)`, `Bash(git add *, git commit *)`');
  });

  test('a skill without frontmatter is unchanged', () => {
    expect(convertSkillMd('# plain\n')).toBe('# plain\n');
  });
});

describe('hooks', () => {
  test('parses both settings.json command shapes', () => {
    expect(parseHookCommand(SETTINGS.hooks.PreToolUse[0]?.hooks[0]?.command ?? '')).toEqual({
      script: '.claude/hooks/scripts/guard.sh',
      args: ['PreToolUse'],
    });
    expect(parseHookCommand(SETTINGS.hooks.SessionStart[0]?.hooks[0]?.command ?? '')).toEqual({
      script: '.archon/scripts/delegator-session.sh',
      args: ['sessionStart'],
    });
    expect(() => parseHookCommand('node foo.js')).toThrow(/not understood/);
  });

  test('maps the events and keeps the matcher for the dispatcher', () => {
    const kit = JSON.parse(convertHooks(SETTINGS)) as {
      version: number;
      hooks: Record<string, { bash: string; timeoutSec: number }[]>;
    };
    expect(kit.version).toBe(1);
    expect(Object.keys(kit.hooks)).toEqual(['preToolUse', 'sessionStart']);
    expect(kit.hooks.preToolUse?.[0]).toEqual({
      type: 'command',
      bash: "bash .github/hooks/dispatch.sh PreToolUse 'Write|Edit|Bash' .claude/hooks/scripts/guard.sh PreToolUse",
      timeoutSec: 20,
    } as never);
    expect(kit.hooks.sessionStart?.[0]?.timeoutSec).toBe(60);
    expect(() => convertHooks({ hooks: { Notification: [] } })).toThrow(/Notification/);
  });

  test('copies permissions.deny', () => {
    expect(JSON.parse(convertDeny(SETTINGS))).toEqual(['Bash(rm -rf /*)', 'Read(./.env)']);
  });

  test('the dispatcher applies the matcher and turns exit 2 into a deny', () => {
    const root = track(mkdtempSync(join(tmpdir(), 'kit-sync-dispatch-')));
    write(root, '.github/hooks/dispatch.sh', DISPATCH_SH, true);
    write(
      root,
      '.claude/hooks/scripts/block.sh',
      '#!/usr/bin/env bash\necho "no edits here" >&2\nexit 2\n'
    );
    const run = (matcher: string, payload: string): string => {
      const r = Bun.spawnSync(
        [
          'bash',
          '.github/hooks/dispatch.sh',
          'PreToolUse',
          matcher,
          '.claude/hooks/scripts/block.sh',
        ],
        {
          cwd: root,
          stdin: Buffer.from(payload),
          env: { ...process.env, CLAUDE_PROJECT_DIR: root },
          stdout: 'pipe',
          stderr: 'pipe',
        }
      );
      expect(r.exitCode).toBe(0);
      return r.stdout.toString();
    };
    const denied = JSON.parse(run('Edit|Write', '{"tool_name":"Edit"}')) as Record<string, unknown>;
    expect(denied.permissionDecision).toBe('deny');
    expect(String(denied.permissionDecisionReason)).toContain('no edits here');
    expect(run('Edit|Write', '{"tool_name":"Bash"}')).toBe('');
    expect(run('Edit', '{"tool_name":"EditNotebook"}')).toBe('');
  });
});

describe('rules', () => {
  test('a layer rule applies to the kit.yaml module glob', () => {
    const out = convertRule(
      'domain',
      '---\npaths:\n  - "**/*-domain/**"\n---\n# Domain\n',
      KIT_MODULES
    );
    expect(out).toBe('---\napplyTo: "@@KIT_MODULES_DOMAIN@@"\n---\n# Domain\n');
  });

  test('a rule without paths applies everywhere; other paths are kept', () => {
    expect(convertRule('general', '# General\n', KIT_MODULES)).toBe(
      '---\napplyTo: "**"\n---\n# General\n'
    );
    expect(convertRule('web', '---\npaths: ["a/**", "b/**"]\n---\nx\n', KIT_MODULES)).toBe(
      '---\napplyTo: "a/**,b/**"\n---\nx\n'
    );
  });
});

describe('placeholders and rewrites', () => {
  test('a targeted rewrite fails when its count does not fit', () => {
    expect(applyRewrites('f', 'main main', [['main', '@@KIT_BASE_BRANCH@@', 2]])).toBe(
      '@@KIT_BASE_BRANCH@@ @@KIT_BASE_BRANCH@@'
    );
    expect(() => applyRewrites('f', 'main', [['main', 'x', 2]])).toThrow(/expected 2/);
  });

  test('the main checkout path becomes the built-in project-dir placeholder', () => {
    expect(applyGlobalRewrites('"Bash(cd /home/viktor/wedding-portal &&*)"')).toBe(
      '"Bash(cd @@KIT_PROJECT_DIR@@ &&*)"'
    );
    expect(applyGlobalRewrites('/home/viktor/wedding-portal-wt/x')).toBe(
      '/home/viktor/wedding-portal-wt/x'
    );
    expect(
      leakCheck([{ profile: 'core', path: 'a', content: 'cd @@KIT_PROJECT_DIR@@' }]).failures
    ).toEqual([]);
  });

  test('the global rewrites move skill paths and the contract repo', () => {
    expect(
      applyGlobalRewrites('bash .claude/skills/run-wedding-portal/x.sh run-wedding-portal')
    ).toBe('bash .github/skills/run-app/x.sh run-app');
    expect(applyGlobalRewrites('".claude\\skills\\gh" .claude/skills-old')).toBe(
      '".github\\skills\\gh" .claude/skills-old'
    );
    expect(applyGlobalRewrites('gh repo clone Vikteur/rekord-contract')).toBe(
      'gh repo clone @@KIT_CONTRACT_REPO@@'
    );
  });
});

describe('leak check', () => {
  test('fails on a home path, an owner account and a token; warns on project nouns', () => {
    const r = leakCheck([
      { profile: 'core', path: 'a', content: 'cd /home/viktor/x' },
      { profile: 'core', path: 'b', content: 'as Vikteur' },
      { profile: 'java', path: 'c', content: `token ghp_${'a'.repeat(36)}` },
      { profile: 'java', path: 'd', content: 'the wedding portal' },
      { profile: 'java-quarkus', path: 'e', content: 'the wedding portal' },
      { profile: 'core', path: 'f', content: 'clean' },
    ]);
    expect(r.failures.map(f => f.split(':')[0])).toEqual(['core/a', 'core/b', 'java/c']);
    expect(r.warnings).toEqual(['java/d (2)']);
  });
});

describe('never-ship files', () => {
  test('night-preflight is in no profile', () => {
    for (const p of NEVER_SHIP)
      expect(classify(p, '')).toEqual({ exclude: true, why: 'never ships' });
    expect(NEVER_SHIP).toContain('.archon/scripts/night-preflight.sh');
  });

  test("the delegator's night step 6 is dropped and step 7 renumbered", () => {
    const night = [
      '5. Commit the ticket edits.',
      '6. The owner runs `night-preflight.sh` (it is no delegator tool). Start nothing until the owner says it printed GO;',
      '   help fix each NO-GO it names.',
      '7. **Build the list one ticket after another** (`pick-tickets.js`)',
      '',
    ].join('\n');
    const out = applyRewrites('.claude/agents/delegator.md', night, [DELEGATOR_NIGHT_STEP]);
    expect(out).toBe(
      '5. Commit the ticket edits.\n6. **Build the list one ticket after another** (`pick-tickets.js`)\n'
    );
    expect(neverShipRefs({ profile: 'core', path: 'x', content: out })).toEqual([]);
  });

  test('a changed night step fails the sync loudly', () => {
    const drifted = '6. The owner runs `night-preflight.sh` first.\n7. **Build the list\n';
    expect(() =>
      applyRewrites('.claude/agents/delegator.md', drifted, [DELEGATOR_NIGHT_STEP])
    ).toThrow(/rewrite expected 1 of .*found 0/);
  });

  test('a shipped reference to a never-ship script fails, but the fence test may deny it', () => {
    const r = leakCheck([
      { profile: 'core', path: 'docs/a.md', content: 'ok\nrun `night-preflight.sh` first' },
      {
        profile: 'core',
        path: 'docs/b.md',
        content: 'the night-preflight-ish word and night-list.txt',
      },
      {
        profile: 'core',
        path: '.archon/scripts/test/delegator-fence.test.sh',
        content: `case_ "no night-preflight.sh" deny "$(cmd_ 'bash night-preflight.sh')"\nallow night-preflight.sh`,
      },
    ]);
    expect(r.failures).toEqual([
      'core/docs/a.md:2: names never-ship night-preflight.sh',
      'core/.archon/scripts/test/delegator-fence.test.sh:2: names never-ship night-preflight.sh',
    ]);
  });
});

describe('sync on a fixture repo', () => {
  test('assigns, converts and records every file', () => {
    const src = fixture();
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-out-')));
    const r = sync(src, out, false, NO_REWRITES);
    expect(r.kit.failures).toEqual([]);
    const manifest = JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8')) as {
      source: { name: string; commit: string };
      files: {
        path: string;
        profile: string;
        mode: string;
        template: boolean;
        origin: string | null;
        kind: string;
      }[];
    };
    expect(manifest.source).toEqual({
      name: 'sample-app',
      commit: git(src, 'rev-parse', 'HEAD').trim(),
    });
    const keys = manifest.files.map(f => `${f.profile}/${f.path}`);
    expect(keys).toEqual([
      'core/.archon/copilot/deny.json',
      'core/.claude/hooks/scripts/guard.sh',
      'core/.github/hooks/dispatch.sh',
      'core/.github/hooks/kit.json',
      'core/.github/instructions/general.instructions.md',
      'core/.github/mcp.json',
      'core/.github/skills/grill-pr/SKILL.md',
      'core/docs/code-maps/README.md',
      'java/.github/agents/developer.agent.md',
      'java/.github/instructions/domain.instructions.md',
      'java/docs/code-maps/java.md',
      'java/docs/scaffold-templates/a/entity.mustache',
      'java-quarkus/.github/skills/run-app/SKILL.md',
      'java-quarkus/.github/skills/run-app/scripts/smoke.sh',
      'java-quarkus/docs/code-maps/exemplars/x.md',
      'java-quarkus/docs/scaffold-templates/a/resource.mustache',
      'openapi-contract/.claude/scripts/contract-pin.sh',
      'openapi-contract/.github/mcp.json',
    ]);
    const byKey = new Map(manifest.files.map(f => [`${f.profile}/${f.path}`, f]));
    expect(byKey.get('java-quarkus/.github/skills/run-app/scripts/smoke.sh')?.mode).toBe('0755');
    expect(byKey.get('core/.github/skills/grill-pr/SKILL.md')?.kind).toBe('skill');
    expect(byKey.get('openapi-contract/.claude/scripts/contract-pin.sh')).toMatchObject({
      template: true,
      origin: '.claude/scripts/contract-pin.sh',
      kind: 'script',
    });
    expect(byKey.get('core/.github/hooks/dispatch.sh')).toMatchObject({
      origin: null,
      kind: 'hook',
      mode: '0755',
    });
    const skill = readFileSync(join(out, 'profiles/core/.github/skills/grill-pr/SKILL.md'), 'utf8');
    expect(skill).toContain(
      '.github/skills/grill-pr/references and .github/skills/run-app/SKILL.md'
    );
    expect(verifyKit(out)).toEqual([]);
    write(out, 'kit.defaults.yaml', 'base_branch: main\n');
    const bundled = renderBundledKit(out);
    expect(bundled).toContain('// AUTO-GENERATED by scripts/generate-bundled-kit.ts');
    expect(bundled).toContain(
      '"java-quarkus/.github/skills/run-app/scripts/smoke.sh": "#!/usr/bin/env bash\\necho ok\\n",'
    );
  });

  test('is deterministic', () => {
    const src = fixture();
    const a = track(mkdtempSync(join(tmpdir(), 'kit-sync-a-')));
    const b = track(mkdtempSync(join(tmpdir(), 'kit-sync-b-')));
    sync(src, a, false, NO_REWRITES);
    sync(src, b, false, NO_REWRITES);
    expect(snapshot(b)).toEqual(snapshot(a));
    expect(readFileSync(join(a, 'manifest.json'), 'utf8')).not.toMatch(/20\d\d-\d\d-\d\dT/);
  });

  test('--check reports drift, and --verify finds it without the source', () => {
    const src = fixture();
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-check-')));
    sync(src, out, false, NO_REWRITES);
    expect(sync(src, out, true, NO_REWRITES).drift).toEqual([]);
    write(out, 'profiles/java/docs/code-maps/java.md', 'edited by hand\n');
    write(out, 'profiles/core/stray.txt', 'x\n');
    expect(sync(src, out, true, NO_REWRITES).drift).toEqual([
      'changed: profiles/java/docs/code-maps/java.md',
      'extra: profiles/core/stray.txt',
    ]);
    expect(verifyKit(out)).toEqual([
      'changed: profiles/java/docs/code-maps/java.md (sha256 differs from manifest)',
      'extra: profiles/core/stray.txt',
    ]);
  });

  test('an unassigned source file fails the sync', () => {
    const src = fixture();
    write(src, '.claude/agents/stranger.md', '---\nname: stranger\n---\n');
    git(src, 'add', '-A');
    git(src, 'commit', '-q', '-m', 'stranger');
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-unassigned-')));
    expect(() => sync(src, out, false, NO_REWRITES)).toThrow(
      /stranger.md: agent not on a copy list/
    );
    expect(() => classify('.claude/unknown/x.sh', '')).toThrow(/not on a copy list/);
  });

  test('a leak fails the sync and writes nothing', () => {
    const src = fixture();
    write(src, '.claude/hooks/scripts/guard.sh', '#!/usr/bin/env bash\ncd /home/viktor/app\n');
    git(src, 'commit', '-q', '-am', 'leak');
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-leak-')));
    const r = sync(src, out, false, NO_REWRITES);
    expect(r.kit.failures).toEqual([
      'core/.claude/hooks/scripts/guard.sh: home path (/home/viktor...)',
    ]);
    expect(snapshot(out).size).toBe(0);
  });

  test('overlays are copied in, and --check reports a stale one', () => {
    const src = fixture();
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-overlay-')));
    const sha = new Bun.CryptoHasher('sha256')
      .update(readFileSync(join(src, '.claude/skills/run-wedding-portal/SKILL.md')))
      .digest('hex');
    write(
      out,
      'overlays/java-spring/overlay.json',
      JSON.stringify({
        '.github/skills/run-app/SKILL.md': {
          derivedFrom: '.claude/skills/run-wedding-portal/SKILL.md',
          sourceSha256: sha,
        },
      })
    );
    write(
      out,
      'overlays/java-spring/.github/skills/run-app/SKILL.md',
      '---\nname: run-app\n---\nSpring.\n'
    );
    const r = sync(src, out, false, NO_REWRITES);
    expect(r.stale).toEqual([]);
    const f = (
      JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8')) as {
        files: { profile: string; origin: string }[];
      }
    ).files.find(x => x.profile === 'java-spring');
    expect(f?.origin).toBe('.claude/skills/run-wedding-portal/SKILL.md');
    expect(verifyKit(out)).toEqual([]);

    write(
      src,
      '.claude/skills/run-wedding-portal/SKILL.md',
      '---\nname: run-wedding-portal\ndescription: Run.\n---\nNew.\n'
    );
    git(src, 'commit', '-q', '-am', 'change');
    const check = sync(src, out, true, NO_REWRITES);
    expect(check.stale.length).toBe(1);
    expect(check.stale[0]).toContain('java-spring/.github/skills/run-app/SKILL.md');
  });
});
