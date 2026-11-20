# Copilot kit: layout and contract

This file is the contract shared by every piece of kit work:
- the generator `scripts/kit-sync.ts` (its copy lists and rewrites in `scripts/kit-sync-lists.ts`, the project-noun and path rewrites in `scripts/kit-sync-generic.ts`, the dependency check in `scripts/kit-sync-deps.ts`, the conversions in `scripts/kit-sync-convert.ts`, source and overlay reading in `scripts/kit-sync-source.ts`);
- the embedder `scripts/generate-bundled-kit.ts`;
- the CLI commands `archon kit add`, `archon kit doctor` and `archon kit tools`;
- the hand-written overlays.

Change it only together with every consumer.

## Purpose

`archon kit add <project>` installs a GitHub Copilot CLI version of an agent setup into a project. The setup comes from a source repo that uses Claude Code (its `.claude/`, `.archon/`, `scripts/`, `docs/scaffold-templates/`; its name is `KIT_SOURCE`, see Source name).

- **Source of truth.** The source repo stays the source. `kit/profiles/**` is **generated**, so never hand-edit it.
- **Hand-written parts.** Only `kit/overlays/**`, `kit/SPEC.md` and `kit/kit.defaults.yaml` are written by hand.
- **Tools.** `archon kit tools [path] [--check]` runs the project's `scripts/install-tools.sh` (core), passing `--check` through: it installs the tools the kit's scripts need, or with `--check` only reports what is missing.

## Generator (kit-sync)

- `KIT_SOURCE=<name> bun run kit:sync <source-repo>` (`scripts/kit-sync.ts <source-repo> [--check] [--out kit]`) rewrites `profiles/**` and `manifest.json`, and leaves the hand-written files alone.
- **Reads the source's HEAD.** It reads git-tracked files from the commit `git rev-parse HEAD` names, never the work tree, so one commit gives one kit; uncommitted changes under the scanned roots are a warning. The scanned roots are `.agents/`, `.archon/`, `.claude/`, `.githooks/`, `.github/`, `docs/code-maps/`, `docs/scaffold-templates/` and `scripts/`. Every tracked file under them is assigned to a profile or excluded by the copy lists, or the sync fails. Binary files and symlinks fail it too.
- **Deterministic.** Sorted output and no timestamps: the same source commit and overlays give the same bytes.
- `--check` regenerates into a temp dir, diffs it with `kit/` and exits 1 on drift (printing the paths) or on an overlay whose `sourceSha256` no longer matches its `derivedFrom` file.
- `--verify` needs no source: it checks `manifest.json` against `profiles/**` (sha256, mode, template flag, sort order, no extra or missing file), that every overlay file is synced, the leak FAIL patterns and the dependency check. `bun run check:kit` runs it and `bun run check:bundled-kit` checks `packages/cli/src/bundled-kit.ts`; both are in `bun run validate`.
- **Leak check.** The sync fails on a home path (`/home/<owner>`), an owner GitHub account, the owner's full name, a reference to a never-ship script (see What never ships), or a secret-looking token (GitHub, AWS, Slack, Anthropic keys, private keys). It warns on the source's project nouns (the first word of `KIT_SOURCE`, rekord, portal) in `core`, `java` and `java-spring`.
- **Dependency check.** Every profile set `kit add` accepts (core, closed under `requires`, at most one of an exclusive group: 8 sets) must hold what its shipped files read: in a set with `java`, `.github/workflows/ci.yml` for `ci-local.sh` and `ci-plan.sh` and `.github/ci-inputs.yml` for `ci-plan.sh`; every template a code-map leaf's `## Scaffold` row links (the rows `scripts/scaffold/targets.js` reads); every project script an agent's `mcp-servers` entry runs, and the contract CLI its MCP fallback names; and every test suite a `.github/workflows/ci.yml` runs by name. A missing file fails `--verify` and prints `FAIL deps:` in a sync. `KNOWN_GAPS` in `scripts/kit-sync-deps.ts` accepts a gap with a reason, reported as `WARN deps:`; a sync names an entry that no longer matches, so it goes once the gap closes.

## Source name

- **`KIT_SOURCE`** is the source repo's name, in kebab case (e.g. `shop-portal`). It is the one value kit-sync derives the source's own names from (`scripts/kit-sync-source-name.ts`): the repo and its checkout folder, its database name (`shop_portal`), the domain noun its names start with (`shop`, `Shop`, `SHOP_`), its former umbrella repo (`shopapp`) and its run skill (`run-shop-portal`, which ships as `run-app`). No copy list, rewrite or leak rule spells the source repo's name.
- **A sync refuses without it.** `kit:sync` and `--check` refuse to run when `KIT_SOURCE` is unset or empty; a name that is not kebab case fails too.
- **`--verify` and the tests** need no source: they run under the placeholder `sample-app`.
- **The kit's own name** is `archon-kit`: `source.name` in `manifest.json` and a project's `kit.lock.json`, never the source repo's.

