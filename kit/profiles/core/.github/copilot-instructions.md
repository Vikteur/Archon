# GitHub Copilot CLI: instructions for this repo

`AGENTS.md` and `.claude/CLAUDE.md` bind you exactly as they bind Claude: the constitution (P1-P8), the STOP list and
"how work moves". Read them; nothing here overrides them. `.github/instructions/` applies to the files you edit.

You read `.github/skills`, `.github/agents`, `.github/instructions` and the hooks in `.claude/settings.json` and
`.github/hooks/*.json` like any Copilot CLI session. Claude-only mechanics do not exist for you: the Agent tool (do a
subagent's job yourself, following its file in `.github/agents/`, or run it as `--agent <name>`).
The rules they enforce still hold; the gates (`commit-msg` hook, local CI by commit SHA, `tdd-check`) and the run guard
(`.archon/copilot/hooks/run-guard.sh`) are what catch you.

## Building a ticket with Copilot

Do not build a ticket in this chat. Use the `archon-cli` skill (`.agents/skills/archon-cli/`) and run the Copilot
variant of the build workflow from the main checkout, detached:

```bash
archon workflow run build-feature-copilot --detach "TASK-n"
archon workflow status                 # active runs
archon workflow attention --watch --json   # decisions and run ends (one stream, as a background task)
archon workflow get <run-id> --json    # one run
archon workflow approve <run-id> "<text>"   # or: reject <run-id> "<reason>" / respond <run-id> <choice> "<text>"
archon workflow resume <run-id>        # a failed or paused run
```

The run asks its blocked questions through `attention`; answer them from the ticket and `docs/memory.md`, and ask
the owner when you do not know. Never merge: the run stops once for a person to approve the plan and ends when its pull request is ready, and a team member reviews and merges it. The run tooling follows `BUILD_WORKFLOW` (default `build-feature`). Setup of this kit:
`.archon/copilot/README.md`.
