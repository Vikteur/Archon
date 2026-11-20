# Follow-ups of the Copilot kit improvement series

Written 2026-11-20, after the eight pull requests of the plan "Copilot kit: improve the build workflow and the CI
steps" were opened as drafts. This file lists what those pull requests left open. Each item names the pull request
it comes from. Unless a line says "verified", the facts come from the report of the agent that built that pull
request and were not checked again.

## The pull requests

| Plan PR | Draft | Branch | Base | What it does |
|---|---|---|---|---|
| 1 | #19 | `kit/pr1-runs-survive` | `local/console` | Retries, timeouts, a bounded fix loop, the `blocked` node |
| 2 | #16 | `kit/pr2-tickets-without-backlog` | `local/console` | Tickets from pasted text, `backlog` key |
| 3 | #18 | `kit/pr3-prompts-cli-first` | `local/console` | CLI-first prompts, the `@@KIT_IF_PROFILE_<NAME>@@` marker |
| 4 | #17 | `kit/pr4-baseline-tools-json` | `local/console` | Hooks read Copilot's real payload, `tools.json`, `.githooks/pre-push` |
| 5 | #22 | `kit/pr5-fences` | #17 | Fences and `denied_tools` per node |
| 6 | #20 | `kit/pr6-ci-steps` | `local/console` | CI without the contract profile, local CI on a team machine |
| 7 | this one | `kit/pr7-gates-ci-tests` | #20 | New report-only gates, tests for the CI scripts |
| 8 | #21 | `kit/pr8-evidence-per-run` | #17 | Copilot usage per node, warnings in the trace |

## Merging

- **Order.** #17 first, then #22 and #21 (retarget both to `local/console`). #20 before this pull request (retarget
  it too). #19, #16 and #18 in any order.
- **Conflicts to expect.** #19, #16, #18, #20, #21 and #22 all change
  `kit/profiles/core/.archon/workflows/build-feature-copilot.yaml`, `kit/manifest.json` and
  `packages/cli/src/bundled-kit.ts`. After each rebase: rehash the manifest, run `bun run kit:bundle`, then
  `bun run check:kit` and `bun run check:bundled-kit`. Never merge the two generated files by hand.
- **No verification run yet.** No pull request was proven by a full `build-feature-copilot` run. Run one per pull
  request, one at a time, on the scratch project, and compare with `kit/profiles/core/.archon/copilot/baseline.md`.