## Folders

```
kit/
  SPEC.md                    this file (hand-written)
  kit.defaults.yaml          the default project config, written to <project>/.archon/kit.yaml (hand-written)
  overlays/<profile>/        hand-written files that replace or add generated files
    overlay.json             { "<target path>": { "derivedFrom": "<source path>|null", "sourceSha256": "<hex>|null",
                                                  "createOnly": true (optional) } }
    <target path>...         the file contents, at their target path
  profiles/<profile>/        GENERATED by kit-sync: files at their path in the target project
    <target path>...
  manifest.json              GENERATED by kit-sync
```

## Profiles

Profiles are installed in this order. When two profiles carry the same path, the later one wins.

| Profile | Requires | Content |
|---|---|---|
| `core` | — | The Archon run tooling: one build run per ticket with a plan approval, CI by SHA, retro and run observability scripts. Also: hooks, generic skills and agents, the codegraph MCP entry, the tool installer, the githooks (`.githooks/` for a person, switched on by `scripts/install-hooks.sh`: `commit-msg`, and `pre-push`, which runs `push-guard.sh check`; `.archon/githooks/` for Archon processes, switched on by the `.archon/config.yaml` env), `.github/copilot-instructions.md` and the instructions templates. |
| `java` | core | Shared Java/JVM skills, the layer rules (as `.github/instructions`), ArchUnit/Gradle CI scripts, `scripts/scaffold*`, the stack-neutral scaffold templates, and the analyst, developer, test-writer and debugger agents. |
| `java-quarkus` | java | The Quarkus originals: bean-config-di, persistence-repository, resilience4j, exception-to-http, api-first-controller, testcontainers, the Quarkus-flavoured scaffold templates, and the source's run skill → `run-app`. |
| `java-spring` | java | The same paths as `java-quarkus`, rewritten for Spring Boot. It comes from `kit/overlays/java-spring/`, which kit-sync copies to `profiles/java-spring/`. |
| `openapi-contract` | core | The contract-api MCP server (`scripts/contract-mcp/**`, from the source's `scripts/portal-mcp/**`), `scripts/contract-agent-readiness/**`, contract-pin, contract-db-parity and the contract-agent. |
| `mijn-gezondheid` | java-spring, openapi-contract | A project profile: that repo's own scaffold templates, their `## Scaffold` table and its `scaffold.json` in `docs/scaffold-templates/project/`, from the hand-written `kit/overlays/mijn-gezondheid/`. java's `new-context.sh`, `smoke.sh` and the wiring check run on them as installed. |

`java-quarkus` and `java-spring` are mutually exclusive. The default for a new project, and for `archon kit setup`, is `core,java,java-spring,openapi-contract,mijn-gezondheid`. An install from before keeps its saved profiles: `archon-kit-update --add-profile mijn-gezondheid` adds it once, and the update after keeps it.

**Project profiles.** A profile with `"project": true` in the manifest carries one repo's own files. It alone may ship into `docs/scaffold-templates/project/`, the repo's own folder: `kit add` refuses a generic profile's file there, and kit-sync's verify fails it. A project profile's files behave as any kit file: written when missing, replaced while unedited, kept once the repo edits them (`--force` takes the kit's). The kit never prunes a file in that folder, so leaving the profile out never removes the repo's templates. A generic profile carries no project noun; a project profile is where they go.

## manifest.json

```json
{
  "version": 1,
  "source": { "name": "archon-kit", "commit": "<sha>" },
  "profiles": {
    "core": { "requires": [], "description": "..." },
    "java": { "requires": ["core"], "description": "..." },
    "mijn-gezondheid": { "requires": ["java-spring", "openapi-contract"], "description": "...", "project": true }
  },
  "exclusive": [["java-quarkus", "java-spring"]],
  "files": [
    {
      "path": ".github/agents/reviewer.agent.md",
      "profile": "core",
      "mode": "0644",
      "template": false,
      "origin": ".claude/agents/reviewer.md",
      "kind": "agent",
      "sha256": "<hex of the file in profiles/>"
    }
  ],
  "aliases": {
    "@scout-copilot": { "provider": "copilot", "model": "claude-haiku-5.5" },
    "@build-copilot": { "provider": "copilot", "model": "claude-sonnet-5.5" },
    "@analyse-copilot": { "provider": "copilot", "model": "claude-opus-5.5" }
  },
  "postInstall": [
    { "profile": "core", "run": "bash scripts/install-hooks.sh", "optional": true },
    { "profile": "core", "run": "bash .archon/scripts/codegraph-setup.sh", "optional": true },
    { "profile": "openapi-contract", "run": "npm ci --prefix scripts/contract-mcp", "optional": false },
    { "profile": "openapi-contract", "run": "bash .archon/scripts/contract-mcp-setup.sh", "optional": true },
    { "profile": "core", "run": "bash .archon/scripts/mcp-setup.sh", "optional": true }
  ]
}
```

