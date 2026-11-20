# Follow-ups of the Copilot kit

Rewritten 2026-11-20, after the follow-up series of [plan.md] (four lanes merged on `kit/follow-ups`, one pull request
into `local/console`). The first series, its eight pull requests and their owner decisions are in the plan document
(Claude Doc "Copilot kit: plan to improve the build workflow and the CI steps"). This file keeps only what is still
open. Unless a line says "verified", the facts come from the report of the lane that built the item.

## The measured run (step 3 of [plan.md])

One `build-feature-copilot` run on the scratch project, 2026-11-20, Sonnet subagent, isolated Archon built at
`56763529a`. Run `8c961580…` (`--from main`) stopped at `tdd-check`. The kit update commit was in its branch range,
because the update could not reach the scratch project's `origin/main`: the real push guard refused that push, as
it should (verified). An earlier try (`aeaac6ad…`) stopped at `ticket`, because its worktree was cut from the old
`origin/main` without `kit-gitignore.sh`. So no run reached `open-pr`, and the numbers below are for
explore → review only, against run B of `kit/profiles/core/.archon/copilot/baseline.md` (in brackets):

| Node | Wall | Input tokens | Turns |
|---|---|---|---|
| explore | 33.5 s [28.2] | 252,554 [200,989] | 6 [6] |
| plan | 61.4 s [31.0] | 589,705 | 13 [6] |
| write-tests (2 tries) | 57.0 s [30.9] | | 15 [7] |
| build-step (2 tries) | 71.5 s [23.3] | 1,017,235 | 27 [8] |
| review | 177.1 s [70.3] | 1,588,768 | 31 [8] |

The run took 92 calls, 4,006,844 input and 36,885 output tokens, and 708 cost units [50 calls, 1,689,207, 21,669,
372]. The baseline is not replaced: this run is not complete.

