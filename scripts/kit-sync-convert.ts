/**
 * kit-sync's conversions (kit/SPEC.md, Conversion rules): Claude Code agents, skills, rules, hooks and MCP servers to
 * their GitHub Copilot CLI form, and the generated hook dispatcher.
 */
import { CONTRACT_SERVER, SOURCE_CONTRACT_SERVER } from './kit-sync-lists';

// ---------------------------------------------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------------------------------------------

const MODEL_MAP: [RegExp, string][] = [
  [/opus/i, 'claude-opus-5.5'],
  [/sonnet/i, 'claude-sonnet-5.5'],
  [/haiku/i, 'claude-haiku-5.5'],
];
const CLAUDE_ONLY_TOOLS = ['PushNotification', 'SendMessage', 'ListAgents'];

const y = (v: unknown): string => JSON.stringify(v);
const yList = (items: readonly string[]): string => `[${items.map(i => y(i)).join(', ')}]`;

export function splitFrontmatter(text: string): { front: string; body: string } | null {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) return null;
  return { front: m[1] ?? '', body: text.slice(m[0].length) };
}

export function parseYaml(text: string, where: string): Record<string, unknown> {
  const v: unknown = Bun.YAML.parse(text);
  if (v === null || v === undefined) return {};
  if (typeof v !== 'object' || Array.isArray(v))
    throw new Error(`${where}: frontmatter is not a map`);
  return v as Record<string, unknown>;
}

function contractName(name: string): string {
  return name.replace(SOURCE_CONTRACT_SERVER, CONTRACT_SERVER);
}

function onCopilotSection(notes: string[]): string {
  return notes.length ? `\n## On Copilot CLI\n\n${notes.map(n => `- ${n}`).join('\n')}\n` : '';
}

function withTrailingSection(body: string, section: string): string {
  if (!section) return body;
  return `${body.replace(/\s*$/, '')}\n${section}`;
}

interface McpServer {
  command: string;
  args?: string[];
  env?: Record<string, string>;
}