- `files` is sorted by `profile` order, then by `path`. Paths use forward slashes and never contain `..`.
- `kind` is one of `agent`, `skill`, `hook`, `instructions`, `mcp`, `workflow`, `script`, `template`, `config` or `doc`.
- `mode` is `0755` for files that are executable in the source (git mode 100755) and `0644` for everything else.
- `createOnly: true` (present only when true, from the overlay entry's `createOnly`) marks a starter file the project
  owns once it exists: `kit add` writes it only when the project has no such file, even with `--force`, and
  `kit doctor` leaves it out of the drift check. The starter `docs/memory.md` of `java` is one.
- `when: "<key>"` (present only on a switchable file) names a boolean key of `.archon/kit.yaml`: the file ships only
  while that key, read from the project's kit.yaml and else from the kit defaults, is not `false`. With it off,
  `kit add` (and `kit setup`) does not write the file and prunes the copy it wrote before when it is unedited (an edited
  one stays, listed as no longer in the kit), and `kit doctor` leaves it out of the drift check. The one key in use is
  `local_ci` (see Local CI switch). `kit-sync --verify` refuses a `when` key that `kit.defaults.yaml` does not set to
  `true` or `false`.

## Placeholders (`template: true`)

- **Syntax.** A placeholder is `@@KIT_<NAME>@@`, where NAME is an UPPER_SNAKE key of `.archon/kit.yaml`; nested keys are joined with `_`. Examples: `@@KIT_BASE_BRANCH@@` and `@@KIT_CONTRACT_REPO@@`.
- **Rendering.** `archon kit add` renders placeholders at install time.
- **Lists.** A list value renders as its items joined with `, `.
- **Missing keys.** A missing key renders empty, and `kit add` warns about it.
- **Built-in.** `@@KIT_PROJECT_DIR@@` is not a kit.yaml key: `kit add` renders it as the absolute path of the project it installs into. It replaces the source's main checkout path, for example in the workflows' `denied_tools`.
- **No overlap.** The syntax never clashes with mustache `{{ }}` or shell `${ }`.
- **Prefer runtime reads.** A script that can read `.archon/kit.yaml` at runtime should do that, using yq with a default. Use placeholders only where a file can't read config: skill or agent markdown, and JSON hook or MCP files.

## .archon/kit.yaml (project config, from kit.defaults.yaml)

```yaml
profiles: [core, java, java-spring, openapi-contract]
stack: spring                # quarkus | spring: the gates that differ per framework branch on it
base_branch: main
gh_accounts: []              # gh-switch-account skill
agent_cli: copilot           # install-tools.sh and kit-config.sh: claude | copilot
build_workflow: build-feature-copilot   # run-metrics.js, retro-stopped.sh and plan-context.sh find the build workflow by this
local_ci: true               # false: the project runs its own CI; see Local CI switch
java_version: 26              # kit add: the build's JavaLanguageVersion.of(N), refused when set to another
pin_proofs: .archon/pin-proofs.txt   # pin-proof-check.sh, either stack: <item>|<module>|<task>|<class> lines
build_shape:                 # build-shape-check.sh; "-" turns one check off, with a notice
  modules: "-"               # the settings.gradle.kts modules, space-separated
  memory_marker: "-"         # a docs/memory.md decision id the build shape must name
  forbidden: "-"             # a remnant no build file or workflow may name
framework_packages: ["org.springframework.."]   # arch-fitness: forbidden in domain
modules:                     # layer globs, used by the .github/instructions applyTo fields and the scope rules
  domain: "**/*-domain/**"
  usecase: "**/*-usecase/**"
  adapter: "**/*-adapter/**"
  gateway: "**/*-gateway/**"
  platform: "**/platform/**"
generated_globs: ["**/build/generated/**"]
commands:
  test: "./gradlew test"
  integration_test: "./gradlew integrationTest"
  check: "./gradlew check"
contract:
  server_name: contract-api  # read at runtime by mcp-setup.sh, mcp-use-check.js, tool-advice.sh and tokenomics
  repo: ""                   # owner/repo of the contract hub; ci-plan.sh reads it with tag_key at runtime
  spec_path: contract/dist/openapi.yaml
  tag_key: contractTag       # gradle.properties key that pins the contract
  checkout_step: "Check out the contract"   # ci-workflow-check.sh: the contract checkout step
  generated_dir: ""          # e.g. shared-adapter/build/generated/openapi/src/main/java/com/acme/api
  api_package: ""            # e.g. com.acme.api
```

## Local CI switch (`local_ci`)

`local_ci: true`, the default, runs CI on the developer's or the run's machine: `.claude/scripts/ci-local.sh` runs the
jobs of `.github/workflows/ci.yml` and posts one `local-ci/<job>` status per job on the commit, and the build workflows
take that verdict by SHA (`ci-by-sha.sh`). A project that runs its own CI, such as GitHub Actions, sets
`local_ci: false`. The manifest marks the local-CI files `when: "local_ci"`, so `kit add` leaves them out and
`kit doctor` does not ask for them:

- core: `.claude/scripts/` `ci-local.sh`, `ci-plan.sh`, `ci-queue.sh`, `ci-ledger.sh`, `ci-status-grammar.sh`,
  `ci-audit.sh`, `ci-cost.sh` and `gate-change-check.sh`, with their `scripts/test/` suites; `.archon/scripts/ci-skip.sh`;
  `.archon/red-triage/infra.tsv` and `flaky.tsv`; and the local-mode suites `ci-by-sha`, `local-ci-run`,
  `local-ci-status` and `red-triage` under `.archon/scripts/test/`;
- java: `.claude/scripts/ci-workflow-check.sh` and `scripts/test/ci-workflow-scope.test.sh`;
- java-quarkus and java-spring: `.github/workflows/ci.yml` and `.github/ci-inputs.yml`.

The four scripts the build workflows name stay, as the workflow contract requires (every script a workflow names
exists), and read the switch at runtime (`kit_get local_ci true`, env `KIT_LOCAL_CI`) so the workflows run unchanged:

- `local-ci-run.sh` runs nothing and exits 0 (the project's CI runs on the push); `--logs` names `gh pr checks` and
  `gh run view <run-id> --log-failed` instead of a local folder, and exits 1;
- `local-ci-status.sh` reads GitHub's check runs and commit statuses on the commit, so `ci-by-sha.sh` answers green,
  red (naming the failed checks), or none, with its usual waits, and the `ready` node marks the pull request ready on
  green;
- `red-triage.sh` cannot triage (exit 1), so the `triage` node counts a red as the branch's own and `ci-fix` works on
  it; there is no infra or flaky rerun, and `red-head` never finds a red inherited from main (it reads only
  `local-ci/<job>` contexts).

`.archon/scripts/test/local-ci-off.test.sh` covers that mode. `affected-check.sh` runs `gate-change-check.sh` and
`ci-workflow-check.sh` only when they exist. Switching back to `true` and running `kit add` writes the files again.

## Conversion rules (kit-sync)

| Source | Target | Rule |
|---|---|---|
| `.claude/agents/<n>.md` | `.github/agents/<n>.agent.md` | Frontmatter becomes `name`, `description`, `model`, `tools`, `mcp-servers`, `hooks` and `include-custom-instructions: true`. An agent with an entry in `.claude/hooks/agent-scopes.json` gets its own `hooks: {preToolUse: [{type: command, command: "env KIT_AGENT=<n> bash .github/hooks/dispatch.sh PreToolUse '*' .claude/hooks/scripts/scope-guard.sh PreToolUse", timeoutSec: 60}]}`, which Copilot CLI runs only while that agent is selected: a root session (`copilot --agent <n>`) sends no agent field, so payload.sh names the agent from `KIT_AGENT` (a subagent's call carries `agentType` and `agentId`, and `KIT_AGENT` never overrides them). A hook that outlives its timeout fails open under Copilot CLI and a non-zero exit denies, so scope-guard keeps 60 s and denies a command longer than `SCOPE_GUARD_MAX_CMD` (16384) instead of reading it slowly; an agent name that is not shell-safe fails the sync. The model maps opus→`claude-opus-5.5`, sonnet→`claude-sonnet-5.5`, haiku→`claude-haiku-5.5`. Tools map Read/Grep/Glob→`read`+`search`, Edit/Write/MultiEdit/NotebookEdit→`edit`, any `Bash(...)`→`execute`, WebFetch/WebSearch→`web`, `Agent(...)`→`agent`, `mcp__<s>__*`→`<s>/*`, `mcp__<s>__<t>`→`<s>/<t>`, and drops Skill (skills load by name), PushNotification, SendMessage and ListAgents. The `skills:` list becomes a body line `Load these skills first: a, b.`. An unknown tool fails the sync. `mcpServers` (a map or a list of one-key maps) becomes `mcp-servers` entries `{type: local, command, args, tools: ["*"], env}`, dropping `alwaysLoad`. Under a closing `## On Copilot CLI` the body notes each Claude-only tool that is dropped, the `Bash(...)` patterns as the shell allowlist to keep to, and the `Agent(...)` names as the only agents to delegate to. The source's contract server name (`portal-api`) becomes `@@KIT_CONTRACT_SERVER_NAME@@` in tools, servers and body. **MCP fallback** (the kit only; the source's agents stay on MCP): an organization's MCP registry policy can block the kit's local servers, so an agent with a shell (`Bash` or `Bash(...)`) and an `mcp__codegraph__` tool may also run `codegraph explore`, `codegraph node`, `codegraph callers`, `codegraph callees`, `codegraph impact` and `codegraph query` (never init, uninit, index, sync, daemon or unlock), and one with a contract server tool `node scripts/contract-mcp/cli.mjs` (the server's CLI, the same answers). Its shell note adds them as `<cmd> *`, a `MCP fallback:` note says when and how to run them, and `.claude/hooks/agent-scopes.json` gets them appended to that agent's `commandAllowlist` (once; an agent without one, or without a shell, gets none), so scope-guard's prefix match lets `codegraph explore "x"` and `node scripts/contract-mcp/cli.mjs search cancel vendor` through, also behind a stripped `rtk `. An agent that names the contract CLI needs `scripts/contract-mcp/cli.mjs` (Dependency check). **Scaffold scripts** (the kit only, `SCAFFOLD_COMMANDS` in `scripts/kit-sync-convert.ts`): a repo's own templates in `docs/scaffold-templates/project/` are used by three generic scripts of the java profile (kit overlays, with no project noun): `scripts/scaffold/new-context.sh` (a new module set rendered from them and registered in the build), `scripts/scaffold/smoke.sh` (every template rendered with its `<name>.example.json` in a throwaway copy, then built; `--render-only` stops after the render) and `scripts/test/scaffold-wiring.test.sh` (every template linked from a `## Scaffold` row, found by `--for` and rendered by the build's scaffold step, without a build). What a module set is and what to build comes from the repo's own `docs/scaffold-templates/project/scaffold.json`, which only a project profile ships (Profiles): `context` (`modules`, `flags`, `args`, `help`, `files` rendered or copied in order, `register` for the settings' `include(` block and the dependents' `implementation(project(...))` lines), `smoke` (`context`: the `new-context.sh` arguments, `gradle`: the `./gradlew` tasks) and `projectOnly` (`scripts/scaffold/targets.js` drops every row that links a kit template, so `--for`, the scaffold step and the scaffold-check gate offer only the repo's own, without an edit to a kit-owned leaf; the wiring check also fails such a row); the headers of `scripts/scaffold/new-context.js` and `smoke.sh` give the form. Without it `new-context.sh` says so and exits 1, `smoke.sh` renders without a context or a build, and the wiring check skips what it needs. `kit add` keeps a repo's own copy of a script it did not write (`--force` takes the kit's). `scripts/scaffold/smoke.sh`, `new-context.sh` and the wiring check are tested by `scripts/test/scaffold-project.test.sh` on a fixture repo. An agent with a shell gets them on its shell note, in a `Scaffold scripts:` note that says when to run them, and on its `commandAllowlist`: developer `scripts/scaffold/new-context.sh`, `scripts/scaffold/smoke.sh` and both checks (`scripts/test/scaffold.test.sh`, the renderer's or a repo's own in its place, and `scripts/test/scaffold-wiring.test.sh`); test-writer `scripts/scaffold/smoke.sh --render-only` and both checks; analyst and reviewer `scripts/scaffold.sh --for` (read-only), `scripts/scaffold/smoke.sh --render-only` and both checks. No other agent gets one. |
| `.claude/skills/<n>/**` | `.github/skills/<n>/**` | Copied verbatim; the source's run skill (`run-<KIT_SOURCE>`) ships as `run-app`. `.claude/skills/archon-cli/**` does not ship (the `.agents/skills/archon-cli` copy does). In SKILL.md frontmatter it keeps `name`, `description`, `license` and `allowed-tools`, and drops the rest. A dropped `disallowed-tools` or `disable-model-invocation` is added as a body note under `## On Copilot CLI`. |
| `.agents/skills/archon-cli/**` | the same path | Verbatim. |
| `.claude/settings.json` `hooks` | `.github/hooks/kit.json` | `{"version":1,"hooks":{<event>:[{"type":"command","bash":"bash .github/hooks/dispatch.sh <ClaudeEvent> '<matcher>' <script path> <args>","timeoutSec":N}]}}`. Events map SessionStart→sessionStart, UserPromptSubmit→userPromptSubmitted, PreToolUse→preToolUse, PostToolUse→postToolUse, PostToolUseFailure→postToolUseFailure, SubagentStart→subagentStart, SubagentStop→subagentStop, SessionEnd→sessionEnd, Stop→agentStop. |
| — | `.github/hooks/dispatch.sh` | Generated, a fixed script. It reads stdin, normalizes the payload with `.claude/hooks/scripts/payload.sh`, applies the Claude matcher regex (anchored) to the normalized tool name, runs the script with the normalized payload (from `.claude/hooks` for a script under it, else the project root; a missing script is a no-op), turns a PreToolUse exit 2 into a deny with stderr as the reason, and translates a Claude `hookSpecificOutput.permissionDecision` into Copilot's top-level `permissionDecision`/`permissionDecisionReason`. A batched payload (Copilot CLI 1.0.114 preToolUse: `{cwd, sessionId, toolCalls: [{id, name, args}]}`) is split into one run per call (`toolCallId`, `toolName`, `toolArgs`); on PreToolUse the first denied call denies the batch, and a batch it cannot read (no jq) is denied. The kit's copy is edited in `kit/` (the kit is no longer synced); `DISPATCH_SH` in `scripts/kit-sync-convert.ts` is the older single-call version. |
| `.claude/settings.json` `permissions.deny` | `.archon/copilot/deny.json` | Read by `run-guard.sh`, which enforces it in every session, not only in run worktrees. |
| `.claude/rules/<layer>.md` | `.github/instructions/<layer>.instructions.md` | `paths:` becomes `applyTo:`, a comma-joined glob string built from the `@@KIT_MODULES_<LAYER>@@` placeholder when the layer is in `modules`, otherwise the verbatim globs. A rule without `paths:` (general) gets `applyTo: "**"`. |
| MCP servers | `.github/mcp.json` | `codegraph` is `codegraph serve --mcp` with env `CODEGRAPH_MCP_TOOLS=explore,node,search,callers,callees,impact` (core). `@@KIT_CONTRACT_SERVER_NAME@@` is `node scripts/contract-mcp/server.mjs` (openapi-contract). Because JSON can't be split by profile, kit-sync writes the full core+contract file to `openapi-contract` and a core-only one to `core`. |
| `.archon/workflows/build-feature.yaml` | `.archon/workflows/build-feature-copilot.yaml` (core) | Generated from the source's `build-feature.yaml` with its `.archon/scripts/copilot-workflow.js` (the generator itself does not ship), or copied when the source tracks it. The Claude workflow itself does not ship: it reads its skills from `.claude/skills`, which a Copilot install does not have (the kit ships them under `.github/skills`), so it would run without them. The Copilot build workflow ships, made standalone (see Plan approval and human merge). After each MCP paragraph of its prompts (the line `Grep stays the tool for text, config, logs and strings; without the tools, read as before.`) it adds one sentence naming the CLI fallback (`WORKFLOW_FALLBACK`); a workflow without that line fails the sync. |
| Other files on the copy lists | the same path | Verbatim. Each one is assigned to a profile by the copy lists in `scripts/kit-sync-lists.ts`. `.github/workflows/ci.yml`, `.github/ci-inputs.yml` and `ci-workflow-check.sh` are Quarkus-built and go to `java-quarkus`. A scaffold template naming `io.quarkus`, `jakarta.ws.rs`, `jakarta.enterprise` or `jakarta.inject` goes to `java-quarkus`, every other one to `java`. |
| Every shipped text file | — | After conversion: `run-<KIT_SOURCE>` becomes `run-app`, the contract hub repo becomes `@@KIT_CONTRACT_REPO@@`, and the source's main checkout path (and its systemd form `%h/<KIT_SOURCE>`) becomes `@@KIT_PROJECT_DIR@@` (only that last one in `.agents/skills/archon-cli/**`). The project nouns go (`NOUN_REWRITES`): `portal-api` and `mcp__portal-api__` become `@@KIT_CONTRACT_SERVER_NAME@@`, `rekordContractTag` becomes `@@KIT_CONTRACT_TAG_KEY@@`, `portal-mcp` becomes `contract-mcp` and `portal-metrics` becomes `run-metrics`, and the files ship renamed to match (`scripts/contract-mcp/**`, `.archon/scripts/contract-mcp-setup.sh`, `.archon/workflows/run-metrics.yaml`). Then the Claude Code paths move to where the kit ships them (`PATH_REWRITES`): `.claude/agents/<n>.md` → `.github/agents/<n>.agent.md`, `.claude/rules/<l>.md` → `.github/instructions/<l>.instructions.md`, the bare folders → `.github/agents` and `.github/instructions`, and `.claude/skills` (either slash) → `.github/skills`; the files that mean the Claude paths themselves keep them (`PATH_SKIP`: `.archon/copilot/README.md`, `skill-check.js`, `audit-log.sh`, `verify-claims.sh`). Per-file rewrites (exact counts, or the sync fails) template the base branch (`@@KIT_BASE_BRANCH@@` in `.archon/config.yaml` and the build-feature-copilot workflow), the gh accounts (`@@KIT_GH_ACCOUNTS@@` in the gh skills; `gh-switch.sh` reads `gh_accounts` from `.archon/kit.yaml` with yq at runtime), the standalone text (`STANDALONE_TARGETED` in `scripts/kit-sync-standalone-text.ts`: the lines that name what never ships), and the project names in comments and messages (`NOUN_TARGETED`). |
| `docs/code-maps/<leaf>.md` (core, java) | same | A listed leaf's `## This repo (<source>)` section, which holds the source's facts, ships as a `## This repo` stub that asks the project to fill it in (`THIS_REPO_LEAVES`). The sync fails when a listed leaf lost the section or an unlisted core or java leaf has one. |
| `.claude/CLAUDE.md` | same (core overlay) | `kit/overlays/core/.claude/CLAUDE.md`: the constitution (P1–P8), the STOP list and How work moves kept, the source's dates, ticket ids and project paths dropped, and its values placeholders (`@@KIT_BASE_BRANCH@@`, `@@KIT_CONTRACT_REPO@@`, `@@KIT_CONTRACT_SERVER_NAME@@`, `@@KIT_BUILD_WORKFLOW@@`, `@@KIT_COMMANDS_TEST@@`). Its `sourceSha256` makes `--check` report it stale when the source's CLAUDE.md changes. |

