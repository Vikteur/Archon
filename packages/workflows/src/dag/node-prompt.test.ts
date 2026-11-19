import { describe, expect, it, mock } from 'bun:test';
import { NODE_PROMPT_MAX_CHARS, nodePromptData, recordNodePrompt } from './node-prompt';

describe('nodePromptData', () => {
  it('keeps the prompt and its position', () => {
    expect(nodePromptData('Build it', { attemptId: 'a1', reask: 0 })).toEqual({
      prompt: 'Build it',
      reask: 0,
      attemptId: 'a1',
    });
  });

  it('names the loop iteration', () => {
    expect(nodePromptData('Next', { reask: 1, iteration: 3 })).toEqual({
      prompt: 'Next',
      reask: 1,
      iteration: 3,
    });
  });

  it('cuts a prompt past the cap and records its full length', () => {
    const long = 'x'.repeat(NODE_PROMPT_MAX_CHARS + 5);
    const data = nodePromptData(long, { reask: 0 });
    expect((data.prompt as string).length).toBe(NODE_PROMPT_MAX_CHARS);
    expect(data.truncated).toBe(true);
    expect(data.length).toBe(NODE_PROMPT_MAX_CHARS + 5);
  });
});

describe('recordNodePrompt', () => {
  it('writes one node_prompt event under the step name', async () => {
    const createWorkflowEvent = mock(() => Promise.resolve());
    const ctx = {
      deps: { store: { createWorkflowEvent } },
      workflowRun: { id: 'run-1' },
    } as unknown as Parameters<typeof recordNodePrompt>[0];
    recordNodePrompt(ctx, 'implement.build-step', 'Do the step', { attemptId: 'a1', reask: 0 });
    await Promise.resolve();
    expect(createWorkflowEvent).toHaveBeenCalledWith({
      workflow_run_id: 'run-1',
      event_type: 'node_prompt',
      step_name: 'implement.build-step',
      data: { prompt: 'Do the step', reask: 0, attemptId: 'a1' },
    });
  });

  it('never throws when the write fails', async () => {
    const createWorkflowEvent = mock(() => Promise.reject(new Error('db down')));
    const ctx = {
      deps: { store: { createWorkflowEvent } },
      workflowRun: { id: 'run-1' },
    } as unknown as Parameters<typeof recordNodePrompt>[0];
    expect(() => {
      recordNodePrompt(ctx, 'plan', 'p', { reask: 0 });
    }).not.toThrow();
    await new Promise(resolve => setTimeout(resolve, 0));
  });
});