- **Push guard, end to end.** `.githooks/pre-push` (#17) was tested with a stand-in guard only. Test one push with
  the real `push-guard.sh` and `core.hooksPath=.githooks`.

## Owner decisions still open

1. **`backlog task` rule in `run-guard.sh` (#16).** With `backlog: false` the guard still denies `backlog task`
   commands. Making the rule apply only with `backlog: true` loosens a guard, so it was left for the owner.
2. **Owner decisions twice in the pull request body (#18).** `pr-body.sh` writes a `## Decisions` section and
   `pr-refresh.sh` writes one too. Proposal: keep the one of `pr-refresh.sh`.
3. **Does a missed round count in the fix loop (#19)?** Today every round counts toward the limit of 10.
4. **Plan-approval reminder (#19).** Left out: it needs a change in Archon's core, not in the kit.
5. **What the trace copies (#21).** The Warnings section of `trace.md` copies a script's own stderr line. Home
   paths, URLs and e-mail addresses are cut; an account name written as plain text is not. The 8-character session
   ids are shown. Decide whether that is acceptable for a local file.
6. **The installed `archon` is 129 commits behind the fork head.** It rejects `assistants.copilot.fileHooks` and
   has no `kit` command, so `workflow-contracts.test.sh` fails its dry-run cases on that machine. Upstream has no
   release after v0.14.0 and has neither feature. Updating means `scripts/install-local.sh --no-setup --skip-tools`
   and a restart of `archon serve`; the old files stay as `.prev-<timestamp>`.

## Work to do

### CI and profiles

- **The contract profile must not carry Java CI (owner decision, 2026-11-20).** An OpenAPI contract is a YAML file
  in a git repository; it needs neither Java nor Spring. #20 put a full `ci.yml` and `ci-inputs.yml` in
  `kit/profiles/openapi-contract`. Change it: `openapi-contract` ships no `ci.yml`; `java-spring` owns the one
  `ci.yml`, with its contract steps on lines marked `@@KIT_IF_PROFILE_OPENAPI-CONTRACT@@` (the marker of #18).
  Remove the `core,openapi-contract` known gap from `scripts/kit-sync-deps.ts`. Every CI step this pull request
  added to both files then lives in one. Needs #18 and #20 merged first.
- **`workflow-contracts` case W1 on an install without the contract profile (#20).** It expects
  `scripts/contract-mcp/cli.mjs`, which ships only with `openapi-contract`. Make the case follow the profile.
- **Remove Quarkus from the kit (owner decision, 2026-11-20).** Not done in #20: it reaches the sync
  classification (`QUARKUS_TEMPLATE`, the skill map in `scripts/kit-sync-lists.ts`), the `stack: quarkus` branches
  in the gate scripts (`build-shape-check.sh`, the pin-proof test data) and the docs pages. Its own pull request.
- **Left out of #20 on purpose:** a unit/integration job split (existing installs would go red), an in-repo
  contract path, `--configuration-cache` in CI, and an upload of the archon-scripts suite log.

### Fences (#22)

- **Protect the hook folders from every node.** A developer node can still edit the hook scripts in its own
  worktree (`.github/hooks`, `.archon/copilot/hooks`, `.claude/hooks`).
- **Match tool names without regard to case.** `monitor` passes where `Monitor` is denied; that Copilot filters
  this itself is assumed, not tested.
- **A hook that runs past its timeout fails open.** Documented, not solved.
- **Other workflows with `fileHooks` on get the same rules.** None was run; run one.
- **Left in on purpose:** the `Bash(...)` patterns in the workflow's `denied_tools` (the guard reads them there),
  the Claude-only env vars in `config.yaml`, and the `worktree-consumer.sh` and `closeout` allowlist entries.

### Workflow (#19, #18)

- **`effort` per node** is set but it is not verified that Copilot accepts it.
- **A retried node runs again on top of its own commits.** Check that each agent node is safe to repeat.
- **`mcp-use` still counts MCP calls only**, although the prompts now put the CLI first.
- **The skill lists of `write-tests` and `build-step`** are not yet cut per installed profile.

### Evidence (#21)

- **Hook records still say `"main"`** instead of the node. #22 exports `KIT_NODE`; use it in the audit records once
  both are merged, and drop the session-id join where it is no longer needed.
- **The tokenomics loader** was tested with fixtures only; check it against a real Archon database with Copilot
  runs.

### This pull request

- **Dependency review is not wired (owner decision needed).** The plan asks for a Gradle plugin that needs no
  account or token. OWASP `dependency-check-gradle` wants an NVD API key to update in reasonable time, and by default
  sends coordinates to Sonatype (OSS Index) and hashes to Maven Central (both can be turned off); the Snyk and
  Sonatype plugins need a token; CycloneDX and Gradle's dependency verification check no advisories. Choose one, or
  accept the offline OWASP setup with its slow first update. The options are in `kit/SPEC.md`, Report-only gates.
- **Every new gate ships report-only.** Switching one to `block` (`gates.<gate>` in `.archon/kit.yaml`, plus a dated
  `docs/memory.md` entry) is the project's step after its week in report mode; none was switched.
- **No tool or plugin is installed.** `install-tools.sh` does not fetch `gitleaks` or `spectral` (it is changed by #19
  and #20), and the kit adds no Spotless or JaCoCo to a build. Until then those gates print "not set up" and pass.
- **The Quarkus `ci.yml` has no new step.** It goes with the Quarkus removal.
- **`tests-ran` checks the total only.** A test task of `ci.gradle_line` that left no JUnit XML is a note, not a
  finding, so a project without integration tests yet stays green. Make it a finding once every module has both.
- **`build-shape-check.sh` checks a fixed task list** (`test`, `integrationTest`, `build`, `:application:bootJar`), not
  the tasks of `ci.gradle_line`. Its new suite pins today's behaviour.
- **`ci-local.sh` does not show the test count** in its `local-ci/<job>` status; the count is only in the job log.
- **The secret scan prints file, line and rule only** (`--redact`), never the matched text. Confirm that is what may
  appear in a CI log.

## Not in the kit

- The plan document (Claude Doc "Copilot kit: plan to improve the build workflow and the CI steps") has the two
  measured runs but not the results of these pull requests.
