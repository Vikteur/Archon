import { describe, expect, test } from 'bun:test';

import { CLAUDE_TO_COPILOT_TOOL_NAMES, mapAllowedTools, mapDeniedTools } from './tool-names';

/** The built-in tool names the bundled Copilot runtime lists from `tools.list`. */
const COPILOT_BUILTIN_TOOLS = new Set([
  'bash',
  'read_bash',
  'stop_bash',
  'list_bash',
  'glob',
  'grep',
  'create',
  'edit',
  'skill',
  'view',
  'web_fetch',
  'task',
  'read_agent',
  'list_agents',
  'write_agent',
]);

describe('CLAUDE_TO_COPILOT_TOOL_NAMES', () => {
  test('maps every entry to a Copilot built-in tool', () => {
    for (const [claude, copilot] of Object.entries(CLAUDE_TO_COPILOT_TOOL_NAMES)) {
      expect({ claude, known: COPILOT_BUILTIN_TOOLS.has(copilot) }).toEqual({
        claude,
        known: true,
      });
    }
  });

  test.each([
    ['Bash', 'bash'],
    ['Read', 'view'],
    ['Write', 'create'],
    ['Edit', 'edit'],
    ['MultiEdit', 'edit'],
    ['Glob', 'glob'],
    ['Grep', 'grep'],
    ['WebFetch', 'web_fetch'],
    ['Agent', 'task'],
    ['Task', 'task'],
    ['Skill', 'skill'],
    ['BashOutput', 'read_bash'],
    ['KillShell', 'stop_bash'],
  ])('%s → %s', (claude, copilot) => {
    expect(CLAUDE_TO_COPILOT_TOOL_NAMES[claude]).toBe(copilot);
  });
});

describe('mapDeniedTools', () => {
  test('translates Claude names and deduplicates', () => {
    expect(mapDeniedTools(['Write', 'Edit', 'MultiEdit', 'WebFetch'])).toEqual({
      tools: ['create', 'edit', 'web_fetch'],
      dropped: [],
      widened: [],
    });
  });

  test('passes unknown and Copilot-native names through', () => {
    expect(mapDeniedTools(['bash', 'WebSearch']).tools).toEqual(['bash', 'WebSearch']);
  });

  test('drops argument patterns rather than denying the whole tool', () => {
    expect(mapDeniedTools(['Bash(git push *)', 'Bash(rm -rf *)', 'Write'])).toEqual({
      tools: ['create'],
      dropped: ['Bash(git push *)', 'Bash(rm -rf *)'],
      widened: [],
    });
  });

  test('maps an MCP tool to the runtime wire name <server>-<tool>', () => {
    expect(mapDeniedTools(['mcp__github__create_issue']).tools).toEqual(['github-create_issue']);
  });

  test('drops a whole-server MCP entry', () => {
    expect(mapDeniedTools(['mcp__github', 'mcp__linear__*'])).toEqual({
      tools: [],
      dropped: ['mcp__github', 'mcp__linear__*'],
      widened: [],
    });
  });

  test('skips blank entries', () => {
    expect(mapDeniedTools(['', '  ', 'Read']).tools).toEqual(['view']);
  });
});

describe('mapAllowedTools', () => {
  test('translates Claude names and deduplicates', () => {
    expect(mapAllowedTools(['Read', 'Grep', 'Glob', 'Read'])).toEqual({
      tools: ['view', 'grep', 'glob'],
      dropped: [],
      widened: [],
    });
  });

  test('keeps the base tool of an argument pattern, flagged as widened', () => {
    expect(mapAllowedTools(['Read', 'Bash(git status *)', 'Bash(git diff *)'])).toEqual({
      tools: ['view', 'bash'],
      dropped: [],
      widened: ['Bash(git status *)', 'Bash(git diff *)'],
    });
  });

  test('a pattern-only list never maps to an empty list', () => {
    expect(mapAllowedTools(['Bash(git push *)']).tools).toEqual(['bash']);
  });

  test('a whole-server MCP entry allows all MCP tools, flagged as widened', () => {
    expect(mapAllowedTools(['mcp__github', 'mcp__linear__get_issue'])).toEqual({
      tools: ['mcp:*', 'linear-get_issue'],
      dropped: [],
      widened: ['mcp__github'],
    });
  });

  test('a list of only blank entries passes through rather than becoming empty', () => {
    expect(mapAllowedTools(['', ' ']).tools).toEqual(['', ' ']);
  });

  test('an explicitly empty list stays empty (no tools)', () => {
    expect(mapAllowedTools([]).tools).toEqual([]);
  });
});
