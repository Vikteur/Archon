# Follow-ups of the Copilot kit

Rewritten 2026-11-20, after the follow-up series of [plan.md] (four lanes merged on `kit/follow-ups`, one pull request
into `local/console`). The first series, its eight pull requests and their owner decisions are in the plan document
(Claude Doc "Copilot kit: plan to improve the build workflow and the CI steps"). This file keeps only what is still
open. Unless a line says "verified", the facts come from the report of the lane that built the item.

## The measured run (step 3 of [plan.md])

Four `build-feature-copilot` runs on the scratch project, 2026-11-20, each driven by a Sonnet subagent with an
isolated Archon. Run 4 is the first to reach `ready`. The baseline is not replaced: its CI went red twice on gaps that
are not the change's, and the two ci-fix rounds make up most of its time and tokens.

- **Run 1, `8c961580…`** (kit `56763529a`) stopped at `tdd-check`: the kit update commit was in its branch range,
  because the real push guard refused the update's push to the scratch project's `main`, as it should (verified).
- **Run 2, `5961dce9…`** (kit `718137727`, the update merged through a scratch pull request) ran every model node in
  about 5.5 min including the plan approval, pushed `feat/health-3` and opened draft PR #3, then failed at `open-pr`:
  `pr-body.sh` wrote `pr-body: wrote …` on stdout before `open-pr.sh`'s JSON, and the node's `output_format` needs one
  JSON document (`failureKind: output_contract`). The line came with `f2fd954b2`, already in `local/console`; it is
  fixed on this branch (below). `ci`, `triage`, `ci-fix` and `ready` did not run.
- **Run 3, `bdccdb95…`** (kit `83690321b`) failed in the build loop after about 8.5 min: `implement` hit its 10
  iterations. The first build agent wrote and committed the right controller without loading its Build skills (run 2's
  did load them), so `step-check` reopened the step; the nine retries never loaded them either (verified: no `skill`
  call in any build-step session, `skills-missing.md` never viewed). The cause is in the kit: the test-side check that
  runs between a build-side miss and the next build agent passed and removed `skills-missing.md`, so no retry could see
  the miss. Fixed below. Iteration 1 per node: explore 33 s, 368k, 9 turns; plan 54 s, 470k, 10; write-tests 32 s,
  423k, 11; build-step 25 s, 311k, 9. The loop's ten rounds took 140 calls and about 5.1M input tokens.
- **Run 4, `28ae4a05…`** (kit `9d15cce5a`) completed in 910 s, plan approval 43 s included: one `implement` round,
  scratch PR #6 marked ready, `local-ci/test success in 6s on Vikteur; 4 tests` on head `1b45432` (verified). CI went
  red twice first; the two ci-fix rounds (diagnose 346 s, fix 132 s) are 478 s and about 3.05M of 5.66M input tokens:
  - the scratch project had no `integrationTest` task, which the default `ci.gradle_line` runs; the fix agent added it.
  - `build-shape-check.sh` (java profile) assumes a multi-module build: it asks for `:application:bootJar`, an
    `application/build.gradle.kts` with the Spring Boot plugin and a `@SpringBootApplication` under
    `application/src/main/java`. A single-module project fails it. **Open.** The fix agent then edited the kit-owned
    `.claude/scripts/build-shape-check.sh` and its test in the run's branch; no fence stops a run from changing a
    kit-owned file. **Open.**
  Per node, run 4 against run B: explore 24.1 s, 187k, 5 [28.2 s, 201k, 6]; plan 59.4 s, 535k, 11 [31.0 s, 234k, 6];
  write-tests 33.1 s, 468k, 12 [30.9 s, 263k, 7]; build-step 24.4 s, 302k, 8 [23.3 s, 296k, 8]; review 122.1 s,
  1.05M, 27 [70.3 s, 267k, 8]; pr-text 8.9 s, 75k, 3 [10.9 s, 102k, 4]. 140 calls, 55,883 output tokens and 1344 cost
  units [50, 21,669, 372]. These numbers are the subagent's, from `copilot-usage.js`; I checked the run status, the PR
  and the CI statuses only.

