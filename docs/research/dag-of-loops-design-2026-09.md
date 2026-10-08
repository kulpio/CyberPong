# A DAG of loops for CyberPong: the recommended design (2026-09)

**What this is.** This note judges three candidate designs and recommends one. The candidates are:
- **minimal**: loops derived from the graph, no new syntax;
- **subgraph**: `version: 2` loop nodes with nested bodies and `$next`/`$exit` edges;
- **jev**: a declared `loops` block, with Jev as each loop's controller.

It builds on the four research notes (`dag-of-loops-theory-2026-09.md`, `dag-of-loops-frameworks-2026-09.md`, `dag-of-loops-ai-research-2026-09.md`, `dag-of-loops-engine-map-2026-09.md`) and the contract `docs/GRAPH-LOOPS.md`.

**How to read the citations.** GE = `python/pong/graph_engine.py`, as it stood in the working tree on 2026-09-24 (3,219 lines). Another session is editing it, so the function names are the reliable anchor, not the line numbers. The other abbreviations are:
- JV = `python/pong/jev.py`
- SM = `src/GraphStudioModel.swift`
- DV = `src/GraphDeckView.swift`
- SV = `src/GraphStudioView.swift`
- CO = `python/pong/composer.py`
- T/ = `python/pong/loops/graphs/`

**How the numbers were found.** The loop derivations and job counts in §11 come from a throwaway script over the template files; nothing ran in the engine. Claims marked *(code reading)* were read from the source, not observed on a running graph.

## 1. The answer, in plain words

**Yes, and CyberPong is most of the way there.**

