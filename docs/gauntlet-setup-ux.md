# Gauntlet — setting the bar inside CyberPong (UX spec)

Design note from Engineering — Design for Engineering — CyberPong. Spec only —
no CyberPong or island source was touched. The engine already exists
(`pong review create --answers`, `python/pong/review_init.py:404 run_answers`);
this replaces how the questions are **asked**. The current nine-field window
(`src/ReviewBarSetup.swift`) is retired by this spec — it is the CLI interview
transcribed into text fields, and it asks in schema words ("Short id (file
name)", "min mean") on an unstyled system window.

**Words on screen.** The feature is the **Gauntlet**; the verb everywhere is
**"Set the bar."** Never on screen: seat ids (w16…), "bar JSON", "dimensions",
"min_each", "scope", "builders", "reviewers". A stranger finishes this without
knowing any of those exist.

---

## 1. Where it lives

**Primary: the Mission tab, top of the page — the Gauntlet strip.** Mission is
already "jobs & flow" (`src/PanelController.swift:471`); the bar is what those
jobs are graded against, so its status card sits above the jobs list as the
first thing on the page. The strip is both the status surface and the entry:
its button opens the setup sheet. Layout reuses the Setup page's `tacticalCard`
(full width − 20, lime accent rail), so it looks like it was always there.

**Secondary: the app menu.** The existing item (`src/MenuBarApp.swift:4023`)
stays but retitles from "Set up a review bar…" to **"Set the bar…"** and opens
the same sheet. Two entries, one flow.

**Not** a fourth top tab — Map / Mission / Setup is width-budgeted
(`src/PanelController.swift:447`) and the Gauntlet is a property of the
mission, not a place of its own.

**Presentation: a sheet attached to the panel window** (`NSWindow.beginSheet`),
not today's floating `NSWindowController`. HIG · Sheets: *"A sheet helps people
perform a scoped task that's closely related to their current context"* and
*"In macOS, tvOS, visionOS, and watchOS, a sheet is always modal."* Setting the
bar is exactly a scoped task in the panel's context, and modality is right —
the person should finish or cancel, not abandon it half-filled behind the map. Fixed
560 × 520; the three steps swap inside a constant frame (no window resize
between steps, so the transition cannot pop). Chrome: `PongSheetChrome.rootView
/ titleLabel / plate / primaryButton / outlineButton` — nothing new.

The sheet is **appearance-aware** (`PongTheme` tokens). It must not use
`PongTheme.Launch.*`: those are the always-dark wizard tokens
(`src/PongTheme.swift:48`), and this sheet lives inside the main panel chrome,
which flips with the app appearance.

---

## 2. The flow — three steps, ~90 seconds

Step pattern and count follow the app's own precedent: `QuickTeamBuilder`
already runs a 3-step flow (`src/QuickTeamBuilder.swift:25 step = 0/1/2`).
Progress is a quiet "1 of 3" caption top-right (`labelFont(11)`,
`textSecondary`).

Buttons follow HIG · Sheets on multi-step flows: *"The Back button lets people
navigate to a previous step in a multi-step flow… It isn't intended to dismiss
a sheet"*, *"If you provide a Done button, always pair it with a Cancel
button… or a Back button"*, and *"Avoid showing all three buttons — Cancel,
Done, and Back — together."* So:

- Step 1: **Cancel** (outline, left) · **Continue** (primary lime, right)
- Steps 2–3: **Back** (outline, left) · **Continue / Set the bar** (primary, right)
- Return advances (`keyEquivalent "\r"` on the primary, as the current form's
  create button already does); Esc = Cancel/Back.