Per node: wall time, Copilot input tokens, turns. Run 2 against baseline run B of
`kit/profiles/core/.archon/copilot/baseline.md` and run 1:

| Node | Run 2 | Run B | Run 1 |
|---|---|---|---|
| explore (haiku, low) | 32.5 s, 278k, 7 | 28.2 s, 201k, 6 | 33.5 s, 253k, 6 |
| plan (opus, high) | 75.8 s, 510k, 10 | 31.0 s, 234k, 6 | 61.4 s, 590k, 13 |
| write-tests (sonnet, medium) | 42.4 s, 487k, 12 | 30.9 s, 263k, 7 | 57.0 s (2 tries), 15 |
| build-step (sonnet, medium) | 30.3 s, 390k, 10 | 23.3 s, 296k, 8 | 71.5 s (2 tries), 1.02M, 27 |
| review (opus, high) | 116.0 s, 957k, 24 | 70.3 s, 267k, 8 | 177.1 s, 1.59M, 31 |
| pr-text (sonnet, low) | 11.4 s, 126k, 5 | 10.9 s, 102k, 4 | not reached |

Run 2 took 68 calls, about 2.75M input and 29,102 output tokens, and 544 cost units [run B: 50 calls, 1.69M, 21,669,
372]. Against run 1, write-tests and build-step ran once each and build-step fell from 27 turns to 10. Against run B,
plan and review are still heavier: review ran `gradlew test` 7 times for a one-endpoint change.

- **`effort` per node: accepted** (`reasoningEffort` in each node's `session.start`, both runs).
- **Fence denies: 20 in run 1, 14 in run 2.** Run 2 has no `2>&1` deny: `./gradlew test > red/step-1.log 2>&1` was
  allowed. What is still denied: shell `cat`, `ls`, `echo` and `grep` (6, against 12), pipes to `tail` or `head` after
  a build (6), `git --no-pager log` forms (4), a `for` loop, and a `grep` with a list of 3 paths (denied by design).
  The owner allowed the filter and `git --no-pager` (2026-11-20); both are fixed below.
- **Run 3's denies: 37, and 37 `DENY` audit records** (verified: the same count per session in all 22 sessions, each
  with its node). `| tail -15` after affected-check went through 12 times; no agent used `git --no-pager`. The causes:
  - 15 in write-tests: its own retry line asks for `git log … step-base..HEAD`, and test-writer's list has no `git log`.
    **Open, the owner's call:** add `git log` to test-writer's list, or have write-tests read `git diff --stat
    <step-base> HEAD` instead (that needs `workflow-contracts`' retry case, which wants `git log` in every retrying
    node, to accept it for write-tests).
  - 11 `ls`/`cat`/`echo` compounds, despite the prompt line; 6 build-step `./gradlew test | tail` (the developer list
    has `./gradlew :` only; it fell back to affected-check); 4 compounds after `;`; 1 `echo` in plan.
  - 1 explore `grep` with 5 paths, denied by design, but its reason reads "jq failed", like a guard crash.
- **Run 4's denies: 20, and 20 `DENY` records**, each naming its node: plan 1, write-tests 2, build-step 2, review 2,
  diagnose 7, fix 6. `cat`/`ls`/`echo` 10, `git` 4 (1 the write-tests `git log` above), `./gradlew test` 2 (build-step
  and fix), and 2 `grep` calls with a 3-path list, whose reason still reads "jq failed". `| tail -<n>` and `| head -<n>`
  went through 11 times, and `git --no-pager log`/`diff` were allowed (diagnose, pr-text). Copilot also sent
  `read_bash` (2 calls), which `tools.json` does not map. **Open.**
- **Run 4 also showed:** a `local-ci/<job>` pending status reads `queued #260 pos 1` on a scratch PR (#260 is not a PR
  of that repo; not looked into), and one `archon-scripts` red on `340419d` (`ci-local.test.sh`: the Archon git env does
  not reach the job), green on the commits before and after it. `kit doctor` in the run's worktree reports the
  workflow file as modified, though it is byte-identical to `main`'s, where doctor reports no drift. All three:
  **open, cause unknown.**