## Test suites

- **What ships.** Every `.archon/scripts/test/*.test.sh` and `scripts/test/*.test.sh` of the source ships with the
  profile of the script it tests, so the suites run in an install (the archon-scripts CI job, `run-suites.sh`). The
  subject is found by the suite's stem (`.archon/scripts/<stem>.sh|.js`, `.claude/scripts/<stem>.sh`,
  `.claude/hooks/scripts/<stem>.sh`, `scripts/<stem>.sh`, `scripts/<stem>/`) or named in `SUITE_SUBJECTS`
  (`scripts/kit-sync-tests.ts`). A fixture folder goes with the suite that reads it (`SUITE_FIXTURES`).
- **What stays out.** `SUITE_EXCLUDE` lists each suite that only works against the source (its own build, contract
  checkout, ci.yml, never-ship files, or the Claude agent files that ship converted), with its reason. A suite whose
  subject cannot be found or does not ship, and a test-folder file that is no suite and no listed fixture, fail the
  sync until they are listed.
- **Rewrites.** The global rewrites apply, then `SUITE_NOUNS`: the source's names become neutral ones (a suite builds
  its own throwaway repos, so a name only has to agree within it). A suite of a `.claude` path-skip file keeps its
  `.claude/` paths, as its subject does.
- **Config.** A suite that asserts a script's defaults sets `KIT_CONFIG=/dev/null`, so the install's `.archon/kit.yaml`
  does not change them.
