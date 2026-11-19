import type { InlineToolCall } from '../primitives/message';

/**
 * Recognises a call to an MCP server's tool, so the run stream can show it as its own row:
 * which server, which tool, with which parameters, and what it answered.
 *
 * Claude names an MCP tool `mcp__<server>__<tool>` (the server name may itself hold
 * single underscores or dashes, e.g. `mcp__portal-api__search`).
 */

/** One MCP tool call, read from its name and input. */
export interface McpCall {
  /** The MCP server, e.g. `portal-api`. */
  server: string;
  /** The server's tool, e.g. `search`. */
  tool: string;
  /** The call's parameters, in the order the agent gave them. */
  params: [string, unknown][];
}

const MCP_NAME = /^mcp__(.+?)__(.+)$/;

/** The MCP call a tool call made, or null when the tool is not an MCP server's. */
export function mcpCallOf(call: Pick<InlineToolCall, 'name' | 'input'>): McpCall | null {
  const match = MCP_NAME.exec(call.name);
  if (match === null) return null;
  const input = call.input;
  const params: [string, unknown][] =
    typeof input === 'object' && input !== null && !Array.isArray(input)
      ? Object.entries(input as Record<string, unknown>)
      : input === undefined || input === null || input === ''
        ? []
        : [['input', input]];
  return { server: match[1], tool: match[2], params };
}

/** A parameter's value as one short line for the row. */
export function paramValuePreview(value: unknown, max = 60): string {
  if (typeof value === 'string') {
    const oneLine = value.replace(/\s+/g, ' ').trim();
    const cut = oneLine.length > max ? `${oneLine.slice(0, max)}…` : oneLine;
    return `"${cut}"`;
  }
  if (typeof value === 'number' || typeof value === 'boolean' || value === null) {
    return String(value);
  }
  if (Array.isArray(value)) return `[${value.length.toString()}]`;
  if (value === undefined) return 'undefined';
  return '{…}';
}

/** The row's digest of the parameters: `query="cancel a vendor" limit=5`. */
export function paramsPreview(params: readonly [string, unknown][], maxEntries = 3): string {
  const shown = params
    .slice(0, maxEntries)
    .map(([key, value]) => `${key}=${paramValuePreview(value)}`);
  if (params.length > maxEntries) shown.push(`+${(params.length - maxEntries).toString()}`);
  return shown.join(' ');
}

/** A parameter's value in full: a string as written, anything else as indented JSON. */
export function paramValueFull(value: unknown): string {
  if (typeof value === 'string') return value;
  return JSON.stringify(value, null, 2) ?? String(value);
}

/** What an MCP tool answered, read for display. */
export type McpResult =
  | {
      kind: 'json';
      /** The answer, indented. */
      pretty: string;
      /** A one-line digest: `10 items`, `{operationId, method, path, +4}`. */
      summary: string;
    }
  | { kind: 'text'; text: string; summary: string };

function jsonDigest(value: unknown): string {
  if (Array.isArray(value))
    return `${value.length.toString()} ${value.length === 1 ? 'item' : 'items'}`;
  if (typeof value === 'object' && value !== null) {
    const keys = Object.keys(value);
    const shown = keys.slice(0, 3);
    if (keys.length > 3) shown.push(`+${(keys.length - 3).toString()}`);
    return `{${shown.join(', ')}}`;
  }
  return paramValuePreview(value, 40);
}

/** An MCP content list (`[{type: "text", text}]`) as its joined text; null when it is not one. */
function contentListText(value: unknown): string | null {
  if (!Array.isArray(value) || value.length === 0) return null;
  const parts: string[] = [];
  for (const part of value) {
    if (typeof part !== 'object' || part === null) return null;
    const record = part as Record<string, unknown>;
    if (typeof record.type !== 'string') return null;
    if (record.type === 'text' && typeof record.text === 'string') parts.push(record.text);
  }
  return parts.join('\n');
}

function tryJson(text: string): { ok: true; value: unknown } | { ok: false } {
  const trimmed = text.trim();
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return { ok: false };
  try {
    return { ok: true, value: JSON.parse(trimmed) };
  } catch {
    return { ok: false };
  }
}

/**
 * Read an MCP tool's recorded answer. Providers record the text of the result's content;
 * some keep the content list itself. JSON text is indented and digested; anything else
 * stays text. Null when there is no answer.
 */
export function mcpResultOf(output: string | undefined): McpResult | null {
  if (output === undefined || output.trim().length === 0) return null;
  let text = output;
  let parsed = tryJson(text);
  if (parsed.ok) {
    const inner = contentListText(parsed.value);
    if (inner !== null) {
      text = inner;
      parsed = tryJson(text);
    }
  }
  if (parsed.ok) {
    return {
      kind: 'json',
      pretty: JSON.stringify(parsed.value, null, 2),
      summary: jsonDigest(parsed.value),
    };
  }
  const firstLine =
    text
      .split('\n')
      .map(line => line.trim())
      .find(line => line.length > 0) ?? '';
  return {
    kind: 'text',
    text,
    summary: firstLine.length > 60 ? `${firstLine.slice(0, 60)}…` : firstLine,
  };
}
