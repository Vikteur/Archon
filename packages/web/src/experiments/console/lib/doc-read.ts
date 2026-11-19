import type { InlineToolCall } from '../primitives/message';

/**
 * Recognises an agent reading a documentation file, so the run stream can show it as its
 * own row: which doc, from where, which part of it, and what it said.
 *
 * A doc is a prose file (Markdown, reStructuredText, AsciiDoc, plain text) or any file under
 * a `docs/` folder. Only the file-reading tool counts: a search over docs is not a read.
 */

/** One read of a doc file, taken from the tool call's input. */
export interface DocRead {
  /** The path as the agent gave it. */
  path: string;
  /** The file name, e.g. `memory.md`. */
  file: string;
  /** The folder, shortened to its last segments for the row, e.g. `…/docs/code-maps`. */
  dir: string;
  /** The part read, when the agent asked for one: `lines 40–119`, `from line 40`, `first 80 lines`. */
  range: string | null;
}

const READ_TOOLS = new Set(['Read', 'read', 'read_file', 'view']);
const DOC_EXTENSION = /\.(md|mdx|markdown|rst|adoc|txt)$/i;
const DOCS_FOLDER = /(^|\/)docs\//;
const DIR_SEGMENTS = 3;

function pathOf(input: InlineToolCall['input']): string | null {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return null;
  const record = input as Record<string, unknown>;
  for (const key of ['file_path', 'path', 'filePath']) {
    const value = record[key];
    if (typeof value === 'string' && value.trim().length > 0) return value.trim();
  }
  return null;
}

function numberOf(input: InlineToolCall['input'], key: string): number | null {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return null;
  const value = (input as Record<string, unknown>)[key];
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
}

/** Whether a path names a doc file. */
export function isDocPath(path: string): boolean {
  const normalised = path.replace(/\\/g, '/');
  return DOC_EXTENSION.test(normalised) || DOCS_FOLDER.test(normalised);
}

function rangeOf(input: InlineToolCall['input']): string | null {
  const offset = numberOf(input, 'offset');
  const limit = numberOf(input, 'limit');
  if (offset !== null && limit !== null)
    return `lines ${offset.toString()}–${(offset + limit - 1).toString()}`;
  if (offset !== null) return `from line ${offset.toString()}`;
  if (limit !== null) return `first ${limit.toString()} lines`;
  return null;
}

/** The doc a tool call read, or null when the call is not a read of a doc file. */
export function docReadOf(call: Pick<InlineToolCall, 'name' | 'input'>): DocRead | null {
  if (!READ_TOOLS.has(call.name)) return null;
  const path = pathOf(call.input);
  if (path === null || !isDocPath(path)) return null;
  const parts = path.replace(/\\/g, '/').split('/');
  const file = parts.pop() ?? path;
  const dirParts = parts.filter(p => p.length > 0);
  const dir =
    dirParts.length > DIR_SEGMENTS
      ? `…/${dirParts.slice(-DIR_SEGMENTS).join('/')}`
      : parts.join('/');
  return { path, file, dir, range: rangeOf(call.input) };
}

/** How many lines a read answered, from its recorded output. */
export function docLineCount(output: string | undefined): number | null {
  if (output === undefined || output.length === 0) return null;
  const trimmed = output.replace(/\n+$/, '');
  return trimmed.length === 0 ? 0 : trimmed.split('\n').length;
}
