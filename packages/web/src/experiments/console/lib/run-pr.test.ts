import { describe, expect, test } from 'bun:test';
import { prFromEvents, toRunPr } from './run-pr';

const done = (data: object): { event_type: string; data: object } => ({
  event_type: 'node_completed',
  data,
});

describe('toRunPr', () => {
  test('reads the number of a GitHub pull request URL', () => {
    expect(toRunPr('https://github.com/Owner/repo-x/pull/242')).toEqual({
      url: 'https://github.com/Owner/repo-x/pull/242',
      number: 242,
    });
  });

  test('refuses what is not a pull request link', () => {
    for (const v of ['https://github.com/o/r/issues/3', 'javascript:alert(1)', 42, null, '']) {
      expect(toRunPr(v)).toBeNull();
    }
  });
});

describe('prFromEvents', () => {
  test("takes the pr field of a completed node's output", () => {
    const events = [
      done({ structured_output: { title: 'x' } }),
      done({ structured_output: { pr: 'https://github.com/o/r/pull/7', sha: 'abc' } }),
      { event_type: 'node_started', data: {} },
    ];
    expect(prFromEvents(events)?.number).toBe(7);
  });

  test('falls back to the node output text', () => {
    expect(prFromEvents([done({ node_output: '{"pr":"https://github.com/o/r/pull/9"}' })])).toEqual(
      { url: 'https://github.com/o/r/pull/9', number: 9 }
    );
  });

  test('the last node that opened one wins; none gives null', () => {
    const two = [
      done({ structured_output: { pr: 'https://github.com/o/r/pull/1' } }),
      done({ structured_output: { pr: 'https://github.com/o/r/pull/2' } }),
    ];
    expect(prFromEvents(two)?.number).toBe(2);
    expect(prFromEvents([done({ node_output: 'not json' }), done({})])).toBeNull();
    expect(
      prFromEvents([
        {
          event_type: 'node_failed',
          data: { structured_output: { pr: 'https://github.com/o/r/pull/3' } },
        },
      ])
    ).toBeNull();
  });
});
