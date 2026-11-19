import { describe, expect, test } from 'bun:test';
import { logKindNouns, normaliseLogKinds, parseLogKinds, toggleLogKind } from './log-filter';

describe('log filter kinds', () => {
  test('toggling adds in menu order and removes', () => {
    expect(toggleLogKind(['docs'], 'prompts')).toEqual(['prompts', 'docs']);
    expect(toggleLogKind(['prompts', 'docs'], 'prompts')).toEqual(['docs']);
  });

  test('stored kinds are read back without repeats or unknown names', () => {
    expect(parseLogKinds('["mcp","scripts","mcp","nope"]')).toEqual(['scripts', 'mcp']);
    expect(parseLogKinds(null)).toEqual([]);
    expect(parseLogKinds('not json')).toEqual([]);
    expect(parseLogKinds('{"a":1}')).toEqual([]);
    expect(normaliseLogKinds([])).toEqual([]);
  });

  test('names the kinds in a sentence', () => {
    expect(logKindNouns(['scripts'])).toBe('script runs');
    expect(logKindNouns(['docs', 'prompts'])).toBe('prompts or doc reads');
    expect(logKindNouns(['prompts', 'scripts', 'mcp'])).toBe('prompts, script runs or MCP calls');
  });
});
