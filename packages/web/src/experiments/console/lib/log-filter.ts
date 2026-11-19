/**
 * The run log's kind filter: pick any of these kinds and the log shows only rows of the
 * kinds picked, each under its node's divider. Picking none shows the whole log.
 */

export type LogKind = 'prompts' | 'scripts' | 'mcp' | 'docs';

export interface LogKindInfo {
  kind: LogKind;
  /** The menu's label. */
  label: string;
  /** What the rows are called in a sentence: "No script runs yet." */
  noun: string;
  /** The rows' accent, so the menu matches what it filters to. */
  accent: string;
  /** The keyboard shortcut that toggles the kind. */
  key: string;
  /** The menu item's tooltip. */
  title: string;
}

export const LOG_KINDS: readonly LogKindInfo[] = [
  {
    kind: 'prompts',
    label: 'Prompts',
    noun: 'prompts',
    accent: 'var(--accent)',
    key: 'o',
    title: 'The prompts agents were given',
  },
  {
    kind: 'scripts',
    label: 'Scripts',
    noun: 'script runs',
    accent: 'var(--warning)',
    key: 'x',
    title: 'The tool calls that ran a script',
  },
  {
    kind: 'mcp',
    label: 'MCP calls',
    noun: 'MCP calls',
    accent: 'var(--brand-teal)',
    key: 'm',
    title: "The calls to an MCP server's tools",
  },
  {
    kind: 'docs',
    label: 'Doc reads',
    noun: 'doc reads',
    accent: 'var(--running)',
    key: 'd',
    title: 'The doc files agents read',
  },
];

const KNOWN = new Set<string>(LOG_KINDS.map(k => k.kind));

/** The kinds in menu order, without repeats or unknown names. */
export function normaliseLogKinds(kinds: readonly string[]): LogKind[] {
  return LOG_KINDS.map(k => k.kind).filter(k => kinds.includes(k) && KNOWN.has(k));
}

/** The picked kinds with `kind` turned on or off. */
export function toggleLogKind(kinds: readonly LogKind[], kind: LogKind): LogKind[] {
  return kinds.includes(kind) ? kinds.filter(k => k !== kind) : normaliseLogKinds([...kinds, kind]);
}

/** Read the picked kinds as stored: a JSON list of kind names. Anything else is none. */
export function parseLogKinds(stored: string | null): LogKind[] {
  if (stored === null) return [];
  try {
    const value: unknown = JSON.parse(stored);
    return Array.isArray(value)
      ? normaliseLogKinds(value.filter((v): v is string => typeof v === 'string'))
      : [];
  } catch {
    return [];
  }
}

/** "script runs", "prompts or doc reads", "prompts, script runs or MCP calls". */
export function logKindNouns(kinds: readonly LogKind[]): string {
  const nouns = LOG_KINDS.filter(k => kinds.includes(k.kind)).map(k => k.noun);
  if (nouns.length <= 1) return nouns.join('');
  return `${nouns.slice(0, -1).join(', ')} or ${nouns[nouns.length - 1]}`;
}
