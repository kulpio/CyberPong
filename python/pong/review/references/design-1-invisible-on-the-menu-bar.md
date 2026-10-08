# Reference · design · score 1

**Job:** Show which agent is working, in the collapsed menu-bar island.

## What shipped

The seat's name beside the orb, in the status colour, inside a ~68pt ear:

    Text(seat.label).lineLimit(1)

"Engineering" rendered as **"E…"**. The working state used a green that sat on
whatever the menu bar happened to be showing behind it.

## Scores

| Dimension | Score | Why |
|---|---|---|
| Hierarchy | 2 | A truncated word pulls the eye harder than the orb it was meant to caption, so attention lands on a glitch. |
| Coherence | 2 | Nothing else in the island truncates to a single character; it looks like a rendering fault rather than a label. |
| Sourcing | 1 | No check of how much room the menu bar actually gives, and no check of what sits behind a transparent element up there. |
| Efficiency | 2 | Tells the reader nothing they can use — "E…" is not identification — while spending the scarcest space on screen. |
| Accessibility | 1 | Contrast never computed, against a background that was never established. The state the user actually saw was the failing one. |

**Mean 1.6 · FAIL**

## Why this is the anchor for 1

Every decision here is defensible in the abstract — label your indicators, colour
by state — and all of it fails in the one place it had to work. This is the
design equivalent of an unsupported claim: it was never checked against the real
surface. The fix was to delete the label and let the orb carry the state, which
is also the lesson: on a bar this narrow, the honest move is to show less.
