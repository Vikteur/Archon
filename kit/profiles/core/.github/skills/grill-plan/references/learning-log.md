# The learning log

A private folder that remembers what the user has learned, across sessions and across both grill
skills (planning and pre-PR), so that each session starts at the right level and brings earlier
concepts back at the right moment. It adapts the teaching workspace of Matt Pocock's `teach` skill to
learning while building.

## Where it lives, and when you touch it

- Default `~/.claude/learning/`; use another folder if the user names one. Keep it out of every
  repository: what someone doesn't know yet is personal, and a shared repo is the wrong place for it.
- Create it only after the user says yes, and lazily: a file appears when there is something to put in
  it.
- **Read** it when a session starts, cheaply: `MISSION.md`, `NOTES.md`, `PRACTICE.md`, `GLOSSARY.md`
  and the titles of the records. Open a whole record only when its concept comes up.
- **Write** to it only at the end of a session, after one message that lists what you would add, and
  only what the user accepts.

## How it steers teaching

- **Level.** The records say what the user can already do. The concept worth teaching is the one the
  mission needs that sits just above that: hard enough to stretch them, close enough to land.
- **Recall.** When a concept from `PRACTICE.md` or a record comes up again, ask them to explain or
  apply it before you say anything about it. Pulling it back out after a gap of days is what moves it
  into long-term memory; reading it again mostly doesn't.
- **Evidence.** Only what the user showed counts as learned. A concept you explained and they nodded at
  is still "explained only", however well it seemed to land.

## The files

**`MISSION.md`**: why the user wants to learn while they build. Ask for it when the log is created:
"What do you want to be able to do yourself that today you leave to the agent, or to someone else?"
Push for something concrete and observable: "design a feature's data model and defend it in review"
beats "understand databases". Sections: *Why* (one to three sentences), *Success looks like* (things
they will be able to do), *Constraints* (time, how they like to learn), *Not now* (nearby topics they
don't want to chase yet). One screen at most. The mission decides how much a concept deserves: one
that serves it gets a scenario check, one that doesn't gets a single line. When the mission shifts,
propose the new wording and add a record that says why.

**`NOTES.md`**: how they like to be taught ("examples from our own code", "skip the analogies") and
anything else worth keeping in mind. Add to it when they say so.

**`GLOSSARY.md`**: technical terms the user has shown they can use correctly. It records compressed
knowledge; it is not a dictionary to learn from, so a term goes in only after they have used it right.
One or two sentences per term, saying what it *is*; pick one name and list the others as aliases to
avoid; use glossary terms inside other definitions; revise in place when their understanding deepens.
This is not the project's domain glossary, which holds the language of the domain.

```md
**Optimistic locking**:
Detecting a conflicting update when it is written, by checking the version the writer read, instead
of locking the record while it is read.
_Avoid_: version check, row versioning
```

**`PRACTICE.md`**: concepts that came up and were explained, but not yet shown. One entry each: the
concept, the date, where it came up, and one or two recall questions, with the answers further down
the file. In a later session, when one of these concepts comes up, its recall question goes first. A
good answer is evidence: write a record and drop the entry. A shaky one gets a short re-explanation and
today's date. Don't ask a recall question on the day it was explained; a gap of a few days is what
makes recall work. Keep the list short (around fifteen entries) and drop entries that no longer serve
the mission.

**`records/NNNN-<slug>.md`**: learning records, numbered from `0001` (highest existing plus one). They
are to learning what decision records are to design: short, and written only when something changes
what to teach next:

1. the user showed they can use something non-trivial (worked out a scenario, explained it back, wrote
   the rule correctly);
2. the user told you what they already know, and how deeply, so it isn't taught again;
3. a misconception was corrected: these predict where related topics will trip them up;
4. the mission shifted.

Material that was only explained doesn't qualify (it goes in `PRACTICE.md`), nor does a term already in
the glossary, nor a diary of the session. Format: a title, then one to three sentences on what is now
known and why it matters for what comes next. Add *Evidence* (how they showed it) or *Implications*
only when they add something. When a later record contradicts an earlier one, mark the old one
`Status: superseded by NNNN` instead of deleting it: how their understanding moved is useful too.

**`RESOURCES.md`**: trusted sources that proved useful, each with one line on what it covers and when
to reach for it. Prefer primary sources: official documentation, specifications, well-known books,
recognised experts; leave out marketing dressed up as teaching. Some questions need experience rather
than knowledge ("will this hold under our real load?"); list the people or well-moderated communities
who can answer those, unless the user doesn't want that. Note the gaps where no good source turned up,
and remove sources that turned out to be wrong or shallow.

**`lessons/NNNN-<slug>.html`**, only when the user asks for one (for instance from the *Study next*
list): one self-contained page that teaches one narrow thing tied to the mission and takes a few
minutes. Knowledge first, made as easy as possible (short, concrete, in terms of their own code); then
practice with immediate feedback that makes them retrieve and apply it; one primary source to read
next; and a reminder to bring their questions back to you. Quiz options all get the same number of
words, the right one sits in a different position each time, and the formatting gives nothing away. A
shared stylesheet in `assets/` keeps the lessons looking like one course. If a dedicated teaching
skill is installed (such as `teach`), suggest it for anything longer than a single lesson.
