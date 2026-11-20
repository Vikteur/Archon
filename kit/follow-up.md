# Follow-ups of the Copilot kit

Rewritten 2026-11-20, after the follow-up series of [plan.md] (four lanes merged on `kit/follow-ups`, one pull request
into `local/console`). The first series, its eight pull requests and their owner decisions are in the plan document
(Claude Doc "Copilot kit: plan to improve the build workflow and the CI steps"). This file keeps only what is still
open. Unless a line says "verified", the facts come from the report of the lane that built the item.

## Waiting for the measured run

These are checked by the one `build-feature-copilot` run of step 3 of [plan.md], on the scratch project, compared
with `kit/profiles/core/.archon/copilot/baseline.md`. Until its result is written here, they are open:

- **`effort` per node** is set, but it is not verified that Copilot accepts it.
- **The fences with `fileHooks` on,** and a second workflow with `fileHooks` on getting the same rules.
- **Push guard, end to end:** one push with the real `push-guard.sh` and `core.hooksPath=.githooks`.
- **The evidence of a real run:** the trace, the usage per node, and hook records that name the node.
- **Tool names in any case:** the guards now match `monitor` like `Monitor`. Which names Copilot really sends is not
  verified.

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
