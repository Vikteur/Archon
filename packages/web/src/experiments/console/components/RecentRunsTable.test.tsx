import { describe, expect, test } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { toRun, type Run } from '../primitives/run';
import { detailFixture } from '../primitives/run.test-fixtures';
import { filterRecentRuns, NO_FILTERS, RecentRunsTable } from './RecentRunsTable';
import { RecentRunRow } from './RecentRunRow';

function run(over: Partial<Run>): Run {
  return { ...toRun(detailFixture.run), ...over };
}

const runs = [
  run({
    id: 'aaaa1111',
    status: 'completed',
    workflow: 'build-feature',
    userMessage: 'TASK-7.4: sign in',
    projectName: 'portal',
    costUsd: 11.44,
    startedAt: '2026-11-18T10:00:00Z',
    finishedAt: '2026-11-18T10:30:00Z',
  }),
  run({
    id: 'bbbb2222',
    status: 'failed',
    workflow: 'build-feature',
    userMessage: 'TASK-48.8: gapless numbering',
    projectName: 'portal',
    costUsd: 5.19,
    startedAt: '2026-11-18T09:00:00Z',
    finishedAt: '2026-11-18T09:10:00Z',
  }),
  run({
    id: 'cccc3333',
    status: 'completed',
    workflow: 'portal-metrics',
    userMessage: '',
    projectName: 'other',
    costUsd: null,
    startedAt: '2026-11-18T08:00:00Z',
    finishedAt: '2026-11-18T08:01:00Z',
  }),
];
const ids = (rs: Run[]): string[] => rs.map(r => r.id);

describe('filterRecentRuns', () => {
  test('no filter keeps the feed order', () => {
    expect(ids(filterRecentRuns(runs, NO_FILTERS, null))).toEqual([
      'aaaa1111',
      'bbbb2222',
      'cccc3333',
    ]);
  });

  test('each column filters', () => {
    const f = (over: Partial<typeof NO_FILTERS>): string[] =>
      ids(filterRecentRuns(runs, { ...NO_FILTERS, ...over }, null));
    expect(f({ status: 'failed' })).toEqual(['bbbb2222']);
    expect(f({ workflow: 'portal-metrics' })).toEqual(['cccc3333']);
    expect(f({ request: 'SIGN' })).toEqual(['aaaa1111']);
    expect(f({ project: 'other' })).toEqual(['cccc3333']);
    expect(f({ id: 'BBBB' })).toEqual(['bbbb2222']);
    expect(f({ workflow: 'build-feature', status: 'completed' })).toEqual(['aaaa1111']);
  });

  test('cost sorts both ways, runs without a cost last', () => {
    expect(ids(filterRecentRuns(runs, NO_FILTERS, { key: 'cost', dir: 'desc' }))).toEqual([
      'aaaa1111',
      'bbbb2222',
      'cccc3333',
    ]);
    expect(ids(filterRecentRuns(runs, NO_FILTERS, { key: 'cost', dir: 'asc' }))).toEqual([
      'bbbb2222',
      'aaaa1111',
      'cccc3333',
    ]);
  });

  test('duration sorts by elapsed time', () => {
    expect(ids(filterRecentRuns(runs, NO_FILTERS, { key: 'duration', dir: 'asc' }))).toEqual([
      'cccc3333',
      'bbbb2222',
      'aaaa1111',
    ]);
  });
});

describe('RecentRunsTable', () => {
  const html = (showProject: boolean): string =>
    renderToStaticMarkup(
      <MemoryRouter>
        <RecentRunsTable
          runs={runs}
          showProject={showProject}
          selectedRunId={null}
          renderHeader={(shown, total) => (
            <span>{`${shown.toString()} of ${total.toString()}`}</span>
          )}
        />
      </MemoryRouter>
    );

  test('the header names and filters every column', () => {
    const out = html(true);
    for (const label of ['status', 'workflow', 'request', 'project', 'run id']) {
      expect(out).toContain(`aria-label="Filter by ${label}"`);
    }
    expect(out).toContain('aria-label="Sort by duration"');
    expect(out).toContain('aria-label="Sort by cost"');
    expect(out).toContain('3 of 3');
  });

  test('the project filter shows only across projects', () => {
    expect(html(false)).not.toContain('aria-label="Filter by project"');
  });

  test('rows show the bare cost under the Cost header', () => {
    const out = html(false);
    expect(out).toContain('>$11.44<');
    expect(out).not.toContain('Reported cost');
    expect(out).toContain('grid-cols-subgrid');
  });

  test('the PR column links the pull request the run opened, in a new tab', () => {
    expect(html(false)).toContain('>PR<');
    const row = renderToStaticMarkup(
      <MemoryRouter>
        <RecentRunRow
          run={runs[0] as Run}
          inTable
          pr={{ url: 'https://github.com/o/r/pull/242', number: 242 }}
        />
      </MemoryRouter>
    );
    expect(row).toContain('href="https://github.com/o/r/pull/242"');
    expect(row).toContain('target="_blank"');
    expect(row).toContain('>#242</a>');
  });
});