- **CI.** A suite a shipped `ci.yml` runs by name must ship in every set that holds that `ci.yml` (dependency check).

## What never ships

- The source's run skill `run-<KIT_SOURCE>`, which becomes the stack's `run-app`.
- The project's own `docs/code-maps/*.md` leaves. Only the README and the `kind: worked-example` leaves ship.
- The source's `docs/memory.md`, `docs/rewrite/**`, `backlog/**`, `contract/**`, the build output, secrets and `.env`
  files. `java` ships a create-only starter `docs/memory.md` (an overlay) that holds only the "CI job set" entry
  `ci-workflow-check.sh` reads (N7).
- A test suite that only works against the source project (see Test suites).
- The source's unattended machinery (owner decision 2026-11-19): the kit's team starts one run per ticket, approves its
  plan and merges its pull request, so nothing picks tickets, runs at night, queues merges or keeps a STOP approval
  ledger. `NEVER_SHIP_GROUPS` in `scripts/kit-sync-lists.ts` lists every path, each with its test, in five groups: the
  delegator (ticket picking, parallel runs, the run watchers, its agent, settings and decision schema), the night runs
  (`night-preflight`, the supervisor, the systemd units, the owner pings, run recovery and the failure classifier), the
  merge queue and the post-merge close-out (`auto-merge.sh`, `merge-turn.sh`, `wait-merge.sh`, `merge-ready.sh`,
  `main-ci.sh`, `ticket-files.sh`, `close-out.sh` and the scripts only they call), the STOP approval ledger
  (`stop-approve.sh`, `stop-check.sh`, `stop-round.sh`, `.archon/stop/**`) and the Copilot workflow generator. No copy
  list overrides the never-ship list; a suite of a never-ship script never ships either.
