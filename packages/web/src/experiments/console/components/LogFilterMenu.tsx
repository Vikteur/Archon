import { useEffect, useRef, useState, type ReactElement } from 'react';
import { LOG_KINDS, toggleLogKind, type LogKind } from '../lib/log-filter';

interface LogFilterMenuProps {
  /** The kinds picked; empty shows the whole log. */
  selected: readonly LogKind[];
  onChange: (next: LogKind[]) => void;
  /** How many rows of each kind the run has. */
  counts: Record<LogKind, number>;
}

function Dot({ accent, on }: { accent: string; on: boolean }): ReactElement {
  return (
    <span
      aria-hidden
      className="h-1.5 w-1.5 shrink-0 rounded-full"
      style={{ background: on ? accent : `color-mix(in oklch, ${accent}, transparent 50%)` }}
    />
  );
}

/**
 * One dropdown for the log's kind filter. Tick any number of kinds (prompts, scripts, MCP
 * calls, doc reads) and the log shows only those rows; tick none for the whole log.
 */
export function LogFilterMenu({ selected, onChange, counts }: LogFilterMenuProps): ReactElement {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent): void => {
      const t = e.target as Node | null;
      if (t !== null && rootRef.current?.contains(t) === true) return;
      setOpen(false);
    };
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', onDoc);
    document.addEventListener('keydown', onKey, true);
    return (): void => {
      document.removeEventListener('mousedown', onDoc);
      document.removeEventListener('keydown', onKey, true);
    };
  }, [open]);

  const picked = LOG_KINDS.filter(k => selected.includes(k.kind));
  const active = picked.length > 0;

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        aria-haspopup="true"
        aria-expanded={open}
        title="Show only some kinds of rows (o, x, m, d)"
        onClick={() => {
          setOpen(v => !v);
        }}
        className="flex max-w-[260px] items-center gap-1.5 rounded-[7px] border bg-surface-elevated py-[3px] pl-2.5 pr-2 font-mono text-[11.5px] font-medium text-text-primary transition-colors hover:bg-surface-hover"
        style={{
          borderColor: active
            ? 'color-mix(in oklch, var(--accent-bright), transparent 50%)'
            : 'var(--border)',
        }}
      >
        <span className="text-text-tertiary">Show</span>
        {active ? (
          <span className="flex min-w-0 items-center gap-1.5 truncate">
            {picked.map(k => (
              <span key={k.kind} className="flex items-center gap-1">
                <Dot accent={k.accent} on />
                <span style={{ color: k.accent }}>{k.label}</span>
              </span>
            ))}
          </span>
        ) : (
          <span>Everything</span>
        )}
        <svg
          aria-hidden
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeLinejoin="round"
          className="shrink-0 text-text-tertiary"
        >
          <path d="M6 9l6 6 6-6" />
        </svg>
      </button>
      {open ? (
        <div
          role="menu"
          aria-label="Show only"
          className="absolute right-0 z-30 mt-1 w-[240px] rounded-lg border bg-surface-elevated p-1 shadow-lg"
          style={{ borderColor: 'var(--border-bright)' }}
        >
          <div className="px-2 pt-1 pb-1.5 font-mono text-[10.5px] uppercase tracking-[0.08em] text-text-tertiary">
            Show only
          </div>
          {LOG_KINDS.map(k => {
            const on = selected.includes(k.kind);
            return (
              <button
                key={k.kind}
                type="button"
                role="menuitemcheckbox"
                aria-checked={on}
                title={k.title}
                onClick={() => {
                  onChange(toggleLogKind(selected, k.kind));
                }}
                className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left font-mono text-[12px] transition-colors hover:bg-surface-hover"
              >
                <span
                  aria-hidden
                  className="flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-[4px] border text-[10px] font-bold leading-none"
                  style={{
                    borderColor: on ? k.accent : 'var(--border-bright)',
                    background: on
                      ? `color-mix(in oklch, ${k.accent}, transparent 75%)`
                      : 'transparent',
                    color: k.accent,
                  }}
                >
                  {on ? '✓' : ''}
                </span>
                <Dot accent={k.accent} on={on} />
                <span className="flex-1" style={{ color: on ? k.accent : 'var(--text-secondary)' }}>
                  {k.label}
                </span>
                <span className="tabular-nums text-text-tertiary">{counts[k.kind].toString()}</span>
                <kbd className="ml-1 rounded border border-border px-1 text-[10px] text-text-tertiary">
                  {k.key}
                </kbd>
              </button>
            );
          })}
          <div className="my-1 border-t border-border/60" />
          <button
            type="button"
            role="menuitem"
            disabled={!active}
            onClick={() => {
              onChange([]);
            }}
            className="w-full rounded-md px-2 py-1.5 text-left font-mono text-[12px] text-text-secondary transition-colors hover:bg-surface-hover disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent"
          >
            Show everything
          </button>
        </div>
      ) : null}
    </div>
  );
}
