import { useState, type ReactElement } from 'react';
import { formatClock, formatRelativeToBaseline } from '../lib/format';
import { useStreamContext } from '../lib/stream-context';
import { CopyButton } from './CopyButton';

interface PromptItemProps {
  prompt: string;
  /** Who got the prompt: the node, or the subagent a tool call started. */
  recipient: string;
  /** A short note beside the recipient: the re-ask, the loop iteration, the call's description. */
  note: string | null;
  timestamp: string;
  /** The prompt's full length when the engine cut it. */
  truncatedFrom?: number | null;
  /** A subagent's prompt is tagged as such; a node's own prompt is not. */
  subagent?: boolean;
  /** A subagent call's answer, shown under the prompt. */
  result?: string;
  /** A subagent call's state; absent for a node prompt. */
  status?: 'running' | 'completed' | 'failed';
}

// Inline colours: the console scope's wildcard border-color rule repaints Tailwind
// border utilities (see theme.css), so accents are set through style.
export const PROMPT_ACCENT = 'var(--accent)';

function firstLine(prompt: string): string {
  return (
    prompt
      .split('\n')
      .map(line => line.trim())
      .find(line => line.length > 0) ?? ''
  );
}

/**
 * The prompt an agent was given. It stands out from tool rows (magenta accent, PROMPT
 * tag, who got it up front, its first line) and opens onto the whole prompt as sent.
 */
export function PromptItem({
  prompt,
  recipient,
  note,
  timestamp,
  truncatedFrom = null,
  subagent = false,
  result,
  status,
}: PromptItemProps): ReactElement {
  const [expanded, setExpanded] = useState(false);
  const { runStartedAt } = useStreamContext();
  const displayed = formatRelativeToBaseline(timestamp, runStartedAt);
  const wallClock = formatClock(timestamp);
  const lines = prompt.split('\n').length;

  return (
    <div className="py-1.5">
      <div
        className="flex flex-col rounded-md border border-l-[3px]"
        style={{
          borderColor: `color-mix(in oklch, ${PROMPT_ACCENT}, transparent 55%)`,
          borderLeftColor: PROMPT_ACCENT,
          background: `color-mix(in oklch, ${PROMPT_ACCENT}, transparent 93%)`,
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
              color: PROMPT_ACCENT,
              background: `color-mix(in oklch, ${PROMPT_ACCENT}, transparent 80%)`,
              borderColor: `color-mix(in oklch, ${PROMPT_ACCENT}, transparent 50%)`,
            }}
          >
            {subagent ? 'Subagent prompt' : 'Prompt'}
          </span>
          {/* Below md the recipient and preview take their own line under the badge. */}
          <span className="order-last flex min-w-0 basis-full flex-col gap-0.5 md:order-none md:flex-1 md:basis-auto">
            <span className="flex min-w-0 items-baseline gap-2.5">
              <span
                className="min-w-0 truncate font-mono text-[13px] font-bold md:shrink-0"
                style={{ color: PROMPT_ACCENT }}
              >
                {recipient}
              </span>
              {note !== null ? (
                <span className="min-w-0 truncate font-mono text-[12px] text-text-secondary">
                  {note}
                </span>
              ) : null}
            </span>
            {expanded ? null : (
              <span className="truncate text-[12px] text-text-tertiary">{firstLine(prompt)}</span>
            )}
          </span>
          <span className="mt-[1px] ml-auto flex shrink-0 items-center gap-3 md:ml-0">
            {status === 'failed' ? (
              <span className="font-mono text-[11.5px] font-bold text-error">failed</span>
            ) : status === 'running' ? (
              <span className="font-mono text-[11.5px] text-text-tertiary">running…</span>
            ) : null}
            <span className="font-mono text-[11.5px] tabular-nums text-text-tertiary">
              {lines.toString()} {lines === 1 ? 'line' : 'lines'}
            </span>
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
          <div
            className="flex flex-col gap-2 border-t px-3 py-2.5"
            style={{ borderColor: `color-mix(in oklch, ${PROMPT_ACCENT}, transparent 75%)` }}
          >
            <div className="flex items-center justify-between gap-3">
              <span className="font-mono text-[10.5px] uppercase tracking-[0.08em] text-text-tertiary">
                Prompt as sent
              </span>
              <CopyButton text={prompt} label="Copy prompt" />
            </div>
            <pre className="max-h-[60vh] overflow-auto whitespace-pre-wrap break-words font-mono text-[12px] leading-relaxed text-text-primary">
              {prompt}
            </pre>
            {truncatedFrom !== null ? (
              <p className="font-mono text-[11px] text-warning">
                Cut to {prompt.length.toLocaleString()} of {truncatedFrom.toLocaleString()}{' '}
                characters when it was recorded.
              </p>
            ) : null}
            {result !== undefined && result.length > 0 ? (
              <>
                <span className="pt-1 font-mono text-[10.5px] uppercase tracking-[0.08em] text-text-tertiary">
                  Result
                </span>
                <pre className="max-h-[40vh] overflow-auto whitespace-pre-wrap break-words font-mono text-[12px] leading-relaxed text-text-secondary">
                  {result}
                </pre>
              </>
            ) : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}

/** The note beside a node prompt: which re-ask, which loop iteration. */
export function nodePromptNote(reask: number, iteration: number | null): string | null {
  const parts: string[] = [];
  if (iteration !== null) parts.push(`iteration ${iteration.toString()}`);
  if (reask > 0) parts.push(`re-ask ${reask.toString()}`);
  return parts.length > 0 ? parts.join(' · ') : null;
}
