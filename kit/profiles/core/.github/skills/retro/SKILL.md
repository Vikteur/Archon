---
name: retro
description: Review a workflow run's process from its evidence — what happened, where the process failed or dragged, the process decisions taken (one ADR each), the lessons and the improvement actions. Never runs tests or reads code. Use after a run.
---
# Retro

## When to use
After a delivery is merged. A run that hit trouble teaches the most, so it is never skipped once merged. One retro per run; a ticket that needed several runs gets one run section per run in the same file.

## What it reviews
The **process**, not the product: how the work moved through the workflow's nodes, agents, gates and handoffs. The
code's correctness is already decided by the review and CI; the retro never runs a test or a build and never opens
source code, test code, a diff or a build file. It asks of every finding: *what in the workflow allowed this, and
what in the workflow would have caught or prevented it?*

## Inputs
- The **evidence file** the pipeline wrote for this run: node timeline (completed, failed with the error, skipped
  with the cause), each agent's last message, commits, the pull request with its reviews and comments, CI runs, and
  the list of run artifacts.
- The run artifacts and handoff files it lists (the plan, the review reports, the step and gate logs, the red test
  logs as proof of test-first order, a CI diagnosis, the token report): open the ones a finding needs, not all.
- The workflow definition the run executed, and the agents, skills, hooks and rules it used: what the process was
  meant to do, to hold against what it did.
- The ticket folder's existing `lessons-learned.md` and ADRs, so a decision already recorded is not recorded twice.
- To confirm one fact: `gh pr view`, `gh run view <id> --log-failed`, `git log --oneline`, the workflow's own run
  record. Read summaries and failing logs, never code or diffs.

## How
1. **Reconstruct what happened** from the timeline, in order, as facts with their evidence (node, artifact, commit,
   CI run id, review comment). Name the outcome in one word: `merged`, `closed`, `failed`.
2. **Find the process decisions.** A decision is a choice between real alternatives that a later reader would
   otherwise have to rediscover: in the plan's approach, in an agent's message ("chose X because Y"), in a step that
   was redone, in a review comment that changed the plan, in how a CI failure was handled. Ask of each: *would
   someone reverse this without knowing why it was taken?* If yes, it gets an ADR. Routine steps the plan dictated,
   naming, and formatting do not.
3. **Separate what went well from what dragged, and name what failed.** Measure drag in evidence, not mood: a red
   CI round, a node that failed and was resumed, a retry loop, a long-running or expensive node, a test rewritten
   after the build, a reviewer change request, a step redone, a handoff that left the next agent guessing, a gate
   that fired late or not at all, a node whose model did not fit its job, work a model did that a script could do.
   Say what it cost (time, rounds, tokens).
4. **Turn drag into lessons.** A lesson is a rule for the next run, phrased as an instruction about the process
   ("make the review gate run the slice tests before the push, the unit run missed them"), with the evidence that
   taught it. Something tried that did not work is a lesson too: what was tried, why it failed, what to do instead.
5. **Route each lesson to an action.** Prefer the most deterministic home: a script or gate over a skill line over
   a docs line over "remember to". Name the action and its home as a follow-up; do not create tickets or edit the
   framework from the retro. Nothing actionable? Write `None.`
6. **Write the ADRs** for the decisions from step 2, numbered on from the highest existing number in the folder,
   and link every one from the run's `Decisions` section.
7. **Stop at the files.** Do not commit, push or open anything: the pipeline checks the format and commits.

## Templates
`lessons-learned.md` starts with `# Retro — <ticket or run>` once, then gets one section per run, newest last. Every
heading below is required and none may be empty; write `None.` when there is nothing.

```markdown
## Run <first 8 characters of the run id> — <YYYY-MM-DD> — <merged|closed|failed>

### What happened
- <fact, with its evidence: node, commit, CI run id, review comment>

### Decisions
- [ADR-NN: <title>](adr/ADR-NN-<slug>.md) — <one line>

### What went well
- <what to keep doing, with evidence>

### What dragged
- <what cost time or rounds, and how much>

### Lessons
- <a rule for the next run, phrased as an instruction> (evidence: <where it showed>)

### Actions
- <follow-up> → <its home: script, gate, skill, docs leaf, ticket>
```

A run that was **stopped** before its retro (cancelled, or rejected at an approval gate) gets a short section,
written by script from the run's record, not by this skill. Leave it as it is, and read it as evidence when a
later run of the same ticket is retro'd: what was stopped, and why, is often that run's first lesson.

```markdown
## Run <id8> — <YYYY-MM-DD> — <cancelled|rejected>

### What happened
- <the request, the node it stopped at, the node timeline, the run that took over>

### Why it stopped
<the reason given when it was stopped, or that none was recorded>
```

`adr/ADR-NN-<slug>.md`, one per decision, the slug in lower-case words joined by `-`:

```markdown
# ADR-NN: <the decision, as a short statement>

## Status
Accepted (<YYYY-MM-DD>, run <id8>) — or Superseded by ADR-MM.

## Context
<the problem and the forces at play, as the run met them>

## Decision
<what was chosen, stated so it can be followed>

## Alternatives considered
- <option> — <why it was not chosen>

## Consequences
<what gets easier, what gets harder, what is now fixed>

## Evidence
<plan step, commit, pull request comment, CI run>
```

## Ground rules
- **Evidence or it did not happen.** Every line cites where it showed; a claim without a source is dropped.
- **Short beats complete.** A retro nobody reads tightens nothing: a few lines per heading.
- **A superseded decision is not deleted.** Write the new ADR and set the old one's status to `Superseded by
  ADR-MM`.
- **Blameless.** Describe what the process allowed, not who slipped.
- **Where the retro files live**, how they are committed and who reads them → `docs/retro/README.md`.
