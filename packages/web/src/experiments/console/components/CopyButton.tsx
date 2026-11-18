import { useEffect, useState, type ReactElement } from 'react';

/** A small text button that copies `text` and says so for a moment. */
export function CopyButton({
  text,
  label = 'Copy',
}: {
  text: string;
  label?: string;
}): ReactElement {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => {
      setCopied(false);
    }, 1500);
    return () => {
      clearTimeout(timer);
    };
  }, [copied]);

  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      onClick={event => {
        event.stopPropagation();
        void navigator.clipboard
          .writeText(text)
          .then(() => {
            setCopied(true);
          })
          .catch(() => {
            /* clipboard refused: nothing to tell */
          });
      }}
      className="rounded px-1.5 py-[1px] font-mono text-[10.5px] text-text-tertiary transition-colors hover:bg-surface-hover hover:text-text-primary"
    >
      {copied ? 'copied ✓' : 'copy'}
    </button>
  );
}
