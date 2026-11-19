---
title: Copilot Kit
description: Install the Archon kit into a GitHub Copilot CLI project, configure it, upgrade it and check it.
category: guides
area: workflows
audience: [user]
status: current
sidebar:
  order: 14
---

The Copilot kit gives a project the Archon setup for GitHub Copilot CLI. It is the
Copilot counterpart of the Claude setup. You install it once with `archon kit setup`
(or by hand with `archon kit add`), commit the files it writes, and then run the
`build-feature-copilot` workflow on your own tickets.

The kit is for projects that use Copilot CLI as the coding agent. It is not a
separate product. Its files live in the Archon fork (`Vikteur/Archon`, folder `kit/`).

## Install with `archon kit setup`

`archon kit setup` is the main way to install the kit. It asks four questions in the
terminal and checks each path as you type it:

1. **Backend repository**: a git checkout. The kit goes here.
2. **Frontend repository**: a git checkout, or empty to skip it.
3. **API contract file**: an OpenAPI file (`.yaml`, `.yml` or `.json`) with a top-level
   `openapi` key.
4. **Use Backlog.md for tickets?**: yes or no. The default is no.

A path may start with `~`. A relative path is read against the current folder. On a
rerun, the dialog offers the last answers. They are kept in `~/.archon/kit-setup.json`
(the three paths, the profiles and the Backlog.md answer, nothing else). The summary
before the confirmation shows `Backlog.md: on` or `off`.

After you confirm the summary, it runs these steps, each with a spinner:

| Step | What it does |
|------|--------------|
| Tools | Runs the kit's tool installer for the backend (`archon kit tools`), with `INSTALL_TOOLS_BACKLOG=0` when Backlog.md is off, so `backlog` is not installed. |
| Kit | Installs the kit into the backend, like `archon kit add --trust`, with the profiles `core,java,java-spring,openapi-contract` unless you pick others. |
| Contract | Sets `contract.spec_path` in the backend's `.archon/kit.yaml` to the absolute contract path and `backlog` to `true` or `false`, then runs `.archon/scripts/contract-mcp-setup.sh`. |
| CodeGraph index | Runs `.archon/scripts/codegraph-setup.sh` for the backend and the frontend. |
| Frontend MCP | Writes the codegraph server into the frontend's `.github/mcp.json` (other servers stay), trusts the frontend folder, and adds it to `codegraph.extra_projects` in the backend's `kit.yaml`. |
| rtk hooks | Runs `rtk init --copilot` in each repository, when `rtk` is on `PATH`. It never installs the global hooks. |
| Servers check | Starts each MCP server of both repositories, as `kit doctor` does. |
| Web views | Runs `bash scripts/web-uis.sh start --open` in the backend and lists the URLs. |

The output of every step goes to a log, `~/.archon/logs/kit-setup-<time>.log`, not to the
terminal. A step that fails is shown as failed with that log path. The later steps still
run, and the command exits 1 at the end.

The last screen lists the web view URLs, the command that stops them
(`bash scripts/web-uis.sh stop` in the backend), the log path and the Copilot login: run
`copilot`, then `/login`, and finish it in a browser signed in as the GitHub account that
has Copilot. That account may differ from the one `gh` uses.

To run it without questions, for example in a script, give the answers as flags:

```bash
archon kit setup --backend ~/code/backend --frontend ~/code/frontend \
  --contract ~/code/contract/dist/openapi.yaml --yes
```

