import { describe, expect, test } from 'bun:test';
import { promptCallOf } from './prompt-call';

describe('promptCallOf', () => {
  test('reads an Agent call as a subagent prompt', () => {
    expect(
      promptCallOf({
        name: 'Agent',
        input: { prompt: 'Review the diff', subagent_type: 'reviewer', description: 'Review' },
      })
    ).toEqual({ prompt: 'Review the diff', agent: 'reviewer', description: 'Review' });
  });

  test('reads a Task call without a type or description', () => {
    expect(promptCallOf({ name: 'Task', input: { prompt: 'Find it' } })).toEqual({
      prompt: 'Find it',
      agent: null,
      description: null,
    });
  });

  test('other tools and calls without a prompt are not prompts', () => {
    expect(promptCallOf({ name: 'Bash', input: { prompt: 'x' } })).toBeNull();
    expect(promptCallOf({ name: 'Agent', input: { description: 'x' } })).toBeNull();
    expect(promptCallOf({ name: 'Agent', input: 'raw' })).toBeNull();
  });
});
