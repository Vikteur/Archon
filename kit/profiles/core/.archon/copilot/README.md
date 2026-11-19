# Copilot CLI kit

Runs this repo's `build-feature` workflow on the GitHub Copilot CLI as `build-feature-copilot`. Copilot CLI only, never
VS Code. The workflow is generated from `build-feature.yaml` by `.archon/scripts/copilot-workflow.js`; do not edit it.

## What Copilot reads (Copilot CLI 1.0.114, `copilot help config`)

- Skills: `.github/skills`, `.claude/skills`, `.agents/skills`, then `~/.copilot/skills`, `~/.agents/skills`. The repo's
  `.claude/skills` and `.agents/skills/archon-cli` load as they are; no copies.
- Instructions: `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/**`, `.github/copilot-instructions.md`.
  `.github/copilot-instructions.md` is the short Copilot-side note (Claude-only mechanics do not apply; how to drive a run).
- Agents: `.github/agents` and `.claude/agents/`. Hooks: Claude Code event names in `.claude/settings.json` run on matching Copilot events;
  repo hooks in `.github/hooks/*.json` too. `.github/hooks/archon-run-guard.json` registers `hooks/run-guard.sh`, which
  refuses unsafe shell commands (no-verify, push to main, the main checkout) inside an Archon run worktree only. The file is in
  Copilot's native `preToolUse` format. `-p` runs skip repo hooks in an untrusted folder: trust `~/.archon/workspaces` once
  ("Yes, and remember this folder") or copy `.github/hooks/archon-run-guard.json` into `${COPILOT_HOME:-~/.copilot}/hooks/`.

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
