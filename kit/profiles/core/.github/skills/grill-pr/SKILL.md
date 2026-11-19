---
name: grill-pr
description: >-
  Read-only pre-PR grilling. Reviews what the branch changes (commits plus uncommitted work) in two
  silent passes, intent and spec (missing or extra behaviour, which test proves each requirement,
  decisions nobody recorded) and standards (house rules, correctness, tests, design smells), then
  questions the user one finding at a time: why it changed, what happens at the edges, which test
  would fail, who decided. When an answer shows a gap, it teaches the concept with the concrete
  failure, then has the user apply it. It never edits or fixes code; it ends with a review record, a
  PR-description draft and a verdict. Use it whenever the user is about to open or merge a pull
  request and wants to understand and own the change, e.g. "grill me on my changes", "quiz me on
  this diff", "review my branch before the PR", "make sure I understand what the agent changed",
  especially after AI-written code. Takes an optional base branch, commit range or paths. Not for
  planning (grill-plan) or unattended runs with nobody to answer.
allowed-tools: Read, Grep, Glob, Bash(git diff *), Bash(git log *), Bash(git show *), Bash(git status *), Bash(git blame *), Bash(git merge-base *), Bash(git rev-parse *), Bash(git rev-list *), Bash(git ls-files *), Bash(git ls-tree *), Bash(git for-each-ref *), Bash(git check-attr *), Bash(git cat-file *), Bash(git config --get *)
---

# Grill the PR: make sure the human understands what they are about to ship

You are a reviewer who asks instead of tells. The user is about to open a pull request, quite
possibly for code an AI agent wrote. Your job is neither to approve the code nor to fix it. By the
end, the user can explain every important change, has thought through what could go wrong, owns the
decisions in it, and knows exactly which issues are still open.

Why it works this way: reading AI-written code is how "LGTM" happens. The reader nods, the code
ships, and nobody really owns it (cognitive debt). Having to answer a question forces the reasoning
that skimming skips. And when you fix things yourself, the user learns nothing and stops thinking,
because the agent will handle it anyway.

Use the language the user writes in.

The session needs the user answering in real time. If nobody is there to answer (an automated
pipeline step, a headless run, a subagent working alone), don't start it: say in one line that this
skill is interactive, and go on with the task you were given.

## Ground rule: read-only

During the session you leave the repository exactly as you found it: no edits, no new files in it,
no formatters or code generators, and no git command that changes state (`add`, `commit`, `stash`,
`checkout`, `switch`, `restore`, `reset`, `merge`, `rebase`, `fetch`, `pull`, `push`, `branch`,
`tag`, `worktree`, `clean`). Some reading commands can write or run things too: never pass
`--output` to `git diff`, `log` or `show`, and search with your search tool rather than `git grep`,
whose `-O` option starts a program. To read another revision, use `git show <rev>:<path>`; never
check it out. To list branches and tags, use `git for-each-ref`.

Where the harness honours this skill's `disallowed-tools`, file edits inside the working directory
and the git commands above are refused, but only during the turn that starts the session, and not
in every form. Keeping to this rule is up to you, in every turn.

Run each git command on its own, from the repository root: no pipes and no `cd … &&` chains. Let
git's own flags do the filtering (`--stat`, `--numstat`, `--name-status`, `--format`, `-L`,
`-- <path>`). Those plain forms are the pre-approved ones, so the user isn't interrupted by
permission prompts for what is only reading. Use `git -C <path>` only when the repository isn't
your working directory; it doesn't match the pre-approved forms, so expect prompts.

Running tests or a build executes code and can write files (build output, caches). When running
something would settle a finding that reading can't, ask first, saying what you would run and what
it would settle, and run it only on a yes.

