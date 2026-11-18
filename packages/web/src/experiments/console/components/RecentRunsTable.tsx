import { useMemo, useState, type ReactElement } from 'react';
import { RecentRunRow, recentRunGridCols } from './RecentRunRow';
import type { Run } from '../primitives/run';
import { elapsedSince } from '../lib/format';
import { useRunPrs } from '../lib/run-pr';

type SortKey = 'duration' | 'cost';
type SortDir = 'desc' | 'asc';

export interface RecentRunFilters {
  status: string;
  workflow: string;
  request: string;
  project: string;
  id: string;
}

export const NO_FILTERS: RecentRunFilters = {
  status: '',
  workflow: '',
  request: '',
  project: '',
  id: '',
};

/** The runs the column filters keep, in feed order or sorted by one numeric column. */
export function filterRecentRuns(
  runs: Run[],
  filters: RecentRunFilters,
  sort: { key: SortKey; dir: SortDir } | null
): Run[] {
  const request = filters.request.trim().toLowerCase();
  const id = filters.id.trim().toLowerCase();
  const kept = runs.filter(
    r =>
      (filters.status === '' || r.status === filters.status) &&
      (filters.workflow === '' || r.workflow === filters.workflow) &&
      (filters.project === '' || (r.projectName ?? '') === filters.project) &&
      (request === '' || r.userMessage.toLowerCase().includes(request)) &&
      (id === '' || r.id.toLowerCase().startsWith(id))
  );
  if (sort === null) return kept;
  const value = (r: Run): number | null =>
    sort.key === 'cost' ? r.costUsd : elapsedSince(r.startedAt, r.finishedAt ?? undefined);
  const sign = sort.dir === 'desc' ? -1 : 1;
  // Runs without a value (no reported cost) go last either way.
  return [...kept].sort((a, b) => {
    const va = value(a);
    const vb = value(b);
    if (va === null || vb === null) return va === vb ? 0 : va === null ? 1 : -1;
    return sign * (va - vb);
  });
}

function distinct(values: string[]): string[] {
  return [...new Set(values.filter(v => v !== ''))].sort((a, b) => a.localeCompare(b));
}

const PR_LOOKUPS = 50;

const HEAD_TEXT =
  'font-mono text-[10.5px] font-semibold uppercase tracking-[0.08em] text-text-tertiary';
// -ml-[7px] (its border and padding) starts a control's text at its column's edge, where the rows' values start.
const CONTROL = `${HEAD_TEXT} -ml-[7px] rounded-[6px] border bg-surface-elevated px-1.5 py-[3px] outline-none focus:border-accent-bright/60`;
const CONTROL_STYLE = { borderColor: 'var(--border)' };

interface HeadSelectProps {
  label: string;
  value: string;
  options: string[];
  onChange: (value: string) => void;
}

function HeadSelect({ label, value, options, onChange }: HeadSelectProps): ReactElement {
  return (
    <select
      aria-label={`Filter by ${label.toLowerCase()}`}
      value={value}
      onChange={e => {
        onChange(e.target.value);
      }}
      className={`${CONTROL} min-w-0 max-w-full ${value !== '' ? 'text-text-primary' : ''}`}
      style={CONTROL_STYLE}
    >
      <option value="">{label}</option>
      {options.map(o => (
        <option key={o} value={o}>
          {o}
        </option>
      ))}
    </select>
  );
}

interface HeadInputProps {
  label: string;
  value: string;
  onChange: (value: string) => void;
  className?: string;
}

function HeadInput({ label, value, onChange, className = '' }: HeadInputProps): ReactElement {
  return (
    <input
      type="search"
      aria-label={`Filter by ${label.toLowerCase()}`}
      placeholder={label}
      value={value}
      onChange={e => {
        onChange(e.target.value);
      }}
      className={`${CONTROL} min-w-0 normal-case tracking-normal placeholder:uppercase placeholder:tracking-[0.08em] placeholder:text-text-tertiary ${className}`}
      style={CONTROL_STYLE}
    />
  );
}

interface RecentRunsTableProps {
  runs: Run[];
  showProject: boolean;
  selectedRunId: string | null;
  /** Called with the rows shown, so the section header can count them. */
  renderHeader: (shown: number, total: number) => ReactElement;
}

