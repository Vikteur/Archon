import { useMemo, useState, type ReactElement } from 'react';
import { formatClock, formatRelativeToBaseline } from '../lib/format';
import { useStreamContext } from '../lib/stream-context';
import {
  mcpResultOf,
  paramValueFull,
  paramsPreview,
  type McpCall,
  type McpResult,
} from '../lib/mcp-call';
import type { InlineToolCall } from '../primitives/message';
import { CopyButton } from './CopyButton';
import { StatusPill, formatDuration } from './ScriptRunItem';

interface McpCallItemProps {
  call: InlineToolCall;
  mcp: McpCall;
  timestamp: string;
}

// Inline colours: the console scope's wildcard border-color rule repaints Tailwind
// border utilities (see theme.css), so accents are set through style.
export const MCP_ACCENT = 'var(--brand-teal)';

const RESULT_PREVIEW_CHARS = 20_000;

/**
 * A call to an MCP server's tool. It stands out from ordinary tool rows (teal accent,
 * MCP tag, `server · tool` up front, the parameters and the answer's digest) and opens
 * onto each parameter in full and the answer, JSON indented.
 */
export function McpCallItem({ call, mcp, timestamp }: McpCallItemProps): ReactElement {
  const [expanded, setExpanded] = useState(false);
  const { runStartedAt } = useStreamContext();
  const displayed = formatRelativeToBaseline(timestamp, runStartedAt);
  const wallClock = formatClock(timestamp);
  const failed = call.status === 'failed' || call.status === 'cancelled';
  const tone = failed ? 'var(--error)' : MCP_ACCENT;
  const result = useMemo(() => mcpResultOf(call.output), [call.output]);
  const preview = paramsPreview(mcp.params);

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
              color: MCP_ACCENT,
              background: `color-mix(in oklch, ${MCP_ACCENT}, transparent 80%)`,
              borderColor: `color-mix(in oklch, ${MCP_ACCENT}, transparent 50%)`,
            }}
          >
            MCP
          </span>
          {/* Below md the tool and its parameters take their own line under the badge. */}
          <span className="order-last flex min-w-0 basis-full flex-col gap-0.5 md:order-none md:flex-1 md:basis-auto">
            <span className="flex min-w-0 items-baseline gap-2.5">
              <span className="min-w-0 truncate font-mono text-[13px] md:shrink-0">
                <span className="text-text-secondary">{mcp.server}</span>
                <span className="text-text-tertiary"> · </span>
                <span className="font-bold" style={{ color: MCP_ACCENT }}>
                  {mcp.tool}
                </span>
              </span>
              {preview.length > 0 ? (
                <span className="min-w-0 truncate font-mono text-[12px] text-text-secondary">
                  {preview}
                </span>
              ) : null}
            </span>
            {result !== null && !expanded ? (
              <span className="truncate font-mono text-[12px] text-text-tertiary">
                → {result.summary}
              </span>
            ) : null}
          </span>
          <span className="mt-[1px] ml-auto flex shrink-0 items-center gap-3 md:ml-0">
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
        {expanded ? <McpCallDetails call={call} mcp={mcp} result={result} /> : null}
      </div>
    </div>
  );
}

function SectionLabel({ children }: { children: string }): ReactElement {
  return (
    <span className="font-mono text-[10.5px] uppercase tracking-[0.08em] text-text-tertiary">
      {children}
    </span>
  );
}

function McpCallDetails({
  call,
  mcp,
  result,
}: {
  call: InlineToolCall;
  mcp: McpCall;
  result: McpResult | null;
}): ReactElement {
  const resultText = result === null ? '' : result.kind === 'json' ? result.pretty : result.text;
  const shown =
    resultText.length > RESULT_PREVIEW_CHARS
      ? `${resultText.slice(0, RESULT_PREVIEW_CHARS)}\n\n… (${(resultText.length - RESULT_PREVIEW_CHARS).toLocaleString()} more chars)`
      : resultText;
  const failed = call.status === 'failed' || call.status === 'cancelled';
  return (
    <div
      className="flex flex-col gap-2 border-t px-3 py-2.5"
      style={{
        borderColor: `color-mix(in oklch, ${MCP_ACCENT}, transparent 75%)`,
      }}
    >
      <div className="flex items-center justify-between gap-3">
        <SectionLabel>{`Tool mcp__${mcp.server}__${mcp.tool}`}</SectionLabel>
        <CopyButton text={JSON.stringify(call.input, null, 2) ?? ''} label="Copy params" />
      </div>
      {mcp.params.length === 0 ? (
        <span className="font-mono text-[12px] text-text-tertiary">No parameters.</span>
      ) : (
        <dl className="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 gap-y-1 font-mono text-[12px]">
          {mcp.params.map(([key, value]) => (
            <div key={key} className="contents">
              <dt className="text-text-tertiary">{key}</dt>
              <dd className="m-0 whitespace-pre-wrap break-words text-text-primary">
                {paramValueFull(value)}
              </dd>
            </div>
          ))}
        </dl>
      )}
      {result !== null ? (
        <>
          <div className="flex items-center justify-between gap-3 pt-1">
            <SectionLabel>{failed ? 'Error' : `Result · ${result.summary}`}</SectionLabel>
            <CopyButton text={resultText} label="Copy result" />
          </div>
          <pre
            className={`max-h-[60vh] overflow-auto whitespace-pre-wrap break-words font-mono text-[12px] leading-relaxed ${failed ? 'text-error' : 'text-text-secondary'}`}
          >
            {shown}
          </pre>
          {call.outputTruncated === true ? (
            <span className="font-mono text-[11px] text-warning">
              Result cut short by the provider.
            </span>
          ) : null}
        </>
      ) : (
        <span className="font-mono text-[12px] text-text-tertiary">
          {call.outcomeUnrecorded === true || call.status !== undefined
            ? 'No result recorded.'
            : 'Waiting for the result…'}
        </span>
      )}
    </div>
  );
}
