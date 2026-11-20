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

## Install everything with one command

On a new machine, or for another set of repositories, one script does the whole install.
It assumes Copilot CLI is up to date and logged in. Run it on Linux, macOS or WSL2:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Vikteur/Archon/local/console/scripts/install-copilot-kit.sh) \
  --backend ~/code/portal --frontend ~/code/web --contract ~/code/api/openapi.yaml
```

Use `bash <(curl …)`, not `curl … | bash`: the pipe takes away the terminal, and the
script then cannot log `gh` in for you.

`scripts/install-copilot-kit.sh` does these steps in order:

1. **Checks the input**: the machine, and the paths you gave. A wrong path stops it before
   anything is installed. It then asks for `sudo` once.
2. **Bun**: installs it if it is missing.
3. **Archon**: clones or updates the fork's `local/console` in `~/archon`, then builds and
   installs it with `install-local.sh`. It also adds `~/.local/bin` and `~/.bun/bin` to the
   `PATH` in your shell's rc file.
4. **The contract**: pulls the contract's repository when that checkout is clean.
5. **`archon kit setup`**: runs it with your answers (see the next section).
6. **gh**: runs `gh auth login` if gh is not logged in (only in a terminal).
7. **`archon kit doctor`**: checks the backend.
8. **The commit**: commits the kit on a new branch (`chore/archon-kit`) in each repository.
   It does this only in a repository whose tree was clean before the run, and it never
   pushes.
9. **A dry run**: runs a dry run of `build-feature-copilot`.
10. **The web views**: runs `archon kit web` on the backend: the MCP Inspectors (the codegraph server of each repository
    and the contract server on your contract), the Groma map, the Backlog.md board when it is
    on, and the Archon web UI (`archon serve`, started when it is not running). It opens each
    view in the browser only once it answers, and names a view that does not answer within
    90 seconds. `archon kit web <backend>` does the same later.

When `groma-check` fails on the committed first scan of the Groma map (an element without a
description), the closing list says so: the pre-push check refuses a push until an agent
curates the map (it runs `groma agent-instructions`) and you commit `groma/`.

| Option | Effect |
|--------|--------|
| `--frontend <path>` | Leave it out when there is no frontend. |
| `--backlog` | Use Backlog.md. |
| `--archon-dir <path>` | Use another folder for the Archon clone (default `~/archon`). |
| `--branch <name>` | Use another branch name for the commit. |
| `--no-commit` | Leave the kit uncommitted. |
| `--no-web` | Do not start and open the web views at the end. |
| `--no-smoke` | Skip the dry run of `build-feature-copilot`. |
| `--dry-run` | Check the paths and print the plan, without changing anything. |

A rerun is safe: it updates what is already there. The script ends with a list of its
warnings, and writes its log to `~/.archon/logs/install-copilot-kit-<timestamp>.log`.

## Update a machine with one command

`archon-kit-update` updates a machine that was installed before: Archon, the kit in the
backend and frontend, and the tools. It needs no options, because it reads the repositories,
the contract, the profiles and the Backlog.md answer from the last `archon kit setup`
(`~/.archon/kit-setup.json`). The installer links the command into `~/.local/bin`. On a
machine installed before the command existed, run it once from the clone, or with curl:

```bash
bash ~/archon/scripts/update-copilot-kit.sh
# or
bash <(curl -fsSL https://raw.githubusercontent.com/Vikteur/Archon/local/console/scripts/update-copilot-kit.sh)
```

After that first run, `archon-kit-update` is on the `PATH`. `archon-kit-update --dry-run`
fetches and lists the new Archon commits and the plan, and changes nothing.

`scripts/update-copilot-kit.sh` does these steps in order:

1. **Checks**: the machine, the saved answers, and that no build run is running. A run
   that waits for its plan approval does not count. `--force` updates anyway.
2. **Archon**: fast-forwards the clone to the fork's `local/console`. When there is
   something new, it builds and installs it with `install-local.sh`. It then runs the
   clone's newest copy of itself for the steps below.
3. **The repositories**: pulls the contract, backend and frontend when their tree is clean
   (fast-forward only).
4. **`archon kit setup`**: runs it again with the saved answers. A kit file you edited is
   kept. A kit file the kit no longer ships is removed when you never edited it (see
   [Rerunning and upgrading](#rerunning-and-upgrading)). The step lists every file it
   removed or kept.
5. **`archon kit doctor`**: checks the backend.
6. **The commit**: commits the update on a new branch (`chore/archon-kit-<archon commit>`)
   in each repository whose tree was clean before the run. It never pushes.
7. **The server**: restarts a running `archon serve` with the same arguments, so it runs
   the new build.
8. **The web views**: runs `archon kit web` on the backend, after the restart: the MCP Inspectors (the codegraph server of each repository
   and the contract server on your contract), the Groma map, the Backlog.md board when it is
   on, and the Archon web UI (`archon serve`, started when it is not running). It opens each
   view in the browser only once it answers, and names a view that does not answer within
   90 seconds. `archon kit web <backend>` does the same later.

| Option | Effect |
|--------|--------|
| `--backend`, `--frontend`, `--contract <path>` | Use other paths than the saved ones (`--frontend ''` for none). |
| `--archon-dir <path>` | Use another Archon clone (default: the clone the script is in, else `~/archon`). |
| `--branch <name>` | Use another branch name for the commit. |
| `--no-pull` | Do not pull the repositories first. |
| `--no-tools` | Do not update the tools (jq, yq, gh, node, codegraph, copilot, rtk, ...). |
| `--add-profile <a,b>` | Add profiles to the saved ones, for example `--add-profile mijn-gezondheid` on an install from before that profile. The next update keeps them. |
| `--no-commit` | Leave the update uncommitted. |
| `--no-restart` | Leave a running `archon serve` on the old build. |
| `--no-web` | Do not start and open the web views at the end (`--web`, the old flag, is the default now). |
| `--rebuild` | Rebuild Archon even when the clone is up to date. |
| `--force` | Update even while a build run is running. |
| `--dry-run` | Print what would be updated, change nothing. |

Push the commit branch and merge it like any other change. The log is in
`~/.archon/logs/update-copilot-kit-<timestamp>.log`.

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
| Kit | Installs the kit into the backend, like `archon kit add --trust`, with the profiles `core,java,java-spring,openapi-contract,mijn-gezondheid` unless you pick others. |
| Contract | Sets `contract.spec_path` in the backend's `.archon/kit.yaml` to the absolute contract path and `backlog` to `true` or `false`, then runs `.archon/scripts/contract-mcp-setup.sh`. |
| CodeGraph index | Runs `.archon/scripts/codegraph-setup.sh` for the backend and the frontend. |
| Frontend MCP | Writes the codegraph server into the frontend's `.github/mcp.json` (other servers stay), trusts the frontend folder, and adds it to `codegraph.extra_projects` in the backend's `kit.yaml`. |
| rtk hooks | Runs `rtk init --copilot` in each repository, when `rtk` is on `PATH`. It never installs the global hooks. |
| Groma map | When `groma` is on `PATH` and the backend has no `groma/` yet: `groma init --directory groma <backend name>`, the Java scanner when a `java` profile is installed, and a first `groma scan`. With Backlog.md off it removes the `backlog/` board and the Backlog.md block that `groma init` adds; `AGENTS.md` keeps its Groma block. |
| Servers check | Starts each MCP server of both repositories, as `kit doctor` does. |
| Web views | Runs `bash scripts/web-uis.sh start` in the backend, starts `archon serve` when its health URL does not answer, waits up to 90 seconds for each view, and opens each one that answers in the browser (`wslview`, `explorer.exe`, `xdg-open` or `open`; `WEB_UIS_OPEN` picks another). A view that does not answer fails the step. |

The output of every step goes to a log, `~/.archon/logs/kit-setup-<time>.log`, not to the
terminal. A step that fails is shown as failed with that log path. The later steps still
run, and the command exits 1 at the end.

The last screen lists the web view URLs, a note when the Groma map is a first scan (commit
it, and have an agent curate it when the pre-push check asks), the command that stops them
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
| `--profile a,b,c` | The kit profiles (default: the last run's, then `core,java,java-spring,openapi-contract,mijn-gezondheid`) |
| `--backlog` | Use Backlog.md for tickets; leave it out for off (`backlog: false` in `kit.yaml`) |
| `--yes` | Skip the confirmation |
| `--no-tools` | Skip the tool installer |
| `--no-rtk` | Skip the rtk hooks |
| `--no-web` | Do not start or open the web views (`archon kit web` does that alone) |

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
| Scripts | `.archon/scripts/`, `scripts/` | Run, CI-by-SHA, pull request, retro and tool installer scripts. There is no ticket picker, night run or merge queue: a person starts each run and a team member merges. |
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
| `mijn-gezondheid` | `java-spring`, `openapi-contract` | A project profile: that project's own scaffold templates, their `## Scaffold` table and `scaffold.json` in `docs/scaffold-templates/project/`. `scripts/scaffold/new-context.sh`, `smoke.sh` and the wiring check run on them as installed. A template you edit is kept on the next update. |

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
| `profiles` | `[core, java, java-spring, openapi-contract, mijn-gezondheid]` | The profiles installed. `kit add --profile` replaces this list. |
| `stack` | `spring` | `quarkus` or `spring`. The gates that differ per framework branch on it. |
| `base_branch` | `main` | The branch that runs target and rebase against. |
| `gh_accounts` | `[]` | The `gh` accounts the `gh-switch-account` skill switches between. |
| `agent_cli` | `copilot` | `claude` or `copilot`. `install-tools.sh` and `kit-config.sh` use it. |
| `build_workflow` | `build-feature-copilot` | The build workflow you start for a ticket. |
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
  --set contract.repo=acme/contract --trust
```

`kit add` records each `--profile` and `--set` in `kit.yaml`. It keeps the rest of your
text, including comments, as it is. Commit the file.

## Rerunning and upgrading

`kit add` writes `.archon/kit.lock.json`. The lock maps each written path to the SHA-256
of what the kit wrote. On a rerun, `kit add` compares each file with the lock:

- A file that still holds what the kit wrote is updated to the newer kit.
- A file the project edited is kept. The command lists it as `kept (differs)`.
- A file the lock records that the newer kit no longer ships is removed, with the folders
  that are then empty, when it still holds what the kit wrote. If you edited it, it is kept
  and listed as `kept (no longer in the kit)` on every run, until you remove it.
- `.archon/config.yaml` counts as the kit's after `kit add` merges its aliases and file hooks
  into it, so a newer kit still updates it.
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

## Running a build

Start one run per Backlog ticket:

```bash
archon workflow run build-feature-copilot --detach "TASK-12"
```

The run plans the ticket and then **stops once for a person to approve the plan**. The
`plan-approval` step shows the ticket, the plan (`plan.md` in the run's artifacts) and the
STOP items the ticket or the plan touches. Answer it in the Archon console, or:

```bash
archon workflow attention --watch          # the runs that wait for you
archon workflow approve <run-id> "notes for the agents"
archon workflow reject <run-id> "why"      # ends the run; no code is written
```

The approval text reaches the agents as reviewer notes. After a rejection, fix the ticket
and start a new run. Run builds in a worktree: a run in a container cannot pause for the
approval.

After the approval the run builds the parts, opens a draft pull request, checks CI by
commit SHA, fixes a red run (at most three rounds) and marks the pull request ready for
review. **The run ends there; it never merges.** A team member then:

1. reviews and merges the pull request;
2. closes the Backlog ticket and commits the backlog change (the run leaves its ticket
   edit uncommitted in the backlog checkout);
3. runs `bash .archon/scripts/cleanup-merged.sh <branch>` to delete the run's branch and
   worktree. It deletes nothing that is not in the base branch, so it refuses a squash
   merge; merge with a merge commit or a fast-forward, or delete them by hand.

A red head or a merge conflict at the ready step fails the run, so a person sees it. To
stop a run that waits, `bash .archon/scripts/stop-run.sh <run-id> "<why>"` rejects it and
keeps the reason. A run that stops on a `BLOCKED:` question fails and names its plan;
answer it with `bash .archon/scripts/answer-blocked.sh <plan.md> "<answer>"`, then
`archon workflow resume <run-id>`.

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
- **An organization's MCP registry policy.** A Copilot account whose organization sets an
  MCP registry allows only the servers that registry lists. Copilot then says
  `2 MCP servers were blocked by policy: 'codegraph', 'contract-api' (Not found in registry <url>)`.
  The servers themselves work (the setup's servers check starts them outside Copilot), and
  Copilot's logs do not record the block, so `kit doctor` cannot see it. Its admin has to
  allow them. Until then, the kit's agents and the build workflow's nodes fall back to the
  same functions through the CLIs, which the agents' Bash allowlists (and `agent-scopes.json`)
  permit:
  - CodeGraph, read-only: `codegraph explore "<question>"`, `codegraph node <symbol>`,
    `codegraph callers <symbol>`, `codegraph callees <symbol>`, `codegraph impact <symbol>`
    and `codegraph query <name>`.
  - The contract server (openapi-contract): `node scripts/contract-mcp/cli.mjs search <words...>`,
    `read <operationId>`, `where <operationId>` (or `--tag <t>`, `--status live|stub|none`),
    `schema <name>` and `usedBy <target>`. It prints the MCP tool's JSON answer.

  Where a CLI fails too, they fall back to file searches, and the build workflow's MCP check
  warns.
- **Structured output.** Structured output from a Copilot node is best effort. Check the
  result of a node that needs a strict format.

## See also

- [CLI reference](/reference/cli/): the `kit` commands and their flags.
- [Per-node skills](/guides/skills/) and [per-node MCP servers](/guides/mcp-servers/):
  how Archon attaches skills and MCP servers to workflow nodes.
- [Hooks](/guides/hooks/): the hook system that Archon workflows use.