function mcpEntry(server: McpServer): string[] {
  const lines = ['    type: "local"', `    command: ${y(server.command)}`];
  lines.push(`    args: ${yList(server.args ?? [])}`);
  lines.push('    tools: ["*"]');
  const env = Object.entries(server.env ?? {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  if (env.length) {
    lines.push('    env:');
    for (const [k, v] of env) lines.push(`      ${k}: ${y(String(v))}`);
  }
  return lines;
}

interface AgentTools {
  tools: string[];
  bash: string[];
  delegates: string[];
  dropped: string[];
}

const READ_TOOLS = ['Read', 'Grep', 'Glob'];
const EDIT_TOOLS = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'];
const WEB_TOOLS = ['WebFetch', 'WebSearch'];

/** A comma list or a YAML list of tool names, splitting on commas outside parentheses. */
function listOf(v: unknown): string[] {
  if (Array.isArray(v)) return v.map(String);
  if (typeof v === 'string') return v.split(/,\s*(?![^()]*\))/).filter(Boolean);
  return [];
}

/** One Claude Code tool name -> the Copilot tools it maps to, or the note it adds. */
function mapTool(t: string, acc: AgentTools, where: string): void {
  const add = (...names: string[]): void => {
    for (const x of names) if (!acc.tools.includes(x)) acc.tools.push(x);
  };
  if (READ_TOOLS.includes(t)) return add('read', 'search');
  if (EDIT_TOOLS.includes(t)) return add('edit');
  if (WEB_TOOLS.includes(t)) return add('web');
  if (t === 'Skill') return;
  if (CLAUDE_ONLY_TOOLS.includes(t)) {
    acc.dropped.push(t);
    return;
  }
  const bash = /^Bash(?:\((.*)\))?$/.exec(t);
  if (bash) {
    add('execute');
    if (bash[1]) acc.bash.push(bash[1]);
    return;
  }
  const agent = /^(?:Agent|Task)(?:\((.*)\))?$/.exec(t);
  if (agent) {
    add('agent');
    if (agent[1]) acc.delegates.push(...agent[1].split(/,\s*/));
    return;
  }
  const mcp = /^mcp__(.+?)__(.+)$/.exec(t);
  if (mcp) return add(`${contractName(mcp[1] ?? '')}/${mcp[2]}`);
  throw new Error(`${where}: no Copilot mapping for tool ${t}`);
}

function agentTools(raw: unknown, where: string): AgentTools {
  const acc: AgentTools = { tools: [], bash: [], delegates: [], dropped: [] };
  for (const t of listOf(raw)) mapTool(t.trim(), acc, where);
  return acc;
}

function stringMap(v: unknown): Record<string, string> | undefined {
  if (!v || typeof v !== 'object') return undefined;
  return Object.fromEntries(Object.entries(v).map(([a, b]) => [a, String(b)]));
}

function mcpServer(k: string, v: unknown, where: string): [string, McpServer] {
  if (!v || typeof v !== 'object') throw new Error(`${where}: mcpServers.${k} is not a map`);
  const s = v as Record<string, unknown>;
  const args = Array.isArray(s.args) ? s.args.map(String) : [];
  return [contractName(k), { command: String(s.command ?? ''), args, env: stringMap(s.env) }];
}

/** `mcpServers`, as a map or a list of one-key maps. */
function agentServers(raw: unknown, where: string): [string, McpServer][] {
  if (!raw || typeof raw !== 'object') return [];
  const maps = Array.isArray(raw)
    ? (raw as Record<string, unknown>[])
    : [raw as Record<string, unknown>];
  return maps.flatMap(m => Object.entries(m).map(([k, v]) => mcpServer(k, v, where)));
}

function agentModel(fm: Record<string, unknown>, where: string): string | undefined {
  const modelIn = String(fm.model ?? '');
  const model = MODEL_MAP.find(([re]) => re.test(modelIn))?.[1];
  if (modelIn && !model) throw new Error(`${where}: unknown model ${modelIn}`);
  return model;
}

const ticks = (items: string[]): string => items.map(t => `\`${t}\``).join(', ');

function agentNotes(t: AgentTools): string[] {
  const notes: string[] = [];
  if (t.dropped.length)
    notes.push(
      `Claude Code gives this agent tools that Copilot CLI does not have: ${ticks(t.dropped)}. Where these instructions use one, go without it and say so in your report.`
    );
  if (t.bash.length)
    notes.push(
      `Claude Code limits this agent's shell to these commands; keep to them: ${ticks(t.bash)}.`
    );
  if (t.delegates.length) notes.push(`Delegate only to these agents: ${ticks(t.delegates)}.`);
  return notes;
}

function agentFront(
  fm: Record<string, unknown>,
  name: string,
  model: string | undefined,
  tools: string[],
  servers: [string, McpServer][]
): string[] {
  const out = ['---', `name: ${y(name)}`, `description: ${y(String(fm.description ?? ''))}`];
  if (model) out.push(`model: ${y(model)}`);
  out.push(`tools: ${yList(tools)}`);
  if (servers.length) out.push('mcp-servers:');
  for (const [k, s] of servers) out.push(`  ${y(k)}:`, ...mcpEntry(s));
  out.push('include-custom-instructions: true', '---', '');
  return out;
}

/** `.claude/agents/<n>.md` -> `.github/agents/<n>.agent.md` (kit/SPEC.md, Conversion rules). */
export function convertAgent(text: string, where = 'agent'): string {
  const parts = splitFrontmatter(text);
  if (!parts) throw new Error(`${where}: no frontmatter`);
  const fm = parseYaml(parts.front, where);
  const name = String(fm.name ?? '');
  if (!name) throw new Error(`${where}: no name`);
  const model = agentModel(fm, where);
  const tools = agentTools(fm.tools, where);
  const front = agentFront(fm, name, model, tools.tools, agentServers(fm.mcpServers, where));
  let body = parts.body.replace(SOURCE_CONTRACT_SERVER, CONTRACT_SERVER);
  const skills = Array.isArray(fm.skills) ? (fm.skills as unknown[]).map(String) : [];
  if (skills.length)
    body = `Load these skills first: ${skills.join(', ')}.\n\n${body.replace(/^\s+/, '')}`;
  return front.join('\n') + withTrailingSection(body, onCopilotSection(agentNotes(tools)));
}

const SKILL_KEEP = ['name', 'description', 'license', 'allowed-tools'];

/** SKILL.md: keep name, description, license and allowed-tools (as written); note a dropped invocation rule. */
export function convertSkillMd(text: string, where = 'SKILL.md'): string {
  const parts = splitFrontmatter(text);
  if (!parts) return text;
  const fm = parseYaml(parts.front, where);
  const kept: string[] = [];
  let keep = false;
  for (const line of parts.front.split('\n')) {
    const key = /^([A-Za-z0-9_-]+):/.exec(line)?.[1];
    if (key !== undefined) keep = SKILL_KEEP.includes(key);
    if (keep) kept.push(line);
  }
  const notes: string[] = [];
  if (fm['disable-model-invocation'] === true)
    notes.push(
      'Claude Code runs this skill only when the user names it (`disable-model-invocation`). Load it only when the user asks for it by name.'
    );
  const list = listOf(fm['disallowed-tools']);
  if (list.length)
    notes.push(
      `Claude Code withholds these tools while this skill runs (\`disallowed-tools\`): ${list.map(t => `\`${t}\``).join(', ')}. Do not use them while you follow this skill.`
    );
  return `---\n${kept.join('\n')}\n---\n${withTrailingSection(parts.body, onCopilotSection(notes))}`;
}

/** `.claude/rules/<layer>.md` -> `.github/instructions/<layer>.instructions.md`. */
export function convertRule(layer: string, text: string, modules: readonly string[]): string {
  const parts = splitFrontmatter(text);
  let applyTo = '**';
  let body = text;
  if (parts) {
    const fm = parseYaml(parts.front, `rule ${layer}`);
    body = parts.body;
    const paths = Array.isArray(fm.paths)
      ? fm.paths.map(String)
      : fm.paths
        ? [String(fm.paths)]
        : [];
    if (paths.length) applyTo = paths.join(',');
  }
  if (modules.includes(layer))
    applyTo = `@@KIT_MODULES_${layer.toUpperCase().replace(/-/g, '_')}@@`;
  return `---\napplyTo: ${y(applyTo)}\n---\n${body}`;
}

export const KIT_MODULES = ['domain', 'usecase', 'adapter', 'gateway', 'platform'];

const EVENT_MAP: Record<string, string> = {
  SessionStart: 'sessionStart',
  UserPromptSubmit: 'userPromptSubmitted',
  PreToolUse: 'preToolUse',
  PostToolUse: 'postToolUse',
  PostToolUseFailure: 'postToolUseFailure',
  SubagentStart: 'subagentStart',
  SubagentStop: 'subagentStop',
  SessionEnd: 'sessionEnd',
  Stop: 'agentStop',
};

function shellWord(s: string): string {
  return /^[\w./@%+=:,-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`;
}

