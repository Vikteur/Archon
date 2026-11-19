import { describe, expect, test } from 'bun:test';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { trackTempRoots } from '@archon/paths/test-utils';
import { renderBundledKit } from './generate-bundled-kit';
import { depsCheck, installableSets, judgeDeps, KNOWN_GAPS } from './kit-sync-deps';
import { genericThisRepo, renamePath } from './kit-sync-generic';
import { applySuiteNouns, classifySuite, suiteOf, suiteSubject } from './kit-sync-tests';
import {
  applyGlobalRewrites,
  applyRewrites,
  CODEGRAPH_CLI,
  CONTRACT_CLI,
  classify,
  convertAgent,
  convertDeny,
  convertHooks,
  convertRule,
  convertSkillMd,
  DELEGATOR_NIGHT_STEP,
  DISPATCH_SH,
  fencedAgents,
  KIT_MODULES,
  leakCheck,
  mcpFallbackCommands,
  NEVER_SHIP,
  neverShipRefs,
  parseHookCommand,
  type Rewrite,
  snapshot,
  sync,
  verifyKit,
  WORKFLOW_FALLBACK,
  withMcpFallbackScopes,
  withWorkflowFallback,
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
  write(
    root,
    '.claude/hooks/agent-scopes.json',
    '{"_comment":"fences","agents":{"developer":{"commandAllowlist":["git add"]},"retro":{"commandAllowlist":["git log"]}}}\n'
  );
  write(root, '.claude/scripts/contract-pin.sh', 'repo=Vikteur/rekord-contract\n', true);
  write(
    root,
    '.archon/scripts/test/guard.test.sh',
    'bash .claude/hooks/scripts/guard.sh # wedding-portal\n'
  );
  write(root, 'scripts/test/image.test.sh', 'excluded\n');
  write(root, 'docs/scaffold-templates/a/resource.mustache', 'import jakarta.ws.rs.GET;\n');
  write(root, 'docs/scaffold-templates/a/entity.mustache', 'record {{name}}() {}\n');
  write(root, 'docs/code-maps/README.md', '# Code maps\n');
  write(
    root,
    'docs/code-maps/java.md',
    '---\nkind: worked-example\n---\n## This repo (sample-app)\nOur modules.\n\n## Where this pattern lives\nJava.\n'
  );
  write(root, 'docs/code-maps/flyway.md', '---\nkind: project\n---\nProject facts.\n');
  write(
    root,
    'docs/code-maps/exemplars/x.md',
    '---\nkind: worked-example\nserves: [java, resilience4j]\n---\nX.\n'
  );
  write(root, 'scripts/portal-mcp/server.mjs', 'export {};\n');
  write(root, 'scripts/portal-mcp/tools.mjs', 'export {};\n');
  write(root, 'scripts/portal-mcp/cli.mjs', "import './tools.mjs';\n");
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

  test('a fenced agent runs scope-guard from its own frontmatter hook, naming itself', () => {
    expect(out).not.toContain('hooks:');
    const fenced = convertAgent(AGENT, 'developer.md', new Set(['developer']));
    expect(fenced).toContain(
      'hooks:\n  preToolUse:\n    - type: "command"\n      command: "env KIT_AGENT=developer bash .github/hooks/dispatch.sh PreToolUse \'*\' .claude/hooks/scripts/scope-guard.sh PreToolUse"\n      timeoutSec: 60\ninclude-custom-instructions: true\n---'
    );
    expect(fencedAgents('{"_comment":"x","agents":{"developer":{},"analyst":{}}}')).toEqual(
      new Set(['developer', 'analyst'])
    );
    expect(fencedAgents(undefined).size).toBe(0);
  });

  test('fails on a tool it cannot map', () => {
    expect(() => convertAgent(AGENT.replace('  - Read\n', '  - TeleportTool\n'), 'x')).toThrow(
      /TeleportTool/
    );
  });
});

