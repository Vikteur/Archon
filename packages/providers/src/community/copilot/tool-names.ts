/**
 * Claude tool names in a node's `allowed_tools` / `denied_tools`, translated to
 * the Copilot runtime's built-in tool names for `availableTools` /
 * `excludedTools`.
 *
 * Workflows are written against Claude's names (`Read`, `Bash`, ...). Copilot
 * matches its filters by exact wire name (`view`, `bash`, ...), so an
 * untranslated `denied_tools: [Bash]` denied nothing and an untranslated
 * `allowed_tools: [Read]` left the agent with no tools at all.
 *
 * Pure module: no SDK runtime import, so the provider's lazy-load invariant
 * holds.
 */

/**
 * Claude tool name → Copilot built-in tool name. The Copilot names are the ones
 * the bundled runtime (`@microsoft/copilot-sdk` 2.0.1, the version pinned in
 * packages/providers/package.json) lists from `tools.list`:
 * bash, read_bash, stop_bash, list_bash, glob, grep, create, edit, view,
 * web_fetch, skill, task, read_agent, write_agent, list_agents. A name missing
 * here passes through unchanged, so a Copilot-native name (`bash`) also works.
 */
export const CLAUDE_TO_COPILOT_TOOL_NAMES: Readonly<Record<string, string>> = {
  Bash: 'bash',
  BashOutput: 'read_bash',
  KillShell: 'stop_bash',
  KillBash: 'stop_bash',
  Read: 'view',
  Write: 'create',
  Edit: 'edit',
  MultiEdit: 'edit',
  Glob: 'glob',
  Grep: 'grep',
  WebFetch: 'web_fetch',
  Skill: 'skill',
  Agent: 'task',
  Task: 'task',
  ListAgents: 'list_agents',
  SendMessage: 'write_agent',
};

/** All MCP tools, in the SDK's source-qualified filter syntax (`ToolSet.addMcp('*')`). */
const ALL_MCP_TOOLS = 'mcp:*';
const MCP_PREFIX = 'mcp__';

export interface CopilotToolFilter {
  /** The Copilot filter entries, deduplicated, in input order. */
  tools: string[];
  /** Entries Copilot cannot express exactly and that were dropped. */
  dropped: string[];
  /** Allowlist entries Copilot cannot express exactly and that were widened. */
  widened: string[];
}

type Translation =
  | { kind: 'exact'; name: string }
  /** `Bash(git *)` or a whole MCP server: only a broader `name` is expressible. */
  | { kind: 'broader'; name: string };

/**
 * One Claude entry → its Copilot form. Argument patterns (`Bash(git push *)`)
 * and whole-server MCP entries (`mcp__github`, `mcp__github__*`) have no exact
 * Copilot equivalent: Copilot filters by tool name only.
 */
function translate(entry: string): Translation {
  const open = entry.indexOf('(');
  if (open > 0 && entry.endsWith(')')) {
    return {
      kind: 'broader',
      name: translateName(entry.slice(0, open).trim()),
    };
  }
  if (entry.startsWith(MCP_PREFIX)) {
    const rest = entry.slice(MCP_PREFIX.length);
    const split = rest.indexOf('__');
    const server = split === -1 ? rest : rest.slice(0, split);
    const tool = split === -1 ? '' : rest.slice(split + 2);
    if (server.length === 0 || tool.length === 0 || tool === '*') {
      return { kind: 'broader', name: ALL_MCP_TOOLS };
    }
    // The runtime's canonical MCP wire name is `<server>-<tool>`
    // (`ToolSet.addMcp` docs: "github-list_issues").
    return { kind: 'exact', name: `${server}-${tool}` };
  }
  return { kind: 'exact', name: translateName(entry) };
}

function translateName(name: string): string {
  return Object.hasOwn(CLAUDE_TO_COPILOT_TOOL_NAMES, name)
    ? CLAUDE_TO_COPILOT_TOOL_NAMES[name]
    : name;
}

function entriesOf(raw: readonly string[]): string[] {
  return raw
    .filter((entry): entry is string => typeof entry === 'string')
    .map(entry => entry.trim())
    .filter(entry => entry.length > 0);
}

/**
 * `denied_tools` → `excludedTools`. An entry with no exact Copilot form is
 * dropped, never widened: excluding all of `bash` for a `Bash(git push *)` rule
 * would take the shell away from a node that only meant to forbid one command.
 * Enforce such rules with a preToolUse file hook instead.
 */
export function mapDeniedTools(raw: readonly string[]): CopilotToolFilter {
  const tools = new Set<string>();
  const dropped: string[] = [];
  for (const entry of entriesOf(raw)) {
    const translation = translate(entry);
    if (translation.kind === 'exact') tools.add(translation.name);
    else dropped.push(entry);
  }
  return { tools: [...tools], dropped, widened: [] };
}

/**
 * `allowed_tools` → `availableTools`. An entry with no exact Copilot form keeps
 * its broader tool (`Bash(git *)` → `bash`, `mcp__github` → `mcp:*`), because
 * dropping it would take away a tool the node needs.
 *
 * Never returns an empty list for a non-empty input: when nothing translates,
 * the raw entries pass through unchanged, which keeps the node as restricted as
 * the author wrote it rather than unrestricted. An explicitly empty input stays
 * empty (no tools).
 */
export function mapAllowedTools(raw: readonly string[]): CopilotToolFilter {
  const tools = new Set<string>();
  const widened: string[] = [];
  for (const entry of entriesOf(raw)) {
    const translation = translate(entry);
    tools.add(translation.name);
    if (translation.kind === 'broader') widened.push(entry);
  }
  if (tools.size === 0 && raw.length > 0) {
    return { tools: [...raw], dropped: [], widened: [] };
  }
  return { tools: [...tools], dropped: [], widened };
}
