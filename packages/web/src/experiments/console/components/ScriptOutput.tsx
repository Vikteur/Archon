import { useMemo, useState, type ReactElement } from 'react';
import { analyzeOutput, type LineTone, type OutputLine } from '../lib/script-run';
import { CopyButton } from './CopyButton';

/** Longer streams open collapsed to their first and last lines. */
const COLLAPSE_ABOVE = 60;
const HEAD_LINES = 20;
const TAIL_LINES = 25;

const TONE_TEXT: Record<LineTone, string> = {
  error: 'text-error',
  warning: 'text-warning',
  success: 'text-success',
};

function toneBackground(tone: LineTone | null): string | undefined {
  if (tone === 'error') return 'color-mix(in oklch, var(--error), transparent 90%)';
  if (tone === 'warning') return 'color-mix(in oklch, var(--warning), transparent 92%)';
  return undefined;
}

function Line({ line }: { line: OutputLine }): ReactElement {
  return (
    <div className="flex gap-3 px-2" style={{ background: toneBackground(line.tone) }}>
      <span
        aria-hidden
        className="w-9 shrink-0 select-none text-right tabular-nums text-text-tertiary/70"
      >
        {line.number.toString()}
      </span>
      <span
        className={`min-w-0 flex-1 whitespace-pre-wrap break-words ${
          line.tone === null ? 'text-text-secondary' : TONE_TEXT[line.tone]
        }`}
      >
        {line.tag !== null ? (
          <span className="font-semibold" style={{ color: 'var(--accent-bright)' }}>
            {line.tag}
          </span>
        ) : null}
        {line.text.length > 0 ? line.text : ' '}
      </span>
    </div>
  );
}

function CountChip({ count, tone }: { count: number; tone: 'error' | 'warning' }): ReactElement {
  const noun = tone === 'error' ? 'error' : 'warning';
  return (
    <span className={`font-semibold ${TONE_TEXT[tone]}`}>
      {count.toString()} {count === 1 ? noun : `${noun}s`}
    </span>
  );
}

function ViewButton({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}): ReactElement {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`rounded px-1.5 py-[1px] transition-colors ${
        active
          ? 'bg-surface-hover text-text-primary'
          : 'text-text-tertiary hover:text-text-secondary'
      }`}
    >
      {label}
    </button>
  );
}

/**
 * One output stream of a script call, readable at a glance: numbered lines, errors and
 * warnings tinted and counted, success lines green, a leading `[tag]` picked out. A long
 * stream opens on its first and last lines; "Problems" lists only the error and warning
 * lines.
 */
export function ScriptOutput({
  stream,
  text,
}: {
  stream: 'stdout' | 'stderr';
  text: string;
}): ReactElement | null {
  const analysis = useMemo(() => analyzeOutput(text), [text]);
  const [mode, setMode] = useState<'all' | 'problems'>('all');
  const [expanded, setExpanded] = useState(false);
  const { lines, errors, warnings } = analysis;
  if (lines.length === 0) return null;

  const problems = errors + warnings;
  const showProblems = mode === 'problems' && problems > 0;
  const collapsible = !showProblems && !expanded && lines.length > COLLAPSE_ABOVE;
  const shown = showProblems
    ? lines.filter(l => l.tone === 'error' || l.tone === 'warning')
    : lines;
  const head = collapsible ? shown.slice(0, HEAD_LINES) : shown;
  const tail = collapsible ? shown.slice(-TAIL_LINES) : [];
  const hidden = collapsible ? shown.length - HEAD_LINES - TAIL_LINES : 0;

  return (
    <div
      className="overflow-hidden rounded border bg-surface-inset"
      style={{
        borderColor:
          stream === 'stderr' ? 'color-mix(in oklch, var(--error), transparent 60%)' : undefined,
      }}
    >
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-border/60 px-2 py-1 font-mono text-[10.5px]">
        <span
          className={`font-semibold uppercase tracking-wider ${
            stream === 'stderr' ? 'text-error' : 'text-text-tertiary'
          }`}
        >
          {stream}
        </span>
        <span className="text-text-tertiary">
          {lines.length.toString()} {lines.length === 1 ? 'line' : 'lines'}
        </span>
        {errors > 0 ? <CountChip count={errors} tone="error" /> : null}
        {warnings > 0 ? <CountChip count={warnings} tone="warning" /> : null}
        <span className="ml-auto flex items-center gap-1">
          {problems > 0 ? (
            <>
              <ViewButton
                label="All"
                active={!showProblems}
                onClick={() => {
                  setMode('all');
                }}
              />
              <ViewButton
                label={`Problems ${problems.toString()}`}
                active={showProblems}
                onClick={() => {
                  setMode('problems');
                }}
              />
            </>
          ) : null}
          <CopyButton text={text} label={`Copy ${stream}`} />
        </span>
      </div>
      <div className="max-h-[480px] overflow-y-auto py-1 font-mono text-[11px] leading-[1.55]">
        {head.map(line => (
          <Line key={line.number} line={line} />
        ))}
        {hidden > 0 ? (
          <button
            type="button"
            onClick={() => {
              setExpanded(true);
            }}
            className="my-0.5 flex w-full items-center gap-3 px-2 py-1 text-left text-text-tertiary transition-colors hover:bg-surface-hover/60 hover:text-text-primary"
          >
            <span aria-hidden className="w-9 shrink-0 text-right">
              ⋯
            </span>
            <span>
              {hidden.toString()} more lines · <span className="underline">show all</span>
            </span>
          </button>
        ) : null}
        {tail.map(line => (
          <Line key={line.number} line={line} />
        ))}
      </div>
    </div>
  );
}