- The primary is **inactive until the step is valid** — HIG · Sheets sanctions
  this for multi-step sheets (*"the Done button … in an inactive state to
  indicate that the task isn't complete yet"*). Each step's field placeholder
  says what is missing, so the disabled state is never the only signal.

### Step 1 — "What should we be great at?"

```
┌──────────────────────────────────────────────── 560 ──┐
│ Set the bar                                    1 of 3 │  15pt semibold titleLabel
│                                                       │
│ WHAT SHOULD WE BE GREAT AT?                           │  section label — see §5
│ Say it like you'd say it to the team.                 │  12pt textSecondary
│ ┌───────────────────────────────────────────────────┐ │
│ │ Landing pages that load instantly and read like   │ │  multi-line, bgInput,
│ │ a human wrote them.▊                              │ │  4 lines, 12pt textPrimary
│ └───────────────────────────────────────────────────┘ │
│                                                       │
│ WHAT KIND OF WORK IS IT?                              │
│ [ Building it ] [ How it looks ] [ The words ]        │  single-select chips
│ [ Finding out ]                                       │
│                                                       │
│ [ Cancel ]                              [ Continue ]  │
└───────────────────────────────────────────────────────┘
```

- The goal is **free text**, one or two sentences. It becomes the bar's title
  (first ~6 words), id (slug), and summary (full text) — derived, never asked.
- The four kind chips map to the engine kinds in plain words:
  **Building it** = code · **How it looks** = design · **The words** = writing
  · **Finding out** = research. The kind's proposed dimensions
  (`review_init.py:38 KIND_DIMENSIONS`) and default pass marks (≥3 each, mean
  ≥4.0) ride along invisibly — they are the engine's defaults, not questions.
- Continue activates when goal text is non-empty and a kind is picked.

### Step 2 — "Who does this apply to?"

```
│ WHO DOES THIS APPLY TO?                               │
│ Pick the parts of the team this bar covers.           │
│                                                       │
│ [ Engineering ] [ Delivery ] [ Growth ]               │  multi-select chips,
│ [ Research ] [ Ops ]                                  │  ALL CLEAR by default
│                                                       │
│ ✓ Engineering  ✓ Growth                               │
│ Held by the reviewer in each lane you picked —        │  12pt textSecondary,
│ never the person who built the work.                  │  appears at ≥1 selection
```

- **Five chips, the five leads, nothing pre-selected.** Choosing is the point
  of the step; a default would let them skip the decision.
- Chips are labels-only — "Engineering", "Delivery", "Growth", "Research",
  "Ops". Under the hood each chip expands to that lane's group shorthand and
  `resolve_seats` (`review_init.py:115`) turns it into lead + coder seats.
  The Engineering chip covers all engineering lanes (CyberPong, Northwind, Design).
- **Roster truth at render time, not at submit.** A lead with no seats on this
  team renders disabled with a caption under the row: "Growth isn't on this
  team yet." Today that failure surfaces only after submission as
  `no seats matched` — moving it here deletes the worst error state.
- **The reviewer stays implicit.** The caption appears once ≥1 chip is
  selected, and its wording depends on the kind from step 1:
  - Building it → "Held by the code reviewer in each lane you picked — never
    the person who built the work."
  - How it looks → "Held by the design reviewer — never the person who built
    the work."
  - The words / Finding out → "Held by a reviewer outside the lane that did
    the work — never the person who built it."
  The sheet submits `reviewers: ""` and the engine's own
  `suggest_reviewers` (`review_init.py:151`) does precisely what the caption
  promises — code → the Grok reviewer in the lane, design → the Design
  reviewer, else a reviewer who sees the work. The caption describes the
  routing; it never asks them to do it. No seat picker exists anywhere.

### Step 3 — "What does great look like?"

```
│ WHAT DOES GREAT LOOK LIKE?                            │
│ Give the reviewer something real to hold the work     │
│ against. Pick any — or more than one.                 │
│                                                       │
│ ┌ ▎Paste a link ────────────────────────────────────┐ │  plate, lime rail
│ │  https://stripe.com                    [ Add ]    │ │
│ └───────────────────────────────────────────────────┘ │
│ ┌ ▎Drop a file ─────────────────────────────────────┐ │
│ │  Drag it here, or  [ Choose… ]                    │ │
│ └───────────────────────────────────────────────────┘ │
│ ┌ ▎Find best in class ──────────────────────────────┐ │
│ │  We'll look at X, GitHub, Reddit and the open     │ │
│ │  web for the best example of this, and bring      │ │
│ │  back candidates. Nothing counts until you        │ │
│ │  confirm it.                          [ Do it ]   │ │
│ └───────────────────────────────────────────────────┘ │
│                                                       │
│  ✓ stripe.com — Payments infrastructure    ×          │  added-reference chips
│                                                       │
│ Engineering and Growth will be held to "landing       │  live summary sentence
│ pages that load instantly", judged against            │
│ stripe.com — by their reviewers, never by             │
│ themselves.                                           │
│                                                       │
│ [ Back ]                             [ Set the bar ]  │
```

- Three **equal** plates (`PongSheetChrome.plate`, ~72 pt each, full width).
  "Find best in class" is the same size and weight as the other two — a
  first-class choice, not an escape hatch.
- **Link:** URL field + Add. On add, fetch the page title async and show a
  confirmation chip "domain — title". A string that doesn't parse as a URL
  gets an inline line under the field: "That doesn't look like a link."
  (`danger` — see §6 for why not amber.)
- **File:** a drop target plus a **Choose…** button opening `NSOpenPanel`.
  HIG · Drag and drop: *"Offer alternative ways to accomplish drag-and-drop
  actions"* — the button is that alternative, in the same plate. On drop or
  choose, a filename chip appears.
- **Find best in class:** selecting it marks the research route. It coexists
  with a link or file — those anchor the bar immediately; research adds
  candidates later. Its copy names the four places and the confirmation rule,
  verbatim as drawn above.
- Added references render as removable chips; the × has a ≥28 pt hit region
  (see §7).
- **The live summary sentence** assembles from their own inputs as they go —
  bold spans in `textPrimary`, the rest 12 pt `textSecondary`. This is the
  moment the flow reads as setting a goal for the team rather than filling a
  schema, and it is the last chance to spot a wrong chip. No separate confirm
  step.
- **Set the bar** activates when there is ≥1 reference **or** the research
  route is selected. If neither, the inactive button carries a caption
  beneath: "The reviewer needs at least one real example — or let us go find
  one." (This surfaces the engine's own refusal — *"a bar needs at least one
  reference"* — before submission, in their words.)

---

## 3. What the sheet writes (contract with the engine)

Keep the exact mechanism of `ReviewBarSetup.swift:136–175`: build an answers
dict, write a temp JSON, run `pong … review create --answers`, parse
`bar_path`. Only the answers change:

| answers key   | value |
|---|---|
| `kind`        | from the step-1 chip (code / design / writing / research) |
| `title`       | first ~6 words of the goal text |
| `bar_id`      | slug of title (engine slugs anyway) |
| `summary`     | the full goal text |
| `builders`    | comma list of lane shorthands from the step-2 chips (Engineering → "CyberPong, Northwind, Design"; others their own shorthand) — `resolve_seats` expands to lead + coders |
| `reviewers`   | `""` — the engine's `suggest_reviewers` decides, matching the step-2 caption |
| `great`       | the added URLs / file paths, comma-joined; `"help"` when research-only — the engine then writes its TODO-anchor stub (`review_init.py:439`), which is our "no reference yet" state |
| `fail` / `dimensions` / `never_waived` | `""` — engine defaults |
| `min_each` / `min_mean` | 3 / 4.0 — engine defaults |
| `scope`       | `"project"` always. Machine scope stays a CLI-only power feature; asking here is a question with no wrong answer they can evaluate. |

If the research route was selected: after the bar writes, the app files one
research job to the Research lane carrying the goal text and the four sources
(X, GitHub, Reddit, open web). The plumbing is Engineering's; the UI contract
is only: the bar exists immediately in "no reference yet", candidates arrive
as a needs-you moment, a confirmed candidate becomes a score-5 reference file
in the bar's references dir and clears the pending state.

---

## 4. The Gauntlet strip — every state drawn

All states are `tacticalCard` rows on the Mission page; title 12 pt semibold
`textPrimary`, caption 11 pt `textSecondary`.

**A — no bar (empty).**
```
▎ GAUNTLET
▎ No bar set.
▎ The team is running without a definition of great.   [ Set the bar ]
```
Lime accent rail; the button is `PongSheetChrome.primaryButton`.

**B — bar set.**
```
▎ GAUNTLET
▎ Landing pages that load instantly
▎ Engineering and Growth · judged against stripe.com
▎ · held by their reviewers                                    [ Edit ]
```
One row per bar; rows stack. Edit reopens the sheet pre-filled.

**C — no reference yet (research out).**
State B's row plus, on its own line, a small indeterminate spinner and:
"Looking for best in class on X, GitHub, Reddit and the web — candidates will
need your confirmation." HIG · Progress indicators: *"Prefer an activity
indicator (spinner) to communicate the status of a background operation"*, and
the sentence is the description the HIG asks for — specific, not "loading".
An unbounded search has no honest percentage, which is the HIG's own criterion
for indeterminate (*"Indeterminate, for unquantifiable tasks"*).

**D — candidates arrived (needs the person).**
The line becomes "3 candidates found — pick what counts." with the amber dot
the app already uses for HUMAN states (`PongTheme.statusKind` →
amber). Clicking opens the **candidate sheet** — the set-bar sheet is never
stacked under it (HIG · Sheets: *"Display only one sheet at a time from the
main interface"*). Each candidate row: source tag as text (X / GitHub /
Reddit / Web — a word, not a color), title, an open-link ⧉, and
**Confirm** / **Skip**. Confirming ≥1 writes the reference(s) and returns the
strip to state B. Skipping all keeps state C with "Nothing confirmed — still
looking" and re-files the research job once; a second all-skip parks the row
as "No good match found — paste a link or drop a file instead", which links
straight into step 3 of the sheet.

**E — error.**
Engine refusals land verbatim in an inline line inside the sheet, in `danger`,
above the footer buttons; the sheet stays open with every input preserved.
Predictable refusals never get here: missing reference and empty-lane chips
are caught in-flow (steps 2–3). Unpredictable ones (engine/CLI failure) show
as: "CyberPong couldn't write the bar — [first line of stderr]".

---

## 5. Type, spacing, geometry — the app's tokens only

- Sizes only from the existing ramp: 15 semibold (sheet title), 12 body,
  11 labels/captions, 10 uppercase section labels. All at or above the HIG's
  published macOS floor (HIG · Accessibility, type table: macOS default
  13 pt, minimum 10 pt). Fonts via `PongTheme.font` / `labelFont` — Space
  Grotesk, as everywhere.
- Radii: `radiusCard` 6 for plates/cards, `radiusPill` 4 for chips and
  buttons. `hairline` 1 borders. No new radius, no new grey.
- Insets 20 pt, stack spacing 10 pt — the values the current form and wizard
  already use.
- **Section labels: use `textSecondary`, not `PongSheetChrome.sectionLabel`'s
  `limeDim`.** Computed (§6): limeDim is 3.69:1 on the dark void and 2.42:1 on
  light — a 10 pt label needs 4.5:1, so the existing helper fails AA in both
  appearances, badly in light. This spec's surfaces use 10 pt uppercase
  `textSecondary` (7.85:1 dark / 8.64:1 light). Flagging the shared helper
  itself is Engineering's call; nothing here depends on it.
- Chip anatomy: 28 pt tall pills, `hairline` border `line`, label 12 pt
  medium `textPrimary`. Selected = `limeSoft` fill + full `lime` border +
  a leading ✓ glyph. The check is the second signal so selection never rides
  on color alone (HIG · Accessibility: *"Convey information with more than
  color alone"* — *"Offer visual indicators, like distinct shapes or icons,
  in addition to color"*).

---

## 6. Contrast — computed, both appearances

WCAG AA thresholds per HIG · Accessibility (its Level AA table): **up to
17 pt → 4.5:1; 18 pt or bold → 3:1**; and *"If your app supports [dark mode],
make sure to check the minimum contrast in both light and dark appearances."*
Every text size in this spec is ≤15 pt, so 4.5:1 applies except where a
15 pt semibold title arguably clears at 3:1 — treated as 4.5:1 anyway.

Computed against the **actual composited backgrounds** (`bgElevated` is
white 6 % at α 0.94 over the void, etc.), from the token values in
`src/PongTheme.swift` / `src/PongSheetChrome.swift`:

| Pair | Dark | Light | Verdict |
|---|---|---|---|
| textPrimary on bg | 21.00:1 | 17.91:1 | pass |
| textPrimary on bgElevated | 19.25:1 | 19.08:1 | pass |
| textSecondary on bg | 7.85:1 | 8.64:1 | pass |
| textSecondary on bgElevated | 7.20:1 | — | pass |
| textTertiary on bgElevated | **3.62:1** | 5.81:1 | **fails small-text AA in dark** |
| lime as text on bg | 16.54:1 | **4.26:1** | dark pass; light body-size borderline-fail |
| limeDim (sectionLabel) on bg | **3.69:1** | **2.42:1** | **fails both** |
| black label on lime primary button | 16.54:1 | 4.61:1 | pass |
| amber as text on bg | 11.84:1 | **3.99:1** | **fails body-size AA in light** |
| danger as text on bg | 5.35:1 | 5.41:1 | pass |
| border `line` on bg (UI boundary, 3:1) | 6.27:1 | 3.32:1 | pass |

Rules that follow, binding for these surfaces:

1. **Errors and refusals are `danger`, never amber.** Amber at body size is
   3.99:1 on light. Amber stays for the needs-you **dot** (a non-text
   indicator paired with words).
2. **No `textTertiary` for anything informative** — 3.62:1 in dark. Captions
   are `textSecondary`.
3. **Section labels `textSecondary`**, per §5.
4. **Lime is fills, rails and borders — not running text.** Black-on-lime
   buttons pass both appearances.

Re-run: the script and outputs above —
`python3 contrast.py` with the WCAG 2.1 relative-luminance formula and the
transcribed token values — is included at the end of this note so the
reviewer can reproduce every number.

---

## 7. Reach, focus, keyboard

- Hit regions ≥ 28 pt. The HIG's Accessibility page publishes **no** macOS
  hit-target minimum (checked — its published minimums are the type table and
  contrast table); the concrete floor the HIG does publish is the Buttons
  size table, whose smallest system size is **Mini, 28 pt**. Chips are 28 pt;
  plates are clickable across their full ~72 pt; the chip-delete × gets a
  28 × 28 pt region via inset padding.
- Chips and cards are `NSButton`s — Full Keyboard Access and VoiceOver reach
  them for free; do not suppress the system focus ring anywhere in the sheet.
- Tab order = reading order: goal → kind chips → footer; chips → footer;
  link → file → research → footer.
- The file plate's Choose… button is the drag-and-drop alternative (§2,
  step 3) — no drop-only affordance exists.

---

## 8. Retired / touched

- `src/ReviewBarSetup.swift` — window retired; keep its `create()` CLI
  mechanism (temp answers JSON → `review create --answers` → parse
  `bar_path`) as the submit path of the new sheet. `present(session:)`
  becomes "open the sheet on the panel window".
- `src/MenuBarApp.swift:4023` — menu item retitle to "Set the bar…".
- Mission page (`paintMission`) — Gauntlet strip added at top.
- Engine untouched. Refusal behavior untouched — the sheet just meets the
  two refusals it can predict before they fire.

## Acceptance mapping

- Entry: §1 (Mission strip + menu item, one flow) · Goals: §2 step 1 ·
  Five leads, multi-select, default-clear: §2 step 2 · URL / upload /
  research first-class with sources named and confirm-before-counting:
  §2 step 3, §4 C–D · Implicit reviewer, spelled without seat ids: §2 step 2
  caption + `suggest_reviewers` · Empty / error / no-reference states: §4 ·
  Contrast computed on actual backgrounds, both appearances: §6 ·
  Stranger-in-one-sitting: three plain-language questions, no schema words
  (§0, §2).

---

## Appendix — contrast script (verbatim, re-runnable)

```python
# WCAG 2.1 contrast for PongTheme tokens against their ACTUAL backgrounds.
# Token values transcribed from src/PongTheme.swift / src/PongSheetChrome.swift.
def lin(c):
    return c/12.92 if c <= 0.03928 else ((c+0.055)/1.055)**2.4
def L(rgb):
    r,g,b = rgb
    return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)
def ratio(fg,bg):
    a,b = L(fg),L(bg)
    return (max(a,b)+0.05)/(min(a,b)+0.05)
def over(fg,alpha,bg):  # composite fg@alpha over bg
    return tuple(alpha*f+(1-alpha)*g for f,g in zip(fg,bg))
g = lambda w:(w,w,w)
BLACK=g(0.0); WHITE=g(1.0)
d_bg=g(0.0); d_elev=over(g(0.06),0.94,d_bg)
d_lime=(0.82,0.95,0.28); d_limeDim=over(d_lime,0.45,d_bg)
d_amber=(1.0,0.706,0.227); d_danger=(0.90,0.28,0.28)
l_bg=g(0.97); l_elev=over(g(1.0),0.96,l_bg)
l_lime=(0.28,0.52,0.06); l_limeDim=over(l_lime,0.65,l_bg)
l_amber=(0.72,0.40,0.02); l_danger=(0.78,0.12,0.12)
d_line=over(WHITE,0.55,d_bg); l_line=over(BLACK,0.45,l_bg)
rows=[("DARK textPrimary/bg",WHITE,d_bg),("DARK textPrimary/elev",WHITE,d_elev),
 ("DARK textSecondary/bg",g(0.62),d_bg),("DARK textSecondary/elev",g(0.62),d_elev),
 ("DARK textTertiary/elev",g(0.42),d_elev),("DARK lime text/bg",d_lime,d_bg),
 ("DARK limeDim/bg",d_limeDim,d_bg),("DARK black/lime btn",BLACK,d_lime),
 ("DARK amber/bg",d_amber,d_bg),("DARK danger/bg",d_danger,d_bg),
 ("LIGHT textPrimary/bg",g(0.06),l_bg),("LIGHT textPrimary/elev",g(0.06),l_elev),
 ("LIGHT textSecondary/bg",g(0.28),l_bg),("LIGHT textTertiary/bg",g(0.38),l_bg),
 ("LIGHT lime text/bg",l_lime,l_bg),("LIGHT limeDim/bg",l_limeDim,l_bg),
 ("LIGHT black/lime btn",BLACK,l_lime),("LIGHT amber/bg",l_amber,l_bg),
 ("LIGHT danger/bg",l_danger,l_bg),
 ("DARK border line/bg",d_line,d_bg),("LIGHT border line/bg",l_line,l_bg)]
for name,fg,bg in rows: print(f"{name:26s} {ratio(fg,bg):6.2f}:1")
```

HIG pages cited (fetched 2026-08-15 from the HIG's own data endpoints, quotes
verbatim): Sheets · Accessibility · Progress indicators · Drag and drop ·
Buttons (size table). Apple's data endpoint publishes these at
`developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`.
