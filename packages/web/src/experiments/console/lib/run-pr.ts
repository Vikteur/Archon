import { useEffect, useState } from 'react';
import { requestJson } from './http';
import type { Run } from '../primitives/run';

/** A pull request a run opened: its GitHub URL and number. */
export interface RunPr {
  url: string;
  number: number;
}

const PULL_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/(\d+)$/;

/** The pull request in a URL, or null when it is not a GitHub pull request link. */
export function toRunPr(url: unknown): RunPr | null {
  if (typeof url !== 'string') return null;
  const m = PULL_URL.exec(url.trim());
  return m?.[1] !== undefined ? { url: url.trim(), number: Number(m[1]) } : null;
}

interface RawEvent {
  event_type?: string;
  data?: { structured_output?: unknown; node_output?: unknown } | null;
}

function prField(output: unknown): unknown {
  if (typeof output === 'string') {
    try {
      return prField(JSON.parse(output) as unknown);
    } catch {
      return undefined;
    }
  }
  return output !== null && typeof output === 'object'
    ? (output as { pr?: unknown }).pr
    : undefined;
}

/**
 * The pull request a run opened: the last completed node whose output has a
 * `pr` field holding a GitHub pull request URL (a build-feature run's `open-pr`).
 */
export function prFromEvents(events: readonly RawEvent[]): RunPr | null {
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    if (e?.event_type !== 'node_completed' || e.data == null) continue;
    const pr = toRunPr(prField(e.data.structured_output)) ?? toRunPr(prField(e.data.node_output));
    if (pr !== null) return pr;
  }
  return null;
}

const STORE_KEY = 'console.run-prs.v1';
const FINISHED = new Set(['completed', 'failed', 'cancelled']);
// A finished run's pull request never changes: remembered across reloads. A live one is asked again.
const known = new Map<string, RunPr | null>(readStore());
const inFlight = new Map<string, Promise<RunPr | null>>();

function readStore(): [string, RunPr | null][] {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    const parsed = raw !== null ? (JSON.parse(raw) as Record<string, string | null>) : {};
    return Object.entries(parsed).map(([id, url]) => [id, url === null ? null : toRunPr(url)]);
  } catch {
    return [];
  }
}

function remember(id: string, pr: RunPr | null): void {
  known.set(id, pr);
  try {
    const raw = localStorage.getItem(STORE_KEY);
    const all = raw !== null ? (JSON.parse(raw) as Record<string, string | null>) : {};
    all[id] = pr?.url ?? null;
    localStorage.setItem(STORE_KEY, JSON.stringify(all));
  } catch {
    // No storage: the lookup is repeated next load.
  }
}

async function lookUp(run: Pick<Run, 'id' | 'status'>): Promise<RunPr | null> {
  const res = await requestJson<{ events?: RawEvent[] }>(
    `/api/workflows/runs/${encodeURIComponent(run.id)}`
  );
  const pr = prFromEvents(res.events ?? []);
  if (FINISHED.has(run.status)) remember(run.id, pr);
  return pr;
}

/** One run's pull request, asked once at a time per run. */
export function runPr(run: Pick<Run, 'id' | 'status'>): Promise<RunPr | null> {
  if (known.has(run.id)) return Promise.resolve(known.get(run.id) ?? null);
  const pending = inFlight.get(run.id);
  if (pending !== undefined) return pending;
  const p = lookUp(run)
    .catch(() => null)
    .finally(() => inFlight.delete(run.id));
  inFlight.set(run.id, p);
  return p;
}

const PARALLEL = 3;

/** The pull requests of the runs shown, filled in as the lookups return, a few at a time. */
export function useRunPrs(runs: readonly Pick<Run, 'id' | 'status'>[]): Map<string, RunPr> {
  const [prs, setPrs] = useState<Map<string, RunPr>>(() => new Map());
  const key = runs.map(r => `${r.id}:${r.status}`).join(',');
  useEffect(() => {
    let live = true;
    const queue = [...runs];
    const worker = async (): Promise<void> => {
      for (let run = queue.shift(); run !== undefined && live; run = queue.shift()) {
        const pr = await runPr(run);
        if (live && pr !== null) {
          setPrs(m => (m.get(run.id)?.url === pr.url ? m : new Map(m).set(run.id, pr)));
        }
      }
    };
    void Promise.all(Array.from({ length: PARALLEL }, worker));
    return () => {
      live = false;
    };
    // `key` stands for `runs`, so a new array of the same runs asks nothing again.
  }, [key]);
  return prs;
}