- Tooling the owner removed from the kit (owner decision 2026-11-20), in `NEVER_SHIP_GROUPS` too, so a sync never
  brings it back and a shipped line that names one of its scripts fails the leak check. That is the Groma architecture
  map (`groma-check.sh`, `groma-delta.sh`, `groma-links.sh`, `groma-sync.sh`, the source's `.githooks/pre-push` hook that
  ran the map check (the kit's own `.githooks/pre-push` runs the push guard), and their suites), the mutation gate
  (`mutation-gate.sh`, PIT on the changed classes, its suite and fixtures) and the image CI job's check
  (`image-check.sh` and its suite). The kit's CI job set is `archon-scripts` and `test`.
- What kit-sync strips with them: the `.claude/settings.json` hooks and deny entries that name a never-ship file, and
  the never-ship agents' entries in `.claude/hooks/agent-scopes.json`. A shipped line that still names a never-ship
  file (a script's basename, `delegator.md`, `delegator.agent.md` or a systemd unit) fails the leak check; the
  `STANDALONE_TARGETED` rewrites reword those lines.
- Kept on purpose, as tools a person runs: `stop-run.sh` (rejects a paused run and keeps the reason),
  `answer-blocked.sh` (answers a run's blocked question) and `cleanup-merged.sh` (deletes a merged branch and its
  worktree).

## Plan approval and human merge

The Copilot build workflow ships standalone (`scripts/kit-sync-standalone.ts`, applied to the generated
`build-feature-copilot.yaml`):

- **One human gate.** A `plan-approval` node (`wait: {form: approval}`) after `stop-route` shows the ticket, the plan
  (`$ARTIFACTS_DIR/plan.md`) and the STOP items the ticket or the plan touches. `implement` runs only on `approve`; on
  `reject` the `plan-rejected` node (`cancel:`) ends the run before any code is written. Answer it in the Archon
  console, or with `archon workflow approve <run-id> [text]` / `archon workflow reject <run-id> <why>`; the approval text
  reaches the agents as reviewer notes. A run in a container cannot pause, so run it in a worktree.
- **The run ends at `ready`.** The nodes after it (`auto-merge`, `merged`, `main-ci`, `ticket-files`, `finalize`,
  `close-out`) are cut. Once CI on the head is green the pull request is marked ready for review, and a team member
  reviews, merges it and closes the Backlog ticket (the run's `map-links` edit is left uncommitted in the backlog
  checkout for them). A red head or a conflict at `ready` fails the run, so a person sees it. After the merge,
  `cleanup-merged.sh <branch>` deletes the run's branch and worktree.
- **Checked.** The cut expects exactly those tail ids after `ready`, `implement` to depend on `stop-route` once, and
  every text rewrite to match its count; a result that still reads a cut node's output or names a cut script or the
  delegator fails the sync.

## The project's command additions (`agent-scopes.local.json`)

`.claude/hooks/agent-scopes.json` is the kit's file: `kit add` replaces it on every update. A project that needs an
agent to run one more command (its own build task, a script of its own) writes `.claude/hooks/agent-scopes.local.json`
beside it and commits it; the kit never writes, prunes or overwrites it. scope-guard (overlay
`kit/overlays/core/.claude/hooks/scripts/scope-guard.sh`) reads it as **additions only**:

```json
{"_comment": "why", "agents": {"<an agent agent-scopes.json fences>": {"commandAllowlist": ["./gradlew lintKotlin", "node tools/check.mjs"]}}}
```

- Each entry is appended to that agent's `commandAllowlist` (an agent without a list gets one). The kit's entries stay:
  nothing in the file removes or replaces one, so a kit update that adds an entry still reaches the agent.
- Refused, as a deny with the reason on every call of a fenced agent until a person fixes the file (fail closed): a file
  that is not JSON or not an object; a top-level key other than `agents` and `_comment`; an agent `agent-scopes.json`
  does not fence (adding an agent); any agent key other than `commandAllowlist` (`allowedFilePaths`, `readPaths`,
  `hubRoot`, a deny list, ...); an entry that is not a string, is empty, holds a shell operator
  (`; & | \` $ < > ( ) { }` or a newline), starts with a wrapper that runs any command (`env`, `xargs`, `sudo`,
  `eval`, `exec`, `timeout`, ...) or an option, or is a bare interpreter (`bash`, `sh -c`, `node -e`, `python3 -c`, ...).
  A call outside any agent, and an agent agent-scopes.json does not fence, are never touched.
- No agent may write it (the existing `agent-scopes*.json` write guard).
- A suite that names its policy (`CLAUDE_SCOPE_POLICY`) reads no project additions unless it also names them
  (`CLAUDE_SCOPE_LOCAL`), so the project's file never changes a suite's verdict.
- Tested by `.archon/scripts/test/scope-local.test.sh` (kit-only).

Before this, the file replaced `agent-scopes.json` whole, a narrowing hook for the source's removed `test-ban.sh`;
the kit drops that meaning (no kit file writes it).
