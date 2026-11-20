#!/usr/bin/env node
// Records this project's past Archon runs as metric records, so the console's Metrics tab has data.
// Usage: node .archon/scripts/run-metrics.js   (the `record` node of the `run-metrics` workflow)
//
// Prints one JSON document, `{ metrics, skipped }`, on stdout; the engine stores `metrics` as the node's records and
// aggregates them by name, window and subject (see the Archon metrics guide). Nothing is written anywhere else.
//
//   sdlc.prs_opened / sdlc.prs_merged / sdlc.prs_abandoned (count, prs) and sdlc.pr_merge_rate (score, ratio):
//       one set per pull request a build-feature run opened, with the same meaning as the SDLC pack's
//       archon-metrics-prs, so the pack's PR cards read them. `runs` names the runs that worked on the pull request.
//   runs.started (count, runs) and runs.spend_usd (count, usd): one record each per run, at its start, with the run's
//       recorded cost as the spend (0 when it recorded none, counted by the engine as a run without cost).
//
// Which runs worked on a pull request: the build-feature run whose `open-pr` node returned it; a build-feature run
// that opened none (failed or cancelled first) goes to the next pull request opened for the same ticket, else that
// ticket's latest one; a review run goes to the pull request number its message names. A run tied to no pull request
// counts only in runs.*. Every subject is a PR URL or a run id, so a re-run replaces its earlier records.
//
// Exit codes: 0 records printed; 1 the archon or gh CLI failed, or the run listing came back incomplete.
'use strict';
const { execFileSync } = require('child_process');

/** The engine accepts at most this many run ids on one record. */
const MAX_RUNS = 20;
/** This workflow's own runs are bookkeeping, not project work. */
const SELF = 'run-metrics';
const LIST_LIMIT = 100000;

const fail = (msg) => { console.error(`run-metrics: ${msg}`); process.exit(1); };
const note = (msg) => console.error(`run-metrics: ${msg}`);

function json(cmd, args) {
  let out;
  try {
    out = execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    fail(`${cmd} ${args.join(' ')} failed: ${(e.stderr || e.message || '').toString().trim()}`);
  }
  try { return JSON.parse(out); } catch (e) { fail(`${cmd} ${args.join(' ')} printed no JSON: ${e.message}`); }
}

