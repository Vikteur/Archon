import { useMemo, useState, type ReactElement, type ReactNode } from 'react';
import { formatClock, formatRelativeToBaseline } from '../lib/format';
import { useStreamContext } from '../lib/stream-context';
import {
  analyzeOutput,
  argKind,
  expandVars,
  parseShellOutput,
  prettyJsonParam,
  runPreview,
  shellDescriptionOf,
  type ArgKind,
  type ScriptRun,
  type ShellOutput,
} from '../lib/script-run';
import type { InlineToolCall } from '../primitives/message';
import { CopyButton } from './CopyButton';
import { ScriptOutput } from './ScriptOutput';

interface ScriptRunItemProps {
  call: InlineToolCall;
  command: string;
  runs: ScriptRun[];
  timestamp: string;
}

// Inline colours: the console scope's wildcard border-color rule repaints Tailwind
// border utilities (see theme.css), so accents are set through style.
const ACCENT = 'var(--warning)';

function baseName(path: string): string {
  return path.replace(/\/+$/, '').split('/').pop() ?? path;
}

function splitPath(path: string): { dir: string; name: string } {
  const trimmed = path.replace(/\/+$/, '');
  const cut = trimmed.lastIndexOf('/');
  return cut === -1
    ? { dir: '', name: trimmed }
    : { dir: trimmed.slice(0, cut + 1), name: trimmed.slice(cut + 1) };
}

function outputOf(call: InlineToolCall): ShellOutput | null {
  return call.output !== undefined && call.output.length > 0 ? parseShellOutput(call.output) : null;
}

/**
 * A shell tool call that ran one or more scripts. It stands out from ordinary tool
 * rows (amber accent, SCRIPT tag, the script's name up front, problem counts) and opens
 * onto what ran: each script with its resolved parameters, then its output.
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
  const tone = failed ? 'var(--error)' : ACCENT;
  const description = shellDescriptionOf(call.input);
  const output = useMemo(() => outputOf(call), [call]);
  const problems = useMemo(() => {
    if (output === null) return { errors: 0, warnings: 0 };
    const out = analyzeOutput(output.stdout);
    const err = analyzeOutput(output.stderr);
    return { errors: out.errors + err.errors, warnings: out.warnings + err.warnings };
  }, [output]);

  return (
    <div className="py-1.5">
      <div
        className="flex flex-col rounded-md border border-l-[3px]"
        style={{
          borderColor: `color-mix(in oklch, ${tone}, transparent 55%)`,
          borderLeftColor: tone,
          background: `color-mix(in oklch, ${tone}, transparent 93%)`,
        }}
      >
        <button
          type="button"
          aria-expanded={expanded}
          onClick={() => {
            setExpanded(v => !v);
          }}
          className="flex w-full items-start gap-4 px-3 py-[9px] text-left transition-colors hover:bg-surface-hover/50"
        >
          <time
            dateTime={timestamp}
            title={wallClock}
            className="mt-[2px] w-14 shrink-0 font-mono text-[11.5px] tabular-nums text-text-tertiary"
          >
            {displayed}
          </time>
          <span
            className="mt-[1px] shrink-0 rounded-[5px] border px-[7px] py-[2px] font-mono text-[10px] font-bold uppercase tracking-[0.08em]"
            style={{
              color: ACCENT,
              background: `color-mix(in oklch, ${ACCENT}, transparent 80%)`,
              borderColor: `color-mix(in oklch, ${ACCENT}, transparent 50%)`,
            }}
          >
            {runs.length > 1 ? `Script ×${runs.length.toString()}` : 'Script'}
          </span>
          <span className="flex min-w-0 flex-1 flex-col gap-0.5">
            {runs.map((run, index) => (
              <RunHeadline key={`${index.toString()}:${run.script}`} run={run} />
            ))}
            {description !== null ? (
              <span className="truncate text-[12px] text-text-tertiary">{description}</span>
            ) : null}
          </span>
          <span className="mt-[1px] flex shrink-0 items-center gap-3">
            {problems.errors > 0 ? (
              <span className="font-mono text-[11px] font-semibold text-error">
                {problems.errors.toString()} err
              </span>
            ) : null}
            {problems.warnings > 0 ? (
              <span className="font-mono text-[11px] font-semibold text-warning">
                {problems.warnings.toString()} warn
              </span>
            ) : null}
            <StatusPill call={call} />
            {call.durationMs !== undefined ? (
              <span className="font-mono text-[11.5px] tabular-nums text-text-tertiary">
                {formatDuration(call.durationMs)}
              </span>
            ) : null}
            <span
              aria-hidden
              className="font-mono text-[11px] text-text-tertiary transition-transform"
              style={{ transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)' }}
            >
              ▸
            </span>
          </span>
        </button>
        {expanded ? (
          <ScriptRunDetails call={call} command={command} runs={runs} output={output} />
        ) : null}
      </div>
    </div>
  );
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms.toString()}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.round((ms % 60_000) / 1000);
  return `${minutes.toString()}m ${seconds.toString()}s`;
}

function RunHeadline({ run }: { run: ScriptRun }): ReactElement {
  const preview = runPreview(run);
  return (
    <span className="flex min-w-0 items-baseline gap-2.5">
      <span
        className="shrink-0 font-mono text-[13px] font-bold"
        style={{ color: ACCENT }}
        title={expandVars(run.script, run.vars)}
      >
        {baseName(expandVars(run.script, run.vars))}
      </span>
      {preview.length > 0 ? (
        <span className="min-w-0 truncate font-mono text-[12px] text-text-secondary">
          {preview}
        </span>
      ) : null}
    </span>
  );
}

function StatusPill({ call }: { call: InlineToolCall }): ReactElement | null {
  if (call.outcomeUnrecorded === true) {
    return <span className="font-mono text-[11.5px] text-text-tertiary">no result recorded</span>;
  }
  if (call.status === 'failed' || call.status === 'cancelled') {
    return (
      <span className="font-mono text-[11.5px] font-bold text-error">
        {call.status}
        {call.exitCode !== undefined ? ` (exit ${call.exitCode.toString()})` : ''}
      </span>
    );
  }
  if (call.status === 'completed') {
    return (
      <span className="font-mono text-[11.5px] text-success">
        ✓ ok{call.exitCode !== undefined ? ` (exit ${call.exitCode.toString()})` : ''}
      </span>
    );
  }
  return <span className="font-mono text-[11.5px] text-text-tertiary">running…</span>;
}

function Section({
  title,
  aside,
  children,
}: {
  title: string;
  aside?: ReactNode;
  children: ReactNode;
}): ReactElement {
  return (
    <div>
      <div className="mb-1 flex items-center gap-2 text-[9.5px] font-semibold uppercase tracking-wider text-text-tertiary">
        <span>{title}</span>
        {aside !== undefined ? <span className="ml-auto normal-case">{aside}</span> : null}
      </div>
      {children}
    </div>
  );
}

const PRE =
  'overflow-x-auto whitespace-pre-wrap break-words rounded border border-border bg-surface-inset p-2 font-mono text-[11px] leading-relaxed text-text-secondary';

function PathText({ path, strong = false }: { path: string; strong?: boolean }): ReactElement {
  const { dir, name } = splitPath(path);
  return (
    <span className="break-all">
      <span className="text-text-tertiary">{dir}</span>
      <span className={strong ? 'font-bold text-text-primary' : 'text-text-primary'}>{name}</span>
    </span>
  );
}

/** A raw parameter that used a variable, shown under its resolved value. */
function RawNote({ raw, resolved }: { raw: string; resolved: string }): ReactElement | null {
  if (raw === resolved) return null;
  return (
    <div className="break-all font-mono text-[10.5px] text-text-tertiary">
      as written: <span className="text-text-secondary">{raw}</span>
    </div>
  );
}

