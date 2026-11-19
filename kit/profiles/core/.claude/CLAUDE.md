# Project ground rules for every agent

> This is the **root instruction layer**: Claude Code and the GitHub Copilot CLI load `.claude/CLAUDE.md` at session
> start, before any file is attached. Path-scoped instructions under `.github/instructions/` (`applyTo:` frontmatter)
> add structural invariants on top of it for the code you happen to be editing; they never replace anything here.
> Installed by the Archon kit (`archon kit add`); the project's own values come from `.archon/kit.yaml`.

## The constitution — non-negotiable (P1–P8)

The supreme law of this framework. Every plan is checked against it, and a deviation is justified in
the plan's `## Complexity Tracking` table — never taken silently.

- **P1 — Lean context is law.** Scope skills per agent and per layer; slice every large artifact
  (plan → per-layer file, spec → tag excerpt, docs → one leaf); one full-reader per artifact; hand
  off summaries, never file dumps.
- **P2 — Determinism over tokens.** Anything a hook or a script can do MUST NOT be done by a model —
  scaffolding, slicing, lint/format, drift checks, codegen, validation.
- **P3 — Generic skills, project docs.** A skill body carries **zero project nouns** (it says *how*);
  every project fact (*what*) lives in a `docs/` leaf. If a skill "needs" a project fact, the leaf is
  missing — add it and link it.
- **P4 — Contract-first.** A contract change lands in the spec and every consuming repo regenerates (DTOs +
  stubs/client) *before* app code. A red build on regenerated-but-unimplemented stubs is the expected
  starting point, not a failing gate. Never hand-edit generated code.
- **P5 — CI is the source of truth.** Every agent may run the tests locally, as often as it helps; a
  part is done only when its CI run is green, fetched by commit SHA. Red ⇒ escalate to the debugger.
- **P6 — Gates are never waived, only reordered or narrowed.** Even an urgent fix keeps branch
  protection and the contract gate. Every workflow ends in a regression test. Recurring human review
  comments become gates.
- **P7 — Architecture invariants hold.** No framework in the domain; dependencies point inward;
  usecase → domain + ports only; adapters hold no business logic. Defended by `arch-fitness`, not by
  reviewer judgment.
- **P8 — Least privilege and declared governance.** Agent and skill manifests are schema-valid; an
  agent that can run commands declares an explicit command allowlist (its entry in `.claude/hooks/agent-scopes.json`,
  enforced by `scope-guard.sh`); capability and cost are
  auditable, never implicit.

## STOP and get a human decision first

Before anything irreversible or security-bearing: say what you are about to do, why, and what it
would take to undo it — then **wait**. Do not proceed on silence, and do not treat an earlier
"continue" as covering a later one of these; approval is per action, not per session. The list is
short on purpose, because a STOP rule people route around protects nothing:

- **pushing a contract change** to the hub repo (@@KIT_CONTRACT_REPO@@), or any spec edit that could break a consumer
  (removed/renamed field or endpoint, narrowed type, new required field, changed status code);
- **a database migration once a production database exists** — then a one-way door over real personal
  data, which a forward-only migration tool will not roll back for you;
- **authentication, authorization or the access matrix**, SSO/SAML/WS-Security config, or
  anything touching how a user is identified;
- **encryption, key handling, or what gets logged** where personal data could be involved;
- **deleting a branch, worktree, history or the audit trail that is not all in @@KIT_BASE_BRANCH@@**, and any
  force-push (`cleanup-merged.sh` deleting what is all in @@KIT_BASE_BRANCH@@ is not one);
- **secrets**, anything that changes what is deployed, and **production configuration** once something runs in
  production;
- **a push to @@KIT_BASE_BRANCH@@** the owner did not allow, except a ticket, retro or token-report commit that stays
  inside its own path (`push-guard.sh` enforces it; its list is the source of truth).

One standing exception, the `@@KIT_BUILD_WORKFLOW@@` workflow: its runs stop once, for a person to approve the plan,
and that approval shows the STOP items the ticket labels or the plan names. An approved run does not pause on them
again: its pull request names them, it rebases the run's own branch onto the base on a conflict and force-pushes it
with a lease. The run never merges its own pull request: it ends once CI on the head is green and the pull request is
ready for review, and a team member reviews, merges it and closes the ticket. The exception covers that workflow's
own steps only: an agent outside it still stops here.

Everything else is ordinary work — do it. This rule exists because none of the above is caught by a
green build: a dropped column and a leaked personal identifier both pass CI.

## How work moves

- **Anything doable via a hook or script must be done that way**, to keep tokens out of the context
  window (branch/folder scaffolding, contract slicing, deterministic gates).
