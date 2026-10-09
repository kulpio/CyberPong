# CyberPong design language: "Sodium & Neon"

Artisan · 29 Sep 2026 · specification only. Builds on the brief, research.md's Recommended direction, the UX and wording reviews, the screenshots and `PongTheme.swift`. Ratios are computed (WCAG 2.x); colour-blind checks use Machado 2009 and CIEDE2000.

**Changes to research.md**
- **Primary button: Wallace white, not amber**, so amber always means "needs you" (ISO 2575 reads amber as caution).
- **Question card lit by haze (#221915):** amber over blue-black turns olive.
- **No texture under reading text:** wear is colour, glyph and time stamp. The frame's 3% grain touches only navigation labels (≥15.1:1).
- **Screens stay Night in Daylight:** deck, terminals, notch panel.

## 1. Five principles
1. **One colour, one job:** amber you, cyan machines at work, magenta the architect, red failed; all else neutral.
2. **Wallace-clean where you decide:** flat black-and-white questions and buttons, one primary per view; the question is the loudest thing on screen.
3. **The room is dark; the screens glow:** fog, grain and glow only on the frame and deck; structure is felt, not seen.
4. **Every state has a shape, a colour and a word.**
5. **Motion explains a change:** ≤400 ms, never on repeated actions, off under Reduce Motion.

## 2. Tokens

### 2.1 Colour: Night (default)
| Token | Hex | Use |
|---|---|---|
| `bg.void` | #07090C | Deck, terminals, scrims |
| `bg.frame` | #090C10 | Sidebar, rail |
| `bg.base` | #0B0F14 | Content, window bar |
| `bg.raised` | #121821 | Cards, chips |
| `bg.overlay` | #1A212C | Popovers, ⌘K, toasts, selected row |
| `bg.selectedMuted` · `selectedOnOverlay` | #151B24 · #222B38 | Selection in an inactive window · selection inside ⌘K and menus |
| `bg.field` | #0F141B | Text fields |
| `state.hover` · `state.pressed` | text.primary at 4% · 7% | Any surface |
| `line.hairline` | text.primary at 8% (#1D2024 on base) | Dividers |
| `line.mark` | #3A4556 | Registration marks, idle deck edges |
| `line.control` | #6B778B | Field and button edges |
| `text.primary` · `secondary` · `tertiary` | #ECE7DC · #AAB2BE · #8C96A5 | Sodium white · context · meta |
| `text.disabled` | #586270 | Disabled only |
| `action.ink` / `onInk` | #ECE7DC (hover #F7F3EA, pressed #D6D0C4) / #0B0F14 | Primary button |
| `signal.you` | #F5A524 | Needs you |
| `signal.live` | #4CD6E0 | Working, links, focus |
| `signal.architect` | #FF6EC7 | The architect only |
| `signal.fail` | #FF7A6E (hover #FF8A7F, pressed #E86A5F) | Failed, destructive |
| `tint.you` · `fail` · `live` · `architect` | #221915 · #231A1D · #112126 · #211824 | Question card · problem card · live chip · chat glyph |
| `fog.teal` · `fog.haze` | #0E3B44 · #C8641E | Deck fog only |

### 2.2 Colour: Daylight
| Token | Hex |
|---|---|
| `bg.frame` · `base` · `raised`/`field`/`overlay` · `selected` | #ECE8E0 · #F7F5F0 · #FFFFFF · #E9E5DC |
| `line.hairline` · `mark` · `control` | text at 10% · #BDB5A7 · #827B6E |
| `text.primary` · `secondary` · `tertiary` | #141A21 · #465060 · #556070 |
| `action.ink` / `onInk` | #141A21 (hover #2B323C, pressed #000000) / #F7F5F0 |
| `signal.you` · `live` · `architect` · `fail` | #8F5200 (badge fill #F0A02A) · #00666F · #A3186C · #B02D21 (fill #B83327 with white) |
| `tint.you` · `fail` · `live` · `architect` | #F6E7D0 · #F4E5E0 · #E1EDEA · #F5E5E9 |

**Keep light mode? Yes, second.** People already toggle it, and bright rooms and some eyes need dark-on-light. With semantic tokens it is one more column, not a second design. Night stays the default; ship Daylight after Night passes review. Settings › General › Look: Night · Daylight · Match Mac.

### 2.3 Contrast
| Night text on | frame | base | raised | overlay | field | tint.you | tint.fail | fog floor |
|---|---|---|---|---|---|---|---|---|
| text.primary | 15.9 | 15.6 | 14.5 | 13.1 | 15.0 | 14.0 | 13.8 | 13.1 |
| text.secondary | 9.2 | 9.0 | 8.3 | 7.6 | 8.6 | 8.1 | 7.9 | 7.6 |
| text.tertiary | 6.6 | 6.4 | 6.0 | 5.4 | 6.2 | 5.8 | 5.7 | 5.4 |
| signal.you | 9.6 | 9.4 | 8.7 | 7.9 | 9.1 | 8.4 | 8.3 | 7.9 |
| signal.live | 11.2 | 11.0 | 10.2 | 9.2 | 10.6 | 9.9 | 9.7 | 9.3 |
| signal.architect | 7.8 | 7.6 | 7.0 | 6.4 | 7.3 | 6.8 | 6.7 | 6.4 |
| signal.fail | 7.7 | 7.6 | 7.0 | 6.4 | 7.3 | 6.8 | 6.7 | 6.4 |
| line.control (edge) | 4.3 | 4.2 | 3.9 | 3.6 | 4.1 | 3.8 | 3.7 | 3.6 |

| Daylight text on | frame | base | raised | selected | tint.you | tint.fail |
|---|---|---|---|---|---|---|
| text.primary | 14.3 | 16.1 | 17.5 | 13.9 | 14.4 | 14.3 |
| text.secondary | 6.7 | 7.5 | 8.1 | 6.5 | 6.7 | 6.6 |
| text.tertiary | 5.2 | 5.9 | 6.4 | 5.1 | 5.2 | 5.2 |
| signal.you | 5.1 | 5.7 | 6.2 | 5.0 | 5.1 | 5.1 |
| signal.live | 5.5 | 6.2 | 6.7 | 5.3 | 5.5 | 5.5 |
| signal.architect | 5.9 | 6.6 | 7.2 | 5.8 | 5.9 | 5.9 |
| signal.fail | 5.3 | 5.9 | 6.5 | 5.2 | 5.3 | 5.3 |
| line.control (edge) | 3.4 | 3.8 | 4.2 | 3.3 | 3.4 | 3.4 |

**Other pairs.**
- **Night:**
  - Ink button text 15.6 (hover 17.4, pressed 12.5); its keycap 5.5; a tertiary keycap on a secondary button 5.7.
  - Badge on amber 9.4; dark text on the red fill 7.6 / 8.4 / 6.1.
  - Primary / tertiary text on `selectedMuted` 14.0 / 5.8, on `selectedOnOverlay` 11.6 / 4.8.
  - Secondary edge on its fill ≥3.15; focus ring ≥9.2.
- **Daylight:** ink text 16.1 (hover 11.9); badge 8.1; white on the red fill 5.9; focus ring ≥4.8.
- **Notch panel:** its #000 body raises every Night pair.

### 2.4 Status markers
| State | Shape | Colour | Word |
|---|---|---|---|
| Needs you | ◆ `diamond.fill` | signal.you | Needs you |
| Working | 270° ring, 1.5 pt stroke; one turn per 1.6 s, in lists, key window only | signal.live | Working |
| Done | ✓ `checkmark` | text.secondary | Done |
| Failed | ✕ `xmark` | signal.fail | Failed |
| Stopped | ■ `stop.fill` | text.tertiary | Stopped |
| Stale | ◌ `circle.dashed` | text.tertiary | Quiet 3 h |

- **Size:** glyph 12 pt in a 16 pt cell; word 12 pt Medium. Paused: ‖ in secondary.
- **Wear:** stopped or stale titles drop to secondary and gain a Plex Mono stamp, "last news 3 h ago".
- **Why the word stays** (simulated ΔE00; below 10 reads as one colour):
  - deuteranopia: working/architect 6.1, architect/done 3.7, working/done 8.3;
  - protanopia: working/done 7.4;
  - tritanopia: architect/failed 6.0.

### 2.5 Type
SF Pro (system API) for the UI, Archivo Expanded SemiBold for eyebrows, IBM Plex Mono for data and terminals; Space Grotesk leaves. Five SF sizes; nothing under 11 pt, deck labels included.

| Role | Face · pt/line · weight | Use |
|---|---|---|
| `title` | SF 22/28 Semibold | Page title |
| `question` | SF 17/22 Semibold | Question; sheet and inspector titles |
| `body` · `bodyStrong` · `control` | SF 13/18 Regular · Semibold · Medium | Text · row titles and primary · buttons and sidebar |
| `secondary` | SF 12/16 Regular | Subtitles, status lines |
| `meta` | SF 11/14 Regular, tabular digits | Times, counts, keycaps |
| `eyebrow` | Archivo Expanded 11/14 SemiBold, capitals, +0.88 pt | Labels of at most 3 words |
| `data` | Plex Mono 12/16 | Files, paths, Details, deck HUD |
| `terminal` | Plex Mono 13/18; bold uses SemiBold | Chats, Screen; ⌘+/⌘− from 11 to 16 |

### 2.6 Space, radius, lines
| Group | Values |
|---|---|
| Grid (4 pt) | 4, 8, 12, 16, 20, 24, 32, 40, 48 |
| Spacing | icon–label 8; title–subtitle 4; row padding 12; card padding 16 (question card 20); cards 12 apart; sections 32; page margin 24 (960), 32 (1440) |
| Heights | controls 24/28/32; sidebar row 32; list row 52 (one line 36); activity 28; window bar 52; hit target ≥24 × 24 |
| Radius | 4 badges, keycaps (deck nodes 3); 6 buttons, fields, selections; 10 cards, popovers, toasts; 14 ⌘K; capsules for count badges and chips; system radius for sheets |
| Lines | 1 pt hairline dividers, never boxes; 1 pt control edge on fields and secondary buttons; cards borderless (Increase Contrast adds `line.control`); registration marks 1 pt `line.mark`, 8 pt arms, inset 6, on screens only (deck, terminals, Screen, empty states) |

### 2.7 Elevation and focus
| Level | Surface | Night shadow (offset, radius, opacity) | Daylight | For |
|---|---|---|---|---|
| 0 | base | none | none | Pages |
| 1 | raised | none | (0,−1), 1, #141A21 at 6% | Cards |
| 2 | overlay | (0,−8), 12, black at 50%, plus a 1 pt top edge of text at 6% | (0,−8), 12, #141A21 at 12%, plus a hairline border | Popovers, toasts, ⌘K, inspector overlay |
| 3 | sheet | system shadow, void scrim at 55% | #141A21 scrim at 25% | Sheets, alerts |

**Focus ring:** 2 pt `signal.live`, 2 pt outside the control, radius +2. Night adds a 6 pt glow at 35%; Increase Contrast makes it 3 pt with no glow. We draw it ourselves (§7). A focused terminal turns its marks cyan instead.

### 2.8 Motion
| Token | Time, curve | Use | Reduce Motion |
|---|---|---|---|
| `fast` | 120 ms ease-out (0.2, 0.8, 0.2, 1) | Hover, press, marker change | Colour only |
| `base` | 200 ms ease-out | Popover or toast in, disclosure, card collapse, row insert (30 ms stagger, 5 rows max) | 150 ms fade |
| `exit` | 150 ms ease-in (0.4, 0, 1, 1) | Anything leaving | 100 ms fade |
| `panel` | 240 ms ease-in-out (0.4, 0, 0.2, 1) | Sidebar ↔ rail, inspector overlay | Instant, then fade |
| `esper` | 3 × 90 ms ease-out | Opening a graph: the deck zooms in 3 steps with a coordinate readout | 150 ms fade |
| `afterglow` | 400 ms linear | A changed number fades from cyan to its own colour | None |
| `spin` | 1.6 s per turn, linear | Working ring | Still |

Toasts: in 200 ms, hold 4 s (6 s with an action; hovering pauses), out 150 ms. Only the working ring loops, in the notch panel too, where it holds still while anything needs you. Nothing moves on typing, scrolling, refresh, or while the window isn't key. Animate transform and opacity only.

### 2.9 Texture
| Texture | Value | Only on |
|---|---|---|
| Grain | Still one-colour noise, 128 px @2x tile, fixed seed; white 3% (Daylight black 2%) | Sidebar, rail, deck void |
| Scanlines | 1 device px light line every 3 px, white 3% | Deck backdrop |
| Fog | #07090C top → #09181D at 55% height (void + 30% teal) → #20211D floor (+ 12% haze) | Deck, Team map |
| Glow | One colour, 6–8 pt blur, ≤35% | Wordmark (baked in), live deck nodes, focus ring, the notch panel's working ring |

Never on text, cards, fields, terminals or buttons. Text over the brightest fog still passes (tertiary 5.4:1). Reduce Transparency and Increase Contrast turn all four off.

## 3. Components
**Shared states,** unless noted:
- hover: `state.hover`; pressed: `state.pressed`;
- focus: the ring;
- disabled: `text.disabled`, no fill;
- selected: `bg.overlay` (`bg.selectedMuted` in an inactive window).

**Sidebar**
- **Size:** 200 pt (232 at 1440), draggable from 180 to 260; ⌥⌘S hides it.
- **Top:** traffic lights at y 0–52, the wordmark at y 52–92 (§5), then **New graph** at y 104: a large secondary button, 176 × 32 at x 12, with "⌘N" as meta.
- **Items:** five 32 pt items from y 148.
  - The pill spans x 8–192 with radius 6.
  - A 16 pt symbol sits at x 16: `diamond` (filled amber while anything waits), `text.bubble`, `point.3.connected.trianglepath.dotted`, `person.2`, `clock`.
  - The `control` label sits at x 40 in secondary; the selected item turns primary Semibold.
- **Badges:** only Needs you gets a filled capsule (≥20 × 16, amber, 11 pt Semibold #0B0F14). Other counts are tertiary meta.
- **Teams:** the TEAMS eyebrow, then 32 pt team rows (still marker, name, "Stopped"). Eight show, then "Show all".
- **Engine:** "✕ Engine off · Fix" sits at the bottom, only while the engine is off.

**Rail:** 56 pt, replacing the sidebar below a 900 pt window.
- The app mark (24 pt) at y 60, New graph as a 32 × 32 `plus`, and 40 × 32 icon cells.
- Counts shrink to 16 × 16 capsules on the icon's corner.
- Names appear in tooltips and VoiceOver.

**Buttons**
- **Sizes:** regular 28 pt (padding 12), large 32 (padding 16), small 24 (12 pt label).
- **Shape:** radius 6; minimum width 64 (88 large).
- **Icon and keycap:** icon 14 pt with a 6 pt gap; keycap hint 11 pt Medium, 8 pt after the label.

| | Rest | Hover | Pressed | Disabled |
|---|---|---|---|---|
| Primary | ink fill, onInk Semibold | #F7F3EA | #D6D0C4 | overlay fill |
| Secondary | #161D27 + control edge | #1C2430 | #222B38 | edge #2A3342 |
| Quiet | text.secondary | hover fill, primary text | pressed fill | disabled text |
| Destructive | quiet, `signal.fail` | `tint.fail` | pressed fill | disabled text |
| Confirm | `signal.fail` fill, #0B0F14 | #FF8A7F | #E86A5F | n/a |

- **Daylight:** secondary #FFFFFF (hover #F2EFE8); confirm #B83327 with white text.
- **Selected** (segmented tabs, filters): a `bg.overlay` segment in Semibold, on a `bg.raised` track.
- **One primary per view:** trailing in sheets (Return), leading in the question card (⌘1).

**The question card**
It appears wherever a question does: Home, a graph (docked over the plan, and in the inspector), a chat (docked over its terminal), the notch panel and ⌘J. Width 480–720 pt (416 in the notch panel); `tint.you` fill, radius 10, padding 20 (16 compact), no border (Increase Contrast adds a 1 pt `signal.you` border). The question is short and the facts behind it are on the card, so a person can decide without opening a file, with each file one click away.

1. **Header, 16 pt:**
   - A 10 pt ◆ and the NEEDS YOU eyebrow in amber (8.4:1).
   - The source in 12 pt secondary, team › graph › step: "Northwind › pricing-r3 › Baseline review". A chat shows a magenta glyph and "Chat · Northwind".
   - Trailing: "waiting 12 min" ("just now" for the first 30 s), and before it a quiet ↗ that opens the graph or the chat.
2. **Question**, 12 pt below: `question` style, at most 3 lines (2 on a compact card) and 15 words; the whole question is its tooltip.
3. **Context**, 8 pt below: the short context lines (at most 3) in `body` secondary. No "More ›": the depth is the next section.
4. **What you're deciding**, 14 pt below, only when there are points or points are on their way:
   - The WHAT YOU'RE DECIDING eyebrow, with a quiet "Hide details" / "Show details (4)" trailing. Open by default on a full card; the choice is kept per question (forgotten 30 days later).
   - Up to six points (the card's `detail`, GRAPH-LOOPS.md › *The question card*): each a tertiary "•" and the point in `body` primary, wrapping freely. A point with a file has a quiet 11 pt cyan link under it, "↗ PLAN.md · Scope" (the file's name, then where in it), with the full path in its tooltip.
   - Then, 8 pt below, who wrote them, 11 pt tertiary, at most 2 lines: "Summary by Claude Haiku from the files · check the files for the full picture", "Written by the chat", "Written by CyberPong from the step's report", "Written by the graph's designer", or, when the designer wrote the question and the points came later, "Written by the graph's designer, with points by Claude Haiku from the files · …" / "…, with points from the step's report".
   - While a helper AI is still writing the plain words or the points: "Details coming…" in 11 pt tertiary. No points and nothing coming: no section at all.
   - VoiceOver: one group labelled "What you're deciding"; each point reads as text, each link is a button ("Open PLAN.md, at Scope").
5. **Files**, 12 pt below, one 20 pt row each:
   - `doc.text` and the file's name in `data` cyan (9.9:1); its folder in the tooltip; two files with one name add their folder's name.
   - All of them: the first 3 as links, then a quiet "+N more" that opens a menu of the rest.
   - While the points show, a file a point already links is not listed again.
   - A click opens a document (Markdown, text, JSON, PDF, an image, HTML …) in its own app; ⌥-click, or any other kind of file, shows it in Finder. A file that is not on this Mac copies its path and says so.
6. **Jev's line**, 12 pt below:
   - The JEV eyebrow, then "Approve 62%" in 12 pt Semibold, then "Send back 30% · Stop 8%" in secondary.
   - If no option is above 50%, it reads "Jev is unsure".
7. **Note**, 16 pt below: a quiet "+ Add a note"; pressed (or by a first press of Send back) it becomes a field: "Add a note for the step that redoes the work (optional)". A chat question whose one answer is a reply opens with the field, "Your answer".
8. **Buttons**, 16 pt below, large, 8 pt apart, wrapping onto a second row when the card is narrow:
   - [Approve ⌘1] primary · [Send back with a note ⌘2] secondary · [Stop the graph ⌘3] destructive. A chat's own options: the first primary, the rest secondary.
   - Keycaps show on the focused card only.
9. **What it does**, 8 pt below, 11/14 tertiary, at most 2 lines: "Approve goes on to Draft."
   - Pointing at another answer swaps in that answer's line.
   - The line is also each button's tooltip and VoiceOver help.

**How the card behaves:**
- **Where it is full:** Home's first card, and in the inspector a step's question that isn't the one docked at the top of the graph. Home's other cards and a graph's or a chat's docked card are compact.
- **Compact card:** padding 16; the header, the question (2 lines), the first context line (one line) and the buttons (regular size), with a quiet "Details ›" at the end of their row. No points, files, Jev line, "+ Add a note" or what-line; the note field still opens there on a first press of Send back, and a chat question answered by a reply shows it from the start. "Details ›" opens that card in place to the full card, with "Show less" where "Details ›" was; a card the person opened stays open when the page draws it again.
- **States:** a click (or ⌘J, which also opens a compact card in full) focuses a card: keycaps and the 2 pt cyan focus ring. While sending, the buttons are disabled and a working ring sits in the header; once answered, it becomes a receipt.
- **Its height follows what shows.** Opening or folding the points, "Details ›" / "Show less", a note and the receipt tell the page, and Home, the graph banner and the inspector lay out again around the card. A docked card taller than its room scrolls its upper part, cut between two lines and never through one, with a scroller that stays drawn, and pins its answers part under it, so the buttons are always in sight.
- **Late words show up.** The question, the context, the points, who wrote them and "coming…" are part of each page's redraw check, so plain words or points that arrive later appear without a click; a note being typed is never wiped.
- **Stop asks twice.** The first press turns it into Confirm ("Click again to stop") for 3 s. Esc cancels.
- **After an answer**, a 36 pt receipt, "✓ Approved · 14:02", and a toast. Home draws again 10 s later, a docked card 6 s later. An answer that didn't go through says why in plain words; when the loop's rounds are spent, the toast offers "Allow one more round".

**Inspector:** 320 pt with padding 20. It docks in windows ≥1,100 pt wide (`bg.base`, leading hairline); otherwise it is an overlay (level 2, `panel` motion; Esc closes it).
- **Header:** the step name (`question`), its marker and word, and "Runs on: Grok 4.7".
- **Sections,** 24 pt apart:
  - RIGHT NOW (at most 3 lines);
  - RESULT FILES;
  - JEV'S CHECKLIST (weakest first, 4 pt bars, %);
  - Details › (folded: `data` under FOR ENGINEERS, with Copy).

**Steps list:** 36 pt rows.
- **Each row:** the index "03" (`data` tertiary, 28 pt column), the marker, the name (13 pt Medium), "round 2 of 3" as meta, and the time.
- **Spine:** a 1 pt `line.mark` joins the markers.
- **Working step:** its row is `bg.overlay`.

**Terminal frame (architect chat)**
- **Frame:** always Night: `bg.void`, registration marks, 16 pt inset.
- **Text:** #DCE2EA (15.3:1).
- **ANSI colours:** red #FF7A6E, green #8FD6A0, yellow #F5C451, blue #7AA7FF, magenta #FF6EC7, cyan #4CD6E0, white #AAB2BE, bright black #7A8699. All are ≥5.4:1.
- **Cursor:** a cyan block at 60%. **Selection:** cyan at 25%.
- **Footer (24 pt):** "⌃Tab leaves the terminal", plus a quiet History button.
- **Focus:** the marks turn cyan while the terminal has the keyboard.
- **Questions:** the architect's question docks above the terminal as a compact card; answering sends the keys.

**3D deck** (graphs and the Team map)
- **Backdrop:**
  - A `DeckBackdropView` (fog, scanlines, grain) under a transparent `SCNView`.
  - Registration marks with 12 pt arms.
  - HUD eyebrow top-left: "STEP 03 / 07 · REVIEW".
  - Fit, −, + and 2D as 28 pt quiet icons, top-right.
  - Esper readout bottom-left, "X 0.42 Y 0.18 ×2.4", shown only while zooming.
- **Nodes:** flat billboarded squares with `lightingModel = .constant`, 24 pt, a 1.5 pt outline and a `bg.base` fill.
  - Pending: `line.control`.
  - Working: cyan on `fog.teal`, plus a glow sprite (1.6× the node, 35%).
  - Needs you: amber on `tint.you`, with ◆ above.
  - Done: secondary ✓. Failed: red ✕. Stopped: tertiary.
  - Stale: dotted, at 60%.
- **Selection:** corner ticks 6 pt out, in text.primary. It never glows: glow means live.
- **Edges:** 1 pt `line.mark`. The edge into the working step is cyan at 60%; into a question, amber at 60%.
- **Labels:** 2D overlays, not textures: 11/14 SF Medium on a void chip at 70%. They always show for working, needs-you and selected nodes.
- **Framing:** fit to the bounds + 48 pt on open and on resize.
- **Accessibility:** the Steps list is the accessible equivalent.

**Notch panel** (beside the Mac's notch; part of the app since 2.1, built from these same tokens and components, with no palette of its own)
- **Colour:** always Night. Its body is #000000 to meet the notch, the one exception.
- **Closed:** chin height (the notch's height + 2 pt, about 34 pt; a 28 pt black tab at the top centre of a screen without a notch). Nothing sits over the camera; concave shoulders join the two sides.
  - Left of the notch: one marker, the most urgent state, and a count of graphs (11 pt Semibold, tabular), at most 64 pt. Both groups when something needs you and graphs work: "◆ 2  ◠ 3". The working count shows from 2.
  - Right of the notch: one line, 11 pt Medium with tabular digits, at most 150 pt. It names the graph and says what it needs or how far along it is: "Pricing page needs you" (amber), "Checkout fix · 3/4", "Research · step 2", "Login form · quiet 14 min" (tertiary), "Paused · back 3:45 pm", "Graph runner off" (red). The name truncates in the middle; the tail never does.
  - Which line wins: needs you (the oldest, never rotated), then Graph runner off, then a finished note (3 s), then a turn every 5 s through the working graphs, the quiet ones and, while Claude's limit holds graphs, one "Paused · back 3:45 pm"; then paused by you, then waits for its team; else the bare notch. The turn stops while the pointer is on the panel.
  - Nothing in it is smaller than 11 pt text or a 16 pt marker; progress is words ("3/4"), never a filling shape or a track.
- **A new question (the nudge):** the shape opens a little below the notch (at most 64 pt below the chin, up to 360 pt wide): ◆, the question in 13 pt Semibold on one line, and "Northwind › Pricing page" in 11 pt tertiary under it. It stays 6 s, then folds back to the amber count. Several at once: "Pricing page needs you · and 2 more". Pointing at it or clicking it opens the panel at that question. No nudge at night (10 pm to 8 am, a setting that is on unless turned off); the amber count still shows.
- **Open:** a 440 pt body with 17 pt concave shoulders and 20 pt bottom corners; content 416 pt (12 pt sides); as tall as its content, down to 24 pt above the Dock (at least 320 pt), with one scroll area under the count line.
  - Top band, beside the camera: the marker and count stay where they were, then Keep open (a pin, cyan when on) and ⋯; on the other side the compact [Graphs | Teams] switch (`PongSegmented`, 24 pt, about 116 pt wide), the same setting as Settings › Notch panel › Shows.
  - Count line (28 pt): "◆ 2 need you   ◠ 3 working   ‖ 1 paused   ○ 1 waits for its team" ("All quiet." when nothing is), then banners for what the person can fix: Graph runner off [Turn on], Claude's limits, Engine off [Fix].
  - NEEDS YOU · 1 OF 3 comes first in both views: the focused question card, then a 36 pt line per other question (clickable to focus), then problems as red cards. A question that arrives while one is being read joins the list; it never replaces the focused card.
  - Graphs view: a 60 pt row per graph (its name and team; the step track with "Step 3 of 4 · Run the tests · Claude Sonnet · round 2 of 3"; what it is doing now, with its age), 44 pt and two lines while anything waits. Steps › opens the step list inside the row. Finished graphs fold under "Show 3 finished".
  - Teams view: a row per team (its marker, name, "Lead: Claude Opus · 2 helpers · …", a 20 pt line per member, the lead's last message, its graphs as chips), chats after the teams, and the "Message the lead…" box.
  - Footer (44 pt): + New graph · Open CyberPong ↗ · "Claude this week: 84%" at 80% or more.
- **The question card in it:** the app's card at 416 pt: padding 16, radius 10, 28 pt buttons, the source on its own line under the header. What you're deciding is open on the focused (first) card and folded ("Show details (4)") on the others; the choice is kept per question, as everywhere. Buttons wrap: Approve and Send back with a note on the first row; Stop the graph always starts the next row, away from the primary. Keycaps and ⌘1–3 on the focused card only. After an answer the receipt line is the confirmation (no toast); after the last one, "That's everything." and the panel closes 1.5 s later.
- **Behaviour:** it opens when the pointer rests on the notch (a 0.15 s wait; a fast sweep past it never opens it) or on a click, and closes 1 s after the pointer leaves (at least 3 s while a question shows); it never closes while a note is being typed or an answer is sending. It takes the keyboard only for typing or after a click on it: answering, pinning and switching views never bring CyberPong's windows forward (opening a graph does). Settings › Notch panel holds these choices.
- **Motion:** open, a spring of 0.42 s; close, 0.36 s, the window shrinking only after it ends; the line slides 0.28 s; the nudge drops in 220 ms and folds back in 180 ms. Reduce Motion: fades.

**The rest**

| Component | Size | Anatomy | States, rules | Used in |
|---|---|---|---|---|
| Window bar | 52 pt, `bg.base` | Sidebar toggle; parents breadcrumb (`control`, secondary). Trailing: ≤2 actions, ⌘K (220 × 28; a magnifier at 960), inspector toggle | Hairline only under scrolled content; drags; double-click zooms | All pages |
| List row | 52 pt, padding 12 | Marker cell 16 at x 12; `bodyStrong` title at x 40; `secondary` status line; trailing 72 pt column: state word (12 Medium, marker colour) + time; divider from x 40 | Selected pill inset 4 | Home, lists |
| · graph / chat / team | | Graph: "Working: Baseline review · step 3 of 7 · Northwind". Chat: magenta `text.bubble.fill` in a 20 pt `tint.architect` circle (6 pt cyan dot when live), "Architect · Claude Fable · 3 graphs". Team: "Lead: Grok 4.7 · 2 helpers" | Stopped team: quiet "Start" on hover | Graphs, Chats, Teams |
| Text field | 28 pt (3→8 lines), padding 8, radius 6 | `bg.field`, control edge, `body`, tertiary placeholder (6.2:1), 12 Medium label above | Hover edge #7D889B; error: edge + 11 pt `signal.fail` line with ✕; disabled edge #2A3342 | Sheets, cards |
| Activity row | 28 pt | Time in `data` tertiary ("now" in cyan), 12 pt marker, step 12 Medium, event 12 secondary | Repeats merge ("×3"); day-break eyebrows | Graph, Team |
| Health strip | 32 pt, `bg.raised`, radius 6 | "◆ 2 need you · ◠ 1 working · ■ 1 stopped"; trailing "✓ Engine OK" (or "✕ Engine off" + Fix), "Next run 16:30" | Items filter | Home |
| Toast | 36 × ≤420, bottom centre | Level 2, radius 10, `body`, optional cyan action | One at a time; announced | All |
| Sheet | 520 (New graph 560), padding 24 | `bg.raised`, `question` title, ≤2 sentences, 56 pt footer: [Cancel] + large primary | Esc / Return; ≤3 buttons | Create flows |
| Alert | 400 pt `PongAlert` sheet | "Stop “pricing-r3”?"; one consequence line; [Stop graph] destructive, [Keep running] primary | The safe choice is loudest | Destructive acts |
| Empty state | ≤360, centred | Registration marks (12 pt arms) 40 pt out; `question` headline; ≤2 lines; one button; Home adds ≤3 example chips | "Nothing needs you." | Every list |
| ⌘K | 640, 20% down, radius 14, level 2 | 56 pt field (17 pt); eyebrow groups; 40 pt rows (icon, title, subtitle, keycaps), ≤8; last row "Ask the Guide: “…”" | Selected `bg.selectedOnOverlay`; opens in 120 ms (fade; the 0.98→1 scale drops under Reduce Motion) | Everywhere |

## 4. Screens
- **Units:** points, from the top-left.
- **At 960:** sidebar 200 pt; text column x 224–936.
- **At 1440:** sidebar 232 pt; margins 32.
- **Every page:** window bar y 0–52, title y 64–92, status line y 96–112, content from y 132.

**Home (Needs you)**
```
960×680 x 0            200 224                                        936
y   0   ● ● ●          │ ⧉                                      ⌕  ⊞ │ bar
   52   CYBERPONG      │
   64                  │ Needs you                                    │ 22/28
  104   [+ New graph]  │ [◆ 2 need you  ◠ 1 working  ■ 1 stopped  ✓ OK]│ 32
  148   ◆ Needs you  2 │
  156                  │ ┌ question card, focused, 712 × ~312 ────────┐
  180     Chats        │ │ ◆ NEEDS YOU  Northwind › pricing-r3        │
  212     Graphs     1 │ │ Approve the baseline review and go on…?    │
  244     Teams        │ │ context · file · Jev's line · note         │
  276     Schedules    │ │ [Approve ⌘1] [Send back… ⌘2]  Stop ⌘3      │
  324   TEAMS          │ └────────────────────────────────────────────┘ 468
  348     ◠ Northwind  │
  380     ■ Riverside  │
  480                  │ ┌ compact card, 712 × 118 ───────────────────┐
  622                  │ WORKING NOW · 52 pt rows (scrolls)
```

**A graph (Plan / Steps / Screen)**
```
960×680  200                                                      960
   0     │ ⧉ Northwind › pricing-overnight-r2       [Pause]  ⋯  ⊞ │
  64     │ pricing-r3                        [Plan|Steps|Screen] │ 240 × 28
  96     │ ◠ Working: Baseline review · step 3 of 7 · 26 min       │
 132     │ compact question card while waiting (118)              │
132–644  │ Plan: deck edge to edge (from 262 under a card)         │
644–680  │ ACTIVITY · 12 events · last 21:50 ▸ (unfolds to 240)   │
```

| Screen | 960 × 680 | 1440 × 900 |
|---|---|---|
| Home | As drawn | Main column x 264–984; Today column x 1016–1408 (NEXT RUNS, FINISHED SINCE YOU LOOKED); the health strip spans both |
| Graph | Selecting a step opens the inspector overlay at x 640–960 | Content x 232–1120; inspector docked x 1120–1440; deck y 132–864; activity y 864–900 |
| Chat | Subtitle "Architect · Claude Fable · ◠ Live"; bar: [Show its graph], ⋯; pending card y 132–250; terminal x 224–936, from y 132 (262 under a card) to 664, ≈87 columns at 13 pt | Terminal x 264–1088, y 132–884 (≈101 columns); docked inspector: ITS GRAPHS, FOLDER, Details |
| Team | Bar: [Start team] when stopped, ⋯ (Stop, Team layout, Save as template); MEMBERS from y 132; MAP x 200–960, y 340–600; composer y 624–680 ("Message the lead…", [Send] primary once typed) | Left column x 264–704 (members, next runs, composer); map x 736–1440, y 52–900 |
| Schedules | [New schedule] primary in the bar; NEXT RUNS (44 pt rows: time, "in 25 min", what, team, quiet "Run now"); ALL SCHEDULES (52 pt rows: last result, "Every weekday at 9:00", switch) | Same column (≤824) + docked inspector with the next 5 runs |
| Settings (⌘,) | Own window, 720 × 540 (height to 900). List 180 pt: General, This Mac, Notch panel, AI accounts, Permissions, Quality bars, Notifications, Advanced, Limits & keys. Pane padding 32; `bg.raised` cards of 40 pt rows; Permissions show live ✓/✕; changes apply at once | Identical |

**New graph sheet** (560 × 436 at both sizes)
```
  24  What do you want done?                        17/22 Semibold
  50  An architect plans it with you, then runs it. 12 secondary
  82  ┌ field 512 × 120: "e.g. Compare our three competitors' prices…" ┐
 222  WHERE  [~/…/Sites/northwind ▾] 512 × 28 (recent, Choose…)
 288  START FROM A RECIPE  (Research and summarise) (Build and check) (Review a doc)
 350  ▸ More options (AI, model): quiet, adds 44
 380  ───────────────────────────────────────── hairline
 394                           [Cancel] 88   [Start] 96 × 32
```
Focus starts in the field. Return starts; Esc cancels.

## 5. Logo use
- **Placement:** the top of the sidebar, in its own 40 pt row under the traffic lights (y 52–92). In the window bar it would fight the page title.
- **Size:** 28 pt tall, 118.5 wide.
  - Measured in the PNG: the letters fill 34.9% of the height (9.8 pt capitals) and 82.2% of the width.
  - The left 8.1% is empty, so set the image at x 6.4 to put the "C" on the 16 pt content line.
- **Clear space:** one capital height (10 pt), glow included.
- **Minimum:** 22 pt. Below that, and in the rail, use the app mark at 24 pt.
- **Night:** `cyberpong-wordmark-dark.png` on #090C10. Composited there, its glow stays intact.
- **Daylight:** `cyberpong-wordmark-light.png` on #ECE8E0. The dark file washes out on light.
- **Never:** recolour it, add glow, animate it, or set it on the deck or a tint.

## 6. Two alternative directions
**A · "Wallace": quieter, Linear/Apple.** Neutral graphite: frame #0E0E10, base #111113, raised #18181B, overlay #202024. Text runs #F2F2F3 / #A0A0A8 / #8A8A93 (16.9, 7.3 and 5.5:1). One accent, #4DB6E8 (8.2:1), covers interaction and working; amber #F0A43A means needs you, red #F26B5E means failed, and there is no magenta. Type is SF Pro everywhere, with SF Mono in terminals, so nothing is bundled. There is no texture and no marks, radii are 8 and 12, the sidebar and toolbar use Liquid Glass on macOS 26, and the deck opens in 2D. It is the cheapest and most native option, but Blade Runner survives only in the wordmark.

**B · "Las Vegas": cinematic, more fog and warmth.** Warm blacks taken from 2049's orange haze: frame #0D0907, base #120D0A, raised #1B1410, overlay #251B15. Text runs #F3E7D6 / #CBB79F / #AE9880 (15.8, 9.9 and 7.0:1). Sodium orange #FF9A2E marks needs you and fills the primary button (9.1:1); teal #3CC7C9 means working, magenta #FF5FB8 the architect, red #FF6A5C failed. Archivo Expanded also sets page titles at 20/26, over SF Pro and Plex Mono. Every page gets a 160 pt haze band at 6%, the deck floor 18% haze, the frame 4% grain; the primary button and live markers glow, and the Esper zoom runs on every page change. It is the most atmospheric option. But orange then means both "act" and "needs you", warm-on-warm text scans more slowly over hours, and the fog costs GPU and battery.

## 7. Building it in AppKit
**Semantic tokens**
- **New file:** add `src/PongTokens.swift`: hex primitives plus `PongColor`, `PongType`, `PongSpace`, `PongRadius` and `PongMotion`.
- **The notch panel:** part of the app since 2.1, so it uses these tokens as they are; it has no palette of its own.
- **Colours:** each is `NSColor(name:dynamicProvider:)`, choosing via `appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])`. SwiftUI uses `Color(nsColor:)`.
- **Layers:** resolve CGColors in `updateLayer()` inside `performAsCurrentDrawingAppearance`, then retire the `appearanceDidChange` notification.
- **Migration:**
  - Old names become `@available(*, deprecated)` aliases (lime → `signal.live` or `action.ink`), so the compiler lists every call site.
  - A typed `PongStatus` replaces `statusKind(_:)`.

**SF Pro**
- Always `NSFont.systemFont(ofSize:weight:)`, never by name; `monospacedDigitSystemFont` for counts.
- Eyebrow fallback: `systemFont(ofSize: 11, weight: .semibold, width: .expanded)` (macOS 13, the app's target); in SwiftUI, `.fontWidth(.expanded)`.

**Archivo Expanded (OFL)**
- **The font:** add the static Archivo Expanded SemiBold TTF from Google Fonts' Archivo family, unmodified, as `resources/fonts/ArchivoExpanded-SemiBold.ttf`. The variable file at `wdth 125, wght 600` also works.
- **Licences:**
  - Add Archivo's `OFL.txt` as `Archivo-OFL.txt`.
  - Plex Mono ships today without its OFL, so add that too, and remove Space Grotesk.
  - Have `build-app.sh` copy `*.txt` as well, and list the licences in `Credits.rtf`, which the standard About panel shows.
- **Loading:**
  - Register with `CTFontManagerRegisterFontsForURL(…, .process, nil)`, and create the font from `CTFontManagerCreateFontDescriptorsFromURL`, so no PostScript name is guessed.
  - Without the file, eyebrows fall back to SF Pro Expanded.

**NSVisualEffectView: no**
- **Why:** translucency makes contrast depend on what's behind the window, so every surface is solid.
- **Liquid Glass:** the build links the macOS 26.4 SDK, so stock parts adopt it. Instead:
  - use `NSSplitViewController` with `NSSplitViewItem(viewController:)` and `canCollapse`, since `sidebarWithViewController:` floats a glass sidebar;
  - draw the window bar under an empty unified `NSToolbar`, which gives the 52 pt title area and centred traffic lights;
  - test on macOS 13 and 26.
- **Accent colour:**
  - The app can't pin one: `NSAccentColorName` needs an asset catalog, and the Command Line Tools lack `actool`. That is why the Mac's own pink accent shows in shots 09–14.
  - Our controls never read `controlAccentColor`, we draw our own rings, and `PongAlert` replaces NSAlert.
  - Or compile an `Assets.car` once with Xcode and commit it.

**Night and Daylight**
- `NSApp.appearance` is `.darkAqua`, `.aqua` or `nil` (Match Mac), stored in `ui-prefs.json` (add `"system"`).
- The deck, terminals and Screen tab force `.darkAqua`; the notch panel is always dark.
- Swap the wordmark in `viewDidChangeEffectiveAppearance()`.
- Watch `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.

**Remove**
- **Colour:** #000 chrome, the always-dark `Launch` palette, lime, violet, the ten neon seat swatches, the 55% and 85% white lines, and the card borders in `applyCard` and `applyFloating`.
- **Type:** Space Grotesk, every size under 11 pt (119 places, plus the old island's 7–10 pt), and 24 sizes cut to 5.
- **Top bar:** tabs, team dropdown, "2 teams live" pill, moon toggle and ↻.
- **Team page:** the nine-pill toolbar, gesture strip, legend and Guide bubble.
- **Mission:** KPI tiles and charts on the main path.
- **Deck:** label textures, 12 pt corner brackets and `drawRings`.
- **Notch panel:** the old island's `Ink` palette and SF Mono (since 2.1 it is drawn with the app's tokens and components).
