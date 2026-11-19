import { getLog } from './log';
import type { RunLayersContext } from './run-context';

/** The `node_prompt` event: the prompt an AI node sent its provider, as sent. */
export const NODE_PROMPT_EVENT_TYPE = 'node_prompt';

/** Longest prompt the event keeps, in code units; a longer one is cut and marked. */
export const NODE_PROMPT_MAX_CHARS = 200_000;

/** Where in the node the prompt was sent: which re-ask, and for an AI loop which iteration. */
export interface NodePromptPosition {
  /** The node attempt that sent it, when the caller has one. */
  attemptId?: string;
  /** 0 for the node's own prompt; n for the n-th structured-output re-ask. */
  reask: number;
  /** The loop iteration that sent it; absent outside an AI loop. */
  iteration?: number;
}

/** The `data` of a `node_prompt` event. */
export function nodePromptData(
  prompt: string,
  position: NodePromptPosition
): Record<string, unknown> {
  const truncated = prompt.length > NODE_PROMPT_MAX_CHARS;
  return {
    prompt: truncated ? prompt.slice(0, NODE_PROMPT_MAX_CHARS) : prompt,
    ...(truncated ? { truncated: true, length: prompt.length } : {}),
    reask: position.reask,
    ...(position.attemptId !== undefined ? { attemptId: position.attemptId } : {}),
    ...(position.iteration !== undefined ? { iteration: position.iteration } : {}),
  };
}

/**
 * Record the prompt an AI node is about to send, so a run's log can show what each agent
 * was asked. Fire-and-forget: a failed write never fails the node.
 */
export function recordNodePrompt(
  ctx: Pick<RunLayersContext, 'deps' | 'workflowRun'>,
  stepName: string,
  prompt: string,
  position: NodePromptPosition
): void {
  ctx.deps.store
    .createWorkflowEvent({
      workflow_run_id: ctx.workflowRun.id,
      event_type: NODE_PROMPT_EVENT_TYPE,
      step_name: stepName,
      data: nodePromptData(prompt, position),
    })
    .catch((err: Error) => {
      getLog().warn({ err, stepName }, 'node_prompt_event_persist_failed');
    });
}