describe('MCP fallback (the kit only)', () => {
  const ALL = [...CODEGRAPH_CLI, CONTRACT_CLI];
  const noMcp = AGENT.replace('  - mcp__codegraph__*\n  - mcp__portal-api__search\n', '');
  const codegraphOnly = AGENT.replace('  - mcp__portal-api__search\n', '');
  const noShell = AGENT.replace('  - Bash(git add *)\n', '');

  test('the commands follow the MCP tools, and only for an agent with a shell', () => {
    expect(CODEGRAPH_CLI).toEqual([
      'codegraph explore',
      'codegraph node',
      'codegraph callers',
      'codegraph callees',
      'codegraph impact',
      'codegraph query',
    ]);
    expect(CONTRACT_CLI).toBe('node scripts/contract-mcp/cli.mjs');
    expect(
      mcpFallbackCommands(['Bash(git add *)', 'mcp__codegraph__*', 'mcp__portal-api__read'])
    ).toEqual(ALL);
    expect(mcpFallbackCommands('Read, Bash, mcp__codegraph__codegraph_explore')).toEqual(
      CODEGRAPH_CLI
    );
    expect(mcpFallbackCommands(['Bash(git add *)', 'mcp__portal-api__where'])).toEqual([
      CONTRACT_CLI,
    ]);
    expect(mcpFallbackCommands(['Bash(git add *)', 'Read'])).toEqual([]);
    expect(mcpFallbackCommands(['Read', 'mcp__codegraph__*'])).toEqual([]);
  });

  test('an agent with the MCP tools gets the commands on its shell note and the fallback paragraph once', () => {
    const out = convertAgent(AGENT, 'developer.md');
    expect(out).toContain(
      "Claude Code limits this agent's shell to these commands; keep to them: `git add *`. On Copilot CLI the MCP fallback below adds: `codegraph explore *`, `codegraph node *`, `codegraph callers *`, `codegraph callees *`, `codegraph impact *`, `codegraph query *`, `node scripts/contract-mcp/cli.mjs *`."
    );
    expect(out.split('MCP fallback:')).toHaveLength(2);
    expect(out).toContain('`codegraph explore "<question or names>"`');
    expect(out).toContain(
      'for `@@KIT_CONTRACT_SERVER_NAME@@/*`, `node scripts/contract-mcp/cli.mjs <tool> <args>`'
    );
    expect(out).toContain('no other codegraph subcommand');
    expect(convertAgent(AGENT, 'developer.md')).toBe(out);
  });

  test('an agent without the MCP tools, or without a shell, gets none; codegraph alone gets only its part', () => {
    for (const text of [noMcp, noShell]) {
      const out = convertAgent(text, 'developer.md');
      expect(out).not.toContain('MCP fallback');
      expect(out).not.toContain('codegraph explore');
    }
    expect(convertAgent(noShell, 'developer.md')).not.toContain('"execute"');
    const cg = convertAgent(codegraphOnly, 'developer.md');
    expect(cg.split('MCP fallback:')).toHaveLength(2);
    expect(cg).toContain('`codegraph query *`.');
    expect(cg).not.toContain('cli.mjs');
  });

  test('agent-scopes.json gets the commands on a fenced allowlist, once, and is untouched otherwise', () => {
    const json = `${JSON.stringify(
      {
        _comment: 'fences',
        agents: {
          developer: {
            allowedFilePaths: ['src/'],
            commandAllowlist: ['git add', 'codegraph explore'],
          },
          reviewer: { commandAllowlist: ['git diff'] },
          retro: { allowedFilePaths: [] },
        },
      },
      null,
      2
    )}\n`;
    const fallbacks = new Map([
      ['developer', ALL],
      ['retro', CODEGRAPH_CLI],
      ['ghost', ALL],
    ]);
    const out = withMcpFallbackScopes(json, fallbacks);
    const agents = (JSON.parse(out) as { agents: Record<string, Record<string, unknown>> }).agents;
    expect(agents.developer?.commandAllowlist).toEqual(['git add', ...ALL]);
    expect(agents.reviewer?.commandAllowlist).toEqual(['git diff']);
    expect(agents.retro).toEqual({ allowedFilePaths: [] });
    expect(agents.ghost).toBeUndefined();
    expect(withMcpFallbackScopes(out, fallbacks)).toBe(out);
    const compact = '{"agents":{"reviewer":{"commandAllowlist":["git diff"]}}}\n';
    expect(withMcpFallbackScopes(compact, fallbacks)).toBe(compact);
  });

  test.skipIf(!Bun.which('jq'))(
    "the kit's scope-guard lets the fallback commands through, also behind rtk",
    () => {
      const root = track(mkdtempSync(join(tmpdir(), 'kit-sync-guard-')));
      const hooks = join(import.meta.dir, '../kit/profiles/core/.claude/hooks/scripts');
      for (const f of ['scope-guard.sh', 'payload.sh'])
        write(root, `.claude/hooks/scripts/${f}`, readFileSync(join(hooks, f), 'utf8'), true);
      const policy = withMcpFallbackScopes(
        '{"agents":{"developer":{"commandAllowlist":["git add"]}}}\n',
        new Map([['developer', ALL]])
      );
      write(root, '.claude/hooks/agent-scopes.json', policy);
      const guard = (command: string): string => {
        const payload = JSON.stringify({
          agent_type: 'developer',
          tool_name: 'Bash',
          tool_input: { command },
          cwd: root,
        });
        const r = Bun.spawnSync(['bash', '.claude/hooks/scripts/scope-guard.sh'], {
          cwd: root,
          stdin: Buffer.from(payload),
          env: { ...process.env, CLAUDE_PROJECT_DIR: root, KIT_AGENT: '' },
          stdout: 'pipe',
          stderr: 'pipe',
        });
        expect(r.exitCode).toBe(0);
        return r.stdout.toString();
      };
      for (const ok of [
        'codegraph explore "how does the vendor cancel work"',
        'codegraph node CancelVendorUseCase',
        'codegraph node --file src/a.java',
        'codegraph callers cancel',
        'codegraph callees cancel',
        'codegraph impact cancel',
        'codegraph query cancel',
        'node scripts/contract-mcp/cli.mjs search cancel vendor',
        'node scripts/contract-mcp/cli.mjs where --status stub',
        'rtk codegraph explore "x"',
        'rtk node scripts/contract-mcp/cli.mjs read cancelVendor',
        'git add a && codegraph impact x',
      ])
        expect(guard(ok)).toBe('');
      for (const no of [
        'codegraph sync',
        'codegraph index',
        'codegraph init',
        'codegraph unlock',
        'codegraph daemon',
        'codegraph',
        'codegraph explorex',
        'codegraph explore x; codegraph sync',
        'codegraph explore $(cat /etc/passwd)',
        'node scripts/contract-mcp/server.mjs',
        'node scripts/contract-mcp/cli.mjsx',
        'rtk codegraph sync',
      ])
        expect(guard(no)).toContain('"permissionDecision":"deny"');
    }
  );

  test('the Copilot workflow gets the CLI sentence after every MCP paragraph, once', () => {
    const line =
      'Grep stays the tool for text, config, logs and strings; without the tools, read as before.';
    const yaml = `a:\n  prompt: |\n      ${line}\n      Next.\nb:\n  prompt: |\n            ${line}\n`;
    const out = withWorkflowFallback(yaml, 'wf.yaml');
    expect(out).toBe(
      `a:\n  prompt: |\n      ${line}\n      ${WORKFLOW_FALLBACK}\n      Next.\nb:\n  prompt: |\n            ${line}\n            ${WORKFLOW_FALLBACK}\n`
    );
    expect(withWorkflowFallback(out, 'wf.yaml')).toBe(out);
    expect(WORKFLOW_FALLBACK).toContain(
      '`node scripts/contract-mcp/cli.mjs search|read|where|schema|usedBy <args>`'
    );
    expect(() => withWorkflowFallback('a: 1\n', 'wf.yaml')).toThrow(/MCP_PROMPT_END/);
  });

  test('an agent that names the contract CLI needs it; without openapi-contract that is a known gap', () => {
    const agent = convertAgent(AGENT, 'developer.md');
    const lines = depsCheck([
      { profile: 'java', path: '.github/agents/developer.agent.md', content: agent },
      { profile: 'openapi-contract', path: 'scripts/contract-mcp/server.mjs', content: '' },
    ]);
    expect(lines).toContain(
      'core,java,openapi-contract: .github/agents/developer.agent.md needs scripts/contract-mcp/cli.mjs (its MCP fallback)'
    );
    const r = judgeDeps(lines.filter(l => l.includes('cli.mjs')));
    expect(r.failures.length).toBeGreaterThan(0);
    expect(r.failures.every(l => l.includes(',openapi-contract:'))).toBe(true);
    expect(r.known.some(l => l.startsWith('core,java: ') && l.includes('cli.mjs'))).toBe(true);
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

describe('project nouns and Copilot paths', () => {
  test('the contract server, its scripts and the pin key become generic', () => {
    expect(
      applyGlobalRewrites(
        'mcp__portal-api__read portal-api scripts/portal-mcp/x portal-mcp: up portal-metrics rekordContractTag my-portal-api'
      )
    ).toBe(
      'mcp__@@KIT_CONTRACT_SERVER_NAME@@__read @@KIT_CONTRACT_SERVER_NAME@@ scripts/contract-mcp/x contract-mcp: up run-metrics @@KIT_CONTRACT_TAG_KEY@@ my-portal-api'
    );
    expect(applyGlobalRewrites('WorkingDirectory=%h/wedding-portal')).toBe(
      'WorkingDirectory=@@KIT_PROJECT_DIR@@'
    );
    expect(renamePath('scripts/portal-mcp/server.mjs')).toBe('scripts/contract-mcp/server.mjs');
    expect(renamePath('.archon/workflows/portal-metrics.yaml')).toBe(
      '.archon/workflows/run-metrics.yaml'
    );
    expect(renamePath('scripts/other.sh')).toBe('scripts/other.sh');
  });

  test('agent, rule and skill paths move to .github, except in the files that mean the Claude ones', () => {
    const text =
      'see .claude/agents/developer.md, .claude/agents/, .claude/rules/domain.md and .claude/skills/x';
    expect(applyGlobalRewrites(text, 'a.md')).toBe(
      'see .github/agents/developer.agent.md, .github/agents/, .github/instructions/domain.instructions.md and .github/skills/x'
    );
    expect(applyGlobalRewrites('.github/agents/developer.agent.md', 'a.md')).toBe(
      '.github/agents/developer.agent.md'
    );
    expect(applyGlobalRewrites(text, '.claude/hooks/scripts/audit-log.sh')).toBe(text);
  });

  test("a listed leaf's This repo section ships as the stub; an unlisted one fails", () => {
    const leaf = '# X\n## This repo (src)\nOur facts.\n\n## Where this pattern lives\nExample.\n';
    const out = genericThisRepo('docs/code-maps/java.md', 'java', leaf);
    expect(out).not.toContain('Our facts');
    expect(out).toContain('## This repo\nFill in');
    expect(out).toContain('## Where this pattern lives\nExample.');
    expect(() => genericThisRepo('docs/code-maps/java.md', 'java', '# X\n')).toThrow(
      /no "## This repo/
    );
    expect(() => genericThisRepo('docs/code-maps/new.md', 'core', leaf)).toThrow(
      /THIS_REPO_LEAVES/
    );
    expect(genericThisRepo('docs/code-maps/new.md', 'java-quarkus', leaf)).toBe(leaf);
  });
});

describe('dependency check', () => {
  test('enumerates the installable sets', () => {
    const sets = installableSets().map(s => s.join(','));
    expect(sets).toHaveLength(8);
    expect(sets).toContain('core');
    expect(sets).toContain('core,java,java-spring,openapi-contract');
    expect(sets.some(s => s.includes('java-quarkus') && s.includes('java-spring'))).toBe(false);
    expect(sets.some(s => s.includes('java-quarkus') && !s.includes(',java,'))).toBe(false);
  });

  test('a set without a file a shipped script, leaf or agent needs is named', () => {
    const files = [
      { profile: 'core', path: '.claude/scripts/ci-local.sh', content: '' },
      { profile: 'java-quarkus', path: '.github/workflows/ci.yml', content: '' },
      {
        profile: 'java',
        path: 'docs/code-maps/x.md',
        content: '| [t](../scaffold-templates/a/t.mustache) | `src/**` |\n',
      },
      { profile: 'java-quarkus', path: 'docs/scaffold-templates/a/t.mustache', content: '' },
      {
        profile: 'java',
        path: '.github/agents/d.agent.md',
        content: '    args: ["scripts/contract-mcp/server.mjs"]\n',
      },
      { profile: 'openapi-contract', path: 'scripts/contract-mcp/server.mjs', content: '' },
    ];
    const lines = depsCheck(files);
    expect(lines).toContain(
      'core,java: .claude/scripts/ci-local.sh needs .github/workflows/ci.yml (it reads it)'
    );
    expect(lines).toContain(
      'core,java,java-spring: docs/code-maps/x.md needs docs/scaffold-templates/a/t.mustache (its ## Scaffold table (targets.js))'
    );
    expect(lines).toContain(
      'core,java,java-quarkus: .github/agents/d.agent.md needs scripts/contract-mcp/server.mjs (its mcp-servers entry)'
    );
    expect(lines.some(l => l.startsWith('core: '))).toBe(false);
    const ci = depsCheck([
      {
        profile: 'java-spring',
        path: '.github/workflows/ci.yml',
        content:
          'run: bash scripts/test/a.test.sh && bash .archon/scripts/test/b.test.sh scripts/test/*.test.sh\n',
      },
      { profile: 'java', path: 'scripts/test/a.test.sh', content: '' },
    ]);
    expect(ci).toContain(
      'core,java,java-spring: .github/workflows/ci.yml needs .archon/scripts/test/b.test.sh (a CI step runs it)'
    );
    expect(ci.some(l => l.includes('needs scripts/test/a.test.sh'))).toBe(false);
    expect(lines.some(l => l.startsWith('core,java,java-quarkus,openapi-contract: '))).toBe(false);
  });

  test('a known gap is reported, an unknown one fails, an unused entry is named', () => {
    const r = judgeDeps([
      'core,java: .claude/scripts/ci-local.sh needs .github/workflows/ci.yml (it reads it)',
      'core,java,java-quarkus: docs/code-maps/x.md needs docs/y (z)',
    ]);
    expect(r.known).toHaveLength(1);
    expect(r.failures).toEqual(['core,java,java-quarkus: docs/code-maps/x.md needs docs/y (z)']);
    expect(r.unused).toHaveLength(KNOWN_GAPS.length - 1);
  });
});

describe('test suites', () => {
  const files = new Set([
    '.claude/hooks/scripts/guard.sh',
    'scripts/scaffold/targets.js',
    'scripts/scaffold/index.js',
    '.claude/hooks/scripts/audit-log.sh',
  ]);
  const judge = (p: string) =>
    p.startsWith('scripts/scaffold/')
      ? ({ profile: 'java' } as const)
      : p.includes('guard')
        ? ({ profile: 'core' } as const)
        : ({ exclude: true, why: 'never ships' } as const);

  test('a suite ships with the profile of the script it tests, found by stem or by name', () => {
    expect(suiteSubject('.archon/scripts/test/guard.test.sh', files)).toBe(
      '.claude/hooks/scripts/guard.sh'
    );
    expect(suiteSubject('scripts/test/scaffold-x.test.sh', files)).toBeUndefined();
    expect(
      suiteSubject(
        'scripts/test/scaffold.test.sh',
        new Set(['scripts/scaffold/b.js', 'scripts/scaffold/a.js'])
      )
    ).toBe('scripts/scaffold/a.js');
    expect(suiteSubject('scripts/test/audit-log-args.test.sh', files)).toBe(
      '.claude/hooks/scripts/audit-log.sh'
    );
    expect(classifySuite('.archon/scripts/test/guard.test.sh', files, judge)).toEqual({
      profile: 'core',
    });
  });

  test('a listed suite stays out with its reason, and so do its fixtures', () => {
    const a = classifySuite('scripts/test/image.test.sh', files, judge);
    expect(a).toMatchObject({ exclude: true });
    expect(a.exclude && a.why).toContain('suite stays out:');
    expect(suiteOf('scripts/test/fixtures/tokenomics/prices.json')).toBe(
      'scripts/test/tokenomics.test.sh'
    );
    expect(
      classifySuite('scripts/test/fixtures/tokenomics/prices.json', files, judge)
    ).toMatchObject({
      exclude: true,
    });
  });

  test('an unknown suite, an unshipped subject and a stray test-folder file fail', () => {
    expect(() => classifySuite('scripts/test/nothing.test.sh', files, judge)).toThrow(
      /no script found for the suite/
    );
    expect(() => classifySuite('scripts/test/audit-log-args.test.sh', files, judge)).toThrow(
      /does not ship \(never ships\)/
    );
    expect(() => suiteOf('scripts/test/helper.sh')).toThrow(/no suite and no listed fixture/);
  });

  test("the source's nouns become neutral ones", () => {
    expect(
      applySuiteNouns('Viktor Van Steenweghen runs wedding-portal-hooks on WeddingId in app.rekord')
    ).toBe('Example Owner runs project-hooks on OrderId in com.example');
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
      { profile: 'core', path: 'g', content: '"owner": "Viktor Van Steenweghen"' },
    ]);
    expect(r.failures.map(f => f.split(':')[0])).toEqual(['core/a', 'core/b', 'java/c', 'core/g']);
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
      'core/.archon/scripts/test/guard.test.sh',
      'core/.claude/hooks/agent-scopes.json',
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
      'openapi-contract/scripts/contract-mcp/cli.mjs',
      'openapi-contract/scripts/contract-mcp/server.mjs',
      'openapi-contract/scripts/contract-mcp/tools.mjs',
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
    // A suite ships with its subject's profile, its source nouns neutral; a listed one stays out.
    expect(
      readFileSync(join(out, 'profiles/core/.archon/scripts/test/guard.test.sh'), 'utf8')
    ).toBe('bash .claude/hooks/scripts/guard.sh # example-app\n');
    expect(keys.some(k => k.endsWith('scripts/test/image.test.sh'))).toBe(false);
    const skill = readFileSync(join(out, 'profiles/core/.github/skills/grill-pr/SKILL.md'), 'utf8');
    expect(skill).toContain(
      '.github/skills/grill-pr/references and .github/skills/run-app/SKILL.md'
    );
    const agent = readFileSync(
      join(out, 'profiles/java/.github/agents/developer.agent.md'),
      'utf8'
    );
    expect(agent).toContain('args: ["scripts/contract-mcp/server.mjs"]');
    expect(agent.split('MCP fallback:')).toHaveLength(2);
    expect(agent).toContain('`node scripts/contract-mcp/cli.mjs *`');
    const scopes = JSON.parse(
      readFileSync(join(out, 'profiles/core/.claude/hooks/agent-scopes.json'), 'utf8')
    ) as { agents: Record<string, { commandAllowlist: string[] }> };
    expect(scopes.agents.developer?.commandAllowlist).toEqual([
      'git add',
      ...CODEGRAPH_CLI,
      CONTRACT_CLI,
    ]);
    expect(scopes.agents.retro?.commandAllowlist).toEqual(['git log']);
    expect(agent).toContain(
      'command: "env KIT_AGENT=developer bash .github/hooks/dispatch.sh PreToolUse'
    );
    expect(readFileSync(join(out, 'profiles/java/docs/code-maps/java.md'), 'utf8')).toContain(
      '## This repo\nFill in this project'
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

  test('--verify compares profile order by number, flags an unknown profile and an overlay exec bit', () => {
    const src = fixture();
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-order-')));
    write(
      out,
      'overlays/java/overlay.json',
      JSON.stringify({
        'scripts/o.sh': { derivedFrom: null, sourceSha256: null },
      })
    );
    write(out, 'overlays/java/scripts/o.sh', 'echo o\n');
    sync(src, out, false, NO_REWRITES);
    expect(verifyKit(out)).toEqual([]);
    chmodSync(join(out, 'overlays/java/scripts/o.sh'), 0o755);
    expect(verifyKit(out)).toContain(
      'overlay not synced: overlays/java/scripts/o.sh (run kit-sync)'
    );
    chmodSync(join(out, 'overlays/java/scripts/o.sh'), 0o644);
    const mf = join(out, 'manifest.json');
    const manifest = JSON.parse(readFileSync(mf, 'utf8')) as {
      files: { profile: string; path: string }[];
    };
    const javaAt = manifest.files.findIndex(f => f.profile === 'java');
    const [java] = manifest.files.splice(javaAt, 1);
    manifest.files.unshift(java);
    manifest.files.push({ ...manifest.files[1], profile: 'nope' });
    writeFileSync(mf, JSON.stringify(manifest));
    const problems = verifyKit(out);
    expect(problems.some(p => /out of order/.test(p))).toBe(true);
    expect(problems.some(p => /names an unknown profile nope/.test(p))).toBe(true);
  });

  test('an overlay marked createOnly is marked so in the manifest; the others are not', () => {
    const src = fixture();
    const out = track(mkdtempSync(join(tmpdir(), 'kit-sync-create-only-')));
    write(
      out,
      'overlays/java/overlay.json',
      JSON.stringify({
        'docs/memory.md': { derivedFrom: null, sourceSha256: null, createOnly: true },
        'docs/other.md': { derivedFrom: null, sourceSha256: null },
      })
    );
    write(out, 'overlays/java/docs/memory.md', '# Project memory\n');
    write(out, 'overlays/java/docs/other.md', '# other\n');
    sync(src, out, false, NO_REWRITES);
    const files = (
      JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8')) as {
        files: { path: string; createOnly?: boolean }[];
      }
    ).files;
    expect(files.find(x => x.path === 'docs/memory.md')?.createOnly).toBe(true);
    expect(files.find(x => x.path === 'docs/other.md')).not.toHaveProperty('createOnly');
    expect(verifyKit(out)).toEqual([]);
  });
});
