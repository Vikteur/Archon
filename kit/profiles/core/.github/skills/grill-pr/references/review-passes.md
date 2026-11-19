# The two review passes

Use this file as your own checklist for the silent review. If you hand the review to a subagent,
it is also that subagent's brief (see the last section).

Keep the two passes apart on purpose. Code can follow every rule and still do the wrong thing. It
can also do exactly what was asked while breaking the house rules. Reviewed together, one hides the
other.

## Pass 1: intent and spec

The spec is whatever says what this change should do: the ticket, a plan or decision record, or
the description in the PR template. Failing those, use the user's own summary.

- **Missing or partial**: check each requirement and acceptance criterion. Is it implemented, all
  of it? Quote the spec line.
- **Done wrong**: it is implemented, but does it behave the way the spec says?
- **Extra**: behaviour nobody asked for, such as drive-by changes, unrelated refactoring or scope
  creep. Some additions come "for completeness": a parameter, an endpoint, a configuration option,
  an abstraction with one implementation. Search for their callers. If nothing uses one yet, ask
  whether it is needed now.
- **Where the spec is silent** (empty input, failures, two users at once, what the user sees on an
  error): judge by what a reasonable user would expect. Their expectation is a requirement; the
  spec's silence is not permission. Whatever the code does there was a decision, so ask who made
  it.
- **Decisions taken alone**: choices in the code that no spec or plan mentions. Examples are a new
  dependency, a new pattern, a changed default, a timeout, a magic number, a renamed public name,
  or different error behaviour. In AI-written code, this is where the surprises hide.
- **Requirement to test**: for each requirement, find the test that proves it. Read the test's
  body, not its name. A name says what someone meant to test; the assertions say what is tested.
  Give each requirement one level:
  - *proven*: an assertion checks this requirement's own claim;
  - *partly*: assertions check some of it (say which part they don't);
  - *only exercised*: a test runs through the code but asserts nothing about the claim;
  - *missing*: no test reaches it;
  - *narrowed on purpose*: the change delivers less than the requirement, and a recorded decision
    says so.

  Some rules for choosing the level:
  - A requirement that lists several things is several claims.
  - "Still works" and "unchanged" claims are the hardest to prove. Only a test that asserts the
    preserved behaviour proves them; one that merely uses the feature doesn't.
  - Prove a requirement at the layer it talks about: a backend test doesn't prove what a screen
    shows.
  - When in doubt between two levels, pick the lower one.
  - If nearly everything comes out proven, you are probably reading test names, not bodies.

## Pass 2: standards and design

**House rules first.** The project's documented rules beat your taste and the baseline below. Where
the project endorses something the baseline would flag, drop the flag. Skip anything that tooling
already enforces (formatters, linters, CI gates): a human's attention is wasted on it.

Then look through these lenses:

- **Correctness**: empty, null, boundary and duplicate inputs; error paths; ordering; time zones;
  concurrency and races; transactions; retries and idempotency.
- **Tests**:
  - Would they fail if the code were wrong?
  - Do they exercise behaviour through a public entry point? Those are the tests worth a human's
    reading time. Or do they mostly mock the internals and verify calls? Such tests are coupled to
    the implementation: they break on every refactoring and still miss real bugs.
  - Do the test names read like a specification?
- **Design**: is each responsibility in the right place? Do dependencies point the right way? Does
  the change duplicate something the codebase already has? Search for it.
- **Readability**: names that say what things are, dead code, and comments that no longer match the
  code.
- **Performance**: N+1 queries, unbounded loads, I/O inside loops.
- **Security and privacy**: input validation, authorisation on new entry points, injection,
  secrets, personal data in logs.
- **Operability and compatibility**:
  - migrations: are they reversible? Do they lock tables or need a backfill? Are they still safe
    if another branch's migration lands first?
  - API and serialised formats;
  - configuration and feature flags;
  - observability.

**The smell baseline** comes from Martin Fowler's *Refactoring*. Each smell is a judgement call,
labelled "possible <smell>", never a violation:

- *Mysterious name*: the name doesn't say what the thing does or holds. If no honest name comes to
  mind, the design is murky.
- *Duplicated code*: the same logic appears in more than one place in the change.
- *Feature envy*: a method that works more with another object's data than with its own.
- *Data clumps*: the same few values always travel together, a type waiting to be born.
- *Primitive obsession*: a string or number stands in for a domain concept.
- *Repeated switches*: the same switch or if-cascade on the same type appears in several places.
- *Shotgun surgery*: one logical change forces scattered edits across many files.
- *Divergent change*: one module is edited for several unrelated reasons.
- *Speculative generality*: abstraction, parameters or hooks for needs nobody has yet.
- *Message chains*: callers walk `a.b().c().d()`, a path they shouldn't depend on.
- *Middle man*: a class or function that mostly passes calls on.
- *Refused bequest*: a subclass that ignores or overrides most of what it inherits.

## For each finding

- **Where**: `path:line` at the reviewed revision. Point at the line that does the thing, not at
  the start of its method.
- **What**: the problem, and the concrete failing case if you have one.
- **Pass**: intent and spec, or standards and design.
- **Weight**: blocker, should-fix, understanding, or nitpick.
- **Confidence**: high (you can show the failing case), medium, or low (say what you couldn't see).

Keep two more lists:

- **Checked and fine**: strengths, and the risks you looked for and cleared, with where. Accurate
  praise helps the user trust the rest.
- **Set aside**: what you didn't judge, and why (generated code, outside this change, outside the
  spec), one line each. Nothing is set aside silently.

## The subagent brief

To hand the review to a subagent, give it this text with the placeholders filled. Then paste the
sections "Pass 1", "Pass 2" and "For each finding" from this file:

```text
You are reviewing a change before its author opens a pull request. You are read-only: change
nothing in the working tree, the index, HEAD or any branch. Run no tests, builds, formatters or
generators. To read another revision, use `git show <rev>:<path>`. Run each git command on its own,
from <repository root>, without pipes. Do all of this yourself, without starting other agents.

The change: <diff command(s)>; commits: <list>; uncommitted work: <yes or no>.
What it should do: <the spec's location or text, or "no spec found">.
House rules: <files>.

Do the two passes below and report each finding in the format below. Put the two passes under
separate headings; don't merge or re-rank them. Then add "Checked and fine" and "Set aside". Quote
only the lines that matter. Keep it under 700 words.
```
