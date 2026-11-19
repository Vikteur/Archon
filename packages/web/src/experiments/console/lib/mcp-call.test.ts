import { describe, expect, test } from 'bun:test';
import { mcpCallOf, mcpResultOf, paramsPreview, paramValueFull } from './mcp-call';

describe('mcpCallOf', () => {
  test('reads the server and tool from an mcp__ name, dashes included', () => {
    expect(
      mcpCallOf({
        name: 'mcp__portal-api__search',
        input: { query: 'cancel a vendor' },
      })
    ).toEqual({
      server: 'portal-api',
      tool: 'search',
      params: [['query', 'cancel a vendor']],
    });
  });

  test('keeps a tool name that holds double underscores whole', () => {
    expect(mcpCallOf({ name: 'mcp__codegraph__codegraph_explore', input: {} })).toMatchObject({
      server: 'codegraph',
      tool: 'codegraph_explore',
      params: [],
    });
  });

  test("a tool that is not an MCP server's is null", () => {
    expect(mcpCallOf({ name: 'Bash', input: { command: 'ls' } })).toBeNull();
    expect(mcpCallOf({ name: 'mcp_portal', input: {} })).toBeNull();
  });

  test('a non-object input is kept as one parameter', () => {
    expect(mcpCallOf({ name: 'mcp__s__t', input: 'raw' })?.params).toEqual([['input', 'raw']]);
  });
});

describe('paramsPreview', () => {
  test('names each parameter, cuts long strings and counts the rest', () => {
    const preview = paramsPreview([
      ['query', 'x'.repeat(70)],
      ['limit', 5],
      ['tags', ['a', 'b']],
      ['filter', { a: 1 }],
    ]);
    expect(preview).toBe(`query="${'x'.repeat(60)}…" limit=5 tags=[2] +1`);
  });

  test('a full value is the string as written or indented JSON', () => {
    expect(paramValueFull('a\nb')).toBe('a\nb');
    expect(paramValueFull({ a: 1 })).toBe('{\n  "a": 1\n}');
  });
});

describe('mcpResultOf', () => {
  test('JSON text is indented and digested', () => {
    const result = mcpResultOf('[{"operationId":"cancelVendor"},{"operationId":"x"}]');
    expect(result).toMatchObject({ kind: 'json', summary: '2 items' });
    expect(result?.kind === 'json' ? result.pretty : '').toContain('\n  {\n');
  });

  test('an object digests to its first keys', () => {
    expect(mcpResultOf('{"a":1,"b":2,"c":3,"d":4}')?.summary).toBe('{a, b, c, +1}');
  });

  test('an MCP content list is unwrapped to its text first', () => {
    const result = mcpResultOf(JSON.stringify([{ type: 'text', text: '{"operationId":"x"}' }]));
    expect(result).toMatchObject({ kind: 'json', summary: '{operationId}' });
  });

  test('plain text stays text, digested to its first line', () => {
    expect(mcpResultOf('\nNo operation found\nmore')).toMatchObject({
      kind: 'text',
      summary: 'No operation found',
    });
  });

  test('no answer is null', () => {
    expect(mcpResultOf(undefined)).toBeNull();
    expect(mcpResultOf('  ')).toBeNull();
  });
});
