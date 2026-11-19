---
applyTo: "**"
---
<!-- Ported to Claude Code from templates/GENERAL.template.md in the agentic blueprint (Copilot original: .github/). -->
# General — backstop

> **The ground rules live in the root instruction file**, `.claude/CLAUDE.md`: the
> constitution digest (P1–P8), the STOP list, how work moves, and where the project facts are. That
> file is preloaded at conversation head. **If it is not already in your context, open it now and
> read it before doing anything else** — everything below assumes it.
>
> This file exists only as a backstop for a harness that reads `.claude/rules/` but not the
> root instruction file. It restates the two rules that are unsafe to miss and nothing
> else; do not let it grow back into a second copy of the ground rules.

- **STOP and get a human decision** before a contract push, a database migration once a production database exists
  (none yet), anything touching authentication/authorization/the access matrix, encryption or what gets logged where
  personal data could be involved, deleting a branch/worktree/history/the audit trail that is not all in main, secrets,
  production config once something runs in production, or a push to main the owner did not allow (except a ticket,
  retro or token-report commit inside its own path: `push-guard.sh` holds the list). An approval binds
  only as an entry `stop-approve.sh record` wrote in `.archon/stop/approvals/` from the owner's own chat words (the list
  round, at most 7 days, `stop-check.sh` judges it); an item not approved holds the merge. One exception: a
  `build-feature` run's own steps, which the owner approved in advance (2026-10-17, `docs/memory.md`): its GitHub
  agent rebases the run's own branch onto main on a conflict and force-pushes it with a lease, and the run deletes its
  own branch and worktree after the merge. The run never merges: the merge script does when nothing is unapproved, or
  the owner (2026-10-18, TASK-58; 2026-10-20).
  Approval is per action, not per session, and silence is not approval. Everything else is ordinary
  work — do it. None of the above is caught by a green build: a dropped column and a leaked personal identifier
  both pass CI.
- **Hand off via checked-in MD files** in the ticket's docs folder, and **report what the work tree
  shows, not what you intended** — the claim is checked against the tree, and CI enforces it on the PR.

Full rules → `.claude/CLAUDE.md` · project facts → `docs/project-profile.md`