/** Syntax-tinted pretty JSON: keys, strings, numbers and literals apart. */
function JsonBlock({ pretty }: { pretty: string }): ReactElement {
  const parts: ReactNode[] = [];
  const token =
    /("(?:[^"\\]|\\.)*")(\s*:)?|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g;
  let last = 0;
  for (const match of pretty.matchAll(token)) {
    const at = match.index;
    if (at > last) parts.push(pretty.slice(last, at));
    const key = match[1] !== undefined && match[2] !== undefined;
    const color = key
      ? 'var(--accent-bright)'
      : match[1] !== undefined
        ? 'var(--success)'
        : match[3] !== undefined
          ? 'var(--warning)'
          : 'var(--brand-teal)';
    parts.push(
      <span key={at} style={{ color }}>
        {match[1] ?? match[0]}
      </span>
    );
    if (key) parts.push(match[2]);
    last = at + match[0].length;
  }
  if (last < pretty.length) parts.push(pretty.slice(last));
  return <pre className={`max-h-[360px] overflow-y-auto ${PRE}`}>{parts}</pre>;
}

const KIND_LABEL: Record<ArgKind, string> = {
  flag: 'flag',
  json: 'json',
  path: 'path',
  text: 'text',
};

function Parameter({ raw, run }: { raw: string; run: ScriptRun }): ReactElement {
  const resolved = expandVars(raw, run.vars);
  const kind = argKind(resolved);
  const json = kind === 'json' ? prettyJsonParam(resolved) : null;
  let body: ReactNode;
  if (json !== null) body = <JsonBlock pretty={json} />;
  else if (kind === 'flag') {
    body = (
      <span className="rounded bg-surface-hover px-1.5 py-[1px] text-text-primary">{resolved}</span>
    );
  } else if (kind === 'path') body = <PathText path={resolved} />;
  else body = <span className="whitespace-pre-wrap break-all text-text-primary">{resolved}</span>;

  return (
    <>
      <span className="pt-[1px] text-right text-[9.5px] uppercase tracking-wider text-text-tertiary">
        {KIND_LABEL[kind]}
      </span>
      <div className="min-w-0 space-y-0.5">
        {body}
        <RawNote raw={raw} resolved={resolved} />
      </div>
    </>
  );
}

