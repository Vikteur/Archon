# Plan for the follow-ups of the Copilot kit improvement series

Written 2026-11-20. It plans every item of [follow-up.md], on top of `local/console` at `b12c17030` (all eight pull
requests merged, the installed `archon` updated to that commit). Nothing in it is built yet.

## The shape

- **One integration branch, `kit/follow-ups`, and one pull request.** Four builders work at the same time, each on
  its own branch and worktree, on files no other builder touches.
- **The generated files are made once.** `kit/manifest.json` and `packages/cli/src/bundled-kit.ts` conflicted in
  almost every merge of the first series. Builders regenerate them to test, but the integrator throws their copies
  away and regenerates once after the four merges.
- **Full renders run once, at integration.** A render with local CI on takes about 100 s, and the first series ran
  one or more per pull request. Here a builder runs only the suites of the files it changed.
- **One measured `build-feature-copilot` run at the end**, on the scratch project, instead of one per pull request.
  The cost: if that run is worse than the baseline, it does not say which lane caused it.

## Step 0: owner decisions (answered in chat, 2026-11-20)

| # | Decision | Owner's answer | Lane |
|---|---|---|---|
| 1 | With `backlog: false`, does `run-guard.sh` still deny `backlog task` commands? | No: the rule applies only with `backlog: true` | B |
| 2 | `## Decisions` is written twice in the pull request body. | Keep only the one of `pr-refresh.sh` | C |
| 3 | Does a missed round count toward the fix loop's limit of 10? | Yes, as today. No change | none |
| 4 | Plan-approval reminder: needs a change in Archon's core. | Left out | none |
| 5 | The trace copies a script's stderr line; an account name in plain text is not cut. | Accepted as it is | none |
| 6 | The secret scan prints file, line and rule in the CI log, never the text. | Accepted as it is | none |
| 7 | Dependency review: which tool. | Left out until an NVD key exists | none |
| 8 | A hook that runs past its timeout lets the call through. | Stays documented only. No change | none |
| 9 | Delete the eight merged branches and the worktrees under `~/kit-prs`. | Yes; the worktree `merged` stays | integrator |

Decision 6 of [follow-up.md] (update the installed `archon`) is done.

## Step 1: four builders at the same time

Each builder is an Opus subagent with its own worktree off `kit/follow-ups`. A lane owns its files: a builder that
needs a file of another lane reports it instead of editing it.

### Lane A: CI and profiles (Opus)

Owns the `ci.yml` files, `ci-inputs.yml`, the java profile's CI scripts, `install-tools.sh`,
`scripts/kit-sync-deps.ts`, `scripts/kit-sync-lists.ts`.

1. `openapi-contract` ships no `ci.yml`. `java-spring` owns the one file, with its contract steps on lines marked
   `@@KIT_IF_PROFILE_OPENAPI-CONTRACT@@`. Remove the `core,openapi-contract` known gap.
2. Remove Quarkus: the profile, the sync classification, the `stack: quarkus` branches in the gate scripts, the
   pin-proof test data and the docs pages. After item 1, because both change the sync scripts.
3. `workflow-contracts` case W1: it passed on the last render without the contract profile. Confirm, then drop the
   item or fix the case.
4. `build-shape-check.sh` reads its tasks from `ci.gradle_line`.
5. `ci-local.sh` shows the test count in its `local-ci/<job>` status.
6. `install-tools.sh` fetches `gitleaks` and `spectral`, so those two gates stop printing "not set up".

Not in this lane: switching a gate to `block`, making `tests-ran` a finding per module, Spotless and JaCoCo in a
build, the unit/integration job split. Those are a project's own steps, or would turn existing installs red.

### Lane B: fences and hooks (Opus)

Owns `run-guard.sh`, `scope-guard.sh`, `node-fences.json`, the hook scripts and their suites.

1. No node may edit the hook folders (`.github/hooks`, `.archon/copilot/hooks`, `.claude/hooks`).
2. Tool names match without regard to case.
3. `run-guard.sh` denies `backlog task` commands only with `backlog: true` (decision 1).
4. Hook records name the node from `KIT_NODE` instead of `"main"`.

