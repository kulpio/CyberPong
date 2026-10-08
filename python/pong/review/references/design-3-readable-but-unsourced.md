# Reference · design · score 3

**Job:** Give the Conversation pane message-app timestamps.

## What shipped

A centred stamp at 50% opacity between messages when the conversation paused for
ten minutes or more, and the day only when the calendar day turns over. It reads
well and the rule is right: a time against every line is noise.

## Scores

| Dimension | Score | Why |
|---|---|---|
| Hierarchy | 4 | The stamp is subordinate to the messages — centred, dimmed, and only where there is a real gap. It does not compete. |
| Coherence | 4 | Uses the pane's existing type sizes and ink opacities rather than introducing a new grey. |
| Sourcing | 2 | "Like a message app" was recalled, not checked. iMessage's actual thresholds and its day-label wording were never looked up, so the ten-minute gap and the "Today · 1:32 AM" format are plausible guesses presented as the convention. |
| Efficiency | 4 | Costs the reader nothing and removes the need to hunt for when something happened. |
| Accessibility | 3 | 50% opacity white on the raised panel is the deliberate look, but the ratio against that background was never computed. It may well pass; nobody knows. |

**Mean 3.4 · sourcing is 2 · FAIL**

## Why this is the anchor for 3

Nothing here is wrong and nothing is dishonest — the work is genuinely usable.
It fails on the rule that a convention borrowed from another product has to be
*checked* rather than remembered, and that contrast is computed rather than
assumed. Note what the reviewer asks back: not "redesign it", but "open Messages
and confirm the gap and the label, and compute the ratio of 50% white on
Ink.raised". Both are ten-minute jobs, which is exactly why a 2 here is a fair
score rather than a harsh one.
