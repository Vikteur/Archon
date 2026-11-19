# Builder check

Run this once, after the decision record is written, if you can start a subagent. A reader who wasn't
in the conversation finds the gaps the two of you stopped seeing.

Give a fresh subagent only this brief, with the placeholders filled and the record pasted in. Nothing
from the conversation: the point is to learn what the record says on its own.

```text
You are an experienced <role, e.g. "backend developer">. You've been handed the decision record below
and asked to plan how to build what it describes, in the repository at <path>. You may read the code;
change nothing. You can't talk to the people who wrote the record.

Report only the questions you would still need answered before you could plan this well: places where
you'd have to guess, and a wrong guess would matter. For each one, give the question, why the answer
changes the plan, and what you'd assume if nobody answered. Most important first.

Leave out what the record explicitly leaves to the builder, what you could reasonably decide yourself,
and remarks about wording. If nothing important is left, say "nothing important left".

<the decision record>
```

Sort what comes back into three piles:

- **Already answered**: the conversation settled it, but the record doesn't say so clearly. Sharpen the
  record.
- **Minor**: a sensible developer could settle it without changing what gets built. Decide it, add it
  to the record, and mark it as yours.
- **Theirs**: only the user can answer, and the answer changes what gets built. Bring these in one
  message, most important first, each with your recommended answer; then update the record.

One round only: the aim is to catch the gaps that matter, not to polish the record forever.