- **`effort` per node: accepted.** `session.start` shows reasoningEffort low, high and medium per node (verified in
  the run's logs by the subagent).
- **Hook records name the node** (`"node":"explore"`, …). The trace and the usage per node were written.
- **The fences hold:** 20 denies, each naming the node. Of the 18 command denies, 12 were shell reads of the run's
  own files (`cat`, `ls`, `echo` in one line) that `view`, `glob` and `grep` cover, 6 were the `2>&1` bug below, and
  the rest were pipes to `tail` or `head` and a `git log` form outside the test writer's list. This friction is the
  likely cause of the extra turns in plan, build-step and review. The lists are not widened (owner, 2026-11-20):
  the prompts that name a run file now say to read files with `view`, `glob` and `grep`, never `cat`, `ls` or `echo`.
  **Open, the owner's call:** a read-only filter (`tail`, `head`) after a pipe.
- **Push guard, end to end: partly.** The real `push-guard.sh` refused the push to the scratch project's main.
  `open-pr` was not reached, so a branch push through the hook is not verified.
- **Not verified:** the `; <n> tests` local-ci status and CI running Gradle (no run reached CI), and a second
  workflow with `fileHooks` (the kit has none: `run-metrics` is a script node only).
- **Tool names Copilot sent:** `bash`, `view`, `glob`, `grep`, `edit`, `create`, `skill`, and MCP tools as
  `<server>-<tool>` (`codegraph-codegraph_explore`, `_node`, `_callers`, `_impact`).
- **Fixed on this branch from what the run found:**
  - A `grep` whose `paths` is a list was denied, because the scope guard could not read it (jq failed). Now a list
    of one string counts as that path, in `payload.sh` and in `claudeCall` (`copilot-audit.js`, also read by
    `run-trace.js` and `mcp-use-check.js`). A longer list is still denied. `node-fence.test.sh` replays the call:
    the old `payload.sh` denies it, the new one allows it.
  - `mcp-use-check` counted only `mcp__<server>__` names, so it reported `mcp: 0` for a node that did call CodeGraph
    (a false warning on plan). It now also counts `<server>-` and `codegraph-`.
  - The scope guard split a command at the `&` of a `2>&1` redirect and denied a "command" named `1` (6 denies;
    the write-tests prompt itself asks for the full output in `red/step-<n>.log`). The `&` of an unescaped `>&` or
    `<&` now stays in its segment; a real `&` after it still splits, and so does one behind an escaped `\>`. The old
    guard also let `<(…)` and `>(…)` through, a process substitution that hides a command as `$(` does: it is now
    denied. `node-fence.test.sh` has 10 new cases; 8 of them fail on the old guard.
  - `.githooks/commit-msg` stayed 0644 after `kit add`: an older kit shipped it 0644, and `kit add` left the mode of
    a file whose content was unchanged. It now gives such an executable its mode back, and counts it as written.
- **Still to do:** a complete run to `open-pr`. The kit update has to reach the scratch project's `origin/main`
  first, through a pull request there or a push the owner allows.

## Fences and guards

- **A hook that runs past its timeout lets the call through.** Documented, not solved (owner decision 8 of the plan).
- **`.archon/workflows` is not fenced.** A node could edit a workflow file in its worktree. The run reads its
  workflow from its snapshot, so the run in progress does not change, but the edit could reach the pull request.
- **Cases the fences do not catch:** a path built so the command text never names it, a script the agent writes and
  then runs, and `git stash`, `git reset` or `git clean` in its worktree.
- **Retried nodes:** the prompts of `write-tests`, `build-step`, `review` and `fix` now say what to do on top of
  their own commits from a failed try. Nothing deterministic stops a second test or fix commit yet.
- **Left in on purpose:** `Bash(*backlog task*)` in the `denied_tools` of the CI-fix nodes (dropping it would loosen
  more than owner decision 1), the `Bash(...)` patterns in the workflow's `denied_tools` (the guard reads them there),
  the Claude-only env vars in `config.yaml`, the `worktree-consumer.sh` and `closeout` allowlist entries, and the
  session-id join of `copilot-usage.js`, which still serves hook records written before they named the node.

## CI and profiles

- **The `local-ci/<job>` status changed form** (`; <n> tests` before the fingerprint). `gate-change-check` treats a
  change to `ci_status_parse` as a change to the `local-ci-status` gate, so a project that takes this kit update
  needs a dated `docs/memory.md` entry for it.
- **`install-tools.sh` reads the `profiles` list as written.** It does not follow what each profile requires: a
  `kit.yaml` that lists only `mijn-gezondheid` leaves out spectral, although that profile needs `openapi-contract`.
  `archon kit add` writes the full list, so only a hand-written list hits this.
- **gitleaks is pinned exactly on Linux only.** winget and Homebrew install their own 8.x, checked against the major
  version, as for jq and yq.
- **Quarkus is gone as a profile, but still named** in the worked-example code-map leaves and exemplars of `core` and
  `java`, two scaffold templates (`controller.mustache`, `flyway-migration.mustache`) and the data of
  `affected-check.test.sh`.
- **Existing installs keep a `stack:` key** that nothing reads any more. Harmless.
- **No sync check for a `java-spring` file without an overlay twin.**
- **`workflow-contracts` case W1 on a core-only install** fails on `scripts/scaffold.sh`, which ships with `java`. It
  passes on the three renders (none is core-only). This was there before this series.
- **Left out on purpose** (decisions of the plan): a unit/integration job split, an in-repo contract path,
  `--configuration-cache` in CI, an upload of the archon-scripts suite log, Spotless and JaCoCo in a build, making
  `tests-ran` a finding per module, and switching a gate to `block` (a project's step after its week in report
  mode).

## Workflow

- **`kit-sync-standalone-text.ts`** does not map the new skill-list markers; flagged only, since the kit is no
  longer synced from another repo.

## Test time

- **`scripts/kit-render-test.sh`** renders the three installs at the same time (`--serial` one after another).
  Serial against parallel is not measured on one machine.
- **The ci-local split** (`ci-local.test.sh`, `ci-local-queue.test.sh`, `ci-local-watch.test.sh`, about 29 s each)
  was timed in the parallel render, not alone.

## Left out, with the reason

- **Plan-approval reminder:** a change in Archon's core, not in the kit.
- **Dependency review:** no tool fits without a key or a token; left out until an NVD key exists.
- **Not counting a missed round, cutting account names from the trace, hiding more of the secret scan:** the owner
  chose to keep these as they are.

[plan.md]: plan.md
