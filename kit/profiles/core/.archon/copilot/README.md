# Copilot CLI kit

Runs this repo's build workflow, `build-feature-copilot`, on the GitHub Copilot CLI. Copilot CLI only, never VS Code.
The workflow ships with the kit, and a kit update replaces it only while it is unedited: change it in the kit, not here.

## What Copilot reads (Copilot CLI 1.0.114, `copilot help config`)

- Skills: `.github/skills`, `.claude/skills`, `.agents/skills`, then `~/.copilot/skills`, `~/.agents/skills`. The repo's
  `.claude/skills` and `.agents/skills/archon-cli` load as they are; no copies.
- Instructions: `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/**`, `.github/copilot-instructions.md`.
  `.github/copilot-instructions.md` is the short Copilot-side note (Claude-only mechanics do not apply; how to drive a run).
- Agents: `.github/agents` and `.claude/agents/`. Hooks: Claude Code event names in `.claude/settings.json` run on matching Copilot events;
  repo hooks in `.github/hooks/*.json` too. `.github/hooks/archon-run-guard.json` registers `hooks/run-guard.sh`, which
  refuses unsafe shell commands (no-verify, push to main, the main checkout, `backlog task` unless the kit config says
  `backlog: false`) inside an Archon run worktree only, and inside a run or a node any write to a hook folder
  (`.github/hooks`, `.archon/copilot`, `.claude/hooks`, `.archon/githooks`, `.githooks`, `.git/hooks`; reading stays
  allowed). The file is in
  Copilot's native `preToolUse` format. `-p` runs skip repo hooks in an untrusted folder: trust `~/.archon/workspaces` once
  ("Yes, and remember this folder") or copy `.github/hooks/archon-run-guard.json` into `${COPILOT_HOME:-~/.copilot}/hooks/`.
- Hook input: preToolUse comes batched, `{cwd, sessionId, toolCalls: [{id, name, args}]}`; `.github/hooks/dispatch.sh`
  runs each hook once per call and `hooks/run-guard.sh` checks every call. Tool names map through `tools.json`, and
  every guard and matcher reads them in any case (`monitor` is `Monitor`).
  [baseline.md](baseline.md) has the payload shapes and the per-node time and tokens of two real runs.
- Fences per node (owner decision 2026-11-20): Archon sets `ARCHON_NODE_EXECUTION` (its `path` names the node) and
  `WORKFLOW_ID` for a node's whole Copilot session, and both reach the hooks. `hooks/run-guard.sh` then enforces the node's
  own `denied_tools`, read from the run's workflow (Archon's snapshot of the run, else `build-feature-copilot.yaml`), in
  every session, not only in run worktrees: Copilot itself keeps only the plain tool names of that list and drops the
  `Bash(...)` patterns. `dispatch.sh` names the node (`KIT_NODE`, the last segment of the path) and
  `.claude/hooks/scripts/scope-guard.sh` fences each call as the agent [node-fences.json](node-fences.json) maps the node
  to (explore and plan analyst, write-tests test-writer, build-step and fix developer, review and pr-text reviewer,
  diagnose debugger), with only the additions that node's prompt needs. A node not in that file gets the strictest
  common set, and a node path, workflow, list or file a guard cannot read denies the call. No node fence lets a node
  write a hook folder, and the audit records of a node name it (`agent` and `node`, where they said `main`). The
  `.archon/scripts/test/node-fence.test.sh` suite covers both guards.
- Known limit, not fixed: a `preToolUse` hook that outruns its `timeoutSec` fails open on Copilot CLI (measured on
  1.0.78), and a non-zero exit denies. The guards are kept fast for that reason (scope-guard denies a command longer
  than `SCOPE_GUARD_MAX_CMD` instead of reading it slowly): keep any guard you add fast too.

## Set up (owner, once)

1. `copilot`, then `/login`; `/model` lists the model ids your plan offers.
   Or put `COPILOT_GITHUB_TOKEN` in `~/.archon/.env` (never in the repo). `archon ai login` has no Copilot flow.
2. Edit the `-copilot` aliases in `.archon/config.yaml`: the one place model ids live.
3. `archon validate workflows build-feature-copilot`
4. `archon workflow run build-feature-copilot --dry-run --default-stubs`
5. `archon workflow run build-feature-copilot --detach "TASK-n"`, or ask Copilot to use the `archon-cli` skill.
   Watch with `archon workflow status` and `archon workflow attention --watch --json`.

## Another repo

`archon kit add <path>` in the Archon fork generates the kit for another project from this one, and writes its
`.archon/kit.yaml` (the keys are in [docs/archon/script/kit-config.md](../../docs/archon/script/kit-config.md)). This
repo is the source of the kit; there is no installer here. `hooks/run-guard.sh` also enforces an optional
`.archon/copilot/deny.json` in every session (the kit writes it from the target's deny patterns).
