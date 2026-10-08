# Reference · design · score 5

**Job:** Make the collapsed island read as an extension of the camera notch, and
make the expand grow out of it rather than pop.

## What shipped

One `IslandShape` used by both states, with `radius` and `shoulder` as
`animatableData`, so collapsed and expanded are the same outline at different
settings. Collapsed carries the measured notch corner and a matching outward
shoulder; the top corners curve outward into the bezel the way the hardware
cutout and the expanded panel already did.

Geometry taken from the host, not from a picture: `safeAreaInsets.top` gave the
notch height (33pt) and the gap between `auxiliaryTopLeftArea` and
`auxiliaryTopRightArea` gave its width (185pt at x763–948). The corner radius is
**not** published by macOS — `_cornerRadius`, `_notchCornerRadius`,
`_displayCornerRadius` and `_notchRect` were each probed by KVC and every one
raises — so it is derived from the measured height rather than typed in points,
and the claim says so plainly.

## Scores

| Dimension | Score | Why |
|---|---|---|
| Hierarchy | 5 | The orb is the only thing in the collapsed state; nothing competes with it, and the count sits subordinate to it. |
| Coherence | 5 | Reuses the expanded island's own outline language instead of inventing a second shape. Deleting the one-off was the fix. |
| Sourcing | 5 | Every number that the OS publishes was read from the OS. The one that is not published is identified as such, tied to a measured value, and flagged as the single constant to nudge. |
| Efficiency | 4 | Nothing extra to click. The morph removed a visual step rather than adding one. |
| Accessibility | 4 | Pure black against the bezel so there is no seam; the orb keeps its own colour contrast. Not measured against both appearances, which is what holds it off a 5 here. |

**Mean 4.6 · every dimension ≥ 3 · PASS**

## Why this is the anchor for 5

The difference between 4 and 5 on `sourcing` is visible here: a 4 would have
picked a corner radius that looked right. This one went and asked the system,
found the system does not answer, said so, and tied the number to something the
system *does* answer. Design work clears this bar when a reviewer can tell which
values were measured and which were chosen.