/** One settings.json hook command -> the script it runs (project-relative) and its arguments. */
export function parseHookCommand(cmd: string): { script: string; args: string[] } {
  const cd = /cd "\$CLAUDE_PROJECT_DIR\/([^"]+)"\s*&&/.exec(cmd)?.[1];
  const m =
    /exec bash (?:"\$CLAUDE_PROJECT_DIR\/([^"]+)"|([^\s;"]+))([^;]*?)\s*(?:;\s*else\b|;\s*fi\b|$)/.exec(
      cmd
    );
  if (!m) throw new Error(`hook command not understood: ${cmd}`);
  const script = m[1] ?? (cd ? `${cd}/${m[2]}` : (m[2] ?? ''));
  const args = (m[3] ?? '').trim().split(/\s+/).filter(Boolean);
  return { script, args };
}

function dispatchEntry(event: string, matcher: string, h: Record<string, unknown>): unknown {
  if (h.type !== 'command')
    throw new Error(`${event}: hook type ${String(h.type)} is not supported`);
  const { script, args } = parseHookCommand(String(h.command ?? ''));
  const bash = [
    'bash .github/hooks/dispatch.sh',
    event,
    `'${matcher.replace(/'/g, `'\\''`)}'`,
    shellWord(script),
    ...args.map(shellWord),
  ].join(' ');
  return { type: 'command', bash, timeoutSec: Number(h.timeout ?? 60) };
}

function eventEntries(event: string, groups: unknown): unknown[] {
  const out: unknown[] = [];
  for (const group of (groups as Record<string, unknown>[] | undefined) ?? []) {
    const matcher = String(group.matcher ?? '');
    for (const h of (group.hooks as Record<string, unknown>[] | undefined) ?? [])
      out.push(dispatchEntry(event, matcher, h));
  }
  return out;
}

/** settings.json `hooks` -> `.github/hooks/kit.json`. */
export function convertHooks(settings: Record<string, unknown>): string {
  const hooks = (settings.hooks ?? {}) as Record<string, unknown>;
  const out: Record<string, unknown[]> = {};
  for (const [event, groups] of Object.entries(hooks)) {
    const target = EVENT_MAP[event];
    if (!target) throw new Error(`no Copilot event for Claude hook event ${event}`);
    const entries = eventEntries(event, groups);
    if (entries.length) (out[target] ??= []).push(...entries);
  }
  return `${JSON.stringify({ version: 1, hooks: out }, null, 2)}\n`;
}

/** settings.json `permissions.deny` -> `.archon/copilot/deny.json`. */
export function convertDeny(settings: Record<string, unknown>): string {
  const perms = (settings.permissions ?? {}) as Record<string, unknown>;
  const deny = Array.isArray(perms.deny) ? perms.deny.map(String) : [];
  return `${JSON.stringify(deny, null, 2)}\n`;
}

/** `.github/mcp.json`: core-only, or core plus the contract server. */
export function mcpJson(withContract: boolean): string {
  const servers: Record<string, unknown> = {
    codegraph: {
      type: 'local',
      command: 'codegraph',
      args: ['serve', '--mcp'],
      env: { CODEGRAPH_MCP_TOOLS: 'explore,node,search,callers,callees,impact' },
      tools: ['*'],
    },
  };
  if (withContract)
    servers[CONTRACT_SERVER] = {
      type: 'local',
      command: 'node',
      args: ['scripts/contract-mcp/server.mjs'],
      tools: ['*'],
    };
  return `${JSON.stringify({ mcpServers: servers }, null, 2)}\n`;
}

export const DISPATCH_SH = `#!/usr/bin/env bash
# dispatch.sh: GENERATED by Archon's kit-sync (kit/SPEC.md), do not edit. Runs one Claude Code hook script under the
# GitHub Copilot CLI; .github/hooks/kit.json calls it once per hook of the source's .claude/settings.json:
#   bash .github/hooks/dispatch.sh <ClaudeEvent> '<matcher>' <script path> [args...]
# It reads the hook payload on stdin and normalizes it to the Claude shape with .claude/hooks/scripts/payload.sh
# (when present), skips the hook when the Claude matcher (a regex over the tool name, anchored) does not match, and
# runs the script with the normalized payload on stdin: from .claude/hooks for a script under it (as settings.json
# does), else from the project root. On PreToolUse it turns a Claude deny (hookSpecificOutput.permissionDecision, or
# exit 2 with the reason on stderr) into Copilot's top-level permissionDecision/permissionDecisionReason. A missing
# script is a no-op, as in settings.json. The script's stderr passes through; dispatch.sh itself always exits 0.
set -uo pipefail
event="\${1:-}"; matcher="\${2:-}"; script="\${3:-}"
[ "$#" -ge 3 ] || exit 0
shift 3
root="\${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
[ -n "$root" ] || root="$PWD"
export CLAUDE_PROJECT_DIR="$root"
[ -f "$root/$script" ] || exit 0

payload="$(cat)"
if [ -f "$root/.claude/hooks/scripts/payload.sh" ]; then
  # shellcheck source=/dev/null
  . "$root/.claude/hooks/scripts/payload.sh"
  payload="$(hook_normalize_payload "$payload")"
fi

kit_deny() { # kit_deny <reason>: a deny decision in the Copilot and the Claude shape
  if declare -F hook_deny_json >/dev/null; then hook_deny_json "$1"; return; fi
  local r="\${1//\\\\/\\\\\\\\}"; r="\${r//\\"/\\\\\\"}"; r="\${r//$'\\n'/ }"
  printf '{"permissionDecision":"deny","permissionDecisionReason":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\\n' "$r" "$r"
}

if [ -n "$matcher" ] && [ "$matcher" != "*" ]; then
  tool=""
  re='"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
  [[ $payload =~ $re ]] && tool="\${BASH_REMATCH[1]}"
  [[ $tool =~ ^($matcher)$ ]] || exit 0
fi

case "$script" in
  .claude/hooks/*) dir="$root/.claude/hooks" ;;
  *) dir="$root" ;;
esac
errf="$(mktemp)"
trap 'rm -f "$errf"' EXIT
out="$(cd "$dir" && printf '%s' "$payload" | bash "$root/$script" "$@" 2>"$errf")"
rc=$?
cat "$errf" >&2

if [ "$event" = PreToolUse ]; then
  if [ "$rc" -eq 2 ]; then
    reason="$(tr '\\n' ' ' <"$errf")"
    kit_deny "\${reason:-blocked by $script}"
    exit 0
  fi
  case "$out" in
    *'"permissionDecision"'*)
      if command -v jq >/dev/null 2>&1; then
        conv="$(printf '%s' "$out" | jq -c 'if type == "object" and (.hookSpecificOutput.permissionDecision // null) != null and (.permissionDecision // null) == null
          then . + {permissionDecision: .hookSpecificOutput.permissionDecision, permissionDecisionReason: (.hookSpecificOutput.permissionDecisionReason // "")}
          else . end' 2>/dev/null)" && out="$conv"
      fi ;;
  esac
fi
[ -z "$out" ] || printf '%s\\n' "$out"
exit 0
`;