const ticketOf = (run) => ((run.user_message || '').match(/\bTASK-\d+(?:\.\d+)*\b/) || [null])[0];
const prNumberOf = (run) => {
  const m = (run.user_message || '').match(/\/pull\/(\d+)|\bPR #(\d+)|\bpull request #(\d+)|#(\d+)/i);
  return m ? Number(m[1] || m[2] || m[3] || m[4]) : null;
};
// The build workflow the project runs: build_workflow of .archon/kit.yaml (env BUILD_WORKFLOW), else the kit's default.
const BUILD = require('./kit-config.js').kitGet('build_workflow', 'build-feature-copilot', 'BUILD_WORKFLOW');
const isBuild = (run) => run.workflow_name === BUILD;
const isReview = (run) => /pr-review/.test(run.workflow_name);
const cost = (run) => (typeof run.metadata?.total_cost_usd === 'number' ? run.metadata.total_cost_usd : null);

/** The PR URL a run's `open-pr` node returned, or null. */
function openedPr(detail) {
  const node = (detail.nodes || []).find((n) => n.nodeId === 'open-pr' && n.state === 'completed');
  if (!node || !node.outputPreview) return null;
  try { return JSON.parse(node.outputPreview).pr || null; } catch { return null; }
}

/** PR URL -> the ids of the runs that worked on it, oldest run first. Pure: `opened` maps run id -> PR URL. */
function attribute(runs, opened) {
  const byStart = [...runs].sort((a, b) => a.started_at.localeCompare(b.started_at));
  const prRuns = new Map();
  const add = (url, id) => {
    const ids = prRuns.get(url) || [];
    if (!ids.includes(id)) ids.push(id);
    prRuns.set(url, ids);
  };
  // Per ticket, the PRs its build runs opened, with when the opening run started.
  const ticketPrs = new Map();
  for (const run of byStart) {
    const url = opened.get(run.id);
    if (!url) continue;
    add(url, run.id);
    const t = ticketOf(run);
    if (t) ticketPrs.set(t, [...(ticketPrs.get(t) || []), { url, start: run.started_at }]);
  }
  const unattributed = [];
  for (const run of byStart) {
    if (opened.has(run.id)) continue;
    let url = null;
    if (isBuild(run)) {
      const prs = ticketPrs.get(ticketOf(run)) || [];
      url = (prs.find((p) => p.start >= run.started_at) || prs[prs.length - 1] || {}).url || null;
    } else if (isReview(run)) {
      const n = prNumberOf(run);
      url = n === null ? null : [...prRuns.keys()].find((u) => u.endsWith(`/pull/${n}`)) || null;
    }
    if (url) add(url, run.id); else unattributed.push(run.id);
  }
  const order = new Map(byStart.map((run, i) => [run.id, i]));
  for (const ids of prRuns.values()) ids.sort((x, y) => order.get(x) - order.get(y));
  return { prRuns, unattributed };
}

const prCount = (name, value, at) => ({ name, kind: 'count', unit: 'prs', value, at });

/** The SDLC pack's PR outcomes: opened, merged, abandoned (1 or 0) and the merge rate once resolved. */
function prOutcomes(pr) {
  const opened = prCount('sdlc.prs_opened', 1, pr.createdAt);
  if (pr.state === 'OPEN') return [opened, prCount('sdlc.prs_abandoned', 0, pr.createdAt)];
  const merged = pr.state === 'MERGED';
  const resolved = merged ? pr.mergedAt : pr.closedAt;
  if (!resolved) fail(`gh reported ${pr.url} ${pr.state.toLowerCase()} without a time`);
  const rate = { name: 'sdlc.pr_merge_rate', kind: 'score', unit: 'ratio', value: merged ? 1 : 0, at: resolved };
  return merged
    ? [opened, prCount('sdlc.prs_merged', 1, resolved), prCount('sdlc.prs_abandoned', 0, resolved), rate]
    : [opened, prCount('sdlc.prs_abandoned', 1, resolved), rate];
}

/** Pure: every record, given the runs, run id -> opened PR URL, and the PRs gh reports. */
function records(runs, opened, prs) {
  const { prRuns, unattributed } = attribute(runs, opened);
  const prByUrl = new Map(prs.map((pr) => [pr.url, pr]));
  const metrics = [];
  const skipped = [];
  for (const [url, ids] of prRuns) {
    const pr = prByUrl.get(url);
    if (!pr) { skipped.push({ subject: url, reason: 'gh does not list this pull request' }); continue; }
    // The newest runs did the latest work; keep them when a PR had more runs than one record may name.
    const named = ids.slice(-MAX_RUNS);
    for (const outcome of prOutcomes(pr)) metrics.push({ ...outcome, subject: url, runs: named });
  }
  for (const run of runs) {
    const at = new Date(run.started_at).toISOString();
    const base = { kind: 'count', subject: run.id, at, runs: [run.id] };
    metrics.push({ ...base, name: 'runs.started', unit: 'runs', value: 1 });
    metrics.push({ ...base, name: 'runs.spend_usd', unit: 'usd', value: cost(run) ?? 0 });
  }
  return { metrics, skipped, unattributed };
}

function main() {
  const listing = json('archon', ['workflow', 'runs', '--json', '--limit', String(LIST_LIMIT)]);
  const runs = (listing.runs || []).filter((r) => r.workflow_name !== SELF);
  if (typeof listing.total === 'number' && listing.runs.length < listing.total) {
    fail(`archon listed ${listing.runs.length} of ${listing.total} runs`);
  }
  const opened = new Map();
  for (const run of runs.filter(isBuild)) {
    const url = openedPr(json('archon', ['workflow', 'get', run.id, '--json', '--verbose']));
    if (url) opened.set(run.id, url);
  }
  const prs = json('gh', ['pr', 'list', '--state', 'all', '--limit', String(LIST_LIMIT),
    '--json', 'url,state,createdAt,mergedAt,closedAt']);
  const { metrics, skipped, unattributed } = records(runs, opened, prs);
  note(`${runs.length} runs, ${opened.size} opened a PR, ${unattributed.length} tied to no PR, ${metrics.length} records`);
  process.stdout.write(`${JSON.stringify({ metrics, skipped })}\n`);
}

if (require.main === module) main();
module.exports = { attribute, records, prOutcomes, ticketOf, prNumberOf };
