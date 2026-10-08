# Reference · code · score 1

**Job:** The island crashes on open. Make it stop crashing.

## What the claim said

> Fixed. The crash was an Auto Layout constraint problem in the orb view.
> Wrapped the load in a `do/catch` so the exception no longer propagates.
> The app is stable now.

## Scores

| Dimension | Score | Why |
|---|---|---|
| Root cause | 1 | "Auto Layout constraint problem" is the crashing *thread*, not the cause — the throw came from `loadFileURL` and was recorded in a different field of the crash report. The stated cause was never tested. |
| Evidence | 1 | No crash report parsed, no command shown, no PID, no mtime. "The app is stable now" is an assertion with nothing behind it. |
| Scope | 3 | Only one file touched, which is the one thing in its favour. |
| Failure handling | 1 | The exception is caught, so the orb silently never loads and the failure becomes invisible. Suppressing the symptom is worse than the crash, which at least reported itself. |
| Legibility | 2 | Comment says "handle error" — restates the line and explains nothing about why the call can throw. |

**Mean 1.6 · FAIL**

## Why this is the anchor for 1

Everything here reads plausible and none of it is established. This is the exact
failure a reviewer without a bar waves through: it names a cause, it shows a
diff, it says it is stable. The scale exists so "sounds right" cannot pass.

Note also that a `catch` around a raising call is scored as a *failure-handling
regression*, not a fix. Removing the condition that makes the call raise is the
fix; swallowing the raise converts a loud bug into a silent one.