Every change here tightens a guard, except item 3. A builder never loosens one beyond that answer.

### Lane C: the workflow (Opus)

Owns `build-feature-copilot.yaml`, `pr-body.sh`, `pr-refresh.sh`, `mcp-use-check.sh` and their suites.

1. Remove the unused `pr_note` output of the `ticket` node.
2. Only `pr-refresh.sh` writes `## Decisions`; `pr-body.sh` no longer does (decision 2).
3. `mcp-use` counts the CLI calls too, now that the prompts put the CLI first.
4. The skill lists of `write-tests` and `build-step` follow the installed profiles.
5. Read each agent node for what a retry does on top of its own commits; fix what is not safe to repeat.

### Lane D: test speed and evidence (Sonnet)

Owns `ci-local.test.sh`, `run-suites.sh`, the trace and tokenomics scripts, `kit/follow-up.md`.

1. Split `ci-local.test.sh` into two or three suites. It takes 89 s of a 100 s render, so the render time drops to
   about the longest part.
2. A script that renders the three installs and runs their suites in parallel, with isolated homes. Today every
   agent rebuilds that by hand.
3. The tokenomics loader against a copy of a real Archon database with Copilot runs (the scratch Archon home has
   the two measured runs). Read only.
4. Rewrite [follow-up.md] at the end: drop what is done, keep what this plan leaves out.

### What a builder may run

- The suites of the files it changed, one by one. Most take under 10 s.
- `bun run check:kit`, `bun run check:bundled-kit` and the kit bun tests.
- At most one render with local CI off (23 s) before it reports.
- No render with local CI on, except lane A and lane D once each, because they change what only that render tests.
- No `build-feature-copilot` run.

## Step 2: integration (the main session, no subagent)

1. Merge the four lane branches into `kit/follow-ups`. Rehash the manifest and run `bun run kit:bundle` once.
2. Run the three renders once, with lane D's script: default with local CI on, default with local CI off, and
   core + java + java-spring. A suite that is red in the parallel run is re-run alone before it counts.
3. On red, the lane that owns the file fixes it, and only the red suites are re-run. The three renders run a second
   time only before the merge, and only if a fix changed more than one suite's files.
4. Open the pull request into `local/console`.

During step 1 the main session also updates the plan document (the Claude Doc) with the results of the first
series, and fast-forwards `~/archon-src`.

## Step 3: one measured run (one Sonnet subagent)

One `build-feature-copilot` run on the scratch project, from the integration branch, compared with
`kit/profiles/core/.archon/copilot/baseline.md`. It covers the items that only a real run can show:

- `effort` per node is accepted by Copilot;
- the fences hold with `fileHooks` on, and a second workflow with `fileHooks` on gets the same rules;
- one push with the real `push-guard.sh` and `core.hooksPath=.githooks`;
- the trace, the usage per node and the hook records of that run.

Merge after this run, then install `archon` from the merged branch and restart `archon serve`.

## Count

| Step | Agents | At the same time | Full renders | Measured runs |
|---|---|---|---|---|
| 0 | none (owner in chat) | | 0 | 0 |
| 1 | 3 Opus, 1 Sonnet | 4 | 0 (2 single renders with local CI on) | 0 |
| 2 | none (main session) | | 1 set of 3 | 0 |
| 3 | 1 Sonnet | 1 | 0 | 1 |

The first series used eight builders and two merge agents, and ran one or more sets of renders per pull request.

## Left out, with the reason

- **Plan-approval reminder:** a change in Archon's core, not in the kit (decision 4).
- **Dependency review:** no tool fits without a key or a token (decision 7).
- **Hook timeout in the trace, cutting account names from the trace, hiding more of the secret scan, not counting
  a missed round:** the owner chose to leave these as they are (decisions 8, 5, 6, 3).
- **Unit/integration job split, an in-repo contract path, `--configuration-cache` in CI, upload of the
  archon-scripts suite log:** left out of #20 on purpose; nothing changed since.
- **Switching a gate to `block`:** a project's step after its week in report mode.

[follow-up.md]: follow-up.md