- **What the phrase means.** Read strictly, an "acyclic directed graph with loops" is a graph whose only cycles are self-loops, a "loop" in graph theory being an edge from a node back to itself (https://en.wikipedia.org/wiki/Loop_(graph_theory)). The Mirabilis page itself returns HTTP 403; only its one sentence is known, from a search index (theory note:18).
- **Every graph already has that shape.** Squeeze each group of steps that feed back into one another into a single box, and the boxes form a DAG (https://en.wikipedia.org/wiki/Strongly_connected_component). CyberPong's nine templates already are DAGs of loops, and each of their loops has one clear place where a round starts (§11).
- **The engine does not know it.** It counts visits per step for the whole life of a graph (`_cap` GE:575-580, `dispatch` GE:779-781), so a critic loop and your approval loop around it share one budget. In build-verify, once the inner loop has used `build`'s 4 visits, your next "rejected" ends the whole graph as `failed_bounded:rounds` instead of starting another round (`advance` GE:2240-2245 → `_bounded` GE:2188-2203; *code reading*).
- **What a real loop gets.** Treat each box as a loop with:
  - one entry;
  - its own round counter, which starts over when you send work back;
  - three exits (it passed, it ran out of rounds, it needs a person), all of which reach a person;
  - a record of its best round.

  Lint can then print the worst-case number of jobs before anything runs. A limit in one loop also no longer cancels the others, which today it does: `_bounded` falls back to `stop` (GE:2203, GE:2408).
- **Where Jev fits: each loop's stop button.** It works like a LabVIEW For Loop's conditional terminal, which can end a loop early but never raise its count (https://www.ni.com/en/support/documentation/supplemental/07/configuring-labview-for-loops-to-exit-conditionally.html). After each round Jev forecasts whether one more round will pass. It may stop a loop early; it may never make one run longer.
- **Why that is where Jev's value lies.**
  - Most of a refinement loop's gain comes in the first rounds, and later rounds can undo good work (https://arxiv.org/abs/2303.17651, https://arxiv.org/abs/2408.03314).
  - The signal to stop has to come from outside the model doing the work (https://arxiv.org/abs/2310.01798).
  - A judge that decides when to stop matched a fixed loop's accuracy at 49% of the cost (TUMIX, https://arxiv.org/abs/2510.01279).

## 2. Scores (0-10; build cost 10 = cheapest)

| criterion | minimal (derived loops) | subgraph (v2 loop bodies) | jev (declared block) |
|---|---|---|---|
| Power for real work | 6 | 9 | 8 |
| Simplicity for a three-person team | 9 | 4 | 6 |
| Compatibility with today's topologies and the Graphs page | 9 | 4 | 7 |
| Safety (bounded; a person decides outward actions; Jev never writes text) | 8 | 7 | 8 |
| How well it uses Jev | 6 | 6 | 9 |
| Build cost | 8 | 3 | 5 |
| **Total / 60** | **46** | **33** | **43** |

**minimal**
- **Strengths.**
  - It fixes the shared-budget bug for every existing topology without adding syntax.
  - Its derivation checks out on all nine templates (§11).
  - Its Jev question rides in the grade request that is already sent in the background (`_attach_jev` GE:1917-1934), so it costs no extra runner tick.
- **Weaknesses.**
  - It cannot tell apart two loops that share a header. In planner-sprints, `eval → sprint` means "next feature" on `win` and "fix again" on `fail` (T/planner-sprints.json edges).
  - It has one Jev question, and Jev can only escalate.
  - It has no parallel copies of a loop.

**subgraph**
- **Strengths.** It has the strongest structure: every level is acyclic, and loops nest to depth 3.
- **Weaknesses.**
  - Every template needs rewriting into nested JSON, and it would run two runtimes side by side.
  - Scoped ids need a separator whose safety is unknown (engine map §4).
  - It calls Jev synchronously, for up to 2 × 12 s, inside a tick that holds the graph lock (GE:2682). That is against the engine's direction: the last synchronous Jev call, the claim read, moved to the background (`_start_claim_read` GE:2020).

**jev**
- **Strengths: the best Jev design.**
  - It asks two complementary questions: a yes/no forecast of the next pass, which labels itself because the next round's grade is the answer, and a choice of what to do next.
  - Code applies the rules in a fixed order, and Jev can only shorten a loop.
  - Shadow mode keeps the labels unbiased.
- **Weaknesses.**
  - It requires rewriting a template's edges once a `loops` block is added: an edge from inside a loop to outside is a lint error.
  - It refuses scout-panel as written.

**Verdict.** Take **minimal's spine**: loops are derived from the graph a team already writes, and the budget belongs to each run of a loop. Graft onto it:
- **from jev:** its two Jev questions, its code-owned order of stop rules and its labelling plan; the best round kept as a `git stash create` ref; `extend` at the gate; and, later, a declared-loop override;
- **from subgraph:** the `escalate` outcome falling back to `bounded` edges; the order for ranking the best round; the lint rule that every loop's way out reaches a person; and the collapsible loop view in the UI;
- **not taken from subgraph:** nested bodies, scoped ids and synchronous Jev calls.

## 3. The design on one screen

1. **Every cycle is a loop the engine names.** Lint derives the loops from the existing nodes and edges (§5). No topology has to change.
2. **There are two kinds of loop.**
   - An **agent loop** repeats without you: builder ⇄ tests ⇄ critic.
   - A **person loop** is closed by your `rejected`. It sits around the agent loops it re-enters.
3. **A budget belongs to one run of a loop, not to a node's lifetime.** A loop's rounds start again whenever work enters it from outside, including your reject. Only a person extends a person loop (`--extend`).
4. **Every loop has three ways out: passed, bounded, escalate.**
   - A limit takes the loop's own way out to a person. If there is none, only that branch ends.
   - A limit never stops the graph or cancels a sibling loop.
5. **Loops remember.** Each round of a loop's run leaves a row (score, failing lines, check result), and exits carry the **best round**, not only the last.
6. **Jev is the condition port.** At the end of each round it answers "will one more pass fix it?" and "continue, stop with the best, or escalate?".
   - Code turns the answers into an outcome, and they can only end a loop early.
   - It starts in shadow mode and is switched on per rubric once the ledger has 100 labels.
7. **The Graphs page shows the loops.** It draws one ring per loop, person rings around agent rings, each labelled with the loop's own budget.

## 4. Words

- **Header**: the one node where a round starts.
- **Latch**: an edge from inside a loop back to its header. Crossing it ends a round.
- **Activation**: one run of a loop, from entering it to leaving it. It has its own round counter.
- **Round**: one pass of an activation. `max_iters` caps the rounds per activation.
- **Loose cycle**: a cycle with two or more entries (WCP-10, http://www.workflowpatterns.com/patterns/control/structural/wcp10.php). It keeps today's per-node caps.

## 5. How lint finds the loops (`_derive_loops`, new, called in `lint` after `_expand_copies` GE:240)

1. **Expand copies.** Copies (`id#k`, GE:381) are expanded as today. Below, the copies of one node count as that node.
2. **Find agent loops.**
   - Drop every edge that leaves a `human` node and run `_scc` (GE:343). Each non-trivial component A is a candidate agent loop.
   - **Its header** is the single node entered either by the start node or by an edge from outside A. Edges from a gate inside the same cycle group of the full graph do not count here; they are a person's re-entries.
   - **Its latches** are the edges from A into the header.
   - **Loops inside it:** remove the latches, run `_scc` inside A again, and treat any remaining cycle the same way. These are inner loops (a loop-nesting forest, https://llvm.org/docs/LoopTerminology.html).
   - **Loose cycles:** a component with no header, or with two or more, is a loose cycle. Lint warns, and its nodes keep today's lifetime caps.
3. **Find person loops.** An edge from gate g to node t is a **person latch** when t can reach g again without passing through a gate's answer.
   - The person loop's id is g, its header is t, and its body is g's cycle group in the full graph.
   - This rule is what makes jev-triage's forward choice gate `choose` a non-loop while `me` is a loop (T/jev-triage.json).
4. **Re-entry below the header.** A person may re-enter an agent loop below its header: scout-panel `read → fix` and fanout-synthesize `ok → synth`. That opens the agent loop at round 0, so its first return to the header counts as round 1.
5. **The invariant lint checks.** Every edge that closes a cycle is a latch of a derived loop or lies inside a loose cycle. No cycle goes uncounted.
6. **Defaults.**
   - An agent loop's `max_iters` is its header's `max_visits` if that is set, otherwise `max_rounds` (1..12, GE:229-235).
   - A person loop's `max_iters` is `max_rounds`.
   - Loop ids are the header id (agent loop) or the gate id (person loop). They cannot collide, because a gate is never inside an agent loop: its outgoing edges were dropped in step 2.

## 6. Topology syntax

**No syntax is required.** One optional top-level map, keyed by derived loop id, overrides the defaults. The keys arrive in stages (§12):
- **Stage 1:** `max_iters`.
- **Stage 2:** `stall`, `min_gain`, `keep`.
- **Stage 3:** `jev`, `min_iters`.
- **Stage 5:** `reenter`, plus `iterates` on an edge.

```json
{"name": "build-verify", "start": "build", "max_rounds": 4,
 "boundaries": {"max_wall_min": 180, "max_jobs": 16},
 "nodes": [
  {"id": "build", "role": "builder", "task": "Round {iteration} ({iterations_left} left). {goal}\nBest so far: {loop_best}\nFix: {prev_summary}"},
  {"id": "tests", "role": "check", "run": ["make test"]},
  {"id": "judge", "role": "critic", "family": "different", "jev": {"rubric": ["@code-change-spec"], "mode": "both", "diff": true}},
  {"id": "ship", "role": "human"}, {"id": "end", "role": "end"}],
 "edges": [
  {"from": "build", "to": "tests"}, {"from": "build", "to": "ship", "on": "blocked"},
  {"from": "tests", "to": "judge", "on": "win"}, {"from": "tests", "to": "build", "on": "fail"},
  {"from": "tests", "to": "ship", "on": "bounded"},
  {"from": "judge", "to": "ship", "on": "win"}, {"from": "judge", "to": "build", "on": "fail"},
  {"from": "judge", "to": "ship", "on": "abstain"}, {"from": "judge", "to": "ship", "on": "bounded"},
  {"from": "ship", "to": "end", "on": "approved"}, {"from": "ship", "to": "build", "on": "rejected"}],
 "loops": {"build": {"max_iters": 4, "stall": 2, "min_gain": 0.05, "keep": "best", "jev": "shadow", "min_iters": 2},
           "ship":  {"max_iters": 3}}}
```

The edges are those of T/build-verify.json. `pong graph lint` would print:

```
loops (outermost first)
  ship    person  header build  3 rounds  a reject opens a fresh `build` loop
    build agent   header build  4 rounds  latches: tests→build fail, judge→build fail
                                          exits: judge→ship win|abstain|bounded, tests→ship bounded, build→ship blocked
worst case 3 × (4 × 3) = 36 jobs; max_jobs 16 ends it first (under today's lifetime caps: 12)
```

**Other syntax changes.**
- **Prompt variables.** New are `{iteration}` and `{iterations_left}` (stage 1) and `{loop_best}` (stage 2), next to today's list (GE:632).
- **The `escalate` outcome (stage 3).** It joins `EDGE_ON` (GE:72). `_family("bounded", "escalate")` is true (GE:497), so an existing `bounded` edge catches it. `*` never matches it, as `*` never matches `bounded` today (GE:514).

## 7. Semantics

**Activations and rounds.** A helper `_cross(graph, source, targets, via)` runs once per routing, whether from `_route` (GE:2255), `_answer` (GE:2836) or `_bounded` (GE:2188). Running once per routing is what makes `meta → gen#1..4` count as one round.
- **Work enters loop L from outside.** L starts a new activation:
  - its round is 1, or 0 for a re-entry below the header;
  - its trail and stall state are cleared;
  - every loop nested in L goes idle and starts fresh on its next entry (reset on re-entry: Ptolemy's reset transition, theory note:106).
- **A latch of L.** If the round is already at `max_iters`, L takes its bounded way out (below). Otherwise the round goes up by one, L appends a trail row for the round that just ended, and the header is dispatched.
- **A person's latch.** It counts one round of the person loop and opens a new activation of the agent loop it lands in.
- **Work leaves L.** The activation closes, recording its outcome and its best round.

**Budgets.**
- **Loop members.** A node inside a derived loop skips the lifetime check in `advance` (GE:2240-2245) unless it sets `max_visits` explicitly. An explicit `max_visits` stays a lifetime cap, so planner-sprints behaves as today.
- **Lifetime counters stay.** `node.visits` is still kept, for the fresh-pane rule and for check file names.
- **Graph-wide backstops.** `max_jobs` (GE:774-778) and `max_wall_min` (GE:2689-2691) stay as they are.

**The bounded way out** (a round would pass `max_iters`; later also the stall rule or Jev). The engine tries, in order:
1. the sending node's `bounded` edge (today's rule);
2. any `bounded` edge from a member of L to outside L;
3. the enclosing person loop's gate, opened with the note "loop build ran 4 rounds without passing";
4. otherwise only this branch ends.

It never calls `stop`. When nothing else is running, `_finish_if_idle` (GE:2424) reports `failed_bounded:rounds`, as today, with the loop id in the summary. Keeping the reason string keeps `tests/test_graph_kind.py:113` and the app's labels valid.

**Person loops.** Before anything moves, `_answer` dry-runs a `rejected`. If the person loop is at its `max_iters`, if fewer than one round's jobs remain under `max_jobs`, or if an explicit `max_visits` would refuse the header, it raises the refusal with the reason. The gate stays open. For example: "ship: a 4th round is past this gate's 3; approve, or `pong goal resume --id g_… --outcome rejected --extend 1`". `--extend N` raises the person loop's cap by N and, if needed, `max_jobs` by N rounds' worth. **A person's answer never stops a graph, and only a person extends a budget.**

**Best round (stage 2).** Each trail row holds:
- `{round, outcome, shortfall (JV:1006), failing line ids with p, check passed/total and fingerprint (GE:1072-1077), diff size, snapshot}`.

Best means, in order: the check passed, then fewer failing lines, then lower shortfall, then the later round. A loop with only a critic and no scores falls back to the last round.

Snapshots:
- **Documents** are copied to `graphs/<id>/loops/<loop>/a<activation>-r<k>/`.
- **Code** is recorded with `git stash create`, which makes a commit of the working tree without touching it and leaves out untracked files (https://git-scm.com/docs/git-stash). The ref is shown at the gate and never restored by the engine.

Every bounded or escalate exit puts `loop: {id, round, best_round, best_shortfall, snapshot}` into `prev`, so the gate reads "best was round 2 (0.18 short); files on disk are round 4's".

**Stall rule (stage 2; engine only, no Jev).** For `stall` rounds in a row (default 2), check whether the failing set (rubric lines plus check fingerprint) shrank or the best shortfall dropped by `min_gain` (default 0.05). If neither happened, the loop takes the escalate way out. This generalises the two per-node `no_progress` rules (GE:1072-1089 and `_no_progress` GE:1864-1884, with `PROGRESS_STEP` 0.1 at GE:1126). It resets on each activation and replaces those two rules for derived loops. Loose cycles keep them.

**Joins (stage 2).** `_ancestors` (GE:2284-2297) skips latches. A join inside a loop then waits only for this round's predecessors, and it can no longer wait on or cancel a sibling loop through an outer back edge (engine map W4, *code reading*).

**Retries, errors, pause, old graphs.**
- A retry (`lost`, `timeout` or `graph retry`) uses `retry=True`, which counts no visit (GE:779-781) and no round.
- An `error` follows `error` edges and is never a round.
- Rounds are counted when work is routed, before `advance` holds it (GE:2246-2251), so held work resumes without being counted twice.
- A stored graph with no `loops` record runs under the legacy per-node caps.

## 8. Jev: each loop's condition port

**When.** At the end of a round in a loop whose latch sender already has a Jev grade: a critic with a `jev` block, or a `jev` grade node. The loop questions ride in the same background request (`_attach_jev` GE:1917; `_start_jev` GE:1679):
- the yes/no question joins the grade's own questions;
- the choice goes once in each option order, the way `decide` sends its two orders (GE:1555-1562).

Questions over one state are evaluated in parallel, and adding them "barely changes the response time" (TypeSafe's API documentation). The critic's route already waits for the attached answer (`_attached_wait` GE:1952-1961), so this adds **no runner tick**. Nothing is ever asked synchronously in the tick (GE:2682).

**Two questions.** Jev answers probabilities only; the engine writes every note.
- **`loop_next`** (yes/no): "If the step that made this work gets one more round, told exactly which rubric lines and checks failed, then after that round every rubric line will pass and every check will exit 0."
- **`loop_outlook`** (a choice, asked in two option orders, built with `choice_question` JV:540, which always adds `none`): "A bounded improvement loop has finished round {k} of {N}. From the work, the checks and the round history in the state, what should happen next?" The options:
  - `continue`: "another round is likely to fix what still fails";
  - `stop_best`: "the best round so far is as good as this loop will get";
  - `escalate`: "the loop is stuck or going backwards, or what still fails needs a person's decision".

**What Jev sees.** Everything the grade already sees (the goal, the documents, the checks, and the note that documents are data, GE:1435), plus:
- round k of N, rounds left and jobs left;
- the last 3 trail rows (per-line p, shortfall, failing ids, check passed/total, whether the fingerprint repeated, diff size);
- the best round and its shortfall.

It never sees the builder's own account (GRAPH-LOOPS.md:115). The trail is a few hundred characters, well under the 70,000-character state cap (JV:60).

**The decision is code: a pure `jev.loop_decide()` next to `decide`. The first rule that applies wins.**
1. The round's combined grade is `win` (`_combine`, GE:1964-2009) → the win edge. Jev cannot turn a win into another round.
2. The round is at `max_iters`, or the budget is spent → bounded.
3. The stall rule fires → escalate.
4. The round is below `min_iters` (default 2; TUMIX used at least 2, https://arxiv.org/abs/2510.01279) → continue.
5. In mode `on`, the loop stops early only when **all** of these hold:
   - `decide(outlook, takes={"escalate": 0.7, "stop_best": 0.9})` (JV:1073-1090) returns `route:escalate` or `route:stop_best`. That means both orders agree, the pick's P reaches its bar in each order, and the choice is peaked (`CHOICE_CONFIDENCE_FLOOR` 0.5, JV:919).
   - P(`loop_next`) ≤ 0.3 (`FAIL_P`, JV:908).

   Either stop takes the escalate way out with the best round. The note says "stuck" or "as good as it will get".
6. Otherwise → continue.

**Why these thresholds.**
- **0.7 to escalate** is the contract's bar for a reversible move (GRAPH-LOOPS.md:108): it only brings a person in sooner.
- **0.9 for `stop_best`** (`DEFAULT_TAKE`, JV:917), because it passes on work that did not win.
- **The yes/no gate keeps a confident-sounding choice from stopping a loop that Jev also thinks one more pass would fix.** A choice has no built-in way to say "unknowable" (an earlier review of TypeSafe's API). The yes/no question is the better-calibrated form: normalized yes/no answers scored 1.3–2.1× better on Brier than choices in an independent audit (quoted in an earlier review of TypeSafe's API).

**Fallbacks and authority.**
- The loop simply **continues**, and the cap and the stall rule still end it, when:
  - Jev is blocked (no key, breaker open, or a client-facing graph; `_jev_blocked` GE:1423);
  - the call errors or times out;
  - `none` is picked, or the two orders disagree.
- Jev never extends a loop, never produces `win`, and never sends anything off the Mac. Every loop way out reaches a person (lint rule L4).

**Modes, labels, rollout.**
- **Modes.** `jev`: `"shadow"` (the default wherever a Jev grade exists) logs and draws the answer and routes nothing. `"on"` applies rule 5. `"off"` does not ask.
- **`loop_next` labels itself.** The next round's combined outcome (`win` = yes) is written with `jev.label` (JV:1176). In shadow every loop runs to its own rules, so the labels are not biased toward loops Jev would have stopped (the selective-labels warning, judges-in-graph-loops:43).
- **`loop_outlook` is used only as an agreement check.** It is not calibrated on its own.
- **Switching a rubric's loops to `on`** requires two things:
  - at least 100 labelled `loop_next` answers (Platt from 100, GRAPH-LOOPS.md:88; judges-in-graph-loops:309);
  - a Brier score better than always predicting the loop type's measured pass rate for the next round.
- **Why the caution.** Jev's scores rank well but are not calibrated probabilities, and one yes/no question repeated 15 times ranged 0.43–0.53 (both from an earlier review of TypeSafe's API).

## 9. Lint rules

**Errors**
- L1. A `loops` key that names no derived loop. The message lists the derived ids.
- L2. `max_iters` or `min_iters` outside 1..12, or `min_iters > max_iters`.
- L3. `jev` set on a loop whose latch senders have no Jev grade.

**Warnings** (existing topologies keep linting)
- L4. A loop with no bounded way out (§7, steps 1-3) that reaches a person through seatless nodes.
- L5. A loose cycle. The message names both entries and says the cycle keeps per-step caps.
- L6. A loop with no way out, the existing check made per loop (GE:332-340).
- L7. The worst-case job count is printed always, and flagged when it exceeds `max_jobs`.
- L8. (Stage 2) Copies feeding a non-join node, where the second arrival is merged and lost (GE:2236-2239; tournament-evolve's `evolve×2 → meta`, engine map W5).

## 10. The Graphs page

- **Stage 1: rings.**
  - One ring per derived loop, taken from the snapshot's `loops` rather than the Swift SCC pass (SM:521-522).
  - Person rings are drawn outside agent rings. Labels read `build · round 2/4` and `ship · round 1/3 · you`.
  - Loose cycles keep the dashed ring, labelled `loose`.
- **Stage 1: fixes and counters.**
  - `GNode` reads `max_visits`, which the snapshot already sends. The node label and the inspector then divide by the node's own cap: today `visit n/maxRounds` (DV:409, SV:754) and the ring's `/g.maxRounds` (DV:178-179) show planner-sprints as `5/3`.
  - The budget line shows `jobs 7/16 · worst 36`, not `round r/maxRounds` (SM:352-353).
  - `visualSignature` (SM:321) includes each loop's round and status, so rings redraw.
- **Stage 2: best round.** A tick on the ring marks the best round. The inspector gets a trail table (round, outcome, failing lines, shortfall, best starred, snapshot ref).
- **Stage 3: Jev chip.** For example `Jev (shadow): continue · next pass 0.64`. The ring turns amber when a loop escalates.
- **Stage 5: collapsed view.** At Orbit, each loop collapses to one plate: the condensation, drawn.

## 11. Migration

Derived with the throwaway script under the §5 rules. "Worst" is the worst-case job count under stage 1, against today's lifetime caps; it grows only through a person's rejects, and `max_jobs` still binds.

| template | loops derived (outer → inner) | re-entry below header | worst / today / max_jobs |
|---|---|---|---|
| best-of-n | none (a DAG) | — | 3 / 3 / 8 |
| brain-loop | person `review` → agent `synthesize` | — | 19 / 7 / none |
| build-verify | person `ship` → agent `build` (latches tests, judge) | — | 48 / 12 / 16 |
| write-review | person `me` → agent `draft` | — | 32 / 8 / 12 |
| fanout-synthesize | person `ok` → agent `plan` (latch `synth route:more`) | `ok → synth` | 24 / 12 / 14 |
| scout-panel | person `read` → agent `panel` (copies grouped) | `read → fix` | 20 / 12 / 16 |
| tournament-evolve | agent `gen` (latch `meta → gen#1-4`, one round) | — | 32 / 32 / 40 |
| jev-triage | person `me` (`choose` is a forward gate) | — | 9 / 9 / 10 |
| planner-sprints | person `gate0`; person `ship` → agent `sprint` (4 latches) | — | 39 / 39 / 60 (lifetime `max_visits: 12` kept) |

- **Templates in stage 1.** No template edit is needed, and there are no loose cycles.
- **planner-sprints keeps `max_visits: 12`** (T/planner-sprints.json:26, :36, :42). Its "next feature" and "fix again" rounds share the header `sprint`. Only stage 5's `iterates` can split them into features (6) × fixes (3).
- **tournament-evolve (stage 2).** Add a join before `meta` (L8).
- **The interview.**
  - `fast` becomes 2 rounds. At 1 (CO:131) a loop can never go round.
  - `parse_stages` (CO:230) emits a `bounded` edge from each critic or check to the next `me`. Today it emits none (engine map W2).

## 12. Build plan

**Stage 1: loops the engine can see; a reject never kills a graph (this week, shippable alone)**
- **Engine** (GE):
  - `_derive_loops` in `lint`; `out["loops"]`.
  - The loose-cycle warning in `_warnings`.
  - `start_nodes` (GE:2911) creates `graph.loops` records. `WG.start` keeps `topology.loops`; today it keeps four keys (engine map §1.1).
  - `_cross` in `_route`, `_answer` and `_bounded`.
  - The `advance` cap skip.
  - `_bounded`'s fallback order (§7).
  - The `_answer` dry run and refusal, and `resume(..., extend=N)`.
  - `_record_jev` keeps `p_pass`, `shortfall` and the failing ids. Today `jev_runs` drops them (GE:1853).
  - A trail row at each latch.
  - `{iteration}` and `{iterations_left}` in `render_task`/`dispatch` (GE:632, 813).
  - `loops` in `snapshot_fields`/`snapshot_node` (GE:2995, 3046).
- **CLI:** the lint table and worst-case line, `goal resume --extend N`, and loop lines in `graph show`.
- **Swift:** the §10 stage-1 items.
- **Composer:** `fast` = 2; bounded edges to `me`.
- **Stage 1 does not include:** best-round snapshots, the stall rule, join scoping or Jev.

**Stage 2: best round and a real stall rule.** Trail ranking and snapshots, `{loop_best}`, `keep: best` on the bounded and escalate ways out, the loop stall rule, `_ancestors` skipping latches, L8 and the tournament-evolve join. Also give the wiring solver `graph.cycle_nodes` from the loop table (an earlier engine audit asked for it; engine map W10).

**Stage 3: Jev in shadow.** `loop_next` and `loop_outlook` in the attached grade request, `jev.loop_decide`, ledger labels, the `escalate` outcome and the ring chip. Nothing routes on Jev yet.

**Stage 4 (optional): Jev on, per rubric,** after the §8 bar. Platt scaling first.

**Stage 5 (optional, later):**
- declared overrides: `iterates` on a latch (planner-sprints features vs fixes), and `reenter: "continue"` (keep counting on re-entry);
- per-loop `jobs` and `wall_min` budgets;
- a `change_strategy` way out to a best-of-n branch with fresh seats (Snell et al., https://arxiv.org/abs/2408.03314);
- loop copies and for-each over a planner's list, only after a git worktree per parallel builder exists (GRAPH-LOOPS.md:88), with lint refusing a copied builder loop without one;
- `schedule: jev`, which gives the next round to the copy with the highest `loop_next`;
- collapsed loop plates.

## 13. Tests (tests/test_graph_engine.py beside :448; tests/test_jev.py; fake Jev via PONG_JEV_FAKE, JV:885)

- **Stage 1**
  - Golden derivation for the nine templates (the §11 table).
  - build-verify and write-review: after the inner loop has spent its rounds, `rejected` starts round 1 of a fresh agent loop, not `failed_bounded:rounds`.
  - Person-loop cap: the refusal keeps the gate open, and `--extend 1` accepts. A reject is also refused when less than one round of `max_jobs` remains.
  - At the cap, the ways out in order:
    - the sender's `bounded` edge;
    - another member's `bounded` edge;
    - the person gate;
    - the branch ends while a parallel loop keeps running, and only an idle graph finishes as `failed_bounded:rounds`.
  - `meta → gen#1..4` counts one round. A retry or held work adds none.
  - A two-entry fixture is loose and keeps lifetime caps. An explicit `max_visits` stays lifetime.
  - A stored graph without `loops` behaves as today. The existing tests pass unchanged, including tests/test_graph_kind.py:83-113.
  - `{iteration}` renders.
- **Stage 2**
  - The exit carries the best round, not the last.
  - The stall rule fires, and resets on a new activation.
  - A join in loop 1 does not wait on or cancel loop 2.
  - L8 warns.
- **Stage 3** (`loop_decide` table)
  - A win beats continue, and the cap beats continue.
  - Round 1 never stops.
  - `escalate` 0.95 with `loop_next` 0.35 → continue; `stop_best` 0.85 → continue.
  - Orders disagree → continue; Jev blocked → continue.
  - Shadow routes nothing and its history equals a no-Jev run apart from Jev events.
  - Labels are written on the next round's grade.

## 14. What not to build

- Nested loop bodies with scoped ids, `$next`/`$exit`, or a v2 runtime beside v1. That is the subgraph design's cost, with an unknown separator.
- A synchronous Jev call inside the tick, and a Jev-only node per round, which costs a 30 s tick (GRAPH-LOOPS.md:3).
- Jev extending a loop, declaring `win`, or paging a person whenever it is unsure mid-loop.
- One run-wide step counter as the only cap (LangGraph, MAF), loops with no cap, loops as templates that call themselves (Argo), re-running the whole flow as a loop (Airflow) (frameworks note §5).
- A dispatcher node for multi-entry cycles (Havlak). Warn, keep the legacy caps, and let a person split the node.
- The engine restoring code to the best round on its own. Learned halting or a marginal-gain rule before the ledger has labels. A seat declaring its own plateau (T/tournament-evolve.json:31).

## 15. Risks and unknowns

- **More jobs in the worst case.** build-verify can reach 4× today's worst-case count (48 vs 12), only through a person's rejects. `max_jobs` and the reject dry run bound it.
- **Surprise.** A derived loop may not be what an author meant. The lint table exists so they see it before starting.
- **Jev.** Its calibration on `loop_next`, and whether it reads round-over-round numbers reliably, are unknown (AI research note §7). The same Jev grades a round and forecasts the next, so the two errors are linked.
- **Unknown:**
  - how often live graphs hit the reject-after-budget stop (the ledger and graph history were not queried);
  - whether W4 and W5 have happened on a live team;
  - what share of rounds fix work and what share damage it in CyberPong loops;
  - the Mirabilis post's text beyond one sentence, and VisualSim's loop blocks (403).
