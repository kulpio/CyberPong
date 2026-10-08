# CyberPong: Blade Runner, but readable

Scout, 29 September 2026. Bracketed numbers point to **Sources**. Contrast ratios are my own WCAG 2.x calculations.

**In short:** Blade Runner is not more neon. It is fog, a few man-made lights, and screens that change with power and age. Keep the dark room. Drop most boxes and capitals. Give each colour one job: amber for you, cyan for the machines, magenta for the architect.

---

## 1. Blade Runner (1982) and Blade Runner 2049

**Territory Studio's 2049 screens.** Territory made 100+ screens for 15 sets [1]. Villeneuve asked for the tech of a world after digital: physical, organic, optical. They used lenses, microfiche, card files and macro photos of grapefruit [1][2][3]. The look follows power [1][2][4]:
- **Wallace Corp:** pure, geometric, black and white. Advanced and cold.
- **LAPD (Joshi's office, morgue, DNA archive):** plain, neutral, few colours, screen burn, a military feel. The morgue zooms through lenses in steps.
- **K's spinner:** warm, warped, ghosted, faded. Old tech for a low-status officer.
- **Market:** Japanese, Latin, Cyrillic and Arabic letters side by side.

They avoided the cliché of tinting everything blue [3].

**The 1982 film.** Screens were small CRTs with soft, low-resolution text. The Esper enlarges a photo by voice into grainy prints [5]. Syd Mead retrofitted the city: new parts bolted onto old ones. The mood is Art Deco plus a 1940s private eye [6]. Chris Noessel grades these screens poorly on use: they work because the script says so [7]. Film screens are seen for seconds; CyberPong's are read for hours.

**Palette.** LA is cyan, teal and greyish green over deep, detailed blacks. Las Vegas is a near single-colour orange haze. Wallace's rooms are amber, with rippling water light [9]. Joi's purple-pink glow bleeds through fog, and almost all light comes from signs and screens [8]. The 2049 logo is the 1982 lettering in neon turquoise, not red [10]. Poster palettes: orange #F78B04, teal #027F93, deep teal #153A42, brown-black #2B1718 [11]. Your wordmark already fits: turquoise (the 2049 logo) and magenta (Joi).

**Typography.** Not a Eurostile film: Eurostile Bold Extended appears once, on a spinner's CAUTION label [5]. The 1982 type is industrial grotesque: Akzidenz-Grotesk Extended on Tyrell's chairs, Futura on newspapers, OCR-A on the video phone, Goudy Old Style in the opening crawl [5]. 2049 opens in Gotham, and Danny Yount designed the titles [10]. Free stand-ins: Archivo Expanded for the Tyrell stencil, IBM Plex Mono or JetBrains Mono for OCR-style readouts.

**Texture.** In 2049, texture means something: fading, warping and grain show age and low status [2]. It is too much when it covers text you must read, or means nothing.

**Blade Runner vs. generic cyberpunk**

| | Blade Runner | Cyberpunk 2077 | Tron |
|---|---|---|---|
| Light | Man-made sources in fog and rain [6][8] | Neon everywhere | Glowing lines on black |
| Colour | Teal night, sodium amber, one magenta [8][9] | Dark red map, bright yellow and blue [12] | Cyan and orange on a grid |
| Screens | Change with class and age [1][2] | Style over data; a map crowded with icons [12] | Clean vectors |
| Technology | Analogue, mechanical, patched [1][6] | Chrome and glitch | Weightless, inside a computer [13] |

---

## 2. Readable dark and sci-fi interfaces in real products

| Product | What it does | Lesson |
|---|---|---|
| Linear, 2024 | Themes built in LCH from three inputs: base, accent, contrast. Inter Display headings, Inter text [14] | Derive all greys from a few tokens; one contrast setting yields a high-contrast theme |
| Linear, 2026 | Warmer grey, dimmer sidebar, fewer and softer borders. Their rule: "Structure should be felt not seen" [15] | Dim the chrome; kill loud hairlines |
| Arc | A theme is colour, grain and opacity, on the window frame [16] | Grain belongs to the frame |
| NASA Open MCT "Espresso" | #2C2C2C background, #ACACAC text, one key colour #03ACE4; each warning level has its own background, text and icon colour [17] | A status needs three tuned values |
| Open MCT "Darkmatter" (2024) | Sci-fi theme for the public VIPER rover site: #17171B, Chakra Petch numbers, Exo text [18]. Gradients cut after tests showed they slowed reading; corner marks group data; meets Section 508 [19] | Sci-fi can be accessible if data stays flat |
| SpaceX Crew Dragon | Web UI on touchscreens; a small physical panel for emergencies [20]. A tab turns red when its page has alerts (per a close recreation) [21] | Put "needs you" on the navigation |
| Bloomberg Terminal | Amber on black by default. After colour-blindness research (~20,000 users), amber kept neutral data; blue/red took market status [22] | Amber is a calm data voice |
| Android Automotive · Tesla | Builds from black; one accent, used sparingly; at least 4.5:1; white text at 88, 72 and 56% opacity [23]. Tesla's 2013 Model S screen used one plain sans, Gotham [25] | Three text levels, one accent, one family |
| Rivian, 2025 models | 3D car view moved from glossy realism to flat cel-shading, no gradients; tiny ambient animations [24] | Draw the 3D deck flat and outlined |
| Sci-fi UI kits | Arwes: still alpha, last release Aug 2023 [26]. augmented-ui: CSS-only, last update May 2024 [27]. Both web-only | Borrow corner-cut frames; adopt neither |

Warp and Raycast: I found no first-party write-ups of their visual systems. Warp's agent panel is in section 4.

**Rules**
- **Contrast:** WCAG needs 4.5:1 for text, 3:1 for large text and control edges [28]. Apple aims for 7:1 in small text [29].
- **Saturated accents** vibrate on dark and often fail contrast; soften them [30].
- **Small text reads worse in dark mode** [31]. Go up a size, never down.
- **Glow never rescues a colour.** Check text with the glow off. Keep data flat [19][24].
- **Motion:** purposeful, short, skippable and optional; never on frequent actions [32]. Small ambient touches can add life without stealing focus [24].
- **Standard meanings:** red for danger, amber for caution, green for normal [33].

**Current theme, measured** (`src/PongTheme.swift`): tertiary text (42% white on #000) is 3.9:1 and fails AA; hairlines at 55% white are 6.3:1, louder than that text; lime #D1F247 is 16.5:1 and vibrates. Hence the busy feel.

---

## 3. Typography for this look

Faces are free under the SIL Open Font License (OFL) unless noted. OFL fonts can ship inside a paid app with their copyright notice and licence text (an About box works); you may not sell the fonts alone [35]. Weights and axes are from Google Fonts' metadata [34].

| Face | Weights / axes | Verdict |
|---|---|---|
| Michroma | 400 only | Free take on Microgramma/Eurostile (both paid): the 1960s future. More *2001* than Blade Runner. Caps at 12 pt+ only |
| Orbitron | 400–900 | Display-only by design (18 pt+); reads as a game HUD |
| Chakra Petch | 300–700, italics | Square with tapered corners; echoes the wordmark. NASA uses it for numbers [18] |
| Oxanium | 200–800 | Made for small sizes and quick glances; fine from 11 pt. The best "tech" face |
| Rajdhani | 300–700 | Condensed and thin; condensed text reads ~11% slower at a glance [39] |
| Space Grotesk (now) | 300–700 | Keeps Space Mono's quirks. Better for headings than for 11–13 pt UI |
| Tomorrow | 100–900, italics | Clean and geometric, but generic |
| Saira | width 50–125, 100–900 | Condensed to expanded in one family |
| Archivo | width 62–125, 100–900 | Grotesque; at full width, a free cousin of Akzidenz-Grotesk Extended. Most Blade Runner; caps from 11 pt |
| SF Pro | system font | Licensed only for Apple-platform apps [36]; use the system font API |
| Inter / Geist | 100–900 | The best free UI faces. Inter has a Display optical size |
| IBM Plex Sans / Mono | Sans width 75–100 | Drawn around people and machines; the Mono is already bundled |
| JetBrains Mono / Geist Mono | 100–800 / 100–900 | Good terminal faces |
| Berkeley Mono | paid | App embedding needs an enterprise licence, priced on request [37]. Avoid |

**Three systems**

| System | Eyebrow / display | UI text | Mono | Why |
|---|---|---|---|---|
| **A · Tyrell (recommended)** | Archivo Expanded SemiBold, capitals | SF Pro | IBM Plex Mono (keep) | Closest to 1982; most legible; no new text licence |
| B · Wordmark | Oxanium SemiBold, capitals and big numbers | Geist | Geist Mono | Echoes the chamfered wordmark |
| C · Plex | IBM Plex Sans Condensed SemiBold, capitals | IBM Plex Sans | IBM Plex Mono | Least work |

**Type scale** (macOS defaults to 13 pt, with a 10 pt minimum [38])

| Role | pt / line | Face |
|---|---|---|
| Big numbers | 28/32 | SF Pro Semibold, fixed-width digits |
| Page title | 22/28 | SF Pro Semibold |
| Question on a card | 17/22 | SF Pro Semibold |
| Section title | 15/20 | SF Pro Semibold |
| Body and chat | 13/18 | SF Pro Regular |
| Secondary | 12/16 | SF Pro Regular |
| Meta, times | 11/14 | SF Pro Regular, Text 3 |
| Eyebrow | 11/14, capitals, +0.08 em | Archivo Expanded SemiBold |
| Data / terminal | 12/16 · 13/18 | IBM Plex Mono |

Capitals only for one- to three-word labels read at a glance [39]; all else in sentence case. Nothing under 11 pt on dark.

---

## 4. Apps that run or watch AI agents

| Tool | How runs are organised | "Needs you" signal | How you answer |
|---|---|---|---|
| Claude Code Projects | A conversation plus an Overview grouped: Ready for review, Waiting on you, Working, Landing, Idle, Resolved [40] | Dot on the Overview button; desktop alert on input or error [40] | Open the thread; answer or steer |
| Claude Code agent view | Rows by state; icon colour and shape; one-line summary refreshed every 15 s; age [41] | Yellow "Needs input" group [41] | Space to peek and reply; number keys pick an answer [41] |
| Warp | Panel: working, blocked (yellow), cancelled, failed, done [44] | Complete, request and error pop-ups that jump to the agent [44] | Approve in place |
| Cursor 2.0 · Codex app · GitHub mission control | One list of agents or threads (by project in Codex); changes shown per thread [45][46][47] | Live logs, mid-run steering [48] | Pause, refine, restart |
| LangChain Agent Inbox | Inbox styled like email plus support tickets [49] | Notify, question, review [49] | Accept, edit, respond, ignore (repo archived Sept 2026) [50] |
| LangSmith Studio | Graph mode for detail; a simpler chat mode for business users [51] | Run pauses at an interrupt | Resume, or chat |
| Airflow 3.1 | One list of every pending "Required Action" [52][53] | That list | Approve/reject, pick a branch, fill a form [52] |
| CrewAI AMP | Pending-review queue with a context panel [54] | Email first | One-click options plus comment; timeouts pick a default [54] |
| Zapier | A human step pauses the workflow [55] | Email or Slack link | Approve/decline with custom labels; reminders, timeouts [55] |
| GitHub Actions | A job held for review shows "Waiting" [56] | Review deployments | Approve/reject with a comment; fails after 30 days [56] |
| Temporal · Dagster+ · OpenAI traces · n8n | Related events merged into one timeline row [57]; home page leads with failures and health badges [58]; nested step bars [59]; tool calls await approval in Slack or chat [60] | Failures first | Varies |

**Run detail.** One run, three depths: a plain summary, a timeline that merges related steps into single rows [57], and the full log or trace [59]. LangSmith splits these into chat mode and graph mode [51].

**What users ask for.** People running ~30 Claude Code sessions want each one's state, a few words on where it stopped, and how long it has waited. One missed an agent looping on the same tests for most of a week. Colour should carry state, so nobody has to read [42][43].

**What works for a non-technical owner**
1. Group by state, not by tool or team.
2. One plain line per item: what it needs, where it stopped, how long it has waited.
3. Answer in place: two to four labelled buttons and an optional note.
4. Push, don't pull: a badge where you enter; an OS alert that opens the item.
5. Simple view first. The graph is the detail.
6. Safe defaults when nobody answers: a reminder, then a timeout.

---

## 5. Navigation for a Mac app with 4–6 areas

**Apple's guidance**
- A leading sidebar moves between top-level areas: two levels at most, hideable but not hidden by default, nothing critical at its bottom [61].
- Tab views are for closely related panes of one area, six at most [62].
- Toolbar: title under ~15 characters, three groups at most, one prominent main action at the trailing edge beside the inspector buttons [63].
- Inspector: details of the selection, in a trailing pane [64].

NN/g finds left-side lists easier to scan and grow than top bars [66]. Vercel swapped top tabs for a hideable sidebar in February 2026 [67].

**Proposed layout**
- Sidebar: **Needs you** (with a count) · **Work** (graphs) · **Architect** (chat) · **Teams** · **Schedules**.
- Needs you is the home page: asks first, then a one-line health strip, like Dagster's failures-first home [58]. It replaces Mission.
- Setup moves to Settings (⌘,) and a first-run guide.
- A trailing inspector for the selected step, seat or run.
- Tabs only inside an area, such as a graph's Deck · Steps · Log.
- The menu-bar icon, Dock badge and notch island show the same Needs-you count.

**Needs you.** Linear split its inbox into Priority and Other in September 2026 [68]. Crew Dragon lights the tab of any page with alerts [21]. Put state on the navigation.

**⌘K.** One shortcut everywhere; one palette for every action; forgiving search with synonyms; ranking by context [69]. Use plain verbs: "Approve…", "Pause team…", "Open graph…".

**Onboarding and empty states.** Teach by doing, tip in context, postpone setup behind good defaults [65]. Every empty state shows status, a hint and one next step [70]: "Nothing needs you. 3 teams working. Next check-in 4:30 pm. [Start a graph]".

---

## Recommended direction

**The idea:** Wallace-clean where you decide. LAPD-plain where machines work. K's-spinner wear only on what is old.

**Palette.** Contrast is on Base #0B0F14, with Raised in brackets.

| Token | Hex | Contrast | Use |
|---|---|---|---|
| Void | #07090C | — | 3D deck backdrop, window edge |
| Base | #0B0F14 | — | App background (replaces #000) |
| Raised | #121821 | — | Sidebar, cards |
| Overlay | #1A212C | — | Pop-overs, selected row |
| Hairline | #263041 | 1.4:1 | Dividers only |
| Control edge | #606C80 | 3.6:1 (3.4) | Field and button outlines |
| Text | #ECE7DC | 15.6:1 | Main text, warm off-white |
| Text 2 | #AEB5C0 | 9.3:1 | Secondary |
| Text 3 | #99A2B1 | 7.5:1 (6.9) | Meta, times |
| Sodium amber | #F5A524 | 9.4:1 | Needs you; the one main button, with dark text |
| Spinner cyan | #4CD6E0 | 11.0:1 | Working, live, links |
| Joi magenta | #FF6EC7 | 7.6:1 (7.0) | The architect's voice only |
| Alarm red | #FF7A6E | 7.6:1 (7.0) | Failed, blocked |
| Done | Text 2 + ✓ | 9.3:1 | Finished work recedes. No green |
| Haze | #C8641E | 4.9:1 | Fog gradient only, never text |
| Deep teal | #0E3B44 | — | Fog; selected 3D node fill |
| Tint fills | #2A1D08 · #0C2A30 · #2E0E22 | — | Amber, cyan and magenta card backgrounds |

Retire pure black, the lime and the 55% white hairlines. In my colour-blindness simulation, cyan and magenta nearly merge for red-green colour-blind users, so every state also gets a shape and a word: ◆ needs you, a turning ring for working, ✓ done, ✕ failed.

**Type.** System A: Archivo Expanded SemiBold capitals for eyebrows (11 pt, +0.08 em, three words max); SF Pro for all UI text; IBM Plex Mono for terminal and data. Space Grotesk leaves the UI. Oxanium is optional for big deck numbers.

**Texture rules**
1. Texture lives on the frame (sidebar, chrome, 3D void), never under text, cards or the terminal.
2. Grain: still, single-colour noise at 3% opacity or less.
3. Scanlines: the deck backdrop only. One device pixel in three, at 4% or less.
4. Glow: only the wordmark, live dots (8 pt or less), the focus ring and the selected node's edge; blur 10 pt or less at 35% opacity or less. Text never glows and passes 4.5:1 without it.
5. Fog: one vertical deck gradient, haze at 8% near the floor fading to void at the top.
6. No flicker, glitch or colour fringing on anything you read. Reduce Motion, Reduce Transparency or Increase Contrast switches off texture, glow and fog.

**Five signature details**
1. **Sodium-and-neon code.** Amber is you, cyan is the machines at work, magenta is the architect (Joi). Everything else stays neutral [8][9][33].
2. **Registration marks, not boxes.** 8 pt corner ticks and small index numbers ("03 / 07") replace hairline boxes, like the Esper's grid and Open MCT's corner marks [5][15][19].
3. **Fog behind the deck.** Amber haze low, teal-black high. Nodes are flat and outlined; only live nodes glow [8][24].
4. **Wear shows age.** Live items are Wallace-crisp. Stopped or stale ones take the spinner's wear: faded colour, faint grain, a "last seen 3 h ago" stamp, still at 4.5:1 or better [1][2].
5. **Esper motion.** Opening a graph zooms in three quick ~90 ms steps with a coordinate readout; a changed number leaves a 400 ms afterglow. Both stop under Reduce Motion [3][5][32].

---

## Sources

1. Territory Studio, "Blade Runner 2049" project page. https://territorystudio.com/project/blade-runner-2049/ (2017 project; accessed 29 Sep 2026)
2. Design Museum, "Q&A with David Sheldon-Hicks", Beazley Designs of the Year 2018. https://designmuseum.org/exhibitions/past-exhibitions/beazley-designs-of-the-year-2018/qa-with-david-sheldon-hicks-founder-of-territory-studio (2018)
3. AWN, "Communicating the Abstract: the User Interfaces of Blade Runner 2049". https://www.awn.com/vfxworld/communicating-abstract-user-interfaces-blade-runner-2049 (22 Jan 2018)
4. Jono Yuen, HUDS+GUIS, "Blade Runner 2049 – UI Design". https://www.hudsandguis.com/home/2018/blade-runner-2049 (27 Mar 2018)
5. Dave Addey, Typeset in the Future, "Blade Runner". https://typesetinthefuture.com/2016/06/19/bladerunner/ (19 Jun 2016, updated 4 Dec 2018)
6. H. Lightman and R. Patterson, American Cinematographer, "Discussing the Set Design of Blade Runner". https://theasc.com/article/blade-runner-set-design/ (Jul 1982; republished 8 Oct 2020)
7. Christopher Noessel, Sci-fi Interfaces, "Report Card: Blade Runner (1982)". https://scifiinterfaces.com/2020/06/08/report-card-blade-runner-1982/ (8 Jun 2020)
8. Rex Provost, StudioBinder, "Blade Runner 2049 Cinematography". https://www.studiobinder.com/blog/blade-runner-2049-cinematography-analysis/ (19 Dec 2021)
9. Salik Waquas, Color Culture, "Blade Runner 2049 – Cinematography Analysis". https://colorculture.org/blade-runner-2049-cinematography-analysis/ (13 Dec 2025)
10. Giovanni Blandino, Pixartprinting, "The fonts of Denis Villeneuve". https://www.pixartprinting.co.uk/blog/denis-villeneuve-fonts/ (12 Jun 2024)
11. color-hex.com, "blade runner 2049 poster" palette (community). https://www.color-hex.com/color-palette/71647 (accessed 29 Sep 2026)
12. Aiden Le Santo, Interface In Game, "Cyberpunk 2077 — UX/UI Critique". https://interfaceingame.com/articles/cyberpunk-2077-ux-ui-critique/ (14 Mar 2021)
13. Michael Moran, The Register, interview with Syd Mead on Tron. https://www.theregister.com/2017/10/20/syd_mead_and_tron/ (20 Oct 2017)
14. Linear, "How we redesigned the Linear UI (part II)". https://linear.app/now/how-we-redesigned-the-linear-ui (28 Mar 2024)
15. Linear, "A calmer interface for a product in motion". https://linear.app/now/behind-the-latest-design-refresh (12 Mar 2026)
16. Chris Coyier, "What's Good About the Arc Browser". https://chriscoyier.net/2022/12/08/whats-good-about-the-arc-browser/ (8 Dec 2022)
17. NASA Open MCT, Espresso theme constants. https://github.com/nasa/openmct/blob/master/src/styles/_constants-espresso.scss (accessed 29 Sep 2026)
18. NASA Open MCT, PR #7682 "Create new darkmatter theme" and its constants file. https://github.com/nasa/openmct/pull/7682 (merged 25 Apr 2024)
19. Rukmini Bose, "Darkmatter Theme" case study. https://www.rukminibose.com/darkmatter-theme (undated; accessed 29 Sep 2026)
20. Roger Cheng, Hackaday, "Displaying HTML Interfaces and Managing Network Nodes… in Space!". https://hackaday.com/2020/06/08/displaying-html-interfaces-and-managing-network-nodes-in-space/ (8 Jun 2020)
21. Dillon Baird, "Recreating the SpaceX Crew Dragon UI in 60 Days". https://dillonbaird.io/articles/mutantdragon/ (5 Jan 2022)
22. Bloomberg UX, "Designing the Terminal for color accessibility". https://www.bloomberg.com/ux/2021/10/14/designing-the-terminal-for-color-accessibility/ (14 Oct 2021)
23. Google, Android Automotive OS design system: Color. https://developers.google.com/cars/design/automotive-os/design-system/color (updated 23 Jul 2024)
24. Andrew P. Collins, via Yahoo Autos, "Rivian's New Cel-Shaded Infotainment Update". https://autos.yahoo.com/rivian-cel-shaded-infotainment-cool-215000373.html (7 Jun 2024)
25. Fonts In Use, "2013 Tesla Model S dashboard display". https://fontsinuse.com/uses/3997/2013-tesla-model-s-dashboard-display (27 May 2013)
26. Arwes, GitHub repository. https://github.com/arwes/arwes (latest release v1.0.0-alpha.23, 13 Aug 2023)
27. augmented-ui, GitHub repository. https://github.com/propjockey/augmented-ui (last update 28 May 2024)
28. W3C, Web Content Accessibility Guidelines 2.2 (SC 1.4.3, 1.4.11). https://www.w3.org/TR/WCAG22/ (12 Dec 2024)
29. Apple HIG, Dark Mode. https://developer.apple.com/design/human-interface-guidelines/dark-mode (updated 6 Aug 2024)
30. Material Design 2, Dark theme. https://m2.material.io/design/color/dark-theme.html (2019)
31. Raluca Budiu, NN/g, "Dark Mode vs. Light Mode: Which Is Better?". https://www.nngroup.com/articles/dark-mode/ (2 Feb 2020)
32. Apple HIG, Motion. https://developer.apple.com/design/human-interface-guidelines/motion (updated 9 Sep 2025)
33. ISO 2575:2021, Road vehicles: symbols for controls, indicators and tell-tales. https://www.iso.org/standard/68409.html (2021)
34. Google Fonts, family metadata and descriptions. https://github.com/google/fonts/tree/main/ofl (accessed 29 Sep 2026)
35. SIL, OFL FAQ, version 1.1-update7. https://openfontlicense.org/ofl-faq/ (Nov 2023)
36. Apple, Design Resources licence. https://developer.apple.com/support/downloads/terms/apple-design-resources/Apple-Design-Resources-License-20230621-English.pdf (21 Jun 2023)
37. U.S. Graphics Company, Berkeley Mono. https://usgraphics.com/products/berkeley-mono (accessed 29 Sep 2026)
38. Apple HIG, Typography. https://developer.apple.com/design/human-interface-guidelines/typography (updated 16 Dec 2025)
39. Page Laubheimer, NN/g, "Typography for Glanceable Reading: Bigger Is Better". https://www.nngroup.com/articles/glanceable-fonts/ (26 Nov 2017)
40. Claude Code docs, Projects: "See what needs you in Overview". https://code.claude.com/docs/en/claude-projects (accessed 29 Sep 2026)
41. Claude Code docs, Agent view. https://code.claude.com/docs/en/agent-view (accessed 29 Sep 2026)
42. anthropics/claude-code issue #96510, session status in the sidebar. https://github.com/anthropics/claude-code/issues/96510 (23 Sep 2026)
43. anthropics/claude-code issue #94374, status of many sessions at once. https://github.com/anthropics/claude-code/issues/94374 (14 Sep 2026)
44. Warp docs, Managing agents and Agent notifications. https://docs.warp.dev/agents/using-agents/managing-agents and https://docs.warp.dev/agents/capabilities/agent-notifications/ (both updated 24 Sep 2026)
45. Cursor, "Introducing Cursor 2.0 and Composer". https://cursor.com/blog/2-0 (29 Oct 2025)
46. OpenAI, "Introducing the Codex app". https://openai.com/index/introducing-the-codex-app/ (2 Feb 2026)
47. GitHub changelog, "A mission control to assign, steer, and track Copilot coding agent tasks". https://github.blog/changelog/2025-10-28-a-mission-control-to-assign-steer-and-track-copilot-coding-agent-tasks/ (28 Oct 2025)
48. Matt Nigh, GitHub blog, "How to orchestrate agents using mission control". https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/ (1 Dec 2025)
49. Harrison Chase, LangChain, "Introducing ambient agents". https://www.langchain.com/blog/introducing-ambient-agents (14 Jan 2025)
50. langchain-ai/agent-inbox, GitHub repository. https://github.com/langchain-ai/agent-inbox (archived 20 Sep 2026)
51. LangChain docs, LangSmith Studio. https://docs.langchain.com/langsmith/studio (accessed 29 Sep 2026)
52. Kenten Danas, Astronomer, "Introducing Apache Airflow 3.1". https://www.astronomer.io/blog/introducing-apache-airflow-3-1/ (26 Sep 2025)
53. Astronomer docs, "Human-in-the-loop workflows with Airflow". https://www.astronomer.io/docs/learn/airflow-human-in-the-loop (accessed 29 Sep 2026)
54. CrewAI docs, Flow HITL management. https://docs-platform.crewai.com/platform/en/features/flow-hitl-management (accessed 29 Sep 2026)
55. Zapier, "Human in the Loop" guide. https://zapier.com/blog/human-in-the-loop-guide/ (25 Sep 2025; updated 19 Jan 2026)
56. GitHub Docs, Reviewing deployments. https://docs.github.com/actions/managing-workflow-runs/reviewing-deployments (accessed 29 Sep 2026)
57. Temporal, "Updated Event History Timeline View is Now Available". https://temporal.io/change-log/updated-event-history-timeline-view-is-now-available (29 Aug 2024)
58. Dagster, "Introducing the new Dagster+ UI". https://dagster.io/blog/introducing-the-new-dagster-plus-ui (10 Sep 2025)
59. OpenAI Agents SDK docs, Tracing. https://openai.github.io/openai-agents-python/tracing/ (accessed 29 Sep 2026)
60. n8n docs, Human-in-the-loop for AI tool calls. https://docs.n8n.io/advanced-ai/human-in-the-loop-tools/ (accessed 29 Sep 2026)
61. Apple HIG, Sidebars. https://developer.apple.com/design/human-interface-guidelines/sidebars (updated 8 Jun 2026)
62. Apple HIG, Tab views. https://developer.apple.com/design/human-interface-guidelines/tab-views (updated 5 Jun 2023)
63. Apple HIG, Toolbars. https://developer.apple.com/design/human-interface-guidelines/toolbars (updated 16 Dec 2025)
64. Apple HIG, Split views and Windows. https://developer.apple.com/design/human-interface-guidelines/split-views and https://developer.apple.com/design/human-interface-guidelines/windows (both updated 9 Jun 2025)
65. Apple HIG, Onboarding. https://developer.apple.com/design/human-interface-guidelines/onboarding (updated 10 Jun 2024)
66. Page Laubheimer, NN/g, "Left-Side Vertical Navigation on Desktop". https://www.nngroup.com/articles/vertical-nav/ (16 May 2021)
67. Vercel changelog, "New dashboard redesign is now the default". https://vercel.com/changelog/dashboard-navigation-redesign-rollout (26 Feb 2026)
68. Linear changelog, "Priority inbox". https://linear.app/changelog/2026-09-03-priority-inbox (3 Sep 2026)
69. Tim Boucher, Superhuman, "How to build a remarkable command palette". https://blog.superhuman.com/how-to-build-a-remarkable-command-palette/ (12 Oct 2021)
70. Kate Kaplan, NN/g, "Designing Empty States in Complex Applications: 3 Guidelines". https://www.nngroup.com/articles/empty-state-interface-design/ (19 Sep 2021)
