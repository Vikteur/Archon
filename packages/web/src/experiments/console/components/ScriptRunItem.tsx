import { useState, type ReactElement, type ReactNode } from 'react';
import { formatClock, formatRelativeToBaseline } from '../lib/format';
import { useStreamContext } from '../lib/stream-context';
import { parseShellOutput, prettyJsonParam, type ScriptRun } from '../lib/script-run';
import type { InlineToolCall } from '../primitives/message';

interface ScriptRunItemProps {
  call: InlineToolCall;
  command: string;
  runs: ScriptRun[];
  timestamp: string;
}

const OUTPUT_PREVIEW_CHARS = 8000;
// Inline colours: the console scope's wildcard border-color rule repaints Tailwind
// border utilities (see theme.css), so accents are set through style.
const ACCENT = 'var(--warning)';

function baseName(path: string): string {
  return path.split('/').pop() ?? path;
}

function argsPreview(args: readonly string[]): string {
  return args
    .map(arg => {
      const shown = arg.length > 40 ? `${arg.slice(0, 40)}…` : arg;
      return /\s/.test(shown) || shown.length === 0 ? `'${shown}'` : shown;
    })
    .join(' ');
}

/**
 * A shell tool call that ran one or more scripts. It stands out from ordinary tool
 * rows (amber accent, SCRIPT tag, the script's name up front) and opens onto what ran:
 * each script with its parameters, directory and environment, then the output.
 */