function KeyValues({ entries }: { entries: [string, string][] }): ReactElement {
  return (
    <div className="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 gap-y-0.5 font-mono text-[11px]">
      {entries.map(([key, value]) => (
        <div key={key} className="contents">
          <span className="text-text-primary">{key}</span>
          <span className="break-all text-text-secondary">{value}</span>
        </div>
      ))}
    </div>
  );
}

function ScriptInvocation({ run }: { run: ScriptRun }): ReactElement {
  const envEntries = Object.entries(run.env);
  const varEntries = Object.entries(run.vars);
  const script = expandVars(run.script, run.vars);
  const cwd = run.cwd !== undefined ? expandVars(run.cwd, run.vars) : undefined;
  return (
    <div className="space-y-2.5 rounded border border-border bg-surface p-2.5">
      <div className="space-y-0.5 font-mono text-[12px]">
        <div className="flex flex-wrap items-baseline gap-x-2">
          {run.interpreter !== undefined ? (
            <span className="text-text-tertiary">
              {[run.interpreter, ...run.interpreterArgs].join(' ')}
            </span>
          ) : null}
          <PathText path={script} strong />
        </div>
        {cwd !== undefined ? (
          <div className="text-[11px] text-text-tertiary">
            in <span className="break-all text-text-secondary">{cwd}</span>
          </div>
        ) : null}
      </div>
      <Section title={`Parameters · ${run.args.length.toString()}`}>
        {run.args.length === 0 ? (
          <div className="font-mono text-[11px] text-text-tertiary">none</div>
        ) : (
          <div className="grid grid-cols-[2.25rem_minmax(0,1fr)] gap-x-2.5 gap-y-1.5 font-mono text-[11.5px]">
            {run.args.map((arg, index) => (
              <Parameter key={`${index.toString()}:${arg}`} raw={arg} run={run} />
            ))}
          </div>
        )}
      </Section>
      {envEntries.length > 0 ? (
        <Section title="Environment">
          <KeyValues entries={envEntries} />
        </Section>
      ) : null}
      {varEntries.length > 0 ? (
        <Section title="Shell variables">
          <KeyValues entries={varEntries.map(([key, value]) => [`$${key}`, value])} />
        </Section>
      ) : null}
    </div>
  );
}

function ScriptRunDetails({
  call,
  command,
  runs,
  output,
}: Pick<ScriptRunItemProps, 'call' | 'command' | 'runs'> & {
  output: ShellOutput | null;
}): ReactElement {
  const empty = output === null || (output.stdout.length === 0 && output.stderr.length === 0);
  return (
    <div className="space-y-3 border-t border-border/60 px-3 pb-3 pt-2.5 sm:pl-[88px]">
      <Section title={runs.length > 1 ? `Scripts · ${runs.length.toString()}` : 'Script'}>
        <div className="space-y-2">
          {runs.map((run, index) => (
            <ScriptInvocation key={`${index.toString()}:${run.script}`} run={run} />
          ))}
        </div>
      </Section>
      <Section title="Output">
        <div className="space-y-1.5">
          {output !== null ? <ScriptOutput stream="stdout" text={output.stdout} /> : null}
          {output !== null ? <ScriptOutput stream="stderr" text={output.stderr} /> : null}
          {empty ? (
            <div className="font-mono text-[11px] text-text-tertiary">
              {call.status === undefined && call.outcomeUnrecorded !== true
                ? 'still running…'
                : 'no output'}
            </div>
          ) : null}
          {output?.interrupted === true ? (
            <div className="text-[10px] text-error">The command was interrupted.</div>
          ) : null}
          {call.outputTruncated === true ? (
            <div className="text-[10px] text-text-tertiary">Output cut short by the provider.</div>
          ) : null}
        </div>
      </Section>
      <details>
        <summary className="cursor-pointer text-[9.5px] font-semibold uppercase tracking-wider text-text-tertiary">
          Full command
        </summary>
        <div className="mt-1 space-y-1">
          <div className="flex justify-end">
            <CopyButton text={command} label="Copy command" />
          </div>
          <pre className={`max-h-[320px] overflow-y-auto ${PRE}`}>{command}</pre>
        </div>
      </details>
    </div>
  );
}
