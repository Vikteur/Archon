---
name: contract-agent-readiness
description: Check an OpenAPI contract for what an agent must know before it calls an operation (can it be undone, what else goes with it, how to learn it finished, which look-alike to use instead, why it failed) and give every operation a verdict, wrap, describe or redesign. Use before exposing an API to agents as tools, or after a contract change that adds or rewrites a write operation.
---
# Contract agent-readiness

## When to use
An agent picks an operation and calls it knowing only what the contract says: its name, description, parameters,
answers and errors. A person fills the gaps from experience; an agent guesses, and a guess on a destructive call is
expensive. Use this before an API is exposed to agents (an MCP server, a tool list, a search-and-execute surface), when
a contract change adds or rewrites a write operation, and to decide which operations an agent may get at all.

## How
- **Run the script, never judge by reading** — `scripts/contract-agent-readiness.sh --spec <openapi.yaml> --map
  <map.json>` writes a JSON report and a Markdown one. A model reads the summary and the findings, not the spec.
- **Read the verdicts** — `wrap`: the contract already answers what an agent needs; expose the operation as it is.
  `describe`: an error or a warning is open; its description must answer more first, which is a contract change, not
  code. `redesign`: no description makes it safe; a person confirms it outside the agent (a confirmation screen, a
  second factor), or it is split into prepare → inspect → execute with a plan id, or it stays out of the agent's tools.
- **Reshaping is not a verdict** — putting several operations behind one tool that matches an intent ("diagnose",
  "plan the evening") is a choice across operations, not a property of one. The report's tags and tool budget feed
  that choice; make it in the design of the agent surface, not in the contract check.
- **Know what each rule asks** — an operation destroys when it is a DELETE, or a write whose summary or id says delete,
  remove, erase, revoke, unlink, withdraw, forget and the like. It must answer `reversibility` (error: can it be
  undone, and with which operation, or that it cannot), `blast-radius` (warning: what else goes, what stays),
  `look-alike` (error: each operation the map groups it with, named, with when to use it instead) and `alternative`
  (info: when not to use it). Every operation answers `completion` (error: a 202 says how to learn the outcome, or that
  there is none), `error-cause` (warning: a listed error status gives its cause), `thin-description` and
  `param-undocumented` (warnings). `single-step-irreversible` (info, redesign) is a permanent call that takes more than
  the one object and has no confirmation input or prepare step; `human-confirm` (info, redesign) is the map's call.
- **Put judgement in the map, not in code** — `lookAlikes` (groups an agent can take for one another), `humanConfirm`
  (`<operationId>` or `tag:<tag>` with the reason; it matches every non-GET), `accept` (one finding per operation and
  rule, with its reason; it drops to info), `minWords`, `explainStatuses`. An entry that names an operation, a tag or a
  rule the contract lacks is a `map-stale` error, so the map cannot rot silently.
- **Read the tool budget** — the report estimates what one tool per operation costs on every request: in total, for
  the reads alone, per tag, and the largest tools. Use it to choose how the API reaches an agent: a few tools as they
  are, a scoped subset per agent, or a search → doc → execute surface whose cost does not grow with the API.
- **Fix in the contract** — a `describe` finding is fixed by a description in the contract; the report's `fix` says
  what to write. A `redesign` finding is fixed by a new operation shape or by a person in the loop.

## Pattern signals (discovery cues — how the scanner recognizes this in any codebase)
- An OpenAPI document about to be turned into agent tools, one tool per operation.
- Destructive operations whose descriptions say what they do but not what it costs: no undo, no cascade, no
  look-alike named.
- Asynchronous operations (202) that never say how the caller learns that they finished.

## Project specifics → see docs
- Code map (contract location, map file and its decisions, how to run, last run) →
  `docs/code-maps/contract-agent-readiness.md`

## Guardrails (what NOT to do)
- Don't edit the contract because a finding says so: the contract has one owner, and a change to it goes through its
  own workflow, with a human decision first when it could break a consumer.
- Don't silence a finding with `accept` to make the report clean; accept only what the operation's nature justifies,
  with the reason written down.
- Don't expose a `redesign` operation to an agent before its confirmation step or its new shape exists.
- Don't read a clean report as proof that agents use the API well: it checks what the contract says, not what a model
  does with it. Behavioural tests answer that: fixed prompts, run on several models and harnesses, judged by the calls
  they make.
- Don't hand the full report to another agent; hand its summary and the findings that concern that agent.

## Definition of done
- [ ] The script ran on the current contract with the project's map; both reports exist.
- [ ] No `map-stale` error.
- [ ] Every `error` and `warning` is fixed in the contract, accepted in the map with its reason, or handed to the
  contract's owner.
- [ ] Every `redesign` operation is kept out of the agent's tools, or has its confirmation step.