export function ScriptRunItem({
  call,
  command,
  runs,
  timestamp,
}: ScriptRunItemProps): ReactElement {
  const [expanded, setExpanded] = useState(false);
  const { runStartedAt } = useStreamContext();
  const displayed = formatRelativeToBaseline(timestamp, runStartedAt);
  const wallClock = formatClock(timestamp);
  const failed = call.status === 'failed' || call.status === 'cancelled';
  const first = runs[0];
  const names = [...new Set(runs.map(run => baseName(run.script)))];

  return (
    <div className="py-1.5">
      <div
        className="flex flex-col rounded-md border border-l-[3px]"
        style={{
          borderColor: `color-mix(in oklch, ${failed ? 'var(--error)' : ACCENT}, transparent 55%)`,
          borderLeftColor: failed ? 'var(--error)' : ACCENT,
          background: `color-mix(in oklch, ${failed ? 'var(--error)' : ACCENT}, transparent 93%)`,
        }}
      >
        <button
          type="button"
          aria-expanded={expanded}
          onClick={() => {
            setExpanded(v => !v);
          }}
          className="flex w-full items-center gap-4 px-3 py-[10px] text-left transition-colors hover:bg-surface-hover/50"
        >
          <time
            dateTime={timestamp}
            title={wallClock}
            className="w-14 shrink-0 font-mono text-[11.5px] tabular-nums text-text-tertiary"
          >
            {displayed}
          </time>
          <span
            className="shrink-0 rounded-[5px] border px-[7px] py-[2px] font-mono text-[10px] font-bold uppercase tracking-[0.08em]"
            style={{
              color: ACCENT,
              background: `color-mix(in oklch, ${ACCENT}, transparent 80%)`,
              borderColor: `color-mix(in oklch, ${ACCENT}, transparent 50%)`,
            }}
          >
            {runs.length > 1 ? `Script ×${runs.length.toString()}` : 'Script'}
          </span>
          <span className="flex min-w-0 flex-1 items-baseline gap-2.5">
            <span
              className="shrink-0 font-mono text-[13px] font-bold"
              style={{ color: ACCENT }}
              title={first.script}
            >
              {names.join(', ')}
            </span>
            {first.args.length > 0 ? (
              <span className="min-w-0 truncate font-mono text-[12px] text-text-secondary">
                {argsPreview(first.args)}
              </span>
            ) : null}
          </span>
          <StatusPill call={call} />
          {call.durationMs !== undefined ? (
            <span className="shrink-0 font-mono text-[11.5px] tabular-nums text-text-tertiary">
              {call.durationMs.toString()}ms
            </span>
          ) : null}
          <span
            aria-hidden
            className="shrink-0 font-mono text-[11px] text-text-tertiary transition-transform"
            style={{ transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)' }}
          >
            ▸
          </span>
        </button>
        {expanded ? <ScriptRunDetails call={call} command={command} runs={runs} /> : null}
      </div>
    </div>
  );
}

function StatusPill({ call }: { call: InlineToolCall }): ReactElement | null {
  if (call.outcomeUnrecorded === true) {
    return (
      <span className="shrink-0 font-mono text-[11.5px] text-text-tertiary">
        no result recorded
      </span>
    );
  }
  if (call.status === 'failed' || call.status === 'cancelled') {
    return (
      <span className="shrink-0 font-mono text-[11.5px] font-bold text-error">
        {call.status}
        {call.exitCode !== undefined ? ` (exit ${call.exitCode.toString()})` : ''}
      </span>
    );
  }
  if (call.status === 'completed') {
    return (
      <span className="shrink-0 font-mono text-[11.5px] text-success">
        ✓ ok{call.exitCode !== undefined ? ` (exit ${call.exitCode.toString()})` : ''}
      </span>
    );
  }
  return <span className="shrink-0 font-mono text-[11.5px] text-text-tertiary">running…</span>;
}

function Section({ title, children }: { title: string; children: ReactNode }): ReactElement {
  return (
    <div>
      <div className="mb-1 text-[9.5px] font-semibold uppercase tracking-wider text-text-tertiary">
        {title}
      </div>
      {children}
    </div>
  );
}

const PRE =
  'overflow-x-auto whitespace-pre-wrap break-words rounded border border-border bg-surface-inset p-2 font-mono text-[11px] leading-relaxed text-text-secondary';

function OutputBlock({ text, tone }: { text: string; tone?: 'error' }): ReactElement {
  const shown =
    text.length > OUTPUT_PREVIEW_CHARS
      ? `${text.slice(0, OUTPUT_PREVIEW_CHARS)}\n\n… (${(text.length - OUTPUT_PREVIEW_CHARS).toString()} more chars)`
      : text;
  return (
    <pre className={`max-h-[420px] overflow-y-auto ${PRE} ${tone === 'error' ? 'text-error' : ''}`}>
      {shown}
    </pre>
  );
}

function ScriptInvocation({ run }: { run: ScriptRun }): ReactElement {
  const envEntries = Object.entries(run.env);
  return (
    <div className="space-y-2 rounded border border-border bg-surface p-2.5">
      <div className="flex flex-wrap items-baseline gap-x-2 font-mono text-[12px]">
        {run.interpreter !== undefined ? (
          <span className="text-text-tertiary">
            {[run.interpreter, ...run.interpreterArgs].join(' ')}
          </span>
        ) : null}
        <span className="break-all font-bold text-text-primary">{run.script}</span>
      </div>
      {run.cwd !== undefined ? (
        <div className="font-mono text-[11px] text-text-tertiary">
          in <span className="break-all text-text-secondary">{run.cwd}</span>
        </div>
      ) : null}
      {envEntries.length > 0 ? (
        <Section title="Environment">
          <ul className="space-y-0.5 font-mono text-[11px]">
            {envEntries.map(([key, value]) => (
              <li key={key} className="break-all">
                <span className="text-text-primary">{key}</span>
                <span className="text-text-tertiary">=</span>
                <span className="text-text-secondary">{value}</span>
              </li>
            ))}
          </ul>
        </Section>
      ) : null}
      <Section title={`Parameters (${run.args.length.toString()})`}>
        {run.args.length === 0 ? (
          <div className="font-mono text-[11px] text-text-tertiary">none</div>
        ) : (
          <ol className="space-y-1">
            {run.args.map((arg, index) => {
              const json = prettyJsonParam(arg);
              return (
                <li
                  key={`${index.toString()}:${arg}`}
                  className="flex gap-2 font-mono text-[11.5px]"
                >
                  <span className="w-5 shrink-0 text-right tabular-nums text-text-tertiary">
                    {(index + 1).toString()}
                  </span>
                  {json !== null ? (
                    <pre className={`min-w-0 flex-1 ${PRE}`}>{json}</pre>
                  ) : (
                    <span className="min-w-0 break-all text-text-primary">{arg}</span>
                  )}
                </li>
              );
            })}
          </ol>
        )}
      </Section>
    </div>
  );
}

function ScriptRunDetails({
  call,
  command,
  runs,
}: Pick<ScriptRunItemProps, 'call' | 'command' | 'runs'>): ReactElement {
  const output =
    call.output !== undefined && call.output.length > 0 ? parseShellOutput(call.output) : null;
  return (
    <div className="space-y-3 border-t border-border/60 px-3 pb-3 pt-2.5 sm:pl-[88px]">
      <Section title={runs.length > 1 ? 'Scripts' : 'Script'}>
        <div className="space-y-2">
          {runs.map((run, index) => (
            <ScriptInvocation key={`${index.toString()}:${run.script}`} run={run} />
          ))}
        </div>
      </Section>
      <Section title="Output">
        {output === null ? (
          <div className="font-mono text-[11px] text-text-tertiary">
            {call.status === undefined && call.outcomeUnrecorded !== true
              ? 'still running…'
              : 'no output'}
          </div>
        ) : (
          <div className="space-y-1.5">
            {output.stdout.length > 0 ? <OutputBlock text={output.stdout} /> : null}
            {output.stderr.length > 0 ? (
              <div>
                <div className="mb-0.5 font-mono text-[10px] text-error">stderr</div>
                <OutputBlock text={output.stderr} tone="error" />
              </div>
            ) : null}
            {output.stdout.length === 0 && output.stderr.length === 0 ? (
              <div className="font-mono text-[11px] text-text-tertiary">no output</div>
            ) : null}
            {output.interrupted ? (
              <div className="text-[10px] text-error">The command was interrupted.</div>
            ) : null}
            {call.outputTruncated === true ? (
              <div className="text-[10px] text-text-tertiary">
                Output cut short by the provider.
              </div>
            ) : null}
          </div>
        )}
      </Section>
      <details>
        <summary className="cursor-pointer text-[9.5px] font-semibold uppercase tracking-wider text-text-tertiary">
          Full command
        </summary>
        <pre className={`mt-1 max-h-[320px] overflow-y-auto ${PRE}`}>{command}</pre>
      </details>
    </div>
  );
}
