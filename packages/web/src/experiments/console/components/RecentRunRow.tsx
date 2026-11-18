import type { ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { OriginBadge } from './OriginBadge';
import { runDetailPath, type Run } from '../primitives/run';
import { shortRunId, formatElapsed, elapsedSince, formatCost } from '../lib/format';
import { useIsDocker, useIdeEnv, openInIde } from '../lib/health';
import { statusTextClass } from '../lib/run-status';
import { RunOutcomeBadge } from './RunOutcomeBadge';
import type { RunPr } from '../lib/run-pr';

interface RecentRunRowProps {
  run: Run;
  showProject?: boolean;
  selected?: boolean;
  /** In RecentRunsTable: the row takes the table's columns (subgrid) so it lines up with the header. */
  inTable?: boolean;
  /** The pull request the run opened, linked in the PR column. */
  pr?: RunPr;
}

/**
 * Row grid from md up: status | workflow | request | (project) | PR | id | duration | cost | CLI.
 * Below md a row wraps as a card: status, workflow, PR, cost / request / project, id, duration.
 */
export function recentRunGridCols(showProject: boolean): string {
  return showProject
    ? 'md:grid-cols-[220px_auto_minmax(0,1fr)_140px_56px_84px_70px_minmax(64px,auto)_auto]'
    : 'md:grid-cols-[220px_auto_minmax(0,1fr)_56px_84px_70px_minmax(64px,auto)_auto]';
}

const STATUS_GLYPH: Record<string, string> = {
  completed: '●',
  failed: '✕',
  cancelled: '◌',
};

/**
 * Compact one-liner row for terminal-state runs (completed / failed /
 * cancelled). ~36px tall, monospace, data-heavy. Scans like a log.
 *
 * Failed rows keep the error-red glyph and status text so they still catch
 * the eye in a sea of muted completed rows.
 */
export function RecentRunRow({
  run,
  showProject = false,
  selected = false,
  inTable = false,
  pr,
}: RecentRunRowProps): ReactElement {
  const navigate = useNavigate();
  const isDocker = useIsDocker();
  const ideEnv = useIdeEnv();
  const elapsed = formatElapsed(elapsedSince(run.startedAt, run.finishedAt ?? undefined));
  const canOpen = !run.id.startsWith('demo-');
  const canOpenIde =
    !isDocker && run.workingPath !== null && run.workingPath !== '' && !run.id.startsWith('demo-');
  const canRerun =
    run.projectId !== null &&
    run.workflow !== '' &&
    !run.id.startsWith('demo-') &&
    (run.status === 'completed' || run.status === 'failed' || run.status === 'cancelled');
  const glyph = STATUS_GLYPH[run.status] ?? '·';

  const onClick = (): void => {
    if (canOpen) navigate(runDetailPath(run));
  };

  const onRerun = (): void => {
    if (!canRerun || run.projectId === null) return;
    const params = new URLSearchParams({
      rerun: '1',
      workflow: run.workflow,
    });
    if (run.userMessage !== '') params.set('message', run.userMessage);
    navigate(`/console/p/${run.projectId}?${params.toString()}`);
  };

  const gridCols = inTable
    ? 'md:col-span-full md:grid-cols-subgrid'
    : `md:gap-[18px] ${recentRunGridCols(showProject)}`;

  const renderStatus = (): ReactElement => (
    <span className="order-1 flex items-center gap-[9px] md:order-none">
      {run.status === 'failed' ? (
        <span aria-hidden className={`text-[12px] leading-none ${statusTextClass.failed}`}>
          {glyph}
        </span>
      ) : (
        <span
          aria-hidden
          className={`h-2 w-2 shrink-0 rounded-full ${
            run.status === 'completed'
              ? 'bg-success shadow-[0_0_0_3px_color-mix(in_oklch,var(--success),transparent_85%)]'
              : 'bg-text-tertiary'
          }`}
        />
      )}
      <span
        className={`font-mono text-[11px] font-semibold uppercase tracking-[0.05em] ${statusTextClass[run.status]}`}
      >
        {run.status}
      </span>
      <RunOutcomeBadge outcome={run.outcome} />
    </span>
  );

  const renderRunSummary = (): ReactElement => (
    <>
      <span className="order-2 flex min-w-0 grow items-baseline gap-2.5 md:order-none">
        <span className="shrink-0 truncate font-mono text-[13px] font-bold text-text-primary">
          {run.workflow}
        </span>
        {run.parentRunId ? (
          <span
            className="shrink-0 rounded-[5px] border border-border/60 px-1.5 py-px font-mono text-[10px] font-semibold uppercase tracking-[0.04em] text-text-tertiary"
            title={`Sub-run of ${shortRunId(run.parentRunId)}`}
          >
            ↳ child
          </span>
        ) : null}
      </span>

      {/* Its own column, so it starts under the table's Request filter. */}
      <span
        className="order-5 min-w-0 basis-full truncate font-mono text-[13px] font-bold text-text-primary md:order-none md:basis-auto"
        title={run.userMessage !== '' ? run.userMessage : undefined}
      >
        {run.userMessage}
      </span>

      {showProject ? (
        <span className="order-6 truncate text-[12px] text-text-secondary md:order-none">
          {run.projectName ?? ''}
        </span>
      ) : null}

      <span className="order-3 font-mono text-[12px] md:order-none">
        {pr !== undefined ? (
          <a
            href={pr.url}
            target="_blank"
            rel="noopener noreferrer"
            title={`Open pull request #${pr.number.toString()} on GitHub`}
            onClick={e => {
              e.stopPropagation();
            }}
            onKeyDown={e => {
              e.stopPropagation();
            }}
            className="font-semibold text-accent-bright hover:underline"
          >
            #{pr.number}
          </a>
        ) : null}
      </span>

      <span className="order-7 font-mono text-[12px] text-text-tertiary md:order-none md:text-right">
        {shortRunId(run.id)}
      </span>
      <span className="order-8 font-mono text-[12px] tabular-nums text-text-secondary md:order-none md:text-right">
        {elapsed}
      </span>
      <span
        className="order-4 font-mono text-[12px] tabular-nums text-text-primary md:order-none md:text-right"
        title={typeof run.costUsd === 'number' ? 'Reported agent cost; may be partial' : undefined}
      >
        {typeof run.costUsd === 'number' ? formatCost(run.costUsd) : ''}
      </span>
    </>
  );

  return (
    <div
      data-run-id={run.id}
      onClick={onClick}
      role={canOpen ? 'button' : undefined}
      tabIndex={canOpen ? 0 : undefined}
      onKeyDown={
        canOpen
          ? (event): void => {
              if (
                event.target === event.currentTarget &&
                (event.key === 'Enter' || event.key === ' ')
              ) {
                event.preventDefault();
                onClick();
              }
            }
          : undefined
      }
      className={`group flex flex-wrap items-center gap-x-3 gap-y-1.5 border-b md:grid md:gap-y-0 border-border/40 px-[18px] py-[13px] transition-colors last:border-b-0 hover:bg-surface-hover ${gridCols} ${
        selected ? 'bg-surface-hover ring-2 ring-inset ring-accent-bright/40' : ''
      } ${canOpen ? 'cursor-pointer' : ''}`}
    >
      {renderStatus()}

      {renderRunSummary()}

      {/* trailing: origin + hover actions + CLI (from md up; a phone has no hover) */}
      <span className="hidden items-center justify-end gap-1.5 md:flex">
        {/* Origin + quick actions reveal on hover; the resting row matches the
            design (status · body · id · duration · cost · CLI). */}
        <span className="flex items-center gap-1.5 opacity-0 transition-opacity group-hover:opacity-100">
          <OriginBadge origin={run.origin} />
          {canRerun ? (
            <button
              type="button"
              onClick={e => {
                e.stopPropagation();
                onRerun();
              }}
              title={`Rerun ${run.workflow} with the same message`}
              aria-label="Rerun"
              className="rounded p-1 text-text-tertiary transition-colors hover:bg-surface-hover hover:text-text-primary"
            >
              <span aria-hidden className="text-[12px] leading-none">
                ↻
              </span>
            </button>
          ) : null}
          {canOpenIde && run.workingPath !== null ? (
            <button
              type="button"
              onClick={e => {
                e.stopPropagation();
                if (run.workingPath !== null) openInIde(run.workingPath, ideEnv);
              }}
              title={`Open ${run.workingPath} in IDE`}
              aria-label="Open in IDE"
              className="rounded p-1 text-text-tertiary transition-colors hover:bg-surface-hover hover:text-text-primary"
            >
              <span aria-hidden className="font-mono text-[12px] leading-none">
                ↗
              </span>
            </button>
          ) : null}
        </span>
        <button
          type="button"
          onClick={e => {
            e.stopPropagation();
            void navigator.clipboard.writeText(`archon workflow get ${run.id}`);
          }}
          title={`Copy CLI command: archon workflow get ${shortRunId(run.id)}`}
          aria-label="Copy CLI command"
          className="inline-flex items-center gap-1.5 rounded-[7px] border bg-surface-elevated px-2.5 py-[5px] font-mono text-[11px] font-semibold text-text-secondary transition-colors hover:border-accent-bright/50 hover:text-text-primary"
          // Inline because the console scope's wildcard border-color rule
          // repaints Tailwind border utilities (see theme.css).
          style={{ borderColor: 'var(--border-bright)' }}
        >
          <span aria-hidden className="text-[10px] leading-none">
            ❯_
          </span>
          CLI
        </button>
      </span>
    </div>
  );
}