- **The audit records held no denies in runs 1 and 2.** The `.apm-audit` records come from postToolUse, which a denied
  call never reaches. They name the node (`"node":"<node>"`). A deny named the node only in its message, and only
  Copilot's own session log (`events.jsonl`) kept it. The guard now writes the deny record itself (below).
- **The push through `.githooks/pre-push`: partly.** `core.hooksPath` is `.githooks`, and the worktree's `pre-push`
  calls the real `push-guard.sh`; run 1 saw it refuse `main`, and run 2's branch push went through. That the hook ran
  on the branch push is inferred, not seen.
- **`mcp-use`:** explore `mcp: 1` (Copilot's `codegraph-codegraph_explore`, now counted); plan `mcp: 0, cli: 0` with a
  genuine warning (5 hand searches, no CodeGraph).
- **Tool names Copilot sent:** `bash`, `view`, `glob`, `grep`, `edit`, `create`, `skill`, and MCP tools as
  `<server>-<tool>`. Not compared with `tools.json` entry by entry.
- **Not verified:** the `## Misses of the last round` path in a real run (run 4 had no miss), that run 4's pushes went
  through the guard (a passing guard is silent; a dry-run probe was not permitted), the `<(`/`>(` deny and the list-of-one `grep` in a real run (only in the suites), and a second workflow with
  `fileHooks` (the kit has none).
- **Fixed on this branch from what the runs found:**
  - `pr-body.sh` writes its note to stderr; `pr-body.test.sh` case 2b checks stdout stays empty (fails on the old
    script).
  - The scope guard split a command at the `&` of a `2>&1` redirect and denied a "command" named `1` (6 denies in
    run 1; the write-tests prompt asks for the full output in `red/step-<n>.log`). The `&` of an unescaped `>&` or
    `<&` now stays in its segment; a real `&` after it still splits, and so does one behind an escaped `\>`. The old
    guard also let `<(…)` and `>(…)` through, a process substitution that hides a command as `$(` does: it is now
    denied. `node-fence.test.sh` has 10 new cases; 8 of them fail on the old guard.
  - The six prompts that name a run file (explore, plan, write-tests, build-step, review and ci-fix's fix) say to read
    files with `view`, `glob` and `grep`, never `cat`, `ls` or `echo`. No list is widened for those reads (owner,
    2026-11-20).
  - `tail` or `head` with count options only is allowed right after a single `|` or `|&` (owner, 2026-11-20): not
    alone, not after `||` or `;`, not with a file operand, `-f` or a redirect, and what follows is still checked.
  - `git --no-pager <cmd>` is read as `git <cmd>`, against the same lists (owner, 2026-11-20): `test-writer` still
    may not run `git log`.
  - A deny writes a `DENY` record to `.apm-audit/sessions/<session>.jsonl` (owner, 2026-11-20): the `TOOL` record's
    fields (the arg cut to 200 bytes a line), the node and the reason. Only when that folder exists (the guard makes
    none), and a failed write never changes the decision. `node-fence.test.sh` has 19 more cases (127); the old guard
    denies the three new allow cases and writes no record.
  - A check that passes removes only a miss note of its own side (`skills-missing.md`, `scaffold-missing.md`), and
    `step-cut.js` copies the notes into `step.md` under `## Misses of the last round`, which every loop agent reads
    (run 3). 10 new cases in `step-cut`, `skill-check` and `step-check`; 8 of them fail on the old scripts.
  - A `grep` whose `paths` is a list of one string counts as that path, in `payload.sh` and in `claudeCall`
    (`copilot-audit.js`, also read by `run-trace.js` and `mcp-use-check.js`); a longer list is still denied.
  - `mcp-use-check` counts Copilot's MCP names (`<server>-`, `codegraph-`), not only `mcp__<server>__`.
  - `kit add` gives an unchanged executable its mode back (`.githooks/commit-msg` stayed 0644 after an update).
- **Still to do:** a complete run through `ci` to `ready`, once this fix is on the scratch project's `main`.

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