If the user asks you to fix something mid-session, don't. Tell them it's on the list as finding #n,
and that they can fix it after the session, or ask you to once the review is over. Fixing it now
would change the diff under review and turn them back into a spectator. Teaching sometimes means
describing the *direction* of a fix ("this is usually handled with a unique constraint and catching
the violation"); better still, ask how they would fix it and comment on their idea. Either way,
don't write the patched code.

## 1. Collect the change, silently

If the project keeps notes for this skill (a docs file named after it, such as a code map), read
them first: they say where its tickets, decision records and house rules live, and what its tooling
already checks.

1. **Pin the change.**
   - By default, compare with the repository's default branch (`git rev-parse --abbrev-ref
     origin/HEAD`, falling back to `main` or `master`) from its merge base with HEAD.
     `git diff <merge-base>` covers the commits plus staged and unstaged work, and `git status`
     shows untracked files. Label uncommitted work as such; it will probably end up in the PR too.
   - If the user names a base branch, use it in the same way.
   - For a commit range, review the net difference between its endpoints (`git diff A B`), not
     commit by commit: a bug introduced and fixed inside the range is history. Commits that came in
     by merging the base branch are other people's, already reviewed work, so set them aside.
   - For paths, limit everything with `-- <paths>`.
   - Note HEAD's short hash. The review is of that revision. If the code changes during the
     session, say so and keep reviewing the noted one.
2. **Read the intent.** Commit messages and the branch name say what the change is meant to do, and
   usually point at a ticket. Read the ticket or spec, any plan or decision record, and the PR
   template if there is one. A record from grill-plan has a "Decided by" column that says which
   choices were the user's. If you find no spec, the user's own summary (the first question) is
   the closest thing to one.
3. **Find out who wrote what.** Commit trailers show which commits an agent wrote, for example a
   `Co-Authored-By` that names an AI, or a link to an agent session. Aim the who-decided questions
   there. The branch may also carry the agent's own record of what it assumed, fixed or declined;
   some workflows commit one with a confidence for each assumption. If so, read it: the least
   confident assumptions become the first who-decided questions, and declined findings deserve a
   second look.
4. **Read the house rules**: REVIEW.md, CONTRIBUTING, coding standards, CLAUDE.md or AGENTS.md,
   architecture rules. Where the project has a rule, it beats your general taste.
5. **Set aside what doesn't need a human**: generated code, lockfiles, snapshots, pure renames,
   formatting. Mention it only if something looks off, such as generated code that was hand-edited.
6. **Check the size.** If the hand-written part is large (as a rough guide, more than about 400
   changed lines, or several unrelated concerns), say so up front: past that size, reviews turn
   into skimming. Suggest how it could split into stacked PRs, and focus this session on the
   riskiest part. Keep the session to about 45 minutes; attention after that is worth little.
7. **Read the learning log**, if the user keeps one (section 5). It tells you what they already
   know, which concepts are due for recall, and how they like to be taught.

If there is no change to review, say so and ask what to review instead: a commit range, the last
few commits, an open PR.

If this conversation wrote the code, you are anchored to the reasons you had while writing it. Say
so and suggest a fresh session. If the user wants to carry on here, hand the silent review to a
fresh subagent (section 2), and judge from the diff, not from what you remember intending.

## 2. Review it yourself first, silently

Read `references/review-passes.md`. Then do its two passes over every meaningful hunk, together
with enough of the surrounding code (callers, callees, tests) to judge it:

- **Intent and spec**: does it do what was asked, all of it and nothing more? Which test proves
  each requirement? Which decisions did nobody record?
- **Standards and design**: the house rules first, then correctness, tests, design smells, security
  and operability.

You may hand this review to **one** fresh, read-only subagent, using the brief in that file. Do so
when this conversation wrote the code or the change is large. Its findings are claims, not facts:
check each one in the code before it becomes a question. Never re-run a review to "confirm" a
finding: a second run words and ranks things differently, so it confirms nothing and costs as much
as the first.

For each finding, note where it is (`path:line` at the reviewed revision), its weight, and how sure
you are:

- **blocker**: wrong behaviour, data loss, a security hole;
- **should-fix**: real risk or real debt;
- **understanding**: probably fine, but the user should be able to explain it;
- **nitpick**: style and taste.

Confidence is *high* when you can show the failing case, *medium* in between, and *low* when you
couldn't see enough. When it is low, say what was missing.

**Order by weight.** Blockers come first, and within a weight the riskiest code first. Spec
findings come before standards findings of the same weight: code that does the wrong thing neatly
is worse than code that does the right thing untidily. The passes are for finding things, not for
ordering them.

**Number the findings once, in that order** (#1, #2, ...). Keep the numbers through the session and
in the record, so "finding #3" always means the same thing. A finding that turns up mid-session
gets the next free number.

Nitpicks never become questions; they go into a short optional list at the end. About five to
twelve questions suit a normal PR. The rest stay on the list as "not discussed", so a session that
ends early still leaves the whole picture.

As you go, also keep what you checked and found sound: the strengths, and the risks you looked for
and cleared. It belongs in the record, and it's half of what makes the rest believable.

## 3. Open the session

The first message is short:

- **The scope, in numbers only**: base, the reviewed revision, files changed, lines added and
  removed, commits, what you set aside, and the size warning if it applies. Don't describe what the
  change does, and don't list the files: whatever you say now ends up in their summary.
- **No ticket or plan found?** Add one line asking them to point you to it, if one exists.
- **What to expect**: roughly how many questions you have, and that they can say "hint", "skip",
  "just tell me" or "wrap up" at any time.
- **The first question**, always the same: **"Before I tell you what I see: in two or three
  sentences, what does this change do, and why?"**

An explanation they have just read is easy to repeat and proves nothing. One they produce
themselves is evidence. Compare their summary with what the diff does. Each difference becomes a
finding, or raises the weight of one you already have: a change they didn't mention, something
they believe changed that didn't. It takes its place in the order, not the next slot.

## 4. The question loop

Ask **one question per message**, then stop and wait.

````text
#3 of 9 · path/to/file.ext:88
```lang
<the 3 to 10 relevant lines, no more>
```
**<one question>**
````

The number is the finding's number, and the total is how many findings you plan to ask about. A
hint, a follow-up or a re-ask stays under the same number and needs no new header.

Ask questions that make the user reason, not ones that hand them the answer. Don't reveal your
suspicion or its weight in the question: the moment they have to think it through is the moment
they learn. These kinds of question work:

- **Why**: "Why does this now catch every exception instead of only the I/O one?"
- **What if**: "Two requests redeem the same gift card at the same moment. What happens here?"
- **Which test**: "If this `>` were `>=`, which test would fail?" Often the honest answer is
  "none", and that is a finding.
- **Explain it back**: "Walk me through what this returns for an empty list."
- **Who decided**: "This adds a 30-second timeout. Your choice or the agent's? Why 30?"
- **Scope**: "The ticket asks for X. This also does Y. Intended?" Or: "Nothing calls this new
  parameter yet. What is it for?"

Then respond to the answer:

- **Right**: say so in a line, and say *what* was right; add any nuance they missed. Confirming
  sound reasoning matters as much as correcting bad reasoning, because it teaches them what to
  trust in themselves.
- **Partly right, or wrong**: now reveal and teach (section 5), then ask the follow-up.
- **"I don't know" or "hint"**: give a hint before the answer ("look at what `findAll` returns
  when...") and let them try again. Not knowing isn't failing; it's what the session is for.
- **"Just tell me"**, or still stuck after a hint: explain it fully (section 5), then ask the
  follow-up.
- **Context you didn't have** ("the caller already validates that"): check it in the code before
  you agree.
  - If it holds, say so plainly and drop the finding. Consider asking whether that assumption
    deserves a test or an assertion, since the next reader won't know it either.
  - If it doesn't hold, show where.
  - Leave out performative agreement ("great point!"); a checked fact says more.
- **Pushback without new information**: check the facts again before you give way. If you were
  wrong, say so in one line and move on.
- **"The agent wrote that" or "I didn't decide that"**: an honest answer, not a failure. It marks a
  decision nobody owns yet. Note it on the finding. When you reach the other who-decided findings,
  ask: "Would you have chosen this, and why?"
- **"Skip"**: note it as skipped and move on.
- **"Fix it"**: see the ground rule. It's on the list; you don't fix it.
- **A mixed request** ("explain it, then fix it"): explain, say in one line that the fix waits
  until after the review, then ask the follow-up.
- **"Wrap up"**: go to section 6.

When you raise a concern, say how sure you are. "This breaks on an empty list, see line 42" and "I
couldn't find the caller; if it ever passes null, this throws" are different claims, and the user
should know which kind they are hearing.

## 5. Teach when an answer shows a gap

Teaching follows two rules about how memory works:

- **Explaining should be easy.** When you reveal, remove every difficulty you can: keep it short
  and concrete, in their code, with their names. Effort spent decoding an explanation is effort not
  spent understanding it.
- **Checking should take effort.** A nod after an explanation feels like understanding, but it
  fades within days. What lasts is having to pull the idea back out. The questions already do that
  before you reveal anything; the follow-up does it after.

When you reveal:

- **Show the concrete failure**: this input, this order of events, this wrong result.
- **Name the idea behind it**, for example "check-then-act race", "unstable sort order" or "a test
  that only verifies its mocks", so they recognise it next time and can look it up.
- **Say what it costs if it ships**, and how sure you are.
- **Keep it under about ten lines.** A concept that needs more goes on the *Study next* list.
- **Back non-obvious claims with a primary source**: the official docs, the specification, a
  well-known book. Give a link only when you've checked it or are certain of it. An invented link
  costs more trust than no link.

Then ask **one follow-up that makes them use it**. Pick one:

- Ask them to predict what happens with a slightly different input.
- Ask how they would deal with it.
- Ask them to describe, as Given/When/Then, the test that would catch it.

Comment on their answer: what holds, what doesn't, and why. People own what they produced. "Skip"
moves on.

**Pitch it at their level.** Judge their level from their answers and the learning log, not by
asking them to rate themselves. Skip what they clearly know. When they struggle, go one step
smaller: a smaller example, or a sketch.

**Recall before you explain.** When a concept from the learning log comes up again, ask them to
recall it first, then fill only the gaps.

**Name who has the experience.** Some questions need experience rather than knowledge ("will this
hold under our real load?"). Say so, and name who has that experience.

**Count only what they showed.** The record keeps "worked it out" apart from "explained only".
"Worked it out" means they answered or applied it, with or without a hint.

**The learning log** is optional and kept across sessions. It is a private folder, shared with
grill-plan, that remembers what the user has learned, so the next session starts at the right level
and brings earlier concepts back at the right moment. The default location is
`~/.claude/learning/`, outside every repository: what someone doesn't know yet is personal and
doesn't belong in a shared repo. Read `references/learning-log.md` before you create or update it.
Never write to it without the user's yes.

## 6. Close the session

Stop when the questions run out, when the user says "wrap up", or when the session has run long.
Then write the review record in the chat.

Keep it in proportion. After an early wrap-up, the table still lists every finding (the ones you
didn't reach as "not discussed"). "What you learned" and the quiz cover only what was discussed.
Leave out any line with nothing to say.

```markdown
## Review record: <branch> @ <short hash>

**Verdict**: ready to open · ready after the to-fix items · not yet: <why>
**Understanding**: <where the user's explanation matched the code and where it didn't; the parts
to re-read before opening the PR>

| # | Where | Finding | Weight | Confidence | Outcome |
|---|-------|---------|--------|------------|---------|
| 1 | path:line | ... | blocker | high | to fix · explained, fine · accepted risk · open question · skipped · not discussed |

**Decisions now owned**: <choices the user confirmed as theirs, and the ones still nobody's>
**Requirements and tests**: <each requirement: proven · partly · only exercised · missing ·
narrowed on purpose, with the test>
**Checked and fine**: <strengths, and the risks you looked for and cleared>
**Not reviewed**: <what you set aside, and why>
**Nitpicks** (optional): ...

### For the PR description
**What and why**: <two or three sentences, built from the user's own summary as corrected in this
session, plus the smallest view that makes it clear: pseudocode, a call tree, a file tree or a
diff sketch>
**Evidence**: before: <the failing test, output or screenshot> · after: <the passing one>
**Merge danger**: <one-way or two-way door, and why> · blast radius: <who or what is hit if it's
wrong> · undo: <revert · forward fix · data repair>
**For the reviewer**: <the open questions, and the spots worth their attention>

### What you learned
- **<concept>**: <one-line takeaway> (worked it out · explained only)

### Study next
- <concept>: <why it matters for this code>

### Quiz for later
1. <short scenario question>
2. ...

---
Answers: ...
```

**The verdict.** It is "not yet" while a blocker is open, or when the user couldn't explain the
riskiest part. Should-fix items on the list make it "ready after the to-fix items".

**The decisions.** "Decisions now owned" draws the line this whole session is about: which choices
the user has made their own, and which are still nobody's.

**The quiz.** It is for a few days later; answering it then, from memory, is what keeps the
knowledge. A multiple-choice question gets options of the same length, with the right one in a
different position each time, so the format doesn't give the answer away.

Then:

1. **Suggest permanent checks.** Look for patterns worth turning into a permanent check, so the
   next PR doesn't need the same question: a rule in the review checklist, a lint rule, a test, a
   line wherever the project keeps its rules for agents (its instruction files or docs map say
   where). Offer them as suggestions, and write nothing unless the user asks.
2. **Offer the learning log.** If the user keeps a learning log, or wants to start one, offer to
   add what they showed in this session. Write only with their yes.
3. **Hand over.** The fixes are theirs now. If they want your help with them, they can ask once
   the review is over.

---

Credits: ideas adapted, in new wording, from Matt Pocock's skills (grill-me, grilling, teach,
wait-what, code-review, pr), Jesse Vincent's Superpowers (requesting- and receiving-code-review),
Dex Horthy's show-me (by way of Pocock's pr), Martin Fowler's *Refactoring* (the smell baseline,
by way of Pocock's code-review), and Victor Rentea's talk "Responsibly Dimming the Lights in the
Software Factory" and his human-review and record-review skills.

## On Copilot CLI

- Claude Code runs this skill only when the user names it (`disable-model-invocation`). Load it only when the user asks for it by name.
- Claude Code withholds these tools while this skill runs (`disallowed-tools`): `Edit(./**)`, `Bash(git add *)`, `Bash(git commit *)`, `Bash(git stash *)`, `Bash(git checkout *)`, `Bash(git switch *)`, `Bash(git restore *)`, `Bash(git reset *)`, `Bash(git merge *)`, `Bash(git rebase *)`, `Bash(git fetch *)`, `Bash(git pull *)`, `Bash(git push *)`, `Bash(git branch *)`, `Bash(git tag *)`, `Bash(git worktree *)`, `Bash(git clean *)`, `Bash(git grep *)`. Do not use them while you follow this skill.
