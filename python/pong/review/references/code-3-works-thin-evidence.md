# Reference · code · score 3

**Job:** Terminal view-session labels are off-by-one against the roster.

## What the claim said

> Fixed `TerminalTheme.viewToken` to use the seat id instead of `n - 1`.
> Rebuilt CyberPong; it compiles clean. Engineering's window should now be
> `pong-team-w16`.

## Scores

| Dimension | Score | Why |
|---|---|---|
| Root cause | 3 | The named function really was one cause, but the same 0-based name is built in three other places (per-seat spawn, bulk pair path, sanitizer). Fixing one and calling it done leaves the bug live on every path but the one that was read. |
| Evidence | 2 | "It compiles clean" is not evidence for a naming bug. Nothing ran `tmux list-sessions`; the claim says "should now be", which is a prediction, not a result. |
| Scope | 4 | The edit itself is minimal and correct. |
| Failure handling | 3 | No new crash path, but `killPair` still enumerates `0..<12`, so wrappers past `w11` keep leaking — a known failure left untouched. |
| Legibility | 4 | Reads like the surrounding code. |

**Mean 3.2 · every dimension ≥ 3? No — evidence is 2 · FAIL**

## Why this is the anchor for 3

The change is genuinely correct and honestly described — nothing here is a lie.
It fails on the rule that a claim must be verified against reality rather than
against the compiler. Note what the reviewer says back: not "this is bad", but
"run `tmux list-sessions` and paste the seat→session→pane mapping, and grep for
the other constructions of this name". That is an instruction the builder can
act on and argue with, which is the point of publishing the bar up front.

A single dimension at 2 fails the claim even though the mean is above 3. That
rule exists so a strong average cannot carry an unverified result.
