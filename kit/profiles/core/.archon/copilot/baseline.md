# Copilot CLI baseline (Phase 0, 2026-11-20)

Two real `build-feature-copilot` runs on a small Spring Boot scratch repo (one ticket: one GET endpoint), Copilot CLI
1.0.114, Archon on the Copilot provider. Use it as the "before" for any change to the workflow's nodes, models or
prompts: compare a new run per node, not in total.

- **Run A** (`--no-worktree`): every node up to `pr-text` ran; `open-pr` then refused to push `main` (a run pushes its
  own branch only), so `ci`, `triage`, `ci-fix` and `ready` were skipped. 267 s in total.
- **Run B** (worktree mode, the normal one): ran to `ci`, which was red from the scratch install (both CI jobs failed in
  0 s on incomplete contract wiring; Gradle never ran). `diagnose` and `fix` ran once; `fix` made no commit
  (`CI_FIX_NO_COMMIT`), so the loop stopped and `ready` was skipped. 394 s in total.

## Per node

Wall time is the node's own, from the run log. Tokens: **Copilot** is the sum over the node's model calls in Copilot's
own session log (input counts the cached part again on every call); **Archon** is what Archon recorded for the node.
Turns: model calls in the node.

### Run A

| node | wall s | model | Copilot in / out | Archon in / out | turns |
| --- | ---: | --- | ---: | ---: | ---: |
| explore | 27.9 | claude-haiku-5.5 | 179523 / 4609 | 34579 / 238 | 6 |
| plan | 53.2 | claude-opus-5.5 | 335346 / 4752 | 46311 / 19 | 9 |
| write-tests | 30.5 | claude-sonnet-5.5 | 241396 / 2647 | 37827 / 217 | 7 |
| build-step | 27.3 | claude-sonnet-5.5 | 283678 / 2630 | 38736 / 233 | 8 |
| review | 102.1 | claude-opus-5.5 | 528973 / 7010 | 38767 / 782 | 16 |
| pr-text | 13.2 | claude-sonnet-5.5 | 129097 / 1072 | 27066 / 30 | 5 |

`plan-approval` took 11.5 s (a person's wait); every script node took 0.4 s or less.

Cache read / cache write per node (Copilot session log): explore 160638 / 18871, plan 289015 / 46309, write-tests
203553 / 37825, build-step 260630 / 23028, review 490174 / 38765, pr-text 102021 / 27064. Copilot's `cost` field per
node (its unit is not documented): 6, 135, 7, 8, 240, 5.

### Run B

| node | wall s | model | Copilot in / out | Archon in / out | turns |
| --- | ---: | --- | ---: | ---: | ---: |
| explore | 28.2 | claude-haiku-5.5 | 200989 / 4280 | 39183 / 249 | 6 |
| plan | 31.0 | claude-opus-5.5 | 233695 / 2756 | 43166 / 19 | 6 |
| write-tests | 30.9 | claude-sonnet-5.5 | 263200 / 3008 | 41230 / 252 | 7 |
| build-step | 23.3 | claude-sonnet-5.5 | 295745 / 2189 | 40097 / 174 | 8 |
| review | 70.3 | claude-opus-5.5 | 267050 / 4328 | 38409 / 509 | 8 |
| pr-text | 10.9 | claude-sonnet-5.5 | 101555 / 871 | 26024 / 25 | 4 |
| diagnose | 43.0 | claude-opus-5.5 | 277234 / 3613 | 34513 / 505 | 9 |
| fix | 8.9 | claude-sonnet-5.5 | 49739 / 624 | 25497 / 467 | 2 |

Script nodes: ticket 1.4 s, rebase-main 0.7 s, open-pr 4.7 s, ci 10.1 s, triage 1.6 s, red-head 1.3 s.
`plan-approval` took 126.6 s (a person's wait).

## What the runs showed

- **Models.** The dotted ids in the `-copilot` aliases (`claude-opus-5.5`, ...) are accepted. Archon reports the
  resolved model as "unsupported"; Copilot's responses name `claude-opus-5-5` and the like.
- **Token totals.** Archon's numbers are incomplete: `archon workflow get` gave run B 288119 in / 2200 out, marked
  "completeness unknown", with no cost. The real per-call usage is in Copilot's own session log,
  `${COPILOT_HOME:-~/.copilot}/session-state/<session-id>/events.jsonl` (one session per node).
  `node .archon/scripts/copilot-usage.js <run-id>` sums those records per node, fresh input apart from the cache
  reads and writes, with Copilot's own cost units; a run's `trace.md`, the `copilot.*` records of `run-metrics` and the
  tokenomics ledger carry the same numbers. Over run B it gives the table above: 50 calls, 1689207 in (124 fresh,
  1453466 cache read, 235617 cache write), 21669 out, 372 Copilot cost units.
- **Tool names** seen: `bash`, `create`, `skill`, `view`, `grep`, `glob`, `fetch_copilot_cli_documentation`.
  `.archon/copilot/tools.json` maps them, and the CLI's documented names, to the Claude names.
- **The preToolUse payload is batched.** Copilot CLI 1.0.114 sends `{cwd, sessionId, toolCalls: [{id, name, args}, ...]}`
  (args an object; batches of 1, 2, 4 and 5 calls were seen), not the documented `toolName` / `toolArgs`, and names no
  agent and no node. postToolUse and postToolUseFailure send one call: `toolName`, `toolArgs` (an object),
  `toolCallId`. `.github/hooks/dispatch.sh` splits a batch into one hook run per call and `hooks/run-guard.sh` checks
  every call; before that, the PreToolUse guards found no tool name in a batch, so (from reading the code, not seen as a missed
  deny) they let every call through. The audit
  (postToolUse) worked: 193 records in run B.
- **Not measured yet:** the `ready` node, and CI on real tests (run B's CI failed before Gradle started).