- **Navigate code via the CodeGraph MCP server, not by scanning.** Any agent that reads code uses the
  `codegraph` MCP tools first — `codegraph_explore` (area overview: relevant symbols' source + call
  paths), `codegraph_node` (one symbol / one file), `codegraph_callers` / `codegraph_callees`,
  `codegraph_impact` (blast radius before changing a symbol), `codegraph_search` — instead of
  repo-wide grep or whole-file reads. Same token rule as hooks: pull only the slice you need. Fall
  back to direct reads only when the server or the project's `.codegraph/` index is unavailable, or
  when a CodeGraph staleness banner (⚠️) tells you to read a file directly. **The index is per checkout**
  (`.codegraph/`, git-ignored): `bash .archon/scripts/codegraph-setup.sh` builds it or syncs it, and
  the build workflow runs it in every run worktree. Generated code under `build/` is not indexed: for a contract
  operation or schema, ask the @@KIT_CONTRACT_SERVER_NAME@@ MCP server (when the project has it).
- **Tickets live in this repo's Backlog.md backlog (`backlog/`)** (see `AGENTS.md`: run every
  `backlog` command from the main checkout, and read its `backlog instructions` guides before a task
  lifecycle action). A ticket id in a branch name or a commit subject refers to that backlog.
- **Agents hand off via checked-in MD files only** — written into the ticket's docs folder, the
  single home for everything about a ticket.
- **The OpenAPI contract tag is the cross-repo join key** — it links the per-repo capability
  registers and lets one side point the other side's analyst at the right place.
- **One feature branch name, identical across every involved repo** — created (and checked out
  locally) by the start-feature script off the latest `@@KIT_BASE_BRANCH@@`.
- **A part is "done" only when its CI run is green** — push the finished part to the open PR, then run local
  CI on the pushed head: `bash .archon/scripts/local-ci-run.sh <pr> --head <sha>` (it calls
  `.claude/scripts/ci-local.sh --post`, which posts one `local-ci/<job>` status per job on the commit). Take the
  verdict read **by commit SHA**, `bash .archon/scripts/ci-by-sha.sh <sha>` (through `.archon/scripts/local-ci-status.sh`),
  as the answer; on red, `bash .archon/scripts/local-ci-run.sh --logs <sha>` names the folder with the job logs.
  A test run you start yourself is a fast check, never the verdict.
- **Before a push, run `.claude/scripts/affected-check.sh`, never the full suite locally** — it first merges
  `origin/@@KIT_BASE_BRANCH@@` into a branch that is behind, then runs only the tests the branch's change touches
  (the full suite is `@@KIT_COMMANDS_TEST@@`); CI is the verdict.
- **Report what the tree shows, not what you intended.** A completion claim is checked against the
  work tree by `verify-claims`, and enforced on the PR by CI.
- **Docs cross-reference docs with shortcut reference links** — `[label]` inline, `[label]:
  relative/path.md` definitions collected at file bottom. Plain backticked paths only where the
  target doesn't resolve in the repo (placeholders) — and in **skill/instruction
  bodies**, which keep plain paths so harness auto-attach can't eager-load the leaf.

## Project specifics → see docs

- **What doc goes where** → `docs/README.md`, the docs map, when the project has one. Read it before you write any
  doc; one kind of fact has one home. *(plain references on purpose — linked files eager-load into every context;
  open them on demand)*
- Decisions already taken, and approaches already tried and abandoned → `docs/memory.md` — read it before
  proposing a change that reverses one; the reasoning is not in the code
- How a skill is applied, one leaf per skill → `docs/code-maps/<skill>.md` (see its `README.md`). A leaf marked
  `kind: worked-example` shows the right structure with pseudonymized names: follow the structure, map every name to
  this repo's own, never copy a placeholder. A leaf's `## This repo` section holds this project's facts; fill it in
  where it is still the kit's stub.
- The project's values the scripts read (base branch, contract server and hub, layer module globs, commands) →
  `.archon/kit.yaml`. Retros go in `docs/retro/`, follow-ups in `docs/follow-ups/`; the tickets themselves are in
  `backlog/`.

## Shared mechanisms (not agents, but everyone must respect them)

- **Gates** — deterministic checks that can fail a step (e.g. `declared-files-disjoint`).
- **Hooks** — deterministic guardrails between WORKFLOW → SKILLS → DOCS, run by `.github/hooks/kit.json` under the
  Copilot CLI. In-loop gates **report**; the PR's CI is what blocks. Treat an advisory failure as a real one anyway.
- **Worktrees** — each agent instance works in its own clean worktree; never collide.
