import type { InlineToolCall } from '../primitives/message';

/** The tools through which an agent hands a subagent its prompt. */
const SUBAGENT_TOOLS = new Set(['Agent', 'Task']);

/** A subagent call's prompt and who it went to. */
export interface PromptCall {
  prompt: string;
  /** The subagent type the call named, e.g. `developer`; null when it named none. */
  agent: string | null;
  /** The call's short description; null when it gave none. */
  description: string | null;
}

function readString(input: Record<string, unknown>, key: string): string | null {
  const value = input[key];
  return typeof value === 'string' && value.trim().length > 0 ? value : null;
}

/** The prompt a tool call handed a subagent, or null when the call is not a subagent call. */
export function promptCallOf(call: Pick<InlineToolCall, 'name' | 'input'>): PromptCall | null {
  if (!SUBAGENT_TOOLS.has(call.name)) return null;
  const input = call.input;
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return null;
  const record = input as Record<string, unknown>;
  const prompt = readString(record, 'prompt');
  if (prompt === null) return null;
  return {
    prompt,
    agent: readString(record, 'subagent_type'),
    description: readString(record, 'description'),
  };
}