/**
 * The Recent runs as a table: a header row whose column names filter
 * (status, workflow, request, project, run id) or sort (duration, cost), over
 * rows that share its grid so every column lines up.
 */
export function RecentRunsTable({
  runs,
  showProject,
  selectedRunId,
  renderHeader,
}: RecentRunsTableProps): ReactElement {
  const [filters, setFilters] = useState<RecentRunFilters>(NO_FILTERS);
  const [sort, setSort] = useState<{ key: SortKey; dir: SortDir } | null>(null);
  const shown = useMemo(() => filterRecentRuns(runs, filters, sort), [runs, filters, sort]);
  const statuses = useMemo(() => distinct(runs.map(r => r.status)), [runs]);
  const workflows = useMemo(() => distinct(runs.map(r => r.workflow)), [runs]);
  // Only the first rows shown: each lookup reads a whole run's events.
  const prs = useRunPrs(useMemo(() => shown.slice(0, PR_LOOKUPS), [shown]));
  const projects = useMemo(() => distinct(runs.map(r => r.projectName ?? '')), [runs]);
  const filtered =
    sort !== null ||
    (Object.keys(filters) as (keyof RecentRunFilters)[]).some(k => filters[k] !== '');

  const set =
    (key: keyof RecentRunFilters) =>
    (value: string): void => {
      setFilters(f => ({ ...f, [key]: value }));
    };

  const sortButton = (key: SortKey, label: string, title?: string): ReactElement => {
    const dir = sort?.key === key ? sort.dir : null;
    return (
      <button
        type="button"
        title={title ?? `Sort by ${label.toLowerCase()}`}
        aria-label={`Sort by ${label.toLowerCase()}`}
        onClick={() => {
          setSort(
            dir === null ? { key, dir: 'desc' } : dir === 'desc' ? { key, dir: 'asc' } : null
          );
        }}
        className={`${HEAD_TEXT} justify-self-end hover:text-text-primary ${dir !== null ? 'text-text-primary' : ''}`}
      >
        {label}
        <span aria-hidden className="ml-1">
          {dir === 'desc' ? '▼' : dir === 'asc' ? '▲' : '↕'}
        </span>
      </button>
    );
  };

  return (
    <>
      {renderHeader(shown.length, runs.length)}
      <div
        className={`grid gap-x-[18px] overflow-hidden rounded-[12px] border border-border bg-surface ${recentRunGridCols(showProject)}`}
      >
        <div
          role="row"
          className="col-span-full grid grid-cols-subgrid items-center border-b border-border/60 bg-surface-elevated/40 px-[18px] py-[9px]"
        >
          <HeadSelect
            label="Status"
            value={filters.status}
            options={statuses}
            onChange={set('status')}
          />
          <HeadSelect
            label="Workflow"
            value={filters.workflow}
            options={workflows}
            onChange={set('workflow')}
          />
          <HeadInput
            label="Request"
            value={filters.request}
            onChange={set('request')}
            className="w-full max-w-[320px]"
          />
          {showProject ? (
            <HeadSelect
              label="Project"
              value={filters.project}
              options={projects}
              onChange={set('project')}
            />
          ) : null}
          <span className={HEAD_TEXT} title="The pull request the run opened">
            PR
          </span>
          <HeadInput label="Run id" value={filters.id} onChange={set('id')} className="w-full" />
          {sortButton('duration', 'Duration')}
          {sortButton('cost', 'Cost', 'Reported agent cost; may be partial. Click to sort.')}
          <span className="flex justify-end">
            {filtered ? (
              <button
                type="button"
                onClick={() => {
                  setFilters(NO_FILTERS);
                  setSort(null);
                }}
                className={`${HEAD_TEXT} hover:text-text-primary`}
              >
                Clear
              </button>
            ) : null}
          </span>
        </div>
        {shown.map(run => (
          <RecentRunRow
            key={run.id}
            run={run}
            showProject={showProject}
            selected={run.id === selectedRunId}
            inTable
            pr={prs.get(run.id)}
          />
        ))}
        {shown.length === 0 ? (
          <div className="col-span-full px-[18px] py-[13px] text-[12.5px] text-text-tertiary">
            No runs match these filters.
          </div>
        ) : null}
      </div>
    </>
  );
}
