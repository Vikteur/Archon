import { useState, type ReactElement } from 'react';
import { formatClock, formatRelativeToBaseline } from '../lib/format';
import { useStreamContext } from '../lib/stream-context';
import { docLineCount, type DocRead } from '../lib/doc-read';
import type { InlineToolCall } from '../primitives/message';
import { CopyButton } from './CopyButton';
import { StatusPill, formatDuration } from './ScriptRunItem';

interface DocReadItemProps {
  call: InlineToolCall;
  doc: DocRead;
  timestamp: string;
}

// Inline colours: the console scope's wildcard border-color rule repaints Tailwind
// border utilities (see theme.css), so accents are set through style.
export const DOC_ACCENT = 'var(--running)';

const CONTENT_PREVIEW_CHARS = 20_000;

/**
 * An agent reading a doc file. It stands out from ordinary tool rows (blue accent, DOC tag,
 * the file name up front with its folder and the part read) and opens onto the full path and
 * what the read answered.
 */
export function DocReadItem({ call, doc, timestamp }: DocReadItemProps): ReactElement {
  const [expanded, setExpanded] = useState(false);
  const { runStartedAt } = useStreamContext();
  const displayed = formatRelativeToBaseline(timestamp, runStartedAt);
  const wallClock = formatClock(timestamp);
  const failed = call.status === 'failed' || call.status === 'cancelled';
  const tone = failed ? 'var(--error)' : DOC_ACCENT;
  const lines = failed ? null : docLineCount(call.output);

  return (
    <div className="py-1.5">
      <div
        className="flex flex-col rounded-md border border-l-[3px]"
        style={{
          borderColor: `color-mix(in oklch, ${tone}, transparent 55%)`,
          borderLeftColor: tone,
          background: `color-mix(in oklch, ${tone}, transparent 94%)`,
        }}
      >
        <button
          type="button"
          aria-expanded={expanded}
          title={doc.path}
          onClick={() => {
            setExpanded(v => !v);
          }}
          className="flex w-full flex-wrap items-start gap-x-4 gap-y-1 px-3 py-[9px] text-left md:flex-nowrap transition-colors hover:bg-surface-hover/50"
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
              color: DOC_ACCENT,
              background: `color-mix(in oklch, ${DOC_ACCENT}, transparent 80%)`,
              borderColor: `color-mix(in oklch, ${DOC_ACCENT}, transparent 50%)`,
            }}
          >
            Doc
          </span>
          {/* Below md the file and its folder take their own line under the badge. */}
          <span className="order-last flex min-w-0 basis-full items-baseline gap-2.5 md:order-none md:flex-1 md:basis-auto">
            <span
              className="shrink-0 font-mono text-[13px] font-bold"
              style={{ color: DOC_ACCENT }}
            >
              {doc.file}
            </span>
            {doc.dir.length > 0 ? (
              <span className="min-w-0 truncate font-mono text-[12px] text-text-tertiary">
                {doc.dir}
              </span>
            ) : null}
            {doc.range !== null ? (
              <span className="shrink-0 font-mono text-[12px] text-text-secondary">
                {doc.range}
              </span>
            ) : null}
          </span>
          <span className="mt-[1px] ml-auto flex shrink-0 items-center gap-3 md:ml-0">
            {lines !== null ? (
              <span className="font-mono text-[11.5px] tabular-nums text-text-tertiary">
                {lines.toString()} {lines === 1 ? 'line' : 'lines'}
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
        {expanded ? <DocReadDetails call={call} doc={doc} failed={failed} /> : null}
      </div>
    </div>
  );
}

function DocReadDetails({
  call,
  doc,
  failed,
}: {
  call: InlineToolCall;
  doc: DocRead;
  failed: boolean;
}): ReactElement {
  const output = call.output ?? '';
  const shown =
    output.length > CONTENT_PREVIEW_CHARS
      ? `${output.slice(0, CONTENT_PREVIEW_CHARS)}\n\n… (${(output.length - CONTENT_PREVIEW_CHARS).toLocaleString()} more chars)`
      : output;
  return (
    <div
      className="flex flex-col gap-2 border-t px-3 py-2.5"
      style={{ borderColor: `color-mix(in oklch, ${DOC_ACCENT}, transparent 75%)` }}
    >
      <div className="flex items-center justify-between gap-3">
        <span className="min-w-0 break-all font-mono text-[12px] text-text-secondary">
          {doc.path}
        </span>
        <CopyButton text={doc.path} label="Copy path" />
      </div>
      {output.length > 0 ? (
        <>
          <div className="flex items-center justify-between gap-3 pt-1">
            <span className="font-mono text-[10.5px] uppercase tracking-[0.08em] text-text-tertiary">
              {failed ? 'Error' : 'Content'}
            </span>
            <CopyButton text={output} label="Copy content" />
          </div>
          <pre
            className={`max-h-[60vh] overflow-auto whitespace-pre-wrap break-words font-mono text-[12px] leading-relaxed ${failed ? 'text-error' : 'text-text-secondary'}`}
          >
            {shown}
          </pre>
          {call.outputTruncated === true ? (
            <span className="font-mono text-[11px] text-warning">
              Content cut short by the provider.
            </span>
          ) : null}
        </>
      ) : (
        <span className="font-mono text-[12px] text-text-tertiary">
          {call.outcomeUnrecorded === true || call.status !== undefined
            ? 'No content recorded.'
            : 'Reading…'}
        </span>
      )}
    </div>
  );
}