| Flag | Effect |
|------|--------|
| `--backend <path>` | The backend repository |
| `--frontend <path>` | The frontend repository; leave it out to skip the frontend |
| `--contract <file>` | The OpenAPI contract file |
| `--profile a,b,c` | The kit profiles (default: the last run's, then `core,java,java-spring,openapi-contract`) |
| `--backlog` | Use Backlog.md for tickets; leave it out for off (`backlog: false` in `kit.yaml`) |
| `--yes` | Skip the confirmation |
| `--no-tools` | Skip the tool installer |
| `--no-rtk` | Skip the rtk hooks |
| `--no-web` | Do not start the web views |

Without a terminal, `--backend` and `--contract` are required. Without them, the command
prints its usage and exits 2.

Both installers, `scripts/install.sh` and `scripts/install-local.sh`, start
`archon kit setup` at the end when they run in a terminal. Pass `--no-setup` to skip it.
Without setup they run `archon kit tools` instead, which installs `backlog` as before. Pass
`--no-backlog` to leave it out there too (`install.sh` also reads `ARCHON_NO_BACKLOG=1`).

## What the kit installs

`archon kit add` writes these files into your project:

| Part | Where it lands | What it does |
|---|---|---|
| Agents | `.github/agents/*.agent.md` | Role agents, such as the analyst, developer, test-writer, debugger and reviewer. Each one has a model and a Bash allowlist. |
| Skills | `.github/skills/` | Procedural knowledge the agents load, such as clean architecture, TDD, the Java rules and the contract tools. |
| Hooks | `.github/hooks/*.json` | Guardrails. Each hook calls `.github/hooks/dispatch.sh`. Copilot has no matcher syntax, so `dispatch.sh` applies the Claude-style matcher itself. |
| Instructions | `.github/instructions/`, `.github/copilot-instructions.md`, `AGENTS.md` | Layer rules and project facts that Copilot reads on every run. |
| MCP servers | `.github/mcp.json` | Two servers: `codegraph` (code navigation) and `contract-api` (the OpenAPI contract, when that profile is on). |
| Workflows | `build-feature-copilot` and related | Archon workflows that run the build with Copilot nodes. |
| Scripts | `.archon/scripts/`, `scripts/` | Delegator, STOP policy, merge, CI-by-SHA and tool installer scripts. |
| Scaffold templates | Mustache templates in the kit (`java` profile and its overlays) | Starter code for new layers, rendered from `.archon/kit.yaml`. |

The kit also writes `.archon/kit.yaml` (the project's settings), `.archon/kit.defaults.yaml`
(the kit defaults, beside it) and `.archon/kit.lock.json` (the record of what the kit wrote).
They are described below.

In `.archon/config.yaml`, `kit add` adds the kit's command aliases and sets
`assistants.copilot.fileHooks: true`, so Archon's Copilot runs load the kit's
`.github/hooks/*.json`. It keeps your other keys and comments, and a `fileHooks` value you set
yourself.

## Profiles

A profile is a group of kit files. You choose the profiles when you install.

| Profile | Requires | Contents |
|---|---|---|
| `core` | none | Archon run tooling, hooks, generic skills and agents, the `codegraph` MCP entry, the tool installer, git hooks and the Copilot instructions. |
| `java` | `core` | Shared Java and JVM skills, the layer rules, ArchUnit, PIT and Gradle CI scripts, the scaffolder, and the analyst, developer, test-writer and debugger agents. |
| `java-quarkus` | `java` | Quarkus versions of the skills, the scaffold templates, the CI workflow and `run-app`. |
| `java-spring` | `java` | The same set as `java-quarkus`, rewritten for Spring Boot. |
| `openapi-contract` | `core` | The `contract-api` MCP server, contract readiness and pin checks, DB parity, and the contract agent. |

`java-quarkus` and `java-spring` are mutually exclusive. Pick one. Each profile pulls in
the profiles it requires, so you do not need to list `core` or `java` yourself.

A typical Spring Boot project with a contract:

```bash
archon kit add . --profile core,java,java-spring,openapi-contract --trust
```

## The project settings file: `.archon/kit.yaml`

`kit add` renders the kit's `@@KIT_<KEY>@@` placeholders from `.archon/kit.yaml`. Scripts
read the same file at run time with `yq`. Nested keys are flattened with `_`, so
`commands.test` becomes `@@KIT_COMMANDS_TEST@@`.

A key that is missing from an existing `kit.yaml` takes the kit default. The kit does not
rewrite your file to add new keys. This means a kit upgrade can add a key without
touching your values. At run time the scripts read such a key from
`.archon/kit.defaults.yaml`, which `kit add` keeps up to date like any other kit file.

The defaults below suit a Spring Boot Gradle project.

| Key | Default | What it sets |
|---|---|---|
| `profiles` | `[core, java, java-spring, openapi-contract]` | The profiles installed. `kit add --profile` replaces this list. |
| `stack` | `spring` | `quarkus` or `spring`. The gates that differ per framework branch on it. |
| `base_branch` | `main` | The branch that runs target and rebase against. |
| `owner` | `""` | The name STOP approvals are recorded for (`stop-approve.sh record`). |
| `timezone` | `UTC` | The time zone of approval ids and parked notes. |
| `gh_accounts` | `[]` | The `gh` accounts the `gh-switch-account` skill switches between. |
| `ntfy_topic` | `""` | The ntfy topic `notify-owner.sh` posts to. Empty means no push. |
| `agent_cli` | `copilot` | `claude` or `copilot`. The delegator and supervisor scripts use it. |
| `build_workflow` | `build-feature-copilot` | The workflow the delegator starts for each ticket. |
| `java_version` | `21` | The Java version the build and CI use. |
| `pin_proofs` | `.archon/pin-proofs.txt` | The file of pin proofs read by `pin-proof-check.sh`. |
| `build_shape.modules` | `"-"` | The Gradle modules the build-shape check expects, space-separated. `-` turns the check off. |
| `build_shape.memory_marker` | `"-"` | A decision id in `docs/memory.md` that the build shape must name. `-` turns it off. |
| `build_shape.forbidden` | `"-"` | A name that no build file or workflow may contain. `-` turns it off. |
| `framework_packages` | `["org.springframework.."]` | Packages the architecture tests forbid in the domain layer. |
| `modules.domain` | `"**/*-domain/**"` | Glob for the domain layer. Used by the instruction `applyTo` fields and the scope rules. |
| `modules.usecase` | `"**/*-usecase/**"` | Glob for the use-case layer. |
| `modules.adapter` | `"**/*-adapter/**"` | Glob for the adapter layer. |
| `modules.gateway` | `"**/*-gateway/**"` | Glob for the gateway layer. |
| `modules.platform` | `"**/platform/**"` | Glob for the platform layer. |
| `generated_globs` | `["**/build/generated/**"]` | Generated code that reviews and searches skip. |
| `commands.test` | `./gradlew test` | Unit test command. |
| `commands.integration_test` | `./gradlew integrationTest` | Integration test command. |
| `commands.check` | `./gradlew check` | Full check command. |
| `contract.server_name` | `contract-api` | The name of the contract MCP server in `.github/mcp.json`. |
| `contract.repo` | `""` | The `owner/repo` of the contract hub. Used when the spec is not in your tree. |
| `contract.spec_path` | `contract/dist/openapi.yaml` | Where the OpenAPI spec sits in your tree. |
| `contract.tag_key` | `contractTag` | The `gradle.properties` key that pins the contract version. |
| `contract.checkout_step` | `Check out the contract` | The name of the contract checkout step in `ci.yml`. |
| `contract.generated_dir` | `""` | The folder of generated API code, for example `shared-adapter/build/generated/...`. |
| `contract.api_package` | `""` | The Java package of the generated API, for example `com.acme.api`. |

Set a value at install time with `--set`:

```bash
archon kit add . --profile core,java,java-spring,openapi-contract \
  --set contract.repo=acme/contract --set owner=alice --trust
```

`kit add` records each `--profile` and `--set` in `kit.yaml`. It keeps the rest of your
text, including comments, as it is. Commit the file.

## Rerunning and upgrading

`kit add` writes `.archon/kit.lock.json`. The lock maps each written path to the SHA-256
of what the kit wrote. On a rerun, `kit add` compares each file with the lock:

- A file that still holds what the kit wrote is updated to the newer kit.
- A file the project edited is kept. The command lists it as `kept (differs)`.
- A file that differs and has no lock entry (it predates the lock, or the project wrote it) is
  kept too. One line counts them; review them and rerun with `--force` to take the kit's version.
- Line ends do not count: a CRLF checkout of an unedited file is still the kit's.
- A destination that is a symlink, or lies in a folder linked outside the project, is never
  written through. The command lists it as `skipped`.
- `--force` overwrites the edited files too. It does not overwrite create-only starter
  files, such as `docs/memory.md`. Those always belong to the project.

```bash
archon kit add . --dry-run      # show what would change, write nothing
archon kit add .                # update the untouched files, keep the edited ones
archon kit add . --force        # also overwrite edited files (not starter files)
```

Commit `.archon/kit.lock.json`. Without it, the next run cannot tell your edits from the
kit's files.

## Setup steps

After it writes the files, `kit add` runs the setup steps of the selected profiles, in
this order:

1. **Tools.** `scripts/install-tools.sh` checks and installs git, gh, node, jq, yq, java,
   docker, copilot, archon, backlog, groma and codegraph. Pass `--no-tools` to skip it.
   `archon kit tools` runs the same script on its own. It leaves `backlog` out when
   `backlog: false` is in `.archon/kit.yaml` (or the kit defaults), or when you run
   `archon kit tools --no-backlog` (`INSTALL_TOOLS_BACKLOG=0`).
2. **Code index.** `codegraph-setup.sh` builds the CodeGraph index of the project.
3. **Contract MCP.** `npm ci` installs the contract server. Then `contract-mcp-setup.sh`
   finds the contract. A contract in your own tree at `contract.spec_path` is used as it
   is. Otherwise the contract is cloned from `contract.repo`. The readiness map
   `docs/code-maps/contract-agent-readiness.map.json` is optional.
4. **Hooks.** `scripts/install-hooks.sh` wires the hooks into the project.
5. **MCP setup.** `.archon/scripts/mcp-setup.sh` sets up the MCP servers of the project.

The `npm ci` step of the contract server is required. If it fails, `kit add` fails. All
other steps are optional. If one fails, `kit add` prints a warning and continues. Run
`archon kit doctor` afterwards to see what is still missing.

## Folder trust

Copilot CLI reads the repo hooks and `.github/mcp.json` only in a folder it trusts. Without
trust, the hooks and the MCP servers do nothing, and `kit doctor` reports it.

`--trust` adds the project folder to `trustedFolders` in `~/.copilot/config.json`. The
command keeps every other key in that file. You can also trust the folder from inside
`copilot` when it asks.

## First run

`archon kit setup` already checks the MCP servers and points you to the Copilot login.
After a manual `kit add`, do these steps:

1. Check the install:

   ```bash
   archon kit doctor .
   ```

2. Log in to Copilot. Start the CLI once in the project and run `/login`:

   ```bash
   copilot
   ```

   If you cannot use `/login`, set a token in `~/.archon/.env` instead. Use the name
   `COPILOT_GITHUB_TOKEN`. Never commit a token, and never put one in `kit.yaml`.

3. Run a dry run of the build workflow. The `--default-stubs` flag fills in the workflow
   inputs without asking:

   ```bash
   archon workflow run build-feature-copilot --dry-run --default-stubs
   ```

Check the first two steps again after any change to the tools, the login or the folder
trust.

## What `archon kit doctor` checks

`archon kit doctor [path]` reports these, one line each:

- Tools and their versions, as `scripts/install-tools.sh --check` sees them. With
  `backlog: false` in `kit.yaml`, `backlog` is reported as skipped (off), not as missing.
- Copilot login.
- Folder trust in `~/.copilot/config.json`.
- Each MCP server in `.github/mcp.json`, by a `tools/list` call. A server that does not
  answer is reported.
- Hooks: whether the hooks are installed and wired.
- Drift: files whose content differs from the kit's version and the lock.

`archon kit tools [path] --check` runs only the tool check. `archon kit list` shows the
profiles and which ones are installed here. The flags and exit codes are in the
[CLI reference](/reference/cli/).

## Known limits

- **Bash allowlists.** Each agent declares the Bash commands it may run. The
  `scope-guard` hook enforces that list from `agent-scopes.json`. Copilot's own tool
  list does not enforce it. If the hook is not wired, the allowlist is not enforced.
- **Root session.** A plain `copilot` session with no `--agent` selected is not fenced by
  any agent scope. Select an agent for work that should be fenced.
- **Notifications.** The delegator's push notifications and its agent messaging are
  Claude-only. On Copilot, `notify-owner.sh` sends through ntfy, so set `ntfy_topic`.
- **Structured output.** Structured output from a Copilot node is best effort. Check the
  result of a node that needs a strict format.

## See also

- [CLI reference](/reference/cli/): the `kit` commands and their flags.
- [Per-node skills](/guides/skills/) and [per-node MCP servers](/guides/mcp-servers/):
  how Archon attaches skills and MCP servers to workflow nodes.
- [Hooks](/guides/hooks/): the hook system that Archon workflows use.
