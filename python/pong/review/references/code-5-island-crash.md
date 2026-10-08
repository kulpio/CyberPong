# Reference · code · score 5

**Job:** Pong Island crashes on every open. Find why and fix it.

**Briefed theory (turned out to be wrong):** `loadFileURL` throws because the HTML
is missing from the bundle or the allow-read directory is wrong.

## What the claim said

> Root cause: `WebOrb.load` in `island/PongIsland.swift`. `Bundle.main.resourceURL`
> is a *relative* URL (`Contents/Resources/` against the bundle base), so
> `URLComponents(url:resolvingAgainstBaseURL: false)` kept only the relative part
> and dropped the base — `comp.url` came back scheme-less
> (`Contents/Resources/web/orb.html?...`), `isFileURL=false`.
> `-[WKWebView loadFileURL:allowingReadAccessToURL:]` *raises*
> `NSInvalidArgumentException` on a non-file URL; uncaught through SwiftUI's
> `makeNSView`, AppKit's `_crashOnException` turned it into `EXC_BREAKPOINT`.
> The assets were bundled correctly all along — not a missing file.
> Fix: resolve `.absoluteURL`, use `resolvingAgainstBaseURL: true`, plus an
> `isFileURL` precondition so a bad URL never reaches WebKit.
> Rebuilt: binary mtime 00:40 (was 21:27). One `open` → PID 43706 alive past 30s,
> `WebContent` XPC 43779 spawned, zero new `.ips` since the fix.

## Scores

| Dimension | Score | Why |
|---|---|---|
| Root cause | 5 | Named file, function and mechanism, and *disproved* the briefed theory by showing the assets were present and that the same call with an absolute URL does not throw. |
| Evidence | 5 | Parsed the real `.ips`, found the throw backtrace in `asiBacktraces` rather than trusting the crashing thread, reproduced the crash, then verified the rebuilt app by PID and by the absence of new crash reports. |
| Scope | 5 | One function changed. Noted the unrelated dirty files in the tree rather than touching them. |
| Failure handling | 5 | Fixed the cause; the added `isFileURL` guard is a precondition that prevents the raise, explicitly not a catch around it. |
| Legibility | 4 | Comment explains why the relative URL is invisible, which is the surprising part. Slightly long. |

**Mean 4.8 · every dimension ≥ 3 · PASS**

## Why this is the anchor for 5

The briefed root cause was wrong and the work said so, with an experiment rather
than an opinion. That is the difference between a 5 and a 4: a 4 fixes what it
was told to fix and proves it; a 5 also establishes that the explanation itself
is true, and would have caught the team being wrong.
